//! Application-level repair after finite gossip retention. Run through the
//! opt-in tests/composition run-recovery target with a current qmsg source.
//! The localhost fixture blackholes mesh datagrams and pauses the snapshot
//! server's pump. These are local fault controls, not a physical-network test.
const std = @import("std");
const qmesh = @import("qmesh");
const mesh_quic = @import("qmesh_quic");
const messaging = @import("qmesh_messaging");
const qmsg = @import("qmsg");
const state = @import("snapshot_state.zig");
const Req = qmsg.QuicSocket(.req);
const Rep = qmsg.QuicSocket(.rep);
const ca = @embedFile("recovery-pki/ca.pem");
const cert_a = @embedFile("recovery-pki/node-a.pem");
const key_a = @embedFile("recovery-pki/node-a.key");
const cert_b = @embedFile("recovery-pki/node-b.pem");
const key_b = @embedFile("recovery-pki/node-b.key");
const hex_a = "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143";
const hex_b = "c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e";

pub const Options = struct {
    updates: usize = 40,
    eviction_announcements: usize = 40,
    partition_us: u64 = 500_000,
    probe_interval_us: u64 = 100_000,
    request_deadline_ms: u64 = 50,
    max_runtime_us: u64 = 8_000_000,
};

pub const Report = struct {
    converged: bool = false,
    authority_revision: u64 = 0,
    replica_revision: u64 = 0,
    gossip_only_revision: u64 = 0,
    hints_published: usize = 0,
    noise_published: usize = 0,
    hints_evicted: usize = 0,
    hints_delivered_after_heal: usize = 0,
    snapshot_attempts: usize = 0,
    snapshot_timeouts: usize = 0,
    snapshots_applied: usize = 0,
    snapshot_bytes: usize = 0,
    peak_pending_requests: usize = 0,
    peak_pool_entries: usize = 0,
    elapsed_us: u64 = 0,
};

fn peerId(hex: []const u8) qmesh.PeerId {
    var id: qmesh.PeerId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, hex) catch unreachable;
    return id;
}

const Hints = struct {
    latest: u64 = 0,
    delivered: usize = 0,
    fn receive(ctx: ?*anyopaque, _: qmesh.plumtree.MsgId, payload: []const u8) void {
        const self: *Hints = @ptrCast(@alignCast(ctx.?));
        if (state.hintRevision(payload)) |revision| {
            self.latest = @max(self.latest, revision);
            self.delivered += 1;
        }
    }
};

fn makeMesh(a: std.mem.Allocator, hex: []const u8, cert: []const u8, key: []const u8, hints: ?*Hints) !*mesh_quic.Runner {
    const bind = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 0);
    return mesh_quic.Runner.init(a, .{
        .bind = bind,
        .endpoint = .{
            .self = .{ .id = peerId(hex), .addr = bind },
            .tls_cert_pem = cert,
            .tls_key_pem = key,
            .ca_pem = ca,
            .dial_server_name = "qmesh-test",
            .rng_seed = hex[0],
            .overlay_cfg = .{ .active_rotate_period_us = null },
            .broadcast_cfg = .{ .anti_entropy_period_us = 100_000, .ihave_flush_us = 10_000 },
            .hooks = if (hints) |h| .{ .ctx = h, .onBroadcast = Hints.receive } else .{},
        },
    });
}

/// Private facade adapter: Pool owns route demand, QuicSocket owns the entire
/// request engine. There is no second request tracker or private Node access.
const Dialer = struct {
    socket: *Req,
    options: qmsg.node.QuicDialOptions,
    pub fn dial(self: *Dialer, peer: qmesh.PeerId, addr: qmesh.Addr) !u64 {
        var text: [128]u8 = undefined;
        var options = self.options;
        options.expected_peer_spki = peer.bytes;
        return self.socket.dial(try messaging.formatEndpoint(addr, &text), options);
    }
    pub fn status(self: *Dialer, id: u64) ?messaging.SessionStatus {
        const value = self.socket.sessionStatus(id) orelse return null;
        return .{ .state = switch (value.state) {
            .connecting => .connecting,
            .ready => .ready,
            .closing => .closing,
        }, .peer_cert_spki = value.peer_cert_spki };
    }
    pub fn close(self: *Dialer, id: u64) void {
        self.socket.closeSession(id) catch {};
    }
    pub fn findReady(_: *Dialer, _: qmesh.PeerId) ?u64 {
        return null; // This single-peer example owns its outbound route.
    }
};
const Pool = messaging.Pool(Dialer);
const Endpoint = struct {
    addr: qmesh.Addr,
    fn resolve(ctx: ?*anyopaque, peer: qmesh.PeerDesc) !qmesh.Addr {
        if (!peer.id.eql(peerId(hex_a))) return error.UnknownService;
        return @as(*Endpoint, @ptrCast(@alignCast(ctx.?))).addr;
    }
};

