import datetime,hashlib,importlib.util,json,os,pathlib,re,subprocess,sys
sys.dont_write_bytecode=True
repo=pathlib.Path('/Users/nullstyle/prj/zig/qmsg')
p=repo/'.zig-cache/sprint-4-evidence'
spec=importlib.util.spec_from_file_location('composition_checker', '/Users/nullstyle/prj/zig/qmesh-zig/tools/check-composition.py')
checker=importlib.util.module_from_spec(spec); spec.loader.exec_module(checker)
frozen=json.loads((p/'source-frozen.json').read_text())
source=checker.source_identity(repo)
def read(name): return json.loads((p/name).read_text())
def counts(name):
 text=(p/name).read_text(errors='replace')
 runs=[]
 for line in text.splitlines():
  if 'run test ' not in line: continue
  m=re.search(r'run test (\d+) pass(?:, (\d+) skip)? \((\d+) total\)',line)
  if m: runs.append({'passed':int(m[1]),'skipped':int(m[2] or 0),'total':int(m[3]),'line':line.strip()})
 return {'build_summaries':re.findall(r'^Build Summary:.*$',text,re.M),'executed_passed':sum(r['passed'] for r in runs),'executed_skipped':sum(r['skipped'] for r in runs),'executed_total':sum(r['total'] for r in runs),'cached_test_runs':len(re.findall(r'run test cached',text)),'test_runs':runs,'example_executable_compilations':len(re.findall(r'compile exe ',text))}
report={'schema_version':1,'sprint':4,'generated_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'product_change':'Public-interface qualification workload, tests, CLI, build target and documentation only; no src runtime changes, wire changes, pin/version changes, commits or pushes.','source_freeze':frozen,'source_after_producer_checks':source,'sources_unchanged':source==frozen['source'],'canonical_qmsg_tree_sha256':source['tree_sha256'],'source_file_count':source['file_count'],'modes':{},'cli_controls':read('candidate-cli-controls.json'),'native_released_limitation':'QUIC v0.37.2 inherited S3 idle-cache assert is retained as a known negative. Passing ordinary producer tests/smokes does not clear it. Dedicated S4 positives below use fixed selected QUIC. Parent final composition verifies final exact archive independently.','final_candidate_archive':read('candidate-debug-command.json')['final_candidate_archive']}
compiler=pathlib.Path(subprocess.check_output(['mise','which','zig'],cwd=repo,text=True).strip())
report['toolchain']={'compiler_path':str(compiler),'compiler_realpath':str(compiler.resolve()),'compiler_sha256':checker.sha256(compiler),'version':subprocess.check_output([str(compiler),'version'],cwd=repo,text=True).strip(),'platform':sys.platform,'machine':os.uname().machine,'environment':{'ZIG_LOCAL_PKG_DIR':'/Users/nullstyle/prj/zig/qmesh-zig/zig-pkg','PYTHONDONTWRITEBYTECODE':'1'},'jobs':2}
ok=report['sources_unchanged'] and all(r['passed'] for r in report['cli_controls'])
for label in ('debug','releasesafe'):
 native_file=p/('native-'+label+'-command.json')
 if not native_file.exists():
  report['modes'][label]={'status':'pending','missing':str(native_file)}; ok=False; continue
 native=read(native_file.name); native['counts']=counts('native-'+label+'.log'); native['log']=str(p/('native-'+label+'.log')); smokes=[]
 for name in ('pubsub','owned','node-app','runtime','app-dispatch'):
  result=p/('native-'+label+'-'+name+'-result.json')
  if not result.exists(): smokes.append({'status':'pending','missing':str(result)}); ok=False; continue
  item=read(result.name); item['log']=str(p/('native-'+label+'-'+name+'.log')); smokes.append(item); ok=ok and item['exit_code']==0
 candidate=read('candidate-'+label+'-command.json'); candidate['counts']=counts('candidate-'+label+'.log'); candidate['log']=str(p/('candidate-'+label+'.log')); public_records=[]
 for variant in ('default','variant'):
  log=p/('candidate-'+label+'-'+variant+'.log')
  lines=[line for line in log.read_text().splitlines() if line.startswith('PUBLIC_FAULTS ')]
  assert len(lines)==1,(str(log),len(lines))
  record=json.loads(lines[0].removeprefix('PUBLIC_FAULTS '))
  assert record['completed'] and record['accepted']==record['terminal']==15 and record['pending_at_end']==record['duplicate_terminals']==0
  assert record['events_received']==record['events_deinitialized'] and record['handles_retained']==record['handles_released']==4
  public_records.append({'variant':variant,'log':str(log),'record':record})
 candidate['public_records']=public_records
 candidate['transport_selection_note']='Live local QUIC source through shared parent qmsg module (canonical source identities captured before/after); final archive SHA verified, parent final matrix owns direct archive qualification.'
 mode_ok=native['returncode']==0 and candidate['returncode']==0 and candidate['sources_unchanged'] and all(r['returncode']==0 for r in candidate['runs']) and all(s.get('exit_code')==0 for s in smokes)
 ok=ok and mode_ok
 report['modes'][label]={'status':'passed' if mode_ok else 'failed_or_pending','native_full':native,'native_smokes':smokes,'candidate_public_faults':candidate}
report['producer_qualification_status']='passed' if ok else 'pending_or_failed'
report['passed']=ok
report['artifact_index']=[{'path':str(f),'sha256':checker.sha256(f),'bytes':f.stat().st_size} for f in sorted(p.iterdir()) if f.is_file() and f.name not in ('summary.json','summary.json.tmp','summarize.py')]
(p/'summary.json.tmp').write_text(json.dumps(report,indent=2)+'\n'); (p/'summary.json.tmp').replace(p/'summary.json')
print(json.dumps({'producer_qualification_status':report['producer_qualification_status'],'sources_unchanged':report['sources_unchanged'],'source_sha256':source['tree_sha256'],'modes':{m:v['status'] for m,v in report['modes'].items()}},indent=2))
