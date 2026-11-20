#!/usr/bin/env bash
# Serial hermetic sidebar lab. Every Herdr call is intercepted; no server starts.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-sidebar-lib.sh
. "$ROOT/bin/fm-sidebar-lib.sh"
fm_sidebar_classify 'state: failed · source: status-log · failure' alive secondmate no no '' '' '' no
[ "$FM_SIDEBAR_WORD" = 'Needs me' ] || fail 'failed secondmate must not read as healthy Idle'
TMP_ROOT=$(fm_test_tmproot fm-sidebar)
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/data" "$TMP_ROOT/bin" "$TMP_ROOT/fakebin"
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
export FM_DATA_OVERRIDE="$TMP_ROOT/home/data" FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config"
export PATH="$TMP_ROOT/fakebin:$PATH"
export LAB_LOG="$TMP_ROOT/metadata.jsonl" LAB_CALLS="$TMP_ROOT/relaunch.txt"
export LAB_AGENT=alive LAB_HOLD=1 LAB_UNSUPPORTED=0 LAB_SHELL=$$
unset FM_RESOURCE_CONFIG FM_SIDEBAR_CURRENT_LINE FM_SIDEBAR_RUN_OUT
# Copy the executable so sibling script lookups stay inside this disposable lab.
# Real libraries are linked, while authority/control readers are boundary stubs.
for file in "$ROOT"/bin/*; do ln -s "$file" "$TMP_ROOT/bin/${file##*/}"; done
rm "$TMP_ROOT/bin/fm-captain-hold.sh" "$TMP_ROOT/bin/fm-control.sh" "$TMP_ROOT/bin/fm-resource-run"
cat > "$TMP_ROOT/bin/fm-captain-hold.sh" <<'STUB'
#!/usr/bin/env bash
if [ "${LAB_MUTATE_META:-0}" = 1 ]; then printf 'changed=1\n' >> "$FM_HOME/state/sample.meta"; fi
if [ "${LAB_WAKE_AGENT:-0}" = 1 ]; then printf 'alive\n' > "$LAB_AGENT_FILE"; fi
exit "$LAB_HOLD"
STUB
cat > "$TMP_ROOT/bin/fm-control.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAB_CALLS"
STUB
cat > "$TMP_ROOT/bin/fm-resource-run" <<'STUB'
#!/usr/bin/env bash
if [ -n "${LAB_BUDGET:-}" ]; then cat "$LAB_BUDGET"; else printf '{}\n'; fi
STUB
cat > "$TMP_ROOT/fakebin/crew-state" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$LAB_LINE" "$LAB_RUN"
STUB
cat > "$TMP_ROOT/fakebin/no-mistakes" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${LAB_CI:-}"
STUB
cat > "$TMP_ROOT/fakebin/herdr" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
assert a[-2:] == ['--session', 'lab'], 'unscoped Herdr call'
a = a[:-2]
result = {}
if a[:2] in (['workspace', 'report-metadata'], ['pane', 'report-metadata']):
    if os.environ['LAB_UNSUPPORTED'] == '1': sys.exit(1)
    if '--help' in a: sys.exit(0)
    with open(os.environ['LAB_LOG'], 'a') as f: f.write(json.dumps(a) + '\n')
elif a[:2] == ['workspace', 'list']:
    tokens = {}
    if os.path.exists(os.environ['LAB_LOG']):
        for line in open(os.environ['LAB_LOG']):
            call = json.loads(line)
            if call[:2] == ['workspace', 'report-metadata']:
                tokens.update(item.split('=', 1) for item in call if item.startswith('fm_status'))
    result = {'workspaces': [{'workspace_id': 'w1', 'tokens': tokens}]}
