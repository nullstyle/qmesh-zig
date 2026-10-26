#!/usr/bin/env python3
"""Bounded local qualification runner; every command gets durable raw evidence."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("name")
parser.add_argument("--cwd", type=Path)
parser.add_argument("--timeout", type=int, default=2700)
parser.add_argument("--baseline", action="store_true")
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ["--"] else args.command
root = Path(__file__).resolve().parents[2]
evidence = Path(__file__).resolve().parent
cwd = (args.cwd or root).resolve()
initial = json.loads((evidence / "initial-candidate-manifest.json").read_text())
runtime_files = initial["runtime_build_sources"]["files"]
actual = (json.loads((evidence / "released-control-manifest.json").read_text())
          if args.baseline else initial)
linux = args.name.startswith("linux-") and "docker" in command
input_root = (evidence / ("linux-fuzz-source" if args.name.startswith("linux-fuzz")
                          else "linux-source")) if linux else (cwd if args.baseline else root)


def runtime_unchanged():
    return (all(hashlib.sha256((root / name).read_bytes()).hexdigest() == sha
                for name, sha in runtime_files.items()) and
            all(hashlib.sha256((input_root / name).read_bytes()).hexdigest() == sha
                for name, sha in actual["runtime_build_sources"]["files"].items()))


assert runtime_unchanged(), "candidate runtime changed before gate"
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
env = dict(os.environ, COPYFILE_DISABLE="1")
env["PATH"] = str(evidence / "tools-bin") + os.pathsep + env["PATH"]
log = evidence / (args.name + ".log")
record = {"name": args.name, "started_utc": started, "cwd": str(cwd),
          "command": command, "timeout_seconds": args.timeout,
          "host": platform.platform(), "compiler": initial["compiler"],
          "source_commit": actual["source"]["commit"],
          "runtime_build_tree_sha256": actual["runtime_build_sources"]["tree_sha256"],
          "log": log.name, "passed": False}
record["candidate_input_directory"] = str(input_root)
if linux:
    record["orchestrator_compiler"] = record["compiler"]
    record["compiler"] = {"path": "/opt/zig/zig", "version": "0.17.0",
                          "sha256": initial["linux_builder_image"]["compiler_sha256"]}
    record["execution_platform"] = "Linux arm64 container on OrbStack"
print("GATE_START " + args.name, flush=True)
start = time.monotonic()
with log.open("wb") as output:
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=output,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        exit_code = process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        exit_code = 124
        record["timed_out"] = True
record.update(finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              elapsed_seconds=time.monotonic() - start, exit_code=exit_code,
              runtime_unchanged=runtime_unchanged())
contents = log.read_bytes()
record["log_sha256"] = hashlib.sha256(contents).hexdigest()
record["build_summaries"] = re.findall(r"Build Summary:.*", contents.decode(errors="replace"))
record["passed"] = exit_code == 0 and record["runtime_unchanged"]
(evidence / (args.name + ".json")).write_text(json.dumps(record, indent=2) + "\n")
print("GATE_RESULT " + json.dumps(record), flush=True)
raise SystemExit(0 if record["passed"] else 1)
