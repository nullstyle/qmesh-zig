#!/usr/bin/env python3
"""Run only after the root explicitly releases its quiet profiling window."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess

BASE = Path(__file__).resolve().parent
OUTPUT = BASE.parent / "sprint-3-linux-composition"
IMAGE = "sha256:97711185ccd951b04ca293caa83c7b88832ef61c0422439ae82903b7a1f6f969"


def shell_script(lane, optimize, provenance):
    expected = {name: {key: row["clone"][key] for key in ("tree_sha256", "file_count", "commit", "status")} for name, row in provenance["inputs"].items()}
    setup = """set -euo pipefail
ulimit -c 0
export PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export ZIG_GLOBAL_CACHE_DIR=/workspace/.zig-global-cache
export PYTHONDONTWRITEBYTECODE=1
mkdir -p /workspace
for repo in quic-zig qmsg qmesh-zig; do
  cp -a "/inputs/$repo" /workspace/
  git config --global --add safe.directory "/workspace/$repo"
done
cd /workspace/qmesh-zig
python3 - <<'RUNTIME_PY'
import datetime,hashlib,importlib.util,json,os,platform,shutil,subprocess
from pathlib import Path
spec=importlib.util.spec_from_file_location('composition','/workspace/qmesh-zig/tools/check-composition.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
expected=EXPECTED_INPUTS
compiler=Path(shutil.which('zig')).resolve()
version=subprocess.check_output([str(compiler),'version'],text=True).strip()
sha=hashlib.sha256(compiler.read_bytes()).hexdigest()
assert str(compiler)=='/opt/zig/zig' and version=='0.17.0' and sha.startswith('5165c9a2'),(compiler,version,sha)
sources={}
for name,wanted in expected.items():
    identity=m.source_identity(Path('/workspace')/name)
    for key,value in wanted.items():assert identity[key]==value,(name,key,identity[key],value)
    assert subprocess.check_output(['git','rev-parse','--is-shallow-repository'],cwd='/workspace/'+name,text=True).strip()=='true'
    assert not Path('/workspace',name,'.git/objects/info/alternates').exists()
    sources[name]=identity
runtime={'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'host':subprocess.check_output(['uname','-srm'],text=True).strip(),'platform':platform.platform(),'os_release':Path('/etc/os-release').read_text(),'compiler':{'path':str(compiler),'version':version,'sha256':sha},'git':subprocess.check_output(['git','--version'],text=True).strip(),'python':platform.python_version(),'image_id':'IMAGE_ID','entrypoint_override':'/bin/bash','environment':{key:os.environ.get(key) for key in ['PATH','ZIG_GLOBAL_CACHE_DIR','PYTHONDONTWRITEBYTECODE']},'sources_before':sources}
Path('/evidence/LANE-runtime.json').write_text(json.dumps(runtime,indent=2)+'\\n')
print('LINUX_RUNTIME '+json.dumps({'compiler':runtime['compiler'],'host':runtime['host'],'source_hashes':{name:identity['tree_sha256'] for name,identity in sources.items()}}),flush=True)
RUNTIME_PY
python3 tools/check-composition.py --sprint2 --sprint3 --mode selected --qmsg-path /workspace/qmsg --quic-path /workspace/quic-zig --jobs 2 --optimize OPTIMIZE --output-dir /evidence/LANE
"""
    return setup.replace('EXPECTED_INPUTS',repr(expected)).replace('IMAGE_ID',IMAGE).replace('LANE',lane).replace('OPTIMIZE',optimize)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-after-root-signal',action='store_true',required=True)
    args=parser.parse_args()
    if not args.run_after_root_signal:raise SystemExit('Root execution signal is required.')
    provenance=json.loads((BASE/'provenance.json').read_text())
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    results={'started_utc':stamp,'image_id':IMAGE,'input_provenance':str(BASE/'provenance.json'),'lanes':{}}
    OUTPUT.mkdir(exist_ok=True)
    for lane,optimize in [('selected-debug','Debug'),('selected-safe','ReleaseSafe')]:
        if (OUTPUT/lane).exists():raise SystemExit(f'Fresh lane required; refusing existing output: {OUTPUT/lane}')
        name=f'qmsg-sprint3-linux-{lane}-{stamp.lower()}'
        command=['docker','create','--name',name,'--entrypoint','/bin/bash','--workdir','/workspace/qmesh-zig','--mount',f'type=bind,source={OUTPUT},target=/evidence',IMAGE,'-lc',shell_script(lane,optimize,provenance)]
        cid=subprocess.check_output(command,text=True).strip()
        results['lanes'][lane]={'container_id':cid,'container_name':name,'optimize':optimize,'command':command,'input_copy_command':['docker','cp',str(BASE)+'/.',cid+':/inputs'],'passed':False}
        (OUTPUT/'execution.json').write_text(json.dumps(results,indent=2)+'\n')
        subprocess.run(results['lanes'][lane]['input_copy_command'],check=True)
        with (OUTPUT/(lane+'-container.log')).open('w') as output:
            run=subprocess.run(['docker','start','--attach',cid],stdout=output,stderr=subprocess.STDOUT)
        inspected=json.loads(subprocess.check_output(['docker','inspect',cid],text=True))[0]
        results['lanes'][lane]['docker_attach_exit_code']=run.returncode
        results['lanes'][lane]['container_exit_code']=inspected['State']['ExitCode']
        results['lanes'][lane]['container_state']=inspected['State']
        results['lanes'][lane]['actual_mounts']=inspected['Mounts']
        results['lanes'][lane]['actual_image_id']=inspected['Image']
        report_path=OUTPUT/lane/'report.json'
        if report_path.exists():
            report=json.loads(report_path.read_text())
            results['lanes'][lane]['report']=str(report_path)
            results['lanes'][lane]['passed']=run.returncode==0 and inspected['State']['ExitCode']==0 and report.get('passed') is True and report.get('sources_unchanged') is True
        (OUTPUT/'execution.json').write_text(json.dumps(results,indent=2)+'\n')
        print(lane,json.dumps(results['lanes'][lane],default=str),flush=True)
        if not results['lanes'][lane]['passed']:raise SystemExit(1)
    return 0

if __name__=='__main__':raise SystemExit(main())
