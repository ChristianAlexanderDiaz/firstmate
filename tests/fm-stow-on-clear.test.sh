#!/usr/bin/env bash
# Behavior tests for bin/fm-stow-on-clear.sh: the Claude SessionEnd clear hook
# records a pending stow only for the lock-owning session of a genuine primary
# home, the session-start digest surfaces that record, and `done` consumes it.
#
# The hook is driven through its public `hook` entry with Claude-shaped JSON
# payloads; the surfacing case drives the REAL bin/fm-sessionstart-run.sh and
# bin/fm-session-start.sh against a throwaway home, so it proves the record
# reaches the digest a cleared session actually receives.
set -u

# Run beneath one long-lived fixture harness, as tests/fm-sessionstart-nudge.test.sh
# does, so session-lock ownership has a real harness ancestor on a harness-free
# CI runner and a developer's ambient harness cannot make it pass by accident.
if [ "${FM_STOW_ON_CLEAR_TEST_HARNESS:-0}" != 1 ]; then
  HARNESS_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fm-stow-on-clear-harness.XXXXXX") || exit 1
  ln -s /bin/bash "$HARNESS_FIXTURE/codex" || exit 1
  # shellcheck disable=SC2016 # Expand in the fixture shell, not this parent.
  FM_STOW_ON_CLEAR_TEST_HARNESS=1 "$HARNESS_FIXTURE/codex" \
    -c '"$@"; rc=$?; :; exit "$rc"' _ "$0" "$@"
  HARNESS_STATUS=$?
  rm -rf "$HARNESS_FIXTURE"
  exit "$HARNESS_STATUS"
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

TMP_ROOT=$(fm_test_tmproot fm-stow-on-clear)
HOOK="$ROOT/bin/fm-stow-on-clear.sh"
RUN="$ROOT/bin/fm-sessionstart-run.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
HARNESS_PID=$(fm_harness_ancestry_pid) || fail "the fixture harness is not visible in this test's ancestry"

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data" "$dir/config"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

own_lock() { printf '%s\n' "$HARNESS_PID" > "$1/state/.lock"; }

