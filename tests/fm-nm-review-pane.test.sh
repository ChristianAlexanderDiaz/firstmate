#!/usr/bin/env bash
# Hermetic executable-level pane lifecycle and crew-state integration tests.
# Stateful Herdr fake adapted from https://github.com/kunchenguid/firstmate/pull/3751; no live
# Herdr session is queried or changed. The fake rejects unscoped CLI calls.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-nm-review-pane)
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/fakebin"
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$ROOT"
export FM_FAKE_HERDR_STATE="$TMP_ROOT/herdr.json" FM_FAKE_HERDR_LOG="$TMP_ROOT/herdr.log"
export FM_FAKE_NM_STATUS="$TMP_ROOT/run.txt" FM_FAKE_NM_OVERVIEW="$TMP_ROOT/overview.txt"
export PATH="$TMP_ROOT/fakebin:$PATH"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
cat > "$TMP_ROOT/fakebin/herdr" <<'FAKE'
#!/usr/bin/env python3
import json,os,sys,shlex
from pathlib import Path
args=sys.argv[1:]
assert args[-2:]==['--session','lab'], 'every Herdr call must name the session'
args=args[:-2]
with open(os.environ['FM_FAKE_HERDR_LOG'],'a') as f: f.write(json.dumps(args)+'\n')
p=Path(os.environ['FM_FAKE_HERDR_STATE']); s=json.loads(p.read_text())
a=args[:2]; result={}
def error(code): print(json.dumps({'error':{'code':code}}),file=sys.stderr); sys.exit(1)
if a==['session','list']:
 print(json.dumps({'sessions':[{'name':'lab','running':True,'socket_path':str(p)+'.sock'}]})); sys.exit()
if a==['pane','get']:
 pane=s['panes'].get(args[2])
 if not pane: error('pane_not_found')
 if s.get('ambiguous'): print('unreadable'); sys.exit()
 result={'pane':{'pane_id':args[2],**pane}}
elif a==['pane','layout']:
 result={'layout':{'panes':[{'pane_id':args[3],'rect':{'width':s.get('width',120)}}]}}
elif a==['pane','split']:
 source=s['panes'][args[2]]
 n='w1:p'+str(s['next']); s['next']+=1
 s['panes'][n]={'workspace_id':source['workspace_id'],'tab_id':source['tab_id']}
 s['right']=n
 result={'pane':{'pane_id':n,**s['panes'][n]}}
elif a==['pane','list']:
 result={'panes':[{'pane_id':k,**v} for k,v in s['panes'].items()]}
elif a==['pane','neighbor']:
 result={'neighbor':{'pane_id':args[3],'neighbor_pane_id':s.get('right')}}
elif a==['pane','move']:
 assert args[args.index('--tab')+1]==s['panes'][args[2]]['tab_id'], 'move must bind the target tab'
 s['right']=args[2]
 result={'move_result':{'pane':{'pane_id':args[2]}}}
elif a==['pane','process-info']:
 pane=s['panes'].get(args[3],{})
 argv=shlex.split(pane.get('command','').split('&&')[-1])
 result={'process_info':{'pane_id':args[3],'shell_pid':100,'foreground_process_group_id':200 if pane.get('command') else 100,
  'foreground_processes':[{'argv':argv,'cwd':pane.get('cwd',os.environ['FM_FAKE_WT'])}] if argv else []}}
elif a==['pane','run']:
 if s.get('fail_run'): error('failed')
 s['panes'][args[2]]['command']=args[3]
elif a==['pane','close']:
 assert args[2] not in ('w1:p2','w1:p9'), 'viewer lifecycle must never close chat'
 if s.get('refuse_close'): error('busy')
 s['panes'].pop(args[2],None)
elif a==['workspace','list']:
 result={'workspaces':[{'workspace_id':'w1','label':s.get('label','firstmate'),'focused':True,'active_tab_id':'w1:t2'}]}
elif a==['workspace','rename']:
 assert args[2]=='w1'
 s['label']=args[3]
