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
  # Like quota-axi 0.1.55, --all-accounts refuses --max-age.
  cat > "$fb/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/fake/quota-calls'
case " \$* " in
  *" --all-accounts "*" --max-age "* | *" --max-age "*" --all-accounts "*)
    echo 'error: "--all-accounts cannot be combined with --max-age"'
    exit 1
    ;;
esac
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
  # Keep the home off the supervision host, which a Claude caller would
  # otherwise turn on, so its lease lock never depends on who runs the suite.
  : > "$dir/home/config/supervision-host-off"
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
  local id=$1 error=${2:-rate_limit} message=${3-$LIMIT_TEXT}
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
  case_env "$FAILOVER" choose --map "$CASE/home/config/claude-failover" --snapshot "$snap" "$@"
}

test_choose_picks_by_quota_and_respects_the_fixed_margin() {
  local out rc
  new_case choose c1
  out=$(choose "$(quota_snapshot 0 81)" --current limited --model claude-fable-5-1); rc=$?
  expect_code 0 "$rc" "an account with room should be picked: $out"
  assert_equals "pick	spare	81" "$out" "the spare account has room"
  out=$(choose "$(quota_snapshot 90 81)" --current limited); rc=$?
  assert_equals "pick	spare	81" "$out" "the current account never qualifies, even when its reading shows room"
  out=$(choose "$(quota_snapshot 0 5)" --current limited); rc=$?
  expect_code 1 "$rc" "an account at the fixed 5% safety margin must not be picked"
  assert_contains "$out" "spare: 5% left, at or below the 5% safety margin, resets 2026-10-06T22:59Z" "the refusal names the safety margin and the reset time"
  assert_contains "$out" "limited: 0% left, the account the worker just ran out on, resets 2026-10-03T19:59Z" "the refusal names the current account's reset"
  out=$(choose "$(quota_snapshot 0 6)" --current limited); rc=$?
  assert_equals "pick	spare	6" "$out" "an account just above the safety margin qualifies"
  out=$(choose "$(quota_snapshot 0 15)" --current limited); rc=$?
  expect_code 0 "$rc" "15% quota is above the fixed margin: $out"
  printf 'floor 20\n' >> "$CASE/home/config/claude-failover"
  out=$(choose "$(quota_snapshot 0 15)" --current limited); rc=$?
  expect_code 2 "$rc" "the removed floor setting must refuse as malformed: $out"
  pass "choose: uses only the fixed 5% safety margin and refuses removed configuration"
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
  expect_code 1 "$rc" "enabled extra usage must refuse even when the plan has room"
  assert_contains "$out" "paid usage enabled" "enabled extra usage is named"
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].quotaSemantics.effectiveAvailability[1].effectivePercentRemaining = 2')" --current limited --model claude-fable-5-1); rc=$?
  expect_code 1 "$rc" "a fable worker must respect the fable model scope"
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].quotaSemantics.effectiveAvailability[1].effectivePercentRemaining = 2')" --current limited --model claude-opus-5-5); rc=$?
  expect_code 0 "$rc" "an opus worker is not bound by the fable scope"
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].quotaSemantics.effectiveAvailability[1].effectivePercentRemaining = 2')" --current limited); rc=$?
  expect_code 1 "$rc" "an unknown model is bound by every model scope"
  pass "choose: unknown, missing, stale, and credit-backed quota never qualifies, and model scopes apply"
}

model_scope_snapshot() {
  quota_snapshot 0 80 | jq --arg exhausted "${1:-}" '
    .providers[1] |= (.quotaSemantics.effectiveAvailability[1] as $scope |
      .windows += ["opus", "sonnet", "haiku", "future" |
        {id: ("model:" + .), kind: "model", percentRemaining: 80}] |
      .quotaSemantics.effectiveAvailability += ["opus", "sonnet", "haiku", "future" | . as $family |
        $scope | .scope = ("model:" + $family) |
        .boundedBy = ["five_hour", "seven_day", ("model:" + $family)]]) |
    .providers[1].quotaSemantics.effectiveAvailability |= map(
      if .scope == ("model:" + $exhausted) then
        .effectivePercentRemaining = 0 | .runway.status = "exhausted_now"
      else . end) |
    .providers[1].windows |= map(
      if .id == ("model:" + $exhausted) then .percentRemaining = 0 else . end)'
}

