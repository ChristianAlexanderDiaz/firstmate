#!/usr/bin/env bash
# Shared sidebar collector and display-only publisher.
# Usage: fm-sidebar-state.sh <task> [--refresh] | --sweep | --help
# A plain read and crew-state --sidebar have no side effects. --refresh also
# reports Herdr metadata, queues newly actionable Needs me notifications, and
# recovers a Checking -> non-captain gate transition once per run/gate/findings.
# --sweep rotates through one local Herdr task (including secondmates).
# The watcher owns one bounded child at a time, polling every five seconds.
# With N eligible tasks, the conservative refresh bound is N*(120+5+FM_POLL)
# seconds plus scheduler delay. Ordinary reads are much shorter. Existing
# exited-wait, dead-inbox and wedge alarms retain their own faster bounds;
# they own Stuck notifications, never a competing sidebar alarm.
#
# state/<task>.sidebar is display history only (endpoint, word, checking run).
# .sidebar-relaunched stores claimed gate fingerprints BEFORE control starts:
# a failed/timed-out relaunch is reported, never automatically repeated.
# Capability absence quietly omits metadata. Tokens fm_status/fm_status_detail belong to
# source firstmate-status and expire after 30 minutes if refresh stops.
# No agent status, task title, workspace lifecycle, or budget policy is changed.
# bash -c bodies deliberately expand positional arguments in the bounded child.
# shellcheck disable=SC2016
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
export FM_HOME FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-sidebar-lib.sh
. "$SCRIPT_DIR/fm-sidebar-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

sidebar_collect() {  # <task>
  id=$1 meta="$STATE/$1.meta"
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 1
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 1
  meta_signature=$(cksum "$meta") || return 1
  backend=$FM_BACKEND_VALIDATED_BACKEND
  window=$(fm_meta_get "$meta" window)
  kind=$(fm_meta_get "$meta" kind)
  session=$(fm_meta_get "$meta" herdr_session)
  workspace=$(fm_meta_get "$meta" herdr_workspace_id)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  generation=$(fm_busy_current_gen "$STATE" "$id" 2>/dev/null) || generation=unknown
  endpoint="$window $generation $(fm_meta_get "$meta" worktree)"
  record="$STATE/$id.sidebar"
  line=${FM_SIDEBAR_CURRENT_LINE:-}
  run_out=${FM_SIDEBAR_RUN_OUT:-}
  if [ -z "$line" ]; then
    evidence=$(fm_run_timed 20 "$FM_CREW_STATE_BIN" "$id" --sidebar-evidence 2>/dev/null) || return 1
    line=${evidence%%$'\n'*}
    if [ "$line" != "$evidence" ]; then run_out=${evidence#*$'\n'}; fi
  fi
  case "$line" in 'state: '*) ;; *) return 1 ;; esac
  agent=$(sidebar_agent_state) || agent=unreadable
  captain=unknown
  local rc=0 wait_line
  fm_run_timed 5 "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" --distinguish-absent >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) captain=yes ;; 1) captain=no ;; esac
  wait_line=$(status_declared_wait_line "$STATE/$id.status")
  if status_is_captain_held "$wait_line" || [ "$(status_declared_wait_owner "$wait_line")" = captain ]; then captain=yes; fi
  landed=no
  # This exact detail is minted only by crew-state's merged PR reader.
  case "$line" in 'state: done · source: run-step · run passed: PR merged'*) landed=yes ;; esac
  if fm_pr_poll_retirement_receipt_valid "$STATE" "$id" 2>/dev/null; then landed=yes; fi
  run=$(fm_nm_strip_quotes "$(fm_nm_field "$run_out" id)")
  case "$run" in *[!A-Za-z0-9_-]*) run= ;; esac
  prior=no
  if [ -n "$run" ] && [ "$(fm_meta_get "$record" endpoint)" = "$endpoint" ] \
    && [ "$(fm_meta_get "$record" checking)" = "$run" ]; then prior=yes; fi
  machine='' service='' stall='' ci_progress='' ci_queue='' ci_since=''
  key=$(fm_window_marker_key "$window")
  # The watcher owns the threshold and clears this count on renewed progress.
  local escalations=0
  [ ! -r "$STATE/.wedge-escalations-$key" ] || read -r escalations < "$STATE/.wedge-escalations-$key"
  case "$escalations" in ''|*[!0-9]*) escalations=0 ;; esac
  [ "$escalations" -le 0 ] || stall='no progress past watcher threshold'
  if [ "$backend" = herdr ]; then sidebar_machine_service; fi
  sidebar_ci_evidence
  fm_sidebar_classify "$line" "$agent" "$kind" "$captain" "$landed" "$machine" "$service" "$stall" "$prior"
  if [ "$FM_SIDEBAR_WORD" = Checking ] && [ -n "$ci_progress" ]; then
    FM_SIDEBAR_DETAIL="CI $ci_progress - no agent"
  fi
  if [ "$FM_SIDEBAR_WORD" = 'Needs you' ]; then
    local link
    link=$(fm_nm_strip_quotes "$(fm_nm_field "$run_out" pr)")
    [ -n "$link" ] || link=$(fm_meta_get "$meta" pr)
    [ -z "$link" ] || FM_SIDEBAR_DETAIL="$FM_SIDEBAR_DETAIL - $link"
  fi
  # Metadata is one short line. Never allow control bytes into the UI.
  FM_SIDEBAR_DETAIL=$(printf '%s' "$FM_SIDEBAR_DETAIL" | tr '\n\r\t' '   ' | cut -c1-300)
}

