# Messaging between mesh members

Import `qmesh_messaging` to combine qmesh membership with application sessions.
The mesh core remains independent of qmsg. The concrete adapter receives the
consumer's existing qmsg module, so it never creates another copy of its types.

```zig
const qmesh_dep = b.dependency("qmesh", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("qmesh_messaging", qmesh_dep.module("qmesh_messaging"));
```

```zig
const qmsg = @import("qmsg");
const messaging = @import("qmesh_messaging");

const local_peer_hex = local_peer_id.hex();
var dialer = messaging.QmsgDialer(qmsg){
    .node = &message_node,
    .options = .{
        .server_name = "cluster",
        .identity_verification = .none,
        .ca_pem = cluster_ca,
        .client_cert_pem = cert,
        .client_key_pem = key,
        .transport = .{
            .peer_id = &local_peer_hex, // the local certificate's SPKI identity
            .supported_patterns = qmsg.control.PatternBits.req | qmsg.control.PatternBits.rep,
            .required_peer_patterns = qmsg.control.PatternBits.req | qmsg.control.PatternBits.rep,
        },
    },
};
var pool = try messaging.Pool(@TypeOf(dialer)).init(allocator, .{
    .max_peers = 64,
    .idle_timeout_us = 60_000_000,
});
defer pool.deinit(&dialer);

// After driving mesh and qmsg with their respective clocks:
try pool.service(&mesh.node, &dialer, resolver, now_us);
if (try pool.ensure(&mesh.node, &dialer, resolver, peer_id, now_us)) |session| {
    _ = try message_node.request(.{ .quic = session }, outgoing);
}
```

`Resolver` contains an optional context pointer and a function returning an
application `qmesh.Addr` for a `PeerDesc`. Supply it from deployment config or
service discovery. There is no default relationship between the mesh port and
the application port. Returned addresses are copied; resolver state is borrowed.

## Session and membership contracts

`ensure` starts or renews demand. It returns null while connection establishment
or retry is pending. A returned session has completed TLS and qmsg HELLO and
its certificate SPKI digest matches the requested PeerId. The adapter sets
qmsg's `expected_peer_spki` constraint before dialing; the pool also checks the
observed identity before exposing the mapping. Configured message authorization
still applies independently of membership and certificate identity.

`service` refreshes only demanded peers. It never dials every discovered member.
It uses `Node.member(peer)` point lookups, so a truncated enumeration cannot be
mistaken for removal. Suspected members keep existing sessions; new dials pause
until they are alive again. Confirmed-dead or removed members lose their pool
entries. A changing application endpoint replaces a pool-owned connection.

The pool observes session status directly. It does not consume Node events, so
application replies and lifecycle events remain available to the caller. An
independent qmsg session failure triggers bounded exponential retry without
requiring a mesh membership transition. Dial attempts have a timeout. The
configured peer limit bounds all outstanding demand and retry state.

A closing/draining qmsg session becomes unavailable for new pool requests,
but routine refresh does not close it: qmsg owns the bounded GOAWAY grace and
QUIC close deadline, allowing accepted requests to finish. Once qmsg removes
the session, normal pool retry resumes. Explicit `forget`, endpoint replacement,
confirmed membership loss and idle eviction still follow the pool's ownership
policy. Combine qmsg deadlines with `Pool.nextDeadline`; a drain is not a dial
timeout.

An existing authenticated ready session can be adopted without dialing. Adopted
sessions remain owned by the messaging Node: forgetting or evicting their pool
entry does not close them. The pool closes sessions it dialed on replacement,
eviction, explicit `forget`, or `deinit`. Destroy the pool before the Node.

`lookup` reports the result of the last service pass; it is not a promise that
the network is still reachable. Requests always need their own deadlines. Call
`ensure` to renew an entry's idle lease before new traffic, including when a
cached session is already ready. Set `idle_timeout_us=0` for workloads that keep
long-lived operations and manage eviction themselves.

