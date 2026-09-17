# qmesh-zig

A QUIC-native cluster mesh substrate built on [quic-zig](../quic-zig).

qmesh maintains a resilient randomized peer mesh (HyParView), detects
membership changes (SWIM + Lifeguard), disseminates small events
(Plumtree), attempts recent-message repair (anti-entropy), and exposes authenticated peer sessions to higher-level
distributed systems. It is **not** an actor runtime.

> Design principle: use randomized gossip to preserve connectivity and
> discover change; use direct QUIC paths for sustained traffic; use
> recent-message anti-entropy to repair retained information.

> New here? **[docs/tutorial.md](docs/tutorial.md)** walks the whole
> ladder — run a mesh in three terminals, read its telemetry, drive
> the library, prove properties in the simulator, embed real QUIC,
> deploy to fly, and sketch what you'd build on top (sharded cache,
> mesh-native APM, discovery, config broadcast).

## Status (milestone 1)

- [x] Project skeleton, build, tests (`zig build test`)
- [x] `PeerId` / `PeerDesc` / `Addr` identity model
- [x] Wire framing: version/protocol/type envelopes, bounded codecs,
      stream length-prefixing (`src/frame.zig`)
- [x] HyParView core as a pure state machine — JOIN, FORWARD_JOIN,
      NEIGHBOR handshake, DISCONNECT, SHUFFLE, promotion, active
      rotation (`src/hyparview.zig`)
- [x] Node driver + transport contract (`src/node.zig`)
- [x] Session boundary vocabulary (`src/session.zig`)
- [x] Deterministic simulator: virtual network with loss/delay/
      partition/pause/kill, virtual QUIC sessions with dial latency,
      per-node frozen clocks, seeded per-node PRNGs (`sim/`)
- [x] Scenario tests: 2-node join, 20-node bootstrap, 30% kill +
      heal, partition split + re-merge, 5% loss, pause/resume,
      byte-identical determinism across runs
- [x] QUIC session adapter (`qmesh_quic` module): Endpoint/SessionManager
      over real `quic.Server` + `quic.Client`, session HELLO identity
      resolution, DATAGRAM/stream class mapping, simultaneous-dial
      tiebreak, close handling via the will-close hook — two-node JOIN
      and close-demotion tests over `quic.testing.Loopback` with real
      mutual TLS (vendored test PKI)
- [x] SWIM core (`src/swim.zig`, pure): member table with the
      incarnation lattice (commutativity under arbitrary event
      interleavings is property-tested), PING/ACK/PING_REQ indirect
      probing, suspicion + refutation (self-directed SUSPECT bumps the
      incarnation), CONFIRM on expiry, piggyback dissemination, and a
      Lifeguard local-health multiplier fed by observed app delays.
- [x] SWIM integrated: the node driver multiplexes overlay + SWIM on
      one frames-in/effects-out cycle; session-up feeds the member
      table and is itself liveness evidence — an authenticated
      handshake with a member the table holds suspect/dead resurrects
      it at incarnation+1 (the mutual-CONFIRM wedge exit: the real
      transport tears sessions to "dead" members every service pass,
      so without session evidence a spurious CONFIRM under scheduler
      load has no recovery path once gossip agrees); CONFIRM purges
      the overlay passive view; alive members re-enter it. Partition
      recovery works end-to-end: dead-slot resurrection probes (direct
      ACK evidence outranks a stale CONFIRM, resurrecting at a bumped
      incarnation) re-open the connection, and piggybacked ALIVE
      re-bridges the overlay — the kill/partition scenarios now assert
      membership convergence.
- [x] Plumtree broadcast (`src/plumtree.zig`, pure): eager push /
      lazy IHAVE with duplicate-driven demotion + PRUNE, IWANT repair
      (reliable class) with graft-on-repair, bounded seen/payload
      caches; the tree rides the overlay's active view
- [x] Anti-entropy: recent-window EXCHANGE of message ids (two-message
      termination) pulling gaps through the normal IWANT repair — the
      simplest provable reconciliation; the exchange payload is the
      seam for Rateless IBLT later. Exchanges are pure PULLs when the
      cache is empty (fresh boots / long pauses must still learn), and
      replies are not gated on tree membership (anti-entropy is the
      backstop for peers the tree dropped).
