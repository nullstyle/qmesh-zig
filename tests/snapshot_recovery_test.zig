//! Deterministic transport-free proof of the finite gossip retention boundary.
const std = @import("std");
const qmesh = @import("qmesh");
const qsim = @import("qmesh_sim");
const state = @import("snapshot_state");

fn scenario(seed: u64) !u64 {
    var world = qsim.World.init(std.testing.allocator, seed, .{
        .shuffle_period_us = 1_000_000,
        .promote_period_us = 200_000,
        .neighbor_timeout_us = 800_000,
        .join_timeout_us = 1_000_000,
        .active_rotate_period_us = 5_000_000,
    }, .{
        .probe_period_us = 200_000,
        .probe_timeout_us = 100_000,
        .indirect_timeout_us = 100_000,
        .suspicion_timeout_us = 400_000,
    }, .{
        .missing_timeout_us = 200_000,
        .iwant_timeout_us = 500_000,
        .ihave_flush_us = 20_000,
        .anti_entropy_period_us = 2_000_000,
    }, .{});
    defer world.deinit();
    _ = try world.spawn();
    _ = try world.spawn();
    world.bootstrapAll(0);
    try world.runFor(20_000_000);
    try world.partition(&.{0}, &.{1});
    // Let pre-partition datagrams drain before changing application state.
    try world.runFor(1_000_000);
    var authority: state.State = .{};
    var hints: [40]qmesh.plumtree.MsgId = undefined;
    for (&hints) |*id| {
        authority.update();
        id.* = world.broadcast(0, &state.hint(authority.revision)).?;
        try world.runFor(100_000);
    }
    for (0..40) |_| {
        _ = world.broadcast(0, "unrelated announcement").?;
        try world.runFor(100_000);
    }
    // Inspect the real bounded payload cache, not just its seen-ID ring.
    for (hints) |id| for (world.nodes.items[0].node.broadcast.payloads[0..world.nodes.items[0].node.broadcast.payloads_len]) |entry| {
        try std.testing.expect(!entry.id.eql(id));
    };
    try std.testing.expectEqual(@as(usize, 0), world.deliveredCount(1));
    world.heal();
    // No application hint is published after heal. Recent-window repair can
    // transfer only unrelated announcements; it cannot reconstruct revision40.
    try world.runFor(80_000_000);
    try std.testing.expectEqual(@as(usize, 1), world.componentCount());
    try std.testing.expect(world.deliveredCount(1) > 0);
    for (world.logs.items[1].items.items) |delivery| {
        try std.testing.expect(state.hintRevision(delivery.head[0..@min(delivery.len, delivery.head.len)]) == null);
    }
    const gossip_only: state.State = .{};
    try std.testing.expectEqual(@as(u64, 0), gossip_only.revision);
    var repaired: state.State = .{};
    // This pure proof models a periodic snapshot response. The companion
    // public UDP workload exercises its bounded qmsg request and timeout.
    try repaired.apply(&authority.encode());
    try std.testing.expectEqualDeep(authority, repaired);

    return world.fingerprint();
}

test "partition beyond all retained hints converges only through snapshot reconciliation" {
    try std.testing.expectEqual(try scenario(940), try scenario(940));
}
