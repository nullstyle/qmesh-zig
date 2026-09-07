# qmesh: a tutorial — from three terminals to hypothetical fleets

This walks the whole ladder: run a mesh in three terminals, read its
telemetry, drive the library by hand, prove protocol properties in
the deterministic simulator, embed it over real QUIC, deploy it, and
finally think about what you'd build ON it. Every code snippet is
trimmed from files that compile and run in this repo's test suite —
the source file is named beside each one, so nothing here can quietly
rot.

Time: parts 1–3 are ~20 minutes hands-on; the rest is reading.

---

## 0. The mental model (read this first)

qmesh is a **mesh substrate**, not a messaging framework. It answers
three questions for the processes that run beside it:

- **who is in the cluster** (SWIM membership — suspicion, refutation,
  confirmation, resurrection; ~seconds of cluster-wide agreement),
- **how to reach them** (a HyParView overlay of authenticated QUIC
  sessions, locality-ranked),
- **how to tell everyone something** (Plumtree epidemic broadcast with
  lazy repair, plus periodic anti-entropy as the eventual-repair
  backstop).

The design bet, in one line each:

> randomized gossip preserves connectivity and discovers change;
> direct QUIC paths carry sustained traffic; anti-entropy guarantees
> eventual repair.

Three properties worth internalizing before the first command:

1. **Identity is the certificate.** A node's `PeerId` is the SHA-256
   of its leaf certificate's DER SubjectPublicKeyInfo — the standard
   `openssl x509 -pubkey | openssl pkey -pubin -outform DER |
   openssl dgst -sha256` pipeline. Identity is provisioned, not
   negotiated; mTLS is the trust boundary; there is no "join token".
2. **The protocol cores are pure state machines.** `handle`/`tick`
   take explicit `now` and `rng`, mutate only their own state, and
   emit bounded effect lists. The same bytes run unchanged in a
   deterministic simulator and over real QUIC.
3. **qmesh observes itself.** Metrics snapshots, a per-node event
   ring, and rule-based root-cause fingerprints are first-class
   library surface — the fleet's own behavior during an incident is
   visible in the incident.

Honest boundaries (what qmesh is NOT):

- **Not consensus.** Membership converges to agreement and broadcast
  is exactly-once per message, but there is no total order across
  concurrent publishers and no linearizable state. Use it to build
  the *communication and membership* layer, not a database.
