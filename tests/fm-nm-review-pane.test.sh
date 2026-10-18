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
import json,os,sys
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
 result={'pane':{'pane_id':n,**s['panes'][n]}}
elif a==['pane','process-info']:
 pane=s['panes'].get(args[3],{})
 result={'process_info':{'pane_id':args[3],'shell_pid':100,'foreground_process_group_id':200 if pane.get('command') else 100}}
elif a==['pane','run']:
 if s.get('fail_run'): error('failed')
 s['panes'][args[2]]['command']=args[3]
elif a==['pane','close']:
 assert args[2] not in ('w1:p2','w1:p9'), 'viewer lifecycle must never close chat'
 if s.get('refuse_close'): error('busy')
 s['panes'].pop(args[2],None)
elif a==['workspace','list']:
 result={'workspaces':[{'workspace_id':'w1','focused':True,'active_tab_id':'w1:t2'}]}
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
assert split[split.index('--direction')+1]=='down'
assert split[split.index('--cwd')+1]==sys.argv[3]
assert '--no-focus' in split and split[split.index('--ratio')+1]=='0.55'
assert ['pane','rename','w1:p3','no-mistakes'] in calls
assert json.load(open(sys.argv[2]))['panes']['w1:p3']['command'].endswith('no-mistakes attach --run run-one')
PY
pass 'attributed run opens one stacked viewer, preserving chat and focus'
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
pass 'wide pane chooses side by side'
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
for backend in tmux zellij orca cmux; do
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
