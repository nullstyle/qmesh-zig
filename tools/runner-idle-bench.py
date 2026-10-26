#!/usr/bin/env python3
"""Measure one idle qmesh-node with no peers, mDNS, or publication."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import socket
import subprocess
import time


ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class DarwinUsage(ctypes.Structure):
    # macOS SDK sys/resource.h, rusage_info_v0 (proc_pid_rusage flavor 0).
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_time", "system_time", "package_idle_wakeups", "interrupt_wakeups",
            "pageins", "wired_size", "resident_size", "physical_footprint",
            "process_start", "process_exit",
        )
    ]


def darwin_wakeups(pid):
    if platform.system() != "Darwin":
        return None
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    value = DarwinUsage()
    if library.proc_pid_rusage(pid, 0, ctypes.byref(value)) != 0:
        raise OSError(ctypes.get_errno(), "proc_pid_rusage")
    return {"interrupt": value.interrupt_wakeups, "package_idle": value.package_idle_wakeups}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument("--samples", type=int, default=3)
    args = parser.parse_args()
    if args.seconds <= 0 or args.samples <= 0:
        parser.error("positive --seconds and --samples are required")
    binary = args.binary.resolve(strict=True)
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "runtime_sources": {str(path): digest(ROOT / path) for path in (
            Path("src/quic/loop.zig"), Path("src/quic/main.zig"), Path("src/quic/discovery.zig"),
        )},
        "binary_path": str(binary), "binary_sha256": digest(binary),
        "host": platform.platform(), "duration_seconds": args.seconds,
        "workload": "one idle node, no peers, no mDNS, no publication, metrics interval 3600s",
        "cpu_scope": "whole process lifetime including startup/shutdown; wakeups exclude 100ms warmup",
        "context_switch_scope": "whole process lifetime; voluntary context switches are a portable wait proxy",
        "samples": [],
    }
    env = {key: value for key, value in os.environ.items() if not key.startswith("QMESH_")}
    for index in range(args.samples):
        # The CLI requires a nonzero advertised port. Reserve a fresh local
        # port briefly; bind failure is reported, never counted as idle work.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        command = [str(binary), "--id", "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143",
                   "--bind", f"127.0.0.1:{port}", "--cert", "tests/data/node-a.pem",
                   "--key", "tests/data/node-a.key", "--ca", "tests/data/ca.pem",
                   "--metrics-secs", "3600"]
        log_path = output.with_name(f"{output.stem}-{index}.log")
        with log_path.open("w") as log:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                time.sleep(0.1)
                before = darwin_wakeups(process.pid)
                start = time.monotonic()
                time.sleep(args.seconds)
                after = darwin_wakeups(process.pid)
                elapsed = time.monotonic() - start
                signal_start = time.monotonic()
                # Popen.send_signal polls/reaps an already-exited child;
                # wait4 below owns reaping so the CPU accounting is retained.
                os.kill(process.pid, signal.SIGTERM)
                _, status, usage = os.wait4(process.pid, 0)
                process.returncode = os.waitstatus_to_exitcode(status)
                shutdown = time.monotonic() - signal_start
            except BaseException:
                try:
                    os.kill(process.pid, signal.SIGKILL)
                    os.waitpid(process.pid, 0)
                except ProcessLookupError:
                    pass
                process.returncode = 1
                raise
        if process.returncode != 0:
            raise RuntimeError(f"node exited {process.returncode}: {log_path.read_text()}")
        sample = {
            "command": command, "log": str(log_path), "exit_code": process.returncode,
            "measurement_seconds": elapsed, "shutdown_seconds": shutdown,
            "user_cpu_seconds": usage.ru_utime, "system_cpu_seconds": usage.ru_stime,
            "voluntary_context_switches": usage.ru_nvcsw,
            "involuntary_context_switches": usage.ru_nivcsw,
            "wakeups": {key: after[key] - before[key] for key in before} if before is not None else None,
        }
        report["samples"].append(sample)
        output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(sample), flush=True)


if __name__ == "__main__":
    main()
