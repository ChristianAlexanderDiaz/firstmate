#!/usr/bin/env bash
# Fleet sleep overlay; reuse the ordinary queue and lifecycle control plane.
#
# Usage: FM_HOME=<home> bin/fm-sleep.sh on|off|status
#        FM_HOME=<home> bin/fm-sleep.sh input  # ordinary message on stdin
# Internal propagation: on|off --depth <0..32> (fm-on preserves these argv).
# Internal watcher sweep: sweep (re-interrupt only recorded busy endpoints).
#
# on atomically publishes state/.sleep before any interrupt or propagation.
# Repeating on retries propagation and interruption without replacing entry time.
# Every registered secondmate receives the same on/off operation: local homes run
# this executable with isolated home paths; remote homes use fm-on.sh. Entry
# failures retain the local hold and return nonzero with named errors, never a
# success claim.
# Every recorded live endpoint is interrupted through fm-control.sh, including
# local secondmates and a remote home's own state/parent-route endpoint. No
# process-name sweep, teardown, exit, worktree operation, or session deletion runs.
# The initiating primary completes its sleep entry turn and parks; a parent's
# control plane interrupts each secondmate primary after its home is held.
# Interrupt acknowledgements and unsupported backend refusals remain exactly
# those of fm-control.sh; .sleep-errors retains failures for status and retry.
# Standalone gnhf runs explicitly started outside Firstmate's task endpoints are
# untouched: they have no state/<id>.meta here. A task name containing gnhf is
# never an exemption. This command neither starts nor discovers gnhf processes.
#
# off wakes descendants before releasing this home. A descendant that does not
# confirm stays held: off names it with its release command, records it in
# .sleep-held, still releases this home, and returns nonzero. A later off
# retries only those recorded descendants, even after this home is awake.
# .sleep-return holds delivery while the normal drain
# presents this home's queue; only a successful presentation removes that flag.
# A repeated off with no flag prints nothing. Presentation does not acknowledge
# work: the supervisor handles and acknowledges the drain's normal receipts.
# Descendant returns print a read-only queue/status summary without claiming,
# presenting, or acknowledging their rows; each home drains its own queue.
# Only while a parked watcher is alive does it repeat interrupt for busy task
# endpoints once per poll cycle; it never interrupts a secondmate primary.
# Codex-primary homes park no watcher, and a Claude Stop-hook watcher ends at
# its hook timeout (about 8 hours), so no sweep runs there or past that point.
# Native self-wakes may run until the next sweep; idle endpoints are untouched.
# .sleep-sweep-errors retains the latest sweep failures without injecting a wake.
# In-flight no-mistakes runs are not paused and continue until their next gate.
# Interrupted workers can be resumed through normal steering after return.
# Away/quiet records are preserved. The /sleep return skill handles any away
# return after the sleep queue, so a genuine return also clears away posture.
# input ignores operational injections and /sleep itself; an ordinary message
# invokes off. The /sleep skill owns this return path on every primary harness.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in -h|--help) sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;; esac
: "${FM_HOME:?FM_HOME must name the home to put to sleep}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

residual_notice() {
  printf 'sleep: in-flight no-mistakes runs are not paused; they continue until their next gate\n'
  printf 'sleep: busy workers are re-interrupted only while a parked watcher runs: never in Codex-primary homes, and not past the Claude Stop-hook watcher lifetime (about 8 hours)\n'
}

