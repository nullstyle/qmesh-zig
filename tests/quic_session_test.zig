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

// Provisioned PeerIds: SHA-256 of each node certificate's DER
// SubjectPublicKeyInfo, computed with the standard fingerprint
// pipeline —
//   openssl x509 -in node-X.pem -pubkey -noout \
//     | openssl pkey -pubin -outform DER | openssl dgst -sha256
// The session layer must resolve connections to exactly these ids
// (identity is cert-bound, not announced).
const digest_a_hex = "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143";
const digest_b_hex = "c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e";

fn idFromHex(hex: []const u8) qmesh.PeerId {
    var id: qmesh.PeerId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, hex) catch unreachable;
    return id;
}

test "PeerId.fromCertPem is the provisioned SPKI digest of the node certificate" {
    const from_a = try qmesh.PeerId.fromCertPem(testing.allocator, cert_a);
    try testing.expect(from_a.eql(idFromHex(digest_a_hex)));
    const from_b = try qmesh.PeerId.fromCertPem(testing.allocator, cert_b);
    try testing.expect(from_b.eql(idFromHex(digest_b_hex)));
    try testing.expect(!from_a.eql(from_b));
    // The CA certificate is a different key; a chain file yields its
    // first (leaf) block.
    try testing.expect(!(try qmesh.PeerId.fromCertPem(testing.allocator, ca_pem)).eql(from_a));
    const chain = cert_a ++ ca_pem;
    try testing.expect((try qmesh.PeerId.fromCertPem(testing.allocator, chain)).eql(from_a));
    // Not a PEM block, not base64, and a truncated DER body are refused,
    // never read past their end.
    try testing.expectError(error.InvalidPem, qmesh.PeerId.fromCertPem(testing.allocator, "not a certificate"));
    try testing.expectError(error.InvalidPem, qmesh.PeerId.fromCertPem(testing.allocator, "-----BEGIN CERTIFICATE-----\n@@@@\n-----END CERTIFICATE-----\n"));
    const truncated = comptime blk: {
        // The first 96 base64 characters of the body (a whole DER prefix,
        // padding-correct) and nothing after them.
        const marker = "-----BEGIN CERTIFICATE-----";
        const body = cert_a[std.mem.indexOf(u8, cert_a, marker).? + marker.len ..];
        var head: [96]u8 = undefined;
        var n = 0;
        for (body) |c| {
            if (n == head.len) break;
            if (std.ascii.isWhitespace(c)) continue;
            head[n] = c;
            n += 1;
        }
        break :blk marker ++ "\n" ++ head ++ "\n-----END CERTIFICATE-----\n";
    };
    try testing.expectError(error.InvalidCertificate, qmesh.PeerId.fromCertPem(testing.allocator, truncated));
}

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

    const desc_a = qmesh.PeerDesc{
        .id = idFromHex(digest_a_hex),
        .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4433),
    };
    const desc_b = qmesh.PeerDesc{
        .id = idFromHex(digest_b_hex),
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
    // The overlay edges are keyed by the CERT-DERIVED ids — the
    // provisioned digests above — proving identity binding end to end.
    try testing.expect(a.node.overlay.inActive(desc_b.id) != null);
    try testing.expect(b.node.overlay.inActive(desc_a.id) != null);
    try testing.expect(a.establishedWith(desc_b.id));
    try testing.expect(b.establishedWith(desc_a.id));
    try testing.expectEqual(@as(u64, 0), a.stats.identity_mismatches);
    try testing.expect(a.stats.hellos_received >= 1);
    try testing.expect(b.stats.hellos_received >= 1);
    try testing.expect(a.stats.stream_frames_received >= 1); // HELLO + JOIN rode streams

    // Whole-node metrics over the real transport: the snapshot sees
    // both layers (protocol counters + transport gauges).
    const a_metrics = a.metrics();
    try testing.expectEqual(@as(usize, 1), a_metrics.transport.established);
    try testing.expect(a_metrics.transport.hellos_received >= 1);
    try testing.expect(a_metrics.mesh.driver.frames_received >= 1); // the JOIN
    try testing.expectEqual(@as(usize, 1), a_metrics.mesh.overlay.active);

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

    const desc_a = qmesh.PeerDesc{
        .id = idFromHex(digest_a_hex),
        .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4435),
    };
    const desc_b = qmesh.PeerDesc{
        .id = idFromHex(digest_b_hex),
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

const NoMesh = struct {
    pub fn service(_: *NoMesh, _: *quic.Server) !void {}
};

/// Both protocol endpoints are real; only the UDP path is in memory.
const Pair = struct {
    allocator: std.mem.Allocator,
    a: *qmesh_quic.Endpoint,
    b: *qmesh_quic.Endpoint,
    lb: quic.testing.Loopback,
    driver: MeshDriver,

    fn init(allocator: std.mem.Allocator, target: ?qmesh.PeerId, stream_credit: ?u64) !*Pair {
        const desc_a: qmesh.PeerDesc = .{ .id = idFromHex(digest_a_hex), .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4433) };
        const desc_b: qmesh.PeerDesc = .{ .id = idFromHex(digest_b_hex), .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4434) };
        var a_options = endpointOptions(desc_a, cert_a, key_a, 1);
        if (stream_credit) |credit| a_options.reliable_receive_window = credit;
        const a = try qmesh_quic.Endpoint.init(allocator, a_options);
        errdefer a.deinit();
        const b = try qmesh_quic.Endpoint.init(allocator, endpointOptions(desc_b, cert_b, key_b, 2));
        errdefer b.deinit();
        const srv = try a.listen();
        var contact = desc_a;
        contact.id = target orelse desc_a.id;
        try b.connectPeer(contact);
        const p = try allocator.create(Pair);
        errdefer allocator.destroy(p);
        p.* = .{
            .allocator = allocator,
            .a = a,
            .b = b,
            .lb = try quic.testing.Loopback.init(.{ .allocator = allocator, .server = srv, .client = b.sessions.items[0].client.? }),
            .driver = undefined,
        };
        errdefer p.lb.deinit();
        p.driver = .{ .a = a, .b = b, .clock = &p.lb.now_us };
        var no_mesh: NoMesh = .{};
        try p.lb.handshake(&no_mesh);
        return p;
    }

    fn ready(p: *Pair) !void {
        for (0..20_000) |_| {
            if (p.a.establishedWith(p.b.opts.self.id) and p.b.establishedWith(p.a.opts.self.id)) return;
            try p.lb.step(&p.driver);
        }
        return error.SessionNotReady;
    }

    fn deinit(p: *Pair) void {
        p.lb.deinit();
        p.b.deinit();
        p.a.deinit();
        p.allocator.destroy(p);
    }
};

