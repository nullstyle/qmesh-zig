//! Seeded, transport-free replay of partition/retention and application policy.
const std = @import("std");
const qmesh = @import("qmesh");
const qsim = @import("qmesh_sim");
const messaging = @import("qmesh_messaging");
const plans = @import("chaos_plan");
const schema = @import("snapshot_state");
const a = std.testing.allocator;
const MockDialer = struct {
    peer: qmesh.PeerId,
    live: ?u64 = null,
    next: u64 = 1,
    dials: usize = 0,
    closes: usize = 0,
    endpoint: qmesh.Addr = .none,
    pub fn dial(self: *@This(), _: qmesh.PeerId, address: qmesh.Addr) !u64 {
        const sid = self.next;
        self.next += 1;
        self.dials += 1;
        self.live = sid;
        self.endpoint = address;
        return sid;
    }
    pub fn status(self: *@This(), sid: u64) ?messaging.SessionStatus {
        if (self.live == null or self.live.? != sid) return null;
        return .{ .state = .ready, .peer_cert_spki = self.peer.bytes };
    }
    pub fn close(self: *@This(), sid: u64) void {
        self.closes += 1;
        if (self.live == sid) self.live = null;
    }
    pub fn findReady(_: *@This(), _: qmesh.PeerId) ?u64 {
        return null;
    }
};
const Pool = messaging.Pool(MockDialer);
const Location = struct {
    address: qmesh.Addr,
    fn resolve(ctx: ?*anyopaque, _: qmesh.PeerDesc) !qmesh.Addr {
        return @as(*Location, @ptrCast(@alignCast(ctx.?))).address;
    }
    fn resolver(self: *Location) messaging.Resolver {
        return .{ .context = self, .resolve = resolve };
    }
};
const Replay = struct {
    plan_fingerprint: u64,
    virtual_fingerprint: u64,
    delivery_fingerprint: u64,
    final_state_hash: u64,
    final_revision: u64,
    payloads_evicted: usize,
    endpoint_changes: u64,
    route_closes: usize,
};
fn world(seed: u64) qsim.World {
    return qsim.World.init(a, seed, .{
        .shuffle_period_us = 1_000_000,
        .promote_period_us = 200_000,
        .neighbor_timeout_us = 800_000,
        .join_timeout_us = 1_000_000,
        .active_rotate_period_us = 5_000_000,
    }, .{
        .probe_period_us = 200_000,
        .probe_timeout_us = 100_000,
        .indirect_timeout_us = 100_000,
        .suspicion_timeout_us = 800_000,
        .dead_probe_every = 2,
    }, .{ .missing_timeout_us = 200_000, .iwant_timeout_us = 500_000, .ihave_flush_us = 20_000, .anti_entropy_period_us = 2_000_000 }, .{});
}
fn replay(seed: u64) !Replay {
    const plan = plans.generate(seed);
    var w = world(seed);
    defer w.deinit();
    for (0..12) |_| _ = try w.spawn();
    w.bootstrapAll(0);
    try w.runFor(20_000_000);
    try std.testing.expectEqual(@as(usize, 1), w.componentCount());
    const peer = w.descs.items[0].id;
    const owner = plan.probe_owner;
    var mock: MockDialer = .{ .peer = peer };
    var pool = try Pool.init(a, .{ .max_peers = 1, .retry_initial_us = 1, .retry_max_us = 10, .dial_timeout_us = 1_000_000, .idle_timeout_us = 0 });
    defer pool.deinit(&mock);
    var location: Location = .{ .address = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 5010) };
    _ = try pool.ensure(&w.nodes.items[owner].node, &mock, location.resolver(), peer, w.now_us);
    try pool.service(&w.nodes.items[owner].node, &mock, location.resolver(), w.now_us + 1);
    try std.testing.expect(pool.lookup(peer) != null);
    var authority: schema.State = .{};
    authority.update();
    var replicas: [11]schema.State = @splat(authority);
    const majority = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    try w.partition(&.{0}, &majority);
    var hints: [47]qmesh.plumtree.MsgId = undefined;
    for (hints[0..plan.updates]) |*hint| {
        authority.update();
        hint.* = w.broadcast(0, &schema.hint(authority.revision)).?;
    }
    for (0..plan.noise) |_| _ = w.broadcast(0, "unrelated seeded announcement").?;
    for (hints[0..plan.updates]) |hint| {
        const cache = &w.nodes.items[0].node.broadcast;
        for (cache.payloads[0..cache.payloads_len]) |entry| try std.testing.expect(!entry.id.eql(hint));
    }
    var suspected = false;
    for (0..200) |_| {
        try w.runFor(100_000);
        const state = w.nodes.items[owner].node.member(peer).?.state;
        if (state == .suspect) {
            try pool.service(&w.nodes.items[owner].node, &mock, location.resolver(), w.now_us);
            try std.testing.expect(pool.lookup(peer) != null);
            var fresh_pool = try Pool.init(a, .{ .max_peers = 1 });
            defer fresh_pool.deinit(&mock);
            const dials_before = mock.dials;
            try std.testing.expectError(error.PeerSuspected, fresh_pool.ensure(&w.nodes.items[owner].node, &mock, location.resolver(), peer, w.now_us));
            try std.testing.expectEqual(dials_before, mock.dials);
            try std.testing.expectEqual(@as(usize, 0), fresh_pool.count());
            suspected = true;
            break;
        }
    }
    try std.testing.expect(suspected);
    try w.runFor(20_000_000);
    try std.testing.expectEqual(qmesh.MemberState.dead, w.nodes.items[owner].node.member(peer).?.state);
    try pool.service(&w.nodes.items[owner].node, &mock, location.resolver(), w.now_us);
    try std.testing.expectEqual(@as(usize, 0), pool.count());
    // The application owner restarted; its in-memory authoritative state is
    // held by this fixture, not recovered from storage. No new hint is sent.
    authority.update();
    w.heal();
    try w.runFor(60_000_000);
    try std.testing.expectEqual(@as(usize, 1), w.componentCount());
    try std.testing.expectEqual(qmesh.MemberState.alive, w.nodes.items[owner].node.member(peer).?.state);
    for (w.logs.items[1..]) |log| for (log.items.items) |delivery| {
        try std.testing.expect(schema.hintRevision(delivery.head[0..@min(delivery.len, delivery.head.len)]) == null);
    };
    // Explicit application snapshot responses model the separate qmsg path.
    for (&replicas) |*replica| try replica.apply(&authority.encode());
    _ = try pool.ensure(&w.nodes.items[owner].node, &mock, location.resolver(), peer, w.now_us);
    try pool.service(&w.nodes.items[owner].node, &mock, location.resolver(), w.now_us + 1);
    const before_restart = pool.lookup(peer).?;
    mock.live = null;
    try pool.service(&w.nodes.items[owner].node, &mock, location.resolver(), w.now_us + 2);
    _ = try pool.ensure(&w.nodes.items[owner].node, &mock, location.resolver(), peer, w.now_us + 20);
    try pool.service(&w.nodes.items[owner].node, &mock, location.resolver(), w.now_us + 21);
    try std.testing.expect(pool.lookup(peer).? != before_restart);
    location.address = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 6010);
    try pool.service(&w.nodes.items[owner].node, &mock, location.resolver(), w.now_us + 22);
    try pool.service(&w.nodes.items[owner].node, &mock, location.resolver(), w.now_us + 23);
    try std.testing.expect(mock.endpoint.eql(location.address));
    try std.testing.expect(pool.stats.endpoint_changes > 0);
    authority.update();
    for (&replicas) |*replica| try replica.apply(&authority.encode());
    for (replicas) |replica| try std.testing.expectEqualDeep(authority, replica);
    var digest: u64 = 0xcbf29ce484222325;
    for (w.logs.items) |log| for (log.items.items) |delivery| {
        plans.hashBytes(&digest, &delivery.origin.bytes);
        plans.hashInt(&digest, delivery.seq);
        plans.hashBytes(&digest, delivery.head[0..@min(delivery.len, delivery.head.len)]);
    };
    return .{ .plan_fingerprint = plan.fingerprint(), .virtual_fingerprint = w.fingerprint(), .delivery_fingerprint = digest, .final_state_hash = plans.bytesFingerprint(&authority.encode()), .final_revision = authority.revision, .payloads_evicted = plan.updates, .endpoint_changes = pool.stats.endpoint_changes, .route_closes = mock.closes };
}
test "three seeded twelve-node chaos plans replay identical virtual outcomes" {
    for (plans.replay_seeds) |seed| {
        const first = try replay(seed);
        const second = try replay(seed);
        try std.testing.expectEqualDeep(first, second);
        const json = try std.json.Stringify.valueAlloc(a, .{ .seed = seed, .paired_equal = true, .result = first }, .{});
        defer a.free(json);
        std.debug.print("CHAOS_VIRTUAL_REPLAY {s}\n", .{json});
    }
}
test "fresh owner lookup absence forgets routes without removing retained SWIM records" {
    var original = world(3101);
    defer original.deinit();
    _ = try original.spawn();
    _ = try original.spawn();
    original.bootstrapAll(0);
    try original.runFor(10_000_000);
    const peer = original.descs.items[0].id;
    var mock: MockDialer = .{ .peer = peer };
    var pool = try Pool.init(a, .{ .max_peers = 1 });
    defer pool.deinit(&mock);
    var location: Location = .{ .address = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 5010) };
    _ = try pool.ensure(&original.nodes.items[1].node, &mock, location.resolver(), peer, 0);
    try pool.service(&original.nodes.items[1].node, &mock, location.resolver(), 1);
    try std.testing.expect(pool.lookup(peer) != null);
    var fresh = world(3101);
    defer fresh.deinit();
    _ = try fresh.spawn();
    _ = try fresh.spawn();
    try std.testing.expect(fresh.nodes.items[1].node.member(peer) == null);
    try pool.service(&fresh.nodes.items[1].node, &mock, location.resolver(), 2);
    try std.testing.expectEqual(@as(usize, 0), pool.count());
    try std.testing.expectEqual(@as(usize, 1), mock.closes);
    try std.testing.expect(original.nodes.items[1].node.member(peer) != null);
}