operation=${1:-status}
shift "$(( $# > 0 ? 1 : 0 ))"
depth=0
if [ "${1:-}" = --depth ] && [ "$#" = 2 ]; then depth=$2; shift 2; fi
case "$depth" in ''|*[!0-9]*) exit 2 ;; esac
[ "$depth" -le 32 ] && [ "$#" = 0 ] || { echo 'sleep: invalid arguments or registry cycle' >&2; exit 2; }
case "$operation" in
  status)
    if fm_sleep_active; then
      printf 'sleep: on (%s)\n' "$FM_HOME"
      [ ! -f "$STATE/.sleep-errors" ] || cat "$STATE/.sleep-errors"
      [ ! -f "$STATE/.sleep-sweep-errors" ] || cat "$STATE/.sleep-sweep-errors"
      residual_notice
    else
      printf 'sleep: off (%s)\n' "$FM_HOME"
      [ ! -s "$STATE/.sleep-held" ] || sed 's/^/sleep: secondmate still held: /' "$STATE/.sleep-held"
    fi
    exit 0 ;;
  input)
    fm_sleep_active || exit 0
    message=$(cat)
    [ -n "$message" ] || exit 0
    case "$message" in /sleep|/sleep\ *) exit 0 ;; esac
    kind=
    if fm_operational_input_classify "$message" kind || fm_operational_doorbell_kind "$message" "$STATE" kind; then exit 0; fi
    operation=off ;;
  on|off|sweep) ;;
  *) echo 'usage: fm-sleep.sh on|off|status|input' >&2; exit 2 ;;
esac
fm_refuse_if_gate_agent
fm_lock_acquire_wait_max "$STATE/.sleep.lock" 30 || { echo 'sleep: another posture change is running' >&2; exit 1; }
trap 'fm_lock_release "$STATE/.sleep.lock"' EXIT
held_file="$STATE/.sleep-held"
retry_held=0
if [ "$operation" != on ] && ! fm_sleep_active; then
  [ "$operation" = off ] && [ -s "$held_file" ] || exit 0
  retry_held=1
fi
if [ "$operation" = on ] && [ ! -e "$STATE/.sleep" ]; then
  pending=$(mktemp "$STATE/.sleep.pending.XXXXXX")
  printf 'schema=fm-sleep.v1\nentered=%s\n' "$(date +%s)" > "$pending"
  mv "$pending" "$STATE/.sleep"
fi
error_file="$STATE/.sleep-errors"
[ "$operation" != sweep ] || error_file="$STATE/.sleep-sweep-errors"
: > "$error_file"
failed=0
failure() { printf 'sleep: %s\n' "$*" | tee -a "$error_file" >&2; failed=1; }
held=
descendant_failed() {  # <message> [held-id]
  [ "$operation" = off ] || { failure "$1"; return; }
  printf 'sleep: %s\n' "$1" | tee -a "$error_file" >&2
  [ -n "${2:-}" ] || return 0
  held="$held$2"$'\n'
  printf 'sleep: secondmate %s is still held; release it later with: FM_HOME=%s %s off\n' \
    "$2" "$FM_HOME" "$SCRIPT_DIR/fm-sleep.sh" | tee -a "$error_file" >&2
}