- **Not a message queue.** No persistence, no ordering guarantees
  between publishes, and frames are small (1000-byte payloads) —
  sustained application traffic belongs in a transport like
  [qmsg](https://github.com/nullstyle/qmsg) riding beside qmesh
  (part 8).
- **Not for actors.** It names and watches peers; it does not
  supervise or place your workloads.

---

## 1. Prerequisites

```sh
git clone …/qmesh-zig && cd qmesh-zig
# quic-zig lives beside it (path dependency in build.zig.zon):
#   git clone …/quic-zig ../quic-zig
mise install                    # zig 0.17.0-dev.1683+5ceec001b
ZIG_GLOBAL_CACHE_DIR=$HOME/prj/zig/quic-zig/.zig-global-cache \
  zig build test                # expect every step green
```

The test suite includes a 12-node mesh over real UDP sockets on
loopback — on a loaded laptop it can take a minute; a one-off timing
flake under load is a known property of real-socket tests, not a bug
report (rerun).

## 2. Hello, mesh (three terminals)

The repo ships a throwaway PKI in `tests/data/` (a CA plus twelve
node certs — regenerate with `tools/gen-test-certs.sh` if you ever
need fresh ones). Use two of them.

First, compute the PeerIds — this is the identity pipeline every
operator and every other tool uses:

```sh
for n in a b; do
  echo "node-$n: $(openssl x509 -in tests/data/node-$n.pem -pubkey -noout \
    | openssl pkey -pubin -outform DER | openssl dgst -sha256 | awk '{print $2}')"
done
# node-a: 48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143
# node-b: c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e
```

Terminal 1 — the seed:

```sh
./zig-out/bin/qmesh-node \
  --id 48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143 \
  --bind '[::1]:4451' \
  --cert tests/data/node-a.pem --key tests/data/node-a.key \
  --ca tests/data/ca.pem \
  --metrics-secs 2 --publish-every 3
```

Terminal 2 — a joiner:

```sh
./zig-out/bin/qmesh-node \
  --id c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e \
  --bind '[::1]:4452' \
  --join 48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143:'[::1]:4451' \
  --cert tests/data/node-b.pem --key tests/data/node-b.key \
  --ca tests/data/ca.pem \
  --metrics-secs 2 --publish-every 3
```

(Alternatively via env vars — `QMESH_ID`, `QMESH_BIND`, `QMESH_JOIN`,
`QMESH_CERT/QMESH_KEY/QMESH_CA` as path or inline PEM, which is the
deployment posture.)

Within a couple of seconds both terminals show the mesh agreeing with
itself:

```
metrics alive=1 suspect=0 dead=0 active=1 passive=0 ranked=1 eager=1 lazy=0
        sess=1 lh=0 rtt_min=2481us rtt_max=2481us probes=12 acks_tx=12 …
published seq=7
broadcast origin=c43fffee6eebfd65… seq=7 payload=qmesh-smoke/7
```

Reading the metrics line (the gauges that matter day-to-day):

| field | meaning |
|---|---|
| `alive/suspect/dead` | this node's SWIM view of everyone else |
| `active/passive/ranked` | overlay active view, passive view, locality-ranked slots |
| `eager/lazy` | broadcast tree shape (eager push vs lazy IHAVE edges) |
| `sess` | established QUIC sessions |
| `lh` | Lifeguard local-health exponent — sustained nonzero = this machine is starving the loop |
| `rtt_min/rtt_max` | measured app-level RTT envelope (the cheap RTT matrix) |
| `probes/acks_*` | failure-detector flow — a stall in `probes` with alive peers is the probe-engine seizure signature |
| `suspects/confirms` | lifetime detections |

Terminal 3 — kill it and watch it heal:

```sh
pkill -f 'bind.*4452'   # or kill the joiner's PID: no goodbye, crash semantics
```

In the seed's terminal: within a few seconds `suspect=1` appears
(direct probe and indirect PING_REQ both failed), then — because
nobody refutes — `dead=1` roughly ten seconds later (suspicion window
expiry → CONFIRM, gossiped cluster-wide). Restart the joiner with the
same command: the QUIC handshake itself is authenticated liveness
evidence, so the seed **resurrects** it at a bumped incarnation
within seconds and the overlay re-fuses. No operator action anywhere.

What you just watched, mechanically: SWIM probes one member per
period; failures escalate direct → indirect (PING_REQ through
bystanders, which distinguishes "peer gone" from "path gone") →
suspicion (refutable by the target bumping its incarnation) →
confirm (terminal for that incarnation, heals only through
resurrection evidence). Suspicion windows scale with the target's
measured RTT and with this node's own Lifeguard local health — a
starving node widens its windows instead of evicting healthy peers.

## 3. The console: fleet cards, incident timeline, fingerprints

Run each node with `--control '[::1]:5901'` (a second UDP socket
speaking a tiny text protocol) and the backend-less console attaches
from anywhere you can reach one node:

```sh
./zig-out/bin/qmesh-top '[::1]:5901' '[::1]:5902'
```

Two views per round. **Fleet cards** — one stats line per node, with
the completeness line that makes silence itself the story:

```
48b3be63f84888a0 alive=5 sus=0 dead=0 act=5 rank=3 sess=5 slots=1 lh=0 rtt=2825-75891us pub=12 del=58
…
completeness: 6/6 answered
```

**The incident timeline** — every node's event ring (membership
transitions, Lifeguard changes, session churn, broadcast repairs),
merged across nodes on wall clock, newest first — because each node's
reply pairs its monotonic ring clock with unix-epoch now:

```
fingerprints · root-cause leads
  c43fffee6eebfd65  restart churn: confirmed dead then returned x1 (on 48b3be63f84888a0)
recent fleet events (merged, UTC) · 17 collected
  21:38:12.000 48b3be63f84888a0 session_up peer=c43fffee6eebfd65
  21:38:10.000 c43fffee6eebfd65 self_refute peer=c43fffee6eebfd65 inc=5
  21:38:08.000 48b3be63f84888a0 resurrect peer=c43fffee6eebfd65 inc=1
  21:38:04.000 48b3be63f84888a0 confirm peer=c43fffee6eebfd65 inc=0
  21:37:56.000 48b3be63f84888a0 suspect peer=c43fffee6eebfd65 inc=0
```

