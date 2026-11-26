#!/usr/bin/env bash
# Keep each Herdr worker's no-mistakes view to the right of its chat.
# Ported from https://github.com/kunchenguid/firstmate/pull/3751's separate presentation record
# and session-locked lifecycle; destructive ownership stays with crew-state.
#
# Usage: fm-nm-review-pane.sh <task-id>|--sweep
# --sweep reconciles this home's workers, appending stderr to a 1 MiB rotated
# .nm-review-pane.log. It is the watcher's view-only entry point.
# Reads the current branch's run directly through bounded axi status, independently
# of supervision's stricter attribution. Ordinary crew-state reads remain passive.
# The existing watcher invokes this entry point on a ten-second cadence (rounded
# to its poll); all harnesses use the same code, without tool hooks.
# Task teardown closes the viewer through fm_nm_review_pane_close_locked.
# Non-Herdr and remote tasks are no-ops. Unknown run evidence preserves the pane.
#
# state/<id>.nm-review-pane is an atomic key=value presentation record:
# session, worker, worktree, workspace, tab bind the task endpoint; pane is the
# separate viewer pane, run its attributed run id, started is 1 after pane run.
# An empty pane retains the last run as a tombstone, preventing repeated reads
# of a finished run from reopening it. No worker metadata is changed.
# The named-session presentation lock serializes splits, close, and teardown.
# A record is owned by its task's session and worktree. A pane is closed only
# when its exact id, workspace and tab match the record, and it differs from
# both the recorded and current chat panes. A record from an earlier endpoint,
# such as after a relaunch, is closed and dropped before a new viewer opens.
# Unknown presence retains the record.
# _close_locked requires the caller to hold that same session lock.
#
# Splits and moves always use right, ratio 0.55, no focus. Each observation checks
# the right neighbour and repairs existing placement. An unrecorded attach can
# be adopted only with exact argv, cwd and tab proof; unknown siblings prevent
# splitting. A manually closed view stays closed until the next run.
# state/<id>.nm-review-miss tracks first observation and one alarm per missed run:
# after 30 seconds without a started view on the right, queue a check with the
# concrete failure. Intentional closure is exempt. Success clears the miss.
# A terminal run closes its pane; task teardown removes the tombstone too.
# Already absent panes close successfully. Failed commands retain retry state.
# Exit 0 after a reconciliation attempt; a failed or unsafe one warns on stderr
# and retains the record. Exit 2: usage error.
set -u

FM_NM_REVIEW_PANE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$FM_NM_REVIEW_PANE_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_NM_REVIEW_PANE_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$FM_NM_REVIEW_PANE_LIB_DIR/fm-nm-run-lib.sh"

fm_nm_review_pane_record_write() {  # <record> <pane> <run> <started>
  local record=$1 tmp
  tmp=$(mktemp "$record.XXXXXX") || return 1
  {
    printf 'session=%s\nworker=%s\nworktree=%s\nworkspace=%s\ntab=%s\n' \
      "$FM_NM_REVIEW_SESSION" "$FM_NM_REVIEW_WORKER" "$FM_NM_REVIEW_WORKTREE" \
      "$FM_NM_REVIEW_WORKSPACE" "$FM_NM_REVIEW_TAB"
    printf 'pane=%s\nrun=%s\nstarted=%s\n' "$2" "$3" "$4"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}

fm_nm_review_pane_identity() {  # <meta> <task-id>
  local meta=$1 id=$2
  [ "$(fm_meta_get "$meta" backend)" = herdr ] || return 1
  case "$(fm_meta_get "$meta" kind)" in ''|ship|scout) ;; *) return 1 ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 1
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  FM_NM_REVIEW_SESSION=$(fm_meta_get "$meta" herdr_session)
  FM_NM_REVIEW_WORKER=$(fm_meta_get "$meta" herdr_pane_id)
  FM_NM_REVIEW_WORKTREE=$(fm_meta_get "$meta" worktree)
  FM_NM_REVIEW_WORKSPACE=$(fm_meta_get "$meta" herdr_workspace_id)
  FM_NM_REVIEW_TAB=$(fm_meta_get "$meta" herdr_tab_id)
}