- [x] `qmesh_quic.Runner` (src/quic/loop.zig): the supported socket
      loop — binds the UDP socket, owns one Endpoint, drives ingest →
      stateless drain → dial advance → protocol service → ticks/reap →
      outbound drain per iteration. `run()` blocks until a shutdown
      flag; `step()` is one nonblocking pass for tests and foreign
      event loops. POSIX (raw syscalls; Darwin needs fcntl nonblock).
      Each iteration also feeds its observed clock gap into SWIM's
      Lifeguard local-health multiplier — scheduler starvation scales
      probe/suspicion windows up instead of escalating a stall to
      CONFIRM + eviction, and clean cadence decays them back.
- [x] Twelve-node mesh over REAL UDP sockets (tests/quic_mesh_test.zig)
      driving the Runner directly: bootstrap convergence with
      cert-bound identities, duplicate-suppressed cluster broadcast, a 25%
      mass crash (no goodbyes) with SWIM suspect→confirm and session
      eviction, and post-crash broadcast over the healed mesh.
- [x] Production posture: reliable sends stage flow-control short
      writes in a bounded per-session outbox flushed by the service
      loop (no more full-write assertion); the reset key is minted by
      default at listen; Retry/NEW_TOKEN arm only when deployment
      keys are provided (they change the handshake/token flow).
- [x] Asymmetric-link fault (sim `blackholeOneWay`) with the property
      it exists to prove: one-directional blackholes between two
      nodes never escalate to CONFIRMed death — SWIM's PING_REQ
      indirect probing resolves through the healthy reverse paths,
      often before suspicion even fires.
- [x] Multi-region locality: SWIM samples application-level RTT from
      direct probe ACKs (per-member smoothed, no transport coupling),
      and probe/indirect/suspicion budgets become
      `max(profile floor, factor × smoothed RTT)` — co-located peers
      fail fast while high-RTT pairs self-extend, so profile timers
      no longer pad everyone to the worst region pair. The overlay
      spends a bounded ranked minority of its active slots
      (`ranked_slots`, 3 of 10 in the fly profile) on the lowest-RTT
      peers — promotion preference plus ranked-only displacement, so
      the uniform-random majority (and the small-world connectivity
      it provides) is structurally preserved; the broadcast tree
      inherits locality through the active view. Proven by the
      two-region simulator scenario (zone-shaped latencies): ranked
      sets converge to same-region peers, the cluster stays one
      component.
- [x] Lifeguard buddy set + corroborated-suspicion acceleration
      (Ta): each node silence-monitors a rotating set of random
      buddies — a majority of quiet-but-alive buddies feeds the
      node's own local health ("it's us or our path"), extending
      windows instead of evicting healthy peers; and a suspicion
      gossiped by enough distinct peers halves its window (floored at
      the RTT budget and ¼ of the profile window). Proven in the sim:
      an A/B on identical worlds shows full cluster agreement on a
      kill inside a budget where the unaccelerated control confirms
      nothing, the fly migration-pause scenario stays
      never-CONFIRM, and a 30%-loss flaky node keeps its whole table
      alive (buddy self-diagnosis at work).
- [x] Metrics snapshot surface (`src/metrics.zig`): one plain-data
      struct per node aggregating the protocol cores' gauges (view
      sizes, member states, tree shape, Lifeguard health) and
      lifetime counters (probe/suspect/confirm, shuffles,
      displacements, repairs, frame flow, session transitions) —
      `Node.metrics()` in the core, `qmesh_quic.Endpoint.metrics()`
      adds the transport counters (dials, accepts, established
      sessions, identity mismatches, …). Quic's per-connection qlog
      events wire through `Endpoint.Options.qlog_callback`, installed
      on every owned connection — the wire-level view beside the
      protocol-level counters.
