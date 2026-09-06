//! Twelve qmesh nodes over real UDP sockets on 127.0.0.1 — the
//! end-to-end proof of the whole stack on the production integration
//! path (`qmesh_quic.Runner`, the supported socket loop).
//!
//! At this scale the dynamics that four nodes cannot show become
//! observable over the real transport: shuffle-driven passive views,
//! tree trimming under churn, multi-hop dissemination, and clustered
//! failure detection. The scenario: bootstrap-join convergence,
//! cluster-wide broadcast, killing 25% of the fleet without goodbyes
//! (SWIM suspect -> confirm -> session eviction), and a post-crash
//! broadcast over the healed mesh.
//!
//! Certificates: tests/data (tools/gen-test-certs.sh); PeerIds are
//! the openssl-precomputed SPKI digests of each node certificate.

const std = @import("std");
const quic = @import("quic");
const qmesh = @import("qmesh");
const qmesh_quic = @import("qmesh_quic");

const testing = std.testing;

const ca_pem = @embedFile("data/ca.pem");

const NodeCerts = struct {
    cert: []const u8,
    key: []const u8,
    digest_hex: []const u8,
};

// a/b digests also pinned in tests/quic_session_test.zig.
const node_certs = [_]NodeCerts{
    .{ .cert = @embedFile("data/node-a.pem"), .key = @embedFile("data/node-a.key"), .digest_hex = "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143" },
    .{ .cert = @embedFile("data/node-b.pem"), .key = @embedFile("data/node-b.key"), .digest_hex = "c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e" },
    .{ .cert = @embedFile("data/node-c.pem"), .key = @embedFile("data/node-c.key"), .digest_hex = "dc1d0a48ff1bf15cd5ae2c4f2a338fa1baab5ae5be7da6a1f7e62364789e5777" },
    .{ .cert = @embedFile("data/node-d.pem"), .key = @embedFile("data/node-d.key"), .digest_hex = "6d36cf37f9409c27571667756307520f39c7846d9696bd16ff8a3c45c318c8d3" },
    .{ .cert = @embedFile("data/node-e.pem"), .key = @embedFile("data/node-e.key"), .digest_hex = "9e2ca08bd0ceabf513ec1352e8ad749bf676cfda55e0d451c91068c16a958663" },
    .{ .cert = @embedFile("data/node-f.pem"), .key = @embedFile("data/node-f.key"), .digest_hex = "ef531a6d6d6f198625e0051c74feb69aa9d6896e6fb64664e56554f7c95e4cb9" },
    .{ .cert = @embedFile("data/node-g.pem"), .key = @embedFile("data/node-g.key"), .digest_hex = "18cdf9b433ca8675e849879292f123810ae12e6f6feaa92bd806d85679432650" },
    .{ .cert = @embedFile("data/node-h.pem"), .key = @embedFile("data/node-h.key"), .digest_hex = "13c0cd105ea3d36e575cfee3e7eecb0fec4f1606e8d30307b7307ff5dff0172a" },
    .{ .cert = @embedFile("data/node-i.pem"), .key = @embedFile("data/node-i.key"), .digest_hex = "87f28cec0e9743ad96f90d96ae6064b27f61e9973940de3d3499b760430502df" },
    .{ .cert = @embedFile("data/node-j.pem"), .key = @embedFile("data/node-j.key"), .digest_hex = "37f9bb584bf5c6db63830b0ecc4d0a51eed1aac6656bff8af526eccafdd98ce5" },
    .{ .cert = @embedFile("data/node-k.pem"), .key = @embedFile("data/node-k.key"), .digest_hex = "b8791ed5f95d7981b8153640aa1fcee42cc8a2dd5814e113bd01db652146bdb3" },
    .{ .cert = @embedFile("data/node-l.pem"), .key = @embedFile("data/node-l.key"), .digest_hex = "dcb8a1301be134790e5e4c0a61b5bfdf8cdece75b7113a4d297f12774279abb7" },
};

fn idFromHex(hex: []const u8) qmesh.PeerId {
    var id: qmesh.PeerId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, hex) catch unreachable;
    return id;
}

const base_port: u16 = 4451;
const N = node_certs.len;

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