fm_nm_review_pane_record_owned() {  # <record>
  local record=$1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  [ "$(fm_meta_get "$record" session)" = "$FM_NM_REVIEW_SESSION" ] \
    && [ "$(fm_meta_get "$record" worktree)" = "$FM_NM_REVIEW_WORKTREE" ]
}

fm_nm_review_pane_record_current() {  # <record>
  [ "$(fm_meta_get "$1" worker)" = "$FM_NM_REVIEW_WORKER" ] \
    && [ "$(fm_meta_get "$1" workspace)" = "$FM_NM_REVIEW_WORKSPACE" ] \
    && [ "$(fm_meta_get "$1" tab)" = "$FM_NM_REVIEW_TAB" ]
}

# 0 present in the bound tab, 3 structurally absent, 1 ambiguous.
# Herdr reports pane_not_found as JSON on stderr, so both streams are read.
fm_nm_review_pane_presence() {  # <pane> [workspace] [tab]
  local pane=$1 ws=${2:-$FM_NM_REVIEW_WORKSPACE} tab=${3:-$FM_NM_REVIEW_TAB} info code
  info=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane get "$pane" 2>&1) || true
  code=$(printf '%s' "$info" | jq -r '.error.code // empty' 2>/dev/null)
  [ "$code" != pane_not_found ] || return 3
  printf '%s' "$info" | jq -e --arg pane "$pane" --arg ws "$ws" --arg tab "$tab" '
    .result.pane | .pane_id == $pane and .workspace_id == $ws and .tab_id == $tab
  ' >/dev/null 2>&1
}

# Port of the upstream locked close, retaining its confirmed-gone boundary.
fm_nm_review_pane_close_locked() {  # <state-dir> <task-id> [keep-run]
  local state=$1 id=$2 keep=${3:-0} record pane ws tab presence
  record="$state/$id.nm-review-pane"
  [ -e "$record" ] || return 0
  fm_nm_review_pane_identity "$state/$id.meta" "$id" || return 1
  fm_nm_review_pane_record_owned "$record" || return 1
  pane=$(fm_meta_get "$record" pane)
  ws=$(fm_meta_get "$record" workspace)
  tab=$(fm_meta_get "$record" tab)
  if [ -n "$pane" ]; then
    [ "$pane" != "$FM_NM_REVIEW_WORKER" ] && [ "$pane" != "$(fm_meta_get "$record" worker)" ] || return 1
    [ -n "$ws" ] && [ -n "$tab" ] || return 1
    presence=0
    fm_nm_review_pane_presence "$pane" "$ws" "$tab" || presence=$?
    case "$presence" in
      0)
        fm_backend_herdr_kill_serialized "$FM_NM_REVIEW_SESSION" "$pane" || true
        presence=0
        fm_nm_review_pane_presence "$pane" "$ws" "$tab" || presence=$?
        ;;
      3) ;;
      *) return 1 ;;
    esac
    if [ "$presence" != 3 ]; then
      echo "warning: no-mistakes pane for $id is not confirmed gone; retaining $record" >&2
      return 1
    fi
  fi
  if [ "$keep" = 1 ]; then
    fm_nm_review_pane_record_write "$record" "" "$(fm_meta_get "$record" run)" 1
  else
    rm -f "$record"
  fi
}

# A failed pane run can leave started=0 even if attach started.
# Retry only at a structurally proven shell, never by typing into a viewer.
fm_nm_review_pane_shell_ready() {  # <pane>
  fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane process-info --pane "$1" 2>/dev/null \
    | jq -e --arg pane "$1" '
      .result.process_info | .pane_id == $pane
      and (.shell_pid | type) == "number"
      and .shell_pid == .foreground_process_group_id
    ' >/dev/null 2>&1
}

