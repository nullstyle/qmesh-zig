from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess

ROOT = Path('/Users/nullstyle/prj/zig/qmesh-zig')
QUIC = ROOT.parent / 'quic-zig'
QMSG = ROOT.parent / 'qmsg'
DEST = ROOT / 'evidence/sprint-4-2026-10-26'
spec = importlib.util.spec_from_file_location('composition', ROOT / 'tools/check-composition.py')
composition = importlib.util.module_from_spec(spec)
spec.loader.exec_module(composition)
expected = json.loads((ROOT / '.zig-cache/sprint-4-frozen-inputs.json').read_text())

for name, previous in expected.items():
    current = composition.source_identity(Path(previous['path']))
    assert current['tree_sha256'] == previous['tree_sha256'], (name, current)
    assert current['commit'] == previous['commit'], name
    subprocess.run(['git', 'diff', '--check'], cwd=previous['path'], check=True)
    subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--', 'build.zig.zon', 'mise.toml'],
                   cwd=previous['path'], check=True, capture_output=True)

locations = [
    ('mac-debug', ROOT / '.zig-cache/sprint-4-composition-debug'),
    ('mac-release-safe', ROOT / '.zig-cache/sprint-4-composition-safe'),
    ('linux-selected-debug', ROOT / '.zig-cache/sprint-4-linux-composition/selected-debug'),
    ('linux-selected-release-safe', ROOT / '.zig-cache/sprint-4-linux-composition/selected-safe'),
]
matrices = []
known_failures = []
for label, path in locations:
    report = json.loads((path / 'report.json').read_text())
    assert report['sources_unchanged'], label
    assert report['finished_utc'] and report['final_sources'] and report['setup']['returncode'] == 0, label
    assert report['optimize'] == ('Debug' if label.endswith('debug') else 'ReleaseSafe'), label
    assert report['requested_inputs']['mode'] == ('selected' if label.startswith('linux') else 'both'), label
    assert report['compiler']['version'] == '0.17.0', label
    compiler_sha = ('5165c9a2d17938a8173839b3adf81d025b558d38d9e9711237a6fa5b8d8bb3f7' if label.startswith('linux')
                    else '1c5f706db0ed6d55451940f31dc05a6177d05696bc1fa5d853696d04c718b523')
    assert report['compiler']['sha256'] == compiler_sha, label
    assert report['requested_inputs']['sprint2'] and report['requested_inputs']['sprint3'] and report['requested_inputs']['sprint4'], label
    expected_counts = {'composition': 2, 'sprint2': 1, 'sprint3': 2, 'sprint4': 2, 'qmsg': 894}
    prefixes = ('selected',) if label.startswith('linux') else ('released', 'selected')
    expected_names = {prefix + '-' + suffix for prefix in prefixes for suffix in expected_counts}
    assert {check['name'] for check in report['checks']} == expected_names and len(report['checks']) == len(expected_names), label
    selected = [check for check in report['checks'] if check['name'].startswith('selected-')]
    assert len(selected) == 5 and all(check['returncode'] == 0 for check in selected), label
    assert {check['name'] for check in selected} == {'selected-composition', 'selected-sprint2', 'selected-sprint3', 'selected-sprint4', 'selected-qmsg'}, label
    for check in selected:
        summary = check['summary'] or ''
        counts = re.search(r'(\d+)/(\d+) tests passed', summary)
        total = expected_counts[check['name'].removeprefix('selected-')]
        assert counts and int(counts[1]) == int(counts[2]) == total, (label, check)
        assert 'skipped' not in summary and 'crashed' not in summary, (label, check)
    for check in report['checks']:
        if check['returncode']:
            raw = (path / check['log']).read_text()
            assert label == 'mac-debug' and check['name'].startswith('released-') and 'built == null' in raw and 'pollDatagram' in raw, (label, check)
            known_failures.append({
                'matrix': label, 'check': check['name'],
                'reason': 'Immutable released QUIC 0.37.2 inherited idle-cache assertion; fixed candidate qualifies separately.',
                'log': label + '/' + check['log'],
            })
    if label.startswith('linux'):
        assert report['passed'], label
    for name, original in expected.items():
        key = {'quic-zig': 'quic', 'qmesh-zig': 'qmesh', 'qmsg': 'qmsg'}[name]
        assert report['sources'][key]['tree_sha256'] == original['tree_sha256'], (label, name)
    matrices.append({
        'name': label, 'report': label + '/report.json', 'passed': report['passed'],
        'sources_unchanged': report['sources_unchanged'], 'host': report['host'],
        'compiler': report['compiler'],
        'checks': [{key: check[key] for key in ('name', 'returncode', 'summary')} for check in report['checks']],
    })