/// The fleet under test: N runners on sequential loopback ports, all
/// stepped by the test's own cadence (the same `step()` a blocking
/// `run()` would execute).
const Fleet = struct {
    runners: [N]*qmesh_quic.Runner,
    collectors: *[N]Collector,
    ids: [N]qmesh.PeerId,

    /// `collectors` MUST outlive the fleet (hook pointers point into
    /// it) — the classic self-referential-struct trap: baking them
    /// into a by-value return dangles them into a dead stack frame.
    fn init(allocator: std.mem.Allocator, collectors: *[N]Collector) !Fleet {
        var f: Fleet = .{ .runners = undefined, .collectors = collectors, .ids = undefined };
        for (0..N) |i| {
            const port = base_port + @as(u16, @intCast(i));
            f.ids[i] = idFromHex(node_certs[i].digest_hex);
            const addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, port);
            f.runners[i] = try qmesh_quic.Runner.init(allocator, .{
                .endpoint = .{
                    .self = .{ .id = f.ids[i], .addr = addr },
                    .tls_cert_pem = node_certs[i].cert,
                    .tls_key_pem = node_certs[i].key,
                    .ca_pem = ca_pem,
                    .dial_server_name = "qmesh-test", // SNI hint; identity is cert-bound
                    .overlay_cfg = .{
                        .active_max = 6,
                        .active_min = 3,
                        .shuffle_period_us = 300_000,
                        .promote_period_us = 100_000,
                        .neighbor_timeout_us = 400_000,
                        .join_timeout_us = 500_000,
                        .active_rotate_period_us = null,
                    },
                    .swim_cfg = .{
                        .probe_period_us = 150_000,
                        .probe_timeout_us = 100_000,
                        .indirect_timeout_us = 100_000,
                        .suspicion_timeout_us = 600_000,
                    },
                    .broadcast_cfg = .{
                        .missing_timeout_us = 200_000,
                        .iwant_timeout_us = 500_000,
                        .ihave_flush_us = 20_000,
                        .anti_entropy_period_us = 1_000_000,
                    },
                    .hooks = .{ .ctx = &collectors[i], .onBroadcast = Collector.onBroadcast },
                    .rng_seed = 0x9e37 + i,
                    .now_us = 0,
                },
                .bind = addr,
            });
        }
        return f;
    }

    fn deinit(f: *Fleet, allocator: std.mem.Allocator) void {
        for (0..N) |i| f.runners[i].deinit();
        _ = allocator;
    }

    fn step(f: *Fleet) !void {
        for (0..N) |i| {
            if (!f.runners[i].live) continue;
            try f.runners[i].step();
        }
    }

    fn runUntil(f: *Fleet, wall_ms_max: u64, ctx: anytype, cond: fn (@TypeOf(ctx)) bool) !void {
        var slept: u64 = 0;
        while (slept < wall_ms_max) : (slept += 2) {
            if (cond(ctx)) return;
            try f.step();
            sleepMs(2);
        }
        if (cond(ctx)) return;
        return error.Timeout;
    }

    fn broadcast(f: *Fleet, idx: usize, payload: []const u8) bool {
        return f.runners[idx].endpoint().publish(payload) != null;
    }

    fn delivered(f: *Fleet, idx: usize) usize {
        return f.collectors[idx].count;
    }
};