sidebar_agent_state() {
  fm_run_timed 10 bash -c '. "$1/fm-backend.sh"; fm_backend_agent_state "$2" "$3"' \
    bash "$SCRIPT_DIR" "$backend" "$window" 2>/dev/null
}

sidebar_machine_service() {
  local info shell facts budget='' category value
  info=$(fm_run_timed 3 bash -c '. "$1/backends/herdr.sh"; fm_backend_herdr_cli "$2" pane process-info --pane "$3"' \
    bash "$SCRIPT_DIR" "$session" "$pane" 2>/dev/null) || return 0
  shell=$(printf '%s' "$info" | jq -er --arg pane "$pane" '
    select(.result.type == "pane_process_info" and .result.process_info.pane_id == $pane)
    | .result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null) || return 0
  # The budget owner resolves both its configured and default locations. Status
  # never starts its service; unavailable evidence simply leaves no queue fact.
  budget=$(mktemp "${TMPDIR:-/tmp}/fm-sidebar-budget.XXXXXX") || return 0
  fm_run_timed 3 "$SCRIPT_DIR/fm-resource-run" status > "$budget" 2>/dev/null || printf '{}\n' > "$budget"
  facts=$(fm_run_timed 5 python3 "$SCRIPT_DIR/fm-sidebar-facts.py" "$shell" "$id" "$budget" 2>/dev/null) || facts=
  [ -z "$budget" ] || rm -f "$budget"
  while IFS=$'\t' read -r category value; do
    case "$category" in machine) machine=$value ;; service) service=$value ;; esac
  done <<< "$facts"
}

sidebar_ci_evidence() {
  case "$line" in 'state: working · source: run-step · '*) ;; *) return 0 ;; esac
  [ -n "$run" ] || return 0
  local wt log marker now elapsed
  wt=$(fm_meta_get "$meta" worktree)
  log=$(fm_nm_run_checked "$wt" 3 axi logs --step ci --run "$run" --full) || return 0
  # Optional progress text; absence never changes the canonical run verdict.
  marker=$(printf '%s\n' "$log" | grep -E 'CI checks|CI runner queued|waiting for a runner' | tail -1)
  ci_progress=$(printf '%s\n' "$marker" | sed -nE 's/.*CI[^0-9]*([0-9]+\/[0-9]+).*/\1/p')
  case "$marker" in
    *'CI runner queued'*|*'waiting for a runner'*)
      ci_queue=$run
      now=$(date +%s); ci_since=$now
      if [ "$(fm_meta_get "$record" endpoint)" = "$endpoint" ] \
        && [ "$(fm_meta_get "$record" ci_queue)" = "$ci_queue" ]; then
        ci_since=$(fm_meta_get "$record" ci_since)
      fi
      case "$ci_since" in ''|*[!0-9]*) ci_since=$now ;; esac
      [ "$ci_since" -le "$now" ] || ci_since=$now
      elapsed=$((now - ci_since))
      machine="CI runner ${elapsed}s since observed queued"
      ;;
  esac
}

