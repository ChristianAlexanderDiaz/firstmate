import os, pathlib, subprocess, time, re, json, shutil, traceback, sys
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/christianalexanderdiaz/.no-mistakes/evidence/01M46TBYYHZ4CMX5TQE795VRYJ')
lab = root / '.l'
socket = lab / 's'
state = lab / 'state'
resume = '--resume' in sys.argv
log = (evidence / 'live-ready-pr.log').open('a' if resume else 'w', buffering=1)
results = [r for r in json.loads((evidence/'live-ready-pr-results.json').read_text()) if r['result']=='pass'] if resume else []
active = None
out = None
base_env = os.environ.copy()
for key in list(base_env):
    if key.endswith('_OVERRIDE') and key.startswith('FM_') or key in ('FM_TEST_SEAM','FM_CREW_STATE_BIN','FM_PAUSE_RESURFACE_SECS'):
        base_env.pop(key, None)
env = dict(base_env, FM_HOME=str(lab), FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_SECONDMATE_LIVENESS_SECS='99999999', FM_WATCH_HANDLING_SUCCESSOR='1')

def note(s):
    print(s, flush=True); log.write(s+'\n')

def cmd(args, check=True, **kwargs):
    p = subprocess.run(args, cwd=root, env=env, text=True, capture_output=True, timeout=40, **kwargs)
    log.write('$ '+ ' '.join(map(str,args))+'\n'+p.stdout+p.stderr)
    if check and p.returncode:
        raise RuntimeError(f'{args[0]} exited {p.returncode}: {p.stdout}{p.stderr}')
    return p

def tmux(*args):
    return cmd(['tmux','-S',str(socket),*args])

def read(p):
    return p.read_text() if p.exists() else ''

def queue():
    return read(state/'.wake-queue')

def launch():
    global active,out
    out = (lab/'watch.out').open('w')
    active = subprocess.Popen([str(root/'bin/fm-watch.sh')], cwd=root, env=env, stdout=out, stderr=subprocess.STDOUT)
    return active

def stop():
    global active,out
    if active:
        if active.poll() is None: active.terminate()
        active.wait(timeout=15)
        out.close()
        log.write('WATCHER OUTPUT\n'+read(lab/'watch.out'))
        active=None

def tick(label):
    tmux('send-keys','-t','fm-lab-ready:fm-ready',f"printf 'idle display: {label}\\n'",'Enter')
    time.sleep(.2)
    log.write('REAL PANE\n'+tmux('capture-pane','-p','-t','fm-lab-ready:fm-ready','-S','-6').stdout)

def surface(kind='stale'):
    p=launch()
    try:
        p.wait(timeout=25)
    except subprocess.TimeoutExpired:
        raise AssertionError('Watcher failed to surface '+kind+'; '+read(state/'.watch-triage.log'))
    assert p.returncode==0, read(lab/'watch.out')
    q=queue()
    note('DELIVERED WAKE\n'+q)
    assert '\t'+kind+'\t' in q, f'Expected {kind}, got {q}'
    stop()

def ack():
    p=cmd([str(root/'bin/fm-wake-drain.sh')])
    match=re.search(r'WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',p.stderr)
    assert match, p.stdout+p.stderr
    cmd([str(root/'bin/fm-wake-drain.sh'),'--ack-through',match[1],'--recovery-generation',match[2]])
    assert queue()=='', queue()

def quiet(label):
    start=len(read(state/'.watch-triage.log'))
    tick(label)
    p=launch()
    deadline=time.monotonic()+25
    while time.monotonic()<deadline:
        assert p.poll() is None, 'Unexpected alarm: '+read(lab/'watch.out')+queue()
        delta=read(state/'.watch-triage.log')[start:]
        if 'absorbed stale' in delta:
            note('WATCHER TRIAGE\n'+delta)
            break
        time.sleep(.2)
    else: raise AssertionError('No positive absorption evidence')
    beat=(state/'.last-watcher-beat').stat().st_mtime_ns
    changes=0
    while changes<2 and time.monotonic()<deadline:
        assert p.poll() is None, 'Watcher exited during quiet verification'
        now=(state/'.last-watcher-beat').stat().st_mtime_ns
        if now!=beat: changes+=1; beat=now
        time.sleep(.2)
    assert changes==2, 'No completed poll evidence'
    assert queue()=='', queue()
    note('Watcher continued for two more polls; durable queue stayed empty.')
    stop()

