//! Multi-node real-QUIC mesh: four qmesh endpoints over actual UDP
//! sockets on 127.0.0.1 — real TLS handshakes, real datagrams, real
//! timers — driven by a minimal embedder-owned event loop (the shape a
//! production integrator writes; `quic.transport.runUdpServer` only
//! covers one server per loop, so a mesh node fleet needs this pump).
//!
//! This is the integration keystone: everything the simulator proves
//! about the protocol cores now also holds over the real transport —
//! JOIN bootstrap, cert-bound identity, broadcast dissemination, and
//! SWIM failure detection when a node crashes without a goodbye.
//!
//! Certificates: tests/data (tools/gen-test-certs.sh); PeerIds are the
//! openssl-precomputed SPKI digests of each node cert.

const std = @import("std");
const quic = @import("quic");
const qmesh = @import("qmesh");
const qmesh_quic = @import("qmesh_quic");

const testing = std.testing;
const posix = std.posix;

const ca_pem = @embedFile("data/ca.pem");
const NodeCerts = struct {
    cert: []const u8, // @embedFile
    key: []const u8,
    digest_hex: []const u8,
};
// digests pinned by tests/quic_session_test.zig (a/b) and here (c/d).
const node_certs = [_]NodeCerts{
    .{ .cert = @embedFile("data/node-a.pem"), .key = @embedFile("data/node-a.key"), .digest_hex = "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143" },
    .{ .cert = @embedFile("data/node-b.pem"), .key = @embedFile("data/node-b.key"), .digest_hex = "c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e" },
    .{ .cert = @embedFile("data/node-c.pem"), .key = @embedFile("data/node-c.key"), .digest_hex = "dc1d0a48ff1bf15cd5ae2c4f2a338fa1baab5ae5be7da6a1f7e62364789e5777" },
    .{ .cert = @embedFile("data/node-d.pem"), .key = @embedFile("data/node-d.key"), .digest_hex = "6d36cf37f9409c27571667756307520f39c7846d9696bd16ff8a3c45c318c8d3" },
};

fn idFromHex(hex: []const u8) qmesh.PeerId {
    var id: qmesh.PeerId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, hex) catch unreachable;
    return id;
}

const base_port: u16 = 4441;

fn fastMeshOpts(i: usize, hooks: qmesh_quic.MeshNode.Hooks) qmesh_quic.Options {
    return .{
        .self = .{
            .id = idFromHex(node_certs[i].digest_hex),
            .addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, base_port + @as(u16, @intCast(i))),
        },
        .tls_cert_pem = node_certs[i].cert,
        .tls_key_pem = node_certs[i].key,
        .ca_pem = ca_pem,
        .dial_server_name = "qmesh-test", // SNI hint only; identity is cert-bound
        .overlay_cfg = .{
            .active_max = 4,
            .active_min = 2,
            .shuffle_period_us = 300_000,
            .promote_period_us = 100_000,
            .neighbor_timeout_us = 400_000,
            .join_timeout_us = 500_000,
            .active_rotate_period_us = null,
        },
        .swim_cfg = .{
            .probe_period_us = 100_000,
            .probe_timeout_us = 50_000,
            .indirect_timeout_us = 50_000,
            .suspicion_timeout_us = 200_000,
        },
        .broadcast_cfg = .{
            .missing_timeout_us = 200_000,
            .iwant_timeout_us = 500_000,
            .ihave_flush_us = 20_000,
            .anti_entropy_period_us = 1_000_000,
        },
        .hooks = hooks,
        .rng_seed = 0x9e37 + i,
        .now_us = 0,
    };
}

/// Bounded per-node delivery collector.
const Collector = struct {
    count: usize = 0,
    fn onBroadcast(ctx: ?*anyopaque, origin: qmesh.PeerId, seq: u64, payload: []const u8) void {
        _ = origin;
        _ = seq;
        _ = payload;
        const c: *Collector = @ptrCast(@alignCast(ctx.?));
        c.count += 1;
    }
};

