//! Milestone-2 acceptance: two qmesh nodes exchange a real mesh JOIN
//! over real QUIC — actual TLS (mutual, cluster-CA), actual packet
//! protection, actual DATAGRAM and stream frames — pumped entirely in
//! memory by `quic.testing.Loopback`.
//!
//! Node A listens (quic.Server). Node B dials it (quic.Client) because
//! its overlay emitted a `connect` effect from `startJoin`. The flow
//! this pins end-to-end:
//!
//!   B dial → TLS handshake → HELLO both ways on uni streams (protocol
//!   0x00, identity resolution) → session up → JOIN (reliable, uni
//!   stream + length prefix) → JOIN_ACK → both overlays list each
//!   other active → SHUFFLE over DATAGRAM (ephemeral class).
//!
//! Certificates: tests/data (tools/gen-test-certs.sh). Real mTLS — the
//! server requires client certs against the cluster CA and the client
//! verifies the server against it, no insecure flags. The shared
//! cluster SAN (`DNS:qmesh-test`) is the interim dial-verification
//! posture documented against README gap 2.

const std = @import("std");
const quic = @import("quic");
const qmesh = @import("qmesh");
const qmesh_quic = @import("qmesh_quic");

const testing = std.testing;

const ca_pem = @embedFile("data/ca.pem");
const cert_a = @embedFile("data/node-a.pem");
const key_a = @embedFile("data/node-a.key");
const cert_b = @embedFile("data/node-b.pem");
const key_b = @embedFile("data/node-b.key");

/// Services both endpoints inside Loopback's driver hook; reads the
/// clock straight off the Loopback after wiring.
const MeshDriver = struct {
    a: *qmesh_quic.Endpoint,
    b: *qmesh_quic.Endpoint,
    clock: *u64,

    pub fn service(d: *MeshDriver, srv: *quic.Server) anyerror!void {
        _ = srv;
        try d.a.service(d.clock.*);
        try d.b.service(d.clock.*);
    }
};

fn endpointOptions(self: qmesh.PeerDesc, cert: []const u8, key: []const u8, seed: u64) qmesh_quic.Options {
    return .{
        .self = self,
        .tls_cert_pem = cert,
        .tls_key_pem = key,
        .ca_pem = ca_pem,
        .dial_server_name = "qmesh-test",
        .overlay_cfg = .{
            // Fast clocks so the shuffle/datagram path is exercised
            // within a modest step budget.
            .shuffle_period_us = 100_000,
            .promote_period_us = 50_000,
            .neighbor_timeout_us = 200_000,
            .join_timeout_us = 300_000,
            .active_rotate_period_us = null, // keep the pair stable for assertions
        },
        .rng_seed = seed,
        .now_us = 1_000,
    };
}

