#!/usr/bin/env python3
"""Finalize local producer evidence without changing the frozen source."""
from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import subprocess

root = Path(__file__).resolve().parents[2]
p = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("checker", "/Users/nullstyle/prj/zig/qmesh-zig/tools/check-composition.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
initial = json.loads((p / "initial-candidate-manifest.json").read_text())
manifest_path = p / "final-candidate-manifest.json"
m = json.loads(manifest_path.read_text())
assert h.source_identity(root) == m["source"]
assert h.sha256(Path(m["archive"]["path"])) == m["archive"]["sha256"]
for name, sha in m["all_file_sha256"].items():
    assert h.sha256(p / "package-source" / name) == sha
required = ["mac-debug", "mac-release-safe", "mac-sanitize-full", "mac-build-examples",
            "mac-echo-smoke", "mac-goodput-smoke", "mac-consumer-debug", "mac-consumer-safe",
            "mac-consumer-modes", "mac-cross-windows", "mac-cross-x86", "linux-debug",
            "linux-release-safe", "linux-sanitize-full", "linux-fuzz-50000",
            "linux-examples-udp-consumer", "qns-image-build", "interop-client", "interop-server",
            "fairness-current", "fairness-released", "mac-pins-format",
            "package-consumer-debug", "package-consumer-safe", "package-consumer-modes"]
gates = []
for name in required:
    path = p / (name + ".json")
    gate = json.loads(path.read_text())
    assert gate["passed"] and gate["exit_code"] == 0 and gate["runtime_unchanged"], name
    assert h.sha256(p / gate["log"]) == gate["log_sha256"], name
    gate["record_sha256"] = h.sha256(path)
    gate["record_path"] = str(path)
    gate["input_source_manifest"] = "released-control-manifest.json" if name == "fairness-released" else "initial-candidate-manifest.json"
    gate["input_source_manifest_sha256"] = h.sha256(p / gate["input_source_manifest"])
    if name.startswith("package-consumer"):
        gate["candidate_input_directory"] = str(p / "package-source")
        gate["input_source_manifest"] = "final frozen source and verified extracted archive"
    if name in ("mac-debug", "mac-release-safe"):
        gate["execution_note"] = "Entire graph reused cached successful results after exact runtime/build identity verification; Mac full-C-sanitizer execution is separately fresh."
    if name in ("mac-cross-windows", "mac-cross-x86"):
        gate["execution_note"] = "Compile-only; expected foreign-binary execution errors are accepted by the existing recipe. No native Windows or x86-Linux test execution."
    gates.append(gate)
for family in ("boringssl", "boringssl-upstream"):
    a = json.loads((p / (family + "-host-identity.json")).read_text())
    b = json.loads((p / (family + "-linux-identity.json")).read_text())
    assert a["tree_sha256"] == b["tree_sha256"] and a["file_count"] == b["file_count"]
m.update(finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
         branch=subprocess.check_output(["git", "branch", "--show-current"], cwd=root, text=True).strip(),
         local_qualification_complete=True, required_gate_count=len(gates), gates=gates,
         initial_input_manifest_sha256=h.sha256(p / "initial-candidate-manifest.json"),
         fuzz=json.loads((p / "fuzz-evidence.json").read_text()),
         interop=json.loads((p / "interop-evidence.json").read_text()),
         fairness=json.loads((p / "fairness-assessment.json").read_text()),
         dependencies={name: json.loads((p / (name + "-identity.json")).read_text())
                       for name in ("boringssl-host", "boringssl-linux", "boringssl-upstream-host", "boringssl-upstream-linux")},
         package_consumer_proof={"archive_sha256_verified": True, "all_extracted_files_equal_frozen_source": True,
                                 "debug_and_release_safe_executed": True, "all_six_mode_guards_passed": True,
                                 "canonical_zig_package_hash_verified": False, "public_url_fetch_verified": False,
                                 "limit": "Standalone Zig package rehash has a retained earlier hang; it was not rerun or repaired. This SHA/local archive/path-consumer proof is distinct from a canonical package hash or public URL fetch."},
         negative_control={"scope": "Released downstream QUIC0.37.2 inherited idle-cache defect; retained from Sprint3, not rerun or altered in Sprint4",
                           "binary_sha256": "e979038598010e7ad05877ad7c6c70e4c5c40f7acb5d23366eb1ea4e877952dc",
                           "report": str(root / "benchmark-reports/sprint-3-2026-10-26/recovery-repro/native-red.json")},
         limits=["Inherited mixed-fairness promotion review remains held despite all existing automated qualification gates passing.",
                 "Mac native execution, Linux arm64 containers, foreign-target compilation, and Docker QNS interop are separate evidence.",
                 "Native Windows, native Linux x86-64, hosted tier-1 CI and physical-network performance are not established here.",
                 "Canonical Zig package-hash verification and public URL fetching are not completed; no release, push, tag, version or pin move was performed.",
                 "The parent owns the final coordinated qmsg/qmesh composition checkpoint; producer gates alone do not establish that checkpoint."],
         preparation_findings=[{"file": "released-control-preparation-initial-failure.json", "scope": "System Python preparation failure, corrected using mise Python3.12; no runtime test executed in that failed attempt."}],
         evidence_helpers={name: h.sha256(p / name) for name in ("run-gate.py", "make-package.py", "hash-source.py", "finalize-evidence.py")})
assert m["fairness"]["all_six_match_prior_candidate_observations"]
assert m["interop"]["all_four_cells_passed"]
assert m["fuzz"]["runtime_source_files_match"]
manifest_path.write_text(json.dumps(m, indent=2) + "\n")
summary = {"schema_version": 1, "local_qualification_complete": True,
           "source": m["source"], "archive": m["archive"],
           "runtime_build_tree_sha256": m["runtime_build_sources"]["tree_sha256"],
           "manifest": str(manifest_path), "manifest_sha256": h.sha256(manifest_path),
           "required_gates_passed": len(gates), "promotion_ready": False,
           "promotion_hold": m["promotion_hold"], "limits": m["limits"]}
(p / "index.json").write_text(json.dumps(summary, indent=2) + "\n")
assert h.source_identity(root) == m["source"]
print(json.dumps(summary, indent=2))
