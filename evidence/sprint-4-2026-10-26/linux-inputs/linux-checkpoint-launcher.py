#!/usr/bin/env python3
"""Plan by default; clone/run only after explicit frozen-input authorization."""
import sys
sys.dont_write_bytecode = True
import os
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
os.environ["GIT_OPTIONAL_LOCKS"] = "0"
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import uuid

HERE = Path(__file__).resolve().parent
BRANCHES = {"quic-zig": "codex/sprint-4-stack-qualification",
            "qmsg": "codex/sprint-4-public-faults",
            "qmesh-zig": "codex/sprint-4-seeded-chaos"}
IMAGE = "quic-zig-sprint1-builder:local"
IMAGE_ID = "sha256:97711185ccd951b04ca293caa83c7b88832ef61c0422439ae82903b7a1f6f969"
HEADS = {"quic-zig": "43c2390557c47f48e6c28e07a31efdb2b6723478",
         "qmsg": "8510c90c6aad9dd0b22ca1ace953fc545e044491",
         "qmesh-zig": "2401ec63540e997aa373c750de642af80e03628d"}
PATHS = {name: Path("/Users/nullstyle/prj/zig") / name for name in HEADS}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def capture(command, cwd=None):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def match_identity(actual, expected):
    fields = ("commit", "tree_sha256", "file_count", "manifest_sha256", "dependency_pins")
    return all(actual.get(key) == expected.get(key) for key in fields)