quic_dir = QUIC / 'benchmark-reports/sprint-4-2026-10-26'
quic_index = json.loads((quic_dir / 'index.json').read_text())
assert quic_index['local_qualification_complete'] and quic_index['required_gates_passed'] == 25
assert composition.sha256(Path(quic_index['manifest'])) == quic_index['manifest_sha256']
quic_manifest = json.loads(Path(quic_index['manifest']).read_text())
assert quic_manifest['local_qualification_complete'] and quic_manifest['required_gate_count'] == len(quic_manifest['gates']) == 25
assert len({gate['name'] for gate in quic_manifest['gates']}) == 25
assert quic_manifest['archive_files_equal_worktree'] and quic_manifest['runtime_matches_initial_gate_input']
assert quic_manifest['source']['tree_sha256'] == expected['quic-zig']['tree_sha256']
assert quic_manifest['archive'] == quic_index['archive']
for gate in quic_manifest['gates']:
    assert gate['passed'] and gate['exit_code'] == 0 and gate['runtime_unchanged'], gate['name']
    assert composition.sha256(Path(gate['record_path'])) == gate['record_sha256'], gate['name']
    assert composition.sha256(quic_dir / gate['log']) == gate['log_sha256'], gate['name']
    if gate['name'] != 'fairness-released':
        assert gate['runtime_build_tree_sha256'] == quic_index['runtime_build_tree_sha256'], gate['name']
proof = quic_manifest['package_consumer_proof']
assert all(proof[name] for name in ('archive_sha256_verified', 'all_extracted_files_equal_frozen_source',
                                   'debug_and_release_safe_executed', 'all_six_mode_guards_passed'))
assert not proof['canonical_zig_package_hash_verified'] and not proof['public_url_fetch_verified']
archive = Path(quic_index['archive']['path'])
assert composition.sha256(archive) == quic_index['archive']['sha256']
assert quic_index['source']['tree_sha256'] == expected['quic-zig']['tree_sha256']
qmesh_index = json.loads((ROOT / '.zig-cache/sprint-4-evidence/summary.json').read_text())
assert qmesh_index['live_runs_passed'] == 6 and qmesh_index['live_sources_unchanged']
assert all(gate['failures'] == 0 and gate['skips'] == 0 for gate in qmesh_index['core_gates'].values())
for name, digest in qmesh_index['source_files_sha256'].items():
    assert composition.sha256(ROOT / name) == digest, name
seeded = json.loads((ROOT / '.zig-cache/sprint-4-evidence/seeded-matrix-final/report.json').read_text())
assert seeded['passed'] and seeded['sources_unchanged'] and len(seeded['runs']) == 6
assert all(run['passed'] and all(run['checks'].values()) for run in seeded['runs'])
replay = json.loads((ROOT / '.zig-cache/sprint-4-evidence/replay-cross-check.json').read_text())
assert replay['all_virtual_equal'] and all(run['plan_and_state_match'] for run in replay['live_plan_state_matches_virtual'])
qmsg_index = json.loads((QMSG / '.zig-cache/sprint-4-evidence/summary.json').read_text())
assert qmsg_index['passed'] and qmsg_index['sources_unchanged']
assert qmsg_index['source_freeze']['source'] == expected['qmsg']
assert qmsg_index['source_after_producer_checks'] == expected['qmsg']
assert qmsg_index['canonical_qmsg_tree_sha256'] == expected['qmsg']['tree_sha256']
assert qmsg_index['toolchain']['version'] == '0.17.0'
assert qmsg_index['toolchain']['compiler_sha256'] == '1c5f706db0ed6d55451940f31dc05a6177d05696bc1fa5d853696d04c718b523'
assert qmsg_index['final_candidate_archive']['sha256'] == quic_index['archive']['sha256']
assert set(qmsg_index['modes']) == {'debug', 'releasesafe'}
for mode, details in qmsg_index['modes'].items():
    assert details['status'] == 'passed', mode
    native = details['native_full']
    assert native['returncode'] == 0 and native['counts']['executed_skipped'] == 0, mode
    assert native['counts']['executed_passed'] == native['counts']['executed_total'] == 897, mode
    assert len(details['native_smokes']) == 5 and all(smoke['exit_code'] == 0 for smoke in details['native_smokes']), mode
    fault = details['candidate_public_faults']
    assert fault['returncode'] == 0 and fault['sources_unchanged'], mode
    assert fault['counts']['executed_passed'] == fault['counts']['executed_total'] == 2 and fault['counts']['executed_skipped'] == 0, mode
    for key, repo in (('qmsg', 'qmsg'), ('quic', 'quic-zig')):
        assert fault['sources_before'][key] == fault['sources_after'][key] == expected[repo], (mode, key)
    assert len(fault['runs']) == 2 and all(run['returncode'] == 0 for run in fault['runs']), mode
    assert {record['variant'] for record in fault['public_records']} == {'default', 'variant'}, mode
    for record in fault['public_records']:
        lines = [line.removeprefix('PUBLIC_FAULTS ') for line in Path(record['log']).read_text().splitlines() if line.startswith('PUBLIC_FAULTS ')]
        assert len(lines) == 1 and json.loads(lines[0]) == record['record'], (mode, record['variant'])
        result = record['record']
        assert result['completed'] and result['accepted'] == result['terminal'] == 15
        assert [result[name] for name in ('succeeded', 'authorization_denied', 'canceled', 'deadline_exceeded', 'peer_closed')] == [10, 1, 2, 1, 1]
        assert result['reconnected'] and result['drain_closed'] and result['remote_close_observed'] and result['role_positive_control_ready']
        assert result['events_received'] == result['events_deinitialized'] and result['handles_retained'] == result['handles_released']
        assert result['pending_at_end'] == result['duplicate_terminals'] == 0
        assert result['remote_loss_us'] < result['loss_request_deadline_ms'] * 1000
