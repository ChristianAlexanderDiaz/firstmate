#!/usr/bin/env bash
# fm-board-live.sh - keep an open review board current and say whose turn it is (Python 3).
#
# Usage:
#   fm-board-live.sh ready <board.html>
#   fm-board-live.sh working <board.html>
#   fm-board-live.sh stamp <board.html>
#   fm-board-live.sh status <board.html>
#
# ready      Stamp the board, then record that it waits for the captain. The
#            open page shows "Ready for you, updated HH:MM" in the viewer's
#            local time. Repeating it on an unchanged board changes nothing, so
#            the shown time is when this version was published.
# working    Record that a worker is on the board. The open page shows "Working
#            on your changes". The board file is not touched. A board that was
#            never made ready has no state to change and prints `live: none`.
# stamp      Embed the live block without changing the recorded state, for a
#            builder that rewrites a whole board while its worker is still on it.
# status     Print `state=<ready|working|none> at=<epoch> rev=<n> stamped=<yes|no>`.
#
# THE CALLERS. Nobody runs ready or working by hand in the board loop:
# bin/fm-procevent-lavish.sh makes a board ready on every successful arm and
# working when its listener receives feedback that does not end the session,
# and bin/fm-plan-board.sh build stamps what it writes. A board rewritten whole
# by hand loses its block until the next arm; run stamp after such a rewrite to
# keep the line on screen while the work continues.
#
# THE CONTRACT has two halves, both owned here.
# The live block is one script between `<!-- fm-board-live:begin -->` and
# `<!-- fm-board-live:end -->`, placed before the closing body tag. It carries
# the board file name, a revision that only grows, and a digest of the board
# without the block. Its source is .agents/skills/crewmate-briefs/assets/board-live.js.
# The state file is `<board file name>.live.js` beside the board, a one-line
# script the page loads every two seconds (every fifteen while hidden). A script
# is the only thing the page can read there: Lavish frames a board without an
# origin, so it cannot fetch, reload the outer page, or keep storage.
#
# WHAT THE PAGE DOES WITH IT. It draws one line at the top of the board from the
# recorded state. When the state file names a newer revision than the page
# carries and Lavish's own live reload has not replaced the page within three
# seconds, the page reloads its own frame, but only after proving its Lavish
# page load is still the current one; a frame Lavish has retired would reload
# into an error page. It reloads at most once per revision. When it cannot
# refresh itself, the line says a newer version is ready and to reload the tab.
# Scroll position is restored by Lavish on every frame load.
#
# A TRACKED FILE IS NEVER STAMPED. A board that git tracks is project source,
# so ready and stamp leave it alone, write no state file, and print
# `live: skipped (tracked file)`.
set -eu
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# \{0,1\}//'
  exit 0
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 - "$ROOT/.agents/skills/crewmate-briefs/assets/board-live.js" "$@" <<'PY'
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

BEGIN = '<!-- fm-board-live:begin -->'
END = '<!-- fm-board-live:end -->'
BLOCK = re.compile(re.escape(BEGIN) + r'.*?' + re.escape(END) + r'\n?', re.S)
CONFIG = re.compile(r'<script data-fm-board-live="([^"]*)">')
PREFIX = 'window.__fmBoardLive&&window.__fmBoardLive('
SUFFIX = ');\n'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def write(path, text, like):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as output:
            temporary = output.name
            output.write(text)
        shutil.copymode(like, temporary)
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def block(snippet, name, rev, content):
    config = json.dumps({'v': 1, 'name': name, 'rev': rev, 'content': content}, separators=(',', ':'))
    return (BEGIN + '\n<script data-fm-board-live="' + html.escape(config, quote=True) + '">\n'
            + snippet.rstrip('\n') + '\n</script>\n' + END + '\n')


def stamped(text):
    found = BLOCK.search(text)
    if not found:
        return None, None
    config = CONFIG.search(found.group())
    try:
        data = json.loads(html.unescape(config.group(1)))
        return found.group(), {'rev': int(data['rev']), 'content': str(data['content'])}
    except (AttributeError, KeyError, TypeError, ValueError):
        return found.group(), {'rev': 0, 'content': ''}


def recorded(sidecar):
    try:
        text = sidecar.read_text(encoding='utf-8')
        require(text.startswith(PREFIX) and text.endswith(SUFFIX), 'unreadable')
        data = json.loads(text[len(PREFIX):-len(SUFFIX)])
        return {'state': str(data['state']), 'at': int(data['at']), 'rev': int(data['rev']),
                'content': str(data['content'])}
    except (OSError, KeyError, TypeError, ValueError):
        return None


def record(board, sidecar, state, at, rev, content):
    payload = {'v': 1, 'name': board.name, 'state': state, 'at': at, 'rev': rev, 'content': content}
    write(sidecar, PREFIX + json.dumps(payload, separators=(',', ':')) + SUFFIX, board)


def tracked(board):
    try:
        return subprocess.run(['git', '-C', str(board.parent), 'ls-files', '--error-unmatch', '--', board.name],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


def stamp(board, snippet, floor):
    """Make the board carry a current block; return its revision and digest."""
    text = board.read_text(encoding='utf-8')
    existing, config = stamped(text)
    bare = BLOCK.sub('', text)
    content = hashlib.sha256(bare.rstrip('\n').encode('utf-8')).hexdigest()[:16]
    if (existing and config['content'] == content and config['rev'] >= floor
            and existing == block(snippet, board.name, config['rev'], content)):
        return config['rev'], content, False
    rev = max(int(time.time() * 1000), floor + 1, (config['rev'] + 1) if config else 0)
    fresh = block(snippet, board.name, rev, content)
    close = list(re.finditer(r'</body\s*>', bare, re.I))
    if close:
        at = close[-1].start()
        text = bare[:at] + fresh + bare[at:]
    else:
        text = bare + ('' if bare.endswith('\n') else '\n') + fresh
    write(board, text, board)
    return rev, content, True


try:
    source, *args = sys.argv[1:]
    require(len(args) == 2 and args[0] in ('ready', 'working', 'stamp', 'status'),
            'usage: fm-board-live.sh ready|working|stamp|status <board.html>')
    command = args[0]
    board = Path(os.path.realpath(args[1]))
    require(board.is_file(), 'board does not exist: ' + args[1])
    sidecar = board.with_name(board.name + '.live.js')
    state = recorded(sidecar)
    now = int(time.time())
    if command == 'status':
        _, config = stamped(board.read_text(encoding='utf-8'))
        print('state=%s at=%d rev=%d stamped=%s' % (
            state['state'] if state else 'none', state['at'] if state else 0,
            state['rev'] if state else 0, 'yes' if config else 'no'))
    elif command == 'working':
        if not state:
            print('live: none')
        else:
            if state['state'] != 'working':
                record(board, sidecar, 'working', now, state['rev'], state['content'])
            print('live: working')
    elif tracked(board):
        print('live: skipped (tracked file)')
    else:
        snippet = Path(source).read_text(encoding='utf-8')
        require('</script' not in snippet.lower(), 'invalid live block source')
        rev, content, changed = stamp(board, snippet, state['rev'] if state else 0)
        if command == 'stamp':
            print('live: stamped' + ('' if changed else ' (unchanged)'))
        elif state and state['state'] == 'ready' and state['rev'] == rev and state['content'] == content:
            print('live: ready (unchanged)')
        else:
            record(board, sidecar, 'ready', now, rev, content)
            print('live: ready')
except (OSError, ValueError) as error:
    sys.exit('fm-board-live: ' + str(error))
PY