sidebar_publish() {
  local panes
  [ "$backend" = herdr ] && [ -n "$FM_SIDEBAR_WORD" ] || return 0
  [ "$(fm_meta_get "$meta" presentation)" != closed ] || return 0
  fm_backend_source herdr || return 0
  # An old CLI rejects help; it must not receive a mutation it cannot support.
  fm_run_timed 3 bash -c '. "$1/backends/herdr.sh"; shift; fm_backend_herdr_cli "$@"' \
    bash "$SCRIPT_DIR" "$session" workspace report-metadata --help >/dev/null 2>&1 || return 0
  # A shared workspace cannot represent one task's status. Only publish its
  # label when the live inventory proves this task owns its sole pane.
  panes=$(fm_run_timed 3 bash -c '. "$1/backends/herdr.sh"; shift; fm_backend_herdr_cli "$@"' \
    bash "$SCRIPT_DIR" "$session" pane list 2>/dev/null) || panes='{}'
  if printf '%s' "$panes" | jq -e --arg workspace "$workspace" --arg pane "$pane" '
    [.result.panes[] | select(.workspace_id == $workspace)]
    | length == 1 and .[0].pane_id == $pane' >/dev/null 2>&1; then
    fm_run_timed 3 bash -c '. "$1/backends/herdr.sh"; shift; fm_backend_herdr_cli "$@"' \
      bash "$SCRIPT_DIR" "$session" workspace report-metadata --source firstmate-status "$workspace" \
      --token "fm_status=$FM_SIDEBAR_WORD" --token "fm_status_detail=$FM_SIDEBAR_DETAIL" --ttl-ms 1800000 >/dev/null 2>&1 || true
  fi
  fm_run_timed 3 bash -c '. "$1/backends/herdr.sh"; shift; fm_backend_herdr_cli "$@"' \
    bash "$SCRIPT_DIR" "$session" pane report-metadata --source firstmate-status "$pane" \
    --token "fm_status=$FM_SIDEBAR_WORD" --token "fm_status_detail=$FM_SIDEBAR_DETAIL" --ttl-ms 1800000 >/dev/null 2>&1 || true
}

