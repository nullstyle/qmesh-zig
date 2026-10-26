//! The node runner: an embedder-owned UDP loop that drives one mesh
//! endpoint over real sockets — the supported "just run a mesh node"
//! path, and the exact shape `tests/quic_mesh_test.zig` drives at
//! twelve nodes.
//!
//! One iteration (the EMBEDDING.md order, adapted for a node that is
//! both acceptor and dialer):
//!
//! ```text
//! ingest (recv → the dial that owns the DCID, else Server.feed,
//!         then dial connections on feed-drop)
//!   → stateless-response drain
//!   → advance fresh dials (first ClientHello flight)
//!   → endpoint.service (protocol cores, ingress, timers)
//!   → server.tick + reap, dial ticks
//!   → outbound drain (slot connections, dial connections)
//! ```
//!
//! Two ways to drive it:
//!
//! * `run()` — blocks on socket readability or the earliest protocol,
//!   transport and application deadline until `shutdown` flips.
//! * `step()` — one nonblocking iteration. Tests, foreign event
//!   loops, and anything that owns the wait call this (or wire
//!   `on_iteration` into `run()` for per-pass application work).
//!
//! POSIX only (macOS/Linux): raw `posix.system` syscalls, because
//! this toolchain's std.posix has no wrapped socket layer. Darwin
//! rejects socket-type flags, so nonblocking comes from `fcntl`. The
//! clock is CLOCK_MONOTONIC via libc. Windows embedders drive the
//! endpoint from their own loop (`step` semantics translate directly).
//!
//! Lifetime: `Runner.init` allocates the endpoint, binds the socket;
//! `deinit` tears both down. A `stop()`ped runner's `step` is a no-op
//! (crash tests stop pumping a node and leave its socket dark).

const std = @import("std");
const qmesh = @import("qmesh");
const quic = @import("quic");
const endpoint_mod = @import("endpoint.zig");

const posix = std.posix;
const Endpoint = endpoint_mod.Endpoint;

var clock_origin: ?u64 = null;

fn nowUs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const us: u64 = @as(u64, @intCast(ts.sec)) * std.time.us_per_s +
        @as(u64, @intCast(@divTrunc(ts.nsec, 1000)));
    if (clock_origin == null) clock_origin = us;
    return us - clock_origin.?;
}

fn toQuicAddr(a: qmesh.Addr) ?quic.Address {
    return switch (a) {
        .none => null,
        .v4 => |v4| .{ .ipv4 = .{ .addr = v4.octets, .port = v4.port } },
        .v6 => |v6| .{ .ipv6 = .{ .addr = v6.octets, .port = v6.port } },
    };
}

/// In-process fault injection knobs (chaos testing; see
/// tools/chaos-design.md). Opt-in via `Runner.Options.control`; the
/// control listener mutates these, the loop consults them at the
/// exact points traffic flows. All off by default.
pub const FaultKnobs = struct {
    /// Inbound datagram drop rate in basis points (0 = off).
    drop_in_bp: u32 = 0,
    /// Outbound datagram drop rate in basis points.
    drop_out_bp: u32 = 0,
    /// Freeze: skip loop iterations until this wall time passes —
    /// nothing is sent or processed while the clock advances, so
    /// Lifeguard observes exactly the stall via `noteAppDelay`.
    freeze_until_us: u64 = 0,
    /// Extra sleep per iteration (the "slow" fault).
    delay_us: u64 = 0,
    /// One-way blackholes by port (the pre-decrypt identity available
    /// on both directions of the wire). Bounded.
    bh_in: [4]u16 = @splat(0),
    bh_in_len: usize = 0,
    bh_out: [4]u16 = @splat(0),
    bh_out_len: usize = 0,

    pub fn clearFlaky(f: *FaultKnobs) void {
        f.drop_in_bp = 0;
        f.drop_out_bp = 0;
        f.delay_us = 0;
        f.bh_in_len = 0;
        f.bh_out_len = 0;
    }
};

/// Family-aware socket address. Octets are copied byte-for-byte:
/// sockaddr_in.addr is a u32 on some ABIs and [4]u8 on others, and
/// both hold network-order octets in memory, so memcpy is the
/// order-safe projection in both families.
const SockAddr = struct {
    storage: posix.sockaddr.storage,
    len: posix.socklen_t,
};

