# qmesh-zig

A QUIC-native cluster mesh substrate built on [quic-zig](../quic-zig).

qmesh maintains a resilient randomized peer mesh (HyParView), detects
membership changes (SWIM + Lifeguard, planned), disseminates events
quickly (Plumtree, planned), repairs missed information (anti-entropy,
planned), and exposes authenticated peer sessions to higher-level
distributed systems. It is **not** an actor runtime.

> Design principle: use randomized gossip to preserve connectivity and
> discover change; use direct QUIC paths for sustained traffic; use
> anti-entropy to guarantee eventual repair.

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
      cert-bound identities, exactly-once cluster broadcast, a 25%
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

## Composing with qmsg (the uncoupled way)

qmesh is a mesh substrate, not a messaging framework. To send
application messages between cluster members, run
[qmsg](https://github.com/nullstyle/qmsg) beside it — qmesh names and
watches peers, qmsg carries the traffic:

```text
  qmesh Node.aliveMembers()  ->  Directory.reconcile()  ->  qmsg dialQuic()
                                          |
                                     lookup(PeerId) -> SessionId
```

Each library keeps its own UDP port, its own event loop, and its own
handshake. The only thing they share is an identity, and neither
invents it — both derive it from the same TLS certificate:

| | identity |
| --- | --- |
| qmesh | `PeerId` = `Connection.peerCertSpkiDigest()` |
| qmsg | `Session.peer_cert_spki` = `Connection.peerCertSpkiDigest()` |

so `qmesh.PeerId.hex()` and `qmsg.Session.certPeerIdHex()` are the same
64 characters for the same peer. `examples/qmsg_directory.zig` is the
~200-line embedder-owned glue that follows from that.

Requires qmsg >= 0.6.1 (earlier releases forwarded a different option
set to quic-zig, which instantiated quic twice in one binary). Set
`AuthConfig.cert_binding = .require_match` on the qmsg listener so a
peer cannot announce an id its certificate does not back.

### Why not just watch qmsg sessions?

Because a qmsg session notices a dead peer only through the QUIC idle
timeout, and that is slow by design. qmsg's own two-node test measures
it: with the negotiated idle timeout at 2s, a silent peer's session is
dropped 2169ms after last contact — the timeout plus about one probe
interval. `max_idle_timeout_ms` defaults to **30 seconds**, and
`heartbeat_interval_ms` does not shorten it (a heartbeat keeps a
session alive; it does not detect death faster).

SWIM is built for the question instead. On qmesh's defaults —
`probe_period 1s`, `probe_timeout 0.5s`, `indirect_timeout 0.5s`,
`suspicion_timeout 3s` — a death is CONFIRMed in roughly **5 seconds**,
cluster-wide, and corroborated suspicion cuts that further. Indirect
probing also distinguishes "the peer is gone" from "our path to it is
gone", which a per-connection timeout structurally cannot.

That gap — ~5s of cluster-agreed membership against ~30s of
per-connection silence — is what the composition buys.

What this deliberately does NOT do: share a socket, share a quic
Connection, or run qmsg traffic over a qmesh session. Those couple the
two libraries and cost more than they buy — qmesh's reliable class is a
fresh uni stream per frame with a 1152-byte frame cap and a 16-stream
receive table, which is the wrong pipe for 1 MiB request/response
traffic. Two connections per peer is the price of keeping both wires
at full strength.

## quic-zig API gaps discovered

Concrete gaps the QUIC adapter will need, for follow-up in quic-zig
(generic APIs only — no qmesh concepts belong there). The paste-ready
work order for a quic-zig session lives at
[docs/quic-zig-session-brief.md](docs/quic-zig-session-brief.md); keep
that file authoritative as items land:

1. **Peer certificate access (blocking)** — RESOLVED on quic-zig main
   (post-0.20.0, unreleased 0.21.0). `Connection.peerCertSpkiDigest()`
   returns SHA-256 over the peer leaf certificate's DER-encoded
   SubjectPublicKeyInfo once the handshake completed and the peer
   presented a cert (null otherwise: pre-handshake, optional-client-cert
   servers with no cert presented, past-open connections).
   Role-agnostic, renewal-stable (same keypair ⇒ same digest across
   re-issuance), correct on resumed sessions; preimage matches the
   standard `openssl x509 -pubkey | openssl pkey -pubin -outform DER |
   openssl dgst -sha256` pipeline. Backed by boringssl-zig 0.6.6
   (`SSL_get_peer_certificate` + SPKI DER + SHA-256).
2. **Dialing by address with private-CA peers vs SNI** — RESOLVED on
   quic-zig main (same commit). `Client.Config.identity_verification =
   .none` sends SNI but skips the SAN/CN name check while chain
   validation against `ca_pem` remains mandatory; `.none` without
   `ca_pem` is an `InvalidConfig` at connect time (never a silent
   downgrade). The exact mesh dial posture.
3. **No session-establishment event** — RESOLVED on quic-zig main
   (same commit). `Server.Config.on_handshake_complete` fires exactly
   once per slot, from inside `feed`, the moment the TLS handshake
   completes; the connection is established and open inside the
   callback (`peerCertSpkiDigest()` readable, `slot.user_data`
   installable). Post-init twin: `setOnHandshakeCompleteHook`.
4. **Datagram send bounds are per-connection queues** (64 pending /
   64 KiB). Fine for qmesh's steady state; the adapter just needs to
   count-and-drop on `DatagramQueueFull` like any transport failure.
   Documented, not a gap requiring change.
5. **`streamInitiatedByLocal` is not a `Connection` method.** The
   helper exists in `Connection/streams.zig` but is not thunked onto
   the embedder surface, so the adapter derives locality from
   `conn.role` + the stream-id initiator bit. Trivial ergonomics gap;
   noted in the session brief.

Non-gaps worth noting: RTT (`pathStats(.srtt_us)`), close-cause
classification (`CloseEvent`/`CloseSource` — maps cleanly onto
`session.SessionLostReason`), DATAGRAM + stream ergonomics, and the
in-memory `quic.testing.Loopback` harness are all sufficient as-is.
Re-analyzed 2026-09-07 — two former "deferred" items are NOT quic-zig
gaps at all, and no session briefs are warranted for them:

- **0-RTT resumption**: quic-zig ships it complete — client
  `Config.resumption_state` (versioned envelope) +
  `new_session_callback` (persistence half), server `early_data`
  posture with anti-replay gating. Any qmesh adoption is pure
  adapter wiring (persist one envelope per peer, feed it back on
  reconnect). Adoption trigger: measured reconnect paths dominated
  by handshake RTT — today's are timer-dominated (probe rotations,
  promotion cadence), healing inside one metrics interval on fly.