elif a==['tab','list']:
 result={'tabs':[{'tab_id':'w1:t2','workspace_id':'w1','focused':True}]}
elif a==['pane','rename']: pass
else: error('unsupported')
p.write_text(json.dumps(s)); print(json.dumps({'result':result}))
FAKE
cat > "$TMP_ROOT/fakebin/no-mistakes" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  axi) cat "$FM_FAKE_NM_OVERVIEW" ;;
  'axi status'|'axi status --run '*) cat "$FM_FAKE_NM_STATUS" ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$TMP_ROOT/fakebin/"*
git init -q -b main "$TMP_ROOT/wt"
git -C "$TMP_ROOT/wt" commit -q --allow-empty -m init
git -C "$TMP_ROOT/wt" checkout -q -b fm/panes
export FM_FAKE_WT="$TMP_ROOT/wt"
HEAD_SHA=$(git -C "$TMP_ROOT/wt" rev-parse HEAD)
META="$FM_HOME/state/panes.meta"
RECORD="$FM_HOME/state/panes.nm-review-pane"
fm_write_meta "$META" "window=lab:w1:p2" 'endpoint_task_id=panes' "worktree=$TMP_ROOT/wt" \
  "project=$TMP_ROOT/wt" 'kind=ship' 'mode=no-mistakes' 'backend=herdr' \
  'herdr_session=lab' 'herdr_workspace_id=w1' 'herdr_tab_id=w1:t2' 'herdr_pane_id=w1:p2'
cp "$META" "$TMP_ROOT/original.meta"
reset_panes() {
  printf '%s\n' '{"panes":{"w1:p2":{"workspace_id":"w1","tab_id":"w1:t2"}},"next":3}' > "$FM_FAKE_HERDR_STATE"
  : > "$FM_FAKE_HERDR_LOG"
  rm -f "$RECORD"
  rm -f "$FM_HOME/state/panes.nm-review-miss" "$FM_HOME/state/.wake-queue"
}
run_status() {  # <run> <status> [branch] [head]
  cat > "$FM_FAKE_NM_STATUS" <<EOF
run:
  id: $1
  branch: ${3:-fm/panes}
  status: $2
  head: ${4:-$HEAD_SHA}
EOF
  cp "$FM_FAKE_NM_STATUS" "$FM_FAKE_NM_OVERVIEW"
}
call() { "$ROOT/bin/fm-nm-review-pane.sh" panes; }
record_pane() { sed -n 's/^pane=//p' "$RECORD"; }
count() { python3 - "$FM_FAKE_HERDR_LOG" "$1" <<'PY'
import json,sys
print(sum(json.loads(l)[:2]==['pane',sys.argv[2]] for l in open(sys.argv[1])))
PY
}
change() { python3 - "$FM_FAKE_HERDR_STATE" "$1" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); s=json.loads(p.read_text()); s.update(json.loads(sys.argv[2])); p.write_text(json.dumps(s))
PY
}
reset_panes
run_status run-one running
"$ROOT/bin/fm-crew-state.sh" panes >/dev/null
[ "$(count split)" = 0 ] || fail 'ordinary current-state reads must remain passive'
call
call
[ "$(count split)" = 1 ] && [ "$(count run)" = 1 ] || fail 'one split and attach per run'
cmp "$META" "$TMP_ROOT/original.meta" || fail 'chat metadata changed'
python3 - "$FM_FAKE_HERDR_LOG" "$FM_FAKE_HERDR_STATE" "$TMP_ROOT/wt" <<'PY'
import json,sys
calls=[json.loads(l) for l in open(sys.argv[1])]; split=next(c for c in calls if c[:2]==['pane','split'])
assert split[split.index('--direction')+1]=='right'
assert split[split.index('--cwd')+1]==sys.argv[3]
assert '--no-focus' in split and split[split.index('--ratio')+1]=='0.55'
assert ['pane','rename','w1:p3','no-mistakes'] in calls
assert json.load(open(sys.argv[2]))['panes']['w1:p3']['command'].endswith('no-mistakes attach --run run-one')
PY
pass 'branch-scoped run opens one right-hand viewer, preserving chat and focus'
run_status run-one completed fm/panes deadbeef
call
call
[ "$(count close)" = 1 ] && [ "$(count split)" = 1 ] || fail 'terminal run closes once and stays closed'
run_status run-two running
call
[ "$(count split)" = 2 ] || fail 'new run must open a fresh viewer'
run_status run-two completed
call
call
[ "$(count close)" = 2 ] && [ -f "$RECORD" ] && [ -z "$(record_pane)" ] \
  || fail 'terminal replacement run must close its viewer and keep a tombstone'
