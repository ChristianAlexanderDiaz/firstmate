#!/usr/bin/env python3
"""Recording Herdr protocol stub; only its private tmux socket runs commands."""
import fcntl
import json
import os
import subprocess
import sys
from pathlib import Path

root = Path(os.environ['FM_HERDR_FIXTURE'])
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
if '--session' in args:
    i = args.index('--session')
    del args[i:i + 2]
cmd = tuple(args[:2])

def tmux(*argv):
    return subprocess.check_output([os.environ['FM_FIXTURE_TMUX'], '-L', os.environ['FM_FIXTURE_SOCKET'], *argv], text=True).strip()

def value(flag, default=''):
    return args[args.index(flag) + 1] if flag in args else default

def emit(data):
    print(json.dumps(data))

with (root / 'mutex').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    state = json.loads((root / 'state.json').read_text())
    tabs = state['tabs']
    spaces = state['workspaces']
    if cmd == ('status', '--json'):
        emit({'client': {'version': '0.9.0', 'protocol': 22}, 'server': {'running': True, 'version': '0.9.0', 'protocol': 22}})
    elif cmd == ('session', 'list'):
        emit({'sessions': [{'name': 'fixture', 'running': True, 'socket_path': str(root / 'fake.sock')}]})
    elif cmd == ('workspace', 'list'):
        emit({'result': {'workspaces': spaces}})
    elif cmd == ('workspace', 'create') or cmd == ('tab', 'create'):
        n = state['next']
        state['next'] += 1
        ws = 'w' + str(n) if cmd[0] == 'workspace' else value('--workspace')
        tid, pid = ws + ':t' + str(n), ws + ':p' + str(n)
        target = tmux('new-window', '-d', '-P', '-F', '#{pane_id}', '-t', 'fixture', '-c', value('--cwd'), 'bash --noprofile --norc')
        if cmd[0] == 'workspace':
            spaces.append({'workspace_id': ws, 'label': value('--label'), 'active_tab_id': tid, 'focused': False})
        tab = {'tab_id': tid, 'pane_id': pid, 'workspace_id': ws, 'label': '1' if cmd[0] == 'workspace' else value('--label'), 'target': target, 'focused': False}
        tabs.append(tab)
        emit({'result': {'workspace': {'workspace_id': ws}, 'tab': {'tab_id': tid}, 'root_pane': {'pane_id': pid}}})
    elif cmd == ('tab', 'list') or cmd == ('pane', 'list'):
        rows = [t for t in tabs if t['workspace_id'] == value('--workspace')]
        emit({'result': {'tabs' if cmd[0] == 'tab' else 'panes': rows}})
    elif cmd == ('tab', 'get') or cmd == ('pane', 'get'):
        field = 'tab_id' if cmd[0] == 'tab' else 'pane_id'
        row = next((t.copy() for t in tabs if t[field] == args[2]), None)
        if row is None:
            emit({'error': {'code': 'pane_not_found'}})
        else:
            row['foreground_cwd'] = tmux('display-message', '-p', '-t', row['target'], '#{pane_current_path}')
            emit({'result': {cmd[0]: row}})
    elif cmd == ('agent', 'get'):
        emit({'error': {'code': 'agent_not_found'}})
    elif cmd == ('terminal', 'title'):
        emit({'result': {'reason': 'no_foreground_client'}})
    elif cmd[0] == 'pane' and cmd[1] in ('run', 'send-text', 'send-keys', 'read', 'close'):
        row = next(t for t in tabs if t['pane_id'] == args[2])
        target = row['target']
        if cmd[1] in ('run', 'send-text'):
            tmux('send-keys', '-t', target, '-l', args[3])
            if cmd[1] == 'run':
                tmux('send-keys', '-t', target, 'Enter')
        elif cmd[1] == 'send-keys':
            tmux('send-keys', '-t', target, *[{'enter': 'Enter', 'ctrl+c': 'C-c', 'escape': 'Escape'}.get(k, k) for k in args[3:]])
        elif cmd[1] == 'read':
            print(tmux('capture-pane', '-p', '-t', target, '-S', '-200'))
        else:
            tmux('kill-pane', '-t', target)
            tabs.remove(row)
            if not any(t['workspace_id'] == row['workspace_id'] for t in tabs):
                spaces[:] = [w for w in spaces if w['workspace_id'] != row['workspace_id']]
            emit({'result': {'removed': True}})
    elif cmd == ('pane', 'process-info'):
        emit({'result': {'process_info': {}}})
    else:
        print('unsupported fixture call: ' + repr(args), file=sys.stderr)
        sys.exit(1)
    (root / 'state.json').write_text(json.dumps(state))
