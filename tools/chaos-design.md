# Chaos testing design (real-seam fault injection)

## Why

Every transport-seam bug this project has found — the stateless-reset
ping-pong, the dead-stream decoder cap on lazy delivery, the
session-record leak — reproduced ONLY over the real stack; the
deterministic simulator was clean each time (its fault levers model
the cores, not the seam). The chaos tool exists to hunt that layer
systematically: real `qmesh-node` processes, real QUIC/TLS/sockets,
randomized fault schedules, continuous invariant checks.

Layer split (keep it): **sim** = deterministic proof of the pure
cores; **chaos** = randomized exploration of the real seam;
**fleet-soak** = the chaos tool's no-fault ancestor (stability +
delivery + memory baseline).

## Architecture

```text
tools/chaos-run.sh (driver: seeded schedule, control client, harvest)
   │ spawns N qmesh-node (--control '[::1]:PORT' each)
   │ sends fault commands, collects metrics lines
   ▼
qmesh-node --control ... (in-process fault knobs, OFF unless flagged)
   freeze / drop / blackhole / crash … applied inside the Runner loop
```

**In-process fault injection, not OS-level.** No pf/ipfw/root, exact
semantics, and the loop consults the knobs where the traffic actually
flows: `freeze` skips loop iterations (the wall clock advances, so
Lifeguard sees the gap through the existing `noteAppDelay` feed —
freeze exercises exactly the stall machinery), `drop_in` drops in
`ingest` after recvfrom, `drop_out` drops in `drainOutbound` before
sendto, `blackhole <peer> [in|out]` is the one-way-link fault,
`crash` exits the process (the driver restarts it after a dwell).

Control protocol: one UDP datagram per command to the node's control
port (`freeze 3000`, `drop 1500 in`, `blackhole <hex> out`, `clear`,
`stats`); replies none. Tiny, text, grep-able.

New surface: `Runner.Options.faults: ?*FaultKnobs` (shared struct the
control listener mutates; the loop reads) — opt-in, null by default,
zero cost when absent. The control listener is a second bound UDP
socket drained once per iteration (nonblocking recvfrom, ≤16
commands/iteration, bounded).

## Fault classes → mechanisms probed

| fault            | what it exercises                                          |
|------------------|------------------------------------------------------------|
| crash + restart  | confirm consensus, Ta, resurrection, join-retry, RSS slope |
| freeze (SIGSTOP-like, in-loop) | Lifeguard gap feeding, suspicion windows, idle timeouts, peer view of a stalled node |
| drop in/out (bp) | probe ACK loss, refutation delivery, IHAVE/IWANT repair, anti-entropy as backstop |
| one-way blackhole| PING_REQ indirect probing, asymmetric table states         |
| slow (inject iteration delay) | local-health growth without full stall             |
| concurrent multi-victim | quorum integrity: majority must never be confirmed |

## Invariants (checked continuously from harvested metrics lines)

1. **Watchdog**: an unfrozen node emits metrics within 3× its
   interval — catches livelock/deadlock.
2. **No false permanent eviction**: after faults clear + heal window,
   every live node holds every other live node non-`dead`.
3. **Re-convergence bound**: membership + overlay re-agree within a
   fixed wall budget after `clear` (targets from the fly evidence:
   ~90 s consensus, ~2 min full recovery).
4. **Delivery window ratio**: publishes during fault-free stretches
   reach ≥90% promptly, ~100% after the settle window.
5. **Bounded resources**: RSS slope under threshold across the run;
   `lh` returns to 0 within a decay window after faults clear.
6. **Suspects correlate**: suspicion/confirm bursts only during fault
   windows (a burst outside them is a finding, not noise).

## Driver schedule

Seeded PRNG (reproducible: rerun with the same seed): every 2–8 s
pick a victim (weighted: crash 25 %, freeze 20 %, drop-burst 20 %,
blackhole 15 %, slow 10 %, clear/heal 10 %); never fault a majority
simultaneously (≤ ⌈N/2⌉−1 concurrent victims); crash dwell 5–60 s.
Default campaign: 12 nodes × 30 min; report per-invariant pass/fail
with the schedule log attached for replay.

## Phases

1. **Fault knobs + control channel** in `qmesh-node`/Runner (small,
   unit-testable: freeze/drop/blackhole behave; knobs null →
   zero-change hot path).
2. **Driver** (`tools/chaos-run.sh`): spawn/control/harvest/report.
3. **First campaign**: 12 × 30 min mixed faults; triage anything the
   invariants flag; expected yield: seam bugs of the classes this
   session found manually.
4. **Later, if wanted**: longer/nightly campaigns and a chaos mode
   for the fly app (machines stop/start are already proven levers).

## Non-goals

No kernel-level partitions or latency shaping (OS privileges,
non-portable); no fault injection inside the pure cores (that is the
simulator's job); no unbounded schedules (majority protection is a
driver invariant, not a protocol claim).

## Campaign 1 findings (seed 42, 10 min) — OPEN

Invariants 1-4 and 6 passed (full re-convergence in the heal window,
~100% delivery, lh decay, suspect correlation). Two findings:

1. **RSS balloon, node-e: 267MB vs ~33MB siblings.** The correlated
   schedule froze node-e nearly continuously, then crash-restarted
   it late. Its own counters are calm (sessrec 12-13, shed 0,
   ep_dgram_rx normal, closes 12) — no connection explosion at the
   endpoint layer. Unexplained; needs a deterministic repro plus
   heap profiling (MallocStackLogging) to split real leak vs
   allocator retention of a transient storm (the restart wake
   processes a socket backlog of peer Initials; each half-open
   handshake slot carries a full TLS context).

2. **Probe-engine seizure, same node — FIXED.** After its late
   restart, `probes_sent` froze while `acks_tx` kept climbing: the
   node stopped probing entirely while otherwise healthy. Root cause
   (reproduced deterministically with a freeze storm + a stall
   detector in the metrics loop): a probe armed while Lifeguard
   local-health was stall-inflated bakes in a 2^lh × floor deadline
   (~100s at lh=7); lh then decays but the armed deadline never
   re-evaluates, so the engine sits silent on a clean link. Fix:
   every tick re-clamps the armed deadline to now + the CURRENT
   budget. A second contaminant found on the way: freeze-gap ACKs
   sampled as multi-second "RTT" polluted the EMA and inflated every
   rtt-keyed budget — samples beyond the Lifeguard-scaled floor are
   now discarded, and a wildly-stale EMA snaps to the next clean
   sample. Verified: the same freeze storm that seized five times
   now runs stall-free with probes resuming after heal.

Driver fix needed before deeper campaigns: the awk victim draws
correlate on some seeds (linear seed mixing) — hammering one node;
mix the seed properly (e.g. multiply and xorshift per draw).
