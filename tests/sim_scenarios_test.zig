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

fn fastSwimCfg() qmesh.swim.Config {
    return .{
        .probe_period_us = 200_000,
        .probe_timeout_us = 100_000,
        .indirect_timeout_us = 100_000,
        .suspicion_timeout_us = 400_000,
    };
}

fn fastBroadcastCfg() qmesh.plumtree.Config {
    return .{
        .missing_timeout_us = 200_000,
        .iwant_timeout_us = 500_000,
        .ihave_flush_us = 20_000,
        .anti_entropy_period_us = 2_000_000,
    };
}

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
    var world = qsim.World.init(testing.allocator, 1, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
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
    var world = qsim.World.init(testing.allocator, 7, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
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
    var world = qsim.World.init(testing.allocator, 11, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
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
    var world = qsim.World.init(testing.allocator, 23, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
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
    var world = qsim.World.init(testing.allocator, 31, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{ .drop_bp = 500 });
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
    var world = qsim.World.init(testing.allocator, 41, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
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

test "SWIM: killed members are suspected and confirmed cluster-wide" {
    var world = qsim.World.init(testing.allocator, 77, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 12) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(20_000_000); // overlay converges; member tables fill
    try testing.expectEqual(@as(usize, 1), world.componentCount());

    const victims = [_]u32{ 2, 5, 8, 11 };
    for (victims) |v| try world.kill(v);

    // Probe (≤200 ms) + indirect (≤200 ms) + suspicion (≤400 ms), then
    // piggybacked CONFIRM spreads with the probes.
    try world.runFor(15_000_000);

    for (world.nodes.items, 0..) |sn, idx| {
        if (!world.alive.items[idx]) continue;
        for (victims) |v| {
            const victim_id = world.descs.items[v].id;
            const state = sn.node.swim.stateOf(victim_id) orelse continue;
            try testing.expectEqual(qmesh.swim.MemberState.dead, state);
            // Confirmed-dead members leave the passive view.
            try testing.expect(sn.node.overlay.inPassive(victim_id) == null);
        }
    }
    // Suspicion counted somewhere (probes really failed).
    var total_suspects: u64 = 0;
    for (world.nodes.items, 0..) |sn, idx| {
        if (world.alive.items[idx]) total_suspects += sn.node.swim.stats.suspects_declared;
    }
    try testing.expect(total_suspects > 0);
}

test "broadcast reaches every reachable node exactly once; tree trims" {
    var world = qsim.World.init(testing.allocator, 91, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 12) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(20_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());

    const eager_before = world.totalEagerEdges();

    // First broadcast: everyone (except the publisher) delivers once.
    try testing.expect(world.broadcast(0, "announcement-1") != null);
    try world.runFor(3_000_000);
    for (0..12) |n| {
        const got = world.deliveredCount(@intCast(n));
        if (n == 0) {
            try testing.expectEqual(@as(usize, 0), got); // no self-delivery
        } else {
            try testing.expectEqual(@as(usize, 1), got);
        }
    }

    // More broadcasts from the same origin: duplicates seen via eager
    // push trim the tree (Plumtree's whole point).
    try testing.expect(world.broadcast(0, "announcement-2") != null);
    try world.runFor(3_000_000);
    try testing.expect(world.broadcast(0, "announcement-3") != null);
    try world.runFor(3_000_000);
    for (0..12) |n| {
        const want: usize = if (n == 0) 0 else 3;
        try testing.expectEqual(want, world.deliveredCount(@intCast(n)));
    }
    const eager_after = world.totalEagerEdges();
    try testing.expect(eager_after < eager_before);
    try testing.expect(world.totalDemotions() > 0);
}

test "anti-entropy repairs broadcasts a paused node missed" {
    var world = qsim.World.init(testing.allocator, 92, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 12) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(20_000_000);

    // Node 5 freezes (inbound dropped, clock frozen); four broadcasts
    // happen while it is dark.
    try world.pause(5, 5_000_000);
    for (1..5) |k| {
        var buf: [32]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "missed-{d}", .{k}) catch unreachable;
        try testing.expect(world.broadcast(0, payload) != null);
        try world.runFor(500_000);
    }
    try testing.expectEqual(@as(usize, 0), world.deliveredCount(5));

    // Resume: exchange anti-entropy discovers the gap, IWANT repair
    // (reliable class) delivers it.
    try world.runFor(12_000_000);
    try testing.expectEqual(@as(usize, 4), world.deliveredCount(5));
    // And the messages it DID get arrived intact.
    const seqs = world.deliveredSeqs(5);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, seqs);
}

test "asymmetric link: indirect probing rescues one-way loss" {
    var world = qsim.World.init(testing.allocator, 55, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 8) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(20_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());

    // One-directional blackholes between nodes 1 and 3: each side's
    // DIRECT probes and acks toward the other are lost, but paths
    // through the other six nodes survive in both directions. SWIM's
    // PING_REQ indirect probing resolves the probes through relays —
    // often before suspicion even fires — so neither side may ever
    // CONFIRM the other dead. That is exactly the fault the indirect
    // mechanism exists for.
    try world.blackholeOneWay(1, 3);
    try world.blackholeOneWay(3, 1);
    try world.runFor(15_000_000);

    for ([_]u32{ 1, 3 }) |a| {
        const other: u32 = if (a == 1) 3 else 1;
        const other_id = world.descs.items[other].id;
        const st = world.nodes.items[a].node.swim.stateOf(other_id) orelse
            return error.MemberLost;
        try testing.expect(st != .dead);
        // Probing really ran (the link really was exercised).
        try testing.expect(world.nodes.items[a].node.swim.stats.probes_sent > 0);
    }
    // The cluster stays connected through the healthy paths.
    try testing.expectEqual(@as(usize, 1), world.componentCount());
}

test "identical seeds produce byte-identical overlay state" {
    const run = struct {
        fn f(allocator: std.mem.Allocator, out_fingerprint: *u64, out_stats: *qsim.world.WorldStats) !void {
            var world = qsim.World.init(allocator, 0xabcdef, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
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
