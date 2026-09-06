//! Deterministic simulation scenarios: the behavioral proof layer.
//!
//! Each scenario builds a `qsim.World`, injects faults, runs virtual
//! time, and asserts mesh properties:
//!
//! * bootstrap: two-node join, then a 20-node cluster converging to a
//!   single connected component with bounded views and session-backed
//!   active edges;
//! * churn: killing 30% of nodes, survivors heal;
//! * partition: split + heal re-merges (via active rotation);
//! * loss: 5% datagram loss does not prevent convergence;
//! * pause: a frozen node resumes and rejoins;
//! * determinism: identical seeds produce identical worlds.

const std = @import("std");
const qmesh = @import("qmesh");
const qsim = @import("qmesh_sim");

const testing = std.testing;

fn defaultCfg() qmesh.OverlayConfig {
    // Faster clocks than production defaults so scenarios exercise the
    // same state machines in less virtual time.
    return .{
        .shuffle_period_us = 1_000_000,
        .promote_period_us = 200_000,
        .neighbor_timeout_us = 800_000,
        .join_timeout_us = 1_000_000,
        .active_rotate_period_us = 5_000_000,
    };
}

test "two nodes join and hold a session-backed active edge" {
    var world = qsim.World.init(testing.allocator, 1, defaultCfg(), .{});
    defer world.deinit();
    const a = try world.spawn();
    const b = try world.spawn();
    world.nodes.items[b].node.startJoin(world.descs.items[a]);
    try world.runFor(50_000); // 50 ms: dial (5 ms) + join round trip

    try testing.expect(world.nodes.items[a].node.overlay.inActive(world.descs.items[b].id) != null);
    try testing.expect(world.nodes.items[b].node.overlay.inActive(world.descs.items[a].id) != null);
    try testing.expect(world.sessions.establishedPair(a, b));
    try testing.expect(world.activeEdgesSessionBacked());
    try testing.expectEqual(@as(usize, 1), world.componentCount());
}

test "20-node bootstrap converges to one component, bounded views" {
    var world = qsim.World.init(testing.allocator, 7, defaultCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 20) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(30_000_000); // 30 s virtual

    // Every live node reached at least active_min peers...
    try testing.expect(world.minActiveView() >= 6);
    // ...the overlay is a single connected component...
    try testing.expectEqual(@as(usize, 1), world.componentCount());
    // ...every active edge is a real session...
    try testing.expect(world.activeEdgesSessionBacked());
    // ...and the views respect the paper's bounds everywhere.
    for (world.nodes.items) |sn| {
        sn.node.overlay.checkInvariants();
        try testing.expect(sn.node.overlay.activeSlice().len <= 10);
        try testing.expect(sn.node.overlay.passiveSlice().len <= 40);
    }
}

test "killing 30% of nodes: survivors heal active views and stay connected" {
    var world = qsim.World.init(testing.allocator, 11, defaultCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 20) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(30_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());

    // Kill 6 of 20 (30%), biased away from the bootstrap contact.
    for ([_]u32{ 2, 5, 8, 11, 14, 17 }) |victim| try world.kill(victim);
    try testing.expectEqual(@as(usize, 14), world.liveNodes());

    try world.runFor(30_000_000);

    try testing.expect(world.minActiveView() >= 6);
    try testing.expectEqual(@as(usize, 1), world.componentCount());
    try testing.expect(world.activeEdgesSessionBacked());
    // No dead peer lingers in any survivor's active view (sessions
    // were severed, so session-down demoted them).
    for (world.nodes.items, 0..) |sn, idx| {
        if (!world.alive.items[idx]) continue;
        for (sn.node.overlay.activeSlice()) |e| {
            const other = world.index.get(e.desc.id).?;
            try testing.expect(world.alive.items[other]);
        }
    }
}

test "partition splits the overlay; heal re-merges through rotation" {
    var world = qsim.World.init(testing.allocator, 23, defaultCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 10) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(20_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());

    // 5/5 split: cross sessions die, each side must self-heal. A
    // 5-node side can hold at most 4 actives (n-1), so the assertion
    // here is "everyone within the side", not active_min.
    try world.partition(&.{ 0, 1, 2, 3, 4 }, &.{ 5, 6, 7, 8, 9 });
    try world.runFor(20_000_000);
    try testing.expectEqual(@as(usize, 2), world.componentCount());
    try testing.expect(world.minActiveView() >= 3); // each side internally woven

    // Heal: rotation + promotion bridges the halves again.
    world.heal();
    try world.runFor(40_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());
    try testing.expect(world.activeEdgesSessionBacked());
}

test "5% datagram loss still converges (self-healing)" {
    var world = qsim.World.init(testing.allocator, 31, defaultCfg(), .{ .drop_bp = 500 });
    defer world.deinit();
    var i: u32 = 0;
    while (i < 20) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(60_000_000); // slower under loss; give it time

    try testing.expect(world.minActiveView() >= 6);
    try testing.expectEqual(@as(usize, 1), world.componentCount());
    try testing.expect(world.activeEdgesSessionBacked());
    try testing.expect(world.stats.dropped_loss > 0); // the fault was real
}

test "paused node resumes and rejoins" {
    var world = qsim.World.init(testing.allocator, 41, defaultCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 8) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(15_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());

    // Freeze node 3 for 10 s of virtual time; its traffic drops, its
    // clock freezes. The cluster must remain connected without it.
    try world.pause(3, 10_000_000);
    try world.runFor(10_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());

    // It wakes up and the mesh re-includes it (its sessions survived,
    // so it may already be connected; if its edges were rotated away,
    // shuffle/promotion bring it back).
    try world.runFor(30_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());
    try testing.expect(world.minActiveView() >= 6);
    try testing.expect(world.stats.dropped_paused > 0);
}

test "identical seeds produce byte-identical overlay state" {
    const run = struct {
        fn f(allocator: std.mem.Allocator, out_fingerprint: *u64, out_stats: *qsim.world.WorldStats) !void {
            var world = qsim.World.init(allocator, 0xabcdef, defaultCfg(), .{});
            defer world.deinit();
            var i: u32 = 0;
            while (i < 12) : (i += 1) _ = try world.spawn();
            world.bootstrapAll(0);
            try world.runFor(15_000_000);
            for ([_]u32{ 1, 4 }) |victim| try world.kill(victim);
            try world.runFor(15_000_000);
            out_fingerprint.* = world.fingerprint();
            out_stats.* = world.stats;
        }
    }.f;

    var fa: u64 = 0;
    var fb: u64 = 0;
    var sa: qsim.world.WorldStats = undefined;
    var sb: qsim.world.WorldStats = undefined;
    try run(testing.allocator, &fa, &sa);
    try run(testing.allocator, &fb, &sb);
    try testing.expectEqual(fa, fb);
    try testing.expectEqual(sa.delivered, sb.delivered);
    try testing.expectEqual(sa.dropped_loss, sb.dropped_loss);
    try testing.expectEqual(sa.sessions_up, sb.sessions_up);
}
