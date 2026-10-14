#!/usr/bin/env bash
# Quota-paced refill notification source. No ticket or model is selected here.
# Usage: fm-procevent-refill.sh arm [--root-only]
#        fm-procevent-refill.sh poll|check|notify|retire|source-id
#        fm-procevent-refill.sh classify|terminal <result-file>
#
# arm registers root-home source quota-refill through fm-procevent.sh; root
# bootstrap arms it when config/quota-plan exists. Local secondmates only notify
# that source. Removal of the declaration makes the next sample silent.
# poll is runner-only: sample every 600s, or within 5s of a PR handoff/cleanup
# notification. notify atomically replaces a cheap root-state trigger token.
# check takes one sample (0 = refill output, 75 = no change/no ready work/closed
# gate/unreadable evidence, 73 = admission lock busy; poll retries it within 5s
# without consuming the pending trigger or interval). Unsupported quota-axi cannot
# start work or emit a refill. A successful later read resumes without a re-arm.
#
# Candidates use fm-fleet-snapshot.sh --contribution-input for each local home,
# excluding held, blocked, already-dispatched and non-worker rows. Active lanes
# are ordered as declared, then backlog order, with at most five ids per lane.
# Occupancy uses fm-project-capacity-lib.sh. An uncapped lane reports places
# equal to its ready count, never an invented machine capacity. Capacity shared
# by same-origin clones is counted once. Each id is qualified by its home.
#
# A refill result includes eligible providers and the Claude fallback verdict
# for Codex validation. This is visibility only, not validation-policy control.
# A change in places, eligible providers/day/reset, candidates, or a new open
# episode emits once. Deduplication reads the last durable capture, not a
# pre-capture acknowledgement; a crash before capture can retry the same event.
# Closed/no-ready observations are persisted as a new episode boundary. Results
# remain unhandled until firstmate acknowledges them through fm-procevent.sh.
# relisten keeps the generic runner alive; terminal always returns nonterminal.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-plan-lib.sh
. "$SCRIPT_DIR/fm-quota-plan-lib.sh"

usage() { sed -n '2,/^set -u/{ /^#/s/^# \{0,1\}//p; }' "$0"; }
case "${1:-}" in
  --help|-h|help) usage; exit 0 ;;
  source-id) echo quota-refill; exit 0 ;;
  relisten) exit 0 ;;
  terminal|silent|self-announcing|autohandle|answers) exit 1 ;;
  classify)
    if grep -q '^refill: ' "${2:?result file required}"; then echo refill; else echo unknown; fi
    exit 0 ;;
esac
ROOT_HOME=$(fm_firstmate_root_home "$FM_HOME") || exit 1
if [ "${1:-}" = arm ] && [ "${2:-}" = --root-only ] &&
  [ "$ROOT_HOME" != "$(cd "$FM_HOME" && pwd -P)" ]; then exit 0; fi
CONFIG=$(fm_project_capacity_config_dir "$FM_HOME" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}") || exit 1
# The source and its cache belong to the root, not to the notifying child.
STATE="$ROOT_HOME/state"
export FM_HOME="$ROOT_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG"
export FM_DATA_OVERRIDE="$ROOT_HOME/data" FM_PROJECTS_OVERRIDE="$ROOT_HOME/projects"

notify() {
  local token
  [ -e "$CONFIG/quota-plan" ] || [ -L "$CONFIG/quota-plan" ] || return 0
  mkdir -p "$STATE" || return 1
  token=$(umask 077; mktemp "$STATE/.quota-refill-trigger.XXXXXX") || return 1
  printf '%s\n' "$token" > "$token"
  mv -f "$token" "$STATE/quota-refill-trigger"
}