# Do not let parent state/config/queue overrides leak into a descendant home.
child_sleep() (
  unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK STATE
  exec env FM_HOME="$1" "$SCRIPT_DIR/fm-sleep.sh" "$operation" --depth "$((depth + 1))"
)
registry="${FM_DATA_OVERRIDE:-$FM_HOME/data}/secondmates.md"
if [ "$operation" != sweep ] && [ -f "$registry" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    if ! secondmate_registry_parse_line "$line"; then descendant_failed 'malformed secondmate registry entry'; continue; fi
    [ "$retry_held" = 0 ] || grep -qxF "$SECONDMATE_REGISTRY_ID" "$held_file" || continue
    [ "$operation" != off ] || printf 'Secondmate %s (read-only summary; handled in its own home):\n' "$SECONDMATE_REGISTRY_ID"
    if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
      "$SCRIPT_DIR/fm-on.sh" "$SECONDMATE_REGISTRY_ID" fm-sleep.sh "$operation" --depth "$((depth + 1))" \
        || descendant_failed "remote secondmate $SECONDMATE_REGISTRY_ID did not confirm $operation" "$SECONDMATE_REGISTRY_ID"
    elif [ -d "$SECONDMATE_REGISTRY_HOME" ] && [ "$SECONDMATE_REGISTRY_HOME" != "$FM_HOME" ]; then
      child_sleep "$SECONDMATE_REGISTRY_HOME" \
        || descendant_failed "secondmate $SECONDMATE_REGISTRY_ID did not confirm $operation" "$SECONDMATE_REGISTRY_ID"
    else descendant_failed "secondmate $SECONDMATE_REGISTRY_ID has an unavailable or cyclic home" "$SECONDMATE_REGISTRY_ID"; fi
  done < "$registry"
fi

if [ "$operation" = on ] || [ "$operation" = sweep ]; then
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh"
  # Each home owns only its direct reports. The remote parent-route is local
  # to this host and uses the same control API with that exact state directory.
  for endpoint_state in "$STATE" "$STATE/parent-route"; do
    for meta in "$endpoint_state"/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}; id=${id%.meta}
      [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
      [ "$operation" != sweep ] || [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
      if ! fm_backend_validate_task_endpoint "$meta" "$id"; then failure "invalid endpoint for $id"; continue; fi
      case "$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null || true)" in
        dead) continue ;;
      esac
      if [ "$operation" = sweep ]; then
        verdict=$(fm_busy_classify_meta "$meta" "$id" "$endpoint_state")
        [ "${verdict%% *}" = busy ] || continue
      fi
      if FM_STATE_OVERRIDE="$endpoint_state" "$SCRIPT_DIR/fm-control.sh" "$id" interrupt; then
        printf '%s\n' "$id" >> "$STATE/.sleep-workers"
      else failure "interrupt failed for $id; the hold remains active"; fi
    done
  done
  [ "$failed" = 0 ] || exit 1
  [ "$operation" != sweep ] || exit 0
  printf 'sleep: on; launches and delivery held in %s\n' "$FM_HOME"
  residual_notice
else
  if [ -n "$held" ]; then printf '%s' "$held" > "$held_file"; else rm -f "$held_file"; fi
  if [ "$retry_held" = 1 ]; then rm -f "$error_file"; [ -z "$held" ] || exit 1; exit 0; fi
  [ ! -e "$STATE/.sleep" ] || mv "$STATE/.sleep" "$STATE/.sleep-return"
  printf 'Sleep return: %s\n' "$FM_HOME"
  if [ "$depth" -gt 0 ]; then
    # Do not run the drain here: even an unacknowledged drain advances status
    # presentation cursors and claims rows. The descendant watcher owns those.
    fm_lock_acquire_wait_max "$FM_WAKE_QUEUE_LOCK" 30 || exit 1
    summary_rc=0
    if [ -f "$FM_WAKE_QUEUE" ]; then fm_wake_print_deduped "$FM_WAKE_QUEUE" || summary_rc=$?; fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    [ "$summary_rc" = 0 ] || exit "$summary_rc"
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    for status_file in "$STATE"/*.status; do
      [ -f "$status_file" ] || continue
      offset=$(fm_wake_status_cursor_offset "$status_file") || continue
      if fm_wake_unread_events "$status_file" 0 "$offset"; then
        printf '%s (read-only unread status):\n%s\n' "${status_file##*/}" "$FM_WAKE_UNREAD_LINES"
      fi
    done
  elif ! FM_SLEEP_PRESENT=1 "$SCRIPT_DIR/fm-wake-drain.sh"; then
    failure 'wake presentation failed; rerun off to finish the return'
    exit 1
  fi
  if [ -s "$STATE/.sleep-workers" ]; then
    printf 'Interrupted workers (resume through normal steering):\n'
    sort -u "$STATE/.sleep-workers"
  fi
  rm -f "$STATE/.sleep-return" "$STATE/.sleep-errors" "$STATE/.sleep-workers" "$STATE/.sleep-sweep-errors"
  [ -z "$held" ] || exit 1
fi
