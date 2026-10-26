const std = @import("std");
const qmesh = @import("qmesh");
const mesh = @import("qmesh_quic");
const posix = std.posix;
const a = std.testing.allocator;
const ca = @embedFile("data/ca.pem");
const cert = @embedFile("data/node-a.pem");
const key = @embedFile("data/node-a.key");

fn peer() qmesh.PeerId {
    var id: qmesh.PeerId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143") catch unreachable;
    return id;
}

fn runner() !*mesh.Runner {
    const address = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 0);
    return mesh.Runner.init(a, .{
        .endpoint = .{
            .self = .{ .id = peer(), .addr = address },
            .tls_cert_pem = cert,
            .tls_key_pem = key,
            .ca_pem = ca,
            .dial_server_name = "qmesh-test",
            .swim_cfg = .{ .probe_timeout_us = 20_000 },
        },
        .bind = address,
        .control = address,
    });
}

fn sendTo(socket: posix.socket_t, bytes: []const u8) !void {
    var address: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    if (posix.errno(posix.system.getsockname(socket, @ptrCast(&address), &len)) != .SUCCESS) return error.AddressUnavailable;
    const fd = posix.system.socket(posix.AF.INET, posix.SOCK.DGRAM, @intCast(posix.IPPROTO.UDP));
    if (posix.errno(fd) != .SUCCESS) return error.SocketFailed;
    defer _ = posix.system.close(@intCast(fd));
    if (posix.errno(posix.system.sendto(@intCast(fd), bytes.ptr, bytes.len, 0, @ptrCast(&address), len)) != .SUCCESS) return error.SendFailed;
}

fn sleepUs(us: u64) void {
    var remaining: std.c.timespec = .{ .sec = @intCast(us / std.time.us_per_s), .nsec = @intCast((us % std.time.us_per_s) * std.time.ns_per_us) };
    while (std.c.nanosleep(&remaining, &remaining) != 0) {}
}

fn cpuUs() u64 {
    var now: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(std.c.CLOCK.PROCESS_CPUTIME_ID, &now) == 0);
    return @as(u64, @intCast(now.sec)) * std.time.us_per_s + @as(u64, @intCast(@divTrunc(now.nsec, std.time.ns_per_us)));
}

const Observe = struct {
    started_us: ?u64 = null,
    stop_after_us: u64 = 160_000,
    iterations: usize = 0,
    max_health: u4 = 0,
    fault: enum { none, freeze, slow, callback_stall } = .none,

    fn iteration(context: ?*anyopaque, r: *mesh.Runner, now_us: u64) !void {
        const self: *Observe = @ptrCast(@alignCast(context.?));
        self.iterations += 1;
        self.max_health = @max(self.max_health, r.ep.node.swim.local_health);
        if (self.started_us == null) {
            self.started_us = now_us;
            switch (self.fault) {
                .none => {},
                .freeze => {
                    r.faults.freeze_until_us = now_us + 120_000;
                    // One unread datagram is enough to make a faulty
                    // freeze poll spin continuously on mesh readability.
                    try sendTo(r.readableSockets().mesh, "deliberately queued during freeze");
                },
                .slow => r.faults.delay_us = 120_000,
                .callback_stall => sleepUs(120_000),
            }
        } else {
            if (self.fault == .slow) r.faults.delay_us = 0;
        }
        if (now_us - self.started_us.? >= self.stop_after_us) r.stop();
    }

    fn deadline(context: ?*anyopaque, _: *const mesh.Runner, now_us: u64) ?u64 {
        const self: *Observe = @ptrCast(@alignCast(context.?));
        return if (self.started_us) |start| start + self.stop_after_us else now_us;
    }
};

