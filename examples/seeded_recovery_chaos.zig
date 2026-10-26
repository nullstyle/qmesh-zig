//! Seeded logical chaos over four real localhost mesh nodes. Fault controls are
//! local fixture operations, not OS-process crashes or a physical network test.
const std = @import("std");
const qmesh = @import("qmesh");
const mesh = @import("qmesh_quic");
const messaging = @import("qmesh_messaging");
const qmsg = @import("qmsg");
const schema = @import("snapshot_state.zig");
const plans = @import("chaos_plan.zig");
const Req = qmsg.QuicSocket(.req);
const Rep = qmsg.QuicSocket(.rep);
const Action = plans.Action;
pub const replay_seeds = plans.replay_seeds;
pub const Options = struct {
    seed: u64 = plans.default_seed,
    phase_timeout_us: u64 = 8_000_000,
    max_runtime_us: u64 = 40_000_000,
    probe_interval_us: u64 = 100_000,
    request_deadline_ms: u64 = 100,
};
pub const Report = struct {
    seed: u64,
    plan_fingerprint: u64,
    final_state_hash: u64 = 0,
    logical_actions_completed: usize = 0,
    converged: bool = false,
    authority_revision: u64 = 0,
    replica_revisions: [3]u64 = @splat(0),
    snapshot_attempts: usize = 0,
    snapshot_timeouts: usize = 0,
    snapshots_applied: usize = 0,
    snapshot_replies: usize = 0,
    stale_snapshots_rejected: usize = 0,
    request_backpressure: usize = 0,
    request_peer_closures: usize = 0,
    application_restarts: usize = 0,
    endpoint_moves: usize = 0,
    suspect_preserved_routes: usize = 0,
    suspect_new_dials_paused: usize = 0,
    dead_route_removals: usize = 0,
    absent_route_removals: usize = 0,
    stale_endpoint_rejected: bool = false,
    wrong_identity_rejected: bool = false,
    decoy_positive_control_ready: bool = false,
    hints_evicted: usize = 0,
    hints_delivered_after_heal: usize = 0,
    peak_pending_requests_per_replica: usize = 0,
    peak_pool_entries_per_replica: usize = 0,
    peak_total_pool_entries: usize = 0,
    peak_mesh_session_records: usize = 0,
    peak_mesh_server_slots: usize = 0,
    elapsed_us: u64 = 0,
};
const ca = @embedFile("recovery-pki/ca.pem");
const Identity = struct { cert: []const u8, key: []const u8, hex: []const u8 };
const identities = [_]Identity{
    .{ .cert = @embedFile("recovery-pki/node-a.pem"), .key = @embedFile("recovery-pki/node-a.key"), .hex = "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143" },
    .{ .cert = @embedFile("recovery-pki/node-b.pem"), .key = @embedFile("recovery-pki/node-b.key"), .hex = "c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e" },
    .{ .cert = @embedFile("recovery-pki/node-c.pem"), .key = @embedFile("recovery-pki/node-c.key"), .hex = "dc1d0a48ff1bf15cd5ae2c4f2a338fa1baab5ae5be7da6a1f7e62364789e5777" },
    .{ .cert = @embedFile("recovery-pki/node-d.pem"), .key = @embedFile("recovery-pki/node-d.key"), .hex = "6d36cf37f9409c27571667756307520f39c7846d9696bd16ff8a3c45c318c8d3" },
};
fn id(index: usize) qmesh.PeerId {
    var peer: qmesh.PeerId = undefined;
    _ = std.fmt.hexToBytes(&peer.bytes, identities[index].hex) catch unreachable;
    return peer;
}
const Observer = struct {
    hints: usize = 0,
    fn receive(ctx: ?*anyopaque, _: qmesh.plumtree.MsgId, payload: []const u8) void {
        const self: *Observer = @ptrCast(@alignCast(ctx.?));
        if (schema.hintRevision(payload) != null) self.hints += 1;
    }
};
fn makeMesh(a: std.mem.Allocator, plan: plans.Plan, owner: usize, generation: u64, observer: *Observer) !*mesh.Runner {
    const address = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 0);
    return mesh.Runner.init(a, .{ .bind = address, .endpoint = .{
        .self = .{ .id = id(owner), .addr = address },
        .tls_cert_pem = identities[owner].cert,
        .tls_key_pem = identities[owner].key,
        .ca_pem = ca,
        .dial_server_name = "qmesh-test",
        .rng_seed = plan.mesh_seeds[owner],
        .boot_epoch = (@as(u128, plan.seed) << 64) | generation,
        .overlay_cfg = .{ .active_max = 3, .active_min = 2, .shuffle_period_us = 300_000, .promote_period_us = 100_000, .neighbor_timeout_us = 500_000, .join_timeout_us = 1_000_000, .active_rotate_period_us = 500_000 },
        .swim_cfg = .{ .probe_period_us = 150_000, .probe_timeout_us = 300_000, .indirect_timeout_us = 300_000, .suspicion_timeout_us = 800_000, .max_local_health = 3, .dead_probe_every = 2, .ta_min_corroborators = 2 },
        .broadcast_cfg = .{ .anti_entropy_period_us = 200_000, .ihave_flush_us = 10_000 },
        .hooks = .{ .ctx = observer, .onBroadcast = Observer.receive },
    } });
}
const Dialer = struct {
    socket: *Req,
    options: qmsg.node.QuicDialOptions,
    dials: usize = 0,
    pub fn dial(self: *Dialer, peer: qmesh.PeerId, address: qmesh.Addr) !u64 {
        var text: [128]u8 = undefined;
        var options = self.options;
        options.expected_peer_spki = peer.bytes;
        self.dials += 1;
        return self.socket.dial(try messaging.formatEndpoint(address, &text), options);
    }
    pub fn status(self: *Dialer, session: u64) ?messaging.SessionStatus {
        const status_now = self.socket.sessionStatus(session) orelse return null;
        return .{ .state = switch (status_now.state) {
            .ready => .ready,
            .connecting => .connecting,
            .closing => .closing,
        }, .peer_cert_spki = status_now.peer_cert_spki };
    }
    pub fn close(self: *Dialer, session: u64) void {
        self.socket.closeSession(session) catch {};
    }
    pub fn findReady(_: *Dialer, _: qmesh.PeerId) ?u64 {
        return null;
    }
};
const Pool = messaging.Pool(Dialer);
const Location = struct {
    address: qmesh.Addr,
    fn resolve(ctx: ?*anyopaque, peer: qmesh.PeerDesc) !qmesh.Addr {
        if (!peer.id.eql(id(0))) return error.UnknownService;
        return @as(*Location, @ptrCast(@alignCast(ctx.?))).address;
    }
    fn resolver(self: *Location) messaging.Resolver {
        return .{ .context = self, .resolve = resolve };
    }
};
fn nodeOptions(io: std.Io) qmsg.node.NodeOptions {
    return .{ .io = io, .max_sessions = 8, .max_events = 16, .max_requests = 1, .max_request_bytes = 1024, .max_completion_bytes = 1024, .max_event_bytes = 4096 };
}
fn limits(owner: usize) qmsg.transport.quic.QuicOptions {
    return .{ .peer_id = identities[owner].hex, .max_message_size = 1024, .max_queued_messages = 8, .max_queued_bytes = 8192, .initial_max_streams_bidi = 2, .auth_config = .{ .cert_binding = .required } };
}
fn listen(server: *Rep, owner: usize, address: qmesh.Addr) !qmesh.Addr {
    var text: [128]u8 = undefined;
    const listener = try server.listen(try messaging.formatEndpoint(address, &text), .{
        .tls_cert_pem = identities[owner].cert,
        .tls_key_pem = identities[owner].key,
        .client_ca_pem = ca,
        .transport = limits(owner),
    });
    return qmesh.Addr.fromIp(try server.localAddress(listener)) orelse error.InvalidAddress;
}
const Harness = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    plan: plans.Plan,
    runners: *[4]*mesh.Runner,
    observers: *[4]Observer,
    clients: *[3]Req,
    server: *Rep,
    server_live: *bool,
    server_paused: bool = false,
    requests_enabled: bool = true,
    decoy: *Rep,
    decoy_live: *bool,
    dialers: *[3]Dialer,
    pools: *[3]Pool,
    location: *Location,
    authority: schema.State = .{},
    replicas: [3]schema.State = @splat(.{}),
    pending: [3]?qmsg.RequestId = @splat(null),
    expected_close: [3]bool = @splat(false),
    wire_ids: [3]u64 = @splat(0),
    attempted: [3]usize = @splat(0),
    completed: [3][256]qmsg.RequestId = undefined,
    completed_len: [3]usize = @splat(0),
    next_probe: [3]u64 = @splat(0),
    phase: Action = .bootstrap,
    phase_until: u64 = 0,
    started: u64,
    until: u64,
    report: Report,

    fn begin(self: *Harness, action: Action) void {
        self.phase = action;
        self.phase_until = @min(self.until, mesh.Runner.clockUs() + self.options.phase_timeout_us);
        std.debug.print("CHAOS_PHASE seed={d} plan={x} action={s}\n", .{ self.plan.seed, self.plan.fingerprint(), @tagName(action) });
    }
    fn finished(self: *Harness) void {
        self.report.logical_actions_completed += 1;
    }
    fn checkTime(self: *Harness) !void {
        if (mesh.Runner.clockUs() >= self.phase_until) {
            std.debug.print("CHAOS_FAILURE seed={d} plan={x} action={s} attempts={d} timeouts={d}\n", .{ self.plan.seed, self.plan.fingerprint(), @tagName(self.phase), self.report.snapshot_attempts, self.report.snapshot_timeouts });
            return error.ChaosPhaseTimeout;
        }
    }
    fn permitClosures(self: *Harness) void {
        for (0..3) |i| if (self.pending[i] != null) {
            self.expected_close[i] = true;
        };
    }
    fn forgetRoutes(self: *Harness) void {
        self.permitClosures();
        for (0..3) |i| _ = self.pools[i].forget(&self.dialers[i], id(0));
    }
    fn sameState(self: *Harness) bool {
        for (self.replicas) |replica| if (!std.meta.eql(replica, self.authority)) return false;
        for (self.pending) |pending| if (pending != null) return false;
        return true;
    }
    fn allAlive(self: *Harness) bool {
        for (0..4) |owner| for (0..4) |peer| {
            if (owner == peer) continue;
            const member = self.runners[owner].endpoint().node.member(id(peer)) orelse return false;
            if (member.state != .alive) return false;
        };
        return true;
    }
    fn snapshotServer(self: *Harness, socket: *Rep, decoy: bool) !usize {
        var events: [16]qmsg.NodeEvent = undefined;
        const count = try socket.poll(&events);
        defer for (events[0..count]) |*event| event.deinit();
        for (events[0..count]) |event| if (event == .request) {
            if (decoy) return error.WrongIdentityReceivedApplicationRequest;
            const request = event.request;
            if (!std.mem.eql(u8, request.msg.subject, "state.snapshot") or request.msg.body.len != 0) return error.InvalidSnapshotRequest;
            const owner = request.msg.id >> 32;
            if (owner < 1 or owner > 3) return error.InvalidSnapshotRequest;
            const index: usize = @intCast(owner - 1);
            const status = socket.sessionStatus(request.session_id) orelse return error.UnknownSnapshotPeer;
            if (status.peer_cert_spki == null or !std.mem.eql(u8, &status.peer_cert_spki.?, &id(owner).bytes)) return error.WrongSnapshotPeer;
            if (self.pending[index] != null and self.wire_ids[index] == request.msg.id)
                try socket.reply(request.msg.reply_handle.?, .{ .subject = "", .body = &self.authority.encode() });
        };
        return count;
    }
    fn settle(self: *Harness, i: usize, request: qmsg.RequestId) !void {
        if (self.pending[i] == null or self.pending[i].? != request) return error.DuplicateOrUnexpectedOutcome;
        for (self.completed[i][0..self.completed_len[i]]) |terminal| if (terminal == request) return error.DuplicateOrUnexpectedOutcome;
        if (self.completed_len[i] == self.completed[i].len) return error.TerminalHistoryBound;
        self.completed[i][self.completed_len[i]] = request;
        self.completed_len[i] += 1;
        self.pending[i] = null;
    }
    fn clientEvents(self: *Harness, i: usize) !usize {
        var events: [16]qmsg.NodeEvent = undefined;
        const count = try self.clients[i].poll(&events);
        defer for (events[0..count]) |*event| event.deinit();
        for (events[0..count]) |event| switch (event) {
            .reply => |reply| {
                try self.settle(i, reply.request_id);
                self.expected_close[i] = false;
                if (reply.msg.flags.err) return error.ErrorSnapshotReply;
                self.report.snapshot_replies += 1;
                self.replicas[i].apply(reply.msg.body) catch |err| switch (err) {
                    error.StaleSnapshot => {
                        self.report.stale_snapshots_rejected += 1;
                        continue;
                    },
                    else => return err,
                };
                self.report.snapshots_applied += 1;
            },
            .request_failed => |failed| {
                try self.settle(i, failed.request_id);
                if (failed.failure == .deadline_exceeded) {
                    self.report.snapshot_timeouts += 1;
                } else if (failed.failure == .peer_closed and self.expected_close[i]) {
                    self.report.request_peer_closures += 1;
                } else return error.UnexpectedRequestFailure;
                self.expected_close[i] = false;
            },
            else => {},
        };
        return count;
    }
    fn quietWait(self: *Harness) !void {
        var fds: [64]std.posix.pollfd = undefined;
        var count: usize = 0;
        var deadline = @min(self.phase_until, mesh.Runner.clockUs() + 10_000);
        for (self.runners) |runner| {
            fds[count] = .{ .fd = runner.readableSockets().mesh, .events = std.posix.POLL.IN, .revents = 0 };
            count += 1;
            if (runner.nextDeadline(mesh.Runner.clockUs())) |d| deadline = @min(deadline, d);
        }
        var handles: [16]std.Io.net.Socket.Handle = undefined;
        for (0..3) |i| {
            const used = try self.clients[i].readableSockets(&handles);
            for (handles[0..used]) |handle| {
                if (count == fds.len) return error.SocketInventoryBound;
                fds[count] = .{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
            if (self.clients[i].nextTimer()) |d| deadline = @min(deadline, d);
            if (self.pools[i].nextDeadline()) |d| deadline = @min(deadline, d);
            if (self.requests_enabled and self.pending[i] == null) deadline = @min(deadline, self.next_probe[i]);
        }
        for ([_]bool{ self.server_live.* and !self.server_paused, self.decoy_live.* }, 0..) |active, which| {
            if (!active) continue;
            const socket = if (which == 0) self.server else self.decoy;
            const used = try socket.readableSockets(&handles);
            for (handles[0..used]) |handle| {
                if (count == fds.len) return error.SocketInventoryBound;
                fds[count] = .{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
            if (socket.nextTimer()) |d| deadline = @min(deadline, d);
        }
        const now = mesh.Runner.clockUs();
        if (deadline > now) _ = try std.posix.poll(fds[0..count], @intCast((deadline - now + 999) / 1000));
    }
    fn step(self: *Harness) !void {
        try self.checkTime();
        const now = mesh.Runner.clockUs();
        var did_work = false;
        for (self.runners) |runner| try runner.step();
        if (self.server_live.* and !self.server_paused) {
            try self.server.pump(now);
            did_work = try self.snapshotServer(self.server, false) != 0;
        }
        if (self.decoy_live.*) {
            try self.decoy.pump(now);
            did_work = (try self.snapshotServer(self.decoy, true) != 0) or did_work;
        }
        var total_entries: usize = 0;
        for (self.plan.replica_order) |owner| {
            const i = owner - 1;
            try self.clients[i].pump(now);
            const old_dials = self.pools[i].stats.dials;
            const old_closes = self.pools[i].stats.closed;
            const previous_count = self.pools[i].count();
            const member = self.runners[owner].endpoint().node.member(id(0));
            if (member != null and member.?.state == .dead and previous_count != 0) {
                if (self.pending[i] != null) self.expected_close[i] = true;
                self.report.dead_route_removals += 1;
            }
            try self.pools[i].service(&self.runners[owner].endpoint().node, &self.dialers[i], self.location.resolver(), now);
            did_work = (try self.clientEvents(i) != 0) or did_work;
            if (self.requests_enabled and self.pending[i] == null and now >= self.next_probe[i]) {
                const route = self.pools[i].ensure(&self.runners[owner].endpoint().node, &self.dialers[i], self.location.resolver(), id(0), now) catch |err| switch (err) {
                    error.UnknownPeer, error.PeerDead, error.PeerSuspected => null,
                    else => return err,
                };
                if (route) |session| {
                    if (self.phase == .stale_endpoint or self.phase == .wrong_identity) return error.InvalidEndpointExposed;
                    const status = self.clients[i].sessionStatus(session) orelse return error.UnreadyRoute;
                    if (status.state != .ready or status.peer_cert_spki == null or !std.mem.eql(u8, &status.peer_cert_spki.?, &id(0).bytes)) return error.WrongReadyIdentity;
                    if (self.attempted[i] >= 256) return error.RequestAttemptBound;
                    self.wire_ids[i] = (@as(u64, owner) << 32) | (self.wire_ids[i] + 1 & 0xffffffff);
                    const request = self.clients[i].request(session, .{ .id = self.wire_ids[i], .subject = "state.snapshot", .deadline_ms = self.options.request_deadline_ms }) catch |err| switch (@as(anyerror, err)) {
                        error.QueueFull, error.FlowControlled, error.TooManyInflightRequests => blk: {
                            self.report.request_backpressure += 1;
                            break :blk null;
                        },
                        else => return err,
                    };
                    if (request) |token| {
                        self.pending[i] = token;
                        self.attempted[i] += 1;
                        self.report.snapshot_attempts += 1;
                        self.report.peak_pending_requests_per_replica = 1;
                        did_work = true;
                    }
                }
                self.next_probe[i] = now + self.options.probe_interval_us;
            }
            total_entries += self.pools[i].count();
            self.report.peak_pool_entries_per_replica = @max(self.report.peak_pool_entries_per_replica, self.pools[i].count());
            did_work = did_work or old_dials != self.pools[i].stats.dials or old_closes != self.pools[i].stats.closed;
            if (self.clients[i].stats().events_dropped != 0) return error.DroppedCanonicalEvent;
        }
        self.report.peak_total_pool_entries = @max(self.report.peak_total_pool_entries, total_entries);
        if (total_entries > 3 or self.report.peak_pool_entries_per_replica > 1) return error.RouteBound;
        for (self.runners) |runner| {
            const metrics = runner.endpoint().metrics().transport;
            self.report.peak_mesh_session_records = @max(self.report.peak_mesh_session_records, metrics.session_records);
            self.report.peak_mesh_server_slots = @max(self.report.peak_mesh_server_slots, metrics.server_slots);
            if (metrics.session_records > 64 or metrics.server_slots > 32 or metrics.identity_mismatches != 0) return error.MeshResourceOrIdentityBound;
        }
        if (self.server_live.* and self.server.stats().events_dropped != 0) return error.DroppedCanonicalEvent;
        if (!did_work) try self.quietWait();
    }
    fn waitConverged(self: *Harness) !void {
        defer self.requests_enabled = true;
        while (true) {
            var data_equal = true;
            for (self.replicas) |replica| data_equal = data_equal and std.meta.eql(replica, self.authority);
            // Once the phase's state gate is reached, finish accepted work
            // before changing owners. No new demand is admitted during drain.
            if (data_equal and self.allAlive()) self.requests_enabled = false;
            if (self.sameState() and self.allAlive()) return;
            try self.step();
        }
    }
    fn isolate(self: *Harness) void {
        self.server_paused = true;
        const authority_port = self.runners[0].endpoint().node.selfDesc().addr.v4.port;
        for (1..4) |owner| {
            const port = self.runners[owner].endpoint().node.selfDesc().addr.v4.port;
            self.runners[0].faults.bh_in[owner - 1] = port;
            self.runners[0].faults.bh_out[owner - 1] = port;
            self.runners[owner].faults.bh_in[0] = authority_port;
            self.runners[owner].faults.bh_out[0] = authority_port;
            self.runners[owner].faults.bh_in_len = 1;
            self.runners[owner].faults.bh_out_len = 1;
        }
        self.runners[0].faults.bh_in_len = 3;
        self.runners[0].faults.bh_out_len = 3;
    }
    fn allDeadAndForgotten(self: *Harness) bool {
        for (1..4) |owner| {
            const member = self.runners[owner].endpoint().node.member(id(0)) orelse return false;
            if (member.state != .dead or self.pools[owner - 1].count() != 0 or self.pending[owner - 1] != null) return false;
        }
        return true;
    }
    fn noUsefulHints(self: *Harness) !void {
        for (self.observers[1..]) |observer| if (observer.hints != 0) return error.UsefulHintEscapedPartition;
    }
};

pub fn runScenario(a: std.mem.Allocator, io: std.Io, options: Options) !Report {
    if (options.phase_timeout_us < 2_000_000 or options.phase_timeout_us > 15_000_000 or options.max_runtime_us < 10_000_000 or options.max_runtime_us > 60_000_000 or options.request_deadline_ms < 10 or options.request_deadline_ms > 200 or options.probe_interval_us < options.request_deadline_ms * 1000 or options.probe_interval_us > 500_000) return error.InvalidOptions;
    const plan = plans.generate(options.seed);
    const started = mesh.Runner.clockUs();
    var observers: [4]Observer = @splat(.{});
    var runners: [4]*mesh.Runner = undefined;
    var runner_count: usize = 0;
    var absent_runner: ?usize = null;
    defer for (runners[0..runner_count], 0..) |runner, owner_index| {
        if (absent_runner == null or absent_runner.? != owner_index) runner.deinit();
    };
    for (&runners, 0..) |*runner, owner| {
        runner.* = try makeMesh(a, plan, owner, owner + 1, &observers[owner]);
        runner_count += 1;
    }
    for (runners[1..]) |runner| runner.endpoint().startJoin(runners[0].endpoint().node.selfDesc());
    var server = try Rep.init(a, .{ .node = nodeOptions(io) });
    var server_live = true;
    defer if (server_live) server.deinit();
    var server_address = try listen(&server, 0, qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 0));
    var location: Location = .{ .address = server_address };
    var decoy: Rep = undefined;
    var decoy_live = false;
    defer if (decoy_live) decoy.deinit();
    var clients: [3]Req = undefined;
    var client_count: usize = 0;
    defer for (clients[0..client_count]) |*client| client.deinit();
    var dialers: [3]Dialer = undefined;
    var pools: [3]Pool = undefined;
    var pool_count: usize = 0;
    defer for (0..pool_count) |i| pools[i].deinit(&dialers[i]);
    for (0..3) |i| {
        clients[i] = try Req.init(a, .{ .node = nodeOptions(io) });
        client_count += 1;
        dialers[i] = .{ .socket = &clients[i], .options = .{ .server_name = "qmesh-test", .identity_verification = .none, .ca_pem = ca, .client_cert_pem = identities[i + 1].cert, .client_key_pem = identities[i + 1].key, .transport = limits(i + 1) } };
        pools[i] = try Pool.init(a, .{ .max_peers = 1, .idle_timeout_us = 0, .dial_timeout_us = 500_000, .retry_initial_us = 50_000, .retry_max_us = 200_000 });
        pool_count += 1;
    }
    var h: Harness = .{ .allocator = a, .io = io, .options = options, .plan = plan, .runners = &runners, .observers = &observers, .clients = &clients, .server = &server, .server_live = &server_live, .decoy = &decoy, .decoy_live = &decoy_live, .dialers = &dialers, .pools = &pools, .location = &location, .started = started, .until = started + options.max_runtime_us, .report = .{ .seed = options.seed, .plan_fingerprint = plan.fingerprint() } };
    errdefer std.debug.print("CHAOS_ABORT seed={d} plan={x} action={s} report={any}\n", .{ plan.seed, plan.fingerprint(), @tagName(h.phase), h.report });
    h.begin(.bootstrap);
    h.authority.update();
    try h.waitConverged();
    var initial_sessions: [3]u64 = undefined;
    for (0..3) |i| initial_sessions[i] = pools[i].lookup(id(0)) orelse return error.BootstrapRouteMissing;
    h.finished();
    h.begin(.partition);
    h.isolate();
    h.finished();
    h.begin(.expire_hints);
    var hint_ids: [47]qmesh.plumtree.MsgId = undefined;
    for (hint_ids[0..plan.updates]) |*hint_id| {
        h.authority.update();
        hint_id.* = runners[0].endpoint().node.publish(&schema.hint(h.authority.revision)) orelse return error.PublishRejected;
        for (runners) |runner| try runner.step();
    }
    for (0..plan.noise) |_| {
        _ = runners[0].endpoint().node.publish("unrelated seeded announcement") orelse return error.PublishRejected;
        for (runners) |runner| try runner.step();
    }
    for (hint_ids[0..plan.updates]) |hint_id| {
        const cache = &runners[0].endpoint().node.broadcast;
        for (cache.payloads[0..cache.payloads_len]) |entry| if (entry.id.eql(hint_id)) return error.HintStillRetained;
        h.report.hints_evicted += 1;
    }
    try h.noUsefulHints();
    h.finished();
    h.begin(.suspect_gate);
    const owner = plan.probe_owner;
    while (true) {
        try h.step();
        const member = runners[owner].endpoint().node.member(id(0)) orelse continue;
        if (member.state != .suspect) continue;
        if (pools[owner - 1].lookup(id(0)) != initial_sessions[owner - 1]) return error.SuspicionDestroyedReadyRoute;
        h.report.suspect_preserved_routes += 1;
        var probe = try Pool.init(a, .{ .max_peers = 1 });
        defer probe.deinit(&dialers[owner - 1]);
        const old_dials = dialers[owner - 1].dials;
        const result = probe.ensure(&runners[owner].endpoint().node, &dialers[owner - 1], location.resolver(), id(0), mesh.Runner.clockUs());
        if (result) |_| return error.SuspicionAdmittedNewRoute else |err| if (err != error.PeerSuspected) return err;
        if (probe.count() != 0 or old_dials != dialers[owner - 1].dials) return error.SuspicionDialedPeer;
        h.report.suspect_new_dials_paused += 1;
        break;
    }
    h.finished();
    h.begin(.dead_gate);
    while (!h.allDeadAndForgotten()) try h.step();
    if (h.report.dead_route_removals != 3 or h.report.snapshot_timeouts == 0) return error.DeadOrTimeoutBranchMissing;
    h.finished();
    h.begin(.restart_application);
    // State remains in this fixture, outside the destroyed messaging owner.
    // This is not a process restart or persistence qualification.
    server.deinit();
    server_live = false;
    server = try Rep.init(a, .{ .node = nodeOptions(io) });
    server_live = true;
    const restarted_address = try listen(&server, 0, server_address);
    if (!restarted_address.eql(server_address)) return error.RestartChangedEndpoint;
    h.authority.update();
    h.report.application_restarts = 1;
    h.finished();
    h.begin(.heal);
    for (runners) |runner| runner.faults.clearFlaky();
    h.server_paused = false;
    runners[0].endpoint().startJoin(runners[plan.probe_owner].endpoint().node.selfDesc());
    h.finished();
    h.begin(.snapshot_repair);
    try h.waitConverged();
    try h.noUsefulHints();
    h.finished();
    h.begin(.stale_endpoint);
    h.forgetRoutes();
    server.deinit();
    server_live = false;
    server = try Rep.init(a, .{ .node = nodeOptions(io) });
    server_live = true;
    const moved = try listen(&server, 0, qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 0));
    if (moved.eql(server_address)) return error.EndpointDidNotMove;
    h.authority.update();
    h.report.endpoint_moves = 1;
    var failures: [3]u64 = undefined;
    for (0..3) |i| failures[i] = pools[i].stats.dial_failures;
    while (true) {
        try h.step();
        var all_failed = true;
        for (0..3) |i| {
            if (pools[i].lookup(id(0)) != null) return error.StaleEndpointExposed;
            all_failed = all_failed and pools[i].stats.dial_failures > failures[i];
        }
        if (all_failed) break;
    }
    h.report.stale_endpoint_rejected = true;
    h.finished();
    h.begin(.wrong_identity);
    decoy = try Rep.init(a, .{ .node = nodeOptions(io) });
    decoy_live = true;
    location.address = try listen(&decoy, plan.decoy_owner, qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 0));
    // First prove that this exact endpoint is usable with its actual key.
    // The simultaneous pool routes still require authority A and must fail.
    const control_owner = plan.probe_owner - 1;
    var control_options = dialers[control_owner].options;
    control_options.expected_peer_spki = id(plan.decoy_owner).bytes;
    var control_text: [128]u8 = undefined;
    const control_session = try clients[control_owner].dial(try messaging.formatEndpoint(location.address, &control_text), control_options);
    while (true) {
        try h.step();
        const control_status = clients[control_owner].sessionStatus(control_session) orelse return error.DecoyPositiveControlClosed;
        if (control_status.state == .ready) {
            if (control_status.peer_cert_spki == null or !std.mem.eql(u8, &control_status.peer_cert_spki.?, &id(plan.decoy_owner).bytes)) return error.DecoyPositiveControlIdentity;
            break;
        }
    }
    try clients[control_owner].closeSession(control_session);
    h.report.decoy_positive_control_ready = true;
    for (0..3) |i| failures[i] = pools[i].stats.dial_failures;
    while (true) {
        try h.step();
        var all_failed = true;
        for (0..3) |i| {
            if (pools[i].lookup(id(0)) != null) return error.WrongIdentityExposed;
            all_failed = all_failed and pools[i].stats.dial_failures > failures[i];
        }
        if (all_failed) break;
    }
    h.report.wrong_identity_rejected = true;
    h.finished();
    h.begin(.moved_endpoint_repair);
    location.address = moved;
    server_address = moved;
    try h.waitConverged();
    h.finished();
    h.begin(.fresh_mesh_owner);
    const reset = plan.reset_owner;
    if (pools[reset - 1].count() != 1 or pools[reset - 1].lookup(id(0)) == null) return error.AbsentRouteNotPresent;
    runners[reset].deinit();
    // Keep deferred cleanup safe if initialization of the replacement fails.
    absent_runner = reset;
    runners[reset] = try makeMesh(a, plan, reset, @as(u64, 0x100) + reset, &observers[reset]);
    absent_runner = null;
    if (runners[reset].endpoint().node.member(id(0)) != null) return error.FreshOwnerContainsOldMembership;
    if (h.pending[reset - 1] != null) h.expected_close[reset - 1] = true;
    try pools[reset - 1].service(&runners[reset].endpoint().node, &dialers[reset - 1], location.resolver(), mesh.Runner.clockUs());
    if (pools[reset - 1].count() != 0) return error.AbsentMemberKeptRoute;
    h.report.absent_route_removals = 1;
    h.replicas[reset - 1] = .{};
    runners[reset].endpoint().startJoin(runners[0].endpoint().node.selfDesc());
    h.finished();
    h.begin(.final_repair);
    try h.waitConverged();
    try h.noUsefulHints();
    h.finished();
    for (observers[1..]) |observer| h.report.hints_delivered_after_heal += observer.hints;
    h.report.authority_revision = h.authority.revision;
    for (h.replicas, 0..) |replica, i| h.report.replica_revisions[i] = replica.revision;
    h.report.final_state_hash = plans.bytesFingerprint(&h.authority.encode());
    h.report.converged = h.sameState() and h.allAlive();
    h.report.elapsed_us = mesh.Runner.clockUs() - started;
    if (!h.report.converged or !h.report.decoy_positive_control_ready or h.report.hints_delivered_after_heal != 0 or h.report.snapshot_replies != h.report.snapshots_applied + h.report.stale_snapshots_rejected or h.report.logical_actions_completed != plans.actions.len or h.report.snapshot_attempts != h.report.snapshot_replies + h.report.snapshot_timeouts + h.report.request_peer_closures) return error.ChaosFinalInvariant;
    return h.report;
}

pub fn main(init: std.process.Init) !void {
    var options: Options = .{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        const value = args.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, arg, "--seed")) options.seed = try std.fmt.parseInt(u64, value, 0) else return error.UnknownArgument;
    }
    const report = try runScenario(init.gpa, init.io, options);
    const json = try std.json.Stringify.valueAlloc(init.gpa, report, .{});
    defer init.gpa.free(json);
    std.debug.print("MESH_CHAOS_WORKLOAD {s}\n", .{json});
}