- [x] Event ring (`src/events.zig`) — the incidents timeline's data
      source (docs/observability-ux.md Concept 2): swim, plumtree,
      and the node driver each own a bounded overwrite-oldest ring of
      plain-data events recorded at the exact transition sites
      (suspect/confirm/refute/resurrect through the incarnation
      lattice chokepoint, Lifeguard lh changes, self-refutations,
      broadcast repairs armed/lapsed, session up/down). The cores
      stay pure — the ring is derived state, deterministic under
      replay, proven by a sim scenario (a killed member's
      session→suspect→confirm story lands in causal order on every
      survivor's merged ring, and loss publishes record their
      repairs). Surfaced two ways: `event ...` lines on qmesh-node's
      stderr each metrics interval, and an `events` control-socket
      query whose reply pairs the node's monotonic ring clock with
      unix-epoch now — so `qmesh-top` merges every node's ring into
      one wall-clock-ordered fleet timeline beside the fleet cards.

## Architecture

```text
┌──────────────────────────────────────────────────┐
│        your distributed system (actors, …)       │
├──────────────────────────────────────────────────┤
│ qmesh                                            │
│   hyParView   active/passive views (pure SM)     │
│   Node(T)     driver: decode → handle → effects  │
│   Transport   minimal send/connect contract      │
├──────────────────┬───────────────────────────────┤
│ qmesh_sim        │ qmesh_quic                    │
│  virtual world   │ Endpoint: Server + dials,     │
│  (deterministic) │ HELLO identity, sessions      │
├──────────────────┴───────────────────────────────┤
│                quic-zig (transport)              │
└──────────────────────────────────────────────────┘
```

Dependency direction is strictly `qmesh -> quic`, split across two
modules: the library core (`qmesh`, src/) stays quic-free (pure
protocol cores, runs in the simulator without BoringSSL), and
`qmesh_quic` (src/quic/) is the real transport — an `Endpoint`
(SessionManager) owning one `quic.Server` for inbound plus one
`quic.Client` per dial, implementing the transport contract: DATAGRAM
for `ephemeral` frames, one length-prefixed uni-stream write per
`reliable` frame. Session identity is CERT-BOUND: PeerId =
`Connection.peerCertSpkiDigest()` (SHA-256 of the peer leaf cert's
DER SubjectPublicKeyInfo — the standard `openssl x509 -pubkey |
openssl pkey -pubin -outform DER | openssl dgst -sha256` preimage, so
provisioned PeerIds interoperate with standard tooling), bound at
handshake completion via the server's `on_handshake_complete` hook or
on the dial side directly. The session HELLO (0x00) survives as a
validated ADDRESS hint (announced id must equal the digest). Dials use
`identity_verification = .none` + pinned `ca_pem` — chain mandatory,
name check irrelevant for mesh dialing. Simultaneous dials tiebreak by
authenticated id to exactly one connection (lower PeerId's dial
wins).
`tests/quic_boundary_test.zig` pins the quic API surface the adapter
uses, so quic-zig drift fails this project's build with a clear
message.

### The purity discipline

Every protocol core is a pure state machine:

```zig
overlay.handle(from, msg, now, rng, out: *Effects);  // messages
overlay.tick(now, rng, out: *Effects);               // timers
overlay.nextDeadline();                              // timer due time
```

`now` and `rng` are explicit parameters (never ambient), effects are
bounded lists (never callbacks), so:

- the same code runs unchanged in the simulator and over real QUIC;
- property tests assert over state + effects with no mocks
  (`hyparview.test.view invariants survive a randomized operation
  storm`);
- every scenario is reproducible from a seed.

### Transport contract

`Node(Transport)` needs exactly six things from a transport
(`src/node.zig`): `now`, `rng`, `sendDatagram`, `sendReliable`,
`connect`, `descOf`. `SimTransport` (`sim/node.zig`) is the
simulator's implementation; `qmesh_quic.Endpoint` (`src/quic/`) is the
real one — DATAGRAM for `ephemeral` frames, one length-prefixed stream
write per `reliable` frame (`frame.stream`).

### Message class mapping

| class      | QUIC vehicle | messages                                |
|------------|--------------|-----------------------------------------|
| reliable   | stream frame | JOIN, JOIN_ACK, NEIGHBOR_ACCEPT         |
| ephemeral  | DATAGRAM     | FORWARD_JOIN, NEIGHBOR, NEIGHBOR_REJECT, DISCONNECT, SHUFFLE, SHUFFLE_REPLY |