test "poll timeout rounds future deadlines up and due deadlines stay immediate" {
    const timeout = mesh.loop.waitTimeoutMs;
    try std.testing.expectEqual(@as(i32, 50), timeout(1000, null, 50));
    try std.testing.expectEqual(@as(i32, 0), timeout(1000, 999, 50));
    try std.testing.expectEqual(@as(i32, 0), timeout(1000, 1000, 50));
    try std.testing.expectEqual(@as(i32, 1), timeout(1000, 1001, 50));
    try std.testing.expectEqual(@as(i32, 2), timeout(1000, 2999, 50));
    try std.testing.expectEqual(@as(i32, 50), timeout(1000, std.math.maxInt(u64), 50));
}

test "runner combines core QUIC and application deadlines on one clock" {
    const r = try runner();
    defer r.deinit();
    try r.step(); // consume the initial due core timers
    const now = mesh.Runner.clockUs();
    r.ep.node.swim.next_probe_us = now + 3_000;
    try std.testing.expectEqual(now + 3_000, r.nextDeadline(now).?);
    var observation: Observe = .{ .started_us = now, .stop_after_us = 1_000 };
    r.opts.on_iteration_ctx = &observation;
    r.opts.next_deadline = Observe.deadline;
    try std.testing.expectEqual(now + 1_000, r.nextDeadline(now).?);
    const handles = r.readableSockets();
    try std.testing.expect(handles.mesh != handles.control.?);

    // A fresh dial created after service has immediate work. Once its
    // first flight is sent, its QUIC timer must beat later core timers.
    r.opts.next_deadline = null;
    r.opts.on_iteration = null;
    r.opts.max_wait_ms = 10_000;
    var target = peer();
    target.bytes[0] ^= 1;
    try r.ep.connectPeer(.{ .id = target, .addr = r.localAddress() });
    const dial_now = mesh.Runner.clockUs();
    try std.testing.expectEqual(dial_now, r.nextDeadline(dial_now).?);
    try r.step();
    const after_send = mesh.Runner.clockUs();
    const far = after_send + 20_000_000;
    r.ep.node.swim.next_probe_us = far;
    r.ep.node.overlay.next_shuffle_us = far;
    r.ep.node.overlay.next_scan_us = far;
    r.ep.node.overlay.next_rotate_us = far;
    r.ep.node.broadcast.next_anti_entropy_us = far;
    const transport_deadline = r.ep.sessions.items[0].conn.nextTimerDeadline(after_send).?.at_us;
    try std.testing.expectEqual(transport_deadline, r.nextDeadline(after_send).?);
}

test "step remains nonblocking even when the run wait cap is long" {
    const r = try runner();
    defer r.deinit();
    r.opts.max_wait_ms = 1_000;
    try r.step();
    const before = mesh.Runner.clockUs();
    try r.step();
    try std.testing.expect(mesh.Runner.clockUs() - before < 100_000);
}

test "external poll then step consumes the control datagram and readiness" {
    const r = try runner();
    defer r.deinit();
    const handle = r.readableSockets().control.?;
    try sendTo(handle, "drop 10000 in");
    var ready = [_]posix.pollfd{.{ .fd = handle, .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&ready, 100));
    try r.step();
    try std.testing.expectEqual(@as(u32, 10_000), r.faults.drop_in_bp);
    ready[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&ready, 0));
}

test "intentional normal parks preserve health while legacy callbacks keep their cadence" {
    const r = try runner();
    defer r.deinit();
    var normal: Observe = .{};
    r.opts.on_iteration = Observe.iteration;
    r.opts.on_iteration_ctx = &normal;
    r.opts.next_deadline = Observe.deadline;
    try r.run();
    try std.testing.expect(normal.iterations >= 3 and normal.iterations < 20);
    try std.testing.expectEqual(@as(u4, 0), normal.max_health);

    const legacy = try runner();
    defer legacy.deinit();
    var frequent: Observe = .{ .stop_after_us = 80_000 };
    legacy.opts.on_iteration = Observe.iteration;
    legacy.opts.on_iteration_ctx = &frequent;
    try legacy.run();
    try std.testing.expect(frequent.iterations >= 10);
}