pass 'terminal run with a pipeline-advanced head closes; replacement converges'
reset_panes
change '{"width":300}'
run_status wide running
call
python3 - "$FM_FAKE_HERDR_LOG" <<'PY'
import json,sys
split=next(c for c in map(json.loads,open(sys.argv[1])) if c[:2]==['pane','split'])
assert split[split.index('--direction')+1]=='right'
PY
pass 'width does not change right-hand placement'
# Run replacement must close the old viewer before opening another.
run_status replacement running
call
[ "$(count split)" = 2 ] && [ "$(count close)" = 1 ] || fail 'replacement must close old viewer'
change '{"refuse_close":true}'
run_status replacement completed
call
[ "$(record_pane)" = w1:p4 ] || fail 'unconfirmed close must retain the viewer record'
change '{"refuse_close":false}'
call
[ -z "$(record_pane)" ] || fail 'confirmed close must retire the viewer'
pass 'replacement and close refusal preserve exact viewer identity'
reset_panes
run_status foreign running fm/other
call
[ "$(count split)" = 0 ] || fail 'foreign branch must not open viewer'
run_status historical completed fm/panes deadbeef
call
[ "$(count split)" = 0 ] || fail 'historical head must not open viewer'
for backend in tmux zellij orca cmux paseo; do
  sed "s/^backend=herdr$/backend=$backend/" "$TMP_ROOT/original.meta" > "$META"
  call
  [ "$(count split)" = 0 ] || fail "$backend must be a no-op"
done
cp "$TMP_ROOT/original.meta" "$META"
pass 'foreign, historical and non-Herdr evidence cannot open a viewer'
reset_panes
run_status retry running
change '{"fail_run":true}'
call
[ "$(count split)" = 1 ] && [ -f "$RECORD" ] || fail 'failed attach must retain split record'
change '{"fail_run":false}'
call
[ "$(count split)" = 1 ] && [ "$(count run)" = 2 ] || fail 'attach failure must retry in same pane'
sed 's/^started=1$/started=0/' "$RECORD" > "$TMP_ROOT/record.tmp"
mv "$TMP_ROOT/record.tmp" "$RECORD"
call
[ "$(count run)" = 2 ] || fail 'an already running viewer must never receive a retried shell command'
change '{"ambiguous":true}'
call
[ "$(count split)" = 1 ] || fail 'ambiguous presence must never duplicate viewer'
change '{"ambiguous":false}'
pass 'attach retries reuse the recorded pane; ambiguous reads preserve it'
reset_panes
run_status gone running
call
change '{"panes":{"w1:p2":{"workspace_id":"w1","tab_id":"w1:t2"}}}'
call
[ -f "$RECORD" ] && [ -z "$(record_pane)" ] && [ "$(count split)" = 1 ] \
  || fail 'a viewer closed during its run must leave a tombstone without reopening'
run_status gone2 running
call
change '{"panes":{"w1:p2":{"workspace_id":"w1","tab_id":"w1:t2"}}}'
run_status gone2 completed
call
[ -f "$RECORD" ] && [ -z "$(record_pane)" ] && [ "$(count close)" = 0 ] \
  || fail 'already absent viewer must be accepted when its run ends'
