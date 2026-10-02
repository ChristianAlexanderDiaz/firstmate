#!/usr/bin/env bash
# Behavior tests for Claude account failover (bin/fm-account-failover.sh,
# config/claude-failover, fm-control.sh/fm-spawn.sh --claude-account).
#
# Hermetic: a lifecycle-modelling tmux stub stands in for the terminal (its
# viewport shows Claude's real usage-limit prompt until Escape closes it, its
# exit command stops the agent, and a launch starts a fresh one), and fakes
# stand in for `claude auth status`, `quota-axi --all-accounts --json`, and
# `no-mistakes`. tests/fm-account-failover-live-e2e.test.sh proves the prompt,
# the hook payload, and Escape's outcome against the real Claude Code.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

FAILOVER="$ROOT/bin/fm-account-failover.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-failover)
TASK_TMPS=()
failover_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap 'failover_cleanup; fm_test_cleanup' EXIT

# The prompt Claude Code 2.1.287 renders at a weekly limit, as captured live
# (docs/verification/runtime-backends.md).
LIMIT_SCREEN='❯ Reply with the single word hi.
  ⎿  You'"'"'ve hit your weekly limit · resets Oct 3 at 4pm (America/New_York)
   What do you want to do?
   ❯ 1. Stop and wait for limit to reset
     2. Wait here, then continue automatically at Oct 3 at 4pm
     3. Switch to usage credits
     4. Upgrade your plan
   Enter to confirm · Esc to cancel'
LIMIT_TEXT="You've hit your weekly limit · resets Oct 3 at 4pm (America/New_York)"

make_fakes() {  # <case-dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      printf 'text:%s\n' "$payload" >> "$D/events"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) printf 'claude' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      printf 'key:%s\n' "$payload" >> "$D/events"
      [ "$payload" != Escape ] || rm -f "$D/screen"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -f "$D/screen" ]; then
      cat "$D/screen"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # claude auth status: signed in when the selected root holds a stored login.
  cat > "$fb/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]
  exit
fi
exit 0
SH
  cat > "$fb/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/fake/quota-calls'
cat '$dir/fake/quota.json'
SH
  # no-mistakes: one run on the task branch whose state lives in fake/nm-state
  # (absent means no run); abort records its call and, unless told to stick,
  # turns the run cancelled.
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
D='$dir/fake'
printf '%s\n' "\$*" >> "\$D/nm-calls"
branch=\$(git symbolic-ref --quiet --short HEAD)
case "\$*" in
  'axi')
    if [ -f "\$D/nm-state" ]; then
      printf 'current_branch: %s\nruns_on_current_branch: 1\ncount: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "RUN1",%s,%s,abc1234,""\n' "\$branch" "\$branch" "\$(cat "\$D/nm-state")"
    else
      printf 'current_branch: %s\nruns_on_current_branch: 0\ncount: 0 of 0 total\nruns[0]{id,branch,status,head,pr}:\n' "\$branch"
    fi
    ;;
  'axi status --run RUN1')
    state=\$(cat "\$D/nm-state")
    printf 'id: "RUN1"\nbranch: %s\nstatus: %s\n' "\$branch" "\$state"
    [ "\$state" != cancelled ] || printf 'outcome: cancelled\n'
    ;;
  'axi abort --run RUN1')
    [ -f "\$D/nm-abort-sticks" ] || printf 'cancelled' > "\$D/nm-state"
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux" "$fb/sleep" "$fb/claude" "$fb/quota-axi" "$fb/no-mistakes"
}

