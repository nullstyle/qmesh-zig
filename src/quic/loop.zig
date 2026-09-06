//! The node runner: an embedder-owned UDP loop that drives one mesh
//! endpoint over real sockets — the supported "just run a mesh node"
//! path, and the exact shape `tests/quic_mesh_test.zig` drives at
//! twelve nodes.
//!
//! One iteration (the EMBEDDING.md order, adapted for a node that is
//! both acceptor and dialer):
//!
//! ```text
//! ingest (recv → Server.feed, dial connections on feed-drop)
//!   → stateless-response drain
//!   → advance fresh dials (first ClientHello flight)
//!   → endpoint.service (protocol cores, ingress, timers)
//!   → server.tick + reap, dial ticks
//!   → outbound drain (slot connections, dial connections)
//! ```
//!
//! Two ways to drive it:
//!
//! * `run()` — blocks until the `shutdown` flag flips; park between
//!   iterations for `step_sleep_ms`. The simple deployment.
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

fn sleepMs(ms: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

/// quic.Address (host-order port, wire-order octets) ⇄ sockaddr_in.
/// Address octets are copied byte-for-byte: sockaddr_in.addr is a u32
/// on some ABIs and [4]u8 on others, and both hold network-order
/// octets in memory, so memcpy is the order-safe projection.
fn toSockaddr(a: quic.Address) posix.sockaddr.in {
    var out: posix.sockaddr.in = std.mem.zeroes(posix.sockaddr.in);
    out.family = posix.AF.INET;
    out.port = std.mem.nativeToBig(u16, a.ipv4.port);
    @memcpy(std.mem.asBytes(&out.addr), &a.ipv4.addr);
    return out;
}

fn fromSockaddr(sa: *const posix.sockaddr.in) quic.Address {
    var octets: [4]u8 = undefined;
    @memcpy(&octets, std.mem.asBytes(&sa.addr));
    return .{ .ipv4 = .{ .addr = octets, .port = std.mem.bigToNative(u16, sa.port) } };
}

fn toQuicAddr(a: qmesh.Addr) ?quic.Address {
    return switch (a) {
        .none => null,
        .v4 => |v4| .{ .ipv4 = .{ .addr = v4.octets, .port = v4.port } },
        .v6 => |v6| .{ .ipv6 = .{ .addr = v6.octets, .port = v6.port } },
    };
}

pub const Runner = struct {
    const Self = @This();

    pub const Options = struct {
        /// Endpoint options; `self.addr` is the address peers dial and
        /// MUST equal `bind` (the runner warns nothing — get it right).
        endpoint: endpoint_mod.Options,
        bind: qmesh.Addr,
        /// Park between iterations in `run()`.
        step_sleep_ms: u64 = 2,
        /// Called once per `run()` iteration after the pass completes.
        on_iteration: ?*const fn (ctx: ?*anyopaque, r: *Self, now_us: u64) anyerror!void = null,
        on_iteration_ctx: ?*anyopaque = null,
        /// `run()` exits when this flips true (checked each pass).
        shutdown: ?*std.atomic.Value(bool) = null,
    };

    allocator: std.mem.Allocator,
    opts: Options,
    ep: *Endpoint,
    sock: posix.socket_t,
    /// False once stopped/crashed: `step` becomes a no-op but the
    /// socket stays bound (dark) until deinit.
    live: bool = true,
    buf: [4096]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, opts: Options) !*Self {
        const ep = try Endpoint.init(allocator, opts.endpoint);
        errdefer ep.deinit();
        _ = try ep.listen();

        const bind_q = toQuicAddr(opts.bind) orelse return error.NoRoute;
        var sa = toSockaddr(bind_q);
        const sock = try sysSocket();
        errdefer _ = posix.system.close(sock);
        const rc = posix.system.bind(sock, @ptrCast(&sa), @sizeOf(posix.sockaddr.in));
        if (posix.errno(rc) != .SUCCESS) return error.BindFailed;

        const r = try allocator.create(Self);
        errdefer allocator.destroy(r);
        r.* = .{
            .allocator = allocator,
            .opts = opts,
            .ep = ep,
            .sock = sock,
        };
        return r;
    }

    pub fn deinit(r: *Self) void {
        _ = posix.system.close(r.sock);
        r.ep.deinit();
        r.allocator.destroy(r);
    }

    /// Mark the node down (crash semantics): no further stepping, no
    /// goodbye; the socket sits dark until `deinit`.
    pub fn stop(r: *Self) void {
        r.live = false;
    }

    pub fn endpoint(r: *Self) *Endpoint {
        return r.ep;
    }

    /// One nonblocking iteration of the whole node.
    pub fn step(r: *Self) !void {
        if (!r.live) return;
        const now = nowUs();
        try r.ingest(now);
        try r.service(now);
        try r.drainOutbound(now);
    }

    /// Blocking drive until the shutdown flag flips.
    pub fn run(r: *Self) !void {
        while (true) {
            if (r.opts.shutdown) |flag| {
                if (flag.load(.acquire)) return;
            }
            if (!r.live) return;
            const now = nowUs();
            try r.ingest(now);
            try r.service(now);
            try r.drainOutbound(now);
            if (r.opts.on_iteration) |cb| {
                try cb(r.opts.on_iteration_ctx, r, nowUs());
            }
            sleepMs(r.opts.step_sleep_ms);
        }
    }

    fn ingest(r: *Self, now: u64) !void {
        const srv = r.ep.server.?;
        while (true) {
            var from: posix.sockaddr.in = std.mem.zeroes(posix.sockaddr.in);
            const n = (try sysRecvfrom(r.sock, &r.buf, &from)) orelse break;
            if (n == 0) break;
            const from_addr = fromSockaddr(&from);
            // Server-routed first (slots + stateless); datagrams the
            // server drops may belong to our outbound DIALS — offer
            // them to each dial connection (wrong-CID packets are
            // ignored by the connection).
            const outcome = srv.feed(r.buf[0..n], from_addr, now) catch continue;
            if (outcome == .dropped) {
                for (r.ep.sessions.items) |s| {
                    const cli = s.client orelse continue;
                    if (s.conn.isClosed()) continue;
                    cli.conn.handle(r.buf[0..n], from_addr, now) catch {};
                }
            }
        }
        while (srv.drainStatelessResponse()) |resp| {
            var sa = toSockaddr(resp.dst);
            sysSendto(r.sock, resp.slice(), &sa);
        }
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
                    var sa = toSockaddr(dst);
                    sysSendto(r.sock, r.buf[0..out.len], &sa);
                }
            }
        }
        for (r.ep.sessions.items) |s| {
            const cli = s.client orelse continue;
            while (try cli.conn.pollDatagram(&r.buf, now)) |out| {
                var sa = toSockaddr(s.dial_addr);
                sysSendto(r.sock, r.buf[0..out.len], &sa);
            }
        }
    }
};