fn toSockAddr(a: quic.Address) ?SockAddr {
    switch (a) {
        .ipv4 => |v4| {
            var sa: posix.sockaddr.in = std.mem.zeroes(posix.sockaddr.in);
            sa.family = posix.AF.INET;
            sa.port = std.mem.nativeToBig(u16, v4.port);
            @memcpy(std.mem.asBytes(&sa.addr), &v4.addr);
            var out: SockAddr = .{ .storage = std.mem.zeroes(posix.sockaddr.storage), .len = @sizeOf(posix.sockaddr.in) };
            @memcpy(std.mem.asBytes(&out.storage)[0..@sizeOf(posix.sockaddr.in)], std.mem.asBytes(&sa));
            return out;
        },
        .ipv6 => |v6| {
            var sa: posix.sockaddr.in6 = std.mem.zeroes(posix.sockaddr.in6);
            sa.family = posix.AF.INET6;
            sa.port = std.mem.nativeToBig(u16, v6.port);
            @memcpy(&sa.addr, &v6.addr);
            var out: SockAddr = .{ .storage = std.mem.zeroes(posix.sockaddr.storage), .len = @sizeOf(posix.sockaddr.in6) };
            @memcpy(std.mem.asBytes(&out.storage)[0..@sizeOf(posix.sockaddr.in6)], std.mem.asBytes(&sa));
            return out;
        },
        .unspecified => return null,
    }
}

fn sockFamily(a: qmesh.Addr) posix.sa_family_t {
    return switch (a) {
        .v6 => posix.AF.INET6,
        else => posix.AF.INET,
    };
}

/// Address equality (family, bytes, port) for the ingress filter.
const quicAddrEql = endpoint_mod.quicAddrEql;

fn fromSockAddr(st: *const posix.sockaddr.storage) quic.Address {
    const sa: *const posix.sockaddr = @ptrCast(st);
    switch (sa.family) {
        posix.AF.INET => {
            const in: *const posix.sockaddr.in = @ptrCast(@alignCast(st));
            var octets: [4]u8 = undefined;
            @memcpy(&octets, std.mem.asBytes(&in.addr));
            return .{ .ipv4 = .{ .addr = octets, .port = std.mem.bigToNative(u16, in.port) } };
        },
        posix.AF.INET6 => {
            const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(st));
            return .{ .ipv6 = .{ .addr = in6.addr, .port = std.mem.bigToNative(u16, in6.port) } };
        },
        else => return .unspecified,
    }
}