test_model_choices_check_every_family_they_can_use() {
  local model families family out rc
  new_case model-families c3
  while read -r model families; do
    out=$(choose "$(model_scope_snapshot)" --current limited --model "$model"); rc=$?
    expect_code 0 "$rc" "$model must qualify when every family has room: $out"
    for family in opus sonnet fable haiku future; do
      out=$(choose "$(model_scope_snapshot "$family")" --current limited --model "$model"); rc=$?
      case "$family: $families " in
        future:* | *" $family "*) expect_code 1 "$rc" "$model must refuse exhausted $family quota: $out" ;;
        *) expect_code 0 "$rc" "$model must ignore unrelated $family quota: $out" ;;
      esac
    done
  done <<'MODELS'
opusplan opus sonnet
opusplan[1m] opus sonnet
best fable opus
best[1m] fable opus
opus opus
opus[1m] opus
sonnet sonnet
sonnet[1m] sonnet
fable fable
haiku haiku sonnet
claude-opus-5-5 opus
claude-3-opus-20240229 opus
claude-3-5-sonnet-latest sonnet
claude-haiku-4-5-20251001 haiku sonnet
default opus sonnet fable haiku future
custom-v2 opus sonnet fable haiku future
deployment-opus opus sonnet fable haiku future
MODELS
  out=$(choose "$(model_scope_snapshot | jq '.providers[1].quotaSemantics.effectiveAvailability |= map(if .scope == "model:sonnet" then .status = "unknown" else . end)')" --current limited --model opusplan); rc=$?
  expect_code 1 "$rc" "opusplan must refuse unknown execution quota: $out"
  pass "choose: aliases and full model ids check all usable families; unresolved names check every scope"
}

test_automatic_recovery_respects_alias_and_unresolved_model_scopes() {
  local model family out
  while read -r model family; do
    new_case "model-blocked-$model" t20
    printf 'model=%s\n' "$model" >> "$CASE/home/state/t20.meta"
    printf 'running' > "$CASE/fake/nm-state"
    model_scope_snapshot "$family" > "$CASE/fake/quota.json"
    record_limit t20
    out=$(case_env "$FAILOVER" run t20 2>&1)
    assert_contains "$out" "blocked t20" "$model must not move onto exhausted $family quota: $out"
    assert_no_grep '/exit' "$CASE/fake/literal" "no replacement can start on the exhausted family"
    [ ! -e "$CASE/fake/nm-calls" ] || fail "ineligible model quota must precede validation cancellation"
  done <<'MODELS'
opusplan sonnet
best opus
custom-v2 future
MODELS
  new_case model-move t21
  printf 'model=opusplan\n' >> "$CASE/home/state/t21.meta"
  model_scope_snapshot fable > "$CASE/fake/quota.json"
  record_limit t21
  out=$(case_env "$FAILOVER" run t21 2>&1)
  assert_contains "$out" "moved t21 limited spare" "opusplan can move when both phases have room: $out"
  assert_grep 'model=opusplan' "$CASE/home/state/t21.meta" "the replacement retains its supported alias"
  pass "run: recorded model choices constrain recovery and eligible aliases survive relaunch"
}

# --- run ---------------------------------------------------------------------