Membership agreement must complete; everything else self-heals through
timeouts, shuffles, and promotion, so a lost ephemeral frame only
costs an opportunity.

### Simulator

```zig
var world = qsim.World.init(allocator, seed, cfg, policy);
defer world.deinit();
var i: u32 = 0;
while (i < 20) : (i += 1) _ = try world.spawn();
world.bootstrapAll(0);
try world.runFor(30_000_000);          // 30 s of virtual time
try std.testing.expectEqual(@as(usize, 1), world.componentCount());

world.policy.drop_bp = 500;            // 5% datagram loss
try world.kill(4);                     // permanent, severs sessions
try world.pause(7, 10_000_000);        // freeze one node for 10 s
try world.partition(&.{ 1, 2 }, &.{ 3, 4 });
world.heal();
```

Determinism: one event heap keyed by `(time, schedule-seq)`, per-node
PRNGs, a dedicated link-loss PRNG, timers-before-events (lowest node
index first) tie-break. Same seed ⇒ byte-identical overlay state
(asserted by a test). 200-node scenarios with 30% kills run in ~0.2 s.

### Deviations from the HyParView paper

Documented in `src/hyparview.zig`:

- Active edges are explicitly agreed (JOIN/NEIGHBOR + ACCEPT/REJECT)
  rather than "open connection == membership", because QUIC sessions
  are shared and outlive overlay membership.
- SHUFFLE samples lead with the sender's own descriptor.
- Proposal timeouts do NOT purge the passive view (addresses are not
  liveness claims; purging lets a partition permanently drain the
  other side from passive views and blocks healing — found by the
  partition scenario).
- Active rotation (periodic random edge drop, never below
  `active_min`) exists so healed partitions re-merge even when both
  sides refilled their active views while split.

## Composing with qmsg

qmesh owns membership and bounded dissemination; qmsg owns application
messages, request/reply, subscriptions, deadlines, and authorization.
The optional `qmesh_messaging` module supplies a peer-session pool with
an injected endpoint resolver and qmsg adapter. See
[`examples/qmsg_directory.zig`](examples/qmsg_directory.zig) and
[`docs/MESSAGING.md`](docs/MESSAGING.md).

A member, a dialable application endpoint, and an authenticated ready
qmsg session are separate facts. `Node.member(id)` returns the full
member record, including `alive`/`suspect`/`dead` and contact provenance.
`Node.members(out)` reports `written`, `total`, and `complete`; omission
from an incomplete snapshot never means removal. Suspicion alone does
not require closing a usable application session. `aliveMembers` remains
an alive-only compatibility helper, unsuitable for lifecycle decisions.

Both protocols can derive identity from the same TLS key:
`qmesh.PeerId` and qmsg's verified peer SPKI are the same 32 bytes.
The pool verifies the peer reached by a dial against that expected ID;
certificate/HELLO agreement alone does not establish the intended peer.
A resolver chooses the application endpoint explicitly; no global
"gossip port plus one" convention is required. Connections are acquired
on demand, bounded, retried with backoff, and evicted when idle.

Separate connections preserve each protocol's own framing, resources,
and lifecycle. The implementation can share generic connection-driving
machinery (`quic.app.ConnectionDriver`) without combining wire protocols.
qmesh uses that driver when supplied by quic-zig; the pinned release
fallback preserves the same mesh interface. qmesh's 1152-byte reliable
frames remain protocol traffic, not a tunnel for qmsg's application wire.

## Dissemination contract and capacity

`publish(payload)` accepts up to 1000 bytes and returns a local message
ID. Acceptance is not a cluster delivery acknowledgement. There is no
persistence, causal ordering, total ordering, fixed publication audience,
or unbounded eventual-delivery guarantee. A callback borrows its payload
only for the call; copy data you retain.

The recent repair window holds 32 payloads and exchanges at most 16 IDs
per message (every 10 seconds by default). Duplicate suppression remembers
256 IDs. Cache eviction can make an old message unrecoverable, and an ID
received after deduplication eviction may be delivered again. Slow consumers,
long partitions, and sustained publication must use an application state
snapshot or durable log for complete reconciliation. qmsg can transport
that reconciliation; storage and version semantics belong to the application.

