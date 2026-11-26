#!/usr/bin/env bash
# Opt-in real no-mistakes run and attach view in a guarded named Herdr lab.
# Publication steps are disabled; only this throwaway repo's run is cancelled.
# macOS sandbox-exec prevents init's unrelated personal-skill installation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_NM_REVIEW_PANE_E2E herdr jq no-mistakes sandbox-exec
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-nm-pane-live)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name too-90-nm-panel-right)
REAL_HERDR=$(command -v herdr)
ORIGINAL_PATH=$PATH
RUN_ID='' CLI_PID='' WATCH_PID='' INITIALIZED=0
mkdir -p "$TMP_ROOT/fakebin" "$TMP_ROOT/home/state" "$TMP_ROOT/home/config"
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR ORIGINAL_PATH
cleanup() {
  local rc=$? cancel_ok=1
  if [ -n "$WATCH_PID" ]; then kill "$WATCH_PID" 2>/dev/null || true; wait "$WATCH_PID" 2>/dev/null || true; fi
  if [ "$INITIALIZED" = 1 ]; then
    if [ -z "$RUN_ID" ]; then
      RUN_ID=$(cd "$TMP_ROOT/repo" && no-mistakes axi status | sed -n 's/^  id: "\{0,1\}\([A-Za-z0-9_-]*\)"\{0,1\}$/\1/p' | head -1)
    fi
    if [ -n "$RUN_ID" ]; then
      (cd "$TMP_ROOT/repo" && no-mistakes axi abort --run "$RUN_ID") > "$TMP_ROOT/abort.log" 2>&1 || { rc=1; cancel_ok=0; }
    fi
    if [ "$cancel_ok" = 1 ]; then
      (cd "$TMP_ROOT/repo" && no-mistakes eject) > "$TMP_ROOT/eject.log" 2>&1 || rc=1
    fi
  fi
  if [ -n "$CLI_PID" ]; then kill "$CLI_PID" 2>/dev/null || true; wait "$CLI_PID" 2>/dev/null || true; fi
  env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  if [ -n "${FM_NM_PANE_PROOF_DIR:-}" ]; then
    mkdir -p "$FM_NM_PANE_PROOF_DIR"
    cp "$TMP_ROOT/"*.log "$TMP_ROOT/"*.json "$TMP_ROOT/"*.txt "$FM_NM_PANE_PROOF_DIR/" 2>/dev/null || true
  fi
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# The production transport still supplies a session. Reject any different one
# and route every resulting Herdr command through the guarded helper.
cat > "$TMP_ROOT/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
last=$((${#args[@]} - 1)); flag=$((last - 1))
[ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ] || exit 9
unset "args[$last]" "args[$flag]"
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod +x "$TMP_ROOT/fakebin/herdr"
lab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
git init -q -b main "$TMP_ROOT/repo"
printf 'A small throwaway fixture.\n' > "$TMP_ROOT/repo/README.md"
git -C "$TMP_ROOT/repo" add README.md
git -C "$TMP_ROOT/repo" commit -q -m 'Initialize throwaway pane proof'
git clone -q --bare "$TMP_ROOT/repo" "$TMP_ROOT/origin.git"
git -C "$TMP_ROOT/repo" remote add origin "$TMP_ROOT/origin.git"
git -C "$TMP_ROOT/repo" switch -q -c fm/pane-proof
printf 'A second line for the live review.\n' >> "$TMP_ROOT/repo/README.md"
git -C "$TMP_ROOT/repo" commit -q -am 'Exercise a real no-mistakes run'
no-mistakes daemon status > "$TMP_ROOT/daemon.txt"
(
  cd "$TMP_ROOT/repo"
  sandbox-exec -D "SKILL_ONE=$HOME/.agents/skills" -D "SKILL_TWO=$HOME/.claude" \
    -p '(version 1) (allow default) (deny file-write* (subpath (param "SKILL_ONE")) (subpath (param "SKILL_TWO")))' \
    no-mistakes init
) > "$TMP_ROOT/init.log" 2>&1
INITIALIZED=1
CHAT=$(lab workspace create --cwd "$TMP_ROOT/repo" --label nm-pane-proof --no-focus)
printf '%s\n' "$CHAT" > "$TMP_ROOT/chat.json"
WORKSPACE=$(printf '%s' "$CHAT" | jq -er '.result.workspace.workspace_id')
TAB=$(printf '%s' "$CHAT" | jq -er '.result.tab.tab_id')
WORKER=$(printf '%s' "$CHAT" | jq -er '.result.root_pane.pane_id')
fm_write_meta "$TMP_ROOT/home/state/proof.meta" "window=$HERDR_LAB_SESSION:$WORKER" \
  endpoint_task_id=proof "worktree=$TMP_ROOT/repo" "project=$TMP_ROOT/repo" kind=ship mode=no-mistakes \
  backend=herdr "herdr_session=$HERDR_LAB_SESSION" "herdr_workspace_id=$WORKSPACE" \
  "herdr_tab_id=$TAB" "herdr_pane_id=$WORKER"
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config" FM_ROOT_OVERRIDE="$ROOT" FM_CREW_STATE_NO_FORGE=1
export PATH="$TMP_ROOT/fakebin:$ORIGINAL_PATH"
START=$(date +%s)
(
  cd "$TMP_ROOT/repo"
  no-mistakes axi run --intent 'Prove that a real validation run opens its read-only attach view on the right of an isolated worker chat within 30 seconds. This repository is disposable. Do not publish anything.' \
    --skip=intent,rebase,test,document,lint,sonar,push,pr,ci,feedback --wait 60s
) > "$TMP_ROOT/run.log" 2>&1 &
CLI_PID=$!
# Exercise the real automatic watcher trigger, not a test-side attach call.
# Its entire inventory belongs to this lab and the throwaway repository.
touch "$FM_HOME/state/home-summary.json"
FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1000000 FM_HEARTBEAT=1000000 \
  FM_HEARTBEAT_MAX=1000000 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/watcher.log" 2>&1 &
WATCH_PID=$!
PANE=
while [ "$(($(date +%s) - START))" -lt 30 ]; do
  RECORD="$FM_HOME/state/proof.nm-review-pane"
  PANE=$(sed -n 's/^pane=//p' "$RECORD" 2>/dev/null || true)
  RUN_ID=$(sed -n 's/^run=//p' "$RECORD" 2>/dev/null || true)
  [ -z "$PANE" ] || break
  sleep 1
done
[ -n "$PANE" ] || { cat "$TMP_ROOT/run.log" "$FM_HOME/state/.nm-review-pane.log"; fail 'real run produced no view within 30 seconds'; }
ELAPSED=$(($(date +%s) - START))
lab pane neighbor --pane "$WORKER" --direction right > "$TMP_ROOT/neighbor.json"
jq -e --arg pane "$PANE" '.result.neighbor.neighbor_pane_id == $pane' "$TMP_ROOT/neighbor.json" >/dev/null \
  || fail 'real view is not on the right of its worker'
jq -e --arg worker "$WORKER" --arg pane "$PANE" '
  .result.neighbor.layout as $layout
  | ($layout.panes[] | select(.pane_id == $worker) | .rect) as $chat
  | ($layout.panes[] | select(.pane_id == $pane) | .rect) as $view
  | $view.x >= ($chat.x + $chat.width) and $view.y == $chat.y
    and $layout.focused_pane_id == $worker' "$TMP_ROOT/neighbor.json" >/dev/null \
  || fail 'real pane rectangles or focus do not match chat-left/view-right'
lab pane list --workspace "$WORKSPACE" > "$TMP_ROOT/panes.json"
jq -e --arg tab "$TAB" '[.result.panes[] | select(.tab_id == $tab)] | length == 2' "$TMP_ROOT/panes.json" >/dev/null \
  || fail 'real proof tab must contain exactly chat and view'
for ((i=0;i<50;i++)); do
  lab pane process-info --pane "$PANE" > "$TMP_ROOT/process.json"
  if jq -e --arg run "$RUN_ID" --arg cwd "$TMP_ROOT/repo" \
    '.result.process_info.foreground_processes[] | select(.cwd == $cwd and .argv[1:] == ["attach", "--run", $run])' \
    "$TMP_ROOT/process.json" >/dev/null; then break; fi
  sleep 0.1
done
[ "$i" -lt 50 ] || fail 'real attach process never started in its view'
ELAPSED=$(($(date +%s) - START))
[ "$ELAPSED" -le 30 ] || fail 'real attach process started outside the 30-second window'
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=
"$ROOT/bin/fm-nm-review-pane.sh" --sweep
[ "$(sed -n 's/^pane=//p' "$RECORD")" = "$PANE" ] || fail 'second real sweep duplicated or replaced view'
lab pane move "$PANE" --tab "$TAB" --target-pane "$WORKER" --split down --ratio 0.55 --no-focus > "$TMP_ROOT/stacked.json"
"$ROOT/bin/fm-nm-review-pane.sh" --sweep
lab pane neighbor --pane "$WORKER" --direction right > "$TMP_ROOT/repaired.json"
jq -e --arg pane "$PANE" '.result.neighbor.neighbor_pane_id == $pane' "$TMP_ROOT/repaired.json" >/dev/null \
  || fail 'existing stacked live view did not move to the right'
rm "$RECORD"
"$ROOT/bin/fm-nm-review-pane.sh" --sweep
[ "$(sed -n 's/^pane=//p' "$RECORD")" = "$PANE" ] || fail 'real attach was not adopted after record loss'
lab pane close "$PANE" >/dev/null
"$ROOT/bin/fm-nm-review-pane.sh" --sweep
"$ROOT/bin/fm-nm-review-pane.sh" --sweep
lab pane list --workspace "$WORKSPACE" > "$TMP_ROOT/closed.json"
jq -e --arg tab "$TAB" '[.result.panes[] | select(.tab_id == $tab)] | length == 1' "$TMP_ROOT/closed.json" >/dev/null \
  || fail 'manually closed live view reopened during the same run'
pass 'real stacked view moves right, is adopted without duplication, and stays closed when dismissed'
lab status --json > "$TMP_ROOT/version.json"
printf 'evidence: herdr=%s no-mistakes=%s elapsed_seconds=%s run=%s session=%s worker=%s view=%s\n' \
  "$(jq -r '.client.version // .server.version' "$TMP_ROOT/version.json")" "$(no-mistakes --version)" \
  "$ELAPSED" "$RUN_ID" "$HERDR_LAB_SESSION" "$WORKER" "$PANE" | tee "$TMP_ROOT/result.txt"
pass 'real no-mistakes run opens one live view on the right within 30 seconds'
