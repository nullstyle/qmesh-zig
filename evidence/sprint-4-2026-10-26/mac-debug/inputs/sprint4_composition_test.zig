//! Public fault and seeded recovery acceptance with one selected QUIC module.
const std = @import("std");
const public_faults = @import("public_faults");
const chaos = @import("mesh_chaos");

test "Sprint 4 public messaging faults preserve admission and terminal outcomes" {
    const report = try public_faults.run(std.testing.allocator, std.testing.io, .{});
    try std.testing.expect(report.completed);
    try std.testing.expectEqual(@as(usize, 15), report.accepted);
    try std.testing.expectEqual(report.accepted, report.terminal);
    try std.testing.expectEqual(report.terminal, report.succeeded + report.authorization_denied + report.canceled + report.deadline_exceeded + report.peer_closed);
    try std.testing.expect(report.queue_refused > 0);
    try std.testing.expect(report.inflight_refused > 0);
    try std.testing.expect(report.canceled > 0);
    try std.testing.expect(report.deadline_exceeded > 0);
    try std.testing.expect(report.authorization_denied > 0);
    try std.testing.expect(report.role_rejected > 0);
    try std.testing.expect(report.role_positive_control_ready);
    try std.testing.expect(report.peer_closed > 0);
    try std.testing.expect(report.remote_close_observed);
    try std.testing.expect(report.remote_loss_us < report.loss_request_deadline_ms * 1000);
    try std.testing.expect(report.healthy_succeeded > 0);
    try std.testing.expect(report.goaway_events > 0);
    try std.testing.expect(report.goaway_refused > 0);
    try std.testing.expect(report.late_reply_attempts > 0);
    try std.testing.expect(report.stale_handle_rejected > 0);
    try std.testing.expect(report.reconnected);
    try std.testing.expect(report.drain_closed);
    try std.testing.expectEqual(report.events_received, report.events_deinitialized);
    try std.testing.expectEqual(report.handles_retained, report.handles_released);
    try std.testing.expectEqual(@as(usize, 0), report.pending_at_end);
    try std.testing.expectEqual(@as(usize, 0), report.duplicate_terminals);
    try std.testing.expect(report.ordinary_events_dropped > 0);
    try std.testing.expect(report.peak_outstanding_per_client <= report.max_requests_per_client);
    try std.testing.expect(report.peak_retained_handles <= report.handle_capacity);
    try std.testing.expect(report.peak_server_sessions <= report.max_sessions_per_actor);
}

test "Sprint 4 seeded multi-node recovery survives membership and endpoint changes" {
    const options: chaos.Options = .{};
    const report = try chaos.runScenario(std.testing.allocator, std.testing.io, options);
    try std.testing.expectEqual(options.seed, report.seed);
    try std.testing.expect(report.converged);
    for (report.replica_revisions) |revision|
        try std.testing.expectEqual(report.authority_revision, revision);
    try std.testing.expectEqual(@as(usize, 13), report.logical_actions_completed);
    try std.testing.expect(report.application_restarts > 0);
    try std.testing.expect(report.endpoint_moves > 0);
    try std.testing.expect(report.suspect_preserved_routes > 0);
    try std.testing.expect(report.suspect_new_dials_paused > 0);
    try std.testing.expect(report.dead_route_removals > 0);
    try std.testing.expect(report.absent_route_removals > 0);
    try std.testing.expect(report.stale_endpoint_rejected);
    try std.testing.expect(report.wrong_identity_rejected);
    try std.testing.expect(report.decoy_positive_control_ready);
    try std.testing.expect(report.snapshot_timeouts > 0);
    try std.testing.expectEqual(report.snapshot_attempts, report.snapshot_replies + report.snapshot_timeouts + report.request_peer_closures);
    try std.testing.expectEqual(report.snapshot_replies, report.snapshots_applied + report.stale_snapshots_rejected);
    try std.testing.expect(report.hints_evicted > 0);
    try std.testing.expectEqual(@as(usize, 0), report.hints_delivered_after_heal);
    try std.testing.expect(report.peak_pending_requests_per_replica <= 1);
    try std.testing.expect(report.peak_pool_entries_per_replica <= 1);
    try std.testing.expect(report.peak_total_pool_entries <= 3);
    try std.testing.expect(report.peak_mesh_session_records <= 64);
    try std.testing.expect(report.peak_mesh_server_slots <= 32);
}