A `MsgId` contains `origin`, a 128-bit `epoch`, and `seq`. Raw core callers
must supply a unique lifetime `boot_epoch` in `Node.Config` (or directly to
`Plumtree.init`). `Endpoint.init` generates it using a CSPRNG unless explicitly
overridden for deterministic tests; the simulator derives it from its seed.
The broadcast hook receives the complete ID. Clock adjustments and process
restarts therefore do not reuse IDs merely because the TLS key is retained.
This wire change uses frame version **2** and ALPN **qmesh/2**; mixed versions
must be upgraded together. Certificate renewal with the same key retains
PeerId; changing the key creates a different member.

Protocol effects own their slice data until `clear()`; source scratch can be
reused immediately. Keep a populated effects list in place until consumed.
Effect capacities are derived from each protocol's maximum fanout/batch work.
The QUIC adapter bounds staged reliable output to eight frames and tracks
16 simultaneous receive streams, explicitly refusing excess streams.
Transport acceptance can still fail or a connection can end; protocol timers
and bounded repair handle those failures. These limits keep memory bounded
but are not an application message queue.

## quic-zig integration

The adapter uses public QUIC certificate evidence, handshake/close hooks,
stream allocation/read/write operations, datagrams, and connection timers.
`tests/quic_boundary_test.zig` pins that surface. The generic
`quic.app.ConnectionDriver` path borrows accepted or dialed connections,
with bounded pending output, explicit stream refusal, and one lifecycle
implementation. Compatibility with the pinned release remains available
until the shared driver is published.

Identity comes from `Connection.peerCertSpkiDigest()` after mutual TLS.
An outbound dial must also match its expected PeerId; HELLO cannot substitute
another certificate-valid peer. Duplicate dials choose the connection initiated
by the lower PeerId and closing a loser does not report loss of the winner.
HELLO and protocol frames use the same bounded reliable write path; partial
writes resume through the outbox and malformed streams close only their peer
session. Refused streams and protocol errors appear in transport metrics.

`Runner` is the provided socket loop; `Endpoint.service` supports other
embedders. Port-zero binding selects an available UDP port and updates a
zero-port advertisement; `Runner.localAddress()` returns the actual bound
address. Persistent deployment keys remain an explicit configuration choice.

## Layout

```text
src/
  root.zig        public API
  peer.zig        PeerId, Addr, PeerDesc
  frame.zig       wire envelopes, bounded codecs, stream framing
  effects.zig     bounded effect lists
  events.zig      bounded event rings (incidents timeline source)
  session.zig     session-state vocabulary + QUIC mapping notes
  hyparview.zig   active/passive overlay (pure state machine)
  node.zig        Node(Transport) driver + transport contract
  quic/
    discovery.zig qmesh-node's `--mdns` LAN discovery glue (dev-only module)
sim/
  network.zig     deterministic event heap + policy types
  sessions.zig    virtual session manager (dial/establish/sever)
  node.zig        SimTransport / SimNode
  world.zig       run loop, fault injection, scenario assertions
  root.zig        qmesh_sim module root
tests/
  sim_scenarios_test.zig   fault-injection scenarios
  quic_boundary_test.zig   pins the quic-zig API surface
  mdns_discovery_test.zig  `--mdns` glue over loopback mDNS (real sockets)
```

## Development

Toolchain is pinned via mise (the same build as qmsg and mdns-zig):

```sh
mise install        # zig 0.17.0-dev.1786+75044cb04
zig build test      # unit + simulator + quic boundary + mesh + mdns tests
```