fm_nm_review_pane_place() {  # <pane>
  local pane=$1 neighbor
  neighbor=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane neighbor \
    --pane "$FM_NM_REVIEW_WORKER" --direction right 2>/dev/null) || neighbor=
  if printf '%s' "$neighbor" | jq -e --arg pane "$pane" \
    '.result.neighbor.neighbor_pane_id == $pane' >/dev/null 2>&1; then return 0; fi
  FM_NM_REVIEW_REASON='could not move the view to the right'
  fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane move "$pane" \
    --tab "$FM_NM_REVIEW_TAB" --target-pane "$FM_NM_REVIEW_WORKER" --split right --ratio 0.55 --no-focus >/dev/null 2>&1 || return 1
  neighbor=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane neighbor \
    --pane "$FM_NM_REVIEW_WORKER" --direction right 2>/dev/null) || return 1
  printf '%s' "$neighbor" | jq -e --arg pane "$pane" \
    '.result.neighbor.neighbor_pane_id == $pane' >/dev/null 2>&1
}

# Print the single other pane and its exact attach run, or nothing for an empty
# tab. Never adopt a shell, command-text substring, foreign cwd or unknown pane.
fm_nm_review_pane_adoptable() {
  local listing siblings pane run
  listing=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane list \
    --workspace "$FM_NM_REVIEW_WORKSPACE" 2>/dev/null) || return 1
  printf '%s' "$listing" | jq -e '.result.panes | type == "array"' >/dev/null || return 1
  siblings=$(printf '%s' "$listing" | jq -r --arg tab "$FM_NM_REVIEW_TAB" --arg ws "$FM_NM_REVIEW_WORKSPACE" \
    --arg worker "$FM_NM_REVIEW_WORKER" \
    '.result.panes[] | select(.tab_id == $tab and .workspace_id == $ws and .pane_id != $worker) | .pane_id') || return 1
  [ -n "$siblings" ] || return 0
  [ "$(printf '%s\n' "$siblings" | wc -l | tr -d ' ')" = 1 ] || return 1
  pane=$siblings
  run=$(fm_nm_review_pane_attach_run "$pane") || return 1
  printf '%s %s\n' "$pane" "$run"
}

fm_nm_review_pane_attach_run() {  # <pane>
  local pane=$1 info
  info=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane process-info --pane "$pane" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -er --arg pane "$pane" --arg cwd "$FM_NM_REVIEW_WORKTREE" '
    .result.process_info | select(.pane_id == $pane) | .foreground_processes
    | select(length == 1) | .[0]
    | select(.cwd == $cwd and (.argv | length) == 4)
    | select((.argv[0] | split("/") | last) == "no-mistakes" and .argv[1:3] == ["attach", "--run"])
    | .argv[3] | select(test("^[A-Za-z0-9_-]+$"))'
}

# Public library entry point for branch-scoped display evidence. This never
# changes supervision's authoritative state verdict or authorizes cleanup.
fm_nm_review_pane_sync() {  # <meta> <state-dir> <task-id> <run-id> <active|terminal>
  local meta=$1 state=$2 id=$3 run=$4 phase=$5 lock rc=0
  fm_nm_review_pane_identity "$meta" "$id" || return 0
  [ -n "$run" ] || return 0
  fm_backend_source herdr || return 1
  lock=$(fm_backend_herdr_presentation_session_lock_path "$FM_NM_REVIEW_SESSION") || return 1
  FM_NM_REVIEW_REASON='presentation lock is busy'
  fm_lock_try_acquire "$lock" || return 1
  # Re-read after taking the same lock teardown holds, so a captured fleet
  # snapshot cannot recreate a task whose live metadata was already retired.
  if [ "$meta" != "$state/$id.meta" ] || ! fm_nm_review_pane_identity "$state/$id.meta" "$id"; then
    fm_lock_release "$lock" || true
    return 0
  fi
  fm_nm_review_pane_sync_locked "$state" "$id" "$run" "$phase" || rc=$?
  fm_lock_release "$lock" || true
  return "$rc"
}

