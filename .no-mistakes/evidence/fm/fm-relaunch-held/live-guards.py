import os, pathlib, subprocess, time, json, hashlib, shlex, sys, shutil
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/christianalexanderdiaz/.no-mistakes/evidence/01M46R3WV9B8XCFN123QXNTAJS')
log=open(ev/'live-guards.log','w', buffering=1)
base=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_ENV','HERDR_SESSION','HERDR_PANE_ID','HERDR_WORKSPACE_ID','HERDR_TAB_ID','HERDR_SOCKET_PATH','TMUX','TMUX_PANE','CLAUDE_CONFIG_DIR','TASKS_AXI_BACKEND','FM_SUPERVISION_ACTOR']:
    base.pop(k,None)
real_codex=shutil.which('codex')
base.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',DISABLE_AUTOUPDATER='1',TMPDIR=str(root/'.test-runtime'),TERM='xterm-256color')
lab=None; socket=None; results=[]
def run(args, env=None, check=True, timeout=90):
    args=[str(x) for x in args]
    log.write('$ '+shlex.join(args)+'\n')
    p=subprocess.run(args,cwd=root,env=env or base,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log.write(p.stdout+f'\n[exit {p.returncode}]\n')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p

def tm(*args,check=True): return run(['tmux','-L','fm-lab',*args],env=base,check=check)
def capture(name): return tm('capture-pane','-p','-t',name,'-S','-100').stdout

def wait_text(name,text,limit=90):
    end=time.monotonic()+limit
    while time.monotonic()<end:
        out=capture(name)
        # A model response must be in a rendered assistant row, not just the submitted prompt.
        if ('• '+text) in out or ('● '+text) in out: return out
        time.sleep(2)
    raise RuntimeError(f'{text} never appeared as an assistant response: '+out)

def state(label):
    log.write('\nSTATE '+label+'\n')
    return run(['tasks-axi','show',task,'--full','--file',backlog],env=base).stdout

def pidset():
    pane=int(tm('display-message','-p','-t',target,'#{pane_pid}').stdout.strip())
    selected={pane}; queue=[pane]
    while queue:
        parent=queue.pop()
        r=subprocess.run(['pgrep','-P',str(parent)],text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        for child in r.stdout.split():
            child=int(child)
            if child not in selected: selected.add(child); queue.append(child)
    names=subprocess.run(['ps','-p',','.join(map(str,selected)),'-o','pid=,comm='],text=True,stdout=subprocess.PIPE).stdout
    codex=[int(r.split(None,1)[0]) for r in names.splitlines() if pathlib.Path(r.split(None,1)[1]).name=='codex']
    log.write('WORKER_CODEX_PIDS '+json.dumps(codex)+'\n')
    return codex

def test(name,action):
    print('LIVE '+name,flush=True); log.write('\nSCENARIO '+name+'\n')
    try:
        action(); results.append(dict(name=name,result='pass',live=True,evidence='live-guards.log',reason=''))
        print('PASS '+name,flush=True)
    except Exception as e:
        results.append(dict(name=name,result='fail',live=True,evidence='live-guards.log',reason=str(e)))
        print('FAIL '+str(e),flush=True); raise

try:
    lab=pathlib.Path(run(['mktemp','-d',str(root/'.test-runtime/fm-lab.XXXXXX')]).stdout.strip())
    run(['bin/fm-lab-home.sh','create',lab]); (lab/'tmux').mkdir()
    socket=run(['bin/fm-lab-home.sh','tmux-dir',lab]).stdout.strip()
    base.update(FM_HOME=str(lab),TMUX_TMPDIR=socket,FM_CONTROL_EXIT_WAIT='30',FM_CONTROL_LAUNCH_WAIT='30')
    (lab/'config/supervision-host-off').touch()
    (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    # Private socket and an explicit non-zero terminal size before either CLI starts.
    tm('-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),'codex --no-daemon')
    time.sleep(3); capture('primary')
    base['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
    project=lab/'projects/probe'; project.mkdir()
    run(['git','init','-q',project]); (project/'README.md').write_text('Disposable relaunch probe.\n')
    run(['git','-C',project,'add','README.md'])
    run(['git','-C',project,'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','commit.gpgsign=false','commit','-qm','Initial fixture'])
    wt=lab/'probe-worktree'; run(['git','-C',project,'worktree','add','-qb','probe',wt])
    (wt/'unfinished.txt').write_text('Preserve unfinished investigation notes.\n')
    task='lab-relaunch-'+str(os.getpid()); target='primary:fm-'+task
    (lab/'data'/task).mkdir()
    brief=lab/'data'/task/'brief.md'
    brief.write_text('# Task\n## Captain\'s intent\nReply REPLACEMENT_READY and wait.\n\n## Firstmate spec\nThis is an isolated runtime check. Do not modify any file, run any fleet lifecycle command, create any report, or continue investigating. Reply exactly REPLACEMENT_READY, then wait for another instruction.\n')
    backlog=lab/'data/backlog.md'; backlog.write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    run(['tasks-axi','add',task,'Disposable investigation','--kind','scout','--file',backlog]); run(['tasks-axi','start',task,'--file',backlog])
    meta=lab/'state'/f'{task}.meta'
    meta.write_text(f'window={target}\nendpoint_task_id={task}\nworktree={root}\nproject={root}\nharness=codex\nkind=scout\nmode=local-only\nyolo=off\nmodel=default\neffort=low\nbackend=tmux\n')
    tm('new-window','-d','-t','primary:','-n','fm-'+task,'-c',str(root),'-e','PATH='+base['PATH'],'bash --noprofile --norc')
    tm('set-window-option','-t',target,'automatic-rename','off')
    time.sleep(1)
    tm('send-keys','-t',target,'-l','codex --no-daemon --dangerously-bypass-approvals-and-sandbox --disable hooks -c model_reasoning_effort=low "Reply exactly LAB_READY. Do not use any tools. Then wait."')
    time.sleep(0.2)
    tm('send-keys','-t',target,'Enter')
    wait_text(target,'LAB_READY')
    def fresh_guard(row,actor='main'):
        fresh='fresh-'+task
        fresh_brief=lab/'data'/fresh/'brief.md'
        fresh_brief.parent.mkdir(exist_ok=True)
        fresh_brief.write_text(brief.read_text())
        run(['tasks-axi','add',fresh,'Guarded new dispatch','--kind','scout','--file',backlog])
        if 'in_flight' in row: run(['tasks-axi','start',fresh,'--file',backlog])
        if 'held' in row: run(['tasks-axi','hold',fresh,'--reason','pending choice','--kind','captain','--file',backlog])
        if 'blocked' in row: run(['tasks-axi','block',fresh,'--by',blocker,'--file',backlog])
        before=backlog.read_bytes()
        ctl=base.copy(); ctl['FM_SUPERVISION_ACTOR']=actor
        out=run(['bin/fm-spawn.sh',fresh,project,'--scout','--harness','codex','--backend','tmux'],env=ctl,check=False)
        assert out.returncode==1 and ('not dispatchable' in out.stdout or 'only queued unblocked work' in out.stdout),out.stdout
        assert not (lab/'state'/f'{fresh}.meta').exists() and backlog.read_bytes()==before
        inventory=tm('list-windows','-t','primary','-F','#{window_name}').stdout
        assert 'fm-'+fresh not in inventory
        run(['tasks-axi','rm',fresh,'--file',backlog])
    blocker='dependency-'+str(os.getpid()); run(['tasks-axi','add',blocker,'Unfinished dependency','--kind','ship','--file',backlog])
    test('Fresh dispatch refuses held queued work before creating a worker',lambda:fresh_guard('queued held'))
    test('Fresh dispatch refuses dependency-blocked queued work before creating a worker',lambda:fresh_guard('queued blocked'))
    test('Fresh dispatch refuses held in-flight work before creating a worker',lambda:fresh_guard('in_flight held'))
    run(['bin/fm-afk-contract.sh','enter','--spend','10','--words','Keep existing work running; leave pending choices for return.'],env=base)
    run(['bin/fm-afk-contract.sh','validate'],env=base)
    test('Away supervision refuses new dispatch of an already in-flight item',lambda:fresh_guard('in_flight','branch'))
    def refuse(label):
        before=pidset(); assert before
        bm=meta.read_bytes(); bb=backlog.read_bytes(); bf=brief.read_bytes()
        p=run(['bin/fm-control.sh',task,'relaunch','--model','gpt-6.1-sol','--effort','low','--note','Must refuse before stopping.'],env=base,check=False)
        assert p.returncode==1, p.stdout
        assert pidset()==before, 'refusal stopped existing worker'
        assert meta.read_bytes()==bm and backlog.read_bytes()==bb and brief.read_bytes()==bf, 'refusal changed durable state'
        capture(target); state(label)
    run(['tasks-axi','hold',task,'--reason','four pending choices','--kind','captain','--file',backlog])
    run(['tasks-axi','reopen',task,'--file',backlog])
    test('A held queued replacement refuses while the original worker and records remain intact',lambda:refuse('queued held refusal'))
    run(['tasks-axi','unhold',task,'--file',backlog]); run(['tasks-axi','unblock',task,'--by',blocker,'--file',backlog],check=False)
    run(['tasks-axi','done',task,'--file',backlog])
    test('A completed replacement refuses while the original worker remains alive',lambda:refuse('completed refusal'))
    run(['tasks-axi','rm',task,'--file',backlog])
    def missing():
        before=pidset(); bm=meta.read_bytes(); bf=brief.read_bytes()
        p=run(['bin/fm-control.sh',task,'relaunch','--note','Must refuse before stopping.'],env=base,check=False)
        assert p.returncode==1 and 'no backlog item' in p.stdout
        assert pidset()==before and bm==meta.read_bytes() and bf==brief.read_bytes()
    test('A replacement with no owning backlog item refuses without stopping its worker',missing)
finally:
    (ev/'live-guard-scenarios.json').write_text(json.dumps(results,indent=2))
    if socket:
        tm('kill-server',check=False)
        run(['bin/fm-lab-home.sh','teardown',lab],check=False)
    if lab:
        # The product created these private ephemeral launch files; remove only our exact id and home hash.
        if 'task' in globals():
            run(['rm','-rf','/tmp/fm-'+task],check=False)
            token=hashlib.sha256(str(lab).encode()).hexdigest()
            run(['rm','-rf','/tmp/fm-'+task+'+'+token],check=False)
        run(['chmod','-R','u+w',lab],check=False)
        run(['rm','-rf',lab],check=False)
    log.close()