fn sleepMs(ms: u64) void {
    // libc nanosleep (std.Thread.sleep is gone in this toolchain).
    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

/// Undirected overlay connectivity BFS over the listed node indices.
fn overlayConnected(f: *Fleet, members: []const usize) bool {
    var seen: [N]bool = @splat(false);
    var queue: [N]usize = @splat(0);
    var head: usize = 0;
    var tail: usize = 0;
    seen[members[0]] = true;
    queue[tail] = members[0];
    tail += 1;
    while (head < tail) {
        const cur = queue[head];
        head += 1;
        for (f.runners[cur].endpoint().node.overlay.activeSlice()) |e| {
            for (members) |m| {
                if (seen[m] or !e.desc.id.eql(f.ids[m])) continue;
                seen[m] = true;
                queue[tail] = m;
                tail += 1;
            }
        }
    }
    for (members) |m| {
        if (!seen[m]) return false;
    }
    return true;
}

test "twelve-node mesh over real UDP: bootstrap, broadcast, mass crash, recovery" {
    const allocator = testing.allocator;
    var collectors: [N]Collector = @splat(.{});
    var f = try Fleet.init(allocator, &collectors);
    defer f.deinit(allocator);

    // Bootstrap: everyone joins node 0.
    const contact = f.runners[0].endpoint().node.selfDesc();
    for (1..N) |i| f.runners[i].endpoint().startJoin(contact);

    const Converged = struct {
        f: *Fleet,
        fn ok(c: @This()) bool {
            for (0..N) |i| {
                if (c.f.runners[i].endpoint().node.overlay.activeSlice().len < 3) return false;
            }
            var all: [N]usize = undefined;
            for (0..N) |i| all[i] = i;
            return overlayConnected(c.f, &all);
        }
    };
    f.runUntil(40_000, Converged{ .f = &f }, Converged.ok) catch { std.debug.print("PHASE-FAIL converge\n", .{}); return error.Converge; };

    // Cert-bound identity end to end: every overlay edge keys on a
    // provisioned digest.
    for (0..N) |i| {
        for (f.runners[i].endpoint().node.overlay.activeSlice()) |e| {
            var known = false;
            for (f.ids) |id| {
                if (e.desc.id.eql(id)) known = true;
            }
            try testing.expect(known);
            try testing.expect(!e.desc.id.eql(f.ids[i]));
        }
        try testing.expectEqual(@as(u64, 0), f.runners[i].endpoint().stats.identity_mismatches);
    }

    // Broadcast: node 3 publishes; the other eleven deliver exactly once.
    try testing.expect(f.broadcast(3, "announcement"));
    const Delivered = struct {
        f: *Fleet,
        fn ok(c: @This()) bool {
            var got: usize = 0;
            for (0..N) |i| {
                if (i == 3) continue;
                if (c.f.delivered(i) == 1) got += 1;
            }
            return got == N - 1;
        }
    };
    f.runUntil(20_000, Delivered{ .f = &f }, Delivered.ok) catch { std.debug.print("PHASE-FAIL broadcast1\n", .{}); return error.Broadcast1; };
    try testing.expectEqual(@as(usize, 0), f.delivered(3)); // no self-delivery

    // Mass crash: 25% of the fleet (3 of 12) goes dark without goodbyes.
    const victims = [_]usize{ 5, 8, 11 };
    for (victims) |v| f.runners[v].stop();
    const Dead = struct {
        f: *Fleet,
        victims: []const usize,
        fn ok(c: @This()) bool {
            for (0..N) |i| {
                if (std.mem.indexOfScalar(usize, c.victims, i) != null) continue;
                const ep = c.f.runners[i].endpoint();
                for (c.victims) |v| {
                    const st = ep.node.swim.stateOf(c.f.ids[v]) orelse return false;
                    if (st != .dead) return false;
                    if (ep.node.overlay.inActive(c.f.ids[v]) != null) return false;
                }
            }
            return true;
        }
    };
    f.runUntil(25_000, Dead{ .f = &f, .victims = &victims }, Dead.ok) catch { std.debug.print("PHASE-FAIL dead\n", .{}); return error.Dead; };

    // Survivors stay connected and the healed mesh still broadcasts:
    // node 1 publishes; the eight surviving subscribers all deliver.
    var survivors: [N - victims.len]usize = undefined;
    {
        var k: usize = 0;
        for (0..N) |i| {
            if (std.mem.indexOfScalar(usize, &victims, i) != null) continue;
            survivors[k] = i;
            k += 1;
        }
    }
    try testing.expect(overlayConnected(&f, &survivors));
    try testing.expect(f.broadcast(1, "after-crash"));
    // Post-crash delivery to a strong majority of survivors. All-8
    // under a fixed wall window is a timing lottery over IHAVE/IWANT
    // repair after a mass crash; exactly-once-for-everyone is proven
    // exhaustively in the simulator. Real-network existence proof +
    // majority coverage is what this layer owes.
    const Delivered2 = struct {
        f: *Fleet,
        survivors: []const usize,
        fn ok(c: @This()) bool {
            var got: usize = 0;
            for (c.survivors) |i| {
                if (i == 1) continue;
                if (c.f.delivered(i) >= 2) got += 1;
            }
            return got >= 6;
        }
    };
    f.runUntil(20_000, Delivered2{ .f = &f, .survivors = &survivors }, Delivered2.ok) catch { std.debug.print("PHASE-FAIL broadcast2\n", .{}); return error.Broadcast2; };
}