test "a CA-valid connection must match the intended mesh peer" {
    const p = try Pair.init(testing.allocator, .{ .bytes = @splat(77) }, null);
    defer p.deinit();
    try p.b.service(p.lb.now_us);
    try testing.expectEqual(@as(u64, 1), p.b.stats.identity_mismatches);
    try testing.expect(!p.b.establishedWith(p.a.opts.self.id));
    try testing.expectEqual(@as(u64, 0), p.b.node.stats.sessions_up);
    try testing.expectEqual(@as(u64, 0), p.b.node.stats.sessions_down);
}

test "HELLO survives one-byte stream credit without truncation or duplication" {
    const p = try Pair.init(testing.allocator, null, 1);
    defer p.deinit();
    try p.b.service(p.lb.now_us);
    // QUIC may admit the entire write locally; the negotiated window
    // forces its delivery to arrive incrementally at the peer.
    try testing.expectEqual(@as(u64, 1), p.b.stats.hellos_sent);
    try p.ready();
    try testing.expectEqual(@as(u64, 1), p.b.stats.hellos_sent);
}

test "authenticated HELLO refreshes contact while membership stays alive" {
    const p = try Pair.init(testing.allocator, null, null);
    defer p.deinit();
    try p.ready();
    var moved = p.b.opts.self;
    moved.addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 5000);
    var buf: [qmesh.frame.max_frame_len]u8 = undefined;
    const hello = try qmesh_quic.hello.encode(.{ .desc = moved }, &buf);
    try p.b.sendReliable(p.a.opts.self.id, hello);
    for (0..1000) |_| {
        try p.lb.step(&p.driver);
        if (p.a.node.member(moved.id).?.desc.addr.eql(moved.addr)) break;
    }
    const member = p.a.node.member(moved.id).?;
    try testing.expect(member.desc.addr.eql(moved.addr));
    try testing.expectEqual(qmesh.MemberState.alive, member.state);
    try testing.expectEqual(qmesh.ContactSource.authenticated, member.contact_source);
}

test "bad stream framing closes only the offending mesh session" {
    const p = try Pair.init(testing.allocator, null, null);
    defer p.deinit();
    try p.ready();
    const conn = p.b.sessions.items[0].conn;
    const stream = try conn.openNextUni();
    _ = try conn.streamWrite(stream.id, &.{ 255, 255 }); // beyond frame budget
    try conn.streamFinish(stream.id);
    for (0..1000) |_| {
        try p.lb.step(&p.driver);
        if (p.a.stats.protocol_errors != 0) break;
    }
    try testing.expectEqual(@as(u64, 1), p.a.stats.protocol_errors);
    try testing.expect(!p.a.establishedWith(p.b.opts.self.id));
    // service returned successfully to the caller despite malformed input.
}

