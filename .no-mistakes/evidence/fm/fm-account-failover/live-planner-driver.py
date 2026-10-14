import json, pathlib, subprocess
root=pathlib.Path.cwd(); scratch=root/'.test-account-live'; cfg=scratch/'config'; cfg.mkdir(exist_ok=True)
cfg.joinpath('claude-failover').write_text('account near ordinary\naccount far ordinary\n'); cfg.joinpath('claude-account').write_text('paced\n')
evidence=pathlib.Path('/Users/christianalexanderdiaz/.no-mistakes/evidence/01M4XV5N71PBXBHYYR54NGJWRK')
def row(name,pct,reset,reserve):
 return {'provider':'claude','account':name,'state':{'status':'fresh','stale':False},'windows':[{'id':'five_hour','kind':'session','percentRemaining':90,'resetsAt':'2026-10-15T00:00:00Z'},{'id':'seven_day','kind':'weekly','percentRemaining':pct,'resetsAt':reset,'pace':{'status':'behind' if reserve>=0 else 'ahead','reservePercentPoints':reserve}}], 'quotaSemantics':{'status':'known','effectiveAvailability':[{'scope':'all_models','status':'known','effectivePercentRemaining':pct,'boundedBy':['five_hour','seven_day'],'limitingWindowIds':['seven_day'],'runway':{'status':'through_reset','limitingWindowId':'seven_day'},'selection':{'status':'known','spendPriority':.4}}]}}
def snapshot(): return {'schemaVersion':7,'providers':[row('near',60,'2026-10-17T20:00:00Z',12),row('far',90,'2026-10-20T23:00:00Z',20)]}
def drive(label,snap,want,expectedrc=0,reason=None):
 p=scratch/'snapshot.json';p.write_text(json.dumps(snap))
 proc=subprocess.run(['bash','-c','. bin/fm-worker-account-lib.sh; fm_worker_account_pace "$1" claude sonnet "$(cat "$2")"','_',str(cfg),str(p)],capture_output=True,text=True)
 out=proc.stdout+proc.stderr
 log.write('\n'+label+'\n'+out+'exit='+str(proc.returncode)+'\n');log.flush()
 assert proc.returncode==expectedrc,(label,out)
 if want: assert out.startswith('pick\t'+want+'\t'),(label,out)
 if reason: assert reason in out,(label,out)
with evidence.joinpath('live-account-planner.log').open('w') as log:
 log.write('Real Firstmate account planner with disposable quota data; Claude auth checks use the normal signed-in login.\nnear and far are synthetic labels both mapped to ordinary for planner-only coverage; no second account or switch is claimed.\n')
 drive('Nearest weekly reset, on or behind pace',snapshot(),'near')
 s=snapshot();s['providers'][0]['windows'][1]['pace']={'status':'ahead','reservePercentPoints':-12};drive('Ahead-of-pace nearest account defers to overflow',s,'far')
 s=snapshot();s['providers'][0]['windows'][1]['pace']={'status':'unknown','reason':'expired_reset'};drive('Unknown pace keeps the nearest reset',s,'near',reason='pace unknown')
 s=snapshot();del s['providers'][0]['windows'][1]['pace'];drive('Absent pace keeps the nearest reset',s,'near',reason='pace unknown')
 s=snapshot();s['providers'][0]['quotaSemantics']['effectiveAvailability'].append({'scope':'model:opus','status':'known','effectivePercentRemaining':0,'runway':{'status':'exhausted_now'}});s['providers'][0]['windows'].append({'id':'seven_day_opus','kind':'model','percentRemaining':0});drive('Sonnet remains eligible despite unrelated Opus exhaustion',s,'near')
 for mode in ['margin','exhausted','paid','stale','reused','unknown']:
  s=snapshot();r=s['providers'][0]
  if mode=='margin':r['quotaSemantics']['effectiveAvailability'][0]['effectivePercentRemaining']=5
  if mode=='exhausted':r['quotaSemantics']['effectiveAvailability'][0]['runway']['status']='exhausted_now'
  if mode=='paid':r['windows'].append({'id':'extra_usage','kind':'credits','percentRemaining':100})
  if mode=='stale':r['state']={'status':'stale','stale':True}
  if mode=='reused':r['state']['reused']=True
  if mode=='unknown':r['quotaSemantics']['effectiveAvailability'][0]['status']='unknown'
  drive('Refuse '+mode+' nearest account and use safe overflow',s,'far')
 s=snapshot()
 for r in s['providers']:r['quotaSemantics']['effectiveAvailability'][0]['effectivePercentRemaining']=5
 drive('No eligible account refuses with each weekly reset',s,None,1,reason='no account is choosable')
 cfg.joinpath('claude-failover').write_text('account near ordinary\naccount far '+str(scratch/'user')+'\n')
 s=snapshot();s['providers'][0]['windows'][1]['pace']={'status':'ahead','reservePercentPoints':-12};drive('Signed-out overflow refuses and safe nearest account remains usable',s,'near',reason='not signed in')
 cfg.joinpath('claude-failover').write_text('account near ordinary\naccount far ordinary\n');cfg.joinpath('claude-account').unlink()
 p=scratch/'snapshot.json';p.write_text(json.dumps(snapshot()))
 proc=subprocess.run(['bin/fm-account-failover.sh','choose','--map',str(cfg/'claude-failover'),'--snapshot',str(p),'--current','near','--model','sonnet'],capture_output=True,text=True)
 log.write('\nFailover choice excludes exhausted current account\n'+proc.stdout+proc.stderr+'exit='+str(proc.returncode)+'\n');assert proc.returncode==0 and proc.stdout.startswith('pick\tfar\t')
print('Live planner scenarios passed; product output saved.')
