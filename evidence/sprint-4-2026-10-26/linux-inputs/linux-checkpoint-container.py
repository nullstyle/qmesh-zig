#!/usr/bin/env python3
"""Runs only inside the explicitly authorized isolated Linux checkpoint."""
import sys
sys.dont_write_bytecode = True
import os
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
os.environ["GIT_OPTIONAL_LOCKS"] = "0"
os.environ["COPYFILE_DISABLE"] = "1"
os.environ["ZIG_GLOBAL_CACHE_DIR"] = "/cache/zig-global"
os.environ["GIT_CONFIG_GLOBAL"] = "/cache/git-config"
os.environ["PATH"] = "/opt/zig:" + os.environ["PATH"]
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import signal
import shutil
import subprocess
import tarfile
import time

EVIDENCE = Path("/evidence")
WORKSPACE = Path("/workspace")
NAMES = ("quic-zig", "qmsg", "qmesh-zig")
COMPILER_SHA = "5165c9a2d17938a8173839b3adf81d025b558d38d9e9711237a6fa5b8d8bb3f7"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def capture(command, cwd=None):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def save(name, value):
    (EVIDENCE / name).write_text(json.dumps(value, indent=2) + "\n")


def keep_outputs(output, target):
    target.mkdir(parents=True, exist_ok=True)
    for source in output.rglob("*"):
        if not source.is_file() or {"build-cache", ".zig-cache", "zig-pkg", "zig-out", "__pycache__"}.intersection(source.relative_to(output).parts):
            continue
        destination = target / source.relative_to(output)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def main():
    Path("/cache/zig-global").mkdir(parents=True, exist_ok=True)
    assert not WORKSPACE.exists() or not any(WORKSPACE.iterdir())
    WORKSPACE.mkdir(exist_ok=True)
    prepared = json.loads((EVIDENCE / "prepared-inputs.json").read_text())
    bundle = EVIDENCE / "input-workspace.tar"
    assert sha(bundle) == prepared["bundle_sha256"]
    with tarfile.open(bundle) as tar:
        for member in tar.getmembers():
            path = Path(member.name)
            assert not path.is_absolute() and ".." not in path.parts and path.parts[0] in NAMES
            if member.issym() or member.islnk():
                assert not Path(member.linkname).is_absolute() and ".." not in Path(member.linkname).parts
        tar.extractall(WORKSPACE)
    # Required before loading the canonical helper or asking Git for any
    # identity in the transferred, potentially differently owned clones.
    for name in NAMES:
        subprocess.run(["git", "config", "--global", "--add", "safe.directory", str(WORKSPACE / name)], check=True)
    safe = capture(["git", "config", "--global", "--get-all", "safe.directory"]).splitlines()
    assert safe == [str(WORKSPACE / name) for name in NAMES]
    compiler = Path("/opt/zig/zig")
    assert sha(compiler) == COMPILER_SHA
    assert capture([str(compiler), "version"]) == "0.17.0"
    helper_path = WORKSPACE / "qmesh-zig/tools/check-composition.py"
    assert sha(helper_path) == prepared["helper_sha256"]
    spec = importlib.util.spec_from_file_location("checkpoint_helper", helper_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    initial = {name: helper.source_identity(WORKSPACE / name) for name in NAMES}
    for name in NAMES:
        expected = prepared["prepared_identities"][name]
        assert all(initial[name].get(key) == expected.get(key) for key in expected if key != "path"), name
        assert (WORKSPACE / name / ".git").is_dir()
    save("initial-identities.json", initial)
    # Seed only the cached image's declared dependencies, never a host cache.
    packages = WORKSPACE / "qmesh-zig/zig-pkg"
    packages.mkdir(exist_ok=True)
    shutil.copytree("/src/quic-zig/zig-pkg", packages, dirs_exist_ok=True)
    result = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "platform": capture(["uname", "-srm"]),
              "compiler": {"path": str(compiler), "version": "0.17.0", "sha256": COMPILER_SHA},
              "safe_directories": safe, "initial_identities": initial,
              "source_bundle_sha256": prepared["bundle_sha256"], "modes": [], "passed": False}
    try:
        for optimize, suffix in (("Debug", "debug"), ("ReleaseSafe", "safe")):
            output = WORKSPACE / "qmesh-zig/.zig-cache/sprint-4-linux-composition" / ("selected-" + suffix)
            command = ["python3", str(helper_path), "--sprint2", "--sprint3", "--sprint4", "--mode", "selected",
                       "--qmsg-path", "/workspace/qmsg", "--quic-path", "/workspace/quic-zig", "--jobs", "2",
                       "--optimize", optimize, "--output-dir", str(output)]
            print("LINUX_CHECKPOINT_START " + optimize, flush=True)
            start = time.monotonic()
            with (EVIDENCE / ("selected-" + suffix + "-launcher.log")).open("w") as log:
                process = subprocess.Popen(command, cwd=WORKSPACE / "qmesh-zig", stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    code = process.wait(timeout=2700)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        pass
                    # The wrapper can exit while a descendant ignores TERM.
                    # Always kill the old group before starting another mode.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                    code = 124
            report_path = output / "report.json"
            report = json.loads(report_path.read_text()) if report_path.exists() else {}
            checks = []
            for check in report.get("checks", []):
                row = dict(check)
                match = re.search(r"(\d+)/(\d+) tests passed(?: \((\d+) skipped\))?", check.get("summary") or "")
                row["actual_test_counts"] = ({"passed": int(match[1]), "total": int(match[2]), "skipped": int(match[3] or 0)} if match else None)
                log_path = output / check["log"]
                if log_path.exists():
                    row["log_sha256"] = sha(log_path)
                checks.append(row)
            identities = {name: helper.source_identity(WORKSPACE / name) for name in NAMES}
            save("selected-" + suffix + "-identities.json", identities)
            keep_outputs(output, EVIDENCE / "results" / ("selected-" + suffix))
            expected_checks = ["selected-composition", "selected-sprint2", "selected-sprint3", "selected-sprint4", "selected-qmsg"]
            checks_present = [check["name"] for check in checks] == expected_checks
            nonzero_counts = all(check["actual_test_counts"] is not None and check["actual_test_counts"]["total"] > 0 for check in checks)
            executables = []
            for binary in (output / "build-cache").rglob("test"):
                if binary.is_file():
                    with binary.open("rb") as stream:
                        elf = stream.read(4) == b"\x7fELF"
                    if elf:
                        executables.append({"path": str(binary), "sha256": sha(binary), "bytes": binary.stat().st_size})
            row = {"optimize": optimize, "command": command, "returncode": code,
                   "elapsed_seconds": time.monotonic() - start, "checks": checks,
                   "sources_unchanged": identities == initial and report.get("sources_unchanged", False),
                   "all_five_check_groups_present": checks_present, "nonzero_actual_test_counts": nonzero_counts,
                   "test_executable_identities": executables,
                   "passed": code == 0 and report.get("passed", False) and identities == initial and checks_present and nonzero_counts,
                   "expected_counts_reference_only": {"integration": 7, "qmsg": 894}}
            result["modes"].append(row)
            save("checkpoint-result.json", result)
            print("LINUX_CHECKPOINT_RESULT " + json.dumps(row), flush=True)
    finally:
        result["final_identities"] = {name: helper.source_identity(WORKSPACE / name) for name in NAMES}
        result["sources_unchanged"] = result["final_identities"] == initial
        result["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        result["passed"] = len(result["modes"]) == 2 and all(row["passed"] for row in result["modes"]) and result["sources_unchanged"]
        save("final-identities.json", result["final_identities"])
        save("checkpoint-result.json", result)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
