#!/usr/bin/env python3
"""Verify released and selected QUIC composition without implicit siblings."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent


def capture(command, cwd=ROOT):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_identity(path, exclude=None):
    """Hash actual tracked and nonignored files, including uncommitted inputs."""
    path = path.resolve()
    result = {"path": str(path)}
    if (path / ".git").exists():
        result["commit"] = capture(["git", "rev-parse", "HEAD"], path)
        result["status"] = capture(["git", "status", "--short"], path)
        names = subprocess.check_output(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=path
        ).split(b"\0")
    else:
        names = [os.fsencode(entry.relative_to(path).as_posix()) for entry in path.rglob("*") if entry.is_file()]
    digest = hashlib.sha256()
    count = 0
    for name in sorted(set(names) - {b""}):
        entry = path / os.fsdecode(name)
        if exclude and (entry == exclude or exclude in entry.parents):
            continue
        if not entry.is_file():
            continue
        contents = entry.read_bytes()
        digest.update(len(name).to_bytes(8, "big"))
        digest.update(name)
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
        count += 1
    result.update(tree_sha256=digest.hexdigest(), file_count=count)
    manifest = path / "build.zig.zon"
    if manifest.exists():
        result["manifest_sha256"] = sha256(manifest)
        # Record the actual transport/crypto inputs, not just package versions.
        result["dependency_pins"] = {
            name: {"url": url, "hash": package_hash}
            for name, url, package_hash in re.findall(
                r'\.(quic|boringssl)\s*=\s*\.\{\s*\.url\s*=\s*"([^"]+)"\s*,\s*\.hash\s*=\s*"([^"]+)"',
                manifest.read_text(),
            )
        }
    return result


def dependency(manifest, name):
    match = re.search(r"\." + name + r"\s*=\s*\.\{.*?\},", manifest, re.S)
    if not match:
        raise ValueError(f"missing {name} dependency in composition manifest")
    return match.group(0)


def replace_dependency(manifest, name, path, stage):
    relative = os.path.relpath(path.resolve(), stage)
    replacement = "." + name + " = .{ .path = " + json.dumps(relative) + " },"
    return manifest.replace(dependency(manifest, name), replacement, 1)


def extract_source(archive, destination):
    """Extract a verified source tarball, with an optional common root."""
    with tarfile.open(archive) as source:
        members = source.getmembers()
        names = [Path(member.name).parts for member in members if member.name not in (".", "")]
        prefix = names[0][0] if names and all(name[0] == names[0][0] for name in names) else None
        # A rootless package may happen to have only one source directory.
        if not any(member.name.rstrip("/") == f"{prefix}/build.zig.zon" for member in members):
            prefix = None
        for member in members:
            name = Path(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise ValueError(f"unsafe archive path: {member.name}")
            relative = Path(*name.parts[1:]) if prefix else name
            output = destination / relative
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                output.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as data, output.open("wb") as target:
                    shutil.copyfileobj(data, target)
            else:
                raise ValueError(f"unsupported archive member: {member.name}")
    if not (destination / "build.zig.zon").is_file():
        raise ValueError("candidate archive has no build.zig.zon at its package root")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qmsg-path", type=Path, help="explicit qmsg working tree; default: immutable manifest pin")
    quic = parser.add_mutually_exclusive_group()
    quic.add_argument("--quic-path", type=Path, help="explicit QUIC working tree for selected mode")
    quic.add_argument("--quic-archive", type=Path, help="local QUIC candidate tarball for selected mode")
    integrity = parser.add_mutually_exclusive_group()
    integrity.add_argument("--quic-hash", help="verify the archive's Zig package content hash")
    integrity.add_argument("--quic-sha256", help="verify the exact archive SHA-256 instead of recomputing the Zig package hash")
    parser.add_argument("--mode", choices=("both", "released", "selected"), default="both")
    parser.add_argument("--optimize", choices=("Debug", "ReleaseSafe"), default="Debug")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--core", action="store_true", help="also run qmesh's full suite and binary build")
    parser.add_argument("--sprint2", action="store_true", help="also test public QuicSocket traffic with deadline-driven mesh runners")
    parser.add_argument("--sprint3", action="store_true", help="also test reliable publication and missed-announcement snapshot recovery")
    parser.add_argument("--sprint4", action="store_true", help="also test public messaging faults and seeded multi-node recovery")
    parser.add_argument("--output-dir", type=Path, help="new evidence directory (default: .zig-cache/composition/<UTC time>)")
    args = parser.parse_args()
    if bool(args.quic_archive) != bool(args.quic_hash or args.quic_sha256):
        parser.error("--quic-archive requires exactly one of --quic-hash or --quic-sha256")
    if args.quic_sha256 and not re.fullmatch(r"[a-fA-F0-9]{64}", args.quic_sha256):
        parser.error("--quic-sha256 must contain 64 hexadecimal digits")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.mode == "released" and (args.quic_path or args.quic_archive):
        parser.error("a selected QUIC source has no effect in --mode released")
    for name in ("qmsg_path", "quic_path"):
        path = getattr(args, name)
        if path and not (path.resolve() / "build.zig.zon").is_file():
            parser.error(f"--{name.replace('_', '-')} must contain build.zig.zon")

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = (args.output_dir or ROOT / ".zig-cache/composition" / stamp).resolve()
    output.mkdir(parents=True, exist_ok=False)
    stage = output / "workspace/tests/composition"
    stage.mkdir(parents=True)
    package_dir = ROOT / "zig-pkg"
    package_dir.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["ZIG_LOCAL_PKG_DIR"] = str(package_dir)
    env["COPYFILE_DISABLE"] = "1"
    zig = Path(shutil.which("zig") or "zig").resolve()
    report = {
        "started_utc": stamp,
        "host": capture(["uname", "-srm"]),
        "compiler": {"path": str(zig), "version": capture([str(zig), "version"]), "sha256": sha256(zig)},
        "optimize": args.optimize,
        "quic_options": {"target": "native", "release": args.optimize != "Debug", "sanitize-c": "trap"},
        "sources": {"qmesh": source_identity(ROOT, output)},
        "checks": [],
        "passed": False,
        "requested_inputs": {"mode": args.mode, "qmsg_path": str(args.qmsg_path) if args.qmsg_path else None,
                             "quic_path": str(args.quic_path) if args.quic_path else None,
                             "quic_archive": str(args.quic_archive) if args.quic_archive else None,
                             "quic_hash": args.quic_hash, "quic_sha256": args.quic_sha256,
                             "sprint2": args.sprint2, "sprint3": args.sprint3, "sprint4": args.sprint4},
    }
    def save_report():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def fail_setup(message):
        report["setup_error"] = message
        save_report()
        raise ValueError(message)

    save_report()
    (output / "zig-env.txt").write_text(capture([str(zig), "env"]) + "\n")
    base = (ROOT / "tests/composition/build.zig.zon").read_text()
    report["pinned_inputs"] = {name: dependency(base, name) for name in ("qmsg", "quic")}
    save_report()
    manifest = replace_dependency(base, "qmesh", ROOT, stage)
    if args.qmsg_path:
        manifest = replace_dependency(manifest, "qmsg", args.qmsg_path, stage)
        report["sources"]["qmsg"] = source_identity(args.qmsg_path)
    save_report()
    if args.quic_archive:
        archive = args.quic_archive.resolve(strict=True)
        archive_sha256 = sha256(archive)
        # Standalone Zig 0.17 URL/path fetches write a malformed recompressed
        # cache entry with an extra archive root. Isolate hash calculation;
        # normal build --fetch below populates the shared package cache.
        actual_hash = None
        if args.quic_sha256:
            if archive_sha256 != args.quic_sha256.lower():
                fail_setup(f"QUIC archive SHA-256 mismatch: expected {args.quic_sha256}, got {archive_sha256}")
            (output / "fetch-archive.log").write_text(f"Verified archive SHA-256: {archive_sha256}\n")
        else:
            with tempfile.TemporaryDirectory(prefix="qmesh-candidate-hash-") as isolated:
                hash_packages = str(Path(isolated) / "packages")
                hash_env = dict(env, ZIG_GLOBAL_CACHE_DIR=isolated, ZIG_LOCAL_PKG_DIR=hash_packages)
                try:
                    fetched = subprocess.run([str(zig), "fetch", "--pkg-dir", hash_packages, str(archive)],
                                             cwd=ROOT, env=hash_env, text=True, capture_output=True, timeout=180)
                except subprocess.TimeoutExpired:
                    (output / "fetch-archive.log").write_text("Zig package-hash verification timed out after 180 seconds.\n")
                    fail_setup("Zig package-hash verification timed out after 180 seconds")
            (output / "fetch-archive.log").write_text(fetched.stdout + fetched.stderr)
            fetched.check_returncode()
            actual_hash = fetched.stdout.strip().splitlines()[-1]
            if actual_hash != args.quic_hash:
                fail_setup(f"QUIC archive package hash mismatch: expected {args.quic_hash}, got {actual_hash}")
        args.quic_path = output / "candidate-quic"
        extract_source(archive, args.quic_path)
        report["candidate_archive"] = {"path": str(archive), "sha256": archive_sha256, "package_hash": actual_hash,
                                       "verified_by": "sha256" if args.quic_sha256 else "zig-package-hash"}
    if args.quic_path:
        manifest = replace_dependency(manifest, "quic", args.quic_path, stage)
        report["sources"]["quic"] = source_identity(args.quic_path)
    (stage / "build.zig.zon").write_text(manifest)
    shutil.copy2(ROOT / "tests/composition/build.zig", stage / "build.zig")
    shutil.copy2(ROOT / "tests/composition_test.zig", stage.parent / "composition_test.zig")
    for filename in ("sprint2_composition_test.zig", "sprint3_composition_test.zig", "sprint4_composition_test.zig"):
        public_test = ROOT / "tests" / filename
        if public_test.is_file():
            shutil.copy2(public_test, stage.parent / public_test.name)
    shutil.copytree(ROOT / "tests/data", stage.parent / "data")
    report["composition_manifest_sha256"] = sha256(stage / "build.zig.zon")
    save_report()
    fetch_command = [str(zig), "build", "--fetch"]
    with (output / "fetch-dependencies.log").open("w") as log:
        fetched = subprocess.run(fetch_command, cwd=stage, env=env, stdout=log, stderr=subprocess.STDOUT)
    report["setup"] = {"command": fetch_command, "returncode": fetched.returncode, "log": "fetch-dependencies.log"}
    save_report()
    if fetched.returncode:
        print((output / "fetch-dependencies.log").read_text(), file=sys.stderr)
        return fetched.returncode
    for name in ("qmsg", "quic"):
        expected_hash = re.search(r'\.hash\s*=\s*"([^"]+)"', dependency(base, name)).group(1)
        cached = package_dir / expected_hash
        if cached.is_dir():
            report["sources"][name + "_pinned"] = source_identity(cached)
            report["sources"][name + "_pinned"]["package_hash"] = expected_hash
    native_pin = report["sources"]["qmesh"]["dependency_pins"]["quic"]
    native_source = package_dir / native_pin["hash"]
    if native_source.is_dir():
        report["sources"]["quic_native_released"] = source_identity(native_source)
        report["sources"]["quic_native_released"]["package_hash"] = native_pin["hash"]
    report["mode_sources"] = {
        "released": "Each upper library's native QUIC URL/hash pin; type-identity assertion must pass",
        "selected": "Explicit QUIC working tree/archive, or composition package's pinned QUIC input",
    }
    save_report()

    def check(name, cwd, step, extra=()):
        cache = output / "build-cache" / ("qmesh" if cwd == ROOT else "composition")
        command = [str(zig), "build", *step, f"-Doptimize={args.optimize}", f"-j{args.jobs}",
                   "--cache-dir", str(cache), "--summary", "all", *extra]
        print(f"[{name}] {' '.join(command)}", flush=True)
        start = time.monotonic()
        log = output / (name + ".log")
        with log.open("w") as stream:
            result = subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        contents = log.read_text()
        summaries = re.findall(r"^Build Summary:.*$", contents, re.M)
        item = {"name": name, "cwd": str(cwd), "command": command, "returncode": result.returncode,
                "elapsed_seconds": round(time.monotonic() - start, 3), "summary": summaries[-1] if summaries else None,
                "log": log.name}
        report["checks"].append(item)
        save_report()
        print(f"[{name}] exit={result.returncode} {item['summary'] or 'no build summary'}; {log}", flush=True)
        if result.returncode:
            print("\n".join(contents.splitlines()[-50:]), file=sys.stderr, flush=True)
        return result.returncode == 0

    passed = True
    if args.core:
        passed = check("qmesh-test", ROOT, ["test"]) and passed
        passed = check("qmesh-build", ROOT, []) and passed
    modes = ("released", "selected") if args.mode == "both" else (args.mode,)
    for mode in modes:
        extra = ["-Dlocal-quic=" + ("false" if mode == "released" else "true")]
        passed = check(mode + "-composition", stage, ["test"], extra) and passed
        if args.sprint2:
            passed = check(mode + "-sprint2", stage, ["test-sprint2"], extra) and passed
        if args.sprint3:
            passed = check(mode + "-sprint3", stage, ["test-sprint3"], extra) and passed
        if args.sprint4:
            passed = check(mode + "-sprint4", stage, ["test-sprint4"], extra) and passed
        passed = check(mode + "-qmsg", stage, ["test-qmsg"], extra) and passed
    report["passed"] = passed
    report["final_sources"] = {"qmesh": source_identity(ROOT, output)}
    if args.qmsg_path:
        report["final_sources"]["qmsg"] = source_identity(args.qmsg_path)
    if args.quic_path:
        report["final_sources"]["quic"] = source_identity(args.quic_path)
    report["sources_unchanged"] = all(
        identity == report["sources"][name] for name, identity in report["final_sources"].items()
    )
    report["passed"] = passed and report["sources_unchanged"]
    report["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Evidence: {output / 'report.json'}", flush=True)
    if not report["sources_unchanged"]:
        print("Source files changed during the run; repeat the verification on settled inputs.", file=sys.stderr)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