test_limit_prompt_is_answered_with_stop_and_the_worker_moves_to_an_account_with_room() {
  local out
  new_case move t3
  record_limit t3 rate_limit ""
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
  assert_grep 'all-accounts' "$CASE/fake/quota-calls" "quota checks use all mapped accounts"
  [ "$(grep -c '' "$CASE/fake/quota-calls")" = 3 ] || fail "selection, control, and spawn each check fresh quota"
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
  pass "run: with no account above the fixed margin the worker stays stopped and one blocked line names the resets"
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

test_stale_records_never_move_a_worker() {
  local out
  new_case stale t7
  record_limit t7
  printf 'busy_gen=g2\n' >> "$CASE/home/state/t7.meta"
  out=$(case_env "$FAILOVER" run t7 2>&1)
  assert_contains "$out" "skipped t7" "a record from another incarnation is skipped: $out"
  [ ! -s "$CASE/fake/keys" ] || fail "a stale record must not touch the terminal"

  pass "run: stale records are skipped"
}

test_unconfirmed_rate_limits_leave_validation_and_worker_untouched() {
  local scenario id message out meta brief
  for scenario in run tick control text-only stop-only cancel-only; do
    id="t8-$scenario"
    new_case "transient-$scenario" "$id"
    rm -f "$CASE/fake/screen"
    message="API Error: Rate limit reached"
    case "$scenario" in
      text-only) message=$LIMIT_TEXT ;;
      stop-only) printf 'Stop and wait for limit to reset\n' > "$CASE/fake/screen" ;;
      cancel-only) printf 'Esc to cancel\n' > "$CASE/fake/screen" ;;
    esac
    printf 'running' > "$CASE/fake/nm-state"
    meta=$(cat "$CASE/home/state/$id.meta")
    brief=$(cat "$CASE/home/data/$id/brief.md")
    record_limit "$id" rate_limit "$message"
    case "$scenario" in
      tick) out=$(case_env "$FAILOVER" tick 2>&1) ;;
      control) out=$(case_env "$CONTROL" "$id" relaunch --usage-limit 2>&1) ;;
      *) out=$(case_env "$FAILOVER" run "$id" 2>&1) ;;
    esac
    assert_contains "$out" "skipped $id" "$scenario without the complete prompt must be skipped: $out"
    [ ! -e "$CASE/fake/quota-calls" ] || fail "$scenario must not read quota"
    [ ! -e "$CASE/fake/nm-calls" ] || fail "$scenario must not touch validation"
    assert_equals running "$(cat "$CASE/fake/nm-state")" "$scenario must leave validation running"
    [ ! -s "$CASE/fake/keys" ] || fail "$scenario must not send terminal keys"
    [ ! -s "$CASE/fake/literal" ] || fail "$scenario must not stop or relaunch the worker"
    assert_equals claude "$(cat "$CASE/fake/command")" "$scenario must leave the worker running"
    assert_equals "$meta" "$(cat "$CASE/home/state/$id.meta")" "$scenario must retain the worker's account and generation"
    assert_equals "$brief" "$(cat "$CASE/home/data/$id/brief.md")" "$scenario must not create a handoff"
    [ -z "$(status_of "$id")" ] || fail "$scenario must not report account exhaustion"
  done
  pass "recovery: throttling, hook text, and partial prompts leave validation and the worker untouched"
}

