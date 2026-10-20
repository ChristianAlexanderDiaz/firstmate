#!/usr/bin/env bash
# Behavior tests for Claude account failover (bin/fm-account-failover.sh,
# config/claude-failover, fm-control.sh/fm-spawn.sh --claude-account).
#
# Hermetic: a lifecycle-modelling tmux stub stands in for the terminal (its
# viewport shows Claude's captured usage-limit prompt until Escape closes it,
# or an inline repeat limit above an idle composer; its
# exit command stops the agent, and a launch starts a fresh one), and fakes
# stand in for `claude auth status`, `quota-axi --all-accounts --json`, and
# `no-mistakes`. tests/fm-account-failover-live-e2e.test.sh exercises recovery
# against real Claude Code; docs/verification/runtime-backends.md owns the
# captured prompt, hook payload, and Escape outcome.
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
        *cursor_y*) cat "$D/cursor-y" 2>/dev/null || printf '1\n'; exit 0 ;;
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
    model=claude-fable-5-1 effort=default
  CASE_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id") || fail "could not arm fixture turn state"
  printf 'busy_gen=%s\n' "$CASE_GEN" >> "$dir/home/state/$id.meta"
  TASK_TMPS+=("/tmp/fm-$id")
  printf 'account limited ordinary\naccount spare %s\n' "$dir/accounts/spare" > "$dir/home/config/claude-failover"
  # Keep the home off the supervision host, which a Claude caller would
  # otherwise turn on, so its lease lock never depends on who runs the suite.
  : > "$dir/home/config/supervision-host-off"
  printf '%s' "$LIMIT_SCREEN" > "$dir/fake/screen"
  quota_snapshot 0 81 > "$dir/fake/quota.json"
  if [ "$kind" = secondmate ]; then
    mkdir -p "$dir/wt/state" "$dir/wt/data" "$dir/wt/bin" "$dir/wt/.claude"
    printf '%s\n' "$id" > "$dir/wt/.fm-secondmate-home"
    printf '# agents\n' > "$dir/wt/AGENTS.md"
    printf '# standing charter\n' > "$dir/wt/data/charter.md"
    printf '{"permissions":{"deny":["Agent"]}}\n' > "$dir/wt/.claude/settings.local.json"
    printf 'home=%s\n' "$dir/wt" >> "$dir/home/state/$id.meta"
    printf 'claude\n' > "$dir/home/config/secondmate-harness"
  fi
}

# quota_snapshot <limited-percent> <spare-percent> [jq-filter]: an
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
  local id=$1 error=${2:-rate_limit} message=${3-$LIMIT_TEXT} gen
  gen=$(sed -n 's/^busy_gen=//p' "$CASE/home/state/$id.meta" | tail -1)
  case_env "$ROOT/bin/fm-busy-event.sh" apply "$CASE/home/state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop-failure || fail "could not close the fixture turn"
  jq -nc --arg e "$error" --arg m "$message" '{hook_event_name: "StopFailure", error: $e, last_assistant_message: $m}' |
    case_env "$FAILOVER" record "$CASE/home/config" "$CASE/home/state" "$id" "$gen"
}

# The task's supervisor-actionable status lines, if any.
status_of() { cat "$CASE/home/state/$1.status" 2>/dev/null; }

# --- record ------------------------------------------------------------------