elif a[:2] == ['pane', 'get']:
    result = {'pane': {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1'}}
elif a[:2] == ['pane', 'list']:
    result = {'panes': [{'pane_id': 'w1:p1', 'workspace_id': 'w1'}]}
    if os.environ.get('LAB_SHARED') == '1':
        result['panes'].append({'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tokens': {
            'fm_status': os.environ.get('LAB_OTHER_WORD', 'Needs me'),
            'fm_status_detail': 'other pane detail'}})
elif a[:2] == ['agent', 'get']:
    agent = os.environ['LAB_AGENT']
    if os.environ.get('LAB_AGENT_FILE'):
        agent = open(os.environ['LAB_AGENT_FILE']).read().strip()
    if agent == 'dead':
        print(json.dumps({'error': {'code': 'agent_not_found'}})); sys.exit(1)
    result = {'agent': {'agent_status': os.environ.get('LAB_BUSY', 'working')}}
elif a[:2] == ['pane', 'process-info']:
    result = {'type': 'pane_process_info', 'process_info': {
        'pane_id': 'w1:p1', 'shell_pid': int(os.environ['LAB_SHELL']),
        'foreground_processes': [{'pid': os.getppid(), 'name': 'sleep', 'argv': ['sleep', '1']}]}}
else:
    raise AssertionError('unexpected Herdr operation: ' + repr(a))
print(json.dumps({'result': result}))
STUB
chmod +x "$TMP_ROOT/fakebin/"* "$TMP_ROOT/bin/fm-captain-hold.sh" "$TMP_ROOT/bin/fm-control.sh" "$TMP_ROOT/bin/fm-resource-run"
export FM_CREW_STATE_BIN="$TMP_ROOT/fakebin/crew-state"
export LAB_RUN='' LAB_LINE='state: working · source: pane · busy'
write_meta() {
  cat > "$FM_HOME/state/sample.meta" <<EOF
window=lab:w1:p1
endpoint_task_id=sample
worktree=$TMP_ROOT
project=$TMP_ROOT
kind=${1:-ship}
backend=herdr
herdr_session=lab
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
EOF
}
write_meta
script="$TMP_ROOT/bin/fm-sidebar-state.sh"
if [ -n "${FM_SIDEBAR_BASELINE_BIN:-}" ]; then
  bash "$FM_SIDEBAR_BASELINE_BIN" sync
fi
herdr workspace list --session lab > "$TMP_ROOT/before.json"
expect() {
  local wanted=$1 got
  got=$(bash "$script" sample)
  case "$got" in "$wanted - "*) ;; *) fail "expected $wanted, got $got" ;; esac
  bash "$script" sample --refresh
  python3 - "$LAB_LOG" "$wanted" <<'PY'
import json, sys
args = json.loads(open(sys.argv[1]).readlines()[-1])
assert 'fm_status=' + sys.argv[2] in args, args
assert args[args.index('--source')+1] == 'firstmate-status'
print('metadata:', sys.argv[2], next(a for a in args if a.startswith('fm_status_detail=')))
PY
}
expect Working
export LAB_LINE='state: working · source: run-step · ci running' LAB_BUSY=idle
expect Checking
[[ $(bash "$script" sample) == *'agent idle'* ]] || fail 'idle agent detail absent'
export LAB_BUSY=unknown
[ -z "$(bash "$script" sample)" ] || fail 'unknown agent activity must not claim Working'
unset LAB_BUSY
export LAB_AGENT=dead LAB_LINE='state: working · source: run-step · ci running · run: run1'
export LAB_RUN=$'run:\n  id: run1\n  status: ci\n  pr: https://example.invalid/review/7' LAB_CI='CI checks 18/22'
expect Checking
[[ $(bash "$script" sample) == *'CI 18/22 - no agent'* ]] || fail 'CI count or no-agent detail absent'
export LAB_HOLD=0
expect 'Needs you'
[[ $(bash "$script" sample) == *'https://example.invalid/review/7'* ]] || fail 'captain review link absent'
export LAB_HOLD=1 LAB_LINE='state: parked · source: run-step · parked at review · ask-user: authority decision · run: run1'
export LAB_RUN=$'run:\n  id: run1\n  status: awaiting_approval\nfindings[1]{id,action}:\n  F1,ask-user'
expect 'Needs me'
bash "$script" sample --refresh
[ "$(wc -l < "$LAB_CALLS")" -eq 1 ] || fail 'gate relaunched more than once'
grep -q 'findings file .*sidebar-gate.txt' "$LAB_CALLS" || fail 'relaunch note omitted findings'
pass 'Checking transition recovers exactly once and names gate findings'
# Ownership must be positively known before recovering a current gate.
export LAB_LINE='state: working · source: run-step · ci running · run: run2'
export LAB_RUN=$'run:\n  id: run2\n  status: ci'
bash "$script" sample --refresh
export LAB_LINE='state: parked · source: run-step · parked at lint · run: run2'
export LAB_RUN=$'run:\n  id: run2\n  status: awaiting_approval'
for LAB_HOLD in 0 2 3; do
  export LAB_HOLD
  bash "$script" sample --refresh
done
[ "$(wc -l < "$LAB_CALLS")" -eq 1 ] || fail 'unknown or captain ownership relaunched a gate'
export LAB_HOLD=1
printf 'paused [wait=captain]: review requested\n' > "$FM_HOME/state/sample.status"
bash "$script" sample --refresh
[ "$(wc -l < "$LAB_CALLS")" -eq 1 ] || fail 'captain status wait relaunched a gate'
rm "$FM_HOME/state/sample.status"
export LAB_RUN=$'run:\n  id: replacement\n  status: awaiting_approval'
export LAB_LINE='state: parked · source: run-step · parked at review · run: replacement'
bash "$script" sample --refresh
[ "$(wc -l < "$LAB_CALLS")" -eq 2 ] || fail 'current unattended replacement gate was not recovered'
pass 'captain holds and unknown ownership prevent relaunch; current gates need no history'
for fresh in between_sweeps late_watcher; do
  rm -f "$FM_HOME/state/sample.sidebar"
  export LAB_RUN="run:
  id: $fresh
  status: awaiting_approval"
  export LAB_LINE="state: parked · source: run-step · parked at review · run: $fresh"
  expect 'Needs me'
  bash "$script" sample --refresh
