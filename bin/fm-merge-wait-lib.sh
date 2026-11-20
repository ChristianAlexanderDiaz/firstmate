#!/usr/bin/env bash
# Watcher-owned waiting-on-you list, rebuilt once per due check sweep.
# Source after fm-backend, fm-pr-lib, fm-classify-lib, fm-dod-lib, and fm-busy-lib.
# GitHub ready ships share one GraphQL state read. Other forge providers retain
# their existing authenticated polls. No merge authority is granted here.
# The list is process-local: restarting the watcher rebuilds it. Each row binds
# the task metadata, status, activity, local head and authenticated
# poll registration. A change invalidates the row before it can suppress a poll
# or pane capture. Failed/partial reads never suppress ordinary handling.

fm_merge_wait_signature() {  # <state> <id>
  local state=$1 id=$2 wt head activity file
  wt=$(fm_meta_get "$state/$id.meta" worktree)
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  activity=$(fm_busy_classify_meta "$state/$id.meta" "$id" "$state") || return 1
  case "$activity" in 'idle '*) ;; *) return 1 ;; esac
  FM_MERGE_WAIT_HEAD=$head
  FM_MERGE_WAIT_SIGNATURE=$( {
    cksum "$state/$id.meta" "$state/$id.status" 2>/dev/null || return 1
    for file in "$state/$id.busy-state" "$state/$id.busy-gen"; do
      if [ -e "$file" ] || [ -L "$file" ]; then
        cksum "$file" 2>/dev/null || return 1
      else
        printf 'absent %s\n' "$file"
      fi
    done
    printf '%s\n%s\n' "$head" "$activity"
  } ) || return 1
  FM_MERGE_WAIT_SIGNATURE=$(printf '%s' "$FM_MERGE_WAIT_SIGNATURE" | cksum)
}

fm_merge_wait_collect() {  # <state> <bin-dir>; sets requests and GraphQL query
  local state=$1 scripts=$2 meta id kind last current signature head recorded_head index=0
  FM_MERGE_WAIT_REQUESTS=
  FM_MERGE_WAIT_QUERY=
  FM_MERGE_WAIT_RESULTS=
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    kind=$(fm_meta_get "$meta" kind)
    case "$kind" in ship|crewmate|'') ;; *) continue ;; esac
    [ "$(fm_meta_get "$meta" mode)" != local-only ] || continue
    case "$(fm_meta_get "$meta" yolo)" in on|1) continue ;; esac
    fm_merge_wait_signature "$state" "$id" || continue
    signature=$FM_MERGE_WAIT_SIGNATURE; head=$FM_MERGE_WAIT_HEAD
    recorded_head=$(fm_dod_meta_value "$meta" pr_head)
    if fm_dod_forge_head_is_named_head "$(fm_meta_get "$meta" mode)" && fm_pr_head_valid "$recorded_head"; then
      head=$recorded_head
    fi
    last=$(status_last_work_line "$state/$id.status") || continue
    fm_dod_done_reports_ready_pr "$last" || continue
    [ -z "$(status_open_decisions "$state/$id.status" "$kind")" ] || continue
    current=$(FM_CREW_STATE_NO_FORGE=1 "$scripts/fm-crew-state.sh" "$id") || continue
    case "$current" in
      'state: done '*) ;;
      'state: unknown · source: none · no current-state source available') ;;
      'state: unknown · source: status-log · presentation closed; waiting declaration changed · presentation: closed') ;;
      *) continue ;;
    esac
    fm_pr_poll_snapshot_capture "$state" "$id" "$scripts/fm-pr-poll.sh" || continue
    [ "$FM_PR_POLL_SNAPSHOT_PROVIDER" = github ] || continue
    [ "$(fm_dod_pr_url_from_done_note "$(status_line_note "$last")")" = "$FM_PR_POLL_SNAPSHOT_URL" ] || continue
    # Metadata/status/head may have changed during the authoritative read.
    fm_merge_wait_signature "$state" "$id" || continue
    [ "$signature" = "$FM_MERGE_WAIT_SIGNATURE" ] || continue
    FM_MERGE_WAIT_REQUESTS="${FM_MERGE_WAIT_REQUESTS}$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "w$index" "$id" "$signature" "$FM_PR_POLL_SNAPSHOT_REG_HASH" \
      "$FM_PR_POLL_SNAPSHOT_URL" "$head" "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY")"$'\n'
    FM_MERGE_WAIT_QUERY="${FM_MERGE_WAIT_QUERY} w$index: repository(owner: \"${FM_PR_POLL_SNAPSHOT_PATH%%/*}\", name: \"${FM_PR_POLL_SNAPSHOT_PATH#*/}\") { pullRequest(number: $FM_PR_POLL_SNAPSHOT_NUMBER) { url state isDraft headRefOid } }"
    index=$((index + 1))
  done
  [ -z "$FM_MERGE_WAIT_QUERY" ] || FM_MERGE_WAIT_QUERY="query {$FM_MERGE_WAIT_QUERY }"
}

fm_merge_wait_read() {  # <query>; executable via the watcher's bounded runner
  [ -n "$1" ] || return 0
  gh api graphql -f "query=$1" --jq '
    if .errors then empty else
      .data | to_entries[] | select(.value.pullRequest != null)
      | [.key, .value.pullRequest.url, .value.pullRequest.state,
         .value.pullRequest.isDraft, .value.pullRequest.headRefOid] | @tsv
    end' 2>/dev/null
}

fm_merge_wait_lookup() {  # <state> <id>; sets verdict: waiting, merged, changed
  local state=$1 id=$2 alias task signature registration url head identity
  local answer_key answer_url answer_state draft answer_head count=0 verdict=''
  FM_MERGE_WAIT_VERDICT=
  while IFS=$'\t' read -r alias task signature registration url head identity; do
    [ "$task" = "$id" ] || continue
    fm_merge_wait_signature "$state" "$id" || return 1
    [ "$signature" = "$FM_MERGE_WAIT_SIGNATURE" ] || return 1
    [ "$registration" = "$(fm_pr_sha256 "$state/$id.pr-poll-registration")" ] || return 1
    [ "$identity" = "$(fm_pr_file_identity "$state/$id.pr-poll-registration")" ] || return 1
    while IFS=$'\t' read -r answer_key answer_url answer_state draft answer_head; do
      [ "$answer_key" = "$alias" ] || continue
      count=$((count + 1))
      [ "$answer_url" = "$url" ] || return 1
      case "$draft" in true|false) ;; *) return 1 ;; esac
      case "$answer_state" in
        MERGED) verdict=merged ;;
        CLOSED) verdict=changed ;;
        OPEN)
          verdict=changed
          [ "$draft" != false ] || [ "$answer_head" != "$head" ] || verdict=waiting
          ;;
        *) return 1 ;;
      esac
    done <<EOF
${FM_MERGE_WAIT_RESULTS:-}
EOF
    [ "$count" -eq 1 ] || return 1
    FM_MERGE_WAIT_VERDICT=$verdict
    return 0
  done <<EOF
${FM_MERGE_WAIT_REQUESTS:-}
EOF
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ "$#" -eq 2 ] && [ "$1" = --read ] || exit 2
  fm_merge_wait_read "$2"
fi
