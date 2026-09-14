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

That workspace-only consumer imports qmesh, qmsg and QUIC from sibling repos.
The default overrides both upper modules with the same local QUIC module so
coordinated changes can be tested without publishing an intermediate release.
The second invocation validates their released QUIC dependency instead; the
third runs qmsg's module tests with the selected QUIC implementation. Public
package manifests retain URL/hash pins; workspace path dependencies exist only
in this development test package, which is excluded from release archives.
The local mise configuration selects the newer compiler required by qmsg;
the rest of qmesh continues to build with its own pinned compiler.

The integration test establishes real mesh membership with mutual TLS, sends
qmsg requests through the peer pool, loses a qmsg session, restarts the
application listener while the mesh stays alive, changes the application
endpoint, and verifies that the recovered routes still exchange messages.