test_record_writes_a_usage_limit_record_only_for_a_rate_limit_with_the_map() {
  local marker
  new_case record-map t1
  record_limit t1 server_error "Internal server error"
  [ ! -e "$CASE/home/state/t1.usage-limit" ] || fail "a non-rate-limit turn end must not be recorded"
  record_limit t1
  marker=$(cat "$CASE/home/state/t1.usage-limit" 2>/dev/null) || fail "a rate-limit turn end should be recorded"
  assert_contains "$marker" "gen=$CASE_GEN" "the record must name the hook's busy generation"
  assert_contains "$marker" "config_dir_set=0" "the record must say the worker ran with CLAUDE_CONFIG_DIR unset"
  assert_contains "$marker" "message=$LIMIT_TEXT" "the record must carry Claude's limit text"
  jq -nc '{error: "rate_limit", last_assistant_message: "limit"}' |
    case_env CLAUDE_CONFIG_DIR="$CASE/accounts/spare" "$FAILOVER" record "$CASE/home/config" "$CASE/home/state" t1 "$CASE_GEN"
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
  # The prompt gets exactly one key, its cancel. After that, no other input
  # reaches the terminal until the old worker's exit command: no option number,
  # arrow, or Enter can land on a paid choice.
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

test_turn_hooks_invalidate_superseded_limits() {
  local event id out failure hook marker gen
  for event in UserPromptSubmit Stop SessionEnd; do
    id="t34-$event"
    new_case "superseded-$event" "$id"
    rm -f "$CASE/fake/screen"
    printf zsh > "$CASE/fake/command"
    out=$(case_env "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1)
    expect_code 0 $? "the hook fixture must launch: $out"
    rm -f "$CASE/fake/nm-calls" "$CASE/fake/quota-calls"
    failure=$(jq -r '.hooks.StopFailure[0].hooks[0].command' "$CASE/wt/.claude/settings.local.json")
    hook=$(jq -r --arg event "$event" '.hooks[$event][0].hooks[0].command' "$CASE/wt/.claude/settings.local.json")
    jq -nc --arg m "$LIMIT_TEXT" '{error: "rate_limit", last_assistant_message: $m}' | case_env bash -c "$failure"
    marker=$(cat "$CASE/home/state/$id.usage-limit") || fail "the generated failure hook must record the limit"
    case_env bash -c "$hook" || fail "$event hook must succeed"
    assert_absent "$CASE/home/state/$id.usage-limit" "$event must invalidate the pending limit"
    printf '%s\n' "$marker" > "$CASE/home/state/$id.usage-limit"
    printf running > "$CASE/fake/nm-state"
    : > "$CASE/fake/literal"
    : > "$CASE/fake/keys"
    out=$(case_env "$FAILOVER" run "$id" 2>&1)
    assert_contains "$out" "skipped $id" "a superseded report must be skipped: $out"
    assert_equals running "$(cat "$CASE/fake/nm-state")" "$event must preserve validation"
    assert_absent "$CASE/fake/nm-calls" "a superseded turn must not inspect or cancel validation"
    assert_absent "$CASE/fake/quota-calls" "a superseded turn must not read quota"
    [ ! -s "$CASE/fake/keys" ] && [ ! -s "$CASE/fake/literal" ] || fail "$event must leave the worker untouched"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$CASE/home/state" "$id")
    printf 'v1\ngen=%s\n' "$gen" > "$CASE/home/state/$id.usage-limit"
    case_env bash -c "$hook" || fail "a stale hook must tolerate its refusal"
    assert_present "$CASE/home/state/$id.usage-limit" "a stale $event hook must not invalidate a new incarnation's limit"
  done
  pass "recovery: generated turn hooks invalidate superseded limits and stale hooks preserve newer incarnations"
}

test_recovery_rechecks_the_turn_before_cancellation_and_stopping() {
  local stage id out failure submit trigger prior_meta prior_brief
  for stage in quota validation pre-stop; do
    id="t35-$stage"
    new_case "turn-race-$stage" "$id"
    rm -f "$CASE/fake/screen"
    printf zsh > "$CASE/fake/command"
    out=$(case_env "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1)
    expect_code 0 $? "the hook fixture must launch: $out"
    failure=$(jq -r '.hooks.StopFailure[0].hooks[0].command' "$CASE/wt/.claude/settings.local.json")
    submit=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$CASE/wt/.claude/settings.local.json")
    printf '%s\n' "$submit" > "$CASE/new-turn.sh"
    jq -nc --arg m "$LIMIT_TEXT" '{error: "rate_limit", last_assistant_message: $m}' | case_env bash -c "$failure"
    prior_meta=$(cat "$CASE/home/state/$id.meta")
    prior_brief=$(cat "$CASE/home/data/$id/brief.md")
    : > "$CASE/fake/literal"
    : > "$CASE/fake/keys"
    if [ "$stage" = validation ]; then
      mv "$CASE/fakebin/no-mistakes" "$CASE/fakebin/nm-base"
      cat > "$CASE/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$*" = axi ]; then bash '$CASE/new-turn.sh'; fi
exec '$CASE/fakebin/nm-base' "\$@"
SH
      chmod +x "$CASE/fakebin/no-mistakes"
    else
      trigger=1
      [ "$stage" != pre-stop ] || trigger=2
      mv "$CASE/fakebin/quota-axi" "$CASE/fakebin/quota-base"
      cat > "$CASE/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf x >> '$CASE/fake/read-count'
if [ "\$(wc -c < '$CASE/fake/read-count' | tr -d ' ')" = '$trigger' ]; then bash '$CASE/new-turn.sh'; fi
exec '$CASE/fakebin/quota-base' "\$@"
SH
      chmod +x "$CASE/fakebin/quota-axi"
    fi
    [ "$stage" = pre-stop ] || printf running > "$CASE/fake/nm-state"
    out=$(case_env "$FAILOVER" run "$id" 2>&1)
    assert_contains "$out" "skipped $id" "a newer turn during $stage must supersede recovery: $out"
    [ ! -e "$CASE/fake/nm-calls" ] || assert_no_grep 'axi abort' "$CASE/fake/nm-calls" "a newer turn must not cause validation cancellation"
    if [ "$stage" != pre-stop ]; then
      assert_equals running "$(cat "$CASE/fake/nm-state")" "validation must remain running"
    fi
    assert_equals claude "$(cat "$CASE/fake/command")" "the newer turn's worker must remain running"
    [ ! -s "$CASE/fake/keys" ] && [ ! -s "$CASE/fake/literal" ] || fail "a newer turn must receive no stop or launch input"
    assert_equals "$prior_meta" "$(cat "$CASE/home/state/$id.meta")" "supersession must preserve the worker record"
    assert_equals "$prior_brief" "$(cat "$CASE/home/data/$id/brief.md")" "supersession must preserve the original brief"
  done
  pass "recovery: a newer submitted turn during quota, validation discovery, or pre-stop checks prevents the move"
}

test_verified_usage_limit_without_a_menu_moves_without_escape() {
  local scenario message id out
  for scenario in straight typographic straight-c typographic-c; do
    id="t29-$scenario"
    new_case "inline-$scenario" "$id"
    message=$LIMIT_TEXT
    case "$scenario" in
      typographic*) message="You’ve hit your weekly limit · resets Oct 10 at 4pm (America/New_York)" ;;
    esac
    printf '%s\n╭────╮\n│    │\n╰────╯\n' "$message" > "$CASE/fake/screen"
    printf '2\n' > "$CASE/fake/cursor-y"
    printf 'running' > "$CASE/fake/nm-state"
    record_limit "$id" rate_limit "$message"
    case "$scenario" in
      *-c) out=$(case_env LC_ALL=C "$FAILOVER" run "$id" 2>&1) ;;
      *) out=$(case_env "$FAILOVER" run "$id" 2>&1) ;;
    esac
    assert_contains "$out" "moved $id limited spare" "a verified inline usage limit must move: $out"
    assert_no_grep 'key:Escape' "$CASE/fake/events" "an absent limit menu must receive no Escape"
    assert_equals 'text:/exit' "$(head -1 "$CASE/fake/events")" "no key is sent before normal relaunch"
    assert_grep 'claude_account=spare' "$CASE/home/state/$id.meta" "the replacement account is recorded"
    assert_grep 'axi abort --run RUN1' "$CASE/fake/nm-calls" "inline exhaustion still cancels active validation"
    assert_grep 'no-mistakes run RUN1 was aborted' "$CASE/home/data/$id/brief.md" "the handoff gives fresh-run instructions"
    assert_grep 'no usage-limit menu was shown' "$CASE/home/data/$id/brief.md" "the emitted handoff describes inline exhaustion"
    assert_no_grep 'chose that limit' "$CASE/home/data/$id/brief.md" "the emitted handoff must not claim a menu choice"
    [ ! -e "$CASE/home/state/$id.usage-limit" ] || fail "the inline limit event must be consumed"
    [ -z "$(status_of "$id")" ] || fail "successful inline recovery raises no blocked line"
  done
  pass "run: verified inline exhaustion with either apostrophe moves without Escape in default and C locales"
}

