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

fn rankedCfg() qmesh.OverlayConfig {
    // defaultCfg plus the multi-region locality posture (fly profile
    // shape): 3 ranked slots of a 10-slot view.
    var cfg = defaultCfg();
    cfg.ranked_slots = 3;
    return cfg;
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

test "two regions: ranked minority goes near, random majority stays one component" {
    // Zone-shaped latency: 2ms intra-region, 40ms cross (80ms RTT —
    // inside the fast cfg's direct budget so first-contact probes
    // measure instead of timeout; the fly profile's 800ms floor gives
    // the same headroom over its 300ms worst pairs). Every node ranks
    // 3 locality slots; the other 7 of its 10 stay uniformly random —
    // the small-world majority that keeps the cluster connected.
    const overlay_cfg = rankedCfg();
    var world = qsim.World.init(testing.allocator, 141, overlay_cfg, fastSwimCfg(), fastBroadcastCfg(), .{
        .zone_intra_delay_us = 2_000,
        .zone_cross_delay_us = 40_000,
    });
    defer world.deinit();
    var i: u32 = 0;
    while (i < 12) : (i += 1) _ = try world.spawn();
    // Two regions of six.
    for (6..12) |n| world.setZone(@intCast(n), 1);
    world.bootstrapAll(0);
    try world.runFor(30_000_000);

    // The random majority kept global connectivity...
    try testing.expect(world.minActiveView() >= 6);
    try testing.expectEqual(@as(usize, 1), world.componentCount());
    try testing.expect(world.activeEdgesSessionBacked());

    for (world.nodes.items, 0..) |sn, idx| {
        if (!world.alive.items[idx]) continue;
        // The ranked minority is entirely same-region (the lowest-RTT
        // peers this node knows) and the same-region preference is
        // visible in the active view. (Edge placement beyond the
        // ranked set is preference-BIASED, not guaranteed — vacancies
        // are partly filled by the uniform scan; the deterministic
        // preference itself is unit-pinned in hyparview.zig.)
        const ranked = qmesh.hyparview.TestHooks.rankedSlice(&sn.node.overlay);
        try testing.expectEqual(@as(usize, 3), ranked.len);
        var intra_active: usize = 0;
        for (sn.node.overlay.activeSlice()) |e| {
            const other = world.index.get(e.desc.id).?;
            if (world.zones.items[other] == world.zones.items[idx]) intra_active += 1;
        }
        try testing.expect(intra_active >= 1);
        for (ranked) |r| {
            const other = world.index.get(r.id).?;
            try testing.expectEqual(world.zones.items[idx], world.zones.items[other]);
        }
        // RTT really was measured for both distance classes (the
        // mechanism the ranking and budgets ride on).
        var saw_intra = false;
        var saw_cross = false;
        for (world.descs.items, 0..) |d, j| {
            if (j == idx) continue;
            const rtt = sn.node.swim.rttOf(d.id);
            if (rtt == 0) continue;
            if (world.zones.items[j] == world.zones.items[idx]) {
                if (rtt < 10_000) saw_intra = true;
            } else {
                if (rtt > 60_000) saw_cross = true;
            }
        }
        try testing.expect(saw_intra);
        try testing.expect(saw_cross);
    }
}

test "fly profile, two clean nodes: probing must not fabricate failures" {
    // Investigation repro for the fly smoke finding: on real
    // transports (fly 6pn AND loopback) the fly profile suspects a
    // healthy lone peer at a ~25-45% probe failure rate despite 0%
    // path loss. The sim is the deterministic bisector: if the rate
    // reproduces here the bug is in the pure cores; if the sim is
    // clean the bug lives in the real transport seam.
    const p = qmesh.profiles.fly_multi_region;
    var world = qsim.World.init(testing.allocator, 151, p.overlay, p.swim, p.broadcast, .{});
    defer world.deinit();
    _ = try world.spawn();
    _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(60_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());

    var probes: u64 = 0;
    var suspects: u64 = 0;
    var acks_rx: u64 = 0;
    var acks_tx: u64 = 0;
    for (world.nodes.items, 0..) |sn, i| {
        if (!world.alive.items[i]) continue;
        probes += sn.node.swim.stats.probes_sent;
        suspects += sn.node.swim.stats.suspects_declared;
        acks_rx += sn.node.swim.stats.acks_received;
        acks_tx += sn.node.swim.stats.acks_sent;
    }
    std.debug.print("sim fly-profile anatomy: probes={d} suspects={d} acks_tx={d} acks_rx={d}\n", .{ probes, suspects, acks_tx, acks_rx });
    // A clean pair on a lossless virtual link: failures must be
    // negligible (bootstrap races aside), never tens of percent.
    if (probes > 20) {
        try testing.expect(suspects * 20 < probes); // < 5%
    }
}

test "corroborated suspicion accelerates eviction (Ta)" {
    // A/B on identical worlds (same seed): 5s suspicion window, kills
    // at t0, observe at t0+5s. Without Ta nobody can confirm yet
    // (first suspicions arm ~1.5s in; +5s window > observation). With
    // Ta (3 distinct forwarders halve the window) the cluster agrees
    // on the kill inside the budget.
    const run = struct {
        fn f(allocator: std.mem.Allocator, ta: bool, out_confirms: *usize, out_accel: *u64) !void {
            var world = qsim.World.init(allocator, 161, defaultCfg(), .{
                .probe_period_us = 200_000,
                .probe_timeout_us = 100_000,
                .indirect_timeout_us = 100_000,
                .suspicion_timeout_us = 5_000_000,
                .ta_min_corroborators = if (ta) 3 else 0,
            }, fastBroadcastCfg(), .{});
            defer world.deinit();
            var i: u32 = 0;
            while (i < 12) : (i += 1) _ = try world.spawn();
            world.bootstrapAll(0);
            try world.runFor(20_000_000);
            for ([_]u32{ 4, 9 }) |victim| try world.kill(victim);
            try world.runFor(5_000_000);
            out_confirms.* = 0;
            out_accel.* = 0;
            for (world.nodes.items, 0..) |sn, idx| {
                if (!world.alive.items[idx]) continue;
                out_accel.* += sn.node.swim.stats.ta_accelerations;
                for ([_]u32{ 4, 9 }) |victim| {
                    const st = sn.node.swim.stateOf(world.descs.items[victim].id) orelse continue;
                    if (st == .dead) out_confirms.* += 1;
                }
            }
        }
    }.f;

    var with_confirms: usize = 0;
    var with_accel: u64 = 0;
    var without_confirms: usize = 0;
    var without_accel: u64 = 0;
    try run(testing.allocator, true, &with_confirms, &with_accel);
    try run(testing.allocator, false, &without_confirms, &without_accel);
    std.debug.print("ta A/B: with={d}/20 (accel={d}) without={d}/20\n", .{ with_confirms, with_accel, without_confirms });
    try testing.expectEqual(@as(usize, 0), without_confirms);
    try testing.expect(with_accel > 0);
    try testing.expect(with_confirms >= 15);
}

test "flaky node is never confirmed dead (buddy self-diagnosis posture)" {
    // Node 3 drops 30% of inbound frames: its probes of others fail
    // often enough to suspect, but its buddy set goes quiet too —
    // the majority-silence signal feeds its own local health, the
    // suspicion windows extend, refutations land, and the cluster
    // (which hears node 3 fine) never agrees on its death.
    var world = qsim.World.init(testing.allocator, 171, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 8) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(10_000_000);
    world.flaky(3, 3_000);
    try world.runFor(30_000_000);

    const n3 = world.descs.items[3].id;
    for (world.nodes.items, 0..) |sn, idx| {
        if (!world.alive.items[idx] or idx == 3) continue;
        const st = sn.node.swim.stateOf(n3) orelse return error.MemberLost;
        try testing.expect(st != .dead);
    }
    // The flaky node itself must not wedge-confirm its whole table.
    var alive_peers: usize = 0;
    for (world.descs.items, 0..) |d, j| {
        if (j == 3) continue;
        const st = world.nodes.items[3].node.swim.stateOf(d.id) orelse continue;
        if (st == .alive) alive_peers += 1;
    }
    std.debug.print("flaky: node3 alive peers={d}/7 lh={d}\n", .{ alive_peers, world.nodes.items[3].node.swim.local_health });
    try testing.expect(alive_peers >= 1);
    try testing.expectEqual(@as(usize, 1), world.componentCount());
}

test "fly profile cadence: sustained all-node publishing converges exactly-once" {
    // The 35-min loopback soak measured 65-95% steady-state delivery
    // under the fly profile with all nodes publishing every 10s. The
    // sim runs the identical cadence deterministically to split the
    // deficit: core (reproduces here) vs real-transport seam (clean
    // here — and the endpoint's dead-stream-decoder table was the
    // seam culprit, since fixed).
    const p = qmesh.profiles.fly_multi_region;
    var world = qsim.World.init(testing.allocator, 181, p.overlay, p.swim, p.broadcast, .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 12) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(30_000_000);

    // Every node publishes every 10s for 120s (the soak cadence),
    // driven through the same per-node timers the driver would use.
    var t: u64 = 0;
    while (t < 120_000_000) : (t += 10_000_000) {
        for (0..12) |n| _ = world.broadcast(@intCast(n), "soak");
        try world.runFor(10_000_000);
    }
    try world.runFor(30_000_000); // settle: repairs + anti-entropy

    var total_expected: usize = 0;
    var total_got: usize = 0;
    var worst: usize = std.math.maxInt(usize);
    for (0..12) |n| {
        const got = world.deliveredCount(@intCast(n));
        const expected = 12 * 11; // 12 publishes x 11 other nodes
        total_expected += expected;
        total_got += got;
        const ratio = got * 100 / expected;
        if (ratio < worst) worst = ratio;
    }
    std.debug.print("fly-cadence delivery: {d}/{d} worst-node {d}%\n", .{ total_got, total_expected, worst });
    try testing.expectEqual(total_expected, total_got);
}

test "fly migration pause: multi-region profile does not evict a pausing node" {
    const p = qmesh.profiles.fly_multi_region;
    var world = qsim.World.init(testing.allocator, 61, p.overlay, p.swim, p.broadcast, .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 8) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(15_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());
    const active_before = world.nodes.items[4].node.overlay.activeSlice().len;

    try world.pause(4, 3_000_000); // migration-shaped pause
    try world.runFor(5_000_000);
    try world.runFor(15_000_000);

    const n4id = world.descs.items[4].id;
    try testing.expectEqual(@as(usize, 1), world.componentCount());
    try testing.expect(world.nodes.items[4].node.overlay.activeSlice().len >= active_before);
    for (world.nodes.items, 0..) |sn, idx| {
        if (!world.alive.items[idx] or idx == 4) continue;
        const st = sn.node.swim.stateOf(n4id) orelse return error.MemberLost;
        try testing.expect(st != .dead);
        try testing.expect(sn.node.overlay.inActive(n4id) != null);
    }
}

test "event ring: kill and loss leave a causal timeline in witness rings" {
    // Concept 2's data source proven in the deterministic world
    // (docs/observability-ux.md): a crashed member's story — session
    // loss, suspicion, confirm — lands on every survivor's merged
    // ring in causal order for the right peer, and delivery loss
    // records the repairs that recovered it.
    var world = qsim.World.init(testing.allocator, 91, defaultCfg(), fastSwimCfg(), fastBroadcastCfg(), .{});
    defer world.deinit();
    var i: u32 = 0;
    while (i < 8) : (i += 1) _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(20_000_000);
    try testing.expectEqual(@as(usize, 1), world.componentCount());

    // Kill node 5 (no goodbyes — sessions sever with notifications).
    try world.kill(5);
    try world.runFor(10_000_000); // fast profile: probe, indirect, suspect, confirm

    const victim = world.descs.items[5].id;
    var witnesses: usize = 0;
    for (world.nodes.items, 0..) |sn, idx| {
        if (idx == 5 or !world.alive.items[idx]) continue;
        witnesses += 1;
        var ev: [96]qmesh.events.Event = undefined;
        const n = sn.node.recentEvents(&ev);
        var saw_down = false;
        var saw_sus = false;
        var saw_conf = false;
        var sus_older_than_conf = false;
        for (ev[0..n]) |e| {
            if (!e.peer.eql(victim)) continue;
            // newest-first iteration: the confirm must appear BEFORE
            // (newer than) the suspicion it grew out of.
            if (e.kind == .suspect and saw_conf) sus_older_than_conf = true;
            switch (e.kind) {
                .session_down => saw_down = true,
                .suspect => saw_sus = true,
                .confirm => saw_conf = true,
                else => {},
            }
        }
        try testing.expect(saw_down);
        try testing.expect(saw_sus);
        try testing.expect(saw_conf);
        try testing.expect(sus_older_than_conf);
    }

    // Delivery loss: publish repeated rounds under heavy datagram
    // loss and the rings record the repair activity that pulled
    // missed broadcasts — the delivery-dip texture beside the
    // membership story. (Eager push is redundant by design, so a
    // light-loss single round can slip every path; 30% over several
    // rounds reliably leaves eager-path gaps for IWANT to close.)
    world.policy.drop_bp = 3000;
    var round: u32 = 0;
    while (round < 4) : (round += 1) {
        for (0..8) |n| {
            if (world.alive.items[n]) _ = world.broadcast(@intCast(n), "lossy");
        }
        try world.runFor(3_000_000);
    }
    var any_repair = false;
    for (world.nodes.items, 0..) |sn, idx| {
        if (!world.alive.items[idx]) continue;
        var ev: [96]qmesh.events.Event = undefined;
        const n = sn.node.recentEvents(&ev);
        for (ev[0..n]) |e| {
            if (e.kind == .repair or e.kind == .repair_lapsed) any_repair = true;
        }
    }
    try testing.expect(any_repair);
    std.debug.print("event ring: {d} witnesses hold session+suspect+confirm in causal order; repairs recorded\n", .{witnesses});
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