fm_nm_review_pane_sync_locked() {  # <state-dir> <task-id> <run-id> <active|terminal>
  local state=$1 id=$2 run=$3 phase=$4 record pane prior started presence cmd adoption adopted_run
  FM_NM_REVIEW_REASON='pane identity or presence could not be verified'
  record="$state/$id.nm-review-pane"
  if [ -e "$record" ]; then
    fm_nm_review_pane_record_owned "$record" || return 1
    prior=$(fm_meta_get "$record" run)
    if [ "$phase" = terminal ]; then
      fm_nm_review_pane_close_locked "$state" "$id" 1
      return $?
    fi
    if [ "$prior" != "$run" ] || ! fm_nm_review_pane_record_current "$record"; then
      fm_nm_review_pane_close_locked "$state" "$id" || return 1
    fi
  fi
  [ "$phase" = active ] || return 0
  fm_nm_review_pane_presence "$FM_NM_REVIEW_WORKER" || return 1
  pane=$(fm_meta_get "$record" pane)
  started=$(fm_meta_get "$record" started)
  if [ -e "$record" ] && [ -z "$pane" ]; then return 0; fi
  if [ -n "$pane" ]; then
    [ "$pane" != "$FM_NM_REVIEW_WORKER" ] || return 1
    presence=0
    fm_nm_review_pane_presence "$pane" || presence=$?
    case "$presence" in
      0)
        fm_nm_review_pane_place "$pane" || return 1
        if [ "$started" = 1 ] && [ "$(fm_nm_review_pane_attach_run "$pane")" = "$run" ]; then return 0; fi
        FM_NM_REVIEW_REASON='the recorded view is not running its attach process'
        fm_nm_review_pane_shell_ready "$pane" || return 1
        ;;
      3) fm_nm_review_pane_record_write "$record" "" "$run" 1; return $? ;;
      *) return 1 ;;
    esac
  else
    FM_NM_REVIEW_REASON='tab contains an unknown pane or its inventory is unreadable'
    adoption=$(fm_nm_review_pane_adoptable) || return 1
    if [ -n "$adoption" ]; then
      read -r pane adopted_run <<< "$adoption"
      fm_nm_review_pane_record_write "$record" "$pane" "$adopted_run" 1 || return 1
      if [ "$adopted_run" = "$run" ]; then
        fm_nm_review_pane_place "$pane"
        return $?
      fi
      fm_nm_review_pane_close_locked "$state" "$id" || return 1
    fi
    FM_NM_REVIEW_REASON='could not split the view to the right'
    pane=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane split "$FM_NM_REVIEW_WORKER" \
      --direction right --ratio 0.55 --cwd "$FM_NM_REVIEW_WORKTREE" --no-focus 2>/dev/null \
      | jq -r '.result.pane.pane_id // empty' 2>/dev/null) || pane=
    [ -n "$pane" ] && [ "$pane" != "$FM_NM_REVIEW_WORKER" ] || return 1
    # Commit identity before starting attach, allowing a failed run to retry
    # in this same pane rather than creating another one.
    if ! fm_nm_review_pane_record_write "$record" "$pane" "$run" 0; then
      fm_backend_herdr_kill_serialized "$FM_NM_REVIEW_SESSION" "$pane" || true
      return 1
    fi
    fm_nm_review_pane_presence "$pane" || return 1
  fi
  FM_NM_REVIEW_REASON='could not start no-mistakes attach'
  fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane rename "$pane" no-mistakes >/dev/null 2>&1 || return 1
  printf -v cmd 'cd %q && no-mistakes attach --run %q' "$FM_NM_REVIEW_WORKTREE" "$run"
  fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane run "$pane" "$cmd" >/dev/null 2>&1 || return 1
  fm_nm_review_pane_place "$pane" || return 1
  fm_nm_review_pane_record_write "$record" "$pane" "$run" 1
}

fm_nm_review_pane_miss() {  # <state> <id> <run> <reason>
  local lock="$1/$2.nm-review-miss.lock" rc=0
  fm_lock_try_acquire "$lock" || return 0
  fm_nm_review_pane_miss_locked "$@" || rc=$?
  fm_lock_release "$lock" || true
  return "$rc"
}