pass 'already absent viewer closes without touching chat'
reset_panes
run_status rebind running
call
change '{"panes":{"w1:p3":{"workspace_id":"w1","tab_id":"w1:t2"},"w1:p9":{"workspace_id":"w1","tab_id":"w1:t5"}}}'
sed -e 's/^window=.*/window=lab:w1:p9/' -e 's/^herdr_tab_id=.*/herdr_tab_id=w1:t5/' \
  -e 's/^herdr_pane_id=.*/herdr_pane_id=w1:p9/' "$TMP_ROOT/original.meta" > "$META"
call
python3 - "$FM_FAKE_HERDR_LOG" "$FM_FAKE_HERDR_STATE" "$RECORD" <<'PY'
import json,sys
calls=[json.loads(l) for l in open(sys.argv[1])]
assert ['pane','close','w1:p3'] in calls
assert [c[2] for c in calls if c[:2]==['pane','split']]==['w1:p2','w1:p9']
panes=json.load(open(sys.argv[2]))['panes']
assert 'w1:p3' not in panes and panes['w1:p4']['tab_id']=='w1:t5'
record=dict(l.rstrip('\n').split('=',1) for l in open(sys.argv[3]))
assert (record['worker'],record['tab'],record['pane'])==('w1:p9','w1:t5','w1:p4')
PY
cp "$TMP_ROOT/original.meta" "$META"
pass 'relaunched chat closes the earlier viewer and opens one beside the new pane'
reset_panes
run_status bound running
call
sed 's/^pane=.*/pane=w1:p2/' "$RECORD" > "$TMP_ROOT/record.tmp"
mv "$TMP_ROOT/record.tmp" "$RECORD"
run_status bound completed
call
[ "$(count close)" = 0 ] || fail 'worker close was attempted'
[ "$(record_pane)" = w1:p2 ] || fail 'a corrupt record must be retained'
pass 'record corruption cannot redirect viewer cleanup onto chat'
reset_panes
run_status contended running
lock=$(bash -c '. "$1/bin/fm-nm-review-pane.sh"; fm_backend_source herdr; fm_backend_herdr_presentation_session_lock_path lab' bash "$ROOT")
ROOT="$ROOT" LOCK="$lock" READY="$TMP_ROOT/ready" RELEASE="$TMP_ROOT/release" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  touch "$READY"
  while [ ! -e "$RELEASE" ]; do sleep 0.1; done
  fm_lock_release "$LOCK"
' &
holder=$!
for ((i=0;i<100;i++)); do [ ! -e "$TMP_ROOT/ready" ] || break; sleep 0.1; done
if [ ! -e "$TMP_ROOT/ready" ]; then
  touch "$TMP_ROOT/release"; wait "$holder" || true
  fail 'session-lock holder never became ready'
fi
call
if [ "$(count split)" != 0 ]; then
  touch "$TMP_ROOT/release"; wait "$holder" || true
  fail 'contended session lock must yield without splitting'
fi
touch "$TMP_ROOT/release"
wait "$holder"
call
[ "$(count split)" = 1 ] || fail 'released session lock must allow next sweep'
pass 'session lock serializes pane creation with teardown and concurrent sweeps'

reset_panes
change '{"label":"fm-panes"}'
run_status presentation running
"$ROOT/bin/fm-crew-state.sh" panes --sync-presentation >/dev/null
"$ROOT/bin/fm-crew-state.sh" panes --sync-presentation >/dev/null
python3 - "$FM_FAKE_HERDR_LOG" "$FM_FAKE_HERDR_STATE" <<'PY'
import json,sys
calls=[json.loads(l) for l in open(sys.argv[1])]
assert [c for c in calls if c[:2]==['workspace','rename']]==[['workspace','rename','w1','🔍 fm-panes']]
assert json.load(open(sys.argv[2]))['label']=='🔍 fm-panes'
assert sum(c[:2]==['pane','split'] for c in calls)==1
PY
pass 'presentation reconciles both the workspace emoji and review viewer without repeated renames'

