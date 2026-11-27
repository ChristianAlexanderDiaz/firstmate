#!/usr/bin/env bash
# Author protection and cross-home board visibility through public interfaces.
# Uses inert registrations and fixture transports; never opens a real pane.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE
mkdir -p "$LAVISH_AXI_STATE_DIR" "$TMP_ROOT/a/state" "$TMP_ROOT/b/state" "$TMP_ROOT/fakebin"
BOARD="$ROOT/bin/fm-board.py"
printf '<h1>Throwaway board</h1>\n' > "$TMP_ROOT/a/board.html"
printf 'window=test:fm-author\nworktree=%s\nproject=%s\nharness=codex\n' "$TMP_ROOT/a" "$TMP_ROOT/a" > "$TMP_ROOT/a/state/author.meta"
FM_HOME="$TMP_ROOT/a" "$ROOT/bin/fm-procevent.sh" register-task lavish lavish-board author -- \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$TMP_ROOT/a/board.html" >/dev/null
if python3 "$BOARD" guard "$TMP_ROOT/a/state" author >/dev/null 2>&1; then fail 'registered author was allowed to exit'; fi
if FM_HOME="$TMP_ROOT/a" "$ROOT/bin/fm-teardown.sh" author > "$TMP_ROOT/cleanup-refusal" 2>&1; then fail 'cleanup closed board author'; fi
grep -q 'authors open board' "$TMP_ROOT/cleanup-refusal" || fail 'cleanup did not apply board protection'
[ -f "$TMP_ROOT/a/state/author.meta" ] || fail 'cleanup removed protected author metadata'
python3 "$BOARD" guard "$TMP_ROOT/a/state" another || fail 'unrelated worker could not exit'
cat > "$TMP_ROOT/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) [ ! -f "$BOARD_TEST_STOPPED" ] || exit 0; printf 'fm-author\n' ;;
  display-message) printf 'codex\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/tmux"
export PATH="$TMP_ROOT/fakebin:$PATH" BOARD_TEST_STOPPED="$TMP_ROOT/stopped"
jq -n --arg file "$TMP_ROOT/a/board.html" '{sessions:{board:{file:$file,status:"open",url:"http://board"}}}' > "$LAVISH_AXI_STATE_DIR/state.json"
python3 "$BOARD" snapshot "$TMP_ROOT/b/state" --liveness | jq -e '
  length == 1 and .[0].task == "author" and .[0].author == "alive" and .[0].registered' >/dev/null
ln -s "$TMP_ROOT/a" "$TMP_ROOT/alias"
FM_HOME="$TMP_ROOT/alias" "$ROOT/bin/fm-crew-state.sh" author --boards | \
  jq -e 'length == 1 and .[0].task == "author" and .[0].author == "alive"' >/dev/null
pass 'per-worker board view resolves symlinked state directories'
touch "$BOARD_TEST_STOPPED"
python3 "$BOARD" snapshot "$TMP_ROOT/b/state" --liveness | jq -e '.[0].author == "missing" or .[0].author == "dead"' >/dev/null
rm "$BOARD_TEST_STOPPED"
# End is not enough to abandon a terminal round: registration protects the author
# until the normal handled/retire path concludes the review.
jq '.sessions.board.status="ended"' "$LAVISH_AXI_STATE_DIR/state.json" > "$TMP_ROOT/ended"
mv "$TMP_ROOT/ended" "$LAVISH_AXI_STATE_DIR/state.json"
if python3 "$BOARD" guard "$TMP_ROOT/a/state" author >/dev/null 2>&1; then fail 'unacknowledged closed board released author'; fi
python3 "$BOARD" snapshot "$TMP_ROOT/b/state" --liveness | jq -e '.[0].status == "closed" and .[0].author == "board-closed"' >/dev/null
FM_HOME="$TMP_ROOT/a" "$ROOT/bin/fm-procevent.sh" retire lavish-board >/dev/null
python3 "$BOARD" guard "$TMP_ROOT/a/state" author || fail 'retired board trapped author'
pass 'author protection survives listener gaps and session end until retirement'
pass 'cross-home inventory shows alive, stopped and closed boards'

# Record corruption must never authorize stopping a possibly owned author.
printf 'adapter=lavish\nowner_task=author\nargv:\ninvalid\n' > "$TMP_ROOT/a/state/procevent/broken.source"
if python3 "$BOARD" guard "$TMP_ROOT/a/state" author >/dev/null 2>&1; then fail 'malformed board authorized exit'; fi
pass 'unreadable board ownership refuses lifecycle changes'