assert len(qmsg_index['cli_controls']) == 3 and all(control['passed'] for control in qmsg_index['cli_controls'])
for artifact in qmsg_index['artifact_index']:
    assert composition.sha256(Path(artifact['path'])) == artifact['sha256'], artifact['path']

linux_dir = ROOT / '.zig-cache/sprint-4-linux-composition'
linux_host = json.loads((linux_dir / 'host-result.json').read_text())
linux_checkpoint = json.loads((linux_dir / 'checkpoint-result.json').read_text())
linux_prepared = json.loads((linux_dir / 'prepared-inputs.json').read_text())
linux_launch = json.loads((linux_dir / 'launch.json').read_text())
assert linux_host['exit_code'] == 0 and linux_host['original_inputs_unchanged']
assert linux_host['final_original_identities'] == expected
assert linux_prepared['original_identities'] == expected
assert linux_checkpoint['passed'] and linux_checkpoint['sources_unchanged']
assert len(linux_checkpoint['modes']) == 2 and all(mode['passed'] for mode in linux_checkpoint['modes'])
assert linux_checkpoint['source_bundle_sha256'] == linux_prepared['bundle_sha256'] == linux_host['bundle_sha256']
assert linux_launch['image']['id'] == 'sha256:97711185ccd951b04ca293caa83c7b88832ef61c0422439ae82903b7a1f6f969'