def status(line):
    with (state/'ready.status').open('a') as f: f.write(line+'\n')
    surface('signal'); ack()

def arm():
    meta=state/'ready.meta'
    lines=[x for x in meta.read_text().splitlines() if not x.startswith('pr=')]
    meta.write_text('\n'.join(lines)+'\npr=https://github.com/fm-lab/ready/pull/1\n')
    meta.chmod(0o600)
    cmd(['bash','-c','. bin/fm-pr-lib.sh; fm_pr_poll_prepare "$FM_HOME/state" ready github https://github.com/fm-lab/ready/pull/1 github.com fm-lab/ready 1 "$PWD/bin/fm-pr-poll.sh" && fm_pr_poll_publish_prepared'])
    (state/'.last-check').touch()
    note('Armed a complete disposable monitor through production poll publication; forge network polling is outside this watcher-classification scenario.')

def run(name,fn):
    if any(r['name']==name and r['result']=='pass' for r in results): return
    note('\nSCENARIO: '+name)
    try:
        fn(); results.append(dict(name=name,result='pass',live=True)); note('PASS: '+name)
    except Exception as e:
        results.append(dict(name=name,result='fail',live=True,reason=str(e))); note('FAIL: '+str(e)); raise

def churn():
    status('done: PR https://github.com/fm-lab/ready/pull/1 checks green')
    tick('first ready observation'); surface(); ack()
    quiet('ready display tick 1'); quiet('ready display tick 2')

def cadence():
    throttle=state/'.paused-resurfaced-fm-lab-ready_fm-ready'
    assert throttle.exists(), list(state.iterdir())
    old=time.time()-14401
    os.utime(throttle,(old,old))
    note('Advanced only the disposable cadence marker beyond the unmodified four-hour default.')
    tick('after default recheck interval'); surface(); ack()
    quiet('after one recheck')

def direct():
    status('done: PR https://github.com/fm-lab/ready/pull/1')
    tick('direct PR first observation'); surface(); ack(); quiet('direct PR display tick')

def boundaries():
    for mode in ('missing executable','unregistered','retirement receipt'):
        arm()
        if mode=='missing executable': (state/'ready.check.sh').unlink()
        elif mode=='unregistered':
            for suffix in ('check.sh','pr-poll-registration','pr-poll'): (state/('ready.'+suffix)).unlink()
        else:
            cmd(['bash','-c','. bin/fm-pr-lib.sh; fm_pr_poll_snapshot_capture "$FM_HOME/state" ready "$PWD/bin/fm-pr-poll.sh" && fm_pr_poll_retirement_publish "$FM_HOME/state" ready "$PWD/bin/fm-pr-poll.sh" merged'])
            note('Published a valid retirement receipt through the product; startup will retire the monitor.')
        for i in range(2): tick(f'{mode} observation {i+1}'); surface(); ack()
        if mode=='retirement receipt':
            assert not (state/'ready.check.sh').exists() and not (state/'ready.pr-poll-retirement').exists(), 'Retirement failed to clear monitor artifacts'

def statuses():
    arm()
    for line in ('working: resumed branch work','done: ready in branch fm/lab','done: completed implementation summary'):
        status(line)
        for i in range(2): tick(f'non-ready status observation {i+1}'); surface(); ack()

