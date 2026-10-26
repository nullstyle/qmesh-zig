//! Public messaging facade alongside independently driven mesh runners.
//! Select a Sprint 2 qmsg source and run tests/composition: test-sprint2.
const std = @import("std");
const qmesh = @import("qmesh");
const mesh_quic = @import("qmesh_quic");
const qmsg = @import("qmsg");
const a = std.testing.allocator;

comptime {
    if (!@hasDecl(qmsg, "QuicSocket"))
        @compileError("test-sprint2 requires a qmsg revision exporting QuicSocket");
}

const Req = qmsg.QuicSocket(.req);
const Rep = qmsg.QuicSocket(.rep);
const ca = @embedFile("data/ca.pem");
const cert_a = @embedFile("data/node-a.pem");
const key_a = @embedFile("data/node-a.key");
const cert_b = @embedFile("data/node-b.pem");
const key_b = @embedFile("data/node-b.key");
const hex_a = "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143";
const hex_b = "c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e";

fn peerId(hex: []const u8) qmesh.PeerId {
    var id: qmesh.PeerId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, hex) catch unreachable;
    return id;
}

const Watch = struct {
    expected: qmesh.PeerId,
    discovered: std.atomic.Value(bool) = .init(false),

    fn onIteration(ctx: ?*anyopaque, runner: *mesh_quic.Runner, _: u64) !void {
        const self: *Watch = @ptrCast(@alignCast(ctx.?));
        // The runner thread alone reads its mutable membership table.
        if (runner.endpoint().node.member(self.expected)) |member| {
            if (member.state == .alive) self.discovered.store(true, .release);
        }
    }

    fn nextDeadline(_: ?*anyopaque, _: *const mesh_quic.Runner, _: u64) ?u64 {
        // This observer has no periodic work. Internal mesh/QUIC deadlines
        // and the shutdown bound govern run(), not the legacy callback poll.
        return null;
    }
};

fn makeMesh(hex: []const u8, cert: []const u8, key: []const u8, watch: *Watch, shutdown: *std.atomic.Value(bool)) !*mesh_quic.Runner {
    const bind_addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 0);
    return mesh_quic.Runner.init(a, .{
        .bind = bind_addr,
        .shutdown = shutdown,
        .on_iteration = Watch.onIteration,
        .on_iteration_ctx = watch,
        .next_deadline = Watch.nextDeadline,
        .endpoint = .{
            .self = .{ .id = peerId(hex), .addr = bind_addr },
            .tls_cert_pem = cert,
            .tls_key_pem = key,
            .ca_pem = ca,
            .dial_server_name = "qmesh-test",
            .rng_seed = hex[0],
            .overlay_cfg = .{ .active_rotate_period_us = null },
        },
    });
}

const Worker = struct {
    runner: *mesh_quic.Runner,
    failure: ?anyerror = null,

    fn run(self: *Worker) void {
        self.runner.run() catch |err| {
            self.failure = err;
        };
    }
};

