#!/usr/bin/env bash
# Live guard for Claude account failover against the real Claude Code, in an
# isolated Herdr lab session.
#
# It needs a Claude account that is AT its usage limit right now, named by
# FM_ACCOUNT_FAILOVER_LIVE_ROOT (`ordinary` for CLAUDE_CONFIG_DIR unset, or an
# absolute Claude config directory), and proves the vendor surfaces
# bin/fm-account-failover.sh is built on:
#   1. A prompt to that account ends its turn through StopFailure with
#      "error": "rate_limit", and the real hook, wired to the production
#      recorder, writes the usage-limit record naming the account root and
#      Claude's limit text.
#   2. The production `run` handles the limit and leaves an idle composer,
#      answering a shown menu with Escape or accepting verified inline
#      exhaustion without a key. This guard does not separately assert that
#      a menu appeared or Escape was sent. quota-axi is faked to report no
#      account with room, so the guard stops at the blocked line and never moves anything.
# A limited account spends no model tokens, but the guard still submits a
# prompt, so it is opt-in: FM_ACCOUNT_FAILOVER_LIVE=1 (or FM_LIVE=1).
# Record a passing run in docs/verification/runtime-backends.md
# ("Claude usage-limit prompt").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate opt-in FM_ACCOUNT_FAILOVER_LIVE herdr jq claude

