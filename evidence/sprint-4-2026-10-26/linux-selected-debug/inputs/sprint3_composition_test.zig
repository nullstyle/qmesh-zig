//! Public application workloads with one selected transport module.
const std = @import("std");
const pubsub = @import("pubsub_workload");
const recovery = @import("snapshot_recovery");

test "Sprint 3 reliable publications isolate slow subscribers and resubscribe" {
    const options: pubsub.Options = .{};
    const report = try pubsub.run(std.testing.allocator, std.testing.io, options);
    try std.testing.expectEqual(options.publications, report.attempted);
    try std.testing.expectEqual(3 * options.publications, report.matched);
    try std.testing.expectEqual(2 * options.publications, report.healthy_delivered);
    try std.testing.expectEqual(@as(usize, 0), report.slow_delivered);
    try std.testing.expect(report.backpressured > 0);
    try std.testing.expect(report.queued >= 2 * options.publications);
    try std.testing.expect(report.peak_pending_messages <= 3 * options.queue_messages);
    try std.testing.expect(report.peak_pending_bytes <= 3 * options.queue_bytes);
    try std.testing.expect(report.reconnected);
}

test "Sprint 3 snapshots recover state after every change hint is lost" {
    const report = try recovery.runScenario(std.testing.allocator, std.testing.io, .{});
    try std.testing.expect(report.converged);
    try std.testing.expectEqual(report.authority_revision, report.replica_revision);
    try std.testing.expect(report.gossip_only_revision < report.authority_revision);
    try std.testing.expect(report.hints_published > 0);
    try std.testing.expectEqual(report.hints_published, report.hints_evicted);
    try std.testing.expectEqual(@as(usize, 0), report.hints_delivered_after_heal);
    try std.testing.expect(report.snapshot_timeouts > 0);
    try std.testing.expect(report.snapshots_applied > 0);
    try std.testing.expect(report.snapshot_bytes > 0);
    try std.testing.expect(report.peak_pending_requests <= 1);
    try std.testing.expect(report.peak_pool_entries <= 1);
}