sidebar_refresh() (
  local id=$1 lock="$STATE/.$1.sidebar.lock" snapshot gate mark note rc=0 checking=''
  fm_lock_try_acquire "$lock" || exit 0
  trap 'fm_lock_release "$lock"' EXIT
  sidebar_collect "$id" || exit 0
  [ "$backend" = herdr ] || exit 0
  sidebar_publish
  if [ "$FM_SIDEBAR_WORD" = 'Needs me' ] \
    && [ "$(fm_sidebar_wake_owner "$agent" "$stall")" = sidebar ]; then
    mark="$endpoint $line"
    if [ "$(fm_meta_get "$record" notified)" != "$mark" ]; then
      fm_wake_append check "sidebar-$id" "check: sidebar $id Needs me - $FM_SIDEBAR_DETAIL; reconcile the task" || exit 1
    fi
  else mark=; fi
  [ "$prior" != yes ] || checking=$run
  [ "$FM_SIDEBAR_WORD" != Checking ] || checking=$run
  # No previous Checking identity survives a changed run or endpoint.
  snapshot=$(mktemp "$record.XXXXXX") || exit 1
  printf 'endpoint=%s\nword=%s\nchecking=%s\nnotified=%s\nci_queue=%s\nci_since=%s\n' \
    "$endpoint" "$FM_SIDEBAR_WORD" "$checking" "$mark" "$ci_queue" "$ci_since" > "$snapshot"
  mv "$snapshot" "$record" || exit 1
  case "$line" in 'state: parked · source: run-step · '*) ;; *) exit 0 ;; esac
  [ "$prior" = yes ] && [ "$captain" = no ] && [ "$FM_SIDEBAR_WORD" = 'Needs me' ] || exit 0
  case "$kind" in ship|scout) ;; *) exit 0 ;; esac
  fm_sleep_active "$STATE" && exit 0
  case "$agent" in dead|missing) ;; *) exit 0 ;; esac
  # Gate identity excludes volatile step durations but includes findings rows.
  gate=$(printf '%s\n%s\n' "$run $line" "$run_out" | awk '
    NR == 1 {print; next}
    /^[[:space:]]*findings\[[0-9]+\]\{/ {n=$0; sub(/.*\[/,"",n); sub(/\].*/,"",n); print; next}
    n+0 > 0 {print; n--}' | cksum)
  grep -Fxq "$gate" "$STATE/$id.sidebar-relaunched" 2>/dev/null && exit 0
  # Recheck ownership immediately before claiming recovery. Unknown blocks it.
  fm_run_timed 5 "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" --distinguish-absent >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || exit 0
  local wait_line
  wait_line=$(status_declared_wait_line "$STATE/$id.status")
  if status_is_captain_held "$wait_line" || [ "$(status_declared_wait_owner "$wait_line")" = captain ]; then exit 0; fi
  # A slow run read must not restart a successor that appeared meanwhile.
  agent=$(sidebar_agent_state) || exit 0
  case "$agent" in dead|missing) ;; *) exit 0 ;; esac
  [ "$(cksum "$meta")" = "$meta_signature" ] || exit 0
  local current_generation
  current_generation=$(fm_busy_current_gen "$STATE" "$id" 2>/dev/null) || current_generation=unknown
  [ "$current_generation" = "$generation" ] || exit 0
  printf '%s\n' "$gate" >> "$STATE/$id.sidebar-relaunched" || exit 1
  snapshot="$DATA/$id/nm-$run-findings.txt"
  if [ ! -f "$snapshot" ]; then
    snapshot="$STATE/$id.sidebar-gate.txt"
    printf '%s\n' "$run_out" > "$snapshot" || exit 1
  fi
  note="The background validation reached $line with no agent. Read the gate and findings file $snapshot. Resume validation; escalate ask-user findings to firstmate and never answer them yourself."
  if ! fm_run_timed 30 "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note "$note"; then
    fm_wake_append check "sidebar-relaunch-$id" "check: sidebar $id gate recovery failed; inspect $snapshot and relaunch manually" || exit 1
  fi
)

sidebar_sweep() {
  local cursor='' candidate task pass
  [ ! -r "$STATE/.sidebar-cursor" ] || read -r cursor < "$STATE/.sidebar-cursor"
  for pass in after wrap; do
    for candidate in "$STATE"/*.meta; do
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
      task=${candidate##*/}; task=${task%.meta}
      if [ "$pass" = after ]; then [[ "$task" > "$cursor" ]] || continue
      else [[ "$task" > "$cursor" ]] && continue; fi
      [ "$(fm_meta_get "$candidate" backend)" = herdr ] || continue
      [ -z "$(fm_meta_get "$candidate" remote_host)" ] || continue
      # Advance before reading so one unresponsive task cannot starve the rest.
      printf '%s\n' "$task" > "$STATE/.sidebar-cursor"
      sidebar_refresh "$task"
      return
    done
  done
}

case "${1:-}" in
  --help) sed -n '2,20p' "$0"; exit 0 ;;
  --sweep) sidebar_sweep ;;
  ''|--*) echo 'usage: fm-sidebar-state.sh <task> [--refresh] | --sweep' >&2; exit 2 ;;
  *)
    case "${2:-}" in
      --refresh) sidebar_refresh "$1" ;;
      '') sidebar_collect "$1" && { [ -z "$FM_SIDEBAR_WORD" ] || printf '%s - %s\n' "$FM_SIDEBAR_WORD" "$FM_SIDEBAR_DETAIL"; } ;;
      *) exit 2 ;;
    esac
    ;;
esac