test_a_second_usage_limit_moves_to_a_third_account() {
  local out gen
  new_case repeat t9
  mkdir -p "$CASE/accounts/third"
  printf '{}\n' > "$CASE/accounts/third/.credentials.json"
  printf 'account third %s\n' "$CASE/accounts/third" >> "$CASE/home/config/claude-failover"
  quota_snapshot 0 6 '.providers += [.providers[1] | .account = "third"]' > "$CASE/fake/quota.json"
  record_limit t9
  out=$(case_env "$FAILOVER" run t9 2>&1)
  assert_contains "$out" "moved t9 limited spare" "the first exhaustion moves: $out"
  gen=$(sed -n 's/^busy_gen=//p' "$CASE/home/state/t9.meta" | tail -1)
  printf '%s' "$LIMIT_SCREEN" > "$CASE/fake/screen"
  quota_snapshot 0 0 '.providers += [.providers[1] | .account = "third" | .quotaSemantics.effectiveAvailability[] |= (.effectivePercentRemaining = 80 | .runway.status = "through_reset")]' > "$CASE/fake/quota.json"
  jq -nc --arg m "$LIMIT_TEXT" '{error: "rate_limit", last_assistant_message: $m}' |
    case_env CLAUDE_CONFIG_DIR="$CASE/accounts/spare" "$FAILOVER" record "$CASE/home/config" "$CASE/home/state" t9 "$gen"
  out=$(case_env "$FAILOVER" run t9 2>&1)
  assert_contains "$out" "moved t9 spare third" "a second exhaustion moves without delay: $out"
  assert_grep 'claude_account=third' "$CASE/home/state/t9.meta" "the third account is recorded"
  [ ! -e "$CASE/home/state/t9.account-failover" ] || fail "moves must not create a cooldown ledger"
  pass "run: consecutive genuine usage limits can move onto another account"
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

test_a_moved_task_keeps_its_literal_account() {
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
  printf 'account default ordinary\n' >> "$CASE/home/config/claude-failover"
  quota_snapshot 80 81 '.providers[0].account = "default"' > "$CASE/fake/quota.json"
  : > "$CASE/fake/literal"
  out=$(case_env CLAUDE_CONFIG_DIR="$CASE/accounts/spare" "$CONTROL" t11 relaunch --claude-account default --note "back" 2>&1); rc=$?
  expect_code 0 "$rc" "selecting the literal default account should succeed: $out"
  assert_grep 'claude_account=default' "$CASE/home/state/t11.meta" "default is retained literally"
  assert_no_grep "CLAUDE_CONFIG_DIR=" "$CASE/fake/literal" "the mapped ordinary root sheds the supervisor root"
  : > "$CASE/fake/literal"
  out=$(case_env "$CONTROL" t11 relaunch --note "keep literal" 2>&1); rc=$?
  expect_code 0 "$rc" "the literal account must survive another relaunch: $out"
  assert_grep 'claude_account=default' "$CASE/home/state/t11.meta" "the literal name survives control and spawn carry-forward"
  pass "fm-control relaunch: every selected account name is literal and retained"
}

test_unusable_preferred_accounts_are_filtered_before_validation() {
  local out mode
  for mode in missing signed-out; do
    new_case "candidate-$mode" t13
    printf 'running' > "$CASE/fake/nm-state"
    printf 'account preferred %s\n' "$CASE/accounts/preferred" >> "$CASE/home/config/claude-failover"
    [ "$mode" != signed-out ] || mkdir -p "$CASE/accounts/preferred"
    quota_snapshot 0 81 '.providers += [.providers[1] | .account = "preferred" | .quotaSemantics.effectiveAvailability[].selection.spendPriority = 1]' > "$CASE/fake/quota.json"
    record_limit t13
    out=$(case_env "$FAILOVER" run t13 2>&1)
    assert_contains "$out" "moved t13 limited spare" "a $mode preferred root must not strand the worker: $out"
    assert_grep 'claude_account=spare' "$CASE/home/state/t13.meta" "the usable candidate is launched"
    assert_grep 'axi abort --run RUN1' "$CASE/fake/nm-calls" "validation still stops cleanly"
  done
  new_case candidate-none t18
  printf 'running' > "$CASE/fake/nm-state"
  rm -f "$CASE/accounts/spare/.credentials.json"
  record_limit t18
  out=$(case_env "$FAILOVER" run t18 2>&1)
  assert_contains "$out" "blocked t18" "no usable alternative blocks before validation: $out"
  [ ! -e "$CASE/fake/nm-calls" ] || fail "candidate refusal must not cancel validation"
  pass "run: unusable and signed-out preferred accounts do not hide usable alternatives"
}

test_recovery_guards_precede_every_mutation() {
  local out rc mode
  for mode in gate lease lifecycle; do
    new_case "guard-$mode" t14
    printf 'running' > "$CASE/fake/nm-state"
    record_limit t14
    case "$mode" in
      gate)
        out=$(case_env FM_GATE_REFUSE_BYPASS=0 NO_MISTAKES_GATE=review "$FAILOVER" run t14 2>&1); rc=$?
        expect_code 3 "$rc" "gate recovery must refuse: $out"
        ;;
      lease)
        printf '%s\n' "$$" > "$CASE/home/state/.lock"
        printf 'branch\t%s\t%s\n' "$$" "$(date +%s)" > "$CASE/home/state/.lease-t14"
        out=$(case_env FM_SUPERVISION_ACTOR=main "$FAILOVER" run t14 2>&1); rc=$?
        expect_code 6 "$rc" "foreign lease recovery must refuse: $out"
        ;;
      lifecycle)
        mkdir "$CASE/home/state/.control-t14.lock"
        printf '%s\n' "$$" > "$CASE/home/state/.control-t14.lock/pid"
        out=$(case_env "$FAILOVER" run t14 2>&1); rc=$?
        expect_code 1 "$rc" "concurrent lifecycle recovery must refuse: $out"
        ;;
    esac
    [ -f "$CASE/home/state/t14.usage-limit" ] || fail "$mode refusal must preserve the event"
    [ ! -s "$CASE/fake/keys" ] || fail "$mode refusal must not touch the terminal"
    [ ! -e "$CASE/fake/nm-calls" ] || fail "$mode refusal must not mutate validation"
    assert_equals running "$(cat "$CASE/fake/nm-state")" "$mode refusal preserves validation"
    assert_grep 'busy_gen=g1' "$CASE/home/state/t14.meta" "$mode refusal preserves the generation"
  done
  pass "run: gate, lease, and lifecycle boundaries protect all recovery mutations"
}

