import os, pathlib, subprocess, time, json, hashlib, shlex, sys, shutil
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/christianalexanderdiaz/.no-mistakes/evidence/01M46R3WV9B8XCFN123QXNTAJS')
log=open(ev/'live-relaunch.log','w', buffering=1)
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
        action(); results.append(dict(name=name,result='pass',live=True,evidence='live-relaunch.log',reason=''))
        print('PASS '+name,flush=True)
    except Exception as e:
        results.append(dict(name=name,result='fail',live=True,evidence='live-relaunch.log',reason=str(e)))
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
    # A forwarding launcher only supplies per-process trust for this disposable repository.
    # Every prompt, model request, process, and lifecycle command still reaches the installed real CLI.
    launcher=lab/'bin'; launcher.mkdir()
    table='projects={'+json.dumps(str(project))+'={trust_level="trusted"},'+json.dumps(str(wt))+'={trust_level="trusted"}}'
    flags=['--no-daemon','-c',table]
    (launcher/'codex').write_text('#!/bin/sh\nexec '+shlex.join([real_codex,*flags])+' "$@"\n')
    (launcher/'codex').chmod(0o700)
    base['PATH']=str(launcher)+':'+base['PATH']
    (wt/'unfinished.txt').write_text('Preserve unfinished investigation notes.\n')
    task='lab-relaunch-'+str(os.getpid()); target='primary:fm-'+task
    (lab/'data'/task).mkdir()
    brief=lab/'data'/task/'brief.md'
    brief.write_text('# Task\n## Captain\'s intent\nReply REPLACEMENT_READY and wait.\n\n## Firstmate spec\nThis is an isolated runtime check. Do not modify any file, run any fleet lifecycle command, create any report, or continue investigating. Reply exactly REPLACEMENT_READY, then wait for another instruction.\n')
    backlog=lab/'data/backlog.md'; backlog.write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    run(['tasks-axi','add',task,'Disposable investigation','--kind','scout','--file',backlog]); run(['tasks-axi','start',task,'--file',backlog])
    meta=lab/'state'/f'{task}.meta'
    meta.write_text(f'window={target}\nendpoint_task_id={task}\nworktree={wt}\nproject={project}\nharness=codex\nkind=scout\nmode=local-only\nyolo=off\nmodel=default\neffort=low\nbackend=tmux\n')
    tm('new-window','-d','-t','primary:','-n','fm-'+task,'-c',str(wt),'-e','PATH='+base['PATH'],'bash --noprofile --norc')
    tm('set-window-option','-t',target,'automatic-rename','off')
    time.sleep(1)
    tm('send-keys','-t',target,'-l','codex --dangerously-bypass-approvals-and-sandbox --disable hooks -c model_reasoning_effort=low "Reply exactly LAB_READY. Do not use any tools. Then wait."')
    time.sleep(0.2)
    tm('send-keys','-t',target,'Enter')
    wait_text(target,'LAB_READY')
    original_work=(wt/'unfinished.txt').read_bytes()
    def relaunch(actor='main'):
        before=pidset(); assert before, 'old actual Codex process absent'
        before_backlog=backlog.read_bytes()
        before_view=state('before relaunch')
        ctl=base.copy(); ctl['FM_SUPERVISION_ACTOR']=actor
        p=run(['bin/fm-control.sh',task,'relaunch','--model','gpt-6.1-sol','--effort','low','--note','Keep the pending hold and unfinished notes. Reply REPLACEMENT_READY and wait.'],env=ctl,timeout=150)
        assert 'relaunched '+task in p.stdout
        wait_text(target,'REPLACEMENT_READY')
        after=pidset(); assert after and not set(before)&set(after), 'worker was not replaced'
        assert backlog.read_bytes()==before_backlog, 'in-flight backlog changed'
        assert (wt/'unfinished.txt').read_bytes()==original_work, 'unfinished work changed'
        values=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
        assert values['window']==target and values['worktree']==str(wt), 'task identity changed'
        assert values['model']=='gpt-6.1-sol' and values['effort']=='low'
        state('after relaunch')
    run(['tasks-axi','hold',task,'--reason','four pending choices','--kind','captain','--file',backlog])
    test('A held investigation replaces its worker, retains its hold, identity, and unfinished notes',lambda:relaunch())
    blocker='dependency-'+str(os.getpid()); run(['tasks-axi','add',blocker,'Unfinished dependency','--kind','ship','--file',backlog])
    run(['tasks-axi','block',task,'--by',blocker,'--file',backlog])
    test('A held and dependency-blocked investigation replaces its worker without clearing either restriction',lambda:relaunch())
    run(['bin/fm-afk-contract.sh','enter','--spend','1','--words','Keep existing work running; leave pending choices for return.'],env=base)
    run(['bin/fm-afk-contract.sh','validate'],env=base)
    test('Away supervision replaces a held blocked worker even at the fresh-dispatch spend cap',lambda:relaunch('branch'))
    def refuse(label):
        before=pidset(); assert before
        bm=meta.read_bytes(); bb=backlog.read_bytes(); bf=brief.read_bytes()
        p=run(['bin/fm-control.sh',task,'relaunch','--model','gpt-6.1-sol','--effort','low','--note','Must refuse before stopping.'],env=base,check=False)
        assert p.returncode==1, p.stdout
        assert pidset()==before, 'refusal stopped existing worker'
        assert meta.read_bytes()==bm and backlog.read_bytes()==bb and brief.read_bytes()==bf, 'refusal changed durable state'
        capture(target); state(label)
    run(['tasks-axi','done',task,'--file',backlog])
    run(['tasks-axi','reopen',task,'--file',backlog])
    test('A held queued replacement refuses while the original worker and records remain intact',lambda:refuse('queued held refusal'))
    run(['tasks-axi','unhold',task,'--file',backlog]); run(['tasks-axi','unblock',task,'--by',blocker,'--file',backlog])
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
    (ev/'live-scenarios.json').write_text(json.dumps(results,indent=2))
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
