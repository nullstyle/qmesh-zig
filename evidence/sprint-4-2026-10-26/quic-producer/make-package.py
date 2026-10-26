#!/usr/bin/env python3
"""Freeze the final source, verify archive bytes, prepare an external consumer."""
from pathlib import Path
import datetime
import gzip
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import tarfile

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
initial = json.loads((out / "initial-candidate-manifest.json").read_text())
helper_path = Path("/Users/nullstyle/prj/zig/qmesh-zig/tools/check-composition.py")
spec = importlib.util.spec_from_file_location("composition_checker", helper_path)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
before = helper.source_identity(root)
assert before["commit"] == initial["source"]["commit"]
names = sorted(set(os.fsdecode(x) for x in subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
).split(b"\0") if x))
snapshot = out / "final-source"
snapshot.mkdir()
entries = {}
for name in names:
    source = root / name
    if not source.is_file():
        continue
    target = snapshot / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(source.stat().st_mode & 0o777)
    entries[name] = helper.sha256(target)
snapshot_identity = helper.source_identity(snapshot)
assert snapshot_identity["tree_sha256"] == before["tree_sha256"]
for name, sha in initial["runtime_build_sources"]["files"].items():
    assert entries[name] == sha, name
changed = {name: {"initial": initial["source_files"].get(name), "final": sha}
           for name, sha in entries.items() if initial["source_files"].get(name) != sha}
assert set(changed) == {"CHANGELOG.md", "docs/DOWNSTREAM_INTEGRATION.md",
                       "docs/SPRINT_4_STACK_QUALIFICATION.md"}, changed
archive = out / "quic-sprint4-final-candidate.tar.gz"
with archive.open("xb") as dest, gzip.GzipFile(filename="", mode="wb", fileobj=dest, mtime=0) as compressed, tarfile.open(fileobj=compressed, mode="w") as tar:
    for name in entries:
        data = (snapshot / name).read_bytes()
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = (snapshot / name).stat().st_mode & 0o777
        info.mtime = 0
        tar.addfile(info, io.BytesIO(data))
package = out / "package-source"
package.mkdir()
with tarfile.open(archive) as tar:
    packaged = {member.name: hashlib.sha256(tar.extractfile(member).read()).hexdigest()
                for member in tar.getmembers() if member.isfile()}
    assert packaged == entries
    tar.extractall(package, filter="data")
package_identity = helper.source_identity(package)
assert package_identity["tree_sha256"] == before["tree_sha256"]
consumer = out / "package-consumer"
for name in entries:
    prefix = "tools/consumer-smoke/"
    if not name.startswith(prefix):
        continue
    target = consumer / name.removeprefix(prefix)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(package / name, target)
zon = consumer / "build.zig.zon"
text = zon.read_text()
assert text.count('"../.."') == 1
zon.write_text(text.replace('"../.."', '"../package-source"'))
assert helper.source_identity(root) == before
manifest = {"schema_version": 1,
            "recorded_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "scope": "Unpublished final full-source candidate after Sprint4 documentation freeze; runtime/build source is identical to the heavy-gate input",
            "identity_algorithm": "exact composition source_identity: SHA256 of sorted u64be path-length/path and u64be content-length/content records",
            "identity_helper_sha256": helper.sha256(helper_path),
            "source": before, "snapshot": snapshot_identity,
            "archive": {"path": str(archive), "sha256": helper.sha256(archive), "bytes": archive.stat().st_size, "file_count": len(packaged)},
            "extracted_source": package_identity,
            "archive_files_equal_worktree": True,
            "runtime_build_sources": initial["runtime_build_sources"],
            "runtime_matches_initial_gate_input": True,
            "documentation_only_changes": changed,
            "all_file_sha256": entries,
            "compiler": initial["compiler"],
            "package_consumer_directory": str(consumer),
            "package_validation_method": "SHA256 verified local archive, exact per-file extraction equality, and copied out-of-tree consumer selecting the extracted package by path; no standalone Zig package rehash",
            "promotion_ready": False,
            "promotion_hold": "Inherited mixed BBR/CUBIC share difference remains under review; passing machinery floors and qualification gates do not clear this hold"}
(out / "final-candidate-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps({"source_tree_sha256": before["tree_sha256"],
                  "archive": manifest["archive"],
                  "runtime_tree_sha256": initial["runtime_build_sources"]["tree_sha256"]}, indent=2))