# Observe queued work with the existing canonical parser, never a second parser.
ready_rows() {
  local state home snapshot all='[]' rows
  fm_local_firstmate_state_dirs "$STATE" || return 1
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    home=${state%/state}
    snapshot=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
      fm_run_timed 30 "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input) || return 1
    rows=$(printf '%s\n' "$snapshot" | jq -ce --arg home "$home" '
      [.tasks[].id] as $live | [.backlog.records[] |
        select(.structured and .state == "queued" and (.kind == "ship" or .kind == "scout") and
          .hold_reason == null and .hold_kind == null and
          (.unresolved_blocker_ids|length) == 0) |
        select(.id as $id | $live | index($id) | not) |
        {id,repo,home:$home}]') || return 1
    all=$(jq -cn --argjson a "$all" --argjson b "$rows" '$a+$b') || return 1
  done
  printf '%s\n' "$all"
}

refill_closed() {
  local file="$STATE/quota-refill-observation.json" tmp
  [ -f "$file" ] || return 0
  tmp=$(umask 077; mktemp "$STATE/.quota-refill-observation.XXXXXX") || return 1
  if jq -e 'if .open == 1 then .episode += 1 | .open = 0 else . end' "$file" > "$tmp"; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

refill_sample() {
  local now today provider gates='{}' open=0 fallback=unreadable ready lane ids count project lock places total=0 lanes='[]' seen='|'
  local observation episode=0 was_open=0 fingerprint previous='' file seq latest=0 tmp
  fm_quota_plan_load "$CONFIG" || { refill_closed; return 75; }
  [ -n "$FM_QUOTA_PLAN_JSON" ] || { refill_closed; return 75; }
  now=$(date +%s)
  today=$(date -u +%Y-%m-%d)
  fm_lock_try_acquire "$STATE/.quota-plan-admission.lock" || return 73
  FM_QUOTA_PLAN_LOCK_HELD="$STATE/.quota-plan-admission.lock"
  if ! fm_quota_plan_snapshot "$STATE" "$now"; then
    fm_quota_plan_release
    refill_closed
    return 75
  fi
  for provider in claude codex; do
    if fm_quota_plan_verdict "$provider" "$now"; then
      open=1
      gates=$(printf '%s\n' "$gates" | jq -c --arg p "$provider" --argjson v "$FM_QUOTA_PLAN_VERDICT" \
        '.[$p] = ($v | {day,reset,open})') || { fm_quota_plan_release; return 75; }
      [ "$provider" != claude ] || fallback=open
    elif [ "$provider" = claude ] && [ -n "$FM_QUOTA_PLAN_VERDICT" ]; then
      fallback=closed
    fi
  done
  fm_quota_plan_release
  if [ "$open" = 1 ]; then
    ready=$(ready_rows) || return 75
    while IFS= read -r lane; do
      [ -n "$lane" ] || continue
      ids=$(printf '%s\n' "$ready" | jq -c --arg p "$lane" '[.[] | select(.repo == $p)]') || return 75
      count=$(printf '%s\n' "$ids" | jq length)
      [ "$count" -gt 0 ] || continue
      # Any local clone of the lane suffices for same-origin occupancy.
      project=
      while IFS= read -r file; do
        if [ -d "$file/projects/$lane" ]; then project="$file/projects/$lane"; break; fi
      done < <(printf '%s\n' "$ids" | jq -r '.[].home')
      [ -n "$project" ] || continue
      lock=$(fm_treehouse_project_lock_path "$project") || return 75
      case "$seen" in *"|$lock|"*) continue ;; esac
      seen="$seen$lock|"
      fm_project_capacity_lookup "$CONFIG" "$lane" || return 75
      places=$count
      if [ -n "$FM_PROJECT_CAPACITY" ]; then
        fm_project_capacity_occupants "$lock" "$project" "$STATE" '' || return 75
        places=$((FM_PROJECT_CAPACITY - FM_PROJECT_CAPACITY_OCCUPANTS))
      fi
      [ "$places" -gt 0 ] || continue
      total=$((total + places))
      lanes=$(printf '%s\n' "$lanes" | jq -c --arg p "$lane" --argjson n "$places" --argjson ids "$ids" \
        '. + [{lane:$p,places:$n,ready:($ids[:5])}]') || return 75
    done < <(printf '%s\n' "$FM_QUOTA_PLAN_JSON" | jq -r --arg today "$today" \
      '.lanes[] | select(.until == null or .until >= $today) | .project')
  fi
  observation="$STATE/quota-refill-observation.json"
  if [ -f "$observation" ]; then
    episode=$(jq -er '.episode | select(type=="number" and . >= 0 and floor == .)' "$observation") || return 75
    was_open=$(jq -er '.open | select(. == 0 or . == 1)' "$observation") || return 75
  fi
  open=0
  [ "$total" -le 0 ] || open=1
  if [ "$open" != "$was_open" ]; then
    episode=$((episode + 1))
    tmp=$(umask 077; mktemp "$STATE/.quota-refill-observation.XXXXXX") || return 75
    jq -cn --argjson e "$episode" --argjson o "$open" '{episode:$e,open:$o}' > "$tmp" && \
      mv -f "$tmp" "$observation" || return 75
  fi
  [ "$open" = 1 ] || return 75
  fingerprint=$(jq -cn --argjson e "$episode" --argjson gates "$gates" --argjson lanes "$lanes" \
    --arg fallback "$fallback" '{episode:$e,gates:$gates,lanes:$lanes,fallback:$fallback}') || return 75
  # Only a durable capture suppresses a repeat. Generic capture owns numbering.
  for file in "$STATE/procevent-inbox/quota-refill."*.result; do
    [ -f "$file" ] || continue
    seq=${file%.result}; seq=${seq##*.}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    if [ "$seq" -gt "$latest" ]; then latest=$seq; previous=$file; fi
  done
  if [ -n "$previous" ] && [ "$(sed -n 's/^fingerprint: //p' "$previous")" = "$fingerprint" ]; then return 75; fi
  printf 'refill: %s places open; next ready: %s\n' "$total" \
    "$(printf '%s\n' "$lanes" | jq -r 'map(.lane + ": " + (.ready | map(.id + "@" + .home) | join(", "))) | join("; ")')"
  printf 'providers: %s; Codex-to-Claude validation fallback: %s\n' \
    "$(printf '%s\n' "$gates" | jq -r 'keys|join(", ")')" "$fallback"
  printf 'fingerprint: %s\n' "$fingerprint"
}

trap 'fm_quota_plan_release || true' EXIT
case "${1:-}" in
  arm)
    fm_quota_plan_load "$CONFIG" || { echo "$FM_QUOTA_PLAN_ERROR" >&2; exit 1; }
    [ -n "$FM_QUOTA_PLAN_JSON" ] || exit 0
    "$SCRIPT_DIR/fm-procevent.sh" register refill quota-refill -- "$SCRIPT_DIR/fm-procevent-refill.sh" poll ;;
  notify) notify ;;
  retire) "$SCRIPT_DIR/fm-procevent.sh" retire quota-refill ;;
  check) refill_sample ;;
  poll)
    next=0; prior_trigger=''
    while :; do
      now=$(date +%s)
      trigger=$(cat "$STATE/quota-refill-trigger" 2>/dev/null || true)
      if [ "$now" -ge "$next" ] || [ "$trigger" != "$prior_trigger" ]; then
        rc=0; refill_sample || rc=$?
        [ "$rc" != 0 ] || exit 0
        [ "$rc" = 73 ] || { prior_trigger=$trigger; next=$((now + 600)); }
      fi
      sleep 5
    done ;;
  *) usage; exit 2 ;;
esac
