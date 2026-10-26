#!/usr/bin/env python3
"""Local gate driver; producer source/commands are recorded beside this file."""
import datetime,json,os,pathlib,runpy,shutil,sys
root=pathlib.Path(__file__).resolve().parents[2]
out=root/'.zig-cache/sprint-4-evidence'/sys.argv[1]
out.mkdir(parents=True,exist_ok=False)
helper=runpy.run_path(str(root.parent/'quic-zig/tools/profile-composition.py'),run_name='process_helpers')
checker=runpy.run_path(str(root/'tools/check-composition.py'),run_name='source_helpers')
workspace=root/'.zig-cache/sprint-4-stack-dev/tests/composition'
zig=pathlib.Path(shutil.which('zig')).resolve()
paths={'qmesh':root,'qmsg':root.parent/'qmsg','quic':root.parent/'quic-zig'}
def capture():
 return {**{name:checker['source_identity'](path)for name,path in paths.items()},'workspace':helper['workspace_identity'](workspace),'compiler':helper['compiler_identity'](zig)}
before=capture()
report={'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sources_before':before,'builds':[],'runs':[],'execution_passed':False,'passed':False,'scope':'three logical seeds per mode on public IPv4 UDP; exact virtual replay is a separate gate','driver_sha256':helper['sha256'](pathlib.Path(__file__))}
def save():(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def checks(r,seed):
 return {'converged':r['converged'],'seed':r['seed']==seed,'actions':r['logical_actions_completed']==13,'replicas':all(n==r['authority_revision']for n in r['replica_revisions']),'terminal':r['snapshot_attempts']==r['snapshot_replies']+r['snapshot_timeouts']+r['request_peer_closures'],'snapshots':r['snapshot_replies']==r['snapshots_applied']+r['stale_snapshots_rejected'],'branches':all(r[n]>0 for n in ['application_restarts','endpoint_moves','suspect_preserved_routes','suspect_new_dials_paused','dead_route_removals','absent_route_removals','snapshot_timeouts','hints_evicted']),'endpoint_identity':r['stale_endpoint_rejected']and r['wrong_identity_rejected']and r['decoy_positive_control_ready'],'no_hints':r['hints_delivered_after_heal']==0,'bounds':r['peak_pending_requests_per_replica']<=1 and r['peak_pool_entries_per_replica']<=1 and r['peak_total_pool_entries']<=3 and r['peak_mesh_session_records']<=64 and r['peak_mesh_server_slots']<=32}
save()
env=os.environ.copy();env['ZIG_LOCAL_PKG_DIR']=str(root/'zig-pkg');env['COPYFILE_DISABLE']='1';env['PYTHONDONTWRITEBYTECODE']='1'
seeds=[0x514d45534804,0x719e0023,0xfedcba9876543210]
try:
 for mode in ('Debug','ReleaseSafe'):
  prefix=out/('install-'+mode)
  command=[str(zig),'build','install-chaos','-Doptimize='+mode,'-Dlocal-quic=true','-j2','--prefix',str(prefix),'--summary','all']
  row={'mode':mode,'command':command,'log':mode+'-build.log'};report['builds'].append(row);save()
  done=helper['run_child'](command,workspace,env,out/row['log'],900)
  row.update(returncode=done['returncode'],timed_out=done['timed_out'])
  if row['returncode']or row['timed_out']:raise RuntimeError(mode+' build failed')
  binary=prefix/'bin/qmesh-recovery-chaos';row['binary_sha256']=helper['sha256'](binary);row['binary']=str(binary);save()
  for seed in seeds:
   command=[str(binary),'--seed',str(seed)]
   run={'mode':mode,'seed':seed,'command':command,'binary_sha256':row['binary_sha256'],'log':mode+'-'+str(seed)+'.log','passed':False};report['runs'].append(run);save()
   run.update(helper['run_child'](command,workspace,env,out/run['log'],60))
   records=[line.removeprefix('MESH_CHAOS_WORKLOAD ')for line in(out/run['log']).read_text().splitlines()if line.startswith('MESH_CHAOS_WORKLOAD ')]
   run['json_records']=len(records)
   if len(records)!=1 or run['returncode']or run['timed_out']:raise RuntimeError(mode+' seed '+str(seed)+' failed')
   r=json.loads(records[0]);run['report']=r;run['checks']=checks(r,seed);run['checks']['binary']=helper['sha256'](binary)==row['binary_sha256'];run['passed']=all(run['checks'].values());save()
   if not run['passed']:raise RuntimeError('invariant failed')
   print(mode,seed,'converged in',r['elapsed_us'],'us',flush=True)
 logical=('seed','plan_fingerprint','final_state_hash','logical_actions_completed','authority_revision','replica_revisions')
 report['logical_replay_equal']={str(seed):all(next(r['report']for r in report['runs']if r['seed']==seed and r['mode']=='Debug')[name]==next(r['report']for r in report['runs']if r['seed']==seed and r['mode']=='ReleaseSafe')[name]for name in logical)for seed in seeds}
 report['execution_passed']=all(report['logical_replay_equal'].values())
except BaseException as error:
 report['error']={'type':type(error).__name__,'message':str(error)}
finally:
 after=capture();report['sources_after']=after;report['sources_unchanged']=before==after;report['passed']=report['execution_passed']and report['sources_unchanged'];report['finished_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat();save();print(out/'report.json',flush=True)
raise SystemExit(0 if report['passed']else 1)