# new_case <name> <id> [kind]: a home with one live canonical claude task whose
# worker runs under the ordinary account, and two signed-in failover accounts.
new_case() {
  local id=$2 kind=${3:-ship} dir="$TMP_ROOT/$1"
  CASE=$dir
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/home/config" "$dir/fake" "$dir/user-home/.claude" \
    "$dir/accounts/spare"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_fakes "$dir"
  printf '{}\n' > "$dir/user-home/.claude/.credentials.json"
  printf '{}\n' > "$dir/accounts/spare/.credentials.json"
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  printf '# Task\n## Captain'"'"'s intent\nKeep working.\n\n## Firstmate spec\nKeep the task whole.\n' > "$dir/home/data/$id/brief.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$dir/wt" "project=$dir/proj" \
    harness=claude "kind=$kind" mode=no-mistakes yolo=off "tasktmp=/tmp/fm-$id" \
    model=claude-fable-5-1 effort=default busy_gen=g1
  TASK_TMPS+=("/tmp/fm-$id")
  printf 'account limited ordinary\naccount spare %s\n' "$dir/accounts/spare" > "$dir/home/config/claude-failover"
  printf '%s' "$LIMIT_SCREEN" > "$dir/fake/screen"
  quota_snapshot 0 81 > "$dir/fake/quota.json"
}

# quota_snapshot <limited-percent> <spare-percent> [spare-extra-jq]: an
# --all-accounts snapshot shaped like quota-axi 0.1.55's schema 7 output.
quota_snapshot() {
  jq -n --argjson limited "$1" --argjson spare "$2" '
    def row($name; $pct; $resets):
      { provider: "claude", account: $name, state: { status: "fresh", stale: false },
        windows: [
          { id: "five_hour", kind: "session", resetsAt: "2026-10-02T05:19:59.617813+00:00", percentRemaining: 100 },
          { id: "seven_day", kind: "weekly", resetsAt: $resets, percentRemaining: $pct },
          { id: "model:fable", kind: "model", resetsAt: $resets, percentRemaining: 90 } ],
        quotaSemantics: { status: "known", effectiveAvailability: [
          { scope: "all_models", status: "known", effectivePercentRemaining: $pct,
            boundedBy: ["five_hour", "seven_day"], limitingWindowIds: ["seven_day"],
            runway: { status: (if $pct == 0 then "exhausted_now" else "through_reset" end), limitingWindowId: "seven_day" },
            selection: { status: "known", spendPriority: 0.4 } },
          { scope: "model:fable", status: "known", effectivePercentRemaining: $pct,
            boundedBy: ["five_hour", "seven_day", "model:fable"], limitingWindowIds: ["seven_day"],
            runway: { status: (if $pct == 0 then "exhausted_now" else "through_reset" end), limitingWindowId: "seven_day" },
            selection: { status: "known", spendPriority: 0.7 } } ] } };
    { schemaVersion: 7, providers: [
        row("limited"; $limited; "2026-10-03T19:59:59.620307+00:00"),
        row("spare"; $spare; "2026-10-06T22:59:59.617929+00:00") ] }' | jq "${3:-.}"
}

case_env() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u CLAUDE_CONFIG_DIR -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u FM_ROOT_OVERRIDE \
    PATH="$CASE/fakebin:$PATH" FM_HOME="$CASE/home" FM_FAKE_DIR="$CASE/fake" HOME="$CASE/user-home" \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_ACCOUNT_FAILOVER_MENU_WAIT=0.5 "$@"
}

# record_limit <id> [error] [message]: what the worker's StopFailure hook does,
# from inside a worker running under the ordinary account.
record_limit() {
  local id=$1 error=${2:-rate_limit} message=${3:-$LIMIT_TEXT}
  jq -nc --arg e "$error" --arg m "$message" '{hook_event_name: "StopFailure", error: $e, last_assistant_message: $m}' |
    case_env "$FAILOVER" record "$CASE/home/config" "$CASE/home/state" "$id" g1
}

# Keys and literals the terminal received, in order, as one transcript.
status_of() { cat "$CASE/home/state/$1.status" 2>/dev/null; }

# --- record ------------------------------------------------------------------