pub const Runner = struct {
    const Self = @This();

    pub const Options = struct {
        /// Endpoint options; `self.addr` is the address peers dial and
        /// normally matches `bind`; port zero is replaced by the actual
        /// bound port. An explicit advertised IP may differ from bind.
        endpoint: endpoint_mod.Options,
        bind: qmesh.Addr,
        /// Compatibility cadence for an on_iteration callback that does
        /// not supply next_deadline. Other waits are deadline driven.
        step_sleep_ms: u64 = 2,
        /// Maximum park: bounds observation of a cross-thread shutdown
        /// flag even when no datagram or protocol timer wakes the loop.
        max_wait_ms: u32 = 50,
        /// Called once per `run()` iteration after the pass completes.
        on_iteration: ?*const fn (ctx: ?*anyopaque, r: *Self, now_us: u64) anyerror!void = null,
        on_iteration_ctx: ?*anyopaque = null,
        /// Absolute time on clockUs(), using on_iteration_ctx. Supplying
        /// this callback opts out of the legacy step_sleep_ms cadence;
        /// null returned by the callback means no application timer.
        next_deadline: ?*const fn (ctx: ?*anyopaque, r: *const Self, now_us: u64) ?u64 = null,
        /// `run()` exits when this flips true (checked each pass).
        shutdown: ?*std.atomic.Value(bool) = null,
        /// Chaos control channel: bind this address (a second UDP
        /// socket) and accept fault commands (freeze/drop/bh/slow/
        /// crash/clear — see tools/chaos-design.md). Null disables.
        control: ?qmesh.Addr = null,
    };

    allocator: std.mem.Allocator,
    opts: Options,
    ep: *Endpoint,
    sock: posix.socket_t,
    local_address: qmesh.Addr,
    /// False once stopped/crashed: `step` becomes a no-op but the
    /// socket stays bound (dark) until deinit.
    live: bool = true,
    buf: [4096]u8 = undefined,
    /// Last iteration's clock sample — the Lifeguard (local health)
    /// input. The gap between iterations is the observed app delay.
    last_step_us: u64,
    /// Chaos fault knobs (see FaultKnobs) + control socket + the
    /// drop-decision xorshift state.
    faults: FaultKnobs = .{},
    fault_rng: u64 = 0x9e3779b97f4a7c15,
    control_sock: ?posix.socket_t = null,

    pub fn init(allocator: std.mem.Allocator, opts: Options) !*Self {
        if (opts.max_wait_ms == 0) return error.InvalidWaitLimit;
        const ep = try Endpoint.init(allocator, opts.endpoint);
        errdefer ep.deinit();
        _ = try ep.listen();

        var sa = toSockAddr(toQuicAddr(opts.bind) orelse return error.NoRoute) orelse return error.NoRoute;
        const sock = try sysSocket(sockFamily(opts.bind));
        errdefer _ = posix.system.close(sock);
        const rc = posix.system.bind(sock, @ptrCast(&sa.storage), sa.len);
        if (posix.errno(rc) != .SUCCESS) return error.BindFailed;
        var actual: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
        var actual_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        if (posix.errno(posix.system.getsockname(sock, @ptrCast(&actual), &actual_len)) != .SUCCESS)
            return error.AddressUnavailable;
        const bound: qmesh.Addr = switch (fromSockAddr(&actual)) {
            .ipv4 => |v| qmesh.Addr.ipv4(v.addr, v.port),
            .ipv6 => |v| qmesh.Addr.ipv6(v.addr, v.port),
            .unspecified => return error.AddressUnavailable,
        };
        const bound_port: u16 = switch (bound) {
            .v4 => |v| v.port,
            .v6 => |v| v.port,
            .none => unreachable,
        };
        switch (ep.opts.self.addr) {
            .v4 => |*v| if (v.port == 0) {
                v.port = bound_port;
            },
            .v6 => |*v| if (v.port == 0) {
                v.port = bound_port;
            },
            .none => ep.opts.self.addr = bound,
        }
        ep.node.overlay.self = ep.opts.self;
        ep.node.swim.self = ep.opts.self;

        const control_sock: ?posix.socket_t = if (opts.control) |c| blk: {
            const csa = toSockAddr(toQuicAddr(c) orelse return error.NoRoute) orelse return error.NoRoute;
            const csock = try sysSocket(sockFamily(c));
            errdefer _ = posix.system.close(csock);
            const crc = posix.system.bind(csock, @ptrCast(&csa.storage), csa.len);
            if (posix.errno(crc) != .SUCCESS) return error.BindFailed;
            break :blk csock;
        } else null;

        errdefer if (control_sock) |cs| {
            _ = posix.system.close(cs);
        };
        const r = try allocator.create(Self);
        errdefer allocator.destroy(r);
        r.* = .{
            .allocator = allocator,
            .opts = opts,
            .ep = ep,
            .sock = sock,
            .local_address = bound,
            .last_step_us = nowUs(),
            .control_sock = control_sock,
        };
        return r;
    }

    pub fn deinit(r: *Self) void {
        _ = posix.system.close(r.sock);
        if (r.control_sock) |cs| _ = posix.system.close(cs);
        r.ep.deinit();
        r.allocator.destroy(r);
    }

    /// Mark the node down (crash semantics): no further stepping, no
    /// goodbye; the socket sits dark until `deinit`.
    pub fn stop(r: *Self) void {
        r.live = false;
    }

    pub fn localAddress(r: *const Self) qmesh.Addr {
        return r.local_address;
    }

    /// The loop's monotonic clock (microseconds since the first
    /// runner in this process was created) — the `now_us` that
    /// `on_iteration` receives. For embedders that `step()` and tick a
    /// side-car (mDNS discovery) on the same time base.
    pub fn clockUs() u64 {
        return nowUs();
    }

    pub fn endpoint(r: *Self) *Endpoint {
        return r.ep;
    }

    pub const ReadableSockets = struct {
        mesh: posix.socket_t,
        control: ?posix.socket_t,
    };

    /// Borrowed handle inventory until deinit. An external owner selects
    /// its admissible read interests, polls them with other protocols,
    /// then calls nonblocking step(). Never close these handles or read
    /// their datagrams outside this runner. A foreign owner's pause
    /// policy must mask mesh readability while it deliberately ignores
    /// mesh input; run() implements that policy for freeze/slow controls.
    pub fn readableSockets(r: *const Self) ReadableSockets {
        return .{ .mesh = r.sock, .control = r.control_sock };
    }

    /// Earliest absolute service time on clockUs(), including the
    /// responsiveness cap. Compositors take the minimum with qmsg and
    /// peer-pool deadlines; the runner owns neither of those modules.
    /// A foreign pause policy uses its resume deadline instead of overdue
    /// protocol timers until it resumes protocol stepping.
    pub fn nextDeadline(r: *const Self, now_us: u64) ?u64 {
        var best: ?u64 = now_us +| @as(u64, r.opts.max_wait_ms) * std.time.us_per_ms;
        earliest(&best, r.ep.node.nextDeadline());
        if (r.ep.server) |server| if (server.nextTimerDeadline(now_us)) |d| earliest(&best, d.at_us);
        for (r.ep.sessions.items) |session| {
            if (session.client == null or session.conn.isClosed()) continue;
            // A callback can create a fresh dial after service(). Its
            // ClientHello must advance before we park without an fd event.
            if (!session.advanced) earliest(&best, now_us);
            if (session.conn.nextTimerDeadline(now_us)) |d| earliest(&best, d.at_us);
        }
        if (r.opts.next_deadline) |callback| {
            earliest(&best, callback(r.opts.on_iteration_ctx, r, now_us));
        } else if (r.opts.on_iteration != null) {
            earliest(&best, now_us +| r.opts.step_sleep_ms *| std.time.us_per_ms);
        }
        return best;
    }

    /// One nonblocking iteration, including a bounded control drain.
    /// Crash commands exit before protocol work; loss/blackhole controls
    /// apply immediately. This method owns no pacing/wait: freeze/slow
    /// scheduling belongs to run(), or a foreign owner's pause policy.
    /// Observed gaps remain raw Lifeguard input for external steppers.
    pub fn step(r: *Self) !void {
        if (!r.live) return;
        r.drainControl();
        const now = nowUs();
        r.feedLocalHealth(now);
        try r.ingest(now);
        try r.service(now);
        try r.drainOutbound(now);
    }

    /// Blocking drive until the shutdown flag flips.
    pub fn run(r: *Self) !void {
        var normal_wait_credit_us: u64 = 0;
        var slow_until_us: u64 = 0;
        while (true) {
            if (r.opts.shutdown) |flag| {
                if (flag.load(.acquire)) return;
            }
            if (!r.live) return;
            r.drainControl();
            const now = nowUs();
            if (now < r.faults.freeze_until_us) {
                // Chaos freeze: nothing processed or sent while the
                // wall clock advances — Lifeguard observes the stall
                // through the next iteration gap.
                // Do not watch the deliberately unread mesh socket:
                // queued traffic must not spin a frozen node. Control
                // remains responsive, as does the bounded shutdown check.
                _ = try r.park(r.faults.freeze_until_us, false);
                continue;
            }
            if (r.faults.delay_us == 0) slow_until_us = 0;
            if (now < slow_until_us) {
                _ = try r.park(slow_until_us, false);
                continue;
            }
            // Only actual successful normal parking, capped at its
            // planned duration, is intentional scheduler inactivity.
            // Work, oversleep, freeze and injected slow delay remain
            // visible to Lifeguard. step() retains its raw-gap contract.
            r.feedLocalHealthAfterWait(now, normal_wait_credit_us);
            normal_wait_credit_us = 0;
            try r.ingest(now);
            try r.service(now);
            try r.drainOutbound(now);
            if (r.opts.on_iteration) |cb| {
                try cb(r.opts.on_iteration_ctx, r, nowUs());
                // Application callbacks can enqueue frames without a
                // new read event. Flush them before choosing a park target.
                try r.drainOutbound(nowUs());
            }
            if (r.faults.delay_us > 0) {
                slow_until_us = nowUs() +| r.faults.delay_us;
                continue;
            }
            normal_wait_credit_us = try r.park(r.nextDeadline(nowUs()), true);
        }
    }

    /// Wait only for readability; UDP writability is normally continuous
    /// and would turn an idle loop into a spin. EINTR returns to the owner
    /// so signal handlers' shutdown flags are observed before re-parking.
    fn park(r: *const Self, deadline_us: ?u64, include_mesh: bool) !u64 {
        var descriptors: [2]posix.pollfd = undefined;
        var len: usize = 0;
        if (include_mesh) {
            descriptors[len] = .{ .fd = r.sock, .events = posix.POLL.IN, .revents = 0 };
            len += 1;
        }
        if (r.control_sock) |control| {
            descriptors[len] = .{ .fd = control, .events = posix.POLL.IN, .revents = 0 };
            len += 1;
        }
        const before = nowUs();
        const timeout_ms = waitTimeoutMs(before, deadline_us, r.opts.max_wait_ms);
        const rc = posix.system.poll(descriptors[0..len].ptr, @intCast(len), timeout_ms);
        const after = nowUs();
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => return 0,
            else => return error.WaitFailed,
        }
        for (descriptors[0..len]) |descriptor| {
            if (descriptor.revents & posix.POLL.NVAL != 0) return error.WaitFailed;
        }
        return @min(after -| before, @as(u64, @intCast(timeout_ms)) * std.time.us_per_ms);
    }

    // --- chaos control channel -------------------------------------------

    fn faultDraw(r: *Self) u32 {
        // xorshift64* — drop decisions only; reproducibility lives in
        // the driver's schedule, not these draws.
        var x = r.fault_rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        r.fault_rng = x;
        return @truncate((x *% 0x2545F4914F6CDD1D) >> 32);
    }

    fn portBlackholed(ports: []const u16, addr: ?quic.Address) bool {
        const a = addr orelse return false;
        const port = switch (a) {
            .ipv4 => |v4| v4.port,
            .ipv6 => |v6| v6.port,
            .unspecified => return false,
        };
        for (ports) |p| {
            if (p == port) return true;
        }
        return false;
    }

    fn dropIn(r: *Self, from: ?quic.Address) bool {
        if (portBlackholed(r.faults.bh_in[0..r.faults.bh_in_len], from)) return true;
        return r.faults.drop_in_bp > 0 and r.faultDraw() % 10_000 < r.faults.drop_in_bp;
    }

    fn dropOut(r: *Self, dst: ?quic.Address) bool {
        if (portBlackholed(r.faults.bh_out[0..r.faults.bh_out_len], dst)) return true;
        return r.faults.drop_out_bp > 0 and r.faultDraw() % 10_000 < r.faults.drop_out_bp;
    }

    /// Drain and apply control commands (one datagram each, text).
    fn drainControl(r: *Self) void {
        const cs = r.control_sock orelse return;
        var guard: usize = 0;
        while (guard < 32) : (guard += 1) {
            var cmd: [128]u8 = undefined;
            var from: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
            var from_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const rc = posix.system.recvfrom(cs, &cmd, cmd.len, posix.MSG.DONTWAIT, @ptrCast(&from), &from_len);
            if (posix.errno(rc) != .SUCCESS) return;
            const n: usize = @intCast(rc);
            if (std.mem.eql(u8, cmd[0..n], "stats")) {
                // Console query (qmesh top): one compact status line
                // back to the asker — the metrics snapshot in wire
                // form. Completeness is the asker's job: nodes that
                // don't answer within its window ARE the story.
                var reply: [256]u8 = undefined;
                const line = r.statsLine(&reply);
                _ = posix.system.sendto(cs, line.ptr, line.len, 0, @ptrCast(&from), from_len);
                continue;
            }
            if (std.mem.eql(u8, cmd[0..n], "events")) {
                // Console timeline query (Concept 2 slice): this
                // node's merged event ring, newest first, prefixed
                // with the clock pairing a cross-node consumer needs
                // — `mono` is the ring's clock, `wall` is unix-epoch
                // now, so the asker can order events ACROSS nodes
                // despite per-process monotonic origins. One datagram;
                // as many of the newest events as fit.
                var reply: [1200]u8 = undefined;
                const payload = r.eventsReply(&reply, nowUs());
                _ = posix.system.sendto(cs, payload.ptr, payload.len, 0, @ptrCast(&from), from_len);
                continue;
            }
            r.applyControl(cmd[0..n]);
        }
    }

    /// One-line fleet-card status for the console (Concept 1 slice,
    /// docs/observability-ux.md).
    fn statsLine(r: *Self, buf: []u8) []const u8 {
        const m = r.ep.metrics();
        var hex8: [16]u8 = undefined;
        const full = r.ep.opts.self.id.hex();
        @memcpy(&hex8, full[0..16]);
        return std.fmt.bufPrint(buf, "{s} alive={d} sus={d} dead={d} act={d} rank={d} sess={d} slots={d} lh={d} rtt={d}-{d}us pub={d} del={d}", .{
            hex8[0..],
            m.mesh.swim.members_alive,
            m.mesh.swim.members_suspect,
            m.mesh.swim.members_dead,
            m.mesh.overlay.active,
            m.mesh.overlay.ranked,
            m.transport.established,
            m.transport.server_slots,
            m.mesh.swim.local_health,
            m.mesh.swim.rtt_min_us,
            m.mesh.swim.rtt_max_us,
            m.mesh.broadcast.published,
            m.mesh.broadcast.delivered,
        }) catch "stats?";
    }

    /// Timeline reply for the console's `events` query (Concept 2
    /// slice): header (short id + clock pairing) then the newest
    /// merged events that fit the datagram, newest first.
    fn eventsReply(r: *Self, buf: []u8, now_mono_us: u64) []const u8 {
        var wall: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &wall);
        const wall_us: u64 = @as(u64, @intCast(wall.sec)) * std.time.us_per_s +
            @as(u64, @intCast(@divTrunc(wall.nsec, 1000)));
        var pos: usize = 0;
        const hex16 = r.ep.opts.self.id.hex();
        const head = std.fmt.bufPrint(buf[pos..], "events id={s} mono={d} wall={d}\n", .{
            hex16[0..16], now_mono_us, wall_us,
        }) catch return "events?";
        pos += head.len;
        var ev: [24]qmesh.events.Event = undefined;
        const n = r.ep.node.recentEvents(&ev);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var line: [96]u8 = undefined;
            const s = qmesh.events.formatEvent(ev[i], &line);
            if (pos + s.len + 1 > buf.len) break;
            @memcpy(buf[pos..][0..s.len], s);
            pos += s.len;
            buf[pos] = '\n';
            pos += 1;
        }
        return buf[0..pos];
    }

    fn applyControl(r: *Self, bytes: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, bytes, ' ');
        const cmd = it.next() orelse return;
        const arg1 = it.next() orelse "";
        const arg2 = it.next() orelse "";
        const now = nowUs();
        if (std.mem.eql(u8, cmd, "freeze")) {
            const ms = std.fmt.parseInt(u64, arg1, 10) catch return;
            r.faults.freeze_until_us = now + ms * std.time.us_per_ms;
        } else if (std.mem.eql(u8, cmd, "drop")) {
            const bp = std.fmt.parseInt(u32, arg1, 10) catch return;
            if (std.mem.eql(u8, arg2, "in")) {
                r.faults.drop_in_bp = bp;
            } else if (std.mem.eql(u8, arg2, "out")) {
                r.faults.drop_out_bp = bp;
            } else {
                r.faults.drop_in_bp = bp;
                r.faults.drop_out_bp = bp;
            }
        } else if (std.mem.eql(u8, cmd, "bh")) {
            const port = std.fmt.parseInt(u16, arg1, 10) catch return;
            const dir: u8 = if (std.mem.eql(u8, arg2, "out")) 1 else if (std.mem.eql(u8, arg2, "in")) 2 else @as(u8, 0);
            if ((dir == 0 or dir == 2) and r.faults.bh_in_len < r.faults.bh_in.len) {
                r.faults.bh_in[r.faults.bh_in_len] = port;
                r.faults.bh_in_len += 1;
            }
            if ((dir == 0 or dir == 1) and r.faults.bh_out_len < r.faults.bh_out.len) {
                r.faults.bh_out[r.faults.bh_out_len] = port;
                r.faults.bh_out_len += 1;
            }
        } else if (std.mem.eql(u8, cmd, "slow")) {
            const ms = std.fmt.parseInt(u64, arg1, 10) catch return;
            r.faults.delay_us = ms * std.time.us_per_ms;
        } else if (std.mem.eql(u8, cmd, "clear")) {
            r.faults.clearFlaky();
        } else if (std.mem.eql(u8, cmd, "crash")) {
            std.process.exit(70);
        }
    }

    /// Feed the observed iteration gap to SWIM's Lifeguard local-health
    /// multiplier: gaps beyond the probe budget (scheduler starvation,
    /// machine stalls — the fleet test's soak contention) scale probe
    /// and suspicion windows up so transient stalls cost at most a
    /// suspicion; sustained clean cadence decays them back. This is the
    /// only `noteAppDelay` caller in the real transport — without it
    /// the multiplier is inert and any stall long enough to expire a
    /// suspicion escalates to CONFIRM and eviction.
    fn feedLocalHealth(r: *Self, now: u64) void {
        r.ep.node.swim.noteAppDelay(now, now -| r.last_step_us);
        r.last_step_us = now;
    }

    fn feedLocalHealthAfterWait(r: *Self, now: u64, normal_wait_credit_us: u64) void {
        r.ep.node.swim.noteAppDelay(now, (now -| r.last_step_us) -| normal_wait_credit_us);
        r.last_step_us = now;
    }

    fn ingest(r: *Self, now: u64) !void {
        const srv = r.ep.server.?;
        while (true) {
            var from: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
            var from_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const n = (try sysRecvfrom(r.sock, &r.buf, &from, &from_len)) orelse break;
            if (n == 0) break;
            const from_addr = fromSockAddr(&from);
            if (r.dropIn(from_addr)) continue; // chaos: inbound loss
            // A datagram that carries one of our DIALS' connection IDs,
            // from the address that dial aims at, is that dial's: give
            // it to the dial and not to the server. quic-zig v0.26.0
            // pads a server's first flight to 1200 bytes (RFC 9000
            // section 14.1), so a peer's ServerHello passes our server's
            // Initial size gate. Through v0.28.1 it opened a half-open
            // slot there (`.accepted`, never `.dropped`), and the dial
            // never saw it. Since v0.29.0 `feed` makes no connection for
            // a datagram of which no packet opens and says `.dropped`,
            // so the second route (`feedServerThenDials`) reaches the
            // dial too, with the bytes as they arrived. This route
            // stays first: our server need not build and tear down a
            // connection for each such datagram, and a peer server's
            // Initials do not count against our server's per-source
            // Initial cap or meet a full slot table (the second route
            // reaches a dial on `.dropped` only, so `.rate_limited`
            // and `.table_full` never do).
            if (r.owningDial(r.buf[0..n], from_addr)) |cli| {
                cli.conn.handle(r.buf[0..n], from_addr, now) catch {};
                continue;
            }
            // Everything else is server-routed first (slots +
            // stateless); a datagram the server drops may still
            // belong to one of our outbound DIALS.
            _ = feedServerThenDials(r.ep, srv, r.buf[0..n], from_addr, now) catch continue;
        }
        while (srv.drainStatelessResponse()) |resp| {
            var sa = toSockAddr(resp.dst) orelse continue;
            sysSendto(r.sock, resp.slice(), &sa);
        }
    }

    /// The live dial that owns `bytes`: it aims at `from`, and the
    /// datagram's Destination Connection ID is one the dial issued. A
    /// long header carries the ID's length; a short header uses the
    /// dial's own ID length.
    fn owningDial(r: *Self, bytes: []const u8, from: quic.Address) ?*quic.Client {
        if (bytes.len == 0) return null;
        for (r.ep.sessions.items) |s| {
            const cli = s.client orelse continue;
            if (s.conn.isClosed()) continue;
            if (!quicAddrEql(s.dial_addr, from)) continue;
            const dcid = destinationCid(bytes, cli.conn.localDcidLen()) orelse continue;
            if (cli.conn.ownsLocalCid(dcid)) return cli;
        }
        return null;
    }

    fn service(r: *Self, now: u64) !void {
        // Advance fresh dials (ClientHello) before anything else.
        for (r.ep.sessions.items) |s| {
            if (s.client) |cli| {
                if (!s.advanced) {
                    try cli.conn.advance();
                    s.advanced = true;
                }
            }
        }
        try r.ep.service(now);
        if (r.ep.server) |srv| {
            try srv.tick(now);
            _ = srv.reap();
        }
        for (r.ep.sessions.items) |s| {
            if (s.client) |cli| {
                if (s.conn.isClosed()) continue;
                try cli.conn.tick(now);
            }
        }
    }

    fn drainOutbound(r: *Self, now: u64) !void {
        if (r.ep.server) |srv| {
            for (srv.iterator()) |slot| {
                while (try slot.conn.pollDatagram(&r.buf, now)) |out| {
                    const dst = out.to orelse slot.peer_addr orelse continue;
                    var sa = toSockAddr(dst) orelse continue;
                    if (r.dropOut(dst)) continue; // chaos: outbound loss
                    sysSendto(r.sock, r.buf[0..out.len], &sa);
                }
            }
        }
        for (r.ep.sessions.items) |s| {
            const cli = s.client orelse continue;
            while (try cli.conn.pollDatagram(&r.buf, now)) |out| {
                var sa = toSockAddr(s.dial_addr) orelse continue;
                if (r.dropOut(s.dial_addr)) continue; // chaos: outbound loss
                sysSendto(r.sock, r.buf[0..out.len], &sa);
            }
        }
    }
};