test_verified_usage_limit_without_room_and_menu_blocks_once() {
  local out meta brief
  new_case inline-none t30
  printf '%s\n╭────╮\n│    │\n╰────╯\n' "$LIMIT_TEXT" > "$CASE/fake/screen"
  printf '2\n' > "$CASE/fake/cursor-y"
  printf 'running' > "$CASE/fake/nm-state"
  meta=$(cat "$CASE/home/state/t30.meta")
  brief=$(cat "$CASE/home/data/t30/brief.md")
  quota_snapshot 0 3 > "$CASE/fake/quota.json"
  record_limit t30
  out=$(case_env "$FAILOVER" run t30 2>&1)
  assert_contains "$out" 'blocked t30' "verified inline exhaustion without room must block: $out"
  [ "$(status_of t30 | grep -c '^blocked: ')" = 1 ] || fail "inline exhaustion reports exactly one blocked line"
  assert_contains "$(status_of t30)" 'resets 2026-10-06T22:59Z' "the alternative reset is reported"
  assert_contains "$(status_of t30)" 'resets 2026-10-03T19:59Z' "the exhausted account reset is reported"
  assert_contains "$(status_of t30)" "$LIMIT_TEXT" "the verified limit text is reported"
  [ ! -s "$CASE/fake/keys" ] || fail "inline exhaustion without room sends no key"
  [ ! -s "$CASE/fake/literal" ] || fail "inline exhaustion without room leaves the worker stopped"
  [ ! -e "$CASE/fake/nm-calls" ] || fail "no qualifying account must preserve validation"
  assert_equals "$meta" "$(cat "$CASE/home/state/t30.meta")" "the stopped worker's record stays intact"
  assert_equals "$brief" "$(cat "$CASE/home/data/t30/brief.md")" "no move creates no handoff"
  out=$(case_env "$FAILOVER" run t30 2>&1)
  assert_contains "$out" 'skipped t30' "the inline event is not consumed twice: $out"
  [ "$(status_of t30 | grep -c '^blocked: ')" = 1 ] || fail "rechecking adds no blocked line"
  pass "run: verified inline exhaustion without room blocks once with reset times"
}

test_unconfirmed_rate_limits_leave_validation_and_worker_untouched() {
  local scenario id message out meta brief
  for scenario in run tick control text-only leading-text limitless stop-only cancel-only; do
    id="t8-$scenario"
    new_case "transient-$scenario" "$id"
    rm -f "$CASE/fake/screen"
    message="API Error: Rate limit reached"
    case "$scenario" in
      text-only) message="You've hit a rate limit" ;;
      leading-text) message="API Error: $LIMIT_TEXT" ;;
      limitless) message="You've hit your weekly limitless quota" ;;
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
    assert_contains "$out" "skipped $id" "$scenario without verified exhaustion must be skipped: $out"
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
  pass "recovery: throttling, unverified exhaustion text, and partial prompts leave validation and the worker untouched"
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
  case_env "$ROOT/bin/fm-busy-event.sh" apply "$CASE/home/state" t9 idle --gen "$gen" --source claude-hook --event stop-failure
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
    assert_grep "busy_gen=$CASE_GEN" "$CASE/home/state/t14.meta" "$mode refusal preserves the generation"
  done
  pass "run: gate, lease, and lifecycle boundaries protect all recovery mutations"
}