done
[ "$(wc -l < "$LAB_CALLS")" -eq 4 ] || fail 'unobserved gates did not each recover exactly once'
pass 'between-sweeps and late-watcher gates recover once without Checking history'
call_count=$(wc -l < "$LAB_CALLS")
export LAB_LINE='state: working · source: run-step · ci running · run: run4'
export LAB_RUN=$'run:\n  id: run4\n  status: ci'
bash "$script" sample --refresh
export LAB_LINE='state: parked · source: run-step · parked at lint · run: run4'
export LAB_RUN=$'run:\n  id: run4\n  status: awaiting_approval' LAB_MUTATE_META=1
bash "$script" sample --refresh
[ "$(wc -l < "$LAB_CALLS")" -eq "$call_count" ] || fail 'changed endpoint metadata allowed stale recovery'
unset LAB_MUTATE_META
export LAB_AGENT_FILE="$TMP_ROOT/agent" LAB_WAKE_AGENT=1
printf 'dead\n' > "$LAB_AGENT_FILE"
bash "$script" sample --refresh
[ "$(wc -l < "$LAB_CALLS")" -eq "$call_count" ] || fail 'an agent that returned during the read was relaunched'
unset LAB_AGENT_FILE LAB_WAKE_AGENT
pass 'changed metadata and a returning agent refuse stale recovery'
rm -f "$FM_HOME/state/sample.sidebar"
export LAB_LINE='state: paused · source: status-log · waiting' LAB_RUN=''
expect Stuck
export LAB_AGENT=alive LAB_LINE='state: blocked · source: status-log · help needed'
expect 'Needs me'
bash "$script" sample --refresh
[ ! -s "$FM_HOME/state/.wake-queue" ] || fail 'display duplicated the watcher alert owner'
export LAB_LINE='state: done · source: run-step · run passed: PR merged'
expect Done
export LAB_LINE='state: done · source: run-step · run passed: PR state unknown (unreadable)'
[ -z "$(bash "$script" sample)" ] || fail 'unknown completion must not request captain action'
export LAB_LINE='state: done · source: run-step · run passed: PR open'
expect 'Needs you'
export LAB_AGENT=dead LAB_LINE='state: working · source: run-step · ci running · run: run3'
export LAB_RUN=$'run:\n  id: run3\n  status: ci' LAB_CI='CI runner queued'
expect 'Waiting for machine'
export LAB_CI='CI checks 19/22'
expect Checking
export LAB_AGENT=alive LAB_RUN='' LAB_CI=''
write_meta secondmate
export LAB_LINE='state: paused · source: status-log · ready'
export LAB_BUSY=idle
expect Idle
export LAB_BUSY=working
expect Working
export LAB_BUSY=idle LAB_LINE='state: working · source: status-log · old working declaration'
expect Idle
unset LAB_BUSY
pass 'secondmate busy and idle follow backend state, not stale declarations'
write_meta
# Positive kernel evidence: a child listener in the exact pane-shell subtree.
python3 - "$TMP_ROOT/ready" <<'PY' &
import pathlib, socket, sys, time
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen()
pathlib.Path(sys.argv[1]).touch()
time.sleep(120)
PY
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fm_test_cleanup' EXIT
for ((i=0;i<100;i++)); do [ ! -f "$TMP_ROOT/ready" ] || break; sleep 0.1; done
export LAB_AGENT=dead
expect Serving
export LAB_BUDGET="$TMP_ROOT/budget.json" FM_RESOURCE_CONFIG="$TMP_ROOT/budget-config"
printf '{"reason":"ready","queue":[{"task":"sample","controller":{"pid":%s},"waitedSeconds":720}]}' "$server" > "$LAB_BUDGET"
expect 'Waiting for machine'
kill "$server"
wait "$server" 2>/dev/null || true
unset FM_RESOURCE_CONFIG
unset LAB_BUDGET
export LAB_LINE='state: working · source: pane · busy' LAB_AGENT=alive LAB_UNSUPPORTED=1
before=$(wc -l < "$LAB_LOG")
bash "$script" sample --refresh
[ "$(wc -l < "$LAB_LOG")" -eq "$before" ] || fail 'unsupported CLI received metadata'
export LAB_UNSUPPORTED=0
printf 'presentation=closed\n' >> "$FM_HOME/state/sample.meta"
bash "$script" sample --refresh
[ "$(wc -l < "$LAB_LOG")" -eq "$before" ] || fail 'closed presentation received metadata'
pass 'unsupported and closed presentation quietly omit metadata'
write_meta
export LAB_SHARED=1
before=$(wc -l < "$LAB_LOG")
bash "$script" sample --refresh
python3 - "$LAB_LOG" "$before" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1]).readlines()[int(sys.argv[2]):]]
workspace = next(c for c in calls if c[:2] == ['workspace', 'report-metadata'])
pane = next(c for c in calls if c[:2] == ['pane', 'report-metadata'])
assert 'fm_status=Needs me' in workspace and 'fm_status_detail=other pane detail' in workspace, calls
assert 'fm_status=Working' in pane, calls
PY
export LAB_OTHER_WORD=Checking LAB_LINE='state: blocked · source: status-log · urgent current pane'
bash "$script" sample --refresh
python3 - "$LAB_LOG" <<'PY'
import json, sys
call = json.loads(open(sys.argv[1]).readlines()[-2])
assert call[:2] == ['workspace', 'report-metadata'] and 'fm_status=Needs me' in call, call
PY
unset LAB_SHARED
unset LAB_OTHER_WORD
pass 'shared workspace reports the most urgent pane in both directions'
for ((i=0;i<20;i++)); do touch "$FM_HOME/state/extra$i.meta"; done
bash "$script" sample --refresh
python3 - "$LAB_LOG" <<'PY'
import json, sys
call = json.loads(open(sys.argv[1]).readlines()[-1])
assert int(call[call.index('--ttl-ms') + 1]) > 21 * 135 * 1000, call
PY
rm "$FM_HOME/state/extra"*.meta
pass 'metadata lifetime exceeds the fleet refresh bound'
fm_sidebar_classify 'state: working · source: run-step · ci' dead ship no no '' '' stalled yes
[ "$FM_SIDEBAR_WORD" = Stuck ] || fail 'Stuck must beat Checking'
fm_sidebar_classify 'state: parked · source: run-step · gate' dead ship no no '' '' stalled
[ "$FM_SIDEBAR_WORD" = 'Needs me' ] || fail 'a current unanswered gate must remain eligible for recovery'
fm_sidebar_classify 'state: parked · source: run-step · gate' dead ship yes no '' '' stalled yes
[ "$FM_SIDEBAR_WORD" = 'Needs you' ] || fail 'captain ownership must beat recovery'
[ "$(fm_sidebar_wake_owner dead '')" = watcher ] || fail 'exited recovery ownership duplicated'
[ "$(fm_sidebar_wake_owner alive stalled)" = watcher ] || fail 'wedge recovery ownership duplicated'
pass 'shared precedence and recovery ownership'
herdr workspace list --session lab > "$TMP_ROOT/after.json"
python3 - "$TMP_ROOT/before.json" "$TMP_ROOT/after.json" "$LAB_LOG" <<'PY'
import json, sys
for label, path in zip(('before', 'after'), sys.argv[1:3]):
    entries = json.load(open(path))['result']['workspaces']
    missing = sum(not e['tokens'].get('fm_status') for e in entries)
    print(f'{label}: {missing}/{len(entries)} entries without an explicit status')