LIMIT_ROOT=${FM_ACCOUNT_FAILOVER_LIVE_ROOT:-}
[ -n "$LIMIT_ROOT" ] || fail "FM_ACCOUNT_FAILOVER_LIVE_ROOT must name a Claude account at its usage limit (ordinary or an absolute config directory); nothing was checked"
case "$LIMIT_ROOT" in
  ordinary | /*) ;;
  *) fail "FM_ACCOUNT_FAILOVER_LIVE_ROOT must be ordinary or an absolute path, got '$LIMIT_ROOT'" ;;
esac
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-afl)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
WORK="$TMP_ROOT/work"
ID=live1
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$WORK"
git -C "$WORK" init -q
printf '# Account failover live guard\n' > "$WORK/AGENTS.md"

# A short label: the lab's session socket path must fit the platform limit.
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-afl)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
PANE=
cleanup() {
  local status=$?
  if [ -n "$PANE" ]; then
    lab pane send-text "$PANE" /exit >/dev/null 2>&1 || true
    lab pane send-keys "$PANE" Enter >/dev/null 2>&1 || true
  fi
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision the isolated Herdr lab session"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# Production Herdr calls carry a trailing --session; route them through the lab.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
# No account has room, so the guard ends at the blocked line.
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '{"schemaVersion":7,"providers":[]}\n'
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/quota-axi"

printf 'account limited %s\n' "$LIMIT_ROOT" > "$HOME_DIR/config/claude-failover"

ws=$(lab workspace create --cwd "$WORK" --label fm-afl --no-focus) || fail "could not create a lab workspace: $ws"
PANE=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id // empty')
WORKSPACE=$(printf '%s' "$ws" | jq -r '.result.root_pane.workspace_id // .result.workspace.workspace_id // empty')
TAB=$(printf '%s' "$ws" | jq -r '.result.root_pane.tab_id // empty')
[ -n "$PANE" ] && [ -n "$WORKSPACE" ] && [ -n "$TAB" ] || fail "the lab workspace reported no pane, workspace, or tab: $ws"
BUSY_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$ID") || fail "could not arm the live turn state"
fm_write_meta "$HOME_DIR/state/$ID.meta" \
  "window=$HERDR_LAB_SESSION:$PANE" "endpoint_task_id=$ID" "worktree=$WORK" "project=$WORK" \
  harness=claude kind=scout "tasktmp=$TMP_ROOT/tasktmp" model=default effort=default "busy_gen=$BUSY_GEN" \
  backend=herdr "herdr_session=$HERDR_LAB_SESSION" "herdr_workspace_id=$WORKSPACE" \
  "herdr_tab_id=$TAB" "herdr_pane_id=$PANE"

# The same StopFailure recorder fm-spawn wires into every Claude ship and scout.
busy_prefix="'$ROOT/bin/fm-busy-event.sh' apply '$HOME_DIR/state' $ID"
busy_suffix="--gen '$BUSY_GEN' --source claude-hook"
recorder="$busy_prefix idle $busy_suffix --event stop-failure && '$ROOT/bin/fm-account-failover.sh' record '$HOME_DIR/config' '$HOME_DIR/state' $ID '$BUSY_GEN'"
jq -n --arg c "$recorder" --arg submit "$busy_prefix busy $busy_suffix --event user-prompt-submit" \
  --arg stop "$busy_prefix idle $busy_suffix --event stop" --arg end "$busy_prefix idle $busy_suffix --event session-end" \
  '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $submit}]}],
            Stop: [{hooks: [{type: "command", command: $stop}]}],
            SessionEnd: [{hooks: [{type: "command", command: $end}]}],
            StopFailure: [{hooks: [{type: "command", command: $c}]}]}}' > "$TMP_ROOT/settings.json"
if [ "$LIMIT_ROOT" = ordinary ]; then
  account_env="-u CLAUDE_CONFIG_DIR"
else
  account_env="CLAUDE_CONFIG_DIR='$LIMIT_ROOT'"
fi
lab pane run "$PANE" "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN $account_env claude --dangerously-skip-permissions --settings '$TMP_ROOT/settings.json' 'Reply with the single word hi.'" >/dev/null \
  || fail "could not start Claude in the lab pane"

screen() { lab pane read "$PANE" --source visible 2>/dev/null; }
trusted=0
for _ in $(seq 1 120); do
  [ ! -f "$HOME_DIR/state/$ID.usage-limit" ] || break
  # A scratch folder Claude has never seen opens on its trust dialog, with the
  # cursor on "No, exit".
  if [ "$trusted" = 0 ] && screen | grep -Fq 'Yes, I trust this folder'; then
    lab pane send-keys "$PANE" Down >/dev/null
    sleep 0.5
    lab pane send-keys "$PANE" Enter >/dev/null
    trusted=1
  fi
  sleep 1
done
marker=$(cat "$HOME_DIR/state/$ID.usage-limit" 2>/dev/null) \
  || fail "$CLAUDE_VERSION: no usage-limit record; is the account at its limit? screen: $(screen)"
assert_contains "$marker" "gen=$BUSY_GEN" "$CLAUDE_VERSION: the record names the hook's busy generation"
if [ "$LIMIT_ROOT" = ordinary ]; then
  assert_contains "$marker" "config_dir_set=0" "$CLAUDE_VERSION: the record names the ordinary account"
else
  assert_contains "$marker" "config_dir=$LIMIT_ROOT" "$CLAUDE_VERSION: the record names the account root"
fi
printf '%s\n' "$marker" | grep -Eq '^message=.*[Ll]imit' \
  || fail "$CLAUDE_VERSION: the StopFailure payload carried no limit text: $marker"
printf '# %s: StopFailure record: %s\n' "$CLAUDE_VERSION" "$(printf '%s\n' "$marker" | grep '^message=')"

out=$(env PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_ACCOUNT_FAILOVER_MENU_WAIT=15 \
  "$ROOT/bin/fm-account-failover.sh" run "$ID" 2>&1)
assert_contains "$out" "blocked $ID" "$CLAUDE_VERSION: the run should end at the blocked line: $out"
after=$(screen)
assert_not_contains "$after" "Stop and wait for limit to reset" "$CLAUDE_VERSION: Escape must close the limit prompt"
assert_not_contains "$after" "Switch to usage credits" "$CLAUDE_VERSION: no paid option may remain on screen"
printf '%s\n' "$after" | grep -Eq '^❯ *$' || fail "$CLAUDE_VERSION: the prompt should close to an empty composer: $after"
assert_contains "$(cat "$HOME_DIR/state/$ID.status")" "blocked: Claude usage limit reached" \
  "$CLAUDE_VERSION: the blocked line is written"
printf '# %s: limit prompt recognized, closed with Escape to an idle composer\n' "$CLAUDE_VERSION"
pass "account failover live: $CLAUDE_VERSION records the usage limit and its prompt closes on Escape alone"