That output is from the kill/restart you just did — the whole causal
story (suspect → confirm → resurrect → the restarted node refuting
the stale suspicions that greeted it) in one view. The
**fingerprints** section is a rule-based pass
(`qmesh.events.annotate`) that recognizes the incident classes this
project has actually hit: starved-only suspectors (a suspicion that
probably describes the suspector's own stall), restart churn loops,
and delivery gaps where anti-entropy is carrying repair.

The same events drain to each node's stderr as `event …` lines every
metrics interval, so chaos-campaign logs carry the mesh's own account
of the fault schedule (`grep '^event'`).

The control socket also takes fault commands — this is the chaos
tooling's lever set (see `tools/chaos-design.md`): `freeze 3000`,
`drop 1500 both`, `bh 4452 in`, `slow 80`, `clear`, `crash`.

## 4. The library in sixty lines: a pure core and a fake transport

Everything below the binaries is library. The driver is
`Node(Transport)` — one struct per process multiplexing the three
cores on a frames-in/effects-out cycle (`src/node.zig`):

```zig
var node = qmesh.Node(FakeTransport).init(me_desc, .{}, &transport, .{
    .ctx = &my_collector,
    .onBroadcast = my_collector.onBroadcast,  // deliveries surface here
});
node.startJoin(contact_desc);          // → JOIN + connect effects
node.onSessionUp(peer_id);             // session = liveness evidence
node.handleWire(from_id, bytes);       // one decoded frame
node.tick();                           // protocol timers
const id = node.publish("hello");      // cluster broadcast (≤1000 B)
```

The transport contract is six functions — `now`, `rng`,
`sendDatagram` (lossy class), `sendReliable` (completion class),
`connect`, `descOf`. A complete fake for tests is ~25 lines
(`src/node.zig` ships one inside its own test block); the two real
ones are `qmesh_sim.SimTransport` and `qmesh_quic.QuicTransport`.

The purity discipline is why this matters. Each core is:

```zig
overlay.handle(from, msg, now, rng, out: *Effects);  // messages
overlay.tick(now, rng, out: *Effects);               // timers
overlay.nextDeadline();                              // sleep math
```

`now`/`rng` are explicit, effects are bounded lists — never
callbacks. Consequences you will come to rely on: property tests
assert over state + effects with no mocks, every scenario replays
from a seed, and the same core bytes run in the simulator and over
real QUIC. Cross-protocol coupling (CONFIRM purges the overlay's
passive view; session establishment resurrects the dead; measured
RTTs feed the overlay's locality ranking) lives ONLY in `node.zig` —
never inside a core.

## 5. Proving things in the deterministic simulator

The simulator (`qmesh_sim`, `sim/`) is a virtual network with
loss/delay/partition/pause/kill, virtual QUIC sessions with dial
latency, per-node frozen-while-paused clocks, and per-node PRNGs.
Same seed ⇒ byte-identical run. 200-node scenarios with 30% kills run
in fractions of a second.

This is the "kitchen" from `tests/sim_scenarios_test.zig` — a
kill-and-heal scenario in full:

```zig
var world = qsim.World.init(allocator, 42, overlay_cfg, swim_cfg, bcast_cfg, .{});
defer world.deinit();
var i: u32 = 0;
while (i < 20) : (i += 1) _ = try world.spawn();
world.bootstrapAll(0);
try world.runFor(30_000_000);                        // 30s virtual
try std.testing.expectEqual(@as(usize, 1), world.componentCount());

// kill 30% with no goodbyes; survivors heal and stay one component
for ([_]u32{ 2, 5, 8, 11, 14, 17 }) |v| try world.kill(v);
try world.runFor(30_000_000);
try std.testing.expectEqual(@as(usize, 14), world.liveNodes());
try std.testing.expectEqual(@as(usize, 1), world.componentCount());

// fault levers, as needed:
world.policy.drop_bp = 500;                          // 5% datagram loss
try world.pause(7, 10_000_000);                      // migration-shaped stall
try world.partition(&.{ 1, 2 }, &.{ 3, 4 });         // split + later heal()
world.flaky(3, 3000);                                // one degraded receiver
world.heal();
```

Assertions are over protocol outcomes: membership converges, the
overlay stays one component, exactly-once delivery counts match
(`world.deliveredCount(n)`), asymmetric links never escalate to
false CONFIRM. To prove a property of YOUR composition, add a test to
`tests/sim_scenarios_test.zig` in this shape — the existing tests
(the Ta A/B kill experiment, the fly-migration-pause scenario, the
two-region locality convergence) are the style guide.

Why determinism is not a nicety: when a real fleet misbehaves, you
bisect by replaying the report's shape in the simulator. Every
production incident class this project has hit was first exonerated
or reproduced here — the simulator is the cheap half of diagnosis;
the chaos harness (part 9) is the expensive half that hunts the
transport seam.

## 6. Real QUIC: embedding the Runner

`qmesh_quic.Runner` (`src/quic/loop.zig`) owns one UDP socket, one
QUIC endpoint (a server for inbound plus one client per dial), and
drives the node loop: ingest → handshake advance → protocol service
→ timers → outbound drain, feeding each iteration's observed clock
gap into Lifeguard. Embedding is options-in, hooks-out (trimmed from
`tests/quic_mesh_test.zig`, which runs twelve of these on loopback):

```zig
const runner = try qmesh_quic.Runner.init(allocator, .{
    .endpoint = .{
        .self = .{ .id = my_id, .addr = bind_addr },
        .tls_cert_pem = cert_pem, .tls_key_pem = key_pem, .ca_pem = ca_pem,
        .dial_server_name = "qmesh",       // SNI hint; identity is cert-bound
        .pmtu_max = 1372,                  // deployment MTU minus headers
        .hooks = .{ .ctx = &collector, .onBroadcast = Collector.onBroadcast },
        // per-core configs; qmesh.profiles.fly_multi_region is the
        // tuned multi-region posture
    },
    .bind = bind_addr,
    .control = control_addr,               // optional console/fault socket
});
defer runner.deinit();
try runner.run();                          // blocks until the shutdown flag
// or drive it yourself: runner.step() is one nonblocking pass —
// foreign event loops and tests call step() on their own cadence
```

Reading the seam, briefly — DATAGRAM carries the lossy class
(probes, gossip, IHAVE), one length-prefixed uni-stream per reliable
frame (JOIN, IWANT answers); sessions are cert-bound at handshake
completion; simultaneous dials tiebreak by PeerId to exactly one
connection. `tests/quic_boundary_test.zig` pins the quic-zig API
surface so transport drift fails this repo's build, and
`tests/quic_session_test.zig` exercises two nodes over
`quic.testing.Loopback` with real mutual TLS.

## 7. Deploying (the fly posture)

One process per machine over a private network (fly's 6pn WireGuard,
a VPC, a tailscale-style overlay — anywhere peers are dialable).
The two hard-won rules:

- **`QMESH_PMTU_MAX=1372`** on fly (6pn MTU 1420 − 48 bytes of
  IPv6+UDP headers). Higher caps silently drop full-size packets —
  the failure looks like mysterious 25–45% loss on pristine paths.
- **`fly deploy` resets per-machine env** — re-apply each machine's
  `QMESH_*` set (`fly machine update`) after every deploy, or the
  nodes exit at config parsing. The full procedure, machine
  inventory, and the post-deploy verification command live in
  `deploy/smoke/RUNBOOK.md`.

The smoke image ships `qmesh-top`, so verification from anywhere in
the private network is one command:

```sh
fly ssh console --app qmesh-smoke-nullstyle \
  -C "timeout 10 /qmesh-top '[fdaa:…]:5901' '[fdaa:…]:5901' …"
```

Healthy fleet = every card `alive=N-1 sus=0 dead=0`, full delivery
(`del` matches everyone else's `pub`), `lh=0`, 6/6 completeness.

## 8. Composing with qmsg (carrying real traffic)

qmesh names and watches peers; it does not carry your payloads (see
the boundaries in part 0). The uncoupled composition runs
[qmsg](https://github.com/nullstyle/qmsg) beside it — separate
socket, separate event loop — sharing exactly one thing: the TLS
identity. Both derive the same 64 hex characters from the same
certificate, so `qmesh.PeerId.hex()` == `qmsg.Session.certPeerIdHex()`
and no naming layer is ever invented.

The glue is the embedder-owned directory (`examples/qmsg_directory.zig`,
~200 lines, the pattern to copy):

```text
qmesh Node.aliveMembers()  ->  Directory.reconcile()  ->  qmsg dialQuic()
                                    |
                               lookup(PeerId) -> SessionId
```

Your request path is then: resolve the key's owner through the
directory, `lookup` its qmsg session, send over qmsg's full wire
(1 MiB messages, reliable streams) — while qmesh's failure detector
keeps the directory honest. The number that justifies the whole
design: a death is cluster-agreed in **~5 seconds** (corroborated
suspicion cuts it further), while a per-connection idle timeout
notices the same death in **~30 seconds** and cannot distinguish
"peer gone" from "path gone" at all.

## 9. Chaos campaigns (how much you should trust all this)

The seam between pure cores and real sockets is where every hard bug
in this project has lived — none of them reproduced in the
simulator. Two tools hunt it systematically:

```sh
tools/fleet-soak.sh 30      # no-fault stability + delivery + memory baseline
tools/chaos-run.sh 15 7     # seeded mixed faults: crash/freeze/drop/
                            # blackhole/slow, majority-protected schedule
```

Invariants checked continuously: no false permanent evictions,
re-convergence inside the heal window, ≥90% exactly-once delivery
under faults, bounded RSS with `lh` decay, suspects only inside
fault windows. The layer has earned its keep three times: the
stateless-reset ping-pong, the probe-engine seizure, and the churn
amplifier (a fallback-ingress bug that made six-node fleets
re-dial-loop — two-node fleets were immune, which is exactly the
class of bug only randomized multi-node fault campaigns catch). The
diagnosis ladders and findings are in `tools/chaos-design.md`.

## 10. Hypotheticals — what you'd build on it

These are design sketches, not shipped code. Each names the qmesh
properties it leans on and the honest caveats.

### 10.1 A sharded cache (the flagship composition)

**Shape:** N cache nodes, consistent sharding, membership-driven
rebalancing, broadcast invalidations.

- The **hash ring is `aliveMembers()`** — reconcile on membership
  changes; a dead node's shard drains in ~5s (cluster agreement),
  not the 30s a connection timeout would take. Resurrections return
  shards just as fast.
- **Invalidations ride `publish()`** — Plumtree's eager push fans out
  in milliseconds; lazy IHAVE + IWANT repair covers loss; anti-
  entropy backfills a node that was down mid-invalidation-burst
  (bounded recent window — see caveat).
- **Rendezvous hashing over the alive set** keeps reshuffles minimal:

  ```zig
  fn owner(members: []const qmesh.PeerDesc, key: []const u8) qmesh.PeerId {
      // highest-random-weight: score = hash(id || key), take the max —
      // one hash per candidate, O(N) per lookup, minimal churn on
      // membership change (only the dead node's keys move)
  }
  ```

- **Locality for free:** the RTT matrix (`rtt_min/rtt_max` per
  member, sampled from probe ACKs) lets a client-side directory
  prefer same-region replicas without another measurement layer.

Caveats: qmesh's recent-window anti-entropy is bounded (~32
payloads) — a long-down node that rejoins needs a bulk sync path
(yours, or qmsg); and invalidation broadcast is exactly-once per
message but unordered between concurrent publishers, so version
stamps belong in the payload.

### 10.2 A mesh-native APM (the stack observing itself)

This is the direction `docs/observability-ux.md` documents, and the
first slices already shipped: event rings, the merged timeline,
fingerprints, completeness-honest queries. The hypothetical end
state inverts metric-first UX into incident-first:

- alerts evaluate **inside** the mesh (local rules per node;
  fleet-scoped rules on gossip aggregates — the missing primitive);
- the incident view fuses the three layers no external APM can
  co-locate: mesh events (you have these now), app metrics, and
  traces with cross-region hop annotations computed from the RTT
  matrix ("612ms of this trace's 800ms was the sjc↔iad legs");
- queries broadcast by asking (`qmesh q 'traces duration>500ms last
  5m'`) with completeness metadata — "11/12 answered; edge-2 is
  suspect, its data anti-entropies in when it resumes" — an answer
  that stays honest exactly when a warehouse's intake is degrading.

Needs from the ecosystem: span/trace-id propagation in qmsg (a
header), the gossip-aggregate primitive, and correlation heuristics
grown from the fingerprint rules. The honest boundary is in the doc:
months-long ad-hoc cardinality crunching still wants a columnar
store — slotted in as just another qmsg consumer.

### 10.3 Service discovery / a live registry

The simplest composition: `aliveMembers()` IS the registry, polled
or reconciled into your load-balancer config; `PeerDesc.addr` is
dialable; the RTT matrix ranks region-local instances; the passive
view is a warm standby pool for autoscaling groups to drain into.
Lean on: 5s death agreement, resurrection, exactly-once membership
gossip. Caveat: discovery reads are eventually consistent — don't
put an admission controller's linearizable decisions on it.

### 10.4 Cluster-wide config and feature flags

`publish()` a versioned config blob on change; every node delivers
exactly once, eager fanout in ms, and a node that rebooted mid-roll
backfills through anti-entropy within a period. Membership gates the
audience ("flag on for the cluster" = alive set at publish time).
Caveat: unordered between concurrent publishes — a version/lamport
stamp in the payload is the whole fix; and blobs are bounded small
(1000 B), so ship digests + a fetch path for big configs.

### 10.5 Edge fleets on overlay networks

The fly posture generalizes: anywhere peers get mutually-dialable
addresses (6pn, VPC, tailscale, a management VLAN), one qmesh node
per machine gives failure detection, locality-aware topology, and
broadcast over mTLS with zero extra auth infrastructure — the PKI is
the API key. Watch: MTU math (part 7's 1372 rule is fly-specific,
the arithmetic is not), and NAT'd mutually-undialable edges are out
of scope until a rendezvous/relay story exists (none planned).

### 10.6 What should NOT power (yet)

Kept honest, with what would have to change:

- **Linearizable anything** (locks, leader election with safety
  guarantees): needs a consensus core; qmesh's agreement is
  eventual membership, not total order.
- **Total-order broadcast** (event sourcing, WAL replication):
  Plumtree delivers exactly-once per message in DAG order, not a
  cluster-agreed sequence. A sequencer atop the mesh is buildable
  but is a real distributed-systems project, not a config change.
- **Bulk data transfer**: frames are ~1 KB by design; use qmsg
  beside it.
- **Very high membership churn** (hundreds of join/leave per
  second): SWIM's dissemination and the incarnation lattice are
  built for fleet-scale cadence, not container-per-request churn;
  the sim would be where you'd find out, honestly.

The deferred-with-revive-triggers list (IBLT anti-entropy for large
recent windows, 0-RTT resumption, stream priorities) is in the
README — each names the measurement that would justify pulling it
forward.

## 11. Cheat sheet

```sh
zig build test                                   # everything
./zig-out/bin/qmesh-node --id … --bind … --cert … --key … --ca … \
    --join <id>:<addr> --metrics-secs 2 --publish-every 3 \
    --control '[::1]:5901'
./zig-out/bin/qmesh-top '[::1]:5901' …           # cards + timeline + fingerprints
tools/fleet-soak.sh 30                           # stability baseline
tools/chaos-run.sh 15 7                          # seeded fault campaign
```

| watch | healthy | alarm |
|---|---|---|
| `alive` | N−1 everywhere | disagreeing across nodes during steady state |
| `suspect` | 0 outside fault windows | sustained suspects on a healthy net |
| `lh` | 0 | sustained nonzero — the machine is starving the loop |
| `probes` | climbing | frozen while peers are alive (seizure signature) |
| `rtt_min/max` | stable envelope | drifting up = network or load regression |
| `del` vs others' `pub` | equal | deficit = delivery dips (see `repair` events) |
| fingerprints | quiet | any lead during steady state |

File map (all paths from repo root):

```text
src/hyparview.zig  overlay (pure)         src/swim.zig     membership (pure)
src/plumtree.zig   broadcast (pure)       src/node.zig     driver + transport contract
src/events.zig     event rings + fingerprints   src/metrics.zig  snapshots
src/quic/          real transport + node + console    sim/   deterministic world
tests/sim_scenarios_test.zig   the scenario cookbook
tests/quic_mesh_test.zig       12 nodes over real UDP
examples/qmsg_directory.zig    the composition pattern
deploy/smoke/RUNBOOK.md        the deployment procedure + findings
tools/chaos-design.md          chaos architecture + incident history
docs/observability-ux.md       the mesh-native APM direction
```