labels = {arg.split('=', 1)[1] for line in open(sys.argv[3]) for arg in json.loads(line)
          if arg.startswith('fm_status=')}
assert len(labels) == 9, labels
print('distinct labels:', len(labels))
PY
# A bounded sweep advances its cursor before a read, so an unreadable task does
# not starve the next one. These records remain local to the stub session.
write_meta
cp "$FM_HOME/state/sample.meta" "$FM_HOME/state/next.meta"
sed 's/endpoint_task_id=sample/endpoint_task_id=next/' "$FM_HOME/state/next.meta" > "$TMP_ROOT/next.meta"
mv "$TMP_ROOT/next.meta" "$FM_HOME/state/next.meta"
bash "$script" --sweep
first=$(cat "$FM_HOME/state/.sidebar-cursor")
bash "$script" --sweep
second=$(cat "$FM_HOME/state/.sidebar-cursor")
[ "$first" != "$second" ] || fail 'sweep did not rotate'
pass 'bounded sweep rotates through home-owned tasks'
if [ -n "${FM_SIDEBAR_PROOF_DIR:-}" ]; then
  mkdir -p "$FM_SIDEBAR_PROOF_DIR"
  cp "$LAB_LOG" "$FM_SIDEBAR_PROOF_DIR/metadata.jsonl"
  cp "$LAB_CALLS" "$FM_SIDEBAR_PROOF_DIR/relaunch.txt"
  cp "$TMP_ROOT/before.json" "$TMP_ROOT/after.json" "$FM_SIDEBAR_PROOF_DIR/"
fi