test_recovery_requires_a_restart_capable_backend_before_any_mutation() {
  local backend kind entry tool window out rc marker meta brief screen
  for backend in zellij orca cmux; do
    for kind in ship scout; do
      for entry in run tick control; do
        new_case "capability-$backend-$kind-$entry" t29 "$kind"
        printf 'running' > "$CASE/fake/nm-state"
        case "$backend" in
          zellij)
            window=fmses:7
            printf 'zellij_session=fmses\nzellij_tab_id=1\nzellij_pane_id=7\n' >> "$CASE/home/state/t29.meta"
            ;;
          orca)
            window=fm-t29
            printf 'terminal=term-1\norca_worktree_id=wt-1::%s\n' "$CASE/wt" >> "$CASE/home/state/t29.meta"
            ;;
          cmux)
            window=ws1:surface1
            printf 'cmux_workspace_id=ws1\ncmux_surface_id=surface1\n' >> "$CASE/home/state/t29.meta"
            ;;
        esac
        printf 'backend=%s\n' "$backend" >> "$CASE/home/state/t29.meta"
        sed "s/^window=.*/window=$window/" "$CASE/home/state/t29.meta" > "$CASE/home/state/t29.meta.new"
        mv "$CASE/home/state/t29.meta.new" "$CASE/home/state/t29.meta"
        for tool in zellij orca cmux; do
          cat > "$CASE/fakebin/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/backend-calls"
exit 1
SH
          chmod +x "$CASE/fakebin/$tool"
        done
        record_limit t29
        marker=$(cat "$CASE/home/state/t29.usage-limit")
        meta=$(cat "$CASE/home/state/t29.meta")
        brief=$(cat "$CASE/home/data/t29/brief.md")
        screen=$(cat "$CASE/fake/screen")
        case "$entry" in
          run) out=$(case_env "$FAILOVER" run t29 2>&1); rc=$? ;;
          tick) out=$(case_env "$FAILOVER" tick 2>&1); rc=$? ;;
          control) out=$(case_env "$CONTROL" t29 relaunch --usage-limit 2>&1); rc=$? ;;
        esac
        if [ "$entry" = tick ]; then
          expect_code 0 "$rc" "tick reports the refused $backend recovery without failing its cycle: $out"
          assert_contains "$out" "skipped t29" "tick must report the refused recovery"
        else
          expect_code 1 "$rc" "$backend recovery must refuse: $out"
          assert_contains "$out" "no recovery-grade agent-state classifier" "the refusal must name the missing restart capability"
        fi
        assert_equals "$marker" "$(cat "$CASE/home/state/t29.usage-limit")" "$backend $entry must preserve the event"
        assert_equals "$meta" "$(cat "$CASE/home/state/t29.meta")" "$backend $entry must preserve the worker record"
        assert_equals "$brief" "$(cat "$CASE/home/data/t29/brief.md")" "$backend $entry must not create a handoff"
        assert_equals "$screen" "$(cat "$CASE/fake/screen")" "$backend $entry must leave the prompt open"
        assert_equals running "$(cat "$CASE/fake/nm-state")" "$backend $entry must preserve active validation"
        [ ! -e "$CASE/fake/nm-calls" ] || fail "$backend $entry must not touch validation"
        [ ! -e "$CASE/fake/quota-calls" ] || fail "$backend $entry must not select another account"
        [ ! -e "$CASE/fake/backend-calls" ] || fail "$backend $entry must not access the terminal"
        [ ! -s "$CASE/fake/keys" ] && [ ! -s "$CASE/fake/literal" ] || fail "$backend $entry must not send keys or commands"
      done
    done
  done
  pass "recovery: unsupported restart backends preserve the event, prompt, worker, and validation"
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

# --- Claude account pacing beside failover -----------------------------------

test_paced_relaunch_refuses_before_stopping_when_no_account_qualifies() {
  local out rc boundary reason id=t33
  for boundary in control spawn; do
    for reason in paid stale failed; do
      new_case "paced-refusal-$boundary-$reason" "$id"
      rm -f "$CASE/fake/screen"
      printf 'paced\n' > "$CASE/home/config/claude-account"
      cp "$CASE/home/state/$id.meta" "$CASE/prior.meta"
      cp "$CASE/home/data/$id/brief.md" "$CASE/prior-brief.md"
      quota_snapshot 0 81 '.providers[1].windows += [{id: "extra_usage", kind: "credits", percentRemaining: 50}]' > "$CASE/fake/quota.json"
      case "$reason" in
        stale) quota_snapshot 60 81 '.providers[].state = {status: "stale", stale: true}' > "$CASE/fake/quota.json" ;;
        failed) rm "$CASE/fake/quota.json" ;;
      esac
      if [ "$boundary" = control ]; then
        out=$(case_env QUOTA_AXI_MAX_AGE=1h "$CONTROL" "$id" relaunch --note "refused" 2>&1); rc=$?
        assert_equals claude "$(cat "$CASE/fake/command")" "the existing worker must remain running"
        [ ! -s "$CASE/fake/literal" ] || fail "pacing refusal must send no stop or launch text"
        cmp -s "$CASE/prior-brief.md" "$CASE/home/data/$id/brief.md" || fail "the original brief must remain unchanged"
      else
        printf zsh > "$CASE/fake/command"
        out=$(case_env "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1); rc=$?
        [ ! -s "$CASE/fake/literal" ] || fail "spawn's independent pacing check must refuse the launch"
      fi
      expect_code 1 "$rc" "a paced $boundary without qualifying accounts must refuse: $out"
      assert_contains "$out" 'error: Claude account pacing:' "the refusal names pacing"
      cmp -s "$CASE/prior.meta" "$CASE/home/state/$id.meta" || fail "a refused replacement must retain the prior task record"
      if [ "$reason" != failed ]; then
        assert_contains "$out" '% week left, resets 2026-10-03T19:59Z' "the refusal shows the first weekly allowance and reset"
        assert_contains "$out" 'spare 81% week left, resets 2026-10-06T22:59Z' "the refusal shows the other weekly allowance and reset"
      fi
    done
  done
  pass "pacing: control refuses before stopping; spawn independently refuses an unsafe replacement"
}