test_record_writes_a_usage_limit_record_only_for_a_rate_limit_with_the_map() {
  local marker
  new_case record-map t1
  record_limit t1 server_error "Internal server error"
  [ ! -e "$CASE/home/state/t1.usage-limit" ] || fail "a non-rate-limit turn end must not be recorded"
  record_limit t1
  marker=$(cat "$CASE/home/state/t1.usage-limit" 2>/dev/null) || fail "a rate-limit turn end should be recorded"
  assert_contains "$marker" "gen=g1" "the record must name the hook's busy generation"
  assert_contains "$marker" "config_dir_set=0" "the record must say the worker ran with CLAUDE_CONFIG_DIR unset"
  assert_contains "$marker" "message=$LIMIT_TEXT" "the record must carry Claude's limit text"
  jq -nc '{error: "rate_limit", last_assistant_message: "limit"}' |
    case_env CLAUDE_CONFIG_DIR="$CASE/accounts/spare" "$FAILOVER" record "$CASE/home/config" "$CASE/home/state" t1 g1
  assert_contains "$(cat "$CASE/home/state/t1.usage-limit")" "config_dir=$CASE/accounts/spare" \
    "the record must name the config root the worker actually ran under"
  pass "record: only a rate-limit StopFailure writes the usage-limit record, naming the worker's real account root"
}

test_absent_map_is_a_no_op() {
  local out
  new_case no-map t2
  rm -f "$CASE/home/config/claude-failover"
  record_limit t2
  [ ! -e "$CASE/home/state/t2.usage-limit" ] || fail "without config/claude-failover the hook must write nothing"
  printf 'v1\ngen=g1\nmessage=%s\n' "$LIMIT_TEXT" > "$CASE/home/state/t2.usage-limit"
  out=$(case_env "$FAILOVER" tick 2>&1) || fail "tick must succeed without the map"
  [ -z "$out" ] || fail "tick without the map must do nothing, got: $out"
  [ -e "$CASE/home/state/t2.usage-limit" ] || fail "tick without the map must not touch any record"
  [ ! -s "$CASE/fake/keys" ] && [ ! -s "$CASE/fake/literal" ] || fail "tick without the map must not touch the terminal"
  [ ! -e "$CASE/fake/quota-calls" ] || fail "tick without the map must not read quota"
  pass "absent config/claude-failover: the hook records nothing and the watcher tick does nothing"
}

# --- choose ------------------------------------------------------------------

choose() {  # <snapshot-json> [choose args...]
  local snap="$CASE/snap.json"
  printf '%s\n' "$1" > "$snap"
  shift
  "$FAILOVER" choose --map "$CASE/home/config/claude-failover" --snapshot "$snap" "$@"
}

test_choose_picks_by_quota_and_respects_the_floor() {
  local out rc
  new_case choose c1
  out=$(choose "$(quota_snapshot 0 81)" --current limited --model claude-fable-5-1); rc=$?
  expect_code 0 "$rc" "an account with room should be picked: $out"
  assert_equals "pick	spare	81" "$out" "the spare account has room"
  out=$(choose "$(quota_snapshot 90 81)" --current limited); rc=$?
  assert_equals "pick	spare	81" "$out" "the current account never qualifies, even when its reading shows room"
  out=$(choose "$(quota_snapshot 0 5)" --current limited); rc=$?
  expect_code 1 "$rc" "an account at the default 5% floor must not be picked"
  assert_contains "$out" "spare: 5% left, at or below the 5% floor, resets 2026-10-06T22:59Z" "the refusal names the floor and the reset time"
  assert_contains "$out" "limited: 0% left, the account the worker just ran out on, resets 2026-10-03T19:59Z" "the refusal names the current account's reset"
  out=$(choose "$(quota_snapshot 0 6)" --current limited); rc=$?
  assert_equals "pick	spare	6" "$out" "an account just above the floor qualifies"
  printf 'floor 20\n' >> "$CASE/home/config/claude-failover"
  out=$(choose "$(quota_snapshot 0 15)" --current limited); rc=$?
  expect_code 1 "$rc" "a configured floor must be respected"
  assert_contains "$out" "at or below the 20% floor" "the configured floor is the one named"
  pass "choose: picks the account with room, never the current one, and never at or below the floor"
}