- **Stream priorities**: quic-zig ships RFC 9218 complete
  (`StreamPriority` urgency + incremental, `streamSetPriority`,
  priority-ordered packetization). qmesh's reliable class is rare,
  tiny, single-frame uni-streams and the hot path is datagrams —
  nothing contends. Adoption trigger: reliable-frame contention
  (large anti-entropy windows starving JOIN/IWANT — the same
  window-growth family as the IBLT trigger).

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
sim/
  network.zig     deterministic event heap + policy types
  sessions.zig    virtual session manager (dial/establish/sever)
  node.zig        SimTransport / SimNode
  world.zig       run loop, fault injection, scenario assertions
  root.zig        qmesh_sim module root
tests/
  sim_scenarios_test.zig   fault-injection scenarios
  quic_boundary_test.zig   pins the quic-zig API surface
```

## Development

Toolchain is pinned via mise (same build as quic-zig):

```sh
mise install        # zig 0.17.0-dev.1683+5ceec001b
zig build test      # unit + simulator + quic boundary tests
```

`build.zig.zon` currently points at `../quic-zig` by path for local
development; release pins move to tarball URL + hash (see quic-zig's
zon for the `zig fetch` caveats).

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

## Next steps (milestone 2)

1. **QUIC session adapter** (`src/quic/`): a `SessionManager` owning
   one `quic.Server` per node plus outbound dials, implementing the
   transport contract — `ephemeral` → `sendDatagram`, `reliable` →
   `frame.stream` writes on a short-lived uni stream, session events
   from `pollEvent`/close/iterator diffs. Two-node JOIN over
   `quic.testing.Loopback` is the acceptance test. This is where gap
   (1) above gets resolved or worked around explicitly.
2. **SWIM + Lifeguard** (`src/swim.zig`): PING/ACK/PING_REQ probing
   over the overlay's sessions, incarnation-carrying ALIVE/SUSPECT/
   CONFIRM events, piggyback dissemination, local-health-aware
   suspicion. Simulator grows "pause" semantics per app-level (not
   transport) responsiveness.
3. Then Plumtree broadcast and periodic anti-entropy, both as pure
   state machines consuming the same session/transport seam.
