# Sprint 3: reliable publication and snapshot recovery

Sprint 2 was committed locally before this work began:

| Repository | Sprint 2 commit |
| --- | --- |
| quic-zig | `c74110a94667dd155068b862cb7a966aadbe7697` |
| qmsg | `941eef6b65deb250d2e5ee56637523be9eec5527` |
| qmesh-zig | `35b4e914e5457157649bbc07c367b569382f1851` |

The coordinated Sprint 3 scope is:

- qmsg: reliable QUIC publication with source filtering, resubscription on
  reconnect, and bounded slow-consumer behavior that does not block healthy peers.
- qmesh: a recovery application in which mesh announcements hint at state
  changes and qmsg requests retrieve authoritative snapshots after missed hints.
- QUIC: profile those real application workloads against the public transport
  pin and the selected candidate; investigate demonstrated bottlenecks or
  regressions before considering implementation changes.

The recovery gate includes a partition longer than gossip retention. Convergence
must follow from bounded, deadline-limited snapshot reconciliation even when no
new announcement arrives after the partition heals. Gossip remains a bounded
dissemination mechanism; the example owns application versions, snapshot
validation and reconciliation policy. Application endpoints come from explicit
configuration through the existing resolver.

Reliable publication reuses qmsg's framing and canonical delivery ownership.
Subscriptions filter at the source. Admission and queue policy are explicit:
transport reliability does not imply durable replay of publications discarded
before stream admission. Existing datagram publication remains available.

## Integration checkpoint

The opt-in `test-sprint3` target runs both public application workloads beside
the original module-identity and pool/restart tests. The checker selects a qmsg
working tree explicitly and validates both native QUIC v0.37.2 and one selected
QUIC source with the same dependency options and module identity:

```sh
mise exec -- python3 tools/check-composition.py --sprint2 --sprint3 \
  --optimize Debug --qmsg-path ../qmsg --quic-path ../quic-zig --jobs 2
mise exec -- python3 tools/check-composition.py --sprint2 --sprint3 \
  --optimize ReleaseSafe --qmsg-path ../qmsg --quic-path ../quic-zig --jobs 2
```

Reports identify compiler binaries, commits and working-tree digests, transport
and crypto pins, commands, executed versus cached tests, failures and skips.
Profiling separates cold connection setup from warm application exchanges and
records completion and queue counters alongside local timing, CPU and RSS.
Performance observations apply to their recorded host and workload.

For an individual development run from a composition workspace configured with
the explicit source paths, use:

```sh
QMSG_RUN_LIVE_UDP=1 mise exec -- zig build run-pubsub-workload \
  -Doptimize=ReleaseSafe -Dlocal-quic=true -- --publications 24
mise exec -- zig build run-recovery -Doptimize=ReleaseSafe -Dlocal-quic=true
mise exec -- zig build install-workloads -Doptimize=ReleaseSafe \
  -Dlocal-quic=true --prefix /absolute/path/to/workload-binaries
```

The publication CLI emits `PUBSUB_WORKLOAD` JSON after executing the workload;
its environment guard otherwise prints instructions without running UDP.
Recovery emits `RECOVERY_WORKLOAD` JSON. The install target permits timed runs
of exact executable bytes outside the build process. Repeat installation with
`-Dlocal-quic=false` and a separate prefix for the native-pin comparison.

The default publication scenario attempts 24 matching publications for three
subscribers, holds one subscriber, checks 48 healthy deliveries and bounded
per-peer pressure, then reconnects without a new subscription call. The recovery
scenario loses and evicts 40 revision hints, exercises request deadlines during
an outage, and retrieves a fixed 81-byte snapshot after healing without another
useful hint. Its configured pool and pending-request bounds are both one.

## Transport baseline finding

Prompt snapshot retries exposed an inherited QUIC idle-cache defect. Stream-limit
notifications and public stream-credit grants could be queued while a cached
idle flag remained set. The selected QUIC source repairs those transitions and
adds deterministic bidi/uni regressions. Released v0.37.2 remains unchanged and
has retained Debug assertion reproductions; a timing-dependent passing retry
does not clear that finding. Final reports distinguish this baseline limitation
from the repaired candidate's application results.

Public pins and versions remain unchanged. Dynamic endpoint advertisements,
live CREDIT/push-pull, survey/bus patterns, extra codecs and evented-backend
adoption remain outside this sprint. The inherited QUIC fairness promotion hold
and release qualification remain separate. Local checks do not establish hosted
CI, native Windows or physical-network acceptance.