// --- raw syscall helpers (this toolchain's std.posix has no wrapped
// socket layer; quic-zig's own socket_opts goes through posix.system
// the same way) -----------------------------------------------------------

fn sysSocket() !posix.socket_t {
    // Flags inside socket()'s type argument are rejected by Darwin
    // (EPROTOTYPE); plain socket, then fcntl O_NONBLOCK — the same
    // fallback std's backends use.
    const rc = posix.system.socket(posix.AF.INET, posix.SOCK.DGRAM, @intCast(posix.IPPROTO.UDP));
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

fn sysRecvfrom(sock: posix.socket_t, buf: []u8, from: *posix.sockaddr.in) !?usize {
    var from_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const rc = posix.system.recvfrom(sock, buf.ptr, buf.len, posix.MSG.DONTWAIT, @ptrCast(from), &from_len);
    const err = posix.errno(rc);
    if (err == .AGAIN) return null;
    if (err != .SUCCESS) return error.RecvFailed;
    return @intCast(rc);
}

fn sysSendto(sock: posix.socket_t, bytes: []const u8, sa: *const posix.sockaddr.in) void {
    _ = posix.system.sendto(sock, bytes.ptr, bytes.len, 0, @ptrCast(sa), @sizeOf(posix.sockaddr.in));
}
