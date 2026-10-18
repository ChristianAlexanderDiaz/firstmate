#!/usr/bin/env bash
# Sleep overlay behavior through its command, wake, and inbox interfaces.
# Transport is faked; every home and process belongs to this temporary fixture.
set -eu
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-sleep)
mkdir -p "$TMP_ROOT"
SLEEP="$ROOT/bin/fm-sleep.sh"

home=$(make_case sleep)
mkdir -p "$home/data" "$home/config"
export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state"
export PATH="$home/fakebin:$PATH"
"$SLEEP" on > "$home/entry"
assert_grep 'sleep: on' "$home/entry" 'sleep entry must report its hold'
first=$(cat "$home/state/.sleep")
"$SLEEP" on >/dev/null
[ "$(cat "$home/state/.sleep")" = "$first" ] || fail 'repeat entry changed the durable epoch'
"$SLEEP" status > "$home/status"
assert_grep 'sleep: on' "$home/status" 'status must observe sleep'
append_wake "$home/state" check sleep-test 'check: sleep-test: needs a decision'
if "$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2>&1; then fail 'sleep allowed drain'; fi
assert_grep 'needs a decision' "$home/state/.wake-queue" 'held queue was lost'
if "$ROOT/bin/fm-spawn.sh" ignored ignored ignored > "$home/spawn" 2>&1; then fail 'sleep allowed spawn'; fi
assert_grep 'spawn refused - sleep is active' "$home/spawn" 'spawn must refuse before setup'

# A recorded steering message is retained but no terminal key is sent.
FM_SEND_LOG="$home/sends" bash -c '
  . "$1/bin/fm-task-inbox-lib.sh"
  rec=$(fm_task_inbox_write "$STATE" worker "continue later")
  fm_task_inbox_ring tmux fake:fm-worker "$rec" && exit 9
  [ -f "$rec" ]
' _ "$ROOT" || fail 'sleep did not hold a durable steering message'
[ ! -s "$home/sends" ] || fail 'sleep rang a steering doorbell'

# The away daemon must not inject even a decision escalation during sleep.
bash -c '
  . "$1/bin/fm-supervise-daemon.sh"
  inject_msg "decision pending" "$2" && exit 9
  [ "$INJECT_LAST_FAILURE" = "deferred: sleep active" ]
' _ "$ROOT" "$home/state" || fail 'away escalation bypassed sleep'

# An external gnhf process is intentionally outside the recorded endpoint set.
bash -c 'exec -a gnhf sleep 60' &
gnhf_pid=$!
"$SLEEP" on >/dev/null
kill -0 "$gnhf_pid" || fail 'sleep touched standalone gnhf'
kill "$gnhf_pid"
wait "$gnhf_pid" 2>/dev/null || true

# Operational text cannot wake the fleet. An ordinary message presents the
# normal queue once, leaves acknowledgement to its supervisor, and releases it.
printf 'queued wake' | "$ROOT/bin/fm-operational-input.sh" encode watcher | "$SLEEP" input
[ -f "$home/state/.sleep" ] || fail 'operational input woke the fleet'
printf 'I am back\n' | "$SLEEP" input > "$home/return" 2> "$home/return.err"
assert_grep 'needs a decision' "$home/return" 'return did not present the held queue'
assert_grep 'WAKE_ACK_REQUIRED' "$home/return.err" 'return lost the normal acknowledgement receipt'
[ ! -e "$home/state/.sleep" ] && [ ! -e "$home/state/.sleep-return" ] || fail 'return did not release sleep'
"$SLEEP" off > "$home/repeat"
[ ! -s "$home/repeat" ] || fail 'repeat off presented the queue twice'
assert_grep 'needs a decision' "$home/state/.wake-queue" 'presentation acknowledged unhandled work'
pass 'sleep: durable on/off, ordinary-message return, held drain and steering, spawn refusal, and standalone gnhf exemption'

# Entry can race with a daemon already inspecting the supervisor composer.
bash -c '
  . "$1/bin/fm-supervise-daemon.sh"
  afk_active() { return 0; }
  fm_backend_target_exists() { return 0; }
  pane_is_busy() { return 1; }
  fm_backend_composer_state() { : > "$STATE/.sleep"; printf empty; }
  fm_daemon_primary_harness() { printf claude; }
  fm_backend_send_text_submit() { printf sent >> "$STATE/unwanted-submit"; }
  inject_msg "decision pending" "$STATE" && exit 9
  [ "$INJECT_LAST_FAILURE" = "deferred: sleep active" ] && [ "$INJECT_SUBMIT_ATTEMPTED" = 0 ]
