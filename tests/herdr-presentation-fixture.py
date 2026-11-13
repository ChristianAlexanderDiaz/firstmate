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
    if args[i + 1] != os.environ['HERDR_LAB_SESSION']:
        sys.exit('wrong fixture session')
    del args[i:i + 2]
else:
    sys.exit('explicit fixture session required')
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
    # Production may retire a shell by PID instead of issuing pane.close.
    targets = set(tmux('list-panes', '-a', '-F', '#{pane_id}').splitlines())
    with (root / 'calls.jsonl').open('a') as log:
        for t in tabs:
            if t['target'] not in targets:
                log.write(json.dumps({'event': 'pane-exited', 'pane_id': t['pane_id'], 'workspace_id': t['workspace_id']}) + '\n')
    tabs[:] = [t for t in tabs if t['target'] in targets]
    spaces[:] = [w for w in spaces if any(t['workspace_id'] == w['workspace_id'] for t in tabs)]
    for w in spaces:
        rows = [t for t in tabs if t['workspace_id'] == w['workspace_id']]
        w['tab_count'] = w['pane_count'] = len(rows)
        if w['active_tab_id'] not in [t['tab_id'] for t in rows]:
            w['active_tab_id'] = rows[0]['tab_id']

    def focus(row):
        for w in spaces:
            w['focused'] = w['workspace_id'] == row['workspace_id']
            if w['focused']:
                w['active_tab_id'] = row['tab_id']
        for t in tabs:
            t['focused'] = t['tab_id'] == row['tab_id']

    def missing(kind):
        emit({'error': {'code': kind + '_not_found'}})
        (root / 'state.json').write_text(json.dumps(state))
        sys.exit(1)

    if cmd == ('status', '--json'):
        emit({'client': {'version': '0.9.0', 'protocol': 22}, 'server': {'running': True, 'version': '0.9.0', 'protocol': 22}})
    elif cmd == ('session', 'list'):
        emit({'sessions': [{'name': os.environ['HERDR_LAB_SESSION'], 'running': True, 'socket_path': str(root / 'fake.sock')}]})
    elif cmd == ('api', 'snapshot'):
        emit({'result': {'snapshot': {'workspaces': spaces, 'tabs': tabs, 'panes': tabs}}})
    elif cmd == ('api', 'schema'):
        emit({'result': {'commands': []}})
    elif cmd == ('workspace', 'get'):
        row = next((w for w in spaces if w['workspace_id'] == args[2]), None)
        if row is None:
            missing('workspace')
        emit({'result': {'workspace': row}})
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
        if '--focus' in args:
            focus(tab)
        emit({'result': {'workspace': {'workspace_id': ws}, 'tab': {'tab_id': tid}, 'root_pane': {'pane_id': pid}}})
    elif cmd == ('tab', 'list') or cmd == ('pane', 'list'):
        rows = [t for t in tabs if t['workspace_id'] == value('--workspace')]
        emit({'result': {'tabs' if cmd[0] == 'tab' else 'panes': rows}})
    elif cmd == ('tab', 'get') or cmd == ('pane', 'get'):
        field = 'tab_id' if cmd[0] == 'tab' else 'pane_id'
        row = next((t.copy() for t in tabs if t[field] == args[2]), None)
        if row is None:
            missing(cmd[0])
        else:
            row['foreground_cwd'] = tmux('display-message', '-p', '-t', row['target'], '#{pane_current_path}')
            emit({'result': {cmd[0]: row}})
    elif cmd == ('tab', 'focus'):
        focus(next(t for t in tabs if t['tab_id'] == args[2]))
        emit({'result': {'focused': True}})
    elif cmd == ('agent', 'get'):
        row = next((t for t in tabs if t['pane_id'] == args[2]), {})
        if 'agent' in row:
            emit({'result': {'agent': row['agent']}})
        else:
            emit({'error': {'code': 'agent_not_found'}})
    elif cmd == ('pane', 'report-agent'):
        row = next(t for t in tabs if t['pane_id'] == args[2])
        row['agent'] = {'agent_status': value('--state'), 'agent_name': value('--agent')}
        emit({'result': {'reported': True}})
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
        pane = value('--pane', args[2])
        row = next((t for t in tabs if t['pane_id'] == pane), None)
        if row is None:
            missing('pane')
        pid = int(tmux('display-message', '-p', '-t', row['target'], '#{pane_pid}'))
        pgid = int(subprocess.check_output(['ps', '-p', str(pid), '-o', 'tpgid='], text=True))
        processes = []
        for line in subprocess.check_output(['ps', '-axo', 'pid=,pgid=,comm=,args='], text=True).splitlines():
            parts = line.split(None, 3)
            if len(parts) == 4 and int(parts[1]) == pgid:
                processes.append({'pid': int(parts[0]), 'name': parts[2], 'argv': parts[3].split()})
        emit({'result': {'type': 'pane_process_info', 'process_info': {
            'pane_id': pane, 'shell_pid': pid, 'foreground_process_group_id': pgid,
            'foreground_processes': processes}}})
    else:
        print('unsupported fixture call: ' + repr(args), file=sys.stderr)
        sys.exit(1)
    (root / 'state.json').write_text(json.dumps(state))
