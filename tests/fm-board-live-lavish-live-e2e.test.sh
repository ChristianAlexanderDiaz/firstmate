#!/usr/bin/env bash
# tests/fm-board-live-lavish-live-e2e.test.sh - live drift guard proving the
# real lavish-axi still behaves the way the board live block
# (.agents/skills/crewmate-briefs/assets/board-live.js, owned by
# bin/fm-board-live.sh) is written against.
#
# Why this file exists: an open board refreshes itself by leaning on four things
# only Lavish decides, and a release can change any of them without notice. A
# stubbed page can only confirm the assumption already written into the stub, so
# each assumption gets a run against the real server:
#
#   1. A file beside the board is served to the board's frame as a script, with
#      no page-load token. That is how the page reads its state file.
#   2. The served board carries Lavish's own script as `/sdk.js?...`, and that
#      address answers while the page load is current even with an extra
#      parameter. That is the page's "is my load still current" check.
#   3. Asking again for the board under a page load that is still current
#      returns the board as it is now on disk. That is the self-refresh.
#   4. Once the session is opened again, the earlier page load is refused for
#      both addresses. That is what keeps a retired page from reloading itself
#      into Lavish's error page.
#
# The page-load handshake is spoken with curl exactly as Lavish's own page
# speaks it, so no browser is needed. The server is this guard's own: a private
# state directory and port, never the shared one, and it is stopped before the
# guard returns.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-board-live.test.sh pins the page's logic
# against stand-ins for these shapes. Run this guard after a lavish-axi upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BOARD_LIVE_LAVISH_LIVE lavish-axi curl python3 lsof

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
PORT=''
cleanup() {
  local pid
  if [ -n "$PORT" ]; then
    pid=$(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1)
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  fi
  [ -z "$LAB" ] || rm -rf "$LAB"
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
VERSION=${VERSION:-version-unknown}
note "lavish-axi $VERSION"
revisit="the board live block must be revisited (bin/fm-board-live.sh)"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-live-lavish.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])') \
  || fail "cannot pick a free port for the guard server"
export LAVISH_AXI_STATE_DIR="$LAB/state" LAVISH_AXI_PORT="$PORT" LAVISH_AXI_HOST=127.0.0.1
export LAVISH_AXI_NO_OPEN=1 LAVISH_AXI_TELEMETRY=0
unset LAVISH_AXI_LINK_HOST
mkdir -p "$LAVISH_AXI_STATE_DIR"

BOARD="$LAB/guard board.html"
write_board() { printf '<!doctype html>\n<html><body>\n<h1>GUARD-%s</h1>\n</body>\n</html>\n' "$1" > "$BOARD"; }
write_board ONE
bash "$ROOT/bin/fm-board-live.sh" ready "$BOARD" >/dev/null || fail "the guard board could not be made ready"

url=$(lavish-axi "$BOARD" 2>/dev/null | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  "http://127.0.0.1:$PORT/session/"*) ;;
  *) fail "the guard board did not open on its own server: ${url:-no url}" ;;
esac
key=${url##*/}
base=${url%/session/*}

status_and_type() {  # <url>: print "<http status> <content type>"
  curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' "$1"
}
# One page load, opened the way Lavish's own page opens it: read the handoff
# from the session page, then begin an artifact load. Prints "<revision> <token>".
begin_load() {  # <request id>
  curl -sS "$url" | python3 -c '
import json, re, sys, urllib.request
page = sys.stdin.read()
data = json.loads(re.search(r"<script id=\"lavish-session\" type=\"application/json\">(.*?)</script>", page, re.S).group(1))
body = json.dumps({"request_id": sys.argv[2], "request_sequence": 1, "chrome_load_token": data["chromeLoadToken"]}).encode()
request = urllib.request.Request(sys.argv[1], data=body, headers={"content-type": "application/json"})
load = json.load(urllib.request.urlopen(request, timeout=10))
print(load["artifact_revision"], load["artifact_load_token"])
' "$base/api/$key/artifact-loads/begin" "$1"
}

# ASSUMPTION 1: the state file beside the board is served as a script, no token.
state_url="$base/artifact/$key/guard%20board.html.live.js"
served=$(status_and_type "$state_url")
case "$served" in
  "200 "*javascript*) ;;
  *) fail "lavish-axi $VERSION serves a file beside the board as [$served], not as a script; $revisit" ;;
esac
[ "$(curl -sS "$state_url")" = "$(cat "$BOARD.live.js")" ] \
  || fail "lavish-axi $VERSION served different bytes than the state file beside the board; $revisit"
pass "lavish-axi $VERSION serves the state file beside a board as a script without a page-load token"

load=$(begin_load fm-board-live-guard-1 2>/dev/null) \
  || fail "lavish-axi $VERSION no longer accepts the page-load handshake this guard speaks; re-verify in a browser, then $revisit"
revision=${load%% *}
token=${load#* }
board_url="$base/artifact/$key/index.html?artifact_revision=$revision&artifact_load_token=$token"

# ASSUMPTION 2: the served board names Lavish's script, and it answers the probe.
page=$(curl -sS "$board_url")
case "$page" in
  *GUARD-ONE*) ;;
  *) fail "lavish-axi $VERSION did not serve the board to a current page load; $revisit" ;;
esac
sdk=$(printf '%s' "$page" | sed -n 's/.*<script src="\(\/sdk\.js?[^"]*\)".*/\1/p' | head -1)
[ -n "$sdk" ] || fail "lavish-axi $VERSION no longer adds a /sdk.js? script to the served board; $revisit"
probed=$(status_and_type "$base$sdk&fm_board_live=1")
case "$probed" in
  "200 "*javascript*) ;;
  *) fail "lavish-axi $VERSION answers the current-load probe with [$probed]; $revisit" ;;
esac
pass "lavish-axi $VERSION adds its script to the served board and answers it while the page load is current"

# ASSUMPTION 3: the same page load, asked again, gets the board as it is now.
write_board TWO
bash "$ROOT/bin/fm-board-live.sh" ready "$BOARD" >/dev/null || fail "the changed guard board could not be made ready"
page=$(curl -sS "$board_url")
case "$page" in
  *GUARD-TWO*) ;;
  *) fail "lavish-axi $VERSION no longer returns the changed board to a page load that is still current; $revisit" ;;
esac
pass "lavish-axi $VERSION returns the changed board when a still-current page load asks again"

# ASSUMPTION 4: a second open retires the first page load for both addresses.
begin_load fm-board-live-guard-2 >/dev/null 2>&1 \
  || fail "lavish-axi $VERSION refused a second page load on the same session; re-verify in a browser, then $revisit"
retired_probe=$(status_and_type "$base$sdk&fm_board_live=2")
retired_board=$(curl -sS -o "$LAB/retired.html" -w '%{http_code}' "$board_url")
case "$retired_probe" in
  2*) fail "lavish-axi $VERSION still answers the probe for a retired page load, so a retired page would reload itself; $revisit" ;;
esac
case "$retired_board" in
  2*) note "lavish-axi $VERSION now serves the board to a retired page load (status $retired_board)" ;;
esac
pass "lavish-axi $VERSION refuses the probe once another page load has taken the session"