' _ "$ROOT" || fail 'sleep entry during composer inspection allowed escalation delivery'
[ ! -e "$home/state/unwanted-submit" ] || fail 'a delayed escalation bypassed sleep'
rm "$home/state/.sleep"
pass 'sleep: an escalation already checking its composer is held before terminal submission'

# A live watcher parks without completing, even when a new status is appended.
"$SLEEP" on >/dev/null
FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=99999 FM_HEARTBEAT=99999 \
  "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
watch_pid=$!
for _ in $(seq 1 100); do [ ! -e "$home/state/.last-watcher-beat" ] || break; sleep 0.1; done
printf 'needs-decision: held test event\n' > "$home/state/worker.status"
sleep 2
kill -0 "$watch_pid" || fail "sleep watcher completed: $(cat "$home/watch.out" "$home/watch.err")"
[ ! -s "$home/watch.out" ] || fail 'sleep watcher emitted a wake'
kill "$watch_pid"
wait "$watch_pid" 2>/dev/null || true
"$SLEEP" off > "$home/return2" 2>/dev/null
assert_grep 'held test event' "$home/return2" 'return lost a status appended during sleep'
pass 'sleep: live watcher holds a status without waking the model and return presents it'

# Exercise the existing remote channel contract with a fake transport. The
# command itself and local recursion are real; the fake route runs the same
# command in a separate home, as fm-on does on its selected host.
code="$TMP_ROOT/code"
mkdir -p "$code"
cp -R "$ROOT/bin" "$code/bin"
cat > "$code/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_REMOTE_CALLS"
[ "${FM_TEST_REMOTE_FAIL:-0}" = 0 ] || exit 255
shift
command=$1; shift
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK STATE
export FM_HOME=$FM_TEST_REMOTE_HOME
exec "$(dirname "$0")/$command" "$@"
SH
chmod +x "$code/bin/fm-on.sh"
parent="$TMP_ROOT/parent"
child="$TMP_ROOT/child"
remote="$TMP_ROOT/remote"
mkdir -p "$parent/state" "$parent/data" "$child/state" "$remote/state"
printf '%s\n' \
  "- child - Local test (home: $child; scope: tests; projects: none; added 2026-10-01)" \
  "- remote - Remote test (host: fake-host; root: $code; home: $remote; scope: tests; projects: none; added 2026-10-01)" \
  > "$parent/data/secondmates.md"
export FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" FM_ROOT_OVERRIDE="$code"
export FM_TEST_REMOTE_HOME="$remote" FM_TEST_REMOTE_CALLS="$parent/calls"
FM_TEST_REMOTE_FAIL=1 "$code/bin/fm-sleep.sh" on > "$parent/failure" 2>&1 && fail 'unconfirmed propagation reported success'
[ -f "$parent/state/.sleep" ] && [ -f "$child/state/.sleep" ] || fail 'partial entry removed local holds'
assert_grep 'remote secondmate remote did not confirm on' "$parent/state/.sleep-errors" 'partial entry must name the failed route'
"$code/bin/fm-sleep.sh" on >/dev/null
[ -f "$remote/state/.sleep" ] || fail 'remote entry was not propagated'
append_wake "$remote/state" check remote-test 'check: remote-test: queued remotely'
"$code/bin/fm-sleep.sh" off > "$parent/return" 2>/dev/null
for state in "$parent/state" "$child/state" "$remote/state"; do
  [ ! -e "$state/.sleep" ] || fail "sleep off did not propagate to $state"
done
assert_grep 'queued remotely' "$parent/return" 'remote queue presentation was lost'
assert_grep 'remote fm-sleep.sh on --depth 1' "$parent/calls" 'remote on bypassed fm-on'
assert_grep 'remote fm-sleep.sh off --depth 1' "$parent/calls" 'remote off bypassed fm-on'
pass 'sleep: local and remote propagation, partial failure retains holds, and remote queue return'
