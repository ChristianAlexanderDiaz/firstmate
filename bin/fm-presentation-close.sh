#!/usr/bin/env bash
# Close only the presentation of exited, waiting, home-local Herdr workers.
# Usage: fm-presentation-close.sh [<task-id> | --heartbeat | --help]
#
# The heartbeat visits at most 20 candidates and starts no further candidate
# after 30 seconds, rotating its cursor so refusals cannot starve later tasks.
# Locks are control -> spawn -> meta -> named-session presentation, all try-only.
# Exact metadata ownership, one tab/pane, its task label, a waiting declaration
# (or authoritative parked/done run), and shell-only processes are required.
# A live agent, secondmate, foreign pane, or ambiguous read always refuses.
# The existing focus-preserving exact-pane close removes the single-pane space.
# No task data, branch, worktree, PR, inbox, status or backlog is removed.
#
# Metadata contract: presentation=closed and presentation_closed_at=<epoch>
# retain window= and all Herdr IDs as the last endpoint identity. Consumers must
# not treat this marker as permission to launch: fm-control relaunch still
# proves absence or a recycled address and fm-spawn --relaunch creates the
# replacement in the same worktree, clearing both fields on publication. Recovery callers
# use that control path with its required progress note, never clear the marker
# themselves. A changed wait remains visible through ordinary status/run reads.
# A staged metadata copy plus original checksum survives interruption between
# close and publication; it can finalize only against the unchanged original
# and positively absent workspace. Refusals are recorded in the task's
# .presentation-close.log, deduplicated by reason; repeated closure is a no-op.
set -eu
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
case "${1:-}" in --help|-h) ;; *) fm_refuse_if_gate_agent ;; esac
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
fm_backend_source herdr

reason() {
  local message=$1 log="$STATE/$id.presentation-close.log" prior
  prior=$(tail -1 "$log" 2>/dev/null || true)
  [ "${prior#* }" = "$message" ] || printf '%s %s\n' "$(date +%s)" "$message" >> "$log"
}

waiting() {
  local current line verb
  current=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_DATA_OVERRIDE="$DATA" FM_CREW_STATE_NO_FORGE=1 \
    "$SCRIPT_DIR/fm-crew-state.sh" "$id") || return 1
  case "$current" in
    'state: working '*) return 1 ;;
    'state: parked '*|'state: paused '*|'state: done '*) return 0 ;;
    *'source: run-step'*) return 1 ;;
  esac
  line=$(status_current_line "$STATE/$id.status" "$(fm_meta_get "$meta" kind)")
  status_is_paused_or_captain_held "$line" && return 0
  verb=$(status_line_verb "$line")
  [ "$verb" != needs-decision ] || return 0
  # A completed but unpublished branch is deliberately retained too.
  if [ "$verb" = 'done' ] && { [ -n "$(fm_meta_get "$meta" pr)" ] || [ -n "$(fm_meta_get "$meta" branch)" ]; }; then
    return 0
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1
}

