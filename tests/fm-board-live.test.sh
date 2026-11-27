#!/usr/bin/env bash
# Behavior tests for bin/fm-board-live.sh and the two places that drive it: the
# recorded state through its own commands, what an open page does with a stamped
# board (tests/fm-board-live-page.test.js), and the Lavish adapter making a
# board ready on arm and working when feedback arrives. No Lavish server and no
# browser are started; the adapter runs against a stand-in for the published
# poll shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-board-live)
LIVE="$ROOT/bin/fm-board-live.sh"
ADAPTER="$ROOT/bin/fm-procevent-lavish.sh"

live() { bash "$LIVE" "$@" 2>&1; }
field() { live status "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
board() {  # <path> <marker>
  printf '<!doctype html>\n<html><body>\n<h1>%s</h1>\n</body>\n</html>\n' "$2" > "$1"
}

# --- the recorded state ------------------------------------------------------
B="$TMP_ROOT/board.html"
board "$B" one
assert_equals "$(live status "$B")" "state=none at=0 rev=0 stamped=no" "a new board had a recorded state"
assert_equals "$(live working "$B")" "live: none" "a board nobody published was marked as being worked on"
assert_absent "$B.live.js" "marking an unpublished board wrote a state file"
assert_equals "$(live ready "$B")" "live: ready" "a board could not be made ready"
assert_equals "$(field "$B" state)" ready "ready was not recorded"
assert_equals "$(field "$B" stamped)" yes "ready left the board without its live block"
assert_grep '<h1>one</h1>' "$B" "stamping lost the board's own content"
first_rev=$(field "$B" rev)
first_at=$(field "$B" at)
[ "$first_at" -ge "$(($(date +%s) - 60))" ] || fail "ready recorded a time that is not now: $first_at"
before=$(cksum < "$B")
sleep 1
assert_equals "$(live ready "$B")" "live: ready (unchanged)" "repeating ready on an unchanged board changed it"
assert_equals "$(field "$B" at) $(field "$B" rev)" "$first_at $first_rev" \
  "repeating ready moved the published time of an unchanged board"
assert_equals "$(cksum < "$B")" "$before" "repeating ready rewrote an unchanged board"
pass "ready stamps a board once and keeps its published time until the board changes"

assert_equals "$(live working "$B")" "live: working" "a published board could not be marked as being worked on"
assert_equals "$(field "$B" state) $(field "$B" rev)" "working $first_rev" "working changed more than the state"
assert_equals "$(cksum < "$B")" "$before" "working touched the board file"
pass "working flips the recorded state and leaves the board file alone"

# An edit in place keeps the block but changes the board, so ready republishes
# it under a newer revision; that is what tells a stale open page to refresh.
sed 's/<h1>one<\/h1>/<h1>two<\/h1>/' "$B" > "$B.next" && mv "$B.next" "$B"
assert_equals "$(live ready "$B")" "live: ready" "a changed board was not republished"
second_rev=$(field "$B" rev)
[ "$second_rev" -gt "$first_rev" ] || fail "a changed board kept its old revision: $second_rev"
assert_equals "$(grep -c 'fm-board-live:begin' "$B")" 1 "republishing duplicated the live block"

# A whole rewrite drops the block. stamp restores it without claiming the board
# is ready, under a revision the recorded state does not outrank.
live working "$B" >/dev/null
board "$B" three
assert_equals "$(field "$B" stamped)" no "fixture invalid: the rewrite kept the block"
assert_equals "$(live stamp "$B")" "live: stamped" "a rewritten board could not be stamped"
assert_equals "$(field "$B" state) $(field "$B" rev)" "working $second_rev" "stamp changed the recorded state"
assert_equals "$(live stamp "$B")" "live: stamped (unchanged)" "stamping twice rewrote the board"
assert_equals "$(live ready "$B")" "live: ready" "the rebuilt board could not be handed back"
[ "$(field "$B" rev)" -gt "$second_rev" ] || fail "a rebuilt board was handed back under a revision an open page already holds"
pass "an edited or rebuilt board is republished under a newer revision"

chmod 600 "$B"
board "$B" four
live ready "$B" >/dev/null
assert_equals "$(perl -e 'printf "%o %o\n", map { (stat $_)[2] & 07777 } @ARGV' "$B" "$B.live.js")" "600 600" \
  "a private board or its state file became readable by others"
NOBODY="$TMP_ROOT/fragment.html"
printf '<h1>no body tag</h1>' > "$NOBODY"
assert_equals "$(live ready "$NOBODY")" "live: ready" "a board without a closing body tag was refused"
assert_equals "$(live ready "$NOBODY")" "live: ready (unchanged)" "a board without a closing body tag never settles"
out=$(live ready "$TMP_ROOT/absent.html") && fail "a missing board was accepted: $out"
assert_contains "$out" "board does not exist" "the missing-board refusal did not say why: $out"
out=$(live publish "$B") && fail "an unknown command was accepted: $out"
assert_contains "$out" "usage:" "the unknown-command refusal did not print usage: $out"
pass "file modes survive, a bodiless board settles, and bad input is refused"

# A board git tracks is project source and is never changed behind its owner.
if command -v git >/dev/null 2>&1; then
  REPO="$TMP_ROOT/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  board "$REPO/tracked.html" tracked
  board "$REPO/scratch.html" scratch
  git -C "$REPO" add tracked.html
  before=$(cksum < "$REPO/tracked.html")
  assert_equals "$(live ready "$REPO/tracked.html")" "live: skipped (tracked file)" "a tracked board was stamped"
  assert_equals "$(live stamp "$REPO/tracked.html")" "live: skipped (tracked file)" "a tracked board was stamped"
  assert_equals "$(cksum < "$REPO/tracked.html")" "$before" "a tracked board was modified"
  assert_absent "$REPO/tracked.html.live.js" "a tracked board gained a state file"
  assert_equals "$(live ready "$REPO/scratch.html")" "live: ready" "an untracked board in a repository was refused"
  pass "a tracked board is left alone while an untracked one beside it is stamped"
else
  printf '%s\n' 'skip - the tracked-file guard requires git'
fi

# --- what an open page does with it ------------------------------------------
PAGE="$TMP_ROOT/page board.html"
board "$PAGE" page
live ready "$PAGE" >/dev/null
if command -v node >/dev/null 2>&1; then
  node "$ROOT/tests/fm-board-live-page.test.js" "$PAGE" || fail "the open-page behavior checks failed"
else
  printf '%s\n' 'skip - the open-page behavior checks require node'
fi

# --- the Lavish adapter drives it --------------------------------------------
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR"
lavish_session() {  # <artifact>
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = { key => $key, file => decode("UTF-8", $real), status => "open",
      url => "http://127.0.0.1:14387/session/0123456789abcdef" };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1"
}
STUB=$(fm_fakebin "$TMP_ROOT/lavish-stub")
cat > "$STUB/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for the published poll: it blocks until the response file appears,
# so a live listener here is a live process, and the wait is bounded so a
# listener that escapes its test cannot run for as long as the host stays up.
case "${1-}" in
  --version) printf '0.1.86\n'; exit 0 ;;
  poll)
    while [ ! -e "$LAVISH_RESPONSE" ]; do
      [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
      sleep 0.05
    done
    cat "$LAVISH_RESPONSE"
    ;;
esac
SH
chmod +x "$STUB/lavish-axi"
wait_state() {  # <board> <state>
  for _ in $(seq 1 100); do
    [ "$(field "$1" state)" = "$2" ] && return 0
    sleep 0.1
  done
  return 1
}

HOME_A="$TMP_ROOT/home"
mkdir -p "$HOME_A/state"
fm_test_track_procevent_home "$HOME_A"
ARMED="$TMP_ROOT/armed.html"
board "$ARMED" armed
lavish_session "$ARMED"
export LAVISH_RESPONSE="$TMP_ROOT/response-armed"
# A generous confirmation window: it ends as soon as the listener is live, so it
# only removes this fixture's dependence on how busy the host is.
out=$(PATH="$STUB:$PATH" FM_HOME="$HOME_A" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=60 bash "$ADAPTER" arm "$ARMED" 2>&1) \
  || fail "fixture invalid: the board could not be armed: $out"
assert_contains "$out" "armed: " "fixture invalid: arm did not confirm a listener: $out"
assert_contains "$out" "live: ready" "arm did not report the board's state line: $out"
assert_equals "$(field "$ARMED" state)" ready "an armed board does not say it is ready"
assert_equals "$(field "$ARMED" stamped)" yes "an armed board carries no live block"
printf 'session:\n  file: %s\n  status: feedback\nprompts[1]{tag,text}:\n  message,"make it bigger"\n' "$ARMED" \
  > "$LAVISH_RESPONSE.staged" && mv "$LAVISH_RESPONSE.staged" "$LAVISH_RESPONSE"
wait_state "$ARMED" working \
  || fail "feedback reached the listener but the board still says $(field "$ARMED" state)"
PATH="$STUB:$PATH" FM_HOME="$HOME_A" bash "$ADAPTER" retire "$ARMED" >/dev/null 2>&1 || true
pass "arming makes a board ready and feedback that keeps the session open makes it working"

# The listener command itself, so each published response shape is driven
# without the runner: only feedback that leaves the session open means a worker
# is about to change the board.
LISTENED="$TMP_ROOT/listened.html"
board "$LISTENED" listened
lavish_session "$LISTENED"
live ready "$LISTENED" >/dev/null
listen() {  # <response body>
  export LAVISH_RESPONSE="$TMP_ROOT/response-listened"
  printf '%b' "$1" > "$LAVISH_RESPONSE"
  PATH="$STUB:$PATH" bash "$ADAPTER" poll "$LISTENED"
}
out=$(listen 'session:\n  file: /b.html\n  status: feedback\n  session_ended: true\nfeedback[1]{text}:\n  ship it\n')
assert_contains "$out" "ship it" "the listener did not pass the final feedback through: $out"
assert_equals "$(field "$LISTENED" state)" ready "feedback that ended the session left the board saying work continues"
listen 'session:\n  file: /b.html\n  status: ended\n  ended_by: user\n' >/dev/null
assert_equals "$(field "$LISTENED" state)" ready "an empty close marked the board as being worked on"
listen 'session:\n  file: /b.html\n  status: browser_disconnected\n' >/dev/null
assert_equals "$(field "$LISTENED" state)" ready "a disconnected browser marked the board as being worked on"
response='session:\n  file: /b.html\n  status: feedback\nprompts[1]{tag,text}:\n  message,"one more change"\n'
out=$(listen "$response")
assert_equals "$out" "$(printf '%b' "$response")" "the listener altered the response it passes to the runner"
assert_equals "$(field "$LISTENED" state)" working "open-session feedback did not mark the board as being worked on"
pass "only feedback that keeps the session open flips a board to working, and the response passes through intact"
