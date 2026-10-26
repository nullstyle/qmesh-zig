# Snapshot recovery after missed announcements

`examples/snapshot_recovery.zig` is a bounded, single-authority application
example. Mesh announcements contain a revision hint. A periodic request for a
complete application snapshot repairs a replica even when it receives no hint.
The `qmesh` core remains independent of `qmsg`; the example composes the public
`qmesh_messaging.Pool` and `qmsg.QuicSocket(.req/.rep)` modules.

The configured resolver maps the authority's authenticated mesh identity to a
separate application endpoint. It does not infer an application port from the
mesh port. The pool admits one demanded peer and verifies the expected server
certificate SPKI. Both socket roles use certificate-bound mutual TLS and the
same public localhost sample identities as the mesh.

## Scenario and limits

The default run first establishes real UDP mesh membership and a ready request
session. It then drops all mesh datagrams through the runners' local fault
knobs and stops pumping the snapshot server for 500 ms. The requester continues
to advance, so a real public request reaches its 50 ms deadline. These are local
fault controls, not a claim about a physical network partition.

During the outage, the authority makes 40 updates and publishes their revision
hints, then publishes 40 unrelated announcements. Each ephemeral send drains
through the local blackhole. Before healing, the example checks that none of
the 40 hint IDs remains in the actual 32-entry payload cache. The separate
256-entry seen-ID cache does not imply that payloads remain repairable.

After both local paths resume, the authority publishes no new revision hint.
The requester probes every 100 ms independently of announcements, retrieves an
81-byte snapshot, and verifies complete state equality at revision 40. The
hypothetical gossip-only replica remains at revision zero. Any useful hint
arriving after the outage makes the scenario fail, so queued or fresh hints
cannot make its recovery gate pass.

Application state is eight `u64` values and one revision. The fixed binary
schema includes an eight-byte version marker and a value count. Decoding
rejects short/long, unsupported-version and wrong-shape snapshots before
mutation. Applying a stale or duplicate revision fails without changing state.
This example assumes one authority; a multi-writer application needs its own
conflict policy and durable storage.

Memory and work are bounded explicitly:

- One pool entry and one request reservation, including terminal outcomes.
- Two messaging sessions per socket, 16 events and 4 KiB of event bytes.
- At most eight queued transport messages and 8 KiB per transport.
- A fixed 128-entry terminal-outcome ledger and at most 120 attempts.
- Default total runtime limit of eight seconds; validated options cap it at 30.

Every canonical event is released once. A timed-out request is consumed once;
the example never replies to a superseded request after the pause. The pool,
sockets and runners each have one owner. The owner waits on borrowed socket
handles and the minimum mesh, request/lifecycle, pool and application deadline.
The paused service contributes neither a readable socket nor an overdue timer.

The included `examples/recovery-pki/` keys are public localhost test material.
Never use them for deployed identities.

## Reproduction

The transport-free gate uses deterministic virtual time and the same state
schema. It partitions the simulator, expires every useful payload, heals for
80 virtual seconds with no new hint, proves the gossip-only state is stale,
and models the periodic snapshot response. Repeating its seed yields the same
world fingerprint. The separate public UDP example exercises the actual qmsg
request timeout and recovery path.

```sh
mise exec -- zig build recovery-test -j2 --summary all
mise exec -- zig build test -j2 --summary all
mise exec -- zig build test -Doptimize=ReleaseSafe -j2 --summary all
```

The root-owned composition workspace provides `run-recovery`, `install-workloads`
and `test-sprint3`. It selects one exact messaging and transport module map;
see [sprint-3-composition.md](sprint-3-composition.md) for the isolated consumer
commands and final source-identified matrix. `runScenario(allocator, io, options)`
returns the bounded report used by that gate and by transport profiling.
Raw local evidence is retained under `.zig-cache/sprint-3-evidence/`; results
are recorded below after qualification. Hosted CI and physical network behavior
are separate from these local tests.

## Local qualification — 2026-10-26

The full core suite contains **142 tests**, including three fixed-schema tests
and one deterministic recovery scenario. Both native ARM64 platforms passed
Debug and ReleaseSafe with zero failed or skipped tests:

| Host | Mode | Steps | Executed | Cached tests |
| --- | --- | --- | ---: | ---: |
| macOS ARM64 | Debug | 31/31 | 18 | 124 |
| macOS ARM64 | ReleaseSafe | 31/31 | 32 | 110 |
| Linux ARM64 | Debug | 31/31 | 142 | 0 |
| Linux ARM64 | ReleaseSafe | 31/31 | 142 | 0 |

Mac uses stock mise Zig 0.17.0, compiler SHA-256
`1c5f706db0ed6d55451940f31dc05a6177d05696bc1fa5d853696d04c718b523`.
Linux uses the cached `quic-zig-sprint1-builder:local` image
`sha256:97711185ccd951b04ca293caa83c7b88832ef61c0422439ae82903b7a1f6f969`,
stock `/opt/zig/zig` 0.17.0, compiler SHA-256
`5165c9a2d17938a8173839b3adf81d025b558d38d9e9711237a6fa5b8d8bb3f7`,
on native Linux ARM64 under OrbStack. The container entrypoint was explicitly
replaced with `sh`; the producer checkout was mounted read-only and caches/logs
were written under a separate ignored evidence mount. All compiles used `-j2`.
The first Linux invocation used a removed build flag and failed setup; that
infrastructure attempt remains recorded separately from the corrected gates.

The native released-transport ReleaseSafe CLI also passed the public UDP
scenario: revision 40 equals revision 40, gossip-only revision zero, 40 hints
expired, zero late hints, six attempts, five deadline failures, one 81-byte
snapshot, and peak request/pool counts of one. Its observed total runtime was
510343 microseconds, including the intentional 500 ms outage. This is a
functional workload result, not a performance comparison.

A correct quiet owner loop (immediate repump after local work) exposed an
intermittent `pollDatagram` rest-shortcut assertion in Debug with the immutable
QUIC v0.37.2 dependency and the initial selected source. The early Debug run
that parked after queued work is historical evidence, not a passing final
qualification of that corrected loop. Red logs and exact frozen sources were
retained for the transport regression. The composition guide records the
selected transport's final repair/matrix separately; native released Debug
must not be represented as passing that gate without new evidence.

Raw producer logs and their index are in `.zig-cache/sprint-3-evidence/`:
`core-debug.log`, `core-safe.log`, `pure-debug-v2.log`, `pure-safe-v2.log`,
`linux-debug-v2.log`, `linux-safe-v2.log`, `recovery-dev-safe.log`, and
`recovery-dev-debug-v2.log`. The final source-stable composition evidence is
owned by [sprint-3-composition.md](sprint-3-composition.md).