test_choose_refuses_unknown_quota_and_paid_usage() {
  local out rc
  new_case choose-unknown c2
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].quotaSemantics.effectiveAvailability[0] |= {scope, status: "unknown"}')" --current limited); rc=$?
  expect_code 1 "$rc" "unknown quota must not qualify"
  assert_contains "$out" "spare: its quota is unknown" "unknown quota is named"
  out=$(choose "$(quota_snapshot 0 81 'del(.providers[1])')" --current limited); rc=$?
  expect_code 1 "$rc" "an account with no reading must not qualify"
  assert_contains "$out" "spare: no quota reading for this account" "a missing reading is named"
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].state.stale = true')" --current limited); rc=$?
  expect_code 1 "$rc" "a stale reading must not qualify"
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].windows += [{id: "extra_usage", kind: "credits", percentRemaining: 26}] | .providers[1].quotaSemantics.effectiveAvailability[0].boundedBy += ["extra_usage"]')" --current limited); rc=$?
  expect_code 1 "$rc" "availability that counts paid credits must not qualify"
  assert_contains "$out" "counts paid usage credits" "paid usage is named"
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].windows += [{id: "extra_usage", kind: "credits", percentRemaining: 26}]')" --current limited); rc=$?
  expect_code 0 "$rc" "an account whose plan windows have room qualifies even with extra usage switched on"
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].quotaSemantics.effectiveAvailability[1].effectivePercentRemaining = 2')" --current limited --model claude-fable-5-1); rc=$?
  expect_code 1 "$rc" "a fable worker must respect the fable model scope"
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].quotaSemantics.effectiveAvailability[1].effectivePercentRemaining = 2')" --current limited --model claude-opus-5-5); rc=$?
  expect_code 0 "$rc" "an opus worker is not bound by the fable scope"
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].quotaSemantics.effectiveAvailability[1].effectivePercentRemaining = 2')" --current limited); rc=$?
  expect_code 1 "$rc" "an unknown model is bound by every model scope"
  pass "choose: unknown, missing, stale, and credit-backed quota never qualifies, and model scopes apply"
}

# --- run ---------------------------------------------------------------------

test_limit_prompt_is_answered_with_stop_and_the_worker_moves_to_an_account_with_room() {
  local out
  new_case move t3
  record_limit t3
  out=$(case_env "$FAILOVER" tick 2>&1)
  assert_contains "$out" "moved t3 limited spare" "the failover should report the move: $out"
  # The prompt gets exactly one key, its cancel, and nothing reaches the
  # terminal until the old worker's exit command: no option number, arrow, or
  # Enter can land on a paid choice.
  assert_equals "key:Escape"$'\n'"text:/exit" "$(head -2 "$CASE/fake/events")" \
    "the limit prompt must be answered with Escape alone before the worker stops"
  assert_grep "CLAUDE_CONFIG_DIR='$CASE/accounts/spare'" "$CASE/fake/literal" "the replacement must launch under the chosen account"
  assert_grep 'claude_account=spare' "$CASE/home/state/t3.meta" "the task record must name the account it now runs on"
  assert_grep "stopped at its Claude account's usage limit" "$CASE/home/data/t3/brief.md" "the replacement must get the handoff note"
  [ ! -e "$CASE/home/state/t3.usage-limit" ] || fail "the usage-limit record must be consumed"
  [ -z "$(status_of t3)" ] || fail "a successful move raises no status line: $(status_of t3)"
  assert_grep 'all-accounts' "$CASE/fake/quota-calls" "the choice must come from one --all-accounts snapshot"
  [ "$(grep -c '' "$CASE/fake/quota-calls")" = 1 ] || fail "exactly one quota snapshot is taken"
  pass "run: the limit prompt gets its stop answer and the worker relaunches on an account with room"
}

test_no_qualifying_account_leaves_the_worker_stopped_with_one_blocked_line() {
  local out
  new_case none t4
  quota_snapshot 0 3 > "$CASE/fake/quota.json"
  record_limit t4
  out=$(case_env "$FAILOVER" run t4 2>&1)
  assert_contains "$out" "blocked t4" "the outcome should be blocked: $out"
  assert_equals "Escape" "$(cat "$CASE/fake/keys")" "the prompt still gets its stop answer"
  assert_no_grep '/exit' "$CASE/fake/literal" "the worker must be left in place, not relaunched"
  [ "$(status_of t4 | grep -c '^blocked: ')" = 1 ] || fail "exactly one blocked line: $(status_of t4)"
  assert_contains "$(status_of t4)" "resets 2026-10-06T22:59Z" "the blocked line names the other account's reset time"
  assert_contains "$(status_of t4)" "resets 2026-10-03T19:59Z" "the blocked line names the current account's reset time"
  assert_contains "$(status_of t4)" "$LIMIT_TEXT" "the blocked line carries Claude's limit text"
  assert_no_grep 'claude_account=' "$CASE/home/state/t4.meta" "the task record must not change"
  out=$(case_env "$FAILOVER" run t4 2>&1)
  assert_contains "$out" "skipped t4" "the consumed record must not be handled twice: $out"
  [ "$(status_of t4 | grep -c '^blocked: ')" = 1 ] || fail "a second pass must not add a second blocked line"
  pass "run: with no account above the floor the worker stays stopped and one blocked line names the resets"
}