fn drain(socket: anytype) !usize {
    var events: [16]qmsg.NodeEvent = undefined;
    const count = try socket.poll(&events);
    for (events[0..count]) |*event| event.deinit();
    return count;
}

/// The foreign owner combines mesh, request/lifecycle, pool and application
/// deadlines. A paused server contributes neither readiness nor stale timers.
fn park(ma: *mesh_quic.Runner, mb: *mesh_quic.Runner, client: *Req, server: *Rep, pool: *Pool, server_paused: bool, deadline_us: u64) !void {
    var fds: [20]std.posix.pollfd = undefined;
    var count: usize = 0;
    for ([_]*mesh_quic.Runner{ ma, mb }) |mesh| {
        fds[count] = .{ .fd = mesh.readableSockets().mesh, .events = std.posix.POLL.IN, .revents = 0 };
        count += 1;
    }
    var handles: [8]std.Io.net.Socket.Handle = undefined;
    const clients = try client.readableSockets(&handles);
    for (handles[0..clients]) |fd| {
        fds[count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        count += 1;
    }
    if (!server_paused) {
        const servers = try server.readableSockets(&handles);
        for (handles[0..servers]) |fd| {
            fds[count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
            count += 1;
        }
    }
    const now = mesh_quic.Runner.clockUs();
    var deadline = @min(deadline_us, now + 10_000);
    if (ma.nextDeadline(now)) |d| deadline = @min(deadline, d);
    if (mb.nextDeadline(now)) |d| deadline = @min(deadline, d);
    if (client.nextTimer()) |d| deadline = @min(deadline, d);
    if (!server_paused) if (server.nextTimer()) |d| {
        deadline = @min(deadline, d);
    };
    if (pool.nextDeadline()) |d| deadline = @min(deadline, d);
    if (deadline <= now) return;
    _ = try std.posix.poll(fds[0..count], @intCast((deadline - now + 999) / 1000));
}

pub fn runScenario(a: std.mem.Allocator, io: std.Io, options: Options) !Report {
    // Bounds also cap the fixed request-outcome ledger, not only wire buffers.
    if (options.updates == 0 or options.updates > 64 or
        options.eviction_announcements < qmesh.plumtree.payload_cache or options.eviction_announcements > 128 or
        options.request_deadline_ms == 0 or options.request_deadline_ms > 200 or
        options.probe_interval_us < options.request_deadline_ms * 1000 or options.probe_interval_us > 500_000 or
        options.partition_us < options.probe_interval_us * 2 or options.partition_us > 2_000_000 or
        options.max_runtime_us < options.partition_us + 1_000_000 or options.max_runtime_us > 30_000_000)
        return error.InvalidOptions;
    const started = mesh_quic.Runner.clockUs();
    const until = started + options.max_runtime_us;
    var report: Report = .{};
    var hints: Hints = .{};
    const ma = try makeMesh(a, hex_a, cert_a, key_a, null);
    defer ma.deinit();
    const mb = try makeMesh(a, hex_b, cert_b, key_b, &hints);
    defer mb.deinit();
    mb.endpoint().startJoin(ma.endpoint().node.selfDesc());
    const node_options: qmsg.node.NodeOptions = .{
        .io = io,
        .max_sessions = 2,
        .max_events = 16,
        .max_requests = 1,
        .max_request_bytes = 1024,
        .max_completion_bytes = 1024,
        .max_event_bytes = 4096,
    };
    var server = try Rep.init(a, .{ .node = node_options });
    defer server.deinit();
    var client = try Req.init(a, .{ .node = node_options });
    defer client.deinit();
    const limits: qmsg.transport.quic.QuicOptions = .{
        .max_message_size = 1024,
        .max_queued_messages = 8,
        .max_queued_bytes = 8192,
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
    var configured: Endpoint = .{ .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, (try server.localAddress(listener)).ip4.port) };
    const resolver: messaging.Resolver = .{ .context = &configured, .resolve = Endpoint.resolve };
    var client_transport = limits;
    client_transport.peer_id = hex_b;
    var dialer: Dialer = .{ .socket = &client, .options = .{
        .server_name = "qmesh-test",
        .identity_verification = .none,
        .ca_pem = ca,
        .client_cert_pem = cert_b,
        .client_key_pem = key_b,
        .transport = client_transport,
    } };
    var pool = try Pool.init(a, .{ .max_peers = 1, .idle_timeout_us = 0, .dial_timeout_us = 2_000_000 });
    defer pool.deinit(&dialer);
    while (true) {
        const now = mesh_quic.Runner.clockUs();
        if (now >= until) return error.ReadinessTimeout;
        try ma.step();
        try mb.step();
        try server.pump(now);
        try client.pump(now);
        const event_count = try drain(&server) + try drain(&client);
        const dials_before = pool.stats.dials;
        const closes_before = pool.stats.closed;
        try pool.service(&mb.endpoint().node, &dialer, resolver, now);
        const ready = if (mb.endpoint().node.member(peerId(hex_a)) != null)
            try pool.ensure(&mb.endpoint().node, &dialer, resolver, peerId(hex_a), now)
        else
            null;
        report.peak_pool_entries = @max(report.peak_pool_entries, pool.count());
        if (ready != null and ma.endpoint().node.member(peerId(hex_b)) != null) break;
        if (event_count != 0 or pool.stats.dials != dials_before or pool.stats.closed != closes_before) continue;
        try park(ma, mb, &client, &server, &pool, false, until);
    }

    const partition_started = mesh_quic.Runner.clockUs();
    const heal_at = partition_started + options.partition_us;
    ma.faults.drop_in_bp = 10_000;
    ma.faults.drop_out_bp = 10_000;
    mb.faults.drop_in_bp = 10_000;
    mb.faults.drop_out_bp = 10_000;
    var authority: state.State = .{};
    var replica: state.State = .{};
    var ids: [64]qmesh.plumtree.MsgId = undefined;
    for (ids[0..options.updates]) |*id| {
        authority.update();
        id.* = ma.endpoint().node.publish(&state.hint(authority.revision)) orelse return error.PublishRejected;
        report.hints_published += 1;
        // Drain each ephemeral send through the blackhole before publishing
        // another. No useful hint is waiting in the transport at heal time.
        try ma.step();
        try mb.step();
    }
    for (0..options.eviction_announcements) |_| {
        _ = ma.endpoint().node.publish("unrelated announcement") orelse return error.PublishRejected;
        report.noise_published += 1;
        try ma.step();
        try mb.step();
    }
    const cache = &ma.endpoint().node.broadcast;
    for (ids[0..options.updates]) |id| {
        for (cache.payloads[0..cache.payloads_len]) |entry| if (entry.id.eql(id)) return error.HintStillRetained;
        report.hints_evicted += 1;
    }
    if (hints.delivered != 0) return error.PartitionLeakedHint;

    var healed = false;
    var next_probe = partition_started;
    var pending: ?qmsg.RequestId = null;
    var wire_id: u64 = 0;
    var completed: [128]bool = @splat(false);
    while (true) {
        const now = mesh_quic.Runner.clockUs();
        if (now >= until) return error.RecoveryTimeout;
        var did_work = false;
        if (!healed and now >= heal_at) {
            // Resume both local paths without publishing a new revision hint.
            ma.faults.clearFlaky();
            mb.faults.clearFlaky();
            healed = true;
            did_work = true;
        }
        try ma.step();
        try mb.step();
        try client.pump(now);
        if (healed) try server.pump(now);
        const dials_before = pool.stats.dials;
        const closes_before = pool.stats.closed;
        try pool.service(&mb.endpoint().node, &dialer, resolver, now);
        var events: [16]qmsg.NodeEvent = undefined;
        if (healed) {
            const count = try server.poll(&events);
            did_work = did_work or count != 0;
            defer for (events[0..count]) |*event| event.deinit();
            for (events[0..count]) |event| if (event == .request) {
                if (!std.mem.eql(u8, event.request.msg.subject, "state.snapshot") or event.request.msg.body.len != 0)
                    return error.InvalidSnapshotRequest;
                // Requests that expired during the pause have no live local
                // demand. Do not resurrect them by replying after recovery.
                if (pending != null and event.request.msg.id == wire_id)
                    try server.reply(event.request.msg.reply_handle.?, .{ .subject = "", .body = &authority.encode() });
            };
        }
        {
            const count = try client.poll(&events);
            did_work = did_work or count != 0;
            defer for (events[0..count]) |*event| event.deinit();
            for (events[0..count]) |event| switch (event) {
                .reply => |reply| {
                    if (pending == null or reply.request_id != pending.? or reply.request_id >= completed.len or completed[reply.request_id])
                        return error.DuplicateOrUnexpectedOutcome;
                    completed[reply.request_id] = true;
                    pending = null;
                    if (!healed or reply.msg.flags.err) return error.InvalidSnapshotReply;
                    try replica.apply(reply.msg.body);
                    report.snapshots_applied += 1;
                    report.snapshot_bytes += reply.msg.body.len;
                },
                .request_failed => |failed| {
                    if (pending == null or failed.request_id != pending.? or failed.request_id >= completed.len or completed[failed.request_id])
                        return error.DuplicateOrUnexpectedOutcome;
                    completed[failed.request_id] = true;
                    pending = null;
                    if (failed.failure != .deadline_exceeded) return error.UnexpectedRequestFailure;
                    report.snapshot_timeouts += 1;
                },
                else => {},
            };
        }
        if (hints.delivered != 0) return error.LateHintRepairedReplica;
        if (healed and replica.revision == authority.revision) break;
        if (pending == null and now >= next_probe) {
            if (report.snapshot_attempts >= 120) return error.AttemptBoundExceeded;
            if (try pool.ensure(&mb.endpoint().node, &dialer, resolver, peerId(hex_a), now)) |session| {
                wire_id += 1;
                pending = try client.request(session, .{
                    .id = wire_id,
                    .subject = "state.snapshot",
                    .body = "",
                    .deadline_ms = options.request_deadline_ms,
                });
                did_work = true;
                report.snapshot_attempts += 1;
                report.peak_pending_requests = 1;
            }
            next_probe = now + options.probe_interval_us;
        }
        report.peak_pool_entries = @max(report.peak_pool_entries, pool.count());
        // Sends and newly created dials need another pump before parking.
        // A transport timer alone does not describe locally queued output.
        if (did_work or pool.stats.dials != dials_before or pool.stats.closed != closes_before) continue;
        var deadline = if (pending == null) @min(until, next_probe) else until;
        if (!healed) deadline = @min(deadline, heal_at);
        try park(ma, mb, &client, &server, &pool, !healed, deadline);
    }
    report.authority_revision = authority.revision;
    report.replica_revision = replica.revision;
    report.gossip_only_revision = hints.latest;
    report.hints_delivered_after_heal = hints.delivered;
    report.elapsed_us = mesh_quic.Runner.clockUs() - started;
    report.converged = std.meta.eql(authority, replica);
    if (!report.converged or report.snapshot_timeouts == 0 or pending != null or
        report.hints_evicted != report.hints_published or report.peak_pool_entries > 1 or
        report.snapshot_attempts != report.snapshot_timeouts + report.snapshots_applied or
        client.stats().events_dropped != 0 or server.stats().events_dropped != 0)
        return error.RecoveryInvariantFailed;
    // One owner releases each event, pool route, socket and runner exactly once.
    return report;
}

pub fn main(init: std.process.Init) !void {
    const report = try runScenario(init.gpa, init.io, .{});
    const json = try std.json.Stringify.valueAlloc(init.gpa, report, .{});
    defer init.gpa.free(json);
    std.debug.print("RECOVERY_WORKLOAD {s}\n", .{json});
}