fn earliest(best: *?u64, candidate: ?u64) void {
    const at = candidate orelse return;
    if (best.* == null or at < best.*.?) best.* = at;
}

/// POSIX poll has millisecond resolution: round a future deadline up,
/// avoiding a zero-timeout spin during its final fractional millisecond.
pub fn waitTimeoutMs(now_us: u64, deadline_us: ?u64, cap_ms: u32) i32 {
    const cap: u64 = @min(cap_ms, std.math.maxInt(i32));
    const at = deadline_us orelse return @intCast(cap);
    if (at <= now_us) return 0;
    const rounded = (at - now_us +| (std.time.us_per_ms - 1)) / std.time.us_per_ms;
    return @intCast(@min(cap, rounded));
}

/// The runner's second route for a received datagram, the one for a
/// datagram that no dial owns (see `Runner.ingest`): `bytes` go to our
/// server, and when `feed` says `.dropped`, to each live dial aimed at
/// `from`. Public so a test can drive this route without a socket and
/// without the dial route that `ingest` tries first. `bytes` are
/// scratch after the call.
///
/// `feed` takes `bytes` mutable and can change them even when it drops
/// them: quic-zig v0.29.0 strips an Initial's header protection in
/// place, and only then finds that no packet opens (another server's
/// first flight) and says `.dropped`. `Connection.handle` changes the
/// bytes it reads the same way. So the datagram is copied before
/// `feed`, and each dial gets that copy as it arrived. Only a source
/// that a live dial aims at costs the copy.
pub fn feedServerThenDials(
    ep: *Endpoint,
    srv: *quic.Server,
    bytes: []u8,
    from: quic.Address,
    now: u64,
) !quic.Server.FeedOutcome {
    var arrived: [2048]u8 = undefined;
    const len = @min(bytes.len, arrived.len);
    const dialed = liveDialAimedAt(ep, from);
    if (dialed) @memcpy(arrived[0..len], bytes[0..len]);
    const outcome = try srv.feed(bytes, from, now);
    if (outcome != .dropped or !dialed) return outcome;
    for (ep.sessions.items) |s| {
        const cli = s.client orelse continue;
        if (s.conn.isClosed()) continue;
        // Source-address filter: a packet can only belong to the dial
        // connection aimed at its source. Spraying it at every dial
        // was the churn amplifier — each wrong connection logs an auth
        // failure (~7/s on the six-node fleet), and the auth-failure
        // noise drives key updates whose windows drop real traffic
        // (probe ACKs), sustaining suspicion->confirm->re-dial loops.
        if (!quicAddrEql(s.dial_addr, from)) continue;
        @memcpy(bytes[0..len], arrived[0..len]);
        cli.conn.handle(bytes[0..len], from, now) catch {};
    }
    return outcome;
}