test_an_active_no_mistakes_run_is_aborted_before_the_move() {
  local out
  new_case nm t5
  printf 'running' > "$CASE/fake/nm-state"
  record_limit t5
  out=$(case_env "$FAILOVER" run t5 2>&1)
  assert_contains "$out" "moved t5 limited spare" "the worker should move once its run stopped: $out"
  assert_grep 'axi abort --run RUN1' "$CASE/fake/nm-calls" "the task's own active run must be aborted through its supported abort"
  assert_grep 'no-mistakes run RUN1 was aborted' "$CASE/home/data/t5/brief.md" "the handoff note names the aborted run"

  new_case nm-stuck t6
  printf 'running' > "$CASE/fake/nm-state"
  : > "$CASE/fake/nm-abort-sticks"
  record_limit t6
  out=$(case_env "$FAILOVER" run t6 2>&1)
  assert_contains "$out" "blocked t6" "a run that does not stop must block the move: $out"
  assert_no_grep '/exit' "$CASE/fake/literal" "the worker must not move under a run still active"
  assert_contains "$(status_of t6)" "did not stop after its abort" "the blocked line names the stuck run"
  pass "run: an active no-mistakes run is aborted and proven stopped before the worker moves"
}

test_stale_or_unconfirmed_records_never_move_a_worker() {
  local out
  new_case stale t7
  record_limit t7
  printf 'busy_gen=g2\n' >> "$CASE/home/state/t7.meta"
  out=$(case_env "$FAILOVER" run t7 2>&1)
  assert_contains "$out" "skipped t7" "a record from another incarnation is skipped: $out"
  [ ! -s "$CASE/fake/keys" ] || fail "a stale record must not touch the terminal"

  new_case transient t8
  rm -f "$CASE/fake/screen"
  record_limit t8 rate_limit "API Error: Request rejected (429)"
  out=$(case_env "$FAILOVER" run t8 2>&1)
  assert_contains "$out" "skipped t8" "a 429 with no limit text and no prompt is not a usage limit: $out"
  [ ! -e "$CASE/fake/quota-calls" ] || fail "an unconfirmed limit must not read quota"
  pass "run: stale records and rate-limit turn ends without a usage limit are skipped"
}

test_a_second_move_inside_the_repeat_window_is_refused() {
  local out
  new_case repeat t9
  printf '%s limited spare\n' "$(date +%s)" > "$CASE/home/state/t9.account-failover"
  record_limit t9
  out=$(case_env "$FAILOVER" run t9 2>&1)
  assert_contains "$out" "blocked t9" "a second move this soon is refused: $out"
  assert_no_grep '/exit' "$CASE/fake/literal" "the worker must not be moved twice"
  pass "run: a task moved recently is left stopped rather than moved again"
}

# --- watcher -------------------------------------------------------------------

test_the_watcher_moves_a_limited_worker_and_wakes_once() {
  local pid out
  new_case watch t12
  make_fake_crew_state "$CASE/fakebin" >/dev/null
  record_limit t12
  case_env FM_ROOT_OVERRIDE="$ROOT" FM_CREW_STATE_BIN="$CASE/fakebin/fm-crew-state.sh" TMUX='' FM_BACKEND=tmux \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$CASE/watch.out" 2> "$CASE/watch.err" &
  pid=$!
  wait_for_exit "$pid" 600 || fail "the watcher did not exit on the failover wake: $(cat "$CASE/watch.out" "$CASE/watch.err")"
  out=$(cat "$CASE/watch.out")
  assert_contains "$out" "check: account failover moved t12 from Claude account limited to spare after a usage limit" \
    "the watcher should surface the move as one check wake: $(cat "$CASE/watch.err")"
  [ "$(grep -c 'account-failover-t12-' "$CASE/home/state/.wake-queue")" = 1 ] \
    || fail "the move should queue exactly one durable wake row: $(cat "$CASE/home/state/.wake-queue")"
  assert_grep 'claude_account=spare' "$CASE/home/state/t12.meta" "the watcher's move must record the new account"
  pass "watcher: a recorded usage limit is moved by the per-cycle tick and surfaces as one check wake"
}

