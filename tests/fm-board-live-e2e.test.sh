#!/usr/bin/env bash
# Real Lavish listener + real Codex endpoint, confined to a named Herdr lab.
# No browser is opened, no prompt is submitted, and no real board is touched.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
fm_live_gate default-on FM_BOARD_LIVE herdr codex lavish-axi jq python3
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
TMP_ROOT=$(mktemp -d /tmp/fm-board-live.XXXXXX)
FM_HOME=$("$LAB_HOME_HELPER" create "$TMP_ROOT/home")
export FM_HOME FM_STATE_OVERRIDE="$FM_HOME/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish" LAVISH_AXI_NO_OPEN=1 LAVISH_AXI_HOST=127.0.0.1
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name tool-133)
HERDR_ORIGINAL_PATH=$PATH
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
BOARD="$FM_HOME/board.html"
BOARD_ID=''
cleanup() {
  local rc=$? result seq
  if [ -f "$LAVISH_AXI_STATE_DIR/state.json" ]; then
    lavish-axi end "$BOARD" >/dev/null 2>&1 || rc=1
  fi
  if [ -n "$BOARD_ID" ]; then
    for result in "$FM_HOME/state/procevent-inbox/$BOARD_ID".*.result; do
      [ -f "$result" ] || continue
      seq=${result%.result}; seq=${seq##*.}
      "$ROOT/bin/fm-procevent.sh" handled "$BOARD_ID" "$seq" >/dev/null 2>&1 || true
    done
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || rc=1
  fi
  # --port and the private store address only this test's server.
  if [ -f "$LAVISH_AXI_STATE_DIR/state.json" ]; then
    lavish-axi stop --port "$LAVISH_AXI_PORT" >/dev/null 2>&1 || rc=1
  fi
  "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/codex" "$LAVISH_AXI_STATE_DIR"
# Reuse authentication without sharing configuration, history or session writes.
# A blank profile stops at login before Herdr can recognize an idle author.
if [ -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ]; then
  (umask 077; cat "${CODEX_HOME:-$HOME/.codex}/auth.json" > "$TMP_ROOT/codex/auth.json")
fi
# All backend reads are routed through the same named-session helper too.
cat > "$TMP_ROOT/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "$flag" -ge 0 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset 'args[last]' 'args[flag]'
fi
for arg in "${args[@]}"; do case "$arg" in --session|--session=*) exit 9 ;; esac; done
# No input may reach Codex's login/onboarding surface or submit a model prompt.
# The startup command below uses lab() directly; all application-side doorbells
# and lifecycle input go through this read-only transport during the proof.
case "${args[0]} ${args[1]:-}" in
  'pane run'|'pane send-text'|'pane send-keys') exit 91 ;;
esac
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod +x "$TMP_ROOT/bin/herdr"
export PATH="$TMP_ROOT/bin:$PATH"
lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
created=$(lab workspace create --cwd "$FM_HOME" --label board-lifetime --no-focus)
pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id')
workspace=$(printf '%s' "$created" | jq -er '.result.workspace.workspace_id')
tab=$(lab pane get "$pane" | jq -er '.result.pane.tab_id')
# Keep this token-free author inside the lab process tree; do not start even a
# private persistent daemon that could outlive teardown.
cmd=$(printf 'env CODEX_HOME=%q codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox --disable hooks --disable daemon_auto_start' "$TMP_ROOT/codex")
lab pane run "$pane" "$cmd" >/dev/null
cat > "$FM_HOME/state/author.meta" <<EOF
window=$HERDR_LAB_SESSION:$pane
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$workspace
herdr_tab_id=$tab
herdr_pane_id=$pane
endpoint_task_id=author
worktree=$FM_HOME
project=$FM_HOME
harness=codex
kind=scout
EOF
alive=unknown
standalone=0
for _ in $(seq 1 60); do
  alive=$("$ROOT/bin/fm-procevent-lavish.sh" author-state "$FM_HOME/state" author)
  [ "$alive" != alive ] || break
  screen=$(lab pane read "$pane" --source visible)
  if [ "$standalone" = 0 ] && printf '%s' "$screen" | grep -Fq 'Background server has incompatible feature settings' \
    && printf '%s' "$screen" | grep -Fq '› 3. Cancel' \
    && printf '%s' "$screen" | grep -Fq '1. Run without daemon this time'; then
    # Select only the isolated, non-restarting choice after proving the exact
    # dialog and cursor position. Never submit an unknown screen or restart the
    # shared server. The application-side transport remains read-only.
    lab pane send-keys "$pane" up up >/dev/null
    screen=$(lab pane read "$pane" --source visible)
    printf '%s' "$screen" | grep -Fq '› 1. Run without daemon this time' \
      || fail 'could not prove the lab-only standalone selection'
    lab pane send-keys "$pane" enter >/dev/null
    standalone=1
  fi
  sleep 0.5
done
if [ "$alive" != alive ]; then
  printf 'author-state=%s\n' "$alive" >&2
  lab agent get "$pane" >&2 || true
  lab pane read "$pane" --source visible >&2 || true
  fail 'real Codex author did not become alive'
fi
LAVISH_AXI_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
export LAVISH_AXI_PORT
printf '<!doctype html><title>Throwaway lifetime proof</title><h1>Throwaway lifetime proof</h1>\n' > "$BOARD"
lavish-axi "$BOARD" >/dev/null
BOARD_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$BOARD")
"$ROOT/bin/fm-procevent-lavish.sh" arm "$BOARD" --for author >/dev/null
if "$ROOT/bin/fm-control.sh" author exit > "$TMP_ROOT/exit" 2>&1; then fail 'live board author was closed'; fi
[ "$("$ROOT/bin/fm-procevent-lavish.sh" author-state "$FM_HOME/state" author)" = alive ] || fail 'refused exit changed live author'
python3 "$ROOT/bin/fm-board.py" snapshot "$FM_HOME/state" --liveness | jq -e 'any(.[]; .task == "author" and .author == "alive")' >/dev/null
"$ROOT/bin/fm-procevent-lavish.sh" finish "$BOARD" --for author >/dev/null
finished=0
for _ in $(seq 1 60); do
  for result in "$FM_HOME/state/procevent-inbox/$BOARD_ID".*.result; do
    [ -f "$result" ] || continue
    seq=${result%.result}; seq=${seq##*.}
    if "$ROOT/bin/fm-procevent-lavish.sh" terminal "$result"; then
      "$ROOT/bin/fm-procevent.sh" handled "$BOARD_ID" "$seq" >/dev/null
      finished=1
      break
    fi
  done
  [ "$finished" = 0 ] || break
  sleep 0.5
done
[ "$finished" = 1 ] || fail 'finished board did not produce its terminal round'
python3 "$ROOT/bin/fm-board.py" guard "$FM_HOME/state" author
python3 "$ROOT/bin/fm-board.py" snapshot "$FM_HOME/state" --liveness | jq -e 'any(.[]; .task == "author" and .status == "closed")' >/dev/null
printf 'ok - real Lavish listener protects a live Codex author until terminal acknowledgement\n'
herdr_version=$(lab status --json | jq -er '.client.version')
printf 'versions: lavish=%s herdr=%s codex=%s\n' "$(lavish-axi --version)" "$herdr_version" "$(codex --version)"
