set -euo pipefail
ulimit -c 0
export PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export ZIG_GLOBAL_CACHE_DIR=/workspace/.zig-global-cache
mkdir -p /workspace
for repo in quic-zig qmsg qmesh-zig; do cp -a "/inputs/$repo" /workspace/; done
cd /workspace/qmesh-zig
python3 - <<'RUNTIME_PY'
import datetime,hashlib,importlib.util,json,os,platform,shutil,subprocess
from pathlib import Path
spec=importlib.util.spec_from_file_location('composition','/workspace/qmesh-zig/tools/check-composition.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
expected={'quic-zig': {'tree_sha256': '2cf7e4f33ba678b24165767b53a0bc41208232d1386d22968a64843e3c723316', 'file_count': 305, 'commit': 'c74110a94667dd155068b862cb7a966aadbe7697', 'status': 'M CHANGELOG.md\n M docs/DOWNSTREAM_INTEGRATION.md\n M src/Connection/_tests_flow.zig\n M src/Connection/flow.zig\n M tests/e2e/rest_cache_table.zig\n?? docs/SPRINT_3_APPLICATION_PROFILES.md\n?? docs/SPRINT_3_APPLICATION_WORKLOADS.md\n?? tools/application-profile.zig\n?? tools/profile-applications.py\n?? tools/profile-composition.py'}, 'qmsg': {'tree_sha256': '4564992ec56914dad08a28404806b754f887d8c3980dde3044d62defff6708bf', 'file_count': 77, 'commit': '941eef6b65deb250d2e5ee56637523be9eec5527', 'status': 'M CHANGELOG.md\n M README.md\n M ROADMAP.md\n M build.zig\n M docs/QUIC_PUBSUB.md\n M docs/SPRINT.md\n M src/app.zig\n M src/node.zig\n M src/protocol/pubsub.zig\n M src/root.zig\n?? docs/SPRINT_3_RELIABLE_PUBSUB.md\n?? examples/quic_pubsub_localhost.zig\n?? examples/reliable_pubsub_workload.zig\n?? src/reliable_pubsub_test.zig'}, 'qmesh-zig': {'tree_sha256': 'd9dc3a186416f512193c1c84f3fff791d73b10870338a79651aad1ca3f7e8e7e', 'file_count': 282, 'commit': '35b4e914e5457157649bbc07c367b569382f1851', 'status': 'M build.zig\n M docs/MESSAGING.md\n M tests/composition/build.zig\n M tools/check-composition.py\n?? docs/sprint-3-composition.md\n?? docs/sprint-3-recovery.md\n?? examples/recovery-pki/\n?? examples/snapshot_recovery.zig\n?? examples/snapshot_state.zig\n?? tests/snapshot_recovery_test.zig\n?? tests/sprint3_composition_test.zig'}}
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
runtime={'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'host':subprocess.check_output(['uname','-srm'],text=True).strip(),'platform':platform.platform(),'os_release':Path('/etc/os-release').read_text(),'compiler':{'path':str(compiler),'version':version,'sha256':sha},'git':subprocess.check_output(['git','--version'],text=True).strip(),'python':platform.python_version(),'image_id':'sha256:97711185ccd951b04ca293caa83c7b88832ef61c0422439ae82903b7a1f6f969','entrypoint_override':'/bin/bash','environment':{key:os.environ.get(key) for key in ['PATH','ZIG_GLOBAL_CACHE_DIR']},'sources_before':sources}
Path('/evidence/selected-safe-runtime.json').write_text(json.dumps(runtime,indent=2)+'\n')
print('LINUX_RUNTIME '+json.dumps({'compiler':runtime['compiler'],'host':runtime['host'],'source_hashes':{name:identity['tree_sha256'] for name,identity in sources.items()}}),flush=True)
RUNTIME_PY
python3 tools/check-composition.py --sprint2 --sprint3 --mode selected --qmsg-path /workspace/qmsg --quic-path /workspace/quic-zig --jobs 2 --optimize ReleaseSafe --output-dir /evidence/selected-safe