test_manual_relaunch_cannot_race_the_quota_query() {
  local out
  new_case quota-race t15
  cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
if [ ! -e '$CASE/fake/race-result' ]; then
  '$CONTROL' t15 relaunch --note 'manual replacement' > '$CASE/fake/race-output' 2>&1
  printf '%s' "\$?" > '$CASE/fake/race-result'
fi
cat '$CASE/fake/quota.json'
SH
  record_limit t15
  out=$(case_env "$FAILOVER" run t15 2>&1)
  assert_contains "$out" "moved t15 limited spare" "guarded recovery completes: $out"
  assert_equals 1 "$(cat "$CASE/fake/race-result")" "manual relaunch is excluded throughout quota selection"
  assert_contains "$(cat "$CASE/fake/race-output")" "another lifecycle action" "the shared boundary refuses the race"
  [ "$(grep -c '^text:/exit$' "$CASE/fake/events")" = 1 ] || fail "only the original worker is stopped"
  pass "run: quota selection cannot race a manual replacement"
}

test_paid_usage_is_rejected_at_control_and_spawn_launch_boundaries() {
  local out rc
  new_case paid-control t16
  rm -f "$CASE/fake/screen"
  quota_snapshot 0 81 '.providers[1].windows += [{id: "extra_usage", kind: "credits", percentRemaining: 0}]' > "$CASE/fake/quota.json"
  out=$(case_env "$CONTROL" t16 relaunch --claude-account spare --note "move" 2>&1); rc=$?
  expect_code 1 "$rc" "paid-enabled account must refuse at control: $out"
  assert_contains "$out" "paid usage enabled" "the control refusal names paid usage"
  [ ! -s "$CASE/fake/literal" ] || fail "paid control refusal must precede stopping"

  new_case paid-spawn t17
  rm -f "$CASE/fake/screen"
  cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf 'read\n' >> '$CASE/fake/quota-calls'
if [ "\$(wc -l < '$CASE/fake/quota-calls')" -gt 1 ]; then
  jq '.providers[1].windows += [{id: "extra_usage", kind: "credits"}]' '$CASE/fake/quota.json'
else
  cat '$CASE/fake/quota.json'
fi
SH
  out=$(case_env "$CONTROL" t17 relaunch --claude-account spare --note "move" 2>&1); rc=$?
  expect_code 1 "$rc" "paid usage enabled after control must refuse at spawn: $out"
  assert_contains "$out" "paid usage enabled" "spawn rechecks paid status"
  assert_no_grep 'claude_account=' "$CASE/home/state/t17.meta" "failed spawn retains the prior record"
  assert_no_grep 'encode launch-brief' "$CASE/fake/literal" "no paid replacement is started"
  new_case paid-auto t19
  cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf 'read\n' >> '$CASE/fake/quota-calls'
if [ "\$(wc -l < '$CASE/fake/quota-calls')" -gt 1 ]; then
  jq '.providers[1].windows += [{id: "extra_usage", kind: "credits"}]' '$CASE/fake/quota.json'
else
  cat '$CASE/fake/quota.json'
fi
SH
  record_limit t19
  out=$(case_env "$FAILOVER" run t19 2>&1)
  assert_contains "$out" "blocked t19" "a changed paid setting produces a blocked recovery outcome: $out"
  assert_contains "$(status_of t19)" "replacement failed" "the failed move wakes supervision"
  [ ! -s "$CASE/fake/literal" ] || fail "paid recovery refusal must precede stopping"
  pass "launch: control and spawn both refuse paid-enabled accounts"
}

make_quota_cache_fake() {
  quota_snapshot 0 81 '.providers[].state.reused = true' > "$CASE/fake/quota-cached.json"
  cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
D='$CASE/fake'
max_age=\${QUOTA_AXI_MAX_AGE:-0}
case " \$* " in *" --max-age "*) echo 'error: "--all-accounts cannot be combined with --max-age"'; exit 1 ;; esac
if [ "\$max_age" != 0 ]; then
  cat "\$D/quota-cached.json"
else
  printf 'vendor read\n' >> "\$D/vendor-reads"
  if [ -f "\$D/quota-after.json" ] && [ "\$(wc -l < "\$D/vendor-reads")" -ge ${1:-2} ]; then
    cat "\$D/quota-after.json"
  else
    cat "\$D/quota.json"
  fi
fi
SH
}