def new_ready():
    status('done: PR https://github.com/fm-lab/ready/pull/1 checks green')
    tick('new ready declaration'); surface(); ack(); quiet('same ready declaration')
    status('done: PR https://github.com/fm-lab/ready/pull/1 checks green refreshed')
    tick('fresh ready append'); surface(); ack(); quiet('fresh declaration already delivered')

def away():
    cmd([str(root/'bin/fm-afk-contract.sh'),'enter','--words','Disposable away-record test'])
    quiet('ready PR under an away record')
    throttle=state/'.paused-resurfaced-fm-lab-ready_fm-ready'
    old=time.time()-14401; os.utime(throttle,(old,old))
    tick('ready PR away-record long recheck'); surface(); ack()
    cmd([str(root/'bin/fm-afk-contract.sh'),'archive'])

def hold():
    shutil.copyfile(root/'.tasks.toml',lab/'.tasks.toml')
    (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    p=subprocess.run(['tasks-axi','add','ready','disposable ready PR','--file','data/backlog.md'],cwd=lab,env=env,text=True,capture_output=True,timeout=30)
    log.write(p.stdout+p.stderr); assert p.returncode==0,p.stderr
    cmd([str(root/'bin/fm-captain-hold.sh'),'hold','ready','--reason','disposable merge decision'])
    tick('first captain call'); surface(); ack(); quiet('captain call already surfaced')
    original=(state/'ready.status').read_bytes()
    (lab/'decision.txt').write_text('fixture decision: proceed\n')
    cmd([str(root/'bin/fm-captain-hold.sh'),'answer','ready','--decision-file',str(lab/'decision.txt'),'--release'])
    cmd([str(root/'bin/fm-captain-hold.sh'),'hold','ready','--reason','second disposable merge decision'])
    assert original==(state/'ready.status').read_bytes(), 'Unexpected worker status append'
    tick('second captain call with unchanged status'); surface(); ack(); quiet('second captain call already surfaced')

try:
    assert not lab.exists(), 'Lab path already exists'
    cmd([str(root/'bin/fm-lab-home.sh'),'create',str(lab)])
    tmux('-f','/dev/null','new-session','-d','-s','fm-lab-ready','-n','fm-ready','-x','100','-y','30','-c',str(root),f'env HOME={lab} HISTFILE=/dev/null bash --noprofile --norc -i')
    tmux('set-window-option','-t','fm-lab-ready:fm-ready','automatic-rename','off')
    env['TMUX']=tmux('display-message','-p','-t','fm-lab-ready:fm-ready','#{socket_path},#{pid},0').stdout.strip()
    (state/'ready.meta').write_text('window=fm-lab-ready:fm-ready\nkind=ship\nharness=grok\nbackend=tmux\n')
    (state/'.last-check').touch()
    arm()
    if resume:
        note('RESUME: prior successful scenarios preserved; retirement setup corrected using the supported receipt publisher.')
        status('done: PR https://github.com/fm-lab/ready/pull/1')
        tick('fresh disposable home first observation'); surface(); ack()
    run('Green ready PR surfaces once and absorbs repeated real pane changes',churn)
    run('Ready PR resurfaces once after the existing four-hour recheck interval',cadence)
    run('Direct PR delivery receives the same bounded quiet period',direct)
    run('Missing, incomplete, and retiring merge monitors keep alarming',boundaries)
    run('Working, local-only, and pre-validation reports keep alarming',statuses)
    run('New status declarations start a fresh notification window',new_ready)
    run('Ready PR retains the finite recheck cadence under an away record',away)
    run('Reopened captain call alarms with unchanged status and armed monitor',hold)
except Exception:
    log.write(traceback.format_exc()); print(traceback.format_exc(),flush=True)
finally:
    stop()
    if socket.exists(): tmux('kill-server')
    if lab.exists(): shutil.rmtree(lab)
    note('CLEANUP: private tmux server stopped and disposable home removed.')
    (evidence/'live-ready-pr-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
if any(r['result']=='fail' for r in results) or len(results)!=8: raise SystemExit(1)