test "freeze ignores queued mesh readability without hiding the stall" {
    const r = try runner();
    defer r.deinit();
    var observation: Observe = .{ .fault = .freeze, .stop_after_us = 170_000 };
    r.opts.on_iteration = Observe.iteration;
    r.opts.on_iteration_ctx = &observation;
    r.opts.next_deadline = Observe.deadline;
    const cpu_before = cpuUs();
    try r.run();
    const cpu_used = cpuUs() - cpu_before;
    try std.testing.expect(observation.max_health > 0);
    try std.testing.expect(observation.iterations < 15);
    // A busy poll of the deliberately queued datagram burns ~120 ms.
    try std.testing.expect(cpu_used < 60_000);
}

test "artificial slow and callback scheduler stalls remain Lifeguard evidence" {
    for ([_]@FieldType(Observe, "fault"){ .slow, .callback_stall }) |fault| {
        const r = try runner();
        defer r.deinit();
        var observation: Observe = .{ .fault = fault, .stop_after_us = 180_000 };
        r.opts.on_iteration = Observe.iteration;
        r.opts.on_iteration_ctx = &observation;
        r.opts.next_deadline = Observe.deadline;
        try r.run();
        try std.testing.expect(observation.max_health > 0);
    }
}

const Worker = struct {
    runner: *mesh.Runner,
    failed: std.atomic.Value(bool) = .init(false),
    fn run(self: *Worker) void {
        self.runner.run() catch self.failed.store(true, .release);
    }
};

const Iterations = struct {
    count: std.atomic.Value(usize) = .init(0),
    fn iteration(context: ?*anyopaque, _: *mesh.Runner, _: u64) !void {
        const self: *Iterations = @ptrCast(@alignCast(context.?));
        _ = self.count.fetchAdd(1, .release);
    }
    fn deadline(_: ?*anyopaque, _: *const mesh.Runner, _: u64) ?u64 {
        return null;
    }
};

test "mesh readability wakes run before a distant timer" {
    const r = try runner();
    defer r.deinit();
    var shutdown = std.atomic.Value(bool).init(false);
    var iterations: Iterations = .{};
    r.opts.shutdown = &shutdown;
    r.opts.max_wait_ms = 500;
    r.opts.on_iteration = Iterations.iteration;
    r.opts.on_iteration_ctx = &iterations;
    r.opts.next_deadline = Iterations.deadline;
    var worker: Worker = .{ .runner = r };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        shutdown.store(true, .release);
        sendTo(r.readableSockets().control.?, "stats") catch {};
        thread.join();
    }
    const start = mesh.Runner.clockUs();
    while (iterations.count.load(.acquire) == 0 and mesh.Runner.clockUs() - start < 1_000_000) sleepUs(1_000);
    sleepUs(10_000);
    const before_count = iterations.count.load(.acquire);
    try std.testing.expectEqual(@as(usize, 1), before_count);
    const sent_at = mesh.Runner.clockUs();
    try sendTo(r.readableSockets().mesh, "read readiness");
    while (iterations.count.load(.acquire) == before_count and mesh.Runner.clockUs() - sent_at < 100_000) sleepUs(1_000);
    try std.testing.expect(iterations.count.load(.acquire) > before_count);
    try std.testing.expect(!worker.failed.load(.acquire));
}