Drive the pool with a monotonic microsecond clock. `nextDeadline` reports retry,
dial-timeout and idle-eviction wakeups; combine it with messaging and mesh
deadlines. A backwards timestamp returns `ClockMovedBackwards`.

## Migration from the old directory example

The former `Directory.reconcile(aliveMembers(...))` example has been replaced
by this supported module. Replace eager reconciliation with `service` and
explicit `ensure` calls. Replace gossip-port offsets with a resolver. Only
ready sessions are returned; the return value of `dialQuic` is a pending session
identifier, not a usable route. Use `Node.members` when an application needs
enumeration; its result reports completeness and preserves suspect/dead state.

PeerId is derived from the certificate public key. Certificate renewal with
the same key retains identity; key rotation creates a different PeerId and
must be treated as membership replacement or handled by a higher-level logical
identity mapping.

## Validation and local development

`zig build test` runs the bounded pool's deterministic contract tests with the
rest of qmesh. From `tests/composition`, run:

```sh
mise run test
mise run test-released
mise run test-qmsg
```

This consumer uses the local qmesh checkout and exact URL/hash pins for qmsg
and QUIC. It needs no sibling checkouts. `test` injects one selected QUIC
module into both upper modules. By default that source is the newer v0.42.2
transport; the libraries' public manifests remain on v0.37.2. `test-released` leaves each library's own released
QUIC dependency in place; the type-identity test must still prove there is
one `quic.Connection` type. `test-qmsg` runs qmsg's module tests with the
selected QUIC source, including the separate QUIC runtime and independent Node
UDP suites. `test-qmsg-runtime` and `test-qmsg-pairs` run those roots individually.
Both upper libraries pass the identical
`{ target, release = optimize != Debug, sanitize-c = "trap" }` option map.
The QUIC pin fixes the BoringSSL source too. Public package manifests retain
their URL/hash pins; the development test package is excluded from archives.

From the qmesh root, run the complete matrix with bounded compiler parallelism:

```sh
mise run check-sprint1
```

The wrapper stages an isolated consumer, runs both modes plus qmsg's module
suite, and records commands, exit codes, build/test counts, compiler binary
hash, manifest/package hashes, transport/crypto pins, and working-tree source
digests under `.zig-cache/composition/<UTC time>/`. It also runs qmesh's
full suite and binary build when given `--core`. An override changes only the
staged manifest, so no intermediate release or sibling mutation is needed:

```sh
mise exec -- python3 tools/check-composition.py --core --optimize Debug \
  --qmsg-path ../qmsg --quic-path ../quic-zig
mise exec -- python3 tools/check-composition.py --optimize ReleaseSafe \
  --qmsg-path ../qmsg --quic-archive /absolute/path/quic-candidate.tar.gz \
  --quic-hash '<Zig package hash printed by zig fetch>'
```

`--mode released|selected` narrows a run; by default both run. A selected
QUIC override is used only in selected mode. A qmsg override participates in
both modes so its native released dependency and the selected transport are
both exercised. Dirty checkouts are identified by their actual file-content
digest in addition to HEAD and status. The wrapper verifies an archive's Zig
package hash before extracting its source and records the archive SHA-256.
Alternatively pass `--quic-sha256 '<64 hexadecimal digits>'` instead of
`--quic-hash` to verify exact archive bytes without running Zig's package
rehash. The chosen integrity check and extracted source digest are recorded.
It never changes the checked-in manifests. The pinned toolchain is tagged Zig
0.17.0 for the core and composition workspace.

`.github/workflows/composition.yml` runs the pinned-source matrix on Linux and
macOS in Debug and ReleaseSafe and retains the evidence. A local run does not
establish that hosted CI passed. Current local results are recorded in
[`sprint-1-evidence.md`](sprint-1-evidence.md).

The integration test establishes real mesh membership with mutual TLS, sends
qmsg requests through the peer pool, loses a qmsg session, restarts the
application listener while the mesh stays alive, changes the application
endpoint, and verifies that the recovered routes still exchange messages.
