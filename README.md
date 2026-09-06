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
- [ ] SWIM + Lifeguard membership & failure detection
- [ ] Plumtree eager/lazy dissemination
- [ ] Anti-entropy reconciliation

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
`reliable` frame. Session identity resolves via the HELLO protocol
(0x00) until quic-zig exposes certificate digests; simultaneous dials
tiebreak to exactly one connection (lower PeerId's dial wins).
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

`Node(Transport)` needs exactly five things from a transport
(`src/node.zig`): `now`, `rng`, `sendDatagram`, `sendReliable`,
`connect`. `SimTransport` (`sim/node.zig`) is the simulator's
implementation; the QUIC adapter will be the real one — DATAGRAM for
`ephemeral` frames, one length-prefixed stream write per `reliable`
frame (`frame.stream`).

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

## quic-zig API gaps discovered

Concrete gaps the QUIC adapter will need, for follow-up in quic-zig
(generic APIs only — no qmesh concepts belong there). The paste-ready
work order for a quic-zig session lives at
[docs/quic-zig-session-brief.md](docs/quic-zig-session-brief.md); keep
that file authoritative as items land:

1. **Peer certificate access (blocking).** Neither `quic.Connection`
   nor `boringssl.tls.Conn` exposes the peer certificate or a digest
   of it (no `SSL_get_peer_certificate` binding in boringssl-zig).
   mTLS *verification* works (`Server.Config.client_ca_pem`,
   `Client.Config.ca_pem` + client certs), but qmesh cannot bind a
   `PeerId` to the authenticated identity — the central security
   property of the design. Proposed shape: a digest accessor on
   `Connection` (`peerCertDigest(&buf)`) or the SessionManager API:
   `fn peerCertificate(conn) ?[]const u8` implemented over a new
   boringssl-zig binding. Until then, PeerIds are announced inside the
   authenticated channel (JOIN self-description) and cross-checked
   against the session, not against the certificate.
2. **Dialing by address with private-CA peers vs SNI.** `Client.connect`
   requires `server_name` and verifies the certificate identity against
   it. A mesh dials bare IPs from gossip; certificate identity for
   peer certs signed by the cluster CA is usually not the IP. Workable
   today (per-peer SANs or `insecure_skip_verify` + CA pinning, which
   loses impersonation protection); a first-class
   "verify against CA, skip name check" verification mode would make
   the mesh posture exact.
3. **No session-establishment event.** Servers discover new
   connections by diffing `Server.iterator()` slots; handshake
   completion is polled via `Connection.handshakeDone()` /
   `phase()`. Works, but an accept/handshake-complete notification
   (or a documented iterator-diff pattern) would simplify the session
   manager. Not blocking.
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

## Layout

```text
src/
  root.zig        public API
  peer.zig        PeerId, Addr, PeerDesc
  frame.zig       wire envelopes, bounded codecs, stream framing
  effects.zig     bounded effect lists
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