# --- control and spawn ---------------------------------------------------------

test_relaunch_refuses_an_unusable_account_before_stopping_the_worker() {
  local out rc
  new_case refuse t10
  out=$(case_env "$CONTROL" t10 relaunch --claude-account nobody --note "x" 2>&1); rc=$?
  expect_code 1 "$rc" "an unknown account must refuse"
  assert_contains "$out" "names no Claude account 'nobody'" "the refusal names the account"
  rm -f "$CASE/accounts/spare/.credentials.json"
  out=$(case_env "$CONTROL" t10 relaunch --claude-account spare --note "x" 2>&1); rc=$?
  expect_code 1 "$rc" "a signed-out account must refuse"
  assert_contains "$out" "is not signed in" "the refusal names the sign-in"
  printf 'ordinary\n' > "$CASE/home/config/claude-account"
  out=$(case_env "$CONTROL" t10 relaunch --claude-account limited --note "x" 2>&1); rc=$?
  expect_code 1 "$rc" "a pinned home must refuse a failover account"
  assert_contains "$out" "config/claude-account pins every Claude worker" "the refusal names the pin"
  assert_no_grep '/exit' "$CASE/fake/literal" "every refusal must happen before the worker stops"
  pass "fm-control relaunch: an unknown, signed-out, or pin-conflicting account refuses before the worker stops"
}

test_a_moved_task_keeps_its_account_until_default() {
  local out rc
  new_case keep t11
  rm -f "$CASE/fake/screen"
  out=$(case_env "$CONTROL" t11 relaunch --claude-account spare --note "move" 2>&1); rc=$?
  expect_code 0 "$rc" "the move should succeed: $out"
  assert_contains "$out" "claude_account=spare" "the outcome names the account"
  : > "$CASE/fake/literal"
  out=$(case_env "$CONTROL" t11 relaunch --note "again" 2>&1); rc=$?
  expect_code 0 "$rc" "a later relaunch should succeed: $out"
  assert_grep "CLAUDE_CONFIG_DIR='$CASE/accounts/spare'" "$CASE/fake/literal" "a later relaunch keeps the moved account"
  assert_grep 'claude_account=spare' "$CASE/home/state/t11.meta" "the record keeps the account"
  : > "$CASE/fake/literal"
  out=$(case_env "$CONTROL" t11 relaunch --claude-account default --note "back" 2>&1); rc=$?
  expect_code 0 "$rc" "returning to the default account should succeed: $out"
  assert_no_grep 'claude_account=' "$CASE/home/state/t11.meta" "default clears the account"
  assert_no_grep "CLAUDE_CONFIG_DIR=" "$CASE/fake/literal" "default returns to the home's ordinary launch"
  pass "fm-control relaunch: a moved task stays on its account across relaunches until --claude-account default"
}

test_record_writes_a_usage_limit_record_only_for_a_rate_limit_with_the_map
test_absent_map_is_a_no_op
test_choose_picks_by_quota_and_respects_the_floor
test_choose_refuses_unknown_quota_and_paid_usage
test_limit_prompt_is_answered_with_stop_and_the_worker_moves_to_an_account_with_room
test_no_qualifying_account_leaves_the_worker_stopped_with_one_blocked_line
test_an_active_no_mistakes_run_is_aborted_before_the_move
test_stale_or_unconfirmed_records_never_move_a_worker
test_a_second_move_inside_the_repeat_window_is_refused
test_the_watcher_moves_a_limited_worker_and_wakes_once
test_relaunch_refuses_an_unusable_account_before_stopping_the_worker
test_a_moved_task_keeps_its_account_until_default