/// Whether a live dial aims at `from`: only then can a datagram from
/// `from` that our server drops be a dial's.
fn liveDialAimedAt(ep: *const Endpoint, from: quic.Address) bool {
    for (ep.sessions.items) |s| {
        if (s.client == null) continue;
        if (s.conn.isClosed()) continue;
        if (quicAddrEql(s.dial_addr, from)) return true;
    }
    return false;
}

/// The Destination Connection ID of the first packet in `bytes`
/// (RFC 9000 section 17.2: a long header gives its length at byte 5;
/// section 17.3: a short header's is `short_len`, known to the receiver).
fn destinationCid(bytes: []const u8, short_len: usize) ?[]const u8 {
    if (bytes.len == 0) return null;
    if ((bytes[0] & 0x80) != 0) {
        if (bytes.len < 6) return null;
        const len: usize = bytes[5];
        if (len == 0 or bytes.len < 6 + len) return null;
        return bytes[6..][0..len];
    }
    if (short_len == 0 or bytes.len < 1 + short_len) return null;
    return bytes[1..][0..short_len];
}

// --- raw syscall helpers (this toolchain's std.posix has no wrapped
// socket layer; quic-zig's own socket_opts goes through posix.system
// the same way) -----------------------------------------------------------

fn sysSocket(family: posix.sa_family_t) !posix.socket_t {
    // Flags inside socket()'s type argument are rejected by Darwin
    // (EPROTOTYPE); plain socket, then fcntl O_NONBLOCK — the same
    // fallback std's backends use.
    const rc = posix.system.socket(family, posix.SOCK.DGRAM, @intCast(posix.IPPROTO.UDP));
    if (posix.errno(rc) != .SUCCESS) return error.SystemResources;
    const fd: posix.socket_t = @intCast(rc);
    const fl = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(fl) != .SUCCESS) return error.SystemResources;
    // posix.O is a packed bool struct on Darwin; std's own backends
    // build the bit with @bitOffsetOf.
    const nonblock: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    const rc2 = posix.system.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(fl)) | nonblock);
    if (posix.errno(rc2) != .SUCCESS) return error.SystemResources;
    return fd;
}

fn sysRecvfrom(sock: posix.socket_t, buf: []u8, from: *posix.sockaddr.storage, from_len: *posix.socklen_t) !?usize {
    const rc = posix.system.recvfrom(sock, buf.ptr, buf.len, posix.MSG.DONTWAIT, @ptrCast(from), from_len);
    const err = posix.errno(rc);
    if (err == .AGAIN) return null;
    if (err != .SUCCESS) return error.RecvFailed;
    return @intCast(rc);
}

fn sysSendto(sock: posix.socket_t, bytes: []const u8, sa: *const SockAddr) void {
    _ = posix.system.sendto(sock, bytes.ptr, bytes.len, 0, @ptrCast(&sa.storage), sa.len);
}