const CallbackPublication = struct {
    peer: qmesh.PeerId,
    ready_at: ?u64 = null,
    published_at: std.atomic.Value(u64) = .init(0),
    fn iteration(context: ?*anyopaque, r: *mesh.Runner, now_us: u64) !void {
        const self: *CallbackPublication = @ptrCast(@alignCast(context.?));
        if (r.ep.node.overlay.inActive(self.peer) == null) return;
        if (self.ready_at == null) self.ready_at = now_us;
        // Let the handshake/HELLO/ACK exchange become quiet first.
        if (self.published_at.load(.acquire) == 0 and now_us >= self.ready_at.? + 120_000) {
            try std.testing.expect(r.ep.publish("queued by on_iteration") != null);
            self.published_at.store(now_us, .release);
        }
    }
    fn deadline(context: ?*anyopaque, _: *const mesh.Runner, _: u64) ?u64 {
        const self: *CallbackPublication = @ptrCast(@alignCast(context.?));
        if (self.published_at.load(.acquire) != 0) return null;
        return if (self.ready_at) |start| start + 120_000 else null;
    }
};

test "frames queued by an application callback leave before the next park" {
    const sender = try runner();
    defer sender.deinit();
    var receiver_id: qmesh.PeerId = undefined;
    _ = try std.fmt.hexToBytes(&receiver_id.bytes, "c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e");
    const Received = struct {
        at: u64 = 0,
        fn broadcast(context: ?*anyopaque, _: qmesh.plumtree.MsgId, payload: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (std.mem.eql(u8, payload, "queued by on_iteration")) self.at = mesh.Runner.clockUs();
        }
    };
    var received: Received = .{};
    const address = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 0);
    const receiver = try mesh.Runner.init(a, .{
        .endpoint = .{
            .self = .{ .id = receiver_id, .addr = address },
            .tls_cert_pem = @embedFile("data/node-b.pem"),
            .tls_key_pem = @embedFile("data/node-b.key"),
            .ca_pem = ca,
            .dial_server_name = "qmesh-test",
            .hooks = .{ .ctx = &received, .onBroadcast = Received.broadcast },
        },
        .bind = address,
    });
    defer receiver.deinit();
    receiver.ep.startJoin(sender.ep.node.selfDesc());
    var publication: CallbackPublication = .{ .peer = receiver_id };
    var shutdown = std.atomic.Value(bool).init(false);
    sender.opts.on_iteration = CallbackPublication.iteration;
    sender.opts.on_iteration_ctx = &publication;
    sender.opts.next_deadline = CallbackPublication.deadline;
    sender.opts.max_wait_ms = 500;
    sender.opts.shutdown = &shutdown;
    var worker: Worker = .{ .runner = sender };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        shutdown.store(true, .release);
        sendTo(sender.readableSockets().control.?, "stats") catch {};
        thread.join();
    }
    const start = mesh.Runner.clockUs();
    while (received.at == 0 and mesh.Runner.clockUs() - start < 5_000_000) {
        try receiver.step();
        const sent_at = publication.published_at.load(.acquire);
        if (sent_at != 0 and mesh.Runner.clockUs() - sent_at >= 100_000) break;
        sleepUs(1_000);
    }
    try std.testing.expect(!worker.failed.load(.acquire));
    try std.testing.expect(publication.published_at.load(.acquire) != 0);
    try std.testing.expect(received.at != 0);
}

test "freeze control wake and atomic shutdown are bounded while mesh traffic stays queued" {
    const r = try runner();
    defer r.deinit();
    var shutdown = std.atomic.Value(bool).init(false);
    r.opts.shutdown = &shutdown;
    r.faults.freeze_until_us = mesh.Runner.clockUs() + 5_000_000;
    try sendTo(r.readableSockets().mesh, "queued during freeze");
    var worker: Worker = .{ .runner = r };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    sleepUs(20_000);
    // A control command must wake the freeze without waiting five seconds.
    try sendTo(r.readableSockets().control.?, "freeze 0");
    sleepUs(20_000);
    const before = mesh.Runner.clockUs();
    shutdown.store(true, .release);
    thread.join();
    const elapsed = mesh.Runner.clockUs() - before;
    try std.testing.expect(!worker.failed.load(.acquire));
    try std.testing.expect(elapsed < 250_000);
    try std.testing.expect(r.faults.freeze_until_us < before);
}
