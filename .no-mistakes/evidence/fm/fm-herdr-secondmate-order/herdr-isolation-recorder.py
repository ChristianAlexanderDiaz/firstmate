#!/usr/bin/env python3
import os,sys,subprocess,json,time
ROOT='/Users/christianalexanderdiaz/.no-mistakes/worktrees/8ef411716190/01M46QDNV1250V3J2NJPF2GK3V'
REAL=os.environ.get('FM_LAB_REAL_HERDR',ROOT+'/.test-lab/pinned/herdr')
EVIDENCE='/Users/christianalexanderdiaz/.no-mistakes/evidence/01M46QDNV1250V3J2NJPF2GK3V'
os.chdir(ROOT)
os.environ['XDG_CONFIG_HOME']='.test-lab/config'
args=sys.argv[1:]
if args and args[0] in ('workspace','tab','pane','status','session','terminal'):
    if args[:2]==['session','delete'] and os.environ.get('FOCUS_AUDIT_LOG'):
        import shutil
        audit=os.environ['FOCUS_AUDIT_LOG']
        if os.path.isfile(audit): shutil.copyfile(audit,EVIDENCE+'/focus-audit-'+args[2]+'.tsv')
    r=subprocess.run([REAL,*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if args[:2] == ['session','list'] and r.returncode == 0:
        data=json.loads(r.stdout)
        for session in data.get('sessions',[]):
            for key in ('socket_path','session_dir'):
                if key in session: session[key]=os.path.abspath(session[key])
        r.stdout=json.dumps(data).encode()+b'\n'
    if args[0] != 'pane' or args[1:2] != ['process-info']:
        with open(EVIDENCE+'/herdr-live-api.jsonl','a') as f:
            f.write(json.dumps({'time':time.time(),'argv':args,'code':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace')})+'\n')
    if args[:2]==['workspace','list'] and os.path.exists(ROOT+'/.test-lab/capture-arm'):
        data=json.loads(r.stdout)
        labels=[w['label'] for w in data.get('result',{}).get('workspaces',[])]
        names=[x[2:].split(' · ')[0] if x.startswith('└ ') else x for x in labels]
        if names==['firstmate','2ndmate-alpha','a1','2ndmate-bravo','pb','b2','po','life','dotfiles']:
            os.unlink(ROOT+'/.test-lab/capture-arm')
            session=args[args.index('--session')+1]
            subprocess.run([ROOT+'/bin/fm-herdr-lab.sh','viewer','start',session],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            time.sleep(1)
            subprocess.run([ROOT+'/bin/fm-herdr-lab.sh','viewer','stop',session],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr);sys.exit(r.returncode)
if len(args)==2 and args[0]=='--session':
    import fcntl,termios,struct,signal,errno
    master,slave=os.openpty()
    fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
    child=os.fork()
    if child==0:
        os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0)
        for fd in (0,1,2): os.dup2(slave,fd)
        os.close(master)
        if slave>2: os.close(slave)
        os.execv(REAL,[REAL,*args])
    os.close(slave)
    def stop(sig,frame):
        try: os.kill(child,signal.SIGKILL)
        except ProcessLookupError: pass
    for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP): signal.signal(sig,stop)
    with open(EVIDENCE+'/sidebar-live.ansi','wb') as log:
        while True:
            try: data=os.read(master,65536)
            except OSError: break
            if not data: break
            log.write(data);log.flush();os.write(1,data)
    os.waitpid(child,0);sys.exit(0)
os.execv(REAL,[REAL,*args])
