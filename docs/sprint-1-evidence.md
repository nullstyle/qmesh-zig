# Sprint 1 composition evidence — 2026-10-26

This sprint adds reproducible composition checks and integrates qmsg's bounded
GOAWAY lifecycle with the optional `qmesh_messaging` pool. qmesh's public
version and QUIC v0.37.2 pin are unchanged. Runner and discovery changes are
outside this sprint.

## Inputs and repeatable commands

The toolchain is tagged Zig 0.17.0, selected by mise. The composition consumer
pins qmsg commit `1e6960465c1af8f2cfdb8675b01fb00fbea38326` with package hash
`qmsg-0.8.5-g3pJMT1MFQBr6yT5WNY9vEFF-JC3k_FSapLit3BAgi_5`. Its native QUIC
dependency and qmesh's are v0.37.2, package
`quic-0.37.2-DnSYvb2bPwDUgMMPDFV3tX0CgvsCbn2u2ed60n4tUtZ-`.

The consumer's injected-source default is QUIC v0.42.2, package
`quic-0.42.2-DnSYvVJRZQDaf9LFsqj9k1cFzPeYCNwb3HgKBDn8s07g`. Both transport
versions pin BoringSSL commit `ff30fe9953b07f838d7ac09ace84dacfb1e896ca`, package
`boringssl-0.6.7-Vv5DN8RMAgDGST3F3NpoMjez8Z_J60megIom9Ru9XqD2`.
The shared QUIC option map is `{target=native, release=(optimize!=Debug),
sanitize-c="trap"}`. Composition tests assert identical `quic.Connection`
types; QUIC/paseto imports for the qmsg test roots reuse that selected module.

```sh
mise run check-sprint1
mise exec -- python3 tools/check-composition.py --core --optimize Debug \
  --qmsg-path ../qmsg --quic-path ../quic-zig --jobs 2
```

Use `--quic-archive /absolute/path/candidate.tar.gz --quic-hash '<Zig package hash>'`
in place of `--quic-path` for an unpublished archive. Alternatively supply
`--quic-sha256 '<archive SHA-256>'` to verify exact archive bytes directly.
The wrapper verifies the selected content identity before extraction. Normal
dependency fetching uses `zig build --fetch`: standalone Zig 0.17 fetches
recompress archives with an extra root, which can poison a later build's
package cache. Evidence captures compiler binary identity, actual dirty-source
digests, native/injected transport and crypto pins, commands, logs, counts, and
an initial/final source identity comparison. Each run has fresh local build
caches, so passing cached tests cannot hide the execution count.

`test-qmsg` covers all three qmsg test roots: module, QUIC runtime, and
independent Node UDP. The latter is necessary to test the newer transport's
ConnectionDriver path with real PING/GOAWAY traffic. These are test executions
across roots, not a claim of unique test cases.
Both native QUIC v0.37.2 and the selected v0.42.2 candidate expose and use
`ConnectionDriver`. These lanes do not qualify the legacy raw fallback.

## Reproduced defect

With an unchanged endpoint, correct certificate, and an owned session reporting
`.closing`, routine pool service immediately called `closeQuicSession`.
That aborted qmsg's grace interval. The deterministic command

```sh
mise exec -- zig test --test-filter 'protocol drains' --dep qmesh \
  -Mroot=src/composition/root.zig -Mqmesh=src/root.zig
```

failed before the fix with `expected 0, found 1` at `dialer.closes`. It passes
after retaining the session as non-routable until qmsg removes it. The pool
does not schedule a dial-timeout wakeup for the drain; qmsg owns its bounded
deadline. Normal retry resumes after removal. Explicit pool ownership actions
(forget, endpoint replacement, membership removal, idle eviction) still close
owned sessions. The live composition scenario also checks GOAWAY retirement,
preserved session status, and a successful exchange on the replacement route
when built against the newer qmsg source.

## Baseline before the close-contract change

Local host: ARM64 macOS. The first qmesh Debug run executed 127/127 tests,
25/25 steps; build 14/14 steps. Pinned composition Debug and ReleaseSafe both
passed 2/2 integration tests and 316/316 module test executions against each
of native QUIC v0.37.2 and injected v0.42.2. Fresh ReleaseSafe qmesh execution
passed 127/127 tests and build 14/14. Those baseline module checks preceded
the expansion to the separate qmsg runtime/pair roots.

The initial wrapper setup failure is retained at
`.zig-cache/sprint1-baseline-debug/report.json`: it exposed invalid absolute
Zig dependency paths and the standalone-fetch cache issue. Subsequent staged
manifests use paths relative to their build root.

## Final verification