fn park(client: *Req, server: *Rep, until_us: u64) !void {
    var handles: [8]std.Io.net.Socket.Handle = undefined;
    var fds: [16]std.posix.pollfd = undefined;
    var count: usize = 0;
    const client_count = try client.readableSockets(&handles);
    for (handles[0..client_count]) |fd| {
        fds[count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        count += 1;
    }
    const server_count = try server.readableSockets(&handles);
    for (handles[0..server_count]) |fd| {
        fds[count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        count += 1;
    }
    var deadline = until_us;
    if (client.nextTimer()) |d| deadline = @min(deadline, d);
    if (server.nextTimer()) |d| deadline = @min(deadline, d);
    const now = mesh_quic.Runner.clockUs();
    if (deadline <= now) return;
    const timeout_ms: i32 = @intCast(@min(50, (deadline - now + 999) / 1000));
    _ = try std.posix.poll(fds[0..count], timeout_ms);
}

fn discard(socket: anytype) !void {
    var events: [16]qmsg.NodeEvent = undefined;
    const count = try socket.poll(&events);
    for (events[0..count]) |*event| event.deinit();
}

test "Sprint 2 public sockets share an owner clock with deadline-driven mesh runners" {
    var shutdown: std.atomic.Value(bool) = .init(false);
    var watch_a: Watch = .{ .expected = peerId(hex_b) };
    var watch_b: Watch = .{ .expected = peerId(hex_a) };
    const ma = try makeMesh(hex_a, cert_a, key_a, &watch_a, &shutdown);
    defer ma.deinit();
    const mb = try makeMesh(hex_b, cert_b, key_b, &watch_b, &shutdown);
    defer mb.deinit();
    mb.endpoint().startJoin(ma.endpoint().node.selfDesc());

    var worker_a: Worker = .{ .runner = ma };
    var worker_b: Worker = .{ .runner = mb };
    var thread_a: ?std.Thread = null;
    var thread_b: ?std.Thread = null;
    defer {
        shutdown.store(true, .release);
        if (thread_b) |thread| thread.join();
        if (thread_a) |thread| thread.join();
    }
    thread_a = try std.Thread.spawn(.{}, Worker.run, .{&worker_a});
    thread_b = try std.Thread.spawn(.{}, Worker.run, .{&worker_b});

    var server = try Rep.init(a, .{});
    defer server.deinit();
    var client = try Req.init(a, .{});
    defer client.deinit();
    const limits: qmsg.transport.quic.QuicOptions = .{
        .max_message_size = 4 * 1024,
        .max_queued_messages = 16,
        .max_queued_bytes = 64 * 1024,
        .initial_max_streams_bidi = 2,
        .auth_config = .{ .cert_binding = .required },
    };
    var server_transport = limits;
    server_transport.peer_id = hex_a;
    const listener = try server.listen("127.0.0.1:0", .{
        .tls_cert_pem = cert_a,
        .tls_key_pem = key_a,
        .client_ca_pem = ca,
        .transport = server_transport,
    });
    const address = try server.localAddress(listener);
    const until_us = mesh_quic.Runner.clockUs() + 10 * std.time.us_per_s;
    while (!watch_a.discovered.load(.acquire) or !watch_b.discovered.load(.acquire)) {
        if (mesh_quic.Runner.clockUs() >= until_us) return error.MembershipTimeout;
        try server.pump(mesh_quic.Runner.clockUs());
        try discard(&server);
        try park(&client, &server, until_us);
    }

    var endpoint: [64]u8 = undefined;
    const endpoint_text = try std.fmt.bufPrint(&endpoint, "127.0.0.1:{d}", .{address.ip4.port});
    var client_transport = limits;
    client_transport.peer_id = hex_b;
    const session = try client.dial(endpoint_text, .{
        .server_name = "qmesh-test",
        .identity_verification = .none,
        .ca_pem = ca,
        .client_cert_pem = cert_b,
        .client_key_pem = key_b,
        .expected_peer_spki = peerId(hex_a).bytes,
        .transport = client_transport,
    });
    while (true) {
        if (mesh_quic.Runner.clockUs() >= until_us) return error.ReadinessTimeout;
        const now = mesh_quic.Runner.clockUs();
        try server.pump(now);
        try client.pump(now);
        try discard(&server);
        try discard(&client);
        const status = client.sessionStatus(session) orelse return error.PeerClosedBeforeReady;
        if (status.state == .ready) {
            try std.testing.expectEqualSlices(u8, &peerId(hex_a).bytes, &status.peer_cert_spki.?);
            break;
        }
        try park(&client, &server, until_us);
    }

    const message_count = 6;
    const body = "public request after mesh discovery";
    var request_ids: [message_count]qmsg.RequestId = undefined;
    var replied: [message_count]bool = @splat(false);
    for (&request_ids, 0..) |*id, i| id.* = try client.request(session, .{
        .id = 100 + i,
        .subject = "public.echo",
        .body = body,
        .deadline_ms = 5_000,
    });
    var deferred: ?qmsg.ReplyHandle = null;
    defer if (deferred) |*handle| handle.deinit();
    var received: usize = 0;
    var replies: usize = 0;
    var server_session: ?u64 = null;
    var draining = false;
    var goaway_observed = false;
    while (replies != message_count or !goaway_observed) {
        const now = mesh_quic.Runner.clockUs();
        if (now >= until_us) return error.ExchangeTimeout;
        var did_work = false;
        try server.pump(now);
        try client.pump(now);
        var events: [16]qmsg.NodeEvent = undefined;
        {
            const count = try server.poll(&events);
            did_work = count != 0;
            defer for (events[0..count]) |*event| event.deinit();
            for (events[0..count]) |event| if (event == .request) {
                received += 1;
                server_session = event.request.session_id;
                try std.testing.expectEqualStrings(body, event.request.msg.body);
                if (event.request.msg.id == 100) {
                    try std.testing.expect(deferred == null);
                    deferred = event.request.msg.reply_handle.?.retain();
                } else try server.reply(event.request.msg.reply_handle.?, .{ .subject = "", .body = body });
            };
        }
        if (received == message_count and !draining) {
            try server.goaway(server_session.?, 0, "public application drain", now, 3 * std.time.us_per_s);
            draining = true;
            did_work = true;
        }
        {
            const count = try client.poll(&events);
            did_work = did_work or count != 0;
            defer for (events[0..count]) |*event| event.deinit();
            for (events[0..count]) |event| switch (event) {
                .reply => |reply| {
                    try std.testing.expectEqualStrings(body, reply.msg.body);
                    var matched = false;
                    for (request_ids, 0..) |id, i| if (id == reply.request_id) {
                        try std.testing.expect(!replied[i]);
                        replied[i] = true;
                        replies += 1;
                        matched = true;
                        break;
                    };
                    try std.testing.expect(matched);
                },
                .request_failed => return error.RequestFailed,
                .session_goaway => goaway_observed = true,
                else => {},
            };
        }
        if (goaway_observed and deferred != null) {
            try std.testing.expectError(error.EndpointClosed, client.request(session, .{ .subject = "new.work" }));
            try server.reply(deferred.?, .{ .subject = "", .body = body });
            deferred.?.deinit();
            deferred = null;
        }
        // A request/reply/GOAWAY queues work. Pump again before sleeping;
        // transport timers are not a queue-readiness notification.
        if ((replies != message_count or !goaway_observed) and !did_work)
            try park(&client, &server, until_us);
    }
    try std.testing.expectEqual(message_count, received);
    shutdown.store(true, .release);
    thread_b.?.join();
    thread_b = null;
    thread_a.?.join();
    thread_a = null;
    if (worker_a.failure) |err| return err;
    if (worker_b.failure) |err| return err;
}