test_paced_relaunches_choose_afresh_and_failover_still_moves() {
  local out rc
  new_case paced-relaunch t31
  rm -f "$CASE/fake/screen"
  printf 'paced\n' > "$CASE/home/config/claude-account"
  quota_snapshot 60 81 '.providers[0].windows[1].pace = {status: "behind", reservePercentPoints: 10}
    | .providers[1].windows[1].pace = {status: "behind", reservePercentPoints: 20}' > "$CASE/fake/quota.json"
  out=$(case_env "$CONTROL" t31 relaunch --note "paced" 2>&1); rc=$?
  expect_code 0 "$rc" "a paced relaunch should succeed: $out"
  assert_grep 'claude_account=limited' "$CASE/home/state/t31.meta" "the nearest reset on pace gets the replacement"
  assert_grep 'claude_account_reason=chose limited: limited 60% week left, resets 2026-10-03T19:59Z, on or behind pace' \
    "$CASE/home/state/t31.meta" "the reason is recorded"
  assert_no_grep "CLAUDE_CONFIG_DIR='$CASE/accounts/spare'" "$CASE/fake/literal" "the replacement runs on the paced account"
  assert_equals 2 "$(wc -l < "$CASE/fake/quota-calls" | tr -d ' ')" "control and spawn each request a fresh pacing snapshot"
  quota_snapshot 60 81 '.providers[0].windows[1].pace = {status: "ahead", reservePercentPoints: -10}' > "$CASE/fake/quota.json"
  : > "$CASE/fake/literal"
  out=$(case_env "$CONTROL" t31 relaunch --note "paced again" 2>&1); rc=$?
  expect_code 0 "$rc" "a second paced relaunch should succeed: $out"
  assert_grep 'claude_account=spare' "$CASE/home/state/t31.meta" "every relaunch chooses afresh rather than keeping the last account"
  assert_grep "CLAUDE_CONFIG_DIR='$CASE/accounts/spare'" "$CASE/fake/literal" "the replacement runs on the newly chosen account"
  rm "$CASE/home/config/claude-failover"
  : > "$CASE/fake/literal"
  out=$(case_env "$CONTROL" t31 relaunch --note "no map" 2>&1); rc=$?
  expect_code 1 "$rc" "pacing without accounts to pace must refuse: $out"
  assert_contains "$out" "selects pacing across the accounts of config/claude-failover" "the refusal names the missing map"
  assert_no_grep '/exit' "$CASE/fake/literal" "the refusal happens before the worker stops"

  new_case paced-failover t32
  printf 'paced\n' > "$CASE/home/config/claude-account"
  record_limit t32 rate_limit ""
  out=$(case_env "$FAILOVER" tick 2>&1)
  assert_contains "$out" "moved t32 limited spare" "failover still moves a worker beside the paced pin: $out"
  assert_grep 'claude_account=spare' "$CASE/home/state/t32.meta" "the failover account is recorded"
  assert_no_grep 'claude_account_reason=' "$CASE/home/state/t32.meta" "a failover move is not a pacing choice"
  pass "pacing: every paced relaunch chooses afresh, and failover still moves a limited worker beside the paced pin"
}

