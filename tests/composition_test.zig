//! Actual qmesh discovery and qmsg traffic using one QUIC module instance.
//! Run from tests/composition; both local and released QUIC are supported.
const std = @import("std");
const qmesh = @import("qmesh");
const qmesh_quic = @import("qmesh_quic");
const messaging = @import("qmesh_messaging");
const qmsg = @import("qmsg");
const a = std.testing.allocator;
const ca = @embedFile("data/ca.pem");
const cert_a = @embedFile("data/node-a.pem");
const key_a = @embedFile("data/node-a.key");
const cert_b = @embedFile("data/node-b.pem");
const key_b = @embedFile("data/node-b.key");
const patterns = qmsg.control.PatternBits.req | qmsg.control.PatternBits.rep;

fn idFromHex(hex: []const u8) qmesh.PeerId {
    var id: qmesh.PeerId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, hex) catch unreachable;
    return id;
}
const id_a = idFromHex("48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143");
const id_b = idFromHex("c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e");
const Dialer = messaging.QmsgDialer(qmsg);
const Pool = messaging.Pool(Dialer);

fn meshRunner(id: qmesh.PeerId, cert: []const u8, key: []const u8, port: u16) !*qmesh_quic.Runner {
    const addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, port);
    return qmesh_quic.Runner.init(a, .{
        .bind = addr,
        .endpoint = .{
            .self = .{ .id = id, .addr = addr },
            .tls_cert_pem = cert,
            .tls_key_pem = key,
            .ca_pem = ca,
            .dial_server_name = "qmesh-test",
            .rng_seed = port,
            .overlay_cfg = .{ .active_rotate_period_us = null },
        },
    });
}

fn echo(ctx: *qmsg.Context, incoming: qmsg.Message) !void {
    var owned = incoming;
    defer owned.deinit();
    try ctx.reply(.{ .subject = "", .body = incoming.body });
}

fn startServer(server: *qmsg.App, addr: ?qmesh.Addr) !qmesh.Addr {
    server.* = try qmsg.App.init(a, .{});
    errdefer server.deinit();
    try server.rep("echo", echo);
    var buf: [64]u8 = undefined;
    const listener = try server.listenQuic(if (addr) |address| try messaging.formatEndpoint(address, &buf) else "127.0.0.1:0", .{
        .cert_pem = cert_a,
        .key_pem = key_a,
        .client_ca_pem = ca,
        .quic = .{
            .peer_id = "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143",
            .role_flags = qmsg.control.RoleFlags.server,
            .supported_patterns = patterns,
            .max_idle_timeout_ms = 1_000,
            .auth_config = .{ .cert_binding = .required },
        },
    });
    const local = server.node.quic_listeners.items[listener].localAddress().ip4;
    return qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, local.port);
}

const ServiceLocation = struct {
    addr: qmesh.Addr,
    fn resolve(context: ?*anyopaque, _: qmesh.PeerDesc) !qmesh.Addr {
        const self: *ServiceLocation = @ptrCast(@alignCast(context.?));
        return self.addr;
    }
    fn resolver(self: *ServiceLocation) messaging.Resolver {
        return .{ .context = self, .resolve = resolve };
    }
};

const Drive = struct {
    mesh_a: *qmesh_quic.Runner,
    mesh_b: *qmesh_quic.Runner,
    server: *qmsg.App,
    client: *qmsg.Node,
    pool: *Pool,
    dialer: *Dialer,
    location: *ServiceLocation,
    now_us: u64 = 1_000,

    fn step(self: *Drive) !void {
        try self.mesh_a.step();
        try self.mesh_b.step();
        self.now_us += 1_000;
        try self.server.node.tick(self.now_us);
        _ = try self.server.runOnce();
        try self.client.tick(self.now_us);
        try self.pool.service(&self.mesh_b.ep.node, self.dialer, self.location.resolver(), self.now_us);
    }

    fn ready(self: *Drive, previous: ?u64) !u64 {
        for (0..20_000) |_| {
            try self.step();
            if (self.pool.lookup(id_a)) |id| if (previous == null or previous.? != id) return id;
            // Readiness is queried through status; poll ownership stays
            // with the application and this drain cannot steal replies.
            var events: [16]qmsg.NodeEvent = undefined;
            const n = try self.client.poll(&events);
            for (events[0..n]) |*event| event.deinit();
        }
        return error.ReadinessTimeout;
    }

    fn exchange(self: *Drive, session: u64, message_id: u64) !void {
        const request_id = try self.client.request(.{ .quic = session }, .{ .id = message_id, .subject = "echo", .body = "mesh discovered, qmsg delivered", .deadline_ms = 5_000 });
        for (0..20_000) |_| {
            try self.step();
            var events: [16]qmsg.NodeEvent = undefined;
            const n = try self.client.poll(&events);
            defer for (events[0..n]) |*event| event.deinit();
            var replied = false;
            for (events[0..n]) |*event| {
                switch (event.*) {
                    .reply => |reply| {
                        try std.testing.expectEqual(request_id, reply.request_id);
                        try std.testing.expectEqual(@as(?u64, session), reply.session_id);
                        try std.testing.expectEqual(message_id, reply.msg.id);
                        try std.testing.expectEqualStrings("mesh discovered, qmsg delivered", reply.msg.body);
                        replied = true;
                    },
                    .request_failed, .quic_request_failed => return error.RequestFailed,
                    else => {},
                }
            }
            if (replied) return;
        }
        return error.ReplyTimeout;
    }
};

