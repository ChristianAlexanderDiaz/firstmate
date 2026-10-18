#!/usr/bin/env bash
# Token-free Claude exit guard: background a shell with the native ! composer,
# then exercise fm-control exit on a private tmux server and isolated FM_HOME.
# No model prompt is submitted. Trust/permission dialogs fail rather than being
# answered. Refresh runtime-backends.md from this installed-harness proof.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CONTROL_CLAUDE_EXIT_LIVE claude tmux

VERSION=$(claude --version)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-claude-exit.XXXXXX")
SOCKET="fm-control-exit-live-$$"
REAL_TMUX=$(command -v tmux)
TASK=exit-probe
TARGET="probe:fm-$TASK"
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  if [ -s "$LAB/sleep.pid" ]; then
    kill "$(cat "$LAB/sleep.pid")" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT
fail() {
  printf 'not ok - Claude %s: %s\n' "$VERSION" "$1" >&2
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" >&2 || true
  exit 1
}
mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/home/data" "$LAB/home/config"
# Scope all production backend calls to this test's private server. Preserve
# captures to prove that exit actually encountered the real vendor dialog.
cat > "$LAB/shim/tmux" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = capture-pane ]; then
  "$REAL_TMUX" -L "$SOCKET" "\$@" > "$LAB/capture"
  rc=\$?
  cat "$LAB/capture" >> "$LAB/captures"
  cat "$LAB/capture"
  exit "\$rc"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

tmux new-session -d -s probe -n "fm-$TASK" -x 160 -y 45 -c "$ROOT"
# Keep the shell endpoint after Claude exits. Child-session mode suppresses
# transcript persistence; empty setting sources avoid fleet/user hooks.
tmux send-keys -t "$TARGET" -l 'env -u CLAUDECODE CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --setting-sources "" --strict-mcp-config --permission-mode auto'
tmux send-keys -t "$TARGET" Enter
for ((i=0; i<100; i++)); do
  [ "$(fm_tmux_composer_state "$TARGET")" != empty ] || break
  sleep 0.1
done
[ "$(fm_tmux_composer_state "$TARGET")" = empty ] || fail 'no idle composer (trust or startup gate remains untouched)'

# Native shell mode spends no model tokens. Record the shell PID before exec
# so the test also proves that confirming exit stops its background process.
printf -v command '! echo $$ > %q; exec sleep 300' "$LAB/sleep.pid"
tmux send-keys -t "$TARGET" -l "$command"
tmux send-keys -t "$TARGET" Enter
for ((i=0; i<100; i++)); do
  [ ! -s "$LAB/sleep.pid" ] || break
  sleep 0.1
done
[ -s "$LAB/sleep.pid" ] || fail 'native shell did not start'
kill -0 "$(cat "$LAB/sleep.pid")" || fail 'native shell stopped before backgrounding'
# The process starts before Claude installs its running-tool key handler.
# Wait for that handler's advertised shortcut before sending its keys.
for ((i=0; i<100; i++)); do
  screen=$(tmux capture-pane -p -t "$TARGET")
  [[ "$screen" != *'ctrl+b ctrl+b (twice) to run in background'* ]] || break
  sleep 0.1
done
[[ "$screen" == *'ctrl+b ctrl+b (twice) to run in background'* ]] || fail 'native background shortcut did not render'
tmux send-keys -t "$TARGET" C-b C-b
for ((i=0; i<100; i++)); do
  screen=$(tmux capture-pane -p -t "$TARGET")
  if [[ "$screen" == *'Command was manually backgrounded by user'* ]] \
     && [ "$(fm_tmux_composer_state "$TARGET")" = empty ]; then
    break
  fi
  sleep 0.1
done
[[ "$screen" == *'Command was manually backgrounded by user'* ]] || fail 'native shell did not background'
kill -0 "$(cat "$LAB/sleep.pid")" || fail 'background process stopped before exit'
cat > "$LAB/home/state/$TASK.meta" <<META
window=$TARGET
endpoint_task_id=$TASK
worktree=$ROOT
project=$ROOT
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
out=$(FM_HOME="$LAB/home" FM_CONTROL_EXIT_WAIT=15 bash "$ROOT/bin/fm-control.sh" "$TASK" exit 2>&1) \
  || fail "exit failed: $out"
[[ "$out" == *"stopped $TASK harness=claude"* ]] || fail "missing verified stop: $out"
grep -qF 'Background work is running' "$LAB/captures" || fail 'exit never read the background-work dialog'
grep -qF '❯ 1. Exit and stop tasks' "$LAB/captures" || fail 'exit never read the selected stop-tasks row'
for ((i=0; i<100; i++)); do
  kill -0 "$(cat "$LAB/sleep.pid")" 2>/dev/null || break
  sleep 0.1
done
! kill -0 "$(cat "$LAB/sleep.pid")" 2>/dev/null || fail 'exit left its background shell running'
rm "$LAB/sleep.pid"
tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null || fail 'exit destroyed the endpoint'
printf 'ok - Claude %s: fm-control exit confirms the captured background-task picker, stops its shell, and preserves the endpoint\n' "$VERSION"