test_reused_quota_cannot_authorize_selection_or_launch() {
  local out rc mode
  new_case supplied-cache c4
  out=$(choose "$(quota_snapshot 0 81 '.providers[1].state.reused = true')" --current limited); rc=$?
  expect_code 1 "$rc" "a reused supplied snapshot cannot authorize a move: $out"

  for mode in recovery control spawn; do
    new_case "cache-$mode" t22
    make_quota_cache_fake
    if [ "$mode" = spawn ]; then
      quota_snapshot 0 81 '.providers[1].windows += [{id: "extra_usage", kind: "credits"}]' > "$CASE/fake/quota-after.json"
    else
      quota_snapshot 0 81 '.providers[1].windows += [{id: "extra_usage", kind: "credits"}]' > "$CASE/fake/quota.json"
    fi
    if [ "$mode" = recovery ]; then
      record_limit t22
      out=$(case_env QUOTA_AXI_MAX_AGE=1h "$FAILOVER" run t22 2>&1)
      assert_contains "$out" "blocked t22" "recovery must read the changed paid setting: $out"
    else
      rm -f "$CASE/fake/screen"
      out=$(case_env QUOTA_AXI_MAX_AGE=1h "$CONTROL" t22 relaunch --claude-account spare --note "move" 2>&1); rc=$?
      expect_code 1 "$rc" "$mode must refresh the changed paid setting: $out"
    fi
    [ -s "$CASE/fake/vendor-reads" ] || fail "$mode must ask the vendor despite ambient reuse"
    assert_no_grep 'claude_account=' "$CASE/home/state/t22.meta" "$mode cannot publish a paid account"
    assert_no_grep 'encode launch-brief' "$CASE/fake/literal" "$mode cannot launch the paid replacement"
    if [ "$mode" != spawn ]; then
      assert_no_grep '/exit' "$CASE/fake/literal" "$mode refusal precedes stopping"
    fi
  done

  new_case cache-safe t23
  make_quota_cache_fake
  quota_snapshot 0 15 > "$CASE/fake/quota.json"
  record_limit t23
  out=$(case_env QUOTA_AXI_MAX_AGE=1h "$FAILOVER" run t23 2>&1)
  assert_contains "$out" "moved t23 limited spare" "an uncached safe account above the fixed margin still moves: $out"
  assert_equals 3 "$(wc -l < "$CASE/fake/vendor-reads" | tr -d ' ')" "selection, control, and spawn each refresh"
  pass "quota: supplied cache refuses; selection and both launch boundaries force vendor reads"
}

represented_scope_snapshot() {
  quota_snapshot 0 80 | jq --arg scope "$1" '
    .providers[1].windows[2] |= (.id = $scope | .percentRemaining = 0) |
    .providers[1].quotaSemantics.effectiveAvailability[1] |= (
      .scope = $scope | .effectivePercentRemaining = 0 |
      .boundedBy = ["five_hour", "seven_day", $scope] | .limitingWindowIds = [$scope] |
      .runway = {status: "exhausted_now", limitingWindowId: $scope})'
}

test_model_scope_representations_constrain_the_same_families() {
  local scope family model out rc
  new_case scope-representations c5
  while read -r scope family; do
    for model in opus sonnet opusplan best custom-v2; do
      out=$(choose "$(represented_scope_snapshot "$scope")" --current limited --model "$model"); rc=$?
      case "$family:$model" in
        opus:sonnet | sonnet:opus | sonnet:best | fable:opus | fable:sonnet | fable:opusplan)
          expect_code 0 "$rc" "$model can ignore unrelated $scope quota: $out" ;;
        *) expect_code 1 "$rc" "$model must respect exhausted $scope quota: $out" ;;
      esac
    done
  done <<'SCOPES'
model:opus opus
seven_day_opus opus
model:seven_day_opus opus
model:claude-opus-4-6 opus
model:opus-4-6 opus
model:claude-opus-4.6 opus
model:claude-3-opus-20240229 opus
model:claude-sonnet-4-6 sonnet
model:sonnet-4-6 sonnet
model:claude-fable-5-1 fable
model:unreleased-v2 unknown
future_scope unknown
SCOPES
  pass "choose: legacy, versioned, and unresolved model allowances cannot be skipped"
}