test "mesh membership composes with qmsg ready sessions and independent restarts" {
    const ma = try meshRunner(id_a, cert_a, key_a, 0);
    defer ma.deinit();
    const mb = try meshRunner(id_b, cert_b, key_b, 0);
    defer mb.deinit();
    mb.ep.startJoin(ma.ep.node.selfDesc());
    var joined = false;
    for (0..20_000) |_| {
        try ma.step();
        try mb.step();
        if (mb.ep.node.member(id_a)) |member| if (member.state == .alive) {
            joined = true;
            break;
        };
    }
    try std.testing.expect(joined);

    var server: qmsg.App = undefined;
    var location: ServiceLocation = .{ .addr = try startServer(&server, null) };
    var server_live = true;
    defer if (server_live) server.deinit();
    var client = try qmsg.Node.init(a, .{});
    defer client.deinit();
    var dialer: Dialer = .{ .node = &client, .options = .{
        .server_name = "qmesh-test",
        .identity_verification = .none,
        .ca_pem = ca,
        .client_cert_pem = cert_b,
        .client_key_pem = key_b,
        .transport = .{ .peer_id = "c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e", .supported_patterns = patterns, .required_peer_patterns = patterns, .max_idle_timeout_ms = 1_000 },
    } };
    var pool = try Pool.init(a, .{ .retry_initial_us = 1_000, .retry_max_us = 100_000, .idle_timeout_us = 0 });
    defer pool.deinit(&dialer);
    var drive: Drive = .{ .mesh_a = ma, .mesh_b = mb, .server = &server, .client = &client, .pool = &pool, .dialer = &dialer, .location = &location };

    try std.testing.expectEqual(null, try pool.ensure(&mb.ep.node, &dialer, location.resolver(), id_a, 0));
    const first = try drive.ready(null);
    try drive.exchange(first, 41);

    // qmsg session loss alone must not require a membership transition.
    try client.closeQuicSession(first);
    const second = try drive.ready(first);
    try std.testing.expectEqual(qmesh.MemberState.alive, mb.ep.node.member(id_a).?.state);
    try drive.exchange(second, 42);

    // Restart the application listener at the same address with the same
    // certificate while the separate mesh remains continuously alive.
    server.deinit();
    server_live = false;
    location.addr = try startServer(&server, location.addr);
    server_live = true;
    const third = try drive.ready(second);
    try std.testing.expectEqual(qmesh.MemberState.alive, mb.ep.node.member(id_a).?.state);
    try drive.exchange(third, 43);

    // A new application endpoint is discovered through the resolver; no
    // gossip port arithmetic and no membership churn is necessary.
    server.deinit();
    server_live = false;
    location.addr = try startServer(&server, null);
    server_live = true;
    const fourth = try drive.ready(third);
    try drive.exchange(fourth, 44);
    try std.testing.expect(pool.stats.endpoint_changes > 0);

    // The resolver points member B at A's perfectly valid cluster endpoint.
    // CA validation alone would accept A; expected-peer verification must
    // prevent the pool from ever exposing that connection as member B.
    var wrong_pool = try Pool.init(a, .{ .retry_initial_us = 1_000, .retry_max_us = 100_000 });
    defer wrong_pool.deinit(&dialer);
    _ = try wrong_pool.ensure(&ma.ep.node, &dialer, location.resolver(), id_b, drive.now_us);
    for (0..100) |_| {
        try drive.step();
        try wrong_pool.service(&ma.ep.node, &dialer, location.resolver(), drive.now_us);
        try std.testing.expectEqual(null, wrong_pool.lookup(id_b));
    }
    try std.testing.expect(wrong_pool.stats.dial_failures > 0);
}

test "composition shares the exact QUIC Connection type" {
    const Sessions = @FieldType(qmesh_quic.Endpoint, "sessions");
    const SessionPointer = @typeInfo(@FieldType(Sessions, "items")).pointer.child;
    const Session = @typeInfo(SessionPointer).pointer.child;
    const MeshConnection = @typeInfo(@FieldType(Session, "conn")).pointer.child;
    try std.testing.expect(MeshConnection == qmsg.transport.quic_runtime.Connection);
}
