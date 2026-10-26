# Seeded multi-node recovery chaos

`examples/seeded_recovery_chaos.zig` composes four real localhost mesh nodes,
three public `qmsg.QuicSocket(.req)` clients, an authority's `.rep` owner, and
configured `qmesh_messaging.Pool` routes. It reuses Sprint 3's bounded application
snapshot schema. No messaging dependency enters the mesh core.

The seed produces one bounded logical plan: protocol PRNG seeds, a permutation
of the three replicas, selected observer/decoy/fresh-owner roles, and 40–47
application updates plus 40–47 unrelated announcements. The plan fingerprint,
final application-state fingerprint and revisions are replay identities. TLS
randomness, ephemeral ports, UDP packet order, iteration counts, request counts
and wall times are observations and are not claimed deterministic.

The recorded seed table is:

- `0x514d45534804` (default)
- `0x719e0023`
- `0xfedcba9876543210`

## Thirteen logical actions

1. Bootstrap all four mesh identities and recover an initial snapshot at each
   replica through authenticated request sessions.
2. Isolate the authority with the runners' port-based mesh blackholes and pause
   its snapshot server's pump. Clients continue pumping and settle deadlines.
3. Make the seeded updates and hints, then evict every useful hint from the
   actual 32-payload cache with unrelated announcements. Drain each ephemeral
   send through the blackhole. No useful hint may reach a replica afterward.
4. At the chosen observer's suspicion, preserve its exact existing ready route.
   A fresh probe pool must reject the suspected peer without dialing.
5. Confirm death at all three replicas and verify that all three pools forget
   their authority routes. Accepted requests have exactly one terminal outcome.
6. Destroy and recreate the whole authority Rep owner and UDP listener at the
   same configured endpoint, retaining application state outside that owner.
7. Clear the local blackholes, resume the server and bootstrap the authority
   through a known contact. No new application revision hint is published.
8. Recover complete application state at all replicas by periodic snapshots.
9. Move the authority application listener to a distinct port while deliberately
   keeping the configured resolver stale. Bounded failed dials must expose no
   ready route to the stale endpoint.
10. Point the resolver at a live endpoint with another valid cluster key. An
    explicit positive-control dial must become ready with that endpoint's real
    SPKI, while the authority pools must reject it under the expected authority
    SPKI and send it no application request.
11. Correct the configured resolver and recover the newer snapshot.
12. Replace one seeded replica's Runner with a fresh same-identity mesh owner.
    Its empty membership table must return null for the authority; this must
    forget a previously ready pool route. Clear that replica's application
    state and bootstrap the new mesh owner through a known contact.
13. Recover that replica and require all four membership views to be alive and
    all three complete application states to equal the authority.

Application restart here means destroy/recreate inside one process. The fixture
holds authority state outside the messaging owner. It does not qualify an OS
process crash, persistence, consensus or physical-network behavior.

SWIM retains dead records in its fixed table. This scenario adds no membership
GC or tombstone-removal policy. Confirmed death removes application routes;
lookup absence is exercised through a fresh owner generation. Existing
certificate-authenticated join/session contracts perform resurrection.

## Bounds and ownership

The default phase deadline is eight seconds, and the total deadline is forty.
The CLI accepts `--seed <decimal-or-0x-value>`; the reusable `Options` validates
phase limits of 2–15 seconds and total limits of 10–60 seconds. Default requests
have a 100 ms deadline and a 100 ms periodic reconciliation cadence.

Each replica has one pool entry and one accepted request, including its terminal
reservation. The fixed terminal history stores at most 256 opaque request IDs
per replica; it compares ID values rather than using IDs as array indices.
Backpressure is recorded without accepting another request. The counters obey:

```
accepted attempts = replies + deadline failures + expected peer closures
replies = newly applied snapshots + rejected stale/duplicate snapshots
```

Every canonical event batch is freed once. Intentional route teardown marks an
expected peer closure before closing; unrelated failure classifications stop
the scenario. The owner finishes accepted work before changing phases, and
repumps after queued sends, dials or callbacks before parking.

Each messaging Node admits at most eight sessions, sixteen events / 4 KiB of
event bytes, and one request / 1 KiB of request and completion bytes. Each
transport has an eight-message / 8 KiB send bound, a 1 KiB message bound and a
two-stream initial bidi window. The inherited mesh cores retain their fixed
membership/view/cache bounds; the workload additionally fails above 64 mesh
session records or 32 server slots per node. Those gauges and pool/pending high
water marks are included in the report.

The single owner waits on the minimum mesh, messaging, pool, application and
phase deadlines, with a 10 ms response cap. A deliberately paused server adds
neither its readable socket nor its overdue timers. Normal wait duration stays
below the 300 ms probe budget; actual long scheduler stalls remain visible to
Lifeguard. No fixed event sleeps drive phase completion.

The public keys and private keys in `examples/recovery-pki/` are localhost test
material only, copied from the existing test fixtures.

## Virtual replay and reproduction

The independent transport-free test uses twelve `qmesh_sim.World` nodes. For
each recorded seed it repeats the actual partition/retention/heal state machines,
models the application restart and configured endpoint changes through the
existing Pool contract, and checks complete snapshot state. It repeats each
seed and compares the logical plan, virtual world, delivery-log and state
fingerprints plus route counters. A separate fresh-owner lookup test preserves
the old world's records while verifying absence-driven route cleanup.

`CHAOS_VIRTUAL_REPLAY` JSON records retain those virtual fingerprints.
`MESH_CHAOS_WORKLOAD` JSON records retain the real UDP results. Only the logical
plan and application-state results are compared across those layers; a twelve
node virtual graph is not equated with a four node real graph.

```sh
mise exec -- zig build chaos-test -j2 --summary all
mise exec -- zig build test -j2 --summary all
mise exec -- zig build test -Doptimize=ReleaseSafe -j2 --summary all
```

The optional consumer workspace supplies `run-chaos`, `install-chaos` and
`test-sprint4`; see [sprint-4-qualification.md](sprint-4-qualification.md) for the
source-identified cross-repository commands and final matrix. `run-chaos --
--seed 0x719e0023` replays one logical plan. The producer runs the installed
binary for all three seeds in Debug and ReleaseSafe with an external sixty
second process-group watchdog, and records compiler/source/binary identities,
commands, phase logs and invariants in `.zig-cache/sprint-4-evidence/`.