test_recovery_respects_legacy_versioned_and_unresolved_scopes() {
  local scope out
  for scope in seven_day_opus model:claude-opus-4-6 model:unreleased-v2; do
    new_case "represented-${scope//:/-}" t24
    printf 'model=opus\n' >> "$CASE/home/state/t24.meta"
    represented_scope_snapshot "$scope" > "$CASE/fake/quota.json"
    record_limit t24
    out=$(case_env "$FAILOVER" run t24 2>&1)
    assert_contains "$out" "blocked t24" "recovery must respect exhausted $scope: $out"
    assert_no_grep '/exit' "$CASE/fake/literal" "an exhausted relevant scope prevents replacement"
  done
  new_case represented-unrelated t25
  printf 'model=sonnet\n' >> "$CASE/home/state/t25.meta"
  represented_scope_snapshot seven_day_opus > "$CASE/fake/quota.json"
  record_limit t25
  out=$(case_env "$FAILOVER" run t25 2>&1)
  assert_contains "$out" "moved t25 limited spare" "Sonnet can move despite unrelated legacy Opus exhaustion: $out"
  pass "run: scope representations preserve relevant refusals and ordinary successful moves"
}

launch_scope_snapshot() {
  quota_snapshot 0 6 '.providers[1] |= (
    .windows[2].id = "model:claude-sonnet-4-6" | .windows[2].percentRemaining = 6 |
    .quotaSemantics.effectiveAvailability[1] |= (
      .scope = "model:claude-sonnet-4-6" |
      .boundedBy = ["five_hour", "seven_day", "model:claude-sonnet-4-6"] |
      .limitingWindowIds = ["model:claude-sonnet-4-6"] |
      .runway.limitingWindowId = "model:claude-sonnet-4-6"))' | jq "$1"
}

test_remaining_quota_is_checked_at_control_and_spawn() {
  local boundary problem filter out rc expected_reads
  for boundary in control spawn; do
    while read -r problem filter; do
      new_case "headroom-$boundary-$problem" t26
      printf 'model=opusplan\n' >> "$CASE/home/state/t26.meta"
      rm -f "$CASE/fake/screen"
      make_quota_cache_fake
      if [ "$boundary" = control ]; then
        launch_scope_snapshot "$filter" > "$CASE/fake/quota.json"
        expected_reads=1
      else
        launch_scope_snapshot "$filter" > "$CASE/fake/quota-after.json"
        expected_reads=2
      fi
      out=$(case_env "$CONTROL" t26 relaunch --claude-account spare --note "move" 2>&1); rc=$?
      expect_code 1 "$rc" "$boundary must refuse $problem model-aware quota: $out"
      assert_contains "$out" 'cannot launch' "remaining quota must cause the refusal: $out"
      assert_equals "$expected_reads" "$(wc -l < "$CASE/fake/vendor-reads" | tr -d ' ')" "the refusal occurs at $boundary"
      assert_no_grep 'claude_account=' "$CASE/home/state/t26.meta" "$boundary cannot publish an ineligible account"
      assert_no_grep "CLAUDE_CONFIG_DIR='$CASE/accounts/spare'" "$CASE/fake/literal" "$boundary cannot launch an ineligible replacement"
      if [ "$boundary" = control ]; then
        assert_no_grep '/exit' "$CASE/fake/literal" "control refusal precedes stopping"
        assert_equals claude "$(cat "$CASE/fake/command")" "the original agent stays alive"
      else
        assert_equals zsh "$(cat "$CASE/fake/command")" "the refused replacement stays stopped"
      fi
    done <<'QUOTA'
all-margin .providers[1].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 5
all-exhausted .providers[1].quotaSemantics.effectiveAvailability[0].runway.status = "exhausted_now"
model-margin .providers[1].quotaSemantics.effectiveAvailability[1].effectivePercentRemaining = 5
model-zero .providers[1].quotaSemantics.effectiveAvailability[1].effectivePercentRemaining = 0
model-exhausted .providers[1].quotaSemantics.effectiveAvailability[1].runway.status = "exhausted_now"
model-unknown .providers[1].quotaSemantics.effectiveAvailability[1].status = "unknown"
model-percent-unknown .providers[1].quotaSemantics.effectiveAvailability[1].effectivePercentRemaining = null
all-missing .providers[1].quotaSemantics.effectiveAvailability |= map(select(.scope != "all_models"))
QUOTA
  done
  pass "launch: both fresh launch readings enforce model certainty, exhaustion, and the fixed margin"
}