test_secondmate_failover() {
  local out settings failure gen
  new_case secondmate-move sm33 secondmate
  mkdir -p "$CASE/home/state/sm33.inbox"
  printf 'pending instruction\n' > "$CASE/home/state/sm33.inbox/001.msg"
  printf 'unlanded child work\n' > "$CASE/wt/state/child.status"
  record_limit sm33
  out=$(case_env "$FAILOVER" run sm33 2>&1)
  assert_contains "$out" 'moved sm33 limited spare' "the secondmate moves to the account with room: $out"
  assert_grep "home=$CASE/wt" "$CASE/home/state/sm33.meta" "the home is retained"
  assert_grep 'claude_account=spare' "$CASE/home/state/sm33.meta" "the moved account is durable"
  assert_equals '# standing charter' "$(cat "$CASE/wt/data/charter.md")" "the standing charter survives"
  assert_equals 'pending instruction' "$(cat "$CASE/home/state/sm33.inbox/001.msg")" "the steering inbox survives"
  assert_equals 'unlanded child work' "$(cat "$CASE/wt/state/child.status")" "child state survives"
  assert_equals '{"permissions":{"deny":["Agent"]}}' "$(cat "$CASE/wt/.claude/settings.local.json")" "home settings survive"
  # Decode the shell launch via Python's shell lexer, rather than assuming the
  # inline JSON's quoting. Execute the installed recorder with its real payload.
  settings=$(python3 - "$CASE/fake/literal" <<'PY'
import shlex, sys
for line in open(sys.argv[1]):
    args = shlex.split(line)
    if '--settings' in args:
        print(args[args.index('--settings') + 1])
PY
  )
  failure=$(printf '%s' "$settings" | jq -r '.hooks.StopFailure[0].hooks[0].command')
  gen=$(sed -n 's/^busy_gen=//p' "$CASE/home/state/sm33.meta")
  [ -n "$gen" ] || fail "the secondmate must arm a parent generation"
  jq -nc --arg m "$LIMIT_TEXT" '{error:"rate_limit",last_assistant_message:$m}' |
    case_env CLAUDE_CONFIG_DIR="$CASE/accounts/spare" bash -c "$failure"
  assert_grep "gen=$gen" "$CASE/home/state/sm33.usage-limit" "the installed hook records the replacement generation"
  assert_grep "config_dir=$CASE/accounts/spare" "$CASE/home/state/sm33.usage-limit" "the installed hook records the replacement account"
  # The endpoint-dead auto-recovery path also goes through --secondmate.
  printf zsh > "$CASE/fake/command"
  : > "$CASE/fake/windows"
  out=$(case_env "$ROOT/bin/fm-spawn.sh" sm33 --secondmate 2>&1)
  expect_code 0 $? "secondmate recovery succeeds: $out"
  assert_grep 'claude_account=spare' "$CASE/home/state/sm33.meta" "recovery retains the moved account"
  assert_equals 'pending instruction' "$(cat "$CASE/home/state/sm33.inbox/001.msg")" "recovery retains the inbox"
  pass "secondmate: failover and recovery preserve home, inbox, charter, child state, settings and rearm StopFailure"

  new_case secondmate-pin sm34 secondmate
  printf 'ordinary\n' > "$CASE/home/config/claude-account"
  record_limit sm34
  out=$(case_env "$FAILOVER" run sm34 2>&1)
  assert_contains "$out" 'pins every Claude worker' "a pinned secondmate stays stopped: $out"
  assert_no_grep '/exit' "$CASE/fake/literal" "a pinned secondmate is not relaunched"

  new_case secondmate-stale sm35 secondmate
  record_limit sm35
  case_env "$ROOT/bin/fm-busy-event.sh" arm "$CASE/home/state" sm35 >/dev/null
  out=$(case_env "$FAILOVER" run sm35 2>&1)
  assert_contains "$out" 'skipped sm35' "a superseded secondmate limit is ignored: $out"
  [ ! -e "$CASE/home/state/sm35.usage-limit" ] || fail "stale limit is consumed"
  pass "secondmate: pins prevent moves and stale limit records are dropped"
}

test_exhaustion_episode_is_shared() {
  local out
  new_case secondmate-exhausted sm36 secondmate
  quota_snapshot 0 0 > "$CASE/fake/quota.json"
  record_limit sm36
  out=$(case_env "$FAILOVER" run sm36 2>&1)
  assert_contains "$out" 'blocked sm36' "the first exhaustion emits an outcome: $out"
  # Another mate in the SAME launching home, with its own incarnation.
  sed 's/sm36/sm37/g; /^busy_gen=/d' "$CASE/home/state/sm36.meta" > "$CASE/home/state/sm37.meta"
  printf 'fm-sm37\n' >> "$CASE/fake/windows"
  CASE_GEN=$(case_env "$ROOT/bin/fm-busy-event.sh" arm "$CASE/home/state" sm37)
  printf 'busy_gen=%s\n' "$CASE_GEN" >> "$CASE/home/state/sm37.meta"
  record_limit sm37
  out=$(case_env "$FAILOVER" run sm37 2>&1)
  assert_contains "$out" 'already reported' "another mate cannot duplicate the outcome: $out"
  [ ! -s "$CASE/home/state/sm37.status" ] || fail "another mate emitted a duplicate outcome"
  assert_contains "$(status_of sm36)" 'limited:' "the notice names the first account"
  assert_contains "$(status_of sm36)" 'spare:' "the notice names the spare account"
  assert_contains "$(status_of sm36)" 'resets 2026-10-03T19:59Z' "the notice names the first reset"
  assert_contains "$(status_of sm36)" 'resets 2026-10-06T22:59Z' "the notice names the other reset"
  # A reset observed by the watcher re-arms the notice, with no task record.
  quota_snapshot 0 81 > "$CASE/fake/quota.json"
  touch -t 200001010000 "$CASE/home/state/.claude-exhausted"
  case_env "$FAILOVER" tick >/dev/null
  quota_snapshot 0 0 > "$CASE/fake/quota.json"
  record_limit sm36
  out=$(case_env "$FAILOVER" run sm36 2>&1)
  assert_contains "$out" 'blocked sm36' "a later episode emits a new outcome: $out"
  assert_equals 2 "$(grep -c '^blocked:' "$CASE/home/state/sm36.status")" "one notice per episode"
  pass "secondmate: all-exhausted emits one home-wide outcome with resets per episode"
}

