#!/usr/bin/env bash
# Portable shell-tree proof and closed-task reporting; no Herdr lifecycle calls.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(mktemp -d)
pids=()
cleanup() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
fm_backend_herdr_cli() {
  printf '{"result":{"process_info":{"pane_id":"w1:p1","shell_pid":%s}}}\n' "$shell_pid"
}
mkfifo "$TMP_ROOT/input"
bash -c 'read -r line < "$1"' _ "$TMP_ROOT/input" &
shell_pid=$!; pids+=("$shell_pid")
sleep 0.1
fm_backend_herdr_pane_shell_tree lab w1:p1 || fail 'bare sleeping shell rejected'
pass 'real bare shell is eligible without relying on a vendor status string'
if fm_backend_herdr_pane_shell_tree lab different; then fail 'mismatched pane accepted'; fi
pass 'mismatched structured pane identity refuses'
# Non-shell background work must refuse even if it never registered an agent.
bash -c 'sleep 60 & echo "$!" > "$1"; wait' _ "$TMP_ROOT/child" &
shell_pid=$!; pids+=("$shell_pid")
for _ in $(seq 1 50); do [ ! -s "$TMP_ROOT/child" ] || break; sleep 0.1; done
pids+=("$(cat "$TMP_ROOT/child")")
if fm_backend_herdr_pane_shell_tree lab w1:p1; then fail 'background process accepted'; fi
pass 'real background process prevents closure without agent registration'

export FM_HOME="$TMP_ROOT/home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$TMP_ROOT/fakebin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/fakebin/no-mistakes"
chmod +x "$TMP_ROOT/fakebin/no-mistakes"
export PATH="$TMP_ROOT/fakebin:$PATH"
cat > "$FM_HOME/state/sample.meta" <<META
window=lab:w1:p1
backend=herdr
kind=ship
worktree=$TMP_ROOT
presentation=closed
presentation_closed_at=1
META
printf 'paused: waiting for review\n' > "$FM_HOME/state/sample.status"
out=$("$ROOT/bin/fm-crew-state.sh" sample)
case "$out" in 'state: paused '*'presentation: closed'*) ;; *) fail "$out" ;; esac
pass 'closed waiting task preserves its wait in crew-state'
printf 'needs-decision: choose a setting\n' >> "$FM_HOME/state/sample.status"
out=$("$ROOT/bin/fm-crew-state.sh" sample)
case "$out" in 'state: parked '*'choose a setting'*'presentation: closed'*) ;; *) fail "$out" ;; esac
pass 'closed task surfaces a new decision without missing-endpoint noise'
# The watcher public sourced interface excludes endpoints, not status records.
windows=$(bash -c '. "$1/bin/fm-watch.sh"; recorded_windows' _ "$ROOT")
[ -z "$windows" ] || fail 'closed endpoint remains in pane monitoring'
[ -s "$FM_HOME/state/sample.status" ] || fail 'status reporting was removed'
pass 'closed endpoint is absent from pane monitoring while its status survives'
cp "$FM_HOME/state/sample.meta" "$TMP_ROOT/meta.before"
"$ROOT/bin/fm-presentation-close.sh" sample
cmp "$TMP_ROOT/meta.before" "$FM_HOME/state/sample.meta" || fail 'closed task was mutated'
pass 'closing an already-closed presentation is a no-op'
for kind in secondmate unknown; do
  printf 'backend=herdr\nkind=%s\nwindow=foreign\n' "$kind" > "$FM_HOME/state/protected.meta"
  cp "$FM_HOME/state/protected.meta" "$TMP_ROOT/meta.before"
  "$ROOT/bin/fm-presentation-close.sh" protected
  cmp "$TMP_ROOT/meta.before" "$FM_HOME/state/protected.meta" || fail 'non-worker metadata changed'
done
pass 'secondmates and unknown task kinds are never candidates'