test_recovery_refuses_quota_exhausted_after_selection() {
  local change_at out rc
  for change_at in 2 3; do
    new_case "headroom-race-$change_at" t27
    make_quota_cache_fake "$change_at"
    quota_snapshot 0 6 > "$CASE/fake/quota.json"
    quota_snapshot 0 0 > "$CASE/fake/quota-after.json"
    record_limit t27
    out=$(case_env "$FAILOVER" run t27 2>&1); rc=$?
    expect_code 1 "$rc" "quota exhausted after selection must refuse at reading $change_at: $out"
    assert_contains "$out" 'cannot launch' "the fresh reading refuses the exhausted account: $out"
    assert_contains "$(status_of t27)" 'replacement failed' "a refused replacement wakes supervision"
    assert_equals "$change_at" "$(wc -l < "$CASE/fake/vendor-reads" | tr -d ' ')" "the fresh launch reading catches exhaustion"
    assert_no_grep 'claude_account=' "$CASE/home/state/t27.meta" "an exhausted account cannot be published"
    assert_no_grep "CLAUDE_CONFIG_DIR='$CASE/accounts/spare'" "$CASE/fake/literal" "an exhausted replacement cannot launch"
    if [ "$change_at" = 2 ]; then
      assert_no_grep '/exit' "$CASE/fake/literal" "control refuses before stopping the original"
      assert_equals claude "$(cat "$CASE/fake/command")" "the original agent stays alive"
    else
      assert_equals zsh "$(cat "$CASE/fake/command")" "the exhausted replacement stays stopped"
    fi
  done
  pass "run: quota exhausted between selection and either launch check blocks the move"
}

test_launch_checks_use_retained_and_overridden_models() {
  local mode out rc
  local -a relaunch_args
  for mode in retained overridden; do
    new_case "headroom-model-$mode" t28
    rm -f "$CASE/fake/screen"
    relaunch_args=(t28 relaunch --claude-account spare --note "move")
    if [ "$mode" = retained ]; then
      printf 'model=sonnet\n' >> "$CASE/home/state/t28.meta"
    else
      printf 'model=opusplan\n' >> "$CASE/home/state/t28.meta"
      relaunch_args+=(--model sonnet)
    fi
    represented_scope_snapshot seven_day_opus > "$CASE/fake/quota.json"
    out=$(case_env "$CONTROL" "${relaunch_args[@]}" 2>&1); rc=$?
    expect_code 0 "$rc" "$mode Sonnet ignores unrelated Opus exhaustion at both launch checks: $out"
    assert_grep 'claude_account=spare' "$CASE/home/state/t28.meta" "the safe account is published"
    assert_grep 'model=sonnet' "$CASE/home/state/t28.meta" "the requested model is launched"
    assert_grep "CLAUDE_CONFIG_DIR='$CASE/accounts/spare'" "$CASE/fake/literal" "the safe replacement launches on the selected root"
    assert_equals claude "$(cat "$CASE/fake/command")" "the replacement is alive"
  done
  pass "launch: retained and overridden models preserve ordinary successful account moves"
}

test_record_writes_a_usage_limit_record_only_for_a_rate_limit_with_the_map
test_absent_map_is_a_no_op
test_choose_picks_by_quota_and_respects_the_fixed_margin
test_choose_refuses_unknown_quota_and_paid_usage
test_limit_prompt_is_answered_with_stop_and_the_worker_moves_to_an_account_with_room
test_no_qualifying_account_leaves_the_worker_stopped_with_one_blocked_line
test_an_active_no_mistakes_run_is_aborted_before_the_move
test_stale_records_never_move_a_worker
test_unconfirmed_rate_limits_leave_validation_and_worker_untouched
test_a_second_usage_limit_moves_to_a_third_account
test_the_watcher_moves_a_limited_worker_and_wakes_once
test_relaunch_refuses_an_unusable_account_before_stopping_the_worker
test_a_moved_task_keeps_its_literal_account
test_unusable_preferred_accounts_are_filtered_before_validation
test_recovery_guards_precede_every_mutation
test_manual_relaunch_cannot_race_the_quota_query
test_paid_usage_is_rejected_at_control_and_spawn_launch_boundaries
test_model_choices_check_every_family_they_can_use
test_automatic_recovery_respects_alias_and_unresolved_model_scopes
test_reused_quota_cannot_authorize_selection_or_launch
test_model_scope_representations_constrain_the_same_families
test_recovery_respects_legacy_versioned_and_unresolved_scopes
test_remaining_quota_is_checked_at_control_and_spawn
test_recovery_refuses_quota_exhausted_after_selection
test_launch_checks_use_retained_and_overridden_models