test_unrelated_model_moves_preserve_exhaustion() {
  local kind out
  for kind in ship scout secondmate; do
    new_case "model-episode-$kind" t38 "$kind"
    printf 'model=opus\n' >> "$CASE/home/state/t38.meta"
    printf 'claude opus\n' > "$CASE/home/config/secondmate-harness"
    represented_scope_snapshot seven_day_opus > "$CASE/fake/quota.json"
    record_limit t38
    out=$(case_env "$FAILOVER" run t38 2>&1)
    assert_contains "$out" 'blocked t38' "Opus exhaustion is reported: $out"
    assert_equals opus "$(cat "$CASE/home/state/.claude-exhausted")" "the marker owns the exhausted model"
    printf 'model=sonnet\n' >> "$CASE/home/state/t38.meta"
    printf 'claude sonnet\n' > "$CASE/home/config/secondmate-harness"
    record_limit t38
    out=$(case_env "$FAILOVER" run t38 2>&1)
    assert_contains "$out" 'moved t38 limited spare' "Sonnet still moves: $out"
    assert_equals opus "$(cat "$CASE/home/state/.claude-exhausted")" "a $kind move cannot rearm Opus"
    touch -t 200001010000 "$CASE/home/state/.claude-exhausted"
    case_env "$FAILOVER" tick >/dev/null
    assert_equals opus "$(cat "$CASE/home/state/.claude-exhausted")" "Sonnet room cannot rearm Opus in maintenance"
    printf 'model=opus\n' >> "$CASE/home/state/t38.meta"
    printf 'claude opus\n' > "$CASE/home/config/secondmate-harness"
    record_limit t38
    out=$(case_env "$FAILOVER" run t38 2>&1)
    assert_contains "$out" 'already reported' "another Opus limit stays deduplicated: $out"
    assert_equals 1 "$(grep -c '^blocked:' "$CASE/home/state/t38.status")" "one notice persists across the unrelated move"
    quota_snapshot 0 81 > "$CASE/fake/quota.json"
    touch -t 200001010000 "$CASE/home/state/.claude-exhausted"
    case_env "$FAILOVER" tick >/dev/null
    [ ! -e "$CASE/home/state/.claude-exhausted" ] || fail "recovered Opus rearms the notice"
    quota_snapshot 0 0 > "$CASE/fake/quota.json"
    record_limit t38
    out=$(case_env "$FAILOVER" run t38 2>&1)
    assert_contains "$out" 'blocked t38' "new exhaustion after recovery emits a notice: $out"
    assert_equals 2 "$(grep -c '^blocked:' "$CASE/home/state/t38.status")" "recovery starts a new episode"
  done
  pass "exhaustion: unrelated model moves and maintenance preserve the recorded episode"
}

test_successful_recovery_rearms_before_maintenance() {
  local kind model out
  for kind in ship scout secondmate; do
    for model in opus claude-opus-4-6; do
      new_case "recovery-episode-$kind-$model" t40 "$kind"
      printf 'model=%s\n' "$model" >> "$CASE/home/state/t40.meta"
      printf 'claude %s\n' "$model" > "$CASE/home/config/secondmate-harness"
      quota_snapshot 0 0 > "$CASE/fake/quota.json"
      record_limit t40
      out=$(case_env "$FAILOVER" run t40 2>&1)
      assert_contains "$out" 'blocked t40' "initial exhaustion emits a notice: $out"
      assert_equals "$model" "$(cat "$CASE/home/state/.claude-exhausted")" "the model owns its exhaustion episode"
      quota_snapshot 0 81 > "$CASE/fake/quota.json"
      case_env "$FAILOVER" tick >/dev/null
      [ -f "$CASE/home/state/.claude-exhausted" ] || fail "maintenance is still cooling down"
      : > "$CASE/fake/quota-calls"
      record_limit t40
      out=$(case_env "$FAILOVER" run t40 2>&1)
      assert_contains "$out" 'moved t40 limited spare' "$kind recovers on fresh $model quota: $out"
      [ ! -e "$CASE/home/state/.claude-exhausted" ] || fail "successful recovery must rearm without maintenance"
      assert_equals 3 "$(wc -l < "$CASE/fake/quota-calls" | tr -d ' ')" "rearming reuses selection quota, alongside the two launch readings"
      quota_snapshot 0 0 > "$CASE/fake/quota.json"
      record_limit t40
      out=$(case_env "$FAILOVER" run t40 2>&1)
      assert_contains "$out" 'blocked t40' "exhaustion after recovery emits a new notice: $out"
      assert_equals 2 "$(grep -c '^blocked:' "$CASE/home/state/t40.status")" "recovery starts a new exhaustion episode immediately"
      record_limit t40
      out=$(case_env "$FAILOVER" run t40 2>&1)
      assert_contains "$out" 'already reported' "the new episode remains deduplicated: $out"
      assert_equals 2 "$(grep -c '^blocked:' "$CASE/home/state/t40.status")" "repeated exhaustion emits no duplicate notice"
    done
  done
  pass "exhaustion: successful same-model recovery rearms before the maintenance cooldown"
}