def normalize_frozen(value):
    for key in ("repositories", "sources", "frozen_inputs"):
        if key in value and isinstance(value[key], dict):
            value = value[key]
            break
    aliases = {"quic-zig": ("quic-zig", "quic"), "qmsg": ("qmsg",), "qmesh-zig": ("qmesh-zig", "qmesh")}
    return {name: next(value[key] for key in names if key in value) for name, names in aliases.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true", help="Only after root authorizes the exact source freeze")
    parser.add_argument("--frozen-inputs", type=Path)
    parser.add_argument("--output-dir", type=Path, default=HERE / "linux-checkpoint")
    args = parser.parse_args()
    plan = {"state": "HELD: plan only; no source clone or container execution",
            "required_authorization": "Root-provided frozen inputs and explicit run authorization",
            "branches": BRANCHES, "required_heads": HEADS,
            "image": {"tag": IMAGE, "id": IMAGE_ID},
            "mount_policy": "One ignored evidence directory mounted at /evidence; no original project mounts",
            "workspace": "/workspace/{quic-zig,qmsg,qmesh-zig} copied inside the container from authentic shallow clones plus frozen file overlays",
            "git_safe_directories": ["/workspace/" + name for name in HEADS],
            "environment": {"PYTHONDONTWRITEBYTECODE": "1", "GIT_OPTIONAL_LOCKS": "0", "COPYFILE_DISABLE": "1", "ZIG_GLOBAL_CACHE_DIR": "/cache/zig-global"},
            "modes": ["Debug", "ReleaseSafe"],
            "flags": ["--sprint2", "--sprint3", "--sprint4", "--mode", "selected", "--qmsg-path", "/workspace/qmsg", "--quic-path", "/workspace/quic-zig", "--jobs", "2"],
            "outputs": "/workspace/qmesh-zig/.zig-cache/sprint-4-linux-composition/selected-{debug,safe}",
            "expected_counts_reference_only": {"integration": 7, "qmsg": 894},
            "count_policy": "Record actual wrapper summaries, including skips/caches; do not infer a pass from expected counts"}
    if not args.execute:
        print(json.dumps(plan, indent=2))
        return 0
    if args.frozen_inputs is None:
        parser.error("--execute requires the root-provided --frozen-inputs file")
    frozen_path = args.frozen_inputs.resolve(strict=True)
    frozen = normalize_frozen(json.loads(frozen_path.read_text()))
    helper_path = PATHS["qmesh-zig"] / "tools/check-composition.py"
    spec = importlib.util.spec_from_file_location("frozen_composition_helper", helper_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    original = {}
    inventories = {}
    actual_branches = {}
    for name, source in PATHS.items():
        actual_branches[name] = capture(["git", "branch", "--show-current"], source)
        assert actual_branches[name] == BRANCHES[name], (name, "unexpected checkout branch")
        original[name] = helper.source_identity(source)
        assert original[name]["commit"] == HEADS[name], (name, "HEAD changed")
        assert original[name] == frozen[name], (name, "source is not the authorized frozen identity")
        names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=source).split(b"\0")
        inventory = {}
        for raw in sorted(set(names) - {b""}):
            relative = Path(os.fsdecode(raw))
            assert not relative.is_absolute() and ".." not in relative.parts and relative.parts[0] != ".git"
            entry = source / relative
            if not entry.is_file():
                continue
            if entry.is_symlink():
                assert entry.resolve().is_relative_to(source.resolve()), (name, relative, "escaping symlink")
            inventory[relative.as_posix()] = sha(entry)
        assert len(inventory) == original[name]["file_count"]
        inventories[name] = inventory
    output = args.output_dir.resolve()
    assert output.is_relative_to(HERE.resolve()), "output must remain under the ignored producer evidence directory"
    output.mkdir(parents=True, exist_ok=False)
    (output / "frozen-inputs.json").write_bytes(frozen_path.read_bytes())
    (output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    clones = output / "prepared-workspace"
    clones.mkdir()
    prepared = {}
    for name, source in PATHS.items():
        target = clones / name
        command = ["git", "clone", "--no-local", "--depth", "1", "--single-branch", "--branch", actual_branches[name], source.as_uri(), str(target)]
        with (output / (name + "-clone.log")).open("w") as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        assert (target / ".git").is_dir() and not (target / ".git").is_symlink()
        assert capture(["git", "rev-parse", "--is-shallow-repository"], target) == "true"
        assert capture(["git", "rev-parse", "HEAD"], target) == HEADS[name]
        assert not (target / ".git/objects/info/alternates").exists()
        assert not list((target / ".git/objects/pack").glob("*.promisor"))
        promisor = subprocess.run(["git", "config", "--get-regexp", r"extensions\.partialclone|remote\..*\.promisor"], cwd=target, capture_output=True, text=True)
        assert promisor.returncode == 1, (name, "partial-clone configuration or Git error", promisor.stdout, promisor.stderr)
        # Keep authentic independent Git metadata, but replace the checkout
        # with only the actual frozen tracked/nonignored inventory.
        for entry in target.iterdir():
            if entry.name == ".git":
                continue
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
        for relative, expected_sha in inventories[name].items():
            src = source / relative
            dst = target / relative
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_symlink():
                dst.symlink_to(os.readlink(src))
            else:
                shutil.copy2(src, dst)
            assert sha(dst) == expected_sha
        prepared[name] = helper.source_identity(target)
        assert match_identity(prepared[name], frozen[name]), (name, "clone overlay differs")
    assert all(helper.source_identity(PATHS[name]) == original[name] for name in HEADS), "original inputs changed during preparation"
    bundle = output / "input-workspace.tar"
    with tarfile.open(bundle, "w") as tar:
        for name in HEADS:
            tar.add(clones / name / ".git", arcname=name + "/.git", recursive=True)
            for relative in inventories[name]:
                tar.add(clones / name / relative, arcname=name + "/" + relative, recursive=False)
    provenance = {"original_identities": original, "prepared_identities": prepared,
                  "frozen_file_sha256": inventories, "bundle_sha256": sha(bundle),
                  "helper_sha256": sha(helper_path), "branches": actual_branches,
                  "note": "Clone index is authentic HEAD; its status reports the actual file overlay. Frozen original status is preserved separately."}
    (output / "prepared-inputs.json").write_text(json.dumps(provenance, indent=2) + "\n")
    shutil.copy2(HERE / "linux-checkpoint-container.py", output / "container-checkpoint.py")
    image = json.loads(capture(["docker", "image", "inspect", IMAGE]))[0]
    assert image["Id"] == IMAGE_ID and image["Architecture"] == "arm64" and image["Os"] == "linux"
    name = "quic-s4-checkpoint-" + uuid.uuid4().hex[:12]
    command = ["docker", "run", "--rm", "--name", name, "--entrypoint", "/bin/bash",
               "-e", "PYTHONDONTWRITEBYTECODE=1", "-e", "GIT_OPTIONAL_LOCKS=0", "-e", "COPYFILE_DISABLE=1",
               "-v", str(output) + ":/evidence:rw", IMAGE_ID,
               "-lc", "export PYTHONDONTWRITEBYTECODE=1; exec python3 /evidence/container-checkpoint.py"]
    launch = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "command": command, "image": {"id": image["Id"], "platform": "linux/arm64"}}
    (output / "launch.json").write_text(json.dumps(launch, indent=2) + "\n")
    with (output / "docker-launch.log").open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=5800)
        except subprocess.TimeoutExpired:
            code = 124
        finally:
            # Remove only this launcher's uniquely named container, including
            # when its client was interrupted or timed out.
            subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    final_original = {name: helper.source_identity(path) for name, path in PATHS.items()}
    result = {"finished_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "exit_code": code,
              "original_inputs_unchanged": final_original == original, "final_original_identities": final_original,
              "bundle_sha256": sha(bundle), "container_result": "checkpoint-result.json"}
    (output / "host-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if code == 0 and result["original_inputs_unchanged"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
