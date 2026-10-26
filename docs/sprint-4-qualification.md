# Sprint 4: complete-stack qualification

Sprint 3 was committed locally before this work began:

| Repository | Sprint 3 commit |
| --- | --- |
| quic-zig | `43c2390557c47f48e6c28e07a31efdb2b6723478` |
| qmsg | `8510c90c6aad9dd0b22ca1ace953fc545e044491` |
| qmesh-zig | `2401ec63540e997aa373c750de642af80e03628d` |

The final sprint qualifies the existing application and transport interfaces:

- QUIC: exact-candidate platform, C sanitizer, fuzz, interoperability, package
  and consumer gates, plus maintained migration guidance and a fairness audit.
- qmsg: public-interface overload, authorization denial, request deadlines,
  cancellation, independent connection loss/reconnect and graceful draining.
- qmesh: seeded multi-node partitions, application restart, configured endpoint
  movement, membership transitions and snapshot reconciliation.

No publication, version or public dependency-pin change is part of this work.
The selected transport already contains Sprint 3's idle-cache repair. Released
v0.37.2 remains immutable and retains its recorded Debug recovery assertion.
The inherited main-only fairness promotion hold must be assessed separately;
passing application tests alone does not clear it.

## Public application checkpoint

The opt-in `test-sprint4` consumer composes reusable public fault and seeded
recovery workloads. The existing module-identity, pool/restart, explicit-pump,
reliable-publication and snapshot-retention cases remain in the checkpoint:

```sh
mise exec -- python3 tools/check-composition.py --sprint2 --sprint3 --sprint4 \
  --optimize Debug --qmsg-path ../qmsg --quic-path ../quic-zig --jobs 2
mise exec -- python3 tools/check-composition.py --sprint2 --sprint3 --sprint4 \
  --optimize ReleaseSafe --qmsg-path ../qmsg --quic-path ../quic-zig --jobs 2
```

An exact local candidate archive can replace `--quic-path` using
`--quic-archive <path> --quic-sha256 <trusted SHA256>`. All upper modules share
the established `{target, release, sanitize-c = "trap"}` option map and one
QUIC/BoringSSL module identity. The checker records commands, compiler and
source hashes, counts, failures, skips and before/after source identities.

Public request admission and terminal outcomes are distinct: rejected work
gets no request ID, accepted work receives exactly one retained completion,
and one unhealthy peer must not prevent a healthy peer from progressing.
Draining refuses new work while already admitted requests and retained reply
handles obey the existing bounded grace interval.

The fault workload uses named fixture credentials and a public custom
authenticator returning minimal peer-action grants. It qualifies role/subject
admission and denial through live TLS sessions; it is not a new PASETO signature
or production credential-provisioning proof. Those package-level crypto tests
remain separate.

The default public fault run accepts 15 requests and consumes 15 terminal
outcomes: ten successes, one authorization denial, two cancellations, one
deadline failure and one observed remote closure. It checks outcome reservation
under ordinary-event pressure, a matched valid-session control before the
wrong-role dial, wire-ID reuse after reconnect, and a retained reply during
GOAWAY. Late-handle calls qualify application-level rejection/suppression;
transport-level delayed-packet coverage remains in the QUIC driver tests.

Individual workloads can also run from a composition workspace configured with
explicit source paths:

```sh
QMSG_RUN_LIVE_UDP=1 mise exec -- zig build run-public-faults \
  -Dlocal-quic=true -Doptimize=ReleaseSafe
mise exec -- zig build run-chaos -Dlocal-quic=true -Doptimize=ReleaseSafe \
  -- --seed 0x514d45534804
```

`install-public-faults` and `install-chaos` accept separate `--prefix` directories
for exact-binary replay outside the build. Their JSON and phase records identify
the selected seed and hard acceptance outcomes.

Seeded replay distinguishes deterministic application action plans and virtual
network fingerprints from the variable timing and packet counters of real UDP.
Snapshots remain a bounded single-authority application schema. Endpoints come
from explicit configuration through the existing resolver, and mesh suspicion
does not imply immediate application-session removal. SWIM retains dead
records; this sprint does not add a membership garbage-collection protocol.

## Evidence boundaries

Final coordinated evidence is retained under `evidence/sprint-4-2026-10-26/`.
Producer records identify exact local candidates and separate fresh execution
from cached artifacts. Native Mac and Linux-container execution, target-only
Windows/x86 compilation and external-peer interoperability are distinct gates.
Local workflow commands do not establish hosted CI or native Windows results.
Fuzz budgets and coverage are reported explicitly; a timed-out or failed run
does not count as a completed budget.

The final verification index records passing, failing, held and unexecuted
gates. Any original-release failure or promotion hold remains visible beside
the selected candidate's results.

The local package proof verifies exact archive SHA256, extraction/file equality,
out-of-tree Debug/ReleaseSafe consumers and mode guards. It does not establish
a canonical Zig package content hash or a published URL fetch. The known
standalone rehash/cache problem remains a separate tooling limit, and no
release or dependency promotion follows from the local archive proof.