assert not DEST.exists(), DEST
DEST.mkdir(parents=True)
artifacts = []
def copy_file(source, relative):
    target = DEST / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    raw = target.read_bytes()
    assert raw == source.read_bytes()
    artifacts.append({'path': relative.as_posix(), 'origin': str(source),
                      'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw)})

def top_files(label, directory):
    for source in sorted(directory.iterdir()):
        if source.is_file() and source.suffix in ('.json', '.log', '.txt', '.xml', '.py', '.md'):
            copy_file(source, Path(label) / source.name)

for label, path in locations:
    top_files(label, path)
    if label.startswith('mac'):
        suffix = 'debug' if label.endswith('debug') else 'safe'
        copy_file(ROOT / ('.zig-cache/sprint-4-composition-' + suffix + '-launcher.log'), Path(label) / 'launcher.log')
    for name in ('build.zig', 'build.zig.zon'):
        copy_file(path / 'workspace/tests/composition' / name, Path(label) / 'inputs' / name)
    for name in ('composition_test.zig', 'sprint2_composition_test.zig', 'sprint3_composition_test.zig', 'sprint4_composition_test.zig'):
        copy_file(path / 'workspace/tests' / name, Path(label) / 'inputs' / name)

for label, path in [('qmsg-producer', QMSG / '.zig-cache/sprint-4-evidence'),
                    ('qmesh-producer', ROOT / '.zig-cache/sprint-4-evidence'),
                    ('quic-producer', quic_dir),
                    ('linux-inputs', ROOT / '.zig-cache/sprint-4-linux-composition')]:
    top_files(label, path)

for label, path, directories in [
    ('qmesh-producer', ROOT / '.zig-cache/sprint-4-evidence', ['seeded-matrix-final']),
    ('quic-producer', quic_dir, ['interop-client-logs', 'interop-server-logs', 'fuzz-coverage']),
]:
    for directory in directories:
        for source in sorted((path / directory).rglob('*')):
            if source.is_file() and source.suffix in ('.json', '.log', '.txt', '.xml', '.csv'):
                copy_file(source, Path(label) / source.relative_to(path))

copy_file(ROOT / '.zig-cache/sprint-4-frozen-inputs.json', Path('frozen-inputs.json'))
copy_file(Path(__file__), Path('finalize-evidence.py'))
post = {name: composition.source_identity(Path(previous['path']), DEST if name == 'qmesh-zig' else None)
        for name, previous in expected.items()}
for name, current in post.items():
    assert current['tree_sha256'] == expected[name]['tree_sha256'], name

verification = {
    'schema_version': 1,
    'generated_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'sprint3_commits': {name: previous['commit'] for name, previous in expected.items()},
    'sprint4_branches': {name: subprocess.check_output(['git', 'branch', '--show-current'], cwd=previous['path'], text=True).strip()
                         for name, previous in expected.items()},
    'sprint4_committed': False, 'pushed': False, 'public_versions_or_pins_changed': False,
    'candidate_qualification_passed': True,
    'all_final_matrix_commands_passed': not known_failures,
    'released_pin_recovery_qualified': False,
    'released_pin_limitation': 'Released QUIC 0.37.2 retains the reproduced idle-cache defect. Timing-dependent green application runs do not clear retained failure evidence. Public pins remain unchanged.',
    'known_final_matrix_failures': known_failures,
    'matrices': matrices,
    'source_inputs_before_evidence_copy': expected,
    'source_inputs_after_evidence_excluding_directory': post,
    'candidate_archive': quic_index['archive'],
    'candidate_runtime_build_tree_sha256': quic_index['runtime_build_tree_sha256'],
    'linux_isolation': {
        'source_bundle_sha256': linux_prepared['bundle_sha256'],
        'image': linux_launch['image'],
        'checkpoint': 'linux-inputs/checkpoint-result.json',
        'original_sources_unchanged': linux_host['original_inputs_unchanged'],
        'prepared_clone_sources_unchanged': linux_checkpoint['sources_unchanged'],
        'mount_scope': 'Only ignored checkpoint evidence was mounted; live original repositories were not mounted.',
    },
    'producer_reports': {'quic-zig': 'quic-producer/index.json', 'qmsg': 'qmsg-producer/summary.json', 'qmesh-zig': 'qmesh-producer/summary.json'},
    'transport_required_local_gates': quic_index['required_gates_passed'],
    'transport_promotion_ready': quic_index['promotion_ready'],
    'transport_promotion_hold': quic_index['promotion_hold'],
    'canonical_zig_package_hash_verified': False,
    'public_url_fetch_verified': False,
    'compatibility': [
        'No production protocol, default policy, public pin or version changes in Sprint 4.',
        'Public messaging qualification uses 15 admitted requests and owned terminal outcomes; ordinary events may be deliberately dropped under zero-capacity pressure.',
        'Wrong-role and wrong-identity rejections include matched positive admission controls. Remote loss is initiated solely by the server and observed before client teardown.',
        'The custom authorization fixture tests existing authorization integration, not PASETO cryptography or credential provisioning.',
        'Late ReplyHandle calls can fail locally or be suppressed later; this scenario does not prove delayed wire-packet arrival. QUIC driver regressions provide that separate evidence.',
        'The seeded mesh scenario injects local fixture outages, restarts an application owner and moves a configured endpoint. It does not establish OS-process crash recovery, WAN behavior or persistence.',
        'SWIM retains dead records; absent-route removal is checked using a fresh owner generation. No membership GC protocol is introduced.',
    ],
    'limits': [
        'No pushes, releases, tags, public pin changes or Sprint 4 commits. Inherited transport fairness promotion hold remains.',
        'Mac native and Linux arm64 container results are distinct from hosted CI, native Windows, native Linux x86-64 and physical-network qualification.',
        'Foreign-target compile recipes passed; they do not establish foreign-target native runtime execution.',
        'Local archive SHA-256, file equality and out-of-tree consumer proof passed. Canonical Zig package-hash calculation and public URL fetching remain incomplete.',
        'Historical producer slices and earlier review caveats are preserved; final reports and review addenda identify the qualified source revisions.',
        'Large artifacts are not copied into this directory; per-gate records preserve their measured hashes and original local paths. Durable copies retain text results.',
        'Evidence-only files were copied after source-stable qualification; compiled inputs remain byte-identical when this evidence directory is excluded.',
    ],
    'artifacts': artifacts,
}
(DEST / 'verification.json').write_text(json.dumps(verification, indent=2) + '\n')
print(json.dumps({'verification': str(DEST / 'verification.json'), 'candidate_qualification_passed': True,
                  'known_final_matrix_failures': known_failures, 'artifact_count': len(artifacts),
                  'artifact_bytes': sum(item['bytes'] for item in artifacts)}, indent=2))
