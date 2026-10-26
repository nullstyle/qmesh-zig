# Sprint 2 public application composition

Sprint 1 was committed locally before this work began:

| Repository | Sprint 1 commit |
| --- | --- |
| quic-zig | `33f5161becb6f66c7bc475d22d86a447f9281224` |
| qmsg | `6bdcf69732d1101b9c91c9271674b0416772a6ff` |
| qmesh-zig | `128c8dcbd5f69310f71e099fffa64e1785ec2129` |

Sprint 2 keeps public dependency pins unchanged. qmsg's new owned sockets and
qmesh's deadline-driven runner are tested together through an opt-in consumer
target; the immutable default qmsg pin predates that facade.

## Public stack scenario

`tests/sprint2_composition_test.zig` starts two real `Runner.run()` threads.
Each thread alone reads its own membership table and signals discovery through
an atomic flag. A shared atomic shutdown flag is joined before runners are
destroyed. This exercises the actual blocking deadline loop, while the original
nonblocking-step composition scenarios remain covered separately.

The application thread uses only `QuicSocket(.req/.rep)` public methods:

- TLS-configured listen/dial and actual bound address lookup;
- expected certificate SPKI identity matching the discovered mesh member;
- one owner clock from `Runner.clockUs`, canonical events, and borrowed UDP
  handles combined with request/transport/lifecycle deadlines;
- six concurrent requests over a two-stream window, bounded by a 64 KiB queue
  and 4 KiB maximum message reservation;
- a retained reply handle answered after GOAWAY, refusal of new work during
  drain, and exactly one reply for each accepted request;
- a quiet-iteration wait policy: queued mutations are pumped again before
  parking, and locally produced events are consumed before sleeping.

The application address comes from explicit configuration, not an assumed
relationship to the gossip port or an endpoint-advertisement protocol. The
fixture verifies mutual TLS/certificate identity; qmsg's own public tests cover
minimal authorization grants and denied roles/subjects.

## Reproduce

From the qmesh root, select the coordinated working trees:

```sh
mise exec -- python3 tools/check-composition.py --sprint2 --optimize Debug \
  --qmsg-path ../qmsg --quic-path ../quic-zig --jobs 2
mise exec -- python3 tools/check-composition.py --sprint2 --optimize ReleaseSafe \
  --qmsg-path ../qmsg --quic-path ../quic-zig --jobs 2
```

Each run tests the upper libraries' native QUIC v0.37.2 pins and one injected
QUIC module. An immutable local candidate can be selected instead:

```sh
mise exec -- python3 tools/check-composition.py --sprint2 --optimize ReleaseSafe \
  --qmsg-path ../qmsg --quic-archive /absolute/path/quic-zig-sprint-2.tar.gz \
  --quic-sha256 '<trusted archive SHA-256>' --jobs 2
```

The opt-in `test-sprint2` target runs beside the original composition tests and
all three qmsg test roots. The default checker/CI retains its pinned-source
behavior without requiring the new facade. Existing count, source-identity,
module-identity, configuration, and archive-integrity checks remain active.

Final native reports and their exact inputs are retained separately under
`evidence/sprint-2-2026-10-26/`; the verification index references both modes,
consumer-native versus selected QUIC, and any additional Linux execution.
Producer reports distinguish freshly executed tests from unchanged cached
targets. Evidence copies after a gate do not change its compiled implementation.

The QUIC Sprint 2 pressure/ownership checks add tests and documentation; its
packaged Zig/build sources match Sprint 1. This qualification makes no hosted
CI, native Windows, physical-network performance, or release-promotion claim.
The inherited QUIC fairness promotion hold remains separate from these local
application and runner checks.