topology() {
  local snapshot cwd wt
  cwd=$(fm_backend_herdr_current_path "$session:$pane") || return 1
  [ -d "$cwd" ] || return 1
  cwd=$(cd "$cwd" && pwd -P) || return 1
  wt=$(fm_meta_get "$meta" worktree)
  [ -d "$wt" ] || return 1
  wt=$(cd "$wt" && pwd -P) || return 1
  case "$cwd" in "$wt"|"$wt"/*) ;; *) return 1 ;; esac
  snapshot=$(fm_backend_herdr_cli "$session" api snapshot) || return 1
  printf '%s' "$snapshot" | jq -e --arg ws "$workspace" --arg tab "$tab" \
    --arg pane "$pane" --arg label "fm-$id" '
    .result.snapshot as $s
    | [$s.workspaces[]? | select(.workspace_id == $ws)] as $w
    | [$s.tabs[]? | select(.workspace_id == $ws)] as $t
    | [$s.panes[]? | select(.workspace_id == $ws)] as $p
    | ($w | length) == 1 and $w[0].tab_count == 1 and $w[0].pane_count == 1
      and ($t | length) == 1 and $t[0].tab_id == $tab and $t[0].label == $label
      and ($p | length) == 1 and $p[0].pane_id == $pane and $p[0].tab_id == $tab
  ' >/dev/null
}

close_one() (
  id=$1
  case "$id" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || exit 0
  [ "$(fm_meta_get "$meta" backend)" = herdr ] || exit 0
  [ "$(fm_meta_get "$meta" presentation)" != closed ] || exit 0
  case "$(fm_meta_get "$meta" kind)" in ship|scout) ;; *) exit 0 ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || exit 0
  locks=()
  cleanup() {
    local n
    for ((n=${#locks[@]}-1; n>=0; n--)); do fm_lock_release "${locks[n]}" || true; done
  }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  for lock in "$STATE/.control-$id.lock" "$STATE/.spawn-$id.lock" "$(fm_meta_lock_path "$meta")"; do
    fm_lock_try_acquire "$lock" || { reason 'lifecycle lock busy'; exit 0; }
    locks+=("$lock")
  done
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null || { reason 'invalid endpoint ownership'; exit 0; }
  [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] || exit 0
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || exit 0
  case "$(fm_meta_get "$meta" kind)" in ship|scout) ;; *) exit 0 ;; esac
  [ "$(fm_meta_get "$meta" presentation)" != closed ] || exit 0
  session=$(fm_meta_get "$meta" herdr_session)
  workspace=$(fm_meta_get "$meta" herdr_workspace_id)
  tab=$(fm_meta_get "$meta" herdr_tab_id)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  lock=$(fm_backend_herdr_presentation_session_lock_path "$session") || { reason 'session lock unavailable'; exit 0; }
  fm_lock_try_acquire "$lock" || { reason 'presentation lock busy'; exit 0; }
  locks+=("$lock")
  pending="$STATE/$id.presentation-close.pending"
  checksum="$STATE/$id.presentation-close.checksum"
  if [ -f "$pending" ] && [ ! -L "$pending" ] && [ -f "$checksum" ] && [ ! -L "$checksum" ]; then
    if [ "$(cksum < "$meta")" = "$(cat "$checksum")" ] \
      && [ "$(fm_meta_get "$pending" presentation)" = closed ] \
      && [ "$(fm_meta_get "$pending" window)" = "$session:$pane" ] \
      && [ "$(fm_backend_herdr_workspace_presence_state "$session" "$workspace")" = dead ]; then
      mv "$pending" "$meta" || { reason 'closed workspace; metadata publication failed'; exit 1; }
      rm -f "$checksum"
      reason 'closed'
      exit 0
    fi
  fi
  waiting || { reason 'task is not waiting'; exit 0; }
  topology || { reason 'workspace ownership or single-pane topology not proven'; exit 0; }
  agent=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
  case "$agent" in no-agent|stale-agent) ;; *) reason 'agent exit not proven'; exit 0 ;; esac
  fm_backend_herdr_pane_shell_tree "$session" "$pane" || { reason 'pane has live or unreadable processes'; exit 0; }
  # Recheck the topology and process proof immediately before the exact close.
  if ! topology || ! fm_backend_herdr_pane_shell_tree "$session" "$pane"; then
    reason 'pre-close revalidation failed'
    exit 0
  fi
  [ ! -L "$pending" ] && [ ! -L "$checksum" ] || { reason 'unsafe pending record'; exit 0; }
  cksum < "$meta" > "$checksum" || { reason 'cannot stage original checksum'; exit 1; }
  stage=$(mktemp "$STATE/.$id.presentation-close.XXXXXX") || { reason 'cannot stage closed metadata'; exit 1; }
  if ! {
    awk -F= '$1 != "presentation" && $1 != "presentation_closed_at"' "$meta"
    printf 'presentation=closed\npresentation_closed_at=%s\n' "$(date +%s)"
  } > "$stage"; then
    rm -f "$stage"
    reason 'cannot stage closed metadata'
    exit 1
  fi
  mv "$stage" "$pending" || { rm -f "$stage"; reason 'cannot publish staged metadata'; exit 1; }
  close_rc=0
  fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$pane" "$agent" || close_rc=$?
  if [ "$(fm_backend_herdr_workspace_presence_state "$session" "$workspace")" = dead ]; then
    mv "$pending" "$meta" || { reason 'closed workspace; metadata publication failed'; exit 1; }
    rm -f "$checksum"
    reason "closed (focus-close result $close_rc)"
    printf 'presentation closed: %s\n' "$id"
  else
    reason "close unconfirmed (result $close_rc); task retained"
  fi
)

case "${1:---heartbeat}" in
  --help|-h) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  --heartbeat)
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
    cursor=$(cat "$STATE/.presentation-close-cursor" 2>/dev/null || true)
    start=$(date +%s); count=0
    # Two lexical passes wrap once, without a growing candidate queue.
    for pass in after before; do
      for candidate in "$STATE"/*.meta; do
        [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
        id=${candidate##*/}; id=${id%.meta}
        if [[ "$id" > "$cursor" ]]; then [ "$pass" = after ] || continue
        else [ "$pass" = before ] || continue; fi
        [ "$(fm_meta_get "$candidate" backend)" = herdr ] || continue
        [ "$(fm_meta_get "$candidate" presentation)" != closed ] || continue
        close_one "$id" || true
        printf '%s\n' "$id" > "$STATE/.presentation-close-cursor"
        count=$((count + 1))
        if [ "$count" -ge 20 ] || [ "$(( $(date +%s) - start ))" -ge 30 ]; then exit 0; fi
      done
    done
    ;;
  *) close_one "$1" ;;
esac