make_transcript() {  # <path>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
{"type":"user","message":{"role":"user","content":"remember that the deploy key rotates monthly"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Noted the monthly deploy key rotation."},{"type":"tool_use","name":"Bash","input":{"command":"ls state"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"bulky tool output"}]}}
EOF
}

payload() {  # <event> <reason> <session> <transcript>
  jq -cn --arg e "$1" --arg r "$2" --arg s "$3" --arg t "$4" \
    '{session_id: $s, transcript_path: $t, cwd: "/", hook_event_name: $e, reason: $r}'
}

run_hook() {  # <root> <payload> [env...]
  local root=$1 body=$2
  shift 2
  printf '%s' "$body" | env FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$@" "$HOOK" hook
}

expect_no_record() {  # <root> <label>
  if [ -d "$1/state/.pending-stow" ] && [ -n "$(ls -A "$1/state/.pending-stow" 2>/dev/null)" ]; then
    fail "$2 left a pending stow record: $(ls -A "$1/state/.pending-stow")"
  fi
}

test_primary_clear_records() {
  local root="$TMP_ROOT/primary" t="$TMP_ROOT/primary-t/s1.jsonl" out status=0 rec
  make_primary "$root"
  own_lock "$root"
  make_transcript "$t"
  out=$(run_hook "$root" "$(payload SessionEnd clear sess-1 "$t")" 2>&1) || status=$?
  expect_code 0 "$status" "primary clear hook"
  [ -z "$out" ] || fail "primary clear hook printed output: $out"
  rec="$root/state/.pending-stow/sess-1"
  assert_present "$rec" "a clear of the lock-owning primary session wrote no record"
  assert_contains "$(cat "$rec")" "transcript=$t" "the record does not name the cleared transcript"
  assert_contains "$(cat "$rec")" "session=sess-1" "the record does not name the cleared session"
  pass "hook: a clear of the lock-owning primary session records its transcript"
}

test_non_clear_reasons_ignored() {
  local root="$TMP_ROOT/reasons" t="$TMP_ROOT/reasons-t/s.jsonl" reason out status
  make_primary "$root"
  own_lock "$root"
  make_transcript "$t"
  for reason in logout prompt_input_exit resume other ''; do
    status=0
    out=$(run_hook "$root" "$(payload SessionEnd "$reason" "sess-$reason" "$t")" 2>&1) || status=$?
    expect_code 0 "$status" "reason '$reason' hook"
    [ -z "$out" ] || fail "reason '$reason' printed output: $out"
  done
  status=0
  out=$(run_hook "$root" "$(payload SessionStart clear sess-start "$t")" 2>&1) || status=$?
  expect_code 0 "$status" "SessionStart-shaped payload"
  expect_no_record "$root" "a non-clear session end or another event"
  # Non-vacuity: the same home and transcript do record on a real clear.
  run_hook "$root" "$(payload SessionEnd clear sess-real "$t")" >/dev/null 2>&1
  assert_present "$root/state/.pending-stow/sess-real" "the reasons fixture could not record a real clear, so its silence proves nothing"
  pass "hook: session ends other than clear, and other events, are ignored"
}

test_secondmate_home_is_silent() {
  local root="$TMP_ROOT/secondmate" t="$TMP_ROOT/secondmate-t/s.jsonl" out status=0
  make_primary "$root"
  own_lock "$root"
  printf 'sm1\n' > "$root/.fm-secondmate-home"
  make_transcript "$t"
  out=$(run_hook "$root" "$(payload SessionEnd clear sess-sm "$t")" 2>&1) || status=$?
  expect_code 0 "$status" "secondmate clear hook"
  [ -z "$out" ] || fail "secondmate clear hook printed output: $out"
  expect_no_record "$root" "a secondmate home clear"
  pass "hook: a secondmate home is a silent no-op"
}

test_worker_worktree_is_silent() {
  local root="$TMP_ROOT/worker-primary" wt="$TMP_ROOT/worker-wt" t="$TMP_ROOT/worker-t/s.jsonl" out status=0
  make_primary "$root"
  git -C "$root" worktree add -q --detach "$wt" >/dev/null 2>&1 || fail "could not create the fixture task worktree"
  mkdir -p "$wt/bin" "$wt/state"
  : > "$wt/AGENTS.md"
  own_lock "$wt"
  make_transcript "$t"
  out=$(run_hook "$wt" "$(payload SessionEnd clear sess-wt "$t")" 2>&1) || status=$?
  expect_code 0 "$status" "worker worktree clear hook"
  [ -z "$out" ] || fail "worker worktree clear hook printed output: $out"
  expect_no_record "$wt" "a task worktree clear"
  # A worker inherits FM_HOME naming the main home; the worktree root still decides.
  own_lock "$root"
  status=0
  out=$(printf '%s' "$(payload SessionEnd clear sess-wt2 "$t")" \
    | env FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$wt" FM_HOME="$root" "$HOOK" hook 2>&1) || status=$?
  expect_code 0 "$status" "worker worktree with inherited FM_HOME"
  expect_no_record "$root" "a task worktree clear with an inherited main-home FM_HOME"
  pass "hook: a task worktree is a silent no-op even with the main home's FM_HOME"
}

test_unowned_lock_is_silent() {
  local root="$TMP_ROOT/unowned" t="$TMP_ROOT/unowned-t/s.jsonl" out status=0
  make_primary "$root"
  make_transcript "$t"
  out=$(run_hook "$root" "$(payload SessionEnd clear sess-nolock "$t")" 2>&1) || status=$?
  expect_code 0 "$status" "no-lock clear hook"
  [ -z "$out" ] || fail "no-lock clear hook printed output: $out"
  expect_no_record "$root" "a clear by a session that holds no lock"
  printf '999999999\n' > "$root/state/.lock"
  run_hook "$root" "$(payload SessionEnd clear sess-foreign "$t")" >/dev/null 2>&1
  expect_no_record "$root" "a clear by a session that does not own the lock"
  pass "hook: a session that does not own the home lock records nothing"
}

test_foreign_host_and_gate_are_silent() {
  local root="$TMP_ROOT/foreign" t="$TMP_ROOT/foreign-t/s.jsonl" body out status=0
  make_primary "$root"
  own_lock "$root"
  make_transcript "$t"
  body=$(payload SessionEnd clear sess-cursor "$t" | jq -c '. + {cursor_version: "1.0"}')
  out=$(run_hook "$root" "$body" 2>&1) || status=$?
  expect_code 0 "$status" "cursor payload"
  expect_no_record "$root" "a Cursor-delivered payload"
  status=0
  out=$(run_hook "$root" "$(payload SessionEnd clear sess-gate "$t")" NO_MISTAKES_GATE=1 2>&1) || status=$?
  expect_code 0 "$status" "gate agent"
  [ -z "$out" ] || fail "gate agent printed output: $out"
  expect_no_record "$root" "a no-mistakes gate agent"
  status=0
  out=$(printf 'not json' | env FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$HOOK" hook 2>&1) || status=$?
  expect_code 0 "$status" "malformed payload"
  expect_no_record "$root" "a malformed payload"
  pass "hook: Cursor payloads, gate agents, and malformed payloads are silent no-ops"
}

test_pending_and_done() {
  local root="$TMP_ROOT/pending" t="$TMP_ROOT/pending-t/s.jsonl" gone="$TMP_ROOT/pending-t/gone.jsonl" out status=0
  make_primary "$root"
  out=$(FM_HOME="$root" "$HOOK" pending 2>&1) || status=$?
  expect_code 0 "$status" "pending with no records"
  [ -z "$out" ] || fail "pending printed output with no records: $out"

  own_lock "$root"
  make_transcript "$t"
  run_hook "$root" "$(payload SessionEnd clear sess-live "$t")" >/dev/null 2>&1
  run_hook "$root" "$(payload SessionEnd clear sess-gone "$gone")" >/dev/null 2>&1
  assert_present "$root/state/.pending-stow/sess-gone" "a clear whose transcript is not yet on disk must still record"

  out=$(FM_HOME="$root" "$HOOK" pending 2>&1)
  assert_contains "$out" "load the stow skill" "pending did not tell the session to run stow"
  assert_contains "$out" "session sess-live" "pending did not list the readable record"
  assert_contains "$out" "transcript: $t" "pending did not name the transcript"
  assert_contains "$out" "bin/fm-stow-on-clear.sh done sess-live" "pending did not give the clearing command"
  assert_contains "$out" "session sess-gone: transcript $gone is missing or unreadable" "pending did not report the stale record"
  assert_absent "$root/state/.pending-stow/sess-gone" "pending kept a record whose transcript is gone"
  assert_present "$root/state/.pending-stow/sess-live" "pending consumed a record nobody stowed"

  out=$(FM_HOME="$root" "$HOOK" 'done' sess-live 2>&1)
  assert_contains "$out" "Cleared the pending stow record for session sess-live" "done did not confirm the clear"
  assert_absent "$root/state/.pending-stow/sess-live" "done left the record"
  status=0
  out=$(FM_HOME="$root" "$HOOK" 'done' sess-live 2>&1) || status=$?
  expect_code 0 "$status" "repeated done"
  out=$(FM_HOME="$root" "$HOOK" pending 2>&1)
  [ -z "$out" ] || fail "pending printed output after every record was consumed: $out"
  status=0
  FM_HOME="$root" "$HOOK" 'done' '../escape' >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "done with a path-shaped id"
  pass "pending lists live records, drops stale ones, and done consumes a record"
}

# The digest a cleared session receives must carry the record its own clear
# just wrote, and stop carrying it once stow has consumed it.
test_session_start_surfaces_pending_stow() {
  local root="$TMP_ROOT/surface" t="$TMP_ROOT/surface-t/s.jsonl" out status=0
  local run_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  make_primary "$root"
  make_transcript "$t"
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$run_path" \
    "$RUN" --source startup </dev/null >/dev/null
  run_hook "$root" "$(payload SessionEnd clear sess-surface "$t")" >/dev/null 2>&1
  assert_present "$root/state/.pending-stow/sess-surface" "the startup fixture's lock owner could not record its clear"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$run_path" \
    "$RUN" --source clear </dev/null) || status=$?
  expect_code 0 "$status" "clear digest"
  assert_contains "$out" "PENDING STOW" "the clear digest did not surface the pending stow"
  assert_contains "$out" "session sess-surface" "the clear digest did not name the cleared session"
  assert_contains "$out" "NEXT STEP" "the clear digest was incomplete"

  FM_HOME="$root" "$HOOK" 'done' sess-surface >/dev/null
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$run_path" \
    "$RUN" --source clear </dev/null)
  assert_not_contains "$out" "PENDING STOW" "the digest still surfaced a consumed pending stow"
  pass "session start: a clear's digest surfaces the pending stow until stow consumes it"
}

# Both hooks must reject a stale identity even when the recorded pid is a real
# harness ancestor. Drive their public entries with the same legacy, genuine,
# and reboot-reused lock; only boot/start-time readings are stubbed on macOS.
test_hooks_check_lock_holder_identity() {
  local mode scenario source root fakebin real_ps out t
  local run_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  local -a envs
  real_ps=$(command -v ps)
  for mode in linux macos; do
    fakebin="$TMP_ROOT/identity-$mode-bin"
    mkdir -p "$fakebin"
    cat > "$fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
printf '{ sec = %s, usec = 0 }\n' "$(cat "$FM_FAKE_BOOT")"
SH
    chmod +x "$fakebin/sysctl"
    if [ "$mode" = macos ]; then
      cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" lstart= "*) printf '%s /fake/codex\\n' "\$(cat "\$FM_FAKE_LSTART")"; exit 0 ;;
esac
exec "$real_ps" "\$@"
SH
      chmod +x "$fakebin/ps"
    fi
    for scenario in genuine reused legacy; do
      for source in clear compact; do
        root="$TMP_ROOT/identity-$mode-$scenario-$source"
        make_primary "$root"
        own_lock "$root"
        printf '%s\n' "$HARNESS_PID" > "$root/state/.session-start-complete"
        mkdir -p "$root/proc"
        if [ "$mode" = linux ]; then
          mkdir -p "$root/proc/sys/kernel/random"
          printf 'boot-before\n' > "$root/proc/sys/kernel/random/boot_id"
        fi
        printf '1759500000\n' > "$root/boot"
        printf 'Sat Oct  3 10:00:00 2026\n' > "$root/lstart"
        envs=(PATH="$fakebin:$run_path" FM_PROC_ROOT_OVERRIDE="$root/proc"
          FM_FAKE_BOOT="$root/boot" FM_FAKE_LSTART="$root/lstart")
        # shellcheck disable=SC2016 # Expand in the identity-recording shell.
        env FM_HOME="$root" "${envs[@]}" bash -c '
          . "$1/bin/fm-wake-lib.sh"
          fm_lock_record_identity "$2/state/.lock-identity" "$3"
        ' _ "$ROOT" "$root" "$HARNESS_PID"
        grep -q '^identity=.' "$root/state/.lock-identity" \
          || fail "$mode: fixture did not record the live holder identity"
        if [ "$scenario" != genuine ]; then
          [ "$mode" != linux ] || printf 'boot-after\n' > "$root/proc/sys/kernel/random/boot_id"
          printf '1759509999\n' > "$root/boot"
          printf 'Sat Oct  3 12:47:00 2026\n' > "$root/lstart"
        fi
        [ "$scenario" != legacy ] || rm -f "$root/state/.lock-identity"
        t="$root/transcript.jsonl"
        make_transcript "$t"
        out=$(run_hook "$root" "$(payload SessionEnd clear sess-identity "$t")" "${envs[@]}" 2>&1)
        [ -z "$out" ] || fail "$mode/$scenario: clear hook printed output: $out"
        if [ "$scenario" = reused ]; then
          expect_no_record "$root" "$mode: a reused ancestor pid"
        else
          assert_present "$root/state/.pending-stow/sess-identity" \
            "$mode: clear hook rejected the $scenario holder"
        fi
        out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
          FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "${envs[@]}" \
          "$RUN" --source "$source" </dev/null)
        if [ "$scenario" = reused ]; then
          assert_contains "$out" "SESSION START - $root" \
            "$mode: $source trusted completion from a reused ancestor pid"
          assert_not_contains "$out" 'SESSION START (CONTEXT RE-EMIT)' \
            "$mode: $source re-emitted a stale owner's startup"
        else
          assert_contains "$out" "SESSION START (CONTEXT RE-EMIT) - $root" \
            "$mode: $source rejected the $scenario holder's completed startup"
        fi
      done
    done
  done
  pass "both hooks reject reboot-reused ancestor pids and honor genuine and legacy holders on Linux and macOS"
}

test_hooks_check_lock_holder_identity
test_primary_clear_records
test_non_clear_reasons_ignored
test_secondmate_home_is_silent
test_worker_worktree_is_silent
test_unowned_lock_is_silent
test_foreign_host_and_gate_are_silent
test_pending_and_done
test_session_start_surfaces_pending_stow