test "incomplete streams fill the stream window with no refusal and no lost peer" {
    const p = try Pair.init(testing.allocator, null, null);
    defer p.deinit();
    try p.ready();
    const window = qmesh_quic.endpoint.meshTransportParams(p.a.opts.pmtu_max).initial_max_streams_uni;
    const conn = p.b.sessions.items[0].conn;
    // Each stream holds a place in A's window until it ends. B opens
    // one for every place. When its quic says that the window is full
    // (temporary), B waits for A to give the ids of closed streams back.
    var opened: u64 = 0;
    var waits: usize = 0;
    while (opened < window) {
        const stream = conn.openNextUni() catch |err| {
            try testing.expectEqual(error.StreamLimitExceeded, err);
            waits += 1;
            if (waits > 1000) return error.TestUnexpectedResult;
            try p.lb.step(&p.driver);
            continue;
        };
        _ = try conn.streamWrite(stream.id, &.{1}); // keep the length prefix incomplete
        opened += 1;
    }
    // A's receive table has a slot for each place: it tracks them all.
    const a_driver = &p.a.sessions.items[0].driver.?;
    for (0..1000) |_| {
        if (a_driver.table.count() == window) break;
        try p.lb.step(&p.driver);
    }
    try testing.expectEqual(window, a_driver.table.count());
    try testing.expectEqual(@as(u64, 0), p.a.stats.streams_refused);
    try testing.expectEqual(@as(u64, 0), p.a.stats.protocol_errors);
    try testing.expect(p.a.establishedWith(p.b.opts.self.id));
    // While those streams stay open, B's own frames wait for a place.
    for (0..200) |_| try p.lb.step(&p.driver);
    var buf: [qmesh.frame.max_frame_len]u8 = undefined;
    const hello = try qmesh_quic.hello.encode(.{ .desc = p.b.opts.self }, &buf);
    try testing.expectError(error.StreamLimitExceeded, p.b.sendReliable(p.a.opts.self.id, hello));
    try testing.expectEqual(@as(u64, 0), p.a.stats.streams_refused);
}