The final v4 consumer matrix includes qmsg's per-peer control-sender
error-containment repair, including accepted and owned connection cases where
a reset PONG send half must not abort progress for another peer on the Node.
The preceding v3 records remain historical proof for source
`0e8d5873e4c7f7dc03ba4403566cb08b7c4cee599eb741e8e9051c75a4265721`
(853 qmsg test executions per lane), retained under
`../evidence/sprint-1-2026-10-26/pre-containment-v3/`.
The qmesh core and pinned-source CI inputs are unchanged and their prior
passing results are reused.

All following local gates passed on ARM64 macOS with Zig 0.17.0 binary SHA-256
`1c5f706db0ed6d55451940f31dc05a6177d05696bc1fa5d853696d04c718b523`.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| Full qmesh suite after the pool repair | 128/128 tests; 25/25 steps | 128/128 tests; 25/25 steps |
| Native v0.37.2 composition, current qmsg | 2/2 tests; 11/11 steps | 2/2 tests; 11/11 steps |
| Native v0.37.2, all three current qmsg roots | 854/854 tests; 15/15 steps | 854/854 tests; 15/15 steps |
| Repaired QUIC archive composition, current qmsg | 2/2 tests; 11/11 steps | 2/2 tests; 11/11 steps |
| Repaired archive, all three current qmsg roots | 854/854 tests; 15/15 steps | 854/854 tests; 15/15 steps |

The qmsg roots account for 323 module, 187 runtime, and 344 Node-pair test
executions per transport/mode. Every v4 consumer lane executed all 854 qmsg
tests and both composition tests with zero cached test runs and zero skipped
tests. Optional Cap'n Proto codec tests are outside
this consumer's default features. The independent pinned-source CI-default
selected lane also passed locally in Debug: composition 2/2 and the older
immutable qmsg's three roots 830/830, with no sibling qmsg/quic inputs.

The final qmsg working-tree source identity is
`2f17a5c0ea3864b36292fc744c866be50ac45859745e12370c459080d4e32c5f`
(67 files; HEAD `1e6960465c1af8f2cfdb8675b01fb00fbea38326` plus the uncommitted
lifecycle work). It matches the qmsg producer's final identity. Both final
mode reports assert unchanged initial/final qmsg, qmesh and selected-QUIC
source digests.

The selected local artifact is
`../quic-zig/benchmark-reports/sprint-1-2026-10-26/candidate/quic-zig-sprint-1.tar.gz`,
SHA-256 `d5363946e9bbb5a7a0042cb17c29b8f2ed6b33e019ebe2659e8f60823926da53`.
It contains `b0d7d78` plus the SendStream capacity-underflow repair. The
extracted source digest in these reports is
`39bf98abe6de4e3ac57396ea70ec80f49814870e93897990ad3708be3e93eafe`.
The producer's Zig package identifier is
`quic-0.42.2-DnSYvRosaAAz3R7QCdwmgtF2GYdyZm9CAzjwPcr4z50X`; final gates
verified exact archive SHA-256 rather than claiming a completed package
rehash gate. A separate isolated Zig rehash attempt timed out after 120s;
its evidence is retained. The missing/ambiguous-verifier and wrong-SHA checks
reject before compilation.

To repeat the final consumer gates against those explicit local sources:

```sh
for mode in Debug ReleaseSafe; do
  mise exec -- python3 tools/check-composition.py --optimize "$mode" --jobs 2 \
    --qmsg-path ../qmsg \
    --quic-archive ../quic-zig/benchmark-reports/sprint-1-2026-10-26/candidate/quic-zig-sprint-1.tar.gz \
    --quic-sha256 d5363946e9bbb5a7a0042cb17c29b8f2ed6b33e019ebe2659e8f60823926da53
done
```

Raw reports and logs are retained outside the consumer archive paths under
[`../evidence/sprint-1-2026-10-26/`](../evidence/sprint-1-2026-10-26/):
[core](../evidence/sprint-1-2026-10-26/core/report.json),
[Debug composition](../evidence/sprint-1-2026-10-26/debug/report.json),
[ReleaseSafe composition](../evidence/sprint-1-2026-10-26/release-safe/report.json),
[pinned-source Debug](../evidence/sprint-1-2026-10-26/pinned-selected-debug/report.json),
the [final count/source index](../evidence/sprint-1-2026-10-26/final-verification.json),
and [setup/guard evidence](../evidence/sprint-1-2026-10-26/setup-evidence/).
Those reports identify the working tree tested before this final evidence
write; production/test source files did not change afterward. The interrupted
v1/v2 consumer captures remain marked aborted in `.zig-cache`; they are not
counted as final validation.

Hosted Linux/macOS CI has been configured in
`.github/workflows/composition.yml`; it has not been run or claimed green.
The candidate remains local. No public package pin/version, tag, commit,
push or publication was made by this sprint.