# The sweep on a home whose no-mistakes release appends a column to its runs
# table: the worker keeps a readable state, so the sweep applies its emoji and
# follows the next state change instead of stripping the label to no emoji.
reset_panes
change '{"label":"fm-panes"}'
runs_table() {  # <run>
  cat > "$FM_FAKE_NM_OVERVIEW" <<TABLE
count: 1 of 1 total
runs[1]{id,branch,status,head,pr,run_counter}:
  "$1",fm/panes,running,${HEAD_SHA:0:8},"","run 1 of 1, 0 fix rounds"
TABLE
}
run_status appended running
runs_table appended
"$ROOT/bin/fm-crew-state.sh" panes --sync-presentation >/dev/null
cat >> "$FM_FAKE_NM_STATUS" <<'STEPS'
  pr: "https://github.com/o/r/pull/2"
  steps[2]{step,status,findings,duration_ms}:
    review,completed,0,0
    ci,running,0,0
STEPS
"$ROOT/bin/fm-crew-state.sh" panes --sync-presentation >/dev/null
"$ROOT/bin/fm-crew-state.sh" panes --sync-presentation >/dev/null
python3 - "$FM_FAKE_HERDR_LOG" "$FM_FAKE_HERDR_STATE" <<'PY'
import json,sys
calls=[json.loads(l) for l in open(sys.argv[1])]
renames=[c[3] for c in calls if c[:2]==['workspace','rename']]
assert renames==['🔍 fm-panes','⏳ fm-panes'], renames
assert json.load(open(sys.argv[2]))['label']=='⏳ fm-panes'
PY
pass 'a runs table with an appended column keeps the swept emoji applied and current across a state change'

reset_panes
run_status moved running
call
change '{"right":null}'
call
call
[ "$(count split)" = 1 ] && [ "$(count move)" = 1 ] || fail 'existing stacked view must move right exactly once'
pass 'existing stacked view moves right without replacing attach'

reset_panes
run_status adopted running
change '{"next":4,"panes":{"w1:p2":{"workspace_id":"w1","tab_id":"w1:t2"},"w1:p3":{"workspace_id":"w1","tab_id":"w1:t2","command":"no-mistakes attach --run adopted"}}}'
call
[ "$(count split)" = 0 ] && [ "$(count run)" = 0 ] && [ "$(record_pane)" = w1:p3 ] \
  || fail 'proven hook view should be adopted, not duplicated or restarted'
run_status successor running
call
[ "$(count close)" = 1 ] && [ "$(count split)" = 1 ] || fail 'adopted older run must be replaced'
pass 'exact attach process is adopted and replaced on rerun without duplicates'

reset_panes
run_status occupied running
change '{"panes":{"w1:p2":{"workspace_id":"w1","tab_id":"w1:t2"},"w1:p3":{"workspace_id":"w1","tab_id":"w1:t2","command":"sleep 100"}}}'
call
[ "$(count split)" = 0 ] && [ "$(count close)" = 0 ] && [ ! -e "$RECORD" ] \
  || fail 'unknown sibling must prevent creating or closing a pane'
[ ! -s "$FM_HOME/state/.wake-queue" ] || fail 'miss must not alert before 30 seconds'
since=$(($(date +%s) - 31))
sed "s/^since=.*/since=$since/" "$FM_HOME/state/panes.nm-review-miss" > "$TMP_ROOT/miss.tmp"
mv "$TMP_ROOT/miss.tmp" "$FM_HOME/state/panes.nm-review-miss"
call
call
[ "$(wc -l < "$FM_HOME/state/.wake-queue" | tr -d ' ')" = 1 ] || fail '30-second miss must alert once per run'
assert_contains "$(cat "$FM_HOME/state/.wake-queue")" 'unknown pane' 'miss alert must name the failure'
change '{"panes":{"w1:p2":{"workspace_id":"w1","tab_id":"w1:t2"}}}'
call
[ -f "$RECORD" ] && [ ! -f "$FM_HOME/state/panes.nm-review-miss" ] || fail 'successful retry must clear miss'
pass 'unknown panes remain untouched; 30-second miss alerts once and recovery clears it'