test "two-node JOIN over real QUIC with mutual TLS" {
    const allocator = testing.allocator;

    var prng_a = std.Random.DefaultPrng.init(0xa);
    var prng_b = std.Random.DefaultPrng.init(0xb);
    const desc_a = qmesh.PeerDesc{
        .id = qmesh.PeerId.fromRandom(prng_a.random()),
        .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4433),
    };
    const desc_b = qmesh.PeerDesc{
        .id = qmesh.PeerId.fromRandom(prng_b.random()),
        .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4434),
    };

    const a = try qmesh_quic.Endpoint.init(allocator, endpointOptions(desc_a, cert_a, key_a, 1));
    defer a.deinit();
    const b = try qmesh_quic.Endpoint.init(allocator, endpointOptions(desc_b, cert_b, key_b, 2));
    defer b.deinit();

    _ = try a.listen();

    // The join emits `connect` → a real dial (quic.Client) exists.
    b.startJoin(desc_a);
    try testing.expectEqual(@as(usize, 1), b.sessionCount());
    try testing.expectEqual(@as(u64, 1), b.stats.dials);

    const srv = a.server.?;
    const cli = b.sessions.items[0].client.?;

    var lb = try quic.testing.Loopback.init(.{
        .allocator = allocator,
        .server = srv,
        .client = cli,
    });
    defer lb.deinit();

    var driver = MeshDriver{ .a = a, .b = b, .clock = &lb.now_us };
    try lb.handshake(&driver);
    try testing.expect(cli.conn.handshakeDone());
    try testing.expectEqual(@as(usize, 1), srv.iterator().len);

    // HELLO both ways, JOIN, JOIN_ACK: drive until both overlays hold
    // the other as active — the full mesh-join state machine over the
    // real transport.
    var steps: usize = 0;
    while (steps < 20_000) : (steps += 1) {
        const a_ready = a.node.overlay.inActive(desc_b.id) != null;
        const b_ready = b.node.overlay.inActive(desc_a.id) != null;
        if (a_ready and b_ready) break;
        try lb.step(&driver);
    }
    try testing.expect(a.node.overlay.inActive(desc_b.id) != null);
    try testing.expect(b.node.overlay.inActive(desc_a.id) != null);
    try testing.expect(a.establishedWith(desc_b.id));
    try testing.expect(b.establishedWith(desc_a.id));
    try testing.expect(a.stats.hellos_received >= 1);
    try testing.expect(b.stats.hellos_received >= 1);
    try testing.expect(a.stats.stream_frames_received >= 1); // HELLO + JOIN rode streams

    // Drive past one shuffle period: the ephemeral class (DATAGRAM)
    // must carry SHUFFLE/SHUFFLE_REPLY between the pair.
    while (lb.now_us < 400_000) try lb.step(&driver);
    try testing.expect(a.node.overlay.stats.shuffles_received >= 1);
    try testing.expect(b.node.overlay.stats.shuffles_received >= 1);
    try testing.expect(a.stats.datagrams_received >= 1);
    try testing.expect(b.stats.datagrams_received >= 1);

    // Overlay invariants hold exactly as in the simulator.
    a.node.overlay.checkInvariants();
    b.node.overlay.checkInvariants();
}

test "peer close severs the session and demotes the overlay edge" {
    const allocator = testing.allocator;

    var prng_a = std.Random.DefaultPrng.init(0xc);
    var prng_b = std.Random.DefaultPrng.init(0xd);
    const desc_a = qmesh.PeerDesc{
        .id = qmesh.PeerId.fromRandom(prng_a.random()),
        .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4435),
    };
    const desc_b = qmesh.PeerDesc{
        .id = qmesh.PeerId.fromRandom(prng_b.random()),
        .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4436),
    };

    const a = try qmesh_quic.Endpoint.init(allocator, endpointOptions(desc_a, cert_a, key_a, 3));
    defer a.deinit();
    const b = try qmesh_quic.Endpoint.init(allocator, endpointOptions(desc_b, cert_b, key_b, 4));
    defer b.deinit();
    _ = try a.listen();

    b.startJoin(desc_a);
    const srv = a.server.?;
    const cli = b.sessions.items[0].client.?;
    var lb = try quic.testing.Loopback.init(.{
        .allocator = allocator,
        .server = srv,
        .client = cli,
    });
    defer lb.deinit();
    var driver = MeshDriver{ .a = a, .b = b, .clock = &lb.now_us };

    try lb.handshake(&driver);
    var steps: usize = 0;
    while (steps < 20_000 and (a.node.overlay.inActive(desc_b.id) == null or
        b.node.overlay.inActive(desc_a.id) == null)) : (steps += 1)
    {
        try lb.step(&driver);
    }
    try testing.expect(a.establishedWith(desc_b.id));

    // B goes away cleanly. A must observe the close, drop the session,
    // and demote B from active to passive — the same state transition
    // the simulator's session-down path proves.
    cli.conn.close(false, 0, "leaving");
    var td: usize = 0;
    while (td < 10_000 and a.establishedWith(desc_b.id)) : (td += 1) {
        try lb.step(&driver);
        lb.now_us += 10_000;
        try srv.tick(lb.now_us);
        _ = srv.reap();
    }

    try testing.expect(!a.establishedWith(desc_b.id));
    try testing.expect(a.node.overlay.inActive(desc_b.id) == null);
    try testing.expect(a.node.overlay.inPassive(desc_b.id) != null);
    try testing.expect(a.stats.sessions_closed >= 1);
    a.node.overlay.checkInvariants();
}