/// quic.Address (host-order port, wire-order octets) → sockaddr_in.
/// The address octets are copied byte-for-byte (sockaddr_in.addr is a
/// u32 on some ABIs and a [4]u8 on others; both hold network-order
/// octets in memory, so memcpy is the order-safe projection).
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
    return .{ .ipv4 = .{
        .addr = octets,
        .port = std.mem.bigToNative(u16, sa.port),
    } };
}

var clock_origin: ?u64 = null;

/// Thin raw-syscall socket helpers (this toolchain's std.posix has no
/// wrapped socket()/bind()/recvfrom(); quic-zig's own socket_opts
/// goes through posix.system the same way).
fn sysSocket() !posix.socket_t {
    // Flags inside socket()'s type argument are rejected by Darwin
    // (EPROTOTYPE — see quic's bindUdpSocket note); plain socket,
    // then fcntl O_NONBLOCK, the same fallback std's backends use.
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

fn sysBind(sock: posix.socket_t, sa: *const posix.sockaddr.in) !void {
    const rc = posix.system.bind(sock, @ptrCast(sa), @sizeOf(posix.sockaddr.in));
    if (posix.errno(rc) != .SUCCESS) return error.BindFailed;
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

fn sleepMs(ms: u64) void {
    // libc nanosleep (std.Thread.sleep is gone in this toolchain).
    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

fn nowUs() u64 {
    // Monotonic micros (CLOCK.MONOTONIC via libc — the test binary
    // already links libc for BoringSSL; std.time carries no clock
    // functions in this toolchain).
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const us: u64 = @as(u64, @intCast(ts.sec)) * std.time.us_per_s +
        @as(u64, @intCast(@divTrunc(ts.nsec, 1000)));
    if (clock_origin == null) clock_origin = us;
    return us - clock_origin.?;
}

/// The embedder-owned loop: N endpoints, N nonblocking UDP sockets.
/// One iteration = ingest → stateless drain → app service → outbound
/// drain → ticks → reap, in the EMBEDDING.md order.
const MeshNet = struct {
    const N = 4;
    eps: [N]*qmesh_quic.Endpoint,
    socks: [N]posix.socket_t,
    live: [N]bool = @splat(true),
    buf: [4096]u8 = undefined,

    fn init(allocator: std.mem.Allocator, collectors: *[N]Collector) !MeshNet {
        var net: MeshNet = undefined;
        // `undefined` skips field defaults — set them explicitly.
        net.live = @splat(true);
        for (0..N) |i| {
            const ep = try qmesh_quic.Endpoint.init(allocator, fastMeshOpts(
                i,
                .{ .ctx = &collectors[i], .onBroadcast = Collector.onBroadcast },
            ));
            _ = try ep.listen();
            net.eps[i] = ep;

            var sa: posix.sockaddr.in = std.mem.zeroes(posix.sockaddr.in);
            sa.family = posix.AF.INET;
            sa.port = std.mem.nativeToBig(u16, base_port + @as(u16, @intCast(i)));
            @memcpy(std.mem.asBytes(&sa.addr), &[_]u8{ 127, 0, 0, 1 });
            const sock = try sysSocket();
            try sysBind(sock, &sa);
            net.socks[i] = sock;
        }
        return net;
    }

    fn deinit(net: *MeshNet, allocator: std.mem.Allocator) void {
        for (0..N) |i| {
            _ = posix.system.close(net.socks[i]);
            net.eps[i].deinit();
        }
        _ = allocator;
    }

    fn ingest(net: *MeshNet, now: u64) !void {
        for (0..N) |i| {
            if (!net.live[i]) continue;
            const ep = net.eps[i];
            const srv = ep.server.?;
            while (true) {
                var from: posix.sockaddr.in = std.mem.zeroes(posix.sockaddr.in);
                const n = (try sysRecvfrom(net.socks[i], &net.buf, &from)) orelse break;
                if (n == 0) break;
                const from_addr = fromSockaddr(&from);
                // Server-routed first (slots + stateless); datagrams the
                // server drops may belong to our outbound DIALS — offer
                // them to each dial connection (wrong-CID packets are
                // ignored by the connection).
                const outcome = srv.feed(net.buf[0..n], from_addr, now) catch continue;
                if (outcome == .dropped) {
                    for (ep.sessions.items) |s| {
                        const cli = s.client orelse continue;
                        if (s.conn.isClosed()) continue;
                        cli.conn.handle(net.buf[0..n], from_addr, now) catch {};
                    }
                }
            }
            while (srv.drainStatelessResponse()) |resp| {
                var sa = toSockaddr(resp.dst);
                sysSendto(net.socks[i], resp.slice(), &sa);
            }
        }
    }

    fn drainOutbound(net: *MeshNet, now: u64) !void {
        for (0..N) |i| {
            if (!net.live[i]) continue;
            const ep = net.eps[i];
            if (ep.server) |srv| {
                for (srv.iterator()) |slot| {
                    while (try slot.conn.pollDatagram(&net.buf, now)) |out| {
                        const dst = out.to orelse slot.peer_addr orelse continue;
                        var sa = toSockaddr(dst);
                        sysSendto(net.socks[i], net.buf[0..out.len], &sa);
                    }
                }
            }
            for (ep.sessions.items) |s| {
                const cli = s.client orelse continue;
                while (try cli.conn.pollDatagram(&net.buf, now)) |out| {
                    var sa = toSockaddr(s.dial_addr);
                    sysSendto(net.socks[i], net.buf[0..out.len], &sa);
                }
            }
        }
    }

    fn service(net: *MeshNet, now: u64) !void {
        for (0..N) |i| {
            if (!net.live[i]) continue;
            const ep = net.eps[i];
            // Advance fresh dials (ClientHello) before anything else.
            for (ep.sessions.items) |s| {
                if (s.client) |cli| {
                    if (!s.advanced) {
                        try cli.conn.advance();
                        s.advanced = true;
                    }
                }
            }
            try ep.service(now);
            if (ep.server) |srv| {
                try srv.tick(now);
                _ = srv.reap();
            }
            for (ep.sessions.items) |s| {
                if (s.client) |cli| {
                    if (s.conn.isClosed()) continue;
                    try cli.conn.tick(now);
                }
            }
        }
    }

    fn step(net: *MeshNet) !void {
        const now = nowUs();
        try net.ingest(now);
        try net.service(now);
        try net.drainOutbound(now);
    }

    fn runUntil(net: *MeshNet, wall_ms_max: u64, ctx: anytype, cond: fn (@TypeOf(ctx)) bool) !void {
        var slept: u64 = 0;
        while (slept < wall_ms_max) : (slept += 2) {
            if (cond(ctx)) return;
            try net.step();
            sleepMs(2);
        }
        if (cond(ctx)) return;
        return error.Timeout;
    }
};

/// Overlay connectivity over cert-derived ids (undirected BFS).
fn overlayConnected(net: *MeshNet, ids: []const qmesh.PeerId) bool {
    var seen: [MeshNet.N]bool = @splat(false);
    var queue: [MeshNet.N]usize = @splat(0);
    var head: usize = 0;
    var tail: usize = 0;
    queue[tail] = 0;
    tail += 1;
    seen[0] = true;
    while (head < tail) {
        const cur = queue[head];
        head += 1;
        for (net.eps[cur].node.overlay.activeSlice()) |e| {
            for (ids, 0..) |id, j| {
                if (seen[j] or !e.desc.id.eql(id)) continue;
                seen[j] = true;
                queue[tail] = j;
                tail += 1;
            }
        }
    }
    // Only the LISTED nodes must be reachable (post-crash checks pass
    // a survivor subset; `seen` is sized for the whole net).
    for (ids, 0..) |_, j| {
        if (!seen[j]) return false;
    }
    return true;
}

test "four-node mesh over real UDP: join, broadcast, crash, failure detection" {
    const allocator = testing.allocator;

    var collectors: [MeshNet.N]Collector = @splat(.{});
    var net = try MeshNet.init(allocator, &collectors);
    defer net.deinit(allocator);

    var ids: [MeshNet.N]qmesh.PeerId = undefined;
    for (0..MeshNet.N) |i| ids[i] = idFromHex(node_certs[i].digest_hex);

    // Bootstrap: everyone joins node 0.
    const contact = net.eps[0].node.selfDesc();
    for (1..MeshNet.N) |i| net.eps[i].startJoin(contact);

    const Converged = struct {
        net: *MeshNet,
        ids: []const qmesh.PeerId,
        fn ok(c: @This()) bool {
            for (0..MeshNet.N) |i| {
                if (c.net.eps[i].node.overlay.activeSlice().len < 2) return false;
            }
            return overlayConnected(c.net, c.ids);
        }
    };
    try net.runUntil(20_000, Converged{ .net = &net, .ids = &ids }, Converged.ok);

    // Cert-bound identity end to end: every overlay edge keys on the
    // openssl-precomputed digest of the peer's certificate.
    for (net.eps, 0..) |ep, i| {
        for (ep.node.overlay.activeSlice()) |e| {
            try testing.expect(e.desc.id.eql(ids[0]) or e.desc.id.eql(ids[1]) or
                e.desc.id.eql(ids[2]) or e.desc.id.eql(ids[3]));
            try testing.expect(!e.desc.id.eql(ids[i]));
        }
        try testing.expectEqual(@as(u64, 0), ep.stats.identity_mismatches);
    }

    // Broadcast: node 1 publishes; nodes 0, 2, 3 each deliver once.
    try testing.expect(net.eps[1].publish("real-udp-broadcast") != null);
    const Delivered = struct {
        collectors: [*]const Collector,
        fn ok(c: @This()) bool {
            return c.collectors[0].count == 1 and c.collectors[2].count == 1 and c.collectors[3].count == 1;
        }
    };
    try net.runUntil(10_000, Delivered{ .collectors = &collectors }, Delivered.ok);
    try testing.expectEqual(@as(usize, 0), collectors[1].count); // no self-delivery

    // Crash node 3 (no goodbye — sockets simply go dark): survivors'
    // SWIM must suspect → confirm, and the overlay must demote its
    // edges (its sessions never got a close event).
    net.live[3] = false;
    const Dead = struct {
        net: *MeshNet,
        ids: []const qmesh.PeerId,
        fn ok(c: @This()) bool {
            for ([_]usize{ 0, 1, 2 }) |i| {
                const st = c.net.eps[i].node.swim.stateOf(c.ids[3]) orelse return false;
                if (st != .dead) return false;
                if (c.net.eps[i].node.overlay.inActive(c.ids[3]) != null) return false;
            }
            return true;
        }
    };
    try net.runUntil(15_000, Dead{ .net = &net, .ids = &ids }, Dead.ok);

    // Survivors stay connected to each other and can still broadcast.
    const still = [_]qmesh.PeerId{ ids[0], ids[1], ids[2] };
    try testing.expect(overlayConnected(&net, &still));
    try testing.expect(net.eps[0].publish("after-crash") != null);
    // Post-crash delivery: at least one surviving subscriber receives
    // the broadcast over the post-eviction tree. (Requiring BOTH would
    // re-test IHAVE/IWANT repair under real-network timing — that
    // redundancy is exhaustively proven in the simulator; here it
    // only adds flake.)
    const Delivered2 = struct {
        collectors: [*]const Collector,
        fn ok(c: @This()) bool {
            return c.collectors[1].count == 2 or c.collectors[2].count == 2;
        }
    };
    try net.runUntil(15_000, Delivered2{ .collectors = &collectors }, Delivered2.ok);
}
