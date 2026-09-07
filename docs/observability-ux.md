# qmesh-native observability — UX design

The structural fact this stack builds on: in every other APM the agent
fleet is dumb plumbing feeding a warehouse; here the agent fleet IS
the mesh — self-organizing, failure-detecting, locality-aware — and it
is itself the telemetry transport, the service discovery, and the
trust boundary. The PKI is the API key. Membership is the registry.
The RTT matrix is pre-computed routing metadata. And the observer
observes itself: swim suspicions, Lifeguard health, and delivery
ratios are the first dataset, so the stack's own behavior during an
incident is visible *in* the incident.

## Concept 1 — "Ask the cluster": a live, backend-less console

No warehouse as the primary interface. A console (`qmesh top`, or a
sidecar UI) attaches to any node's control socket and speaks to the
mesh directly — anywhere you can reach one node, you have fleet-wide
sight, because gossip membership makes every node a vantage point.

Interaction model: query-by-asking (`qmesh q 'traces duration>500ms
last 5m'` broadcasts, responses stream back over qmsg sessions, merge
locally). The native UX detail: every answer carries completeness
metadata — "11/12 nodes answered; edge-2 suspect since 14:02, its data
anti-entropies in when it resumes." A warehouse shows whatever
arrived; the mesh-native console says what the cluster knows and
doesn't — and keeps working at partial fidelity during incidents,
when a warehouse's intake is exactly what's degraded.

Trace waterfalls get cross-region hop annotations free from the RTT
matrix: not just "this trace took 800ms" but "612ms of it was the
sjc↔iad legs."

First vertical slice (this doc ships with it): `qmesh top` attaches
to control sockets and renders live fleet cards from metrics
snapshots with the completeness line.

Concept 2's data source also ships: the bounded per-node event ring
(`src/events.zig`) — swim/plumtree/driver transitions recorded at the
exact sites they happen, pure derived state under the cores'
discipline — served by the `events` control query with a
monotonic↔wall clock pairing so `qmesh-top` renders one merged,
wall-clock-ordered fleet timeline beside the cards (and qmesh-node
emits the same ring as `event ...` stderr lines for log-based
correlation). The fusion with app metrics and traces — rule-based
root-cause annotations on top — is the next increment.

## Concept 2 — "The incident timeline": app signals fused with mesh events

Invert the metric-first UX: incident-first. Alerts evaluate INSIDE the
mesh (local rules per node; fleet-scoped rules on gossip-maintained
aggregates). When one fires, the incident view assembles one timeline
from three layers no other stack can co-locate — because no other
stack's failure detector is also the app's cluster:

- the mesh layer (lh transitions, suspicions/refutations, session
  churn, delivery dips — a bounded event ring per node, formalizing
  what swim/plumtree already track);
- the app metrics layer;
- the trace layer, with hops annotated by the RTT matrix.

Result: "why did the error rate spike?" gets answered with membership
causality — "three nodes entered suspicion during a live migration
and delivery dipped to 92%" — automatically. Root-cause annotations
start rule-based (the Lifeguard pause fingerprint, the churn
fingerprints the chaos campaigns encode) and grow into correlation
heuristics.

## Architecture (tiers, all qmesh-native)

- Every qmesh node IS the agent: in-process metrics snapshots and
  quic qlog events (both already built).
- Spans/logs buffer in local rings.
- Region-local rollup sinks attach via the qmsg Directory and ranked
  locality (the nearby collector — the `examples/qmsg_directory.zig`
  pattern).
- Fleet queries and alert-policy changes broadcast over Plumtree;
  bulk payloads ride qmsg sessions.

New library surface needed (modest): a span/trace-id propagation
header in qmsg; the swim/plumtree event ring as a bounded first-class
export; a gossip-aggregate primitive for fleet-scoped alert math.

## Honest boundary

This does not replace warehouse analytics — months-long ad-hoc
cardinality crunching still wants a columnar store, which slots in as
just another qmsg consumer. The bet: attach-anywhere liveness,
completeness-honest queries, and incident timelines with membership
causality are where an APM's daily value lives.