`build.zig.zon` pins a quic-zig release tarball and hash. Keep the
version and build option set aligned with qmsg when composing both.
It also pins [mdns-zig](https://github.com/nullstyle/mdns-zig) as a
**lazy** tarball dependency: only the `qmesh-node` binary and the
discovery test use it, no library module imports it, and a consumer
that fetched qmesh never downloads it. mdns-zig refuses ReleaseFast /
ReleaseSmall because it parses untrusted UDP, so build.zig resolves it
only for Debug and ReleaseSafe (the fly posture already) unless
`-Dmdns=true|false` says otherwise; a ReleaseFast `zig build` still
produces every binary and test, with a `qmesh-node` that refuses
`--mdns` at start-up.

## Running a node (fly smoke-test posture)

`zig build` produces `zig-out/bin/qmesh-node` — one mesh node on the
supported socket loop with the `fly_multi_region` profile, provisioned
cert identity, stderr metrics lines, broadcast logging, and
SIGTERM-clean shutdown:

```sh
# The node's PeerId is its cert's SPKI digest (the standard pipeline):
openssl x509 -in node.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER | openssl dgst -sha256

./zig-out/bin/qmesh-node \
  --id <64-hex-digest> --bind '[fdxx::1]:4451' \
  --cert node.pem --key node.key --ca ca.pem \
  --join <peer-64-hex>:'[fdxx::2]:4451' --metrics-secs 10
```

### LAN discovery: `--mdns` (dev and LAN only)

`--mdns` (env `QMESH_MDNS=1`) finds peers over mDNS/DNS-SD instead of,
or in addition to, `--join`. At start-up the node runs one bounded
`_qmesh._udp` lookup (3 s, or 500 ms after the last answer) and joins
every node already advertising, exactly the way a `--join` contact is
joined. It then advertises itself — instance `--name <label>` (env
`QMESH_NAME`) or the first 16 hex of its id, SRV port = the bound port,
TXT `id=<PeerId hex>` and `epoch=<boot epoch>` — and keeps browsing from
the runner loop, joining each new `(id, epoch)` it hears (a peer that
restarts re-announces a new epoch and is joined again). Every join is
an `mdns join id=... addr=...` line on stderr. Because the advertised
`id` reaches every node on the LAN, `qmesh-node` checks `--id` against
the SPKI digest of `--cert` at start-up (`PeerId.fromCertPem`) and
refuses a mismatch — with or without `--mdns`, a wrong id fails every
peer's identity check anyway.

```sh
# Two nodes on one LAN, no --join anywhere. Bind the LAN address (it
# is also the contact the node gossips about itself); the port need
# not match between nodes.
./zig-out/bin/qmesh-node --id <a-hex> --bind 192.168.1.10:4451 --cert a.pem --key a.key --ca ca.pem --mdns
./zig-out/bin/qmesh-node --id <b-hex> --bind 192.168.1.11:4451 --cert b.pem --key b.key --ca ca.pem --mdns
```

The TXT `id` is an unauthenticated selector: any host on the link can
publish any digest, so it only says which PeerId to expect at that
address, and the pinned-CA mTLS handshake plus HELLO proves it, as for
a `--join` contact typed by an operator. A forged advert costs one
failed dial. Link-local IPv6 contacts are skipped (`Addr` has no scope
field, and the socket loop sends scope id 0); a peer with an IPv4 or a
global/ULA IPv6 address is joined.

Multicast does not exist on fly 6pn, so `--mdns` is a LAN and
development convenience, never the production bootstrap — `--join` /
`QMESH_JOIN` remains that. On macOS a Terminal-launched binary inherits
Terminal's Local Network grant; `mdns warning no_packets_10s` on stderr
is the signature of a denied one.

Deploy one process per fly machine over the 6pn network (bind the
machine's private v6; the 6pn interface is MTU 1420, so fly
deployments pass `--pmtu-max 1372` — 1420 minus 48 bytes of IPv6+UDP
headers; at higher caps full-size packets are silently dropped, found
in the fly smoke test). Metrics lines carry the gauges to watch: 
`alive`/`suspect`/`dead` (membership agreement), `active`/
`ranked` (overlay + locality), `sess` (transport), `lh` (Lifeguard
health — sustained nonzero means the machine is starving the loop),
`rtt_min`/`rtt_max` (measured peer RTT envelope). Build deploy
binaries with `-Dtarget=x86_64-linux -Doptimize=ReleaseSafe` (fly
shared-cpu machines are x86_64). The full two-region smoke procedure
and its findings live in [deploy/smoke/RUNBOOK.md](deploy/smoke/RUNBOOK.md).