reset_panes
run_status decoupled running fm/panes deadbeef
printf '%s\n' 'unreadable newer inventory' > "$FM_FAKE_NM_OVERVIEW"
"$ROOT/bin/fm-crew-state.sh" panes --sync-review-pane > "$TMP_ROOT/verdict"
assert_contains "$(cat "$TMP_ROOT/verdict")" 'state: unknown' 'strict ownership must remain unknown'
[ "$(count split)" = 1 ] || fail 'unknown supervision verdict must not suppress same-branch view'
pass 'view detection is independent of strict run inventory and head attribution'

reset_panes
run_status scoped running
sed 's/^run:$/other_branch_run:/' "$FM_FAKE_NM_STATUS" > "$TMP_ROOT/status.tmp"
mv "$TMP_ROOT/status.tmp" "$FM_FAKE_NM_STATUS"
call
[ "$(count split)" = 0 ] || fail 'other_branch_run block must not be interpreted as current run'
sed 's/^other_branch_run:$/active_run:/' "$FM_FAKE_NM_STATUS" > "$TMP_ROOT/status.tmp"
mv "$TMP_ROOT/status.tmp" "$FM_FAKE_NM_STATUS"
call
[ "$(count split)" = 1 ] || fail 'active_run block must be supported'
pass 'current run blocks are scoped and other-branch detail is ignored'

# The portable public attribution helper must accept both real overview schemas
# and ignore unfamiliar history without licensing an unfamiliar current status.
overview=$(cat <<'EOF'
count: 3 of 3 total
runs[3]{id,branch,status,head,pr,run_counter}:
  newest,fm/panes,running,12345678,"","run 3 of 3, 1 fix rounds"
  interrupted,fm/panes,ci_monitor_interrupted,12345678,"","run 2 of 3"
  older,fm/panes,future_status,12345678,"","run 1 of 3"
EOF
)
choice=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_select_run fm/panes "$2" "$3"' _ "$ROOT" "$overview" "$TMP_ROOT/wt")
assert_contains "$choice" 'selected|newest|running|' 'new output and unknown history must select current run'
unknown=$(printf '%s\n' "$overview" | sed 's/newest,fm\/panes,running/newest,fm\/panes,future_status/')
choice=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_select_run fm/panes "$2" "$3"' _ "$ROOT" "$unknown" "$TMP_ROOT/wt")
assert_contains "$choice" 'unknown|unrecognized run status' 'unknown current status must remain unknown'
pass 'six-column quoted run counters and interrupted history preserve newest-run selection'

reset_panes
run_status sweep running
printf 'earlier diagnostic\n' > "$FM_HOME/state/.nm-review-pane.log"
"$ROOT/bin/fm-nm-review-pane.sh" --sweep
"$ROOT/bin/fm-nm-review-pane.sh" --sweep
[ "$(count split)" = 1 ] || fail 'watcher sweep entry point must open only one view'
assert_contains "$(cat "$FM_HOME/state/.nm-review-pane.log")" 'earlier diagnostic' 'sweep must append diagnostics'
dd if=/dev/zero of="$FM_HOME/state/.nm-review-pane.log" bs=1048576 count=1 2>/dev/null
"$ROOT/bin/fm-nm-review-pane.sh" --sweep
[ "$(wc -c < "$FM_HOME/state/.nm-review-pane.log.1" | tr -d ' ')" = 1048576 ] || fail 'sweep must rotate a full log'
pass 'watcher sweep is idempotent and appends then rotates its bounded diagnostic log'

change '{"panes":{"w1:p2":{"workspace_id":"w1","tab_id":"w1:t2"},"w1:p3":{"workspace_id":"w1","tab_id":"w1:t2"}}}'
call
[ "$(count split)" = 1 ] && [ "$(count run)" = 2 ] || fail 'exited attach must restart only in its proven idle shell'
pass 'an exited attach retries in its recorded idle pane without a duplicate split'