test_maintenance_rechecks_are_bounded_and_throttled() {
  local mode out
  for mode in failed hung malformed auth-hung; do
    new_case "maintenance-$mode" t39 secondmate
    quota_snapshot 0 0 > "$CASE/fake/quota.json"
    record_limit t39
    case_env "$FAILOVER" run t39 >/dev/null
    : > "$CASE/fake/quota-calls"
    case_env "$FAILOVER" tick >/dev/null
    [ ! -s "$CASE/fake/quota-calls" ] || fail "a new episode waits for its cooldown"
    touch -t 200001010000 "$CASE/home/state/.claude-exhausted"
    mv "$CASE/fakebin/quota-axi" "$CASE/fakebin/quota-base"
    cat > "$CASE/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
case "$FM_MAINTENANCE_FAILURE" in
  hung) printf 'hung\n' >> "$FM_FAKE_DIR/quota-calls"; exec python3 -c 'import time; time.sleep(30)' ;;
  *) exec "$(dirname "$0")/quota-base" "$@" ;;
esac
SH
    chmod +x "$CASE/fakebin/quota-axi"
    case "$mode" in
      failed) rm "$CASE/fake/quota.json" ;;
      malformed) printf 'invalid\n' > "$CASE/fake/quota.json" ;;
      auth-hung)
        quota_snapshot 0 81 > "$CASE/fake/quota.json"
        mv "$CASE/fakebin/claude" "$CASE/fakebin/claude-base"
        cat > "$CASE/fakebin/claude" <<'SH'
#!/usr/bin/env bash
exec python3 -c 'import time; time.sleep(30)'
SH
        chmod +x "$CASE/fakebin/claude"
        ;;
    esac
    printf 'v1\ngen=stale\n' > "$CASE/home/state/t39.usage-limit"
    out=$(case_env FM_MAINTENANCE_FAILURE="$mode" python3 - "$FAILOVER" <<'PYTEST'
import os, signal, subprocess, sys
p = subprocess.Popen([sys.argv[1], 'tick'], stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, text=True, start_new_session=True)
try:
    out, err = p.communicate(timeout=8)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.communicate()
    sys.exit('maintenance stalled ordinary tick processing')
print(out, end='')
sys.exit(p.returncode)
PYTEST
    ) || fail "$mode maintenance exceeded its responsiveness budget"
    assert_contains "$out" 'skipped t39' "pending events are processed after $mode maintenance: $out"
    [ ! -e "$CASE/home/state/t39.usage-limit" ] || fail "pending stale event is consumed"
    case_env FM_MAINTENANCE_FAILURE="$mode" "$FAILOVER" tick >/dev/null
    assert_equals 1 "$(wc -l < "$CASE/fake/quota-calls" | tr -d ' ')" "$mode attempts are throttled"
    [ -f "$CASE/home/state/.claude-exhausted" ] || fail "$mode cannot rearm exhaustion"
    mv "$CASE/fakebin/quota-base" "$CASE/fakebin/quota-axi"
    if [ "$mode" = auth-hung ]; then
      mv "$CASE/fakebin/claude-base" "$CASE/fakebin/claude"
    fi
    quota_snapshot 0 81 > "$CASE/fake/quota.json"
    case_env "$FAILOVER" tick >/dev/null
    assert_equals 1 "$(wc -l < "$CASE/fake/quota-calls" | tr -d ' ')" "restoration still respects the cooldown"
    touch -t 200001010000 "$CASE/home/state/.claude-exhausted"
    case_env "$FAILOVER" tick >/dev/null
    [ ! -e "$CASE/home/state/.claude-exhausted" ] || fail "a later successful check rearms exhaustion"
  done
  pass "maintenance: failures, hung quota and hung authentication stay bounded and throttled"
}

test_secondmate_failover
test_exhaustion_episode_is_shared
test_unrelated_model_moves_preserve_exhaustion
test_successful_recovery_rearms_before_maintenance
test_maintenance_rechecks_are_bounded_and_throttled

test_record_writes_a_usage_limit_record_only_for_a_rate_limit_with_the_map
test_absent_map_is_a_no_op
test_choose_picks_by_quota_and_respects_the_fixed_margin
test_choose_refuses_unknown_quota_and_paid_usage
test_limit_prompt_is_answered_with_stop_and_the_worker_moves_to_an_account_with_room
test_no_qualifying_account_leaves_the_worker_stopped_with_one_blocked_line
test_an_active_no_mistakes_run_is_aborted_before_the_move
test_stale_records_never_move_a_worker
test_turn_hooks_invalidate_superseded_limits
test_recovery_rechecks_the_turn_before_cancellation_and_stopping
test_verified_usage_limit_without_a_menu_moves_without_escape
test_verified_usage_limit_without_room_and_menu_blocks_once
test_unconfirmed_rate_limits_leave_validation_and_worker_untouched
test_a_second_usage_limit_moves_to_a_third_account
test_the_watcher_moves_a_limited_worker_and_wakes_once
test_relaunch_refuses_an_unusable_account_before_stopping_the_worker
test_a_moved_task_keeps_its_literal_account
test_unusable_preferred_accounts_are_filtered_before_validation
test_recovery_guards_precede_every_mutation
test_recovery_requires_a_restart_capable_backend_before_any_mutation
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
test_paced_relaunch_refuses_before_stopping_when_no_account_qualifies
test_paced_relaunches_choose_afresh_and_failover_still_moves