test "a burst of reliable frames as large as the stream window is delivered in full" {
    const p = try Pair.init(testing.allocator, null, null);
    defer p.deinit();
    try p.ready();
    const window = qmesh_quic.endpoint.meshTransportParams(p.a.opts.pmtu_max).initial_max_streams_uni;
    const b_conn = p.b.sessions.items[0].conn;
    const hellos_before = p.a.stats.hellos_received;
    var buf: [qmesh.frame.max_frame_len]u8 = undefined;
    const hello = try qmesh_quic.hello.encode(.{ .desc = p.b.opts.self }, &buf);
    // Fill every place B has in A's window before A services once, so A
    // sees all these streams open in one pass. The send after the last
    // place waits: the sender sees StreamLimitExceeded at once (it is
    // temporary), and A never refuses a stream and loses its frame.
    var sent: u64 = 0;
    const err = while (sent <= window) : (sent += 1) {
        p.b.sendReliable(p.a.opts.self.id, hello) catch |e| break e;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(error.StreamLimitExceeded, err);
    // A gives ids back in batches of half a window, so at least half of
    // it was free.
    try testing.expect(sent >= window / 2);
    for (0..2000) |_| {
        if (p.a.stats.hellos_received - hellos_before == sent) break;
        try p.lb.step(&p.driver);
    }
    try testing.expectEqual(sent, p.a.stats.hellos_received - hellos_before);
    try testing.expectEqual(@as(u64, 0), p.a.stats.streams_refused);
    // The places come back as the streams close.
    for (0..2000) |_| {
        if (b_conn.local_uni_ids.limit > b_conn.local_uni_ids.opened) break;
        try p.lb.step(&p.driver);
    }
    try p.b.sendReliable(p.a.opts.self.id, hello);
    for (0..2000) |_| {
        if (p.a.stats.hellos_received - hellos_before == sent + 1) break;
        try p.lb.step(&p.driver);
    }
    try testing.expectEqual(sent + 1, p.a.stats.hellos_received - hellos_before);
    try testing.expectEqual(@as(u64, 0), p.a.stats.streams_refused);
    try testing.expectEqual(@as(u64, 0), p.a.stats.protocol_errors);
    try testing.expect(p.a.establishedWith(p.b.opts.self.id));
}

test "a peer cannot open a bidirectional stream: the mesh advertises no bidi window" {
    const p = try Pair.init(testing.allocator, null, null);
    defer p.deinit();
    try p.ready();
    const b_conn = p.b.sessions.items[0].conn;
    const a_conn = p.a.sessions.items[0].conn;
    // qmesh frames travel only on unidirectional streams. With no bidi
    // window, a bidi stream cannot take a slot in A's receive table:
    // B's quic refuses to open one, and A's quic closes a connection
    // whose peer opens one anyway (STREAM_LIMIT_ERROR).
    try testing.expectEqual(@as(u64, 0), a_conn.peer_bidi_ids.limit);
    try testing.expectEqual(@as(u64, 0), b_conn.local_bidi_ids.limit);
    try testing.expectError(error.StreamLimitExceeded, b_conn.openNextBidi());
    for (0..100) |_| try p.lb.step(&p.driver);
    try testing.expectEqual(@as(u64, 0), p.a.stats.streams_refused);
    try testing.expectEqual(@as(u64, 0), p.a.stats.protocol_errors);
    try testing.expect(p.a.establishedWith(p.b.opts.self.id));
    try testing.expect(p.b.establishedWith(p.a.opts.self.id));
    // A peer that opens one anyway (here B's quic is told that A gave
    // it a place) loses the connection before A's driver sees it.
    b_conn.local_bidi_ids.limit = 1;
    const stream = try b_conn.openNextBidi();
    _ = try b_conn.streamWrite(stream.id, &.{ 0, 1, 2 });
    for (0..1000) |_| {
        if (!p.a.establishedWith(p.b.opts.self.id)) break;
        try p.lb.step(&p.driver);
    }
    try testing.expect(!p.a.establishedWith(p.b.opts.self.id));
    const close = a_conn.closeEvent().?;
    try testing.expectEqual(quic.CloseSource.local, close.source);
    try testing.expectEqual(quic.Connection.transport_error_stream_limit, close.error_code);
    try testing.expectEqual(@as(u64, 0), p.a.stats.streams_refused);
}

// A node accepts and dials on ONE socket. Since quic-zig v0.26.0 a
// server's first flight is 1200 bytes, and through v0.28.1 a Server made
// a half-open connection from it (`feed` said `.accepted`), so a node
// that gave every datagram to its server first never let its dial see
// the answer. `Runner.ingest` gives a dial its own datagrams first since
// then. Since v0.29.0 `feed` makes no connection for a datagram of which
// no packet opens, and says `.dropped`, so the runner's second route (a
// dropped datagram goes to the dial aimed at its source) reaches the dial
// too. This test takes only that second route: every datagram of A's
// side goes to B's own server first and to B's dial only on `.dropped`.
test "a peer server's datagrams make no slot in the dialer's server, and the dial completes" {
    const allocator = testing.allocator;
    const desc_a = qmesh.PeerDesc{
        .id = idFromHex(digest_a_hex),
        .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4437),
    };
    const desc_b = qmesh.PeerDesc{
        .id = idFromHex(digest_b_hex),
        .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4438),
    };
    const addr_a: quic.Address = .{ .ipv4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 4437 } };
    const addr_b: quic.Address = .{ .ipv4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 4438 } };

    const a = try qmesh_quic.Endpoint.init(allocator, endpointOptions(desc_a, cert_a, key_a, 5));
    defer a.deinit();
    const b = try qmesh_quic.Endpoint.init(allocator, endpointOptions(desc_b, cert_b, key_b, 6));
    defer b.deinit();
    const srv_a = try a.listen();
    const srv_b = try b.listen();

    b.startJoin(desc_a);
    const cli = b.sessions.items[0].client.?;
    try cli.conn.advance();

    const now: u64 = 1_000;
    var buf: [4096]u8 = undefined;
    var copy: [4096]u8 = undefined;
    var to_dial: usize = 0;
    var largest: usize = 0;
    var steps: usize = 0;
    while (!cli.conn.handshakeDone()) : (steps += 1) {
        if (steps == 64) return error.HandshakeStalled;
        while (try cli.conn.poll(&buf, now)) |len| _ = try srv_a.feed(buf[0..len], addr_b, now);
        for (srv_a.iterator()) |slot| {
            while (try slot.conn.poll(&buf, now)) |len| {
                // `feed` takes the bytes mutable: the dial gets a copy.
                @memcpy(copy[0..len], buf[0..len]);
                try testing.expectEqual(quic.Server.FeedOutcome.dropped, try srv_b.feed(buf[0..len], addr_a, now));
                try testing.expectEqual(@as(usize, 0), srv_b.iterator().len);
                try cli.conn.handle(copy[0..len], addr_a, now);
                to_dial += 1;
                largest = @max(largest, len);
            }
        }
    }
    // The server's first flight was among them: a datagram of 1200 bytes,
    // which passes a server's Initial size gate.
    try testing.expect(to_dial >= 1);
    try testing.expect(largest >= 1200);
    try testing.expectEqual(@as(usize, 0), srv_b.iterator().len);
    try testing.expectEqual(@as(usize, 1), srv_a.iterator().len);
}