fm_nm_review_pane_miss_locked() {  # <state> <id> <run> <reason>
  local state=$1 id=$2 run=$3 reason=$4 file now since alerted tmp
  file="$state/$id.nm-review-miss"
  now=$(date +%s)
  since=$now alerted=0
  if [ "$(fm_meta_get "$file" run)" = "$run" ]; then
    since=$(fm_meta_get "$file" since)
    alerted=$(fm_meta_get "$file" alerted)
  fi
  case "$since" in ''|*[!0-9]*) since=$now ;; esac
  if [ "$((now - since))" -ge 30 ] && [ "$alerted" != 1 ]; then
    fm_wake_append check "nm-review-pane:$id:$run" \
      "no-mistakes view missing for $id after 30 seconds (run $run): $reason" || return 1
    alerted=1
  fi
  tmp=$(mktemp "$file.XXXXXX") || return 1
  printf 'run=%s\nsince=%s\nalerted=%s\nreason=%s\n' "$run" "$since" "$alerted" "$reason" > "$tmp"
  mv -f "$tmp" "$file"
  printf 'warning: no-mistakes view for %s (%s): %s\n' "$id" "$run" "$reason" >&2
}

fm_nm_review_pane_main() {
  local id=${1:-} state meta branch out block run status phase=active rc=0
  case "$id" in
    -h|--help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'; return 0 ;;
    --sweep) fm_nm_review_pane_sweep; return $? ;;
    ''|*[!A-Za-z0-9._-]*) echo 'usage: fm-nm-review-pane.sh <task-id>' >&2; return 2 ;;
  esac
  [ "$#" = 1 ] || { echo 'usage: fm-nm-review-pane.sh <task-id>' >&2; return 2; }
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$FM_NM_REVIEW_PANE_LIB_DIR/.." && pwd)}}/state}
  meta="$state/$id.meta"
  fm_nm_review_pane_identity "$meta" "$id" || return 0
  branch=$(git -C "$FM_NM_REVIEW_WORKTREE" symbolic-ref --quiet --short HEAD) || return 0
  if ! out=$(fm_nm_run_checked "$FM_NM_REVIEW_WORKTREE" 3 axi status); then
    run=$(fm_meta_get "$state/$id.nm-review-miss" run)
    [ -z "$run" ] || fm_nm_review_pane_miss "$state" "$id" "$run" 'axi status is unreadable'
    return 0
  fi
  # Bound fields to the current run block, excluding other_branch_run, tables,
  # step statuses and help text. No run inventory or supervision verdict needed.
  block=$(printf '%s\n' "$out" | awk '
    /^[^[:space:]]/ { inside = ($0 == "run:" || $0 == "active_run:"); if (inside) count++; next }
    inside && /^  [^ ]/ { rows = rows $0 "\n" }
    END { if (count == 1) printf "%s", rows }')
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$block" branch)")" = "$branch" ] || return 0
  run=$(fm_nm_strip_quotes "$(fm_nm_field "$block" id)")
  case "$run" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$block" status)")
  case "$status" in
    completed|failed|cancelled|ci_monitor_interrupted|checks_passed) phase=terminal ;;
    pending|running|fixing|ci|feedback|awaiting_approval|fix_review) ;;
    *) fm_nm_review_pane_miss "$state" "$id" "$run" "unrecognized run status: $status"; return 0 ;;
  esac
  fm_nm_run_is_active "$block" || phase=terminal
  FM_NM_REVIEW_REASON='pane reconciliation could not complete'
  fm_nm_review_pane_sync "$meta" "$state" "$id" "$run" "$phase" || rc=$?
  if [ "$rc" = 0 ]; then
    rm -f "$state/$id.nm-review-miss"
  else
    fm_nm_review_pane_miss "$state" "$id" "$run" "$FM_NM_REVIEW_REASON"
  fi
}

fm_nm_review_pane_sweep() {
  local meta id state log
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  log="$state/.nm-review-pane.log"
  if [ -f "$log" ] && [ "$(wc -c < "$log")" -ge 1048576 ]; then mv -f "$log" "$log.1"; fi
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_meta_get "$meta" backend)" = herdr ] || continue
    id=$(basename "$meta" .meta)
    # Serialize mutations within a sweep; each bounded read precedes only this
    # task's view, never the potentially slow supervision/label reads.
    fm_nm_review_pane_main "$id" 2>>"$log" || true
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_nm_review_pane_main "$@"
fi
