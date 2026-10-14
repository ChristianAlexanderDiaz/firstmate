#!/usr/bin/env bash
set -eu
ROOT=$PWD
SCRATCH="$ROOT/.test-account-live/runtime"
EVIDENCE=/Users/christianalexanderdiaz/.no-mistakes/evidence/01M4XV5N71PBXBHYYR54NGJWRK
mkdir -p "$SCRATCH"
export FM_HERDR_LAB_STATE_DIR="$SCRATCH/herdr-state"
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name acct)
ORIGINAL_PATH=$PATH
PANE=
cleanup() {
  local rc=$?
  if ! env PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" >> "$EVIDENCE/live-runtime.log" 2>&1; then rc=1; fi
  rm -rf "$SCRATCH"
  exit "$rc"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION"
lab() { env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
"$ROOT/bin/fm-lab-home.sh" create "$SCRATCH/home" >/dev/null
mkdir -p "$SCRATCH/work" "$SCRATCH/bin"
git -C "$SCRATCH/work" init -q
printf 'Disposable account-validation project\n' > "$SCRATCH/work/README.txt"
printf 'account near ordinary\naccount far ordinary\n' > "$SCRATCH/home/config/claude-failover"
touch "$SCRATCH/home/config/supervision-host-off"
export HERDR_LAB_HELPER="$HELPER" HERDR_LAB_SESSION="$SESSION" HERDR_ORIGINAL_PATH="$ORIGINAL_PATH"
cat > "$SCRATCH/bin/herdr" <<'WRAP'
#!/usr/bin/env bash
set -eu
args=("$@")
last=$((${#args[@]}-1));flag=$((last-1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
 unset "args[$last]" "args[$flag]"
fi
for arg in "${args[@]}"; do case "$arg" in --session|--session=*) exit 9;; esac; done
printf '%s\n' "${args[*]}" >> "$LIVE_BACKEND_LOG"
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
WRAP
chmod +x "$SCRATCH/bin/herdr"
export LIVE_BACKEND_LOG="$SCRATCH/backend.log"
ws=$(lab workspace create --cwd "$SCRATCH/work" --label account-test --no-focus)
PANE=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id')
WORKSPACE=$(printf '%s' "$ws" | jq -r '.result.root_pane.workspace_id // .result.workspace.workspace_id')
TAB=$(printf '%s' "$ws" | jq -r '.result.root_pane.tab_id')
ID=guard
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$SCRATCH/home/state" "$ID")
cat > "$SCRATCH/home/state/$ID.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$ID
worktree=$SCRATCH/work
project=$SCRATCH/work
harness=claude
kind=scout
model=sonnet
effort=default
busy_gen=$GEN
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE
herdr_tab_id=$TAB
herdr_pane_id=$PANE
tasktmp=$SCRATCH/tasktmp
EOF
FM_HOME="$SCRATCH/home" "$ROOT/bin/fm-brief.sh" "$ID" disposable --scout --herdr-lab >/dev/null
python3 - "$SCRATCH/home/data/$ID/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}','Exercise only disposable account safety checks.').replace('{FIRSTMATE_SPEC}','Do not change any source or credentials.'))
PY
submit="'$ROOT/bin/fm-busy-event.sh' apply '$SCRATCH/home/state' '$ID' busy --gen '$GEN' --source claude-hook --event user-prompt-submit"
failure="'$ROOT/bin/fm-busy-event.sh' apply '$SCRATCH/home/state' '$ID' idle --gen '$GEN' --source claude-hook --event stop-failure && '$ROOT/bin/fm-account-failover.sh' record '$SCRATCH/home/config' '$SCRATCH/home/state' '$ID' '$GEN'"
jq -n --arg submit "$submit" --arg failure "$failure" '{hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:$submit}]}],StopFailure:[{hooks:[{type:"command",command:$failure}]}]}}' > "$SCRATCH/settings.json"
lab pane run "$PANE" "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN claude --setting-sources '' --settings '$SCRATCH/settings.json' 'Reply with only hi; do not run any tools or write any files.'" >/dev/null
sleep 5
lab pane read "$PANE" --source visible > "$EVIDENCE/claude-lab-screen.txt"
run_product() {
 env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u CLAUDE_CONFIG_DIR \
 PATH="$SCRATCH/bin:$ORIGINAL_PATH" FM_HOME="$SCRATCH/home" HERDR_SESSION="$SESSION" FM_ACCOUNT_FAILOVER_MENU_WAIT=0 \
 "$@"
}
record() {
 "$ROOT/bin/fm-busy-event.sh" apply "$SCRATCH/home/state" "$ID" idle --gen "$GEN" --source claude-hook --event stop-failure
 jq -nc --arg msg "$1" '{error:"rate_limit",last_assistant_message:$msg}' | env -u CLAUDE_CONFIG_DIR "$ROOT/bin/fm-account-failover.sh" record "$SCRATCH/home/config" "$SCRATCH/home/state" "$ID" "$GEN"
}
{
 printf 'Real Herdr lab and Claude CLI, synthetic hook events for safety guards; no genuine exhausted-account menu or account switch is claimed.\n'
 printf '\nSuperseded exhaustion after a newer submission:\n'
 record "You've hit your weekly limit · resets Oct 17 at 4pm"
 cp "$SCRATCH/home/state/$ID.usage-limit" "$SCRATCH/old-limit"
 "$ROOT/bin/fm-busy-event.sh" apply "$SCRATCH/home/state" "$ID" busy --gen "$GEN" --source claude-hook --event user-prompt-submit
 test ! -e "$SCRATCH/home/state/$ID.usage-limit"
 cp "$SCRATCH/old-limit" "$SCRATCH/home/state/$ID.usage-limit"
 out=$(run_product "$ROOT/bin/fm-account-failover.sh" run "$ID" 2>&1) || { printf '%s\n' "$out"; exit 1; };printf '%s\n' "$out"
 case "$out" in *'the usage-limit turn was superseded'*) ;; *) exit 1;; esac
 printf '\nDocumented transient throttle with no usage menu:\n'
 record 'API Error: Rate limit reached'
 out=$(run_product "$ROOT/bin/fm-account-failover.sh" run "$ID" 2>&1) || { printf '%s\n' "$out"; exit 1; };printf '%s\n' "$out"
 case "$out" in *'no verified account exhaustion'*) ;; *) exit 1;; esac
 printf '\nStraight-apostrophe exhaustion with no menu and no qualifying map rows:\n'
 record "You've hit your weekly limit · resets Oct 17 at 4pm"
 out=$(run_product "$ROOT/bin/fm-account-failover.sh" run "$ID" 2>&1) || { printf '%s\n' "$out"; exit 1; };printf '%s\n' "$out"
 case "$out" in *'blocked guard'*'no other Claude account has room'*) ;; *) exit 1;; esac
 printf '\nCurly-apostrophe exhaustion under C locale with no menu and no qualifying map rows:\n'
 record 'You’ve hit your weekly limit · resets Oct 17 at 4pm'
 out=$(LC_ALL=C run_product "$ROOT/bin/fm-account-failover.sh" run "$ID" 2>&1) || { printf '%s\n' "$out"; exit 1; };printf '%s\n' "$out"
 case "$out" in *'blocked guard'*'no other Claude account has room'*) ;; *) exit 1;; esac
 printf '\nRepeat run consumes the event only once:\n'
 run_product "$ROOT/bin/fm-account-failover.sh" run "$ID"
 printf '\nRecorded status:\n';cat "$SCRATCH/home/state/$ID.status"
 printf '\nPaced relaunch with no matching quota account refuses before stopping:\n'
 printf 'paced\n' > "$SCRATCH/home/config/claude-account"
 cp "$SCRATCH/home/state/$ID.meta" "$SCRATCH/prior-meta"
 if out=$(run_product "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Disposable pre-stop check' 2>&1); then printf 'UNEXPECTED SUCCESS\n';exit 1;fi
 printf '%s\n' "$out"
 case "$out" in *'no account is choosable'*) ;; *) exit 1;; esac
 cmp "$SCRATCH/prior-meta" "$SCRATCH/home/state/$ID.meta"
 printf '\nPaced fresh spawn refuses before creating a task record:\n'
 FM_HOME="$SCRATCH/home" "$ROOT/bin/fm-brief.sh" fresh disposable --scout --herdr-lab >/dev/null
 python3 - "$SCRATCH/home/data/fresh/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}','Exercise disposable spawn refusal.').replace('{FIRSTMATE_SPEC}','Do not change files.'))
PY
 if out=$(run_product "$ROOT/bin/fm-spawn.sh" fresh "$SCRATCH/work" --scout --harness claude --model sonnet --backend herdr 2>&1);then printf 'UNEXPECTED SUCCESS\n';exit 1;fi
 printf '%s\n' "$out"
 case "$out" in *'no account is choosable'*) ;; *) exit 1;; esac
 test ! -e "$SCRATCH/home/state/fresh.meta"
 if rg 'pane (send-keys|send-text|run)|workspace create|tab create' "$SCRATCH/backend.log"; then printf 'UNEXPECTED ENDPOINT MUTATION\n';exit 1;fi
 printf '\nNo runtime keys, launch commands, or endpoint creation were sent by these guard operations.\n'
} > "$EVIDENCE/live-runtime.log" 2>&1
lab pane read "$PANE" --source visible > "$EVIDENCE/claude-lab-after-guards.txt"
printf 'Live runtime guards passed; disposing of named lab.\n'
