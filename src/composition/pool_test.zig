const std = @import("std");
const messaging = @import("root.zig");
const PeerId = messaging.PeerId;
const Addr = messaging.Addr;
const PeerDesc = messaging.PeerDesc;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Member = struct { desc: PeerDesc, state: enum { alive, suspect, dead } = .alive };
const Mesh = struct {
    records: []Member,
    pub fn member(self: *const Mesh, id: PeerId) ?Member {
        for (self.records) |item| if (item.desc.id.eql(id)) return item;
        return null;
    }
};

const Dialer = struct {
    dials: usize = 0,
    closes: usize = 0,
    fail_next: bool = false,
    last_endpoint: Addr = .none,
    last_expected: PeerId = .zero,
    statuses: [32]?messaging.SessionStatus = @splat(null),
    borrowed: ?u64 = null,

    pub fn dial(self: *Dialer, expected: PeerId, endpoint: Addr) !u64 {
        if (self.fail_next) {
            self.fail_next = false;
            return error.Refused;
        }
        self.dials += 1;
        self.last_endpoint = endpoint;
        self.last_expected = expected;
        self.statuses[self.dials] = .{ .state = .connecting };
        return @intCast(self.dials);
    }
    pub fn close(self: *Dialer, id: u64) void {
        self.closes += 1;
        self.statuses[@intCast(id)] = null;
    }
    pub fn status(self: *Dialer, id: u64) ?messaging.SessionStatus {
        return self.statuses[@intCast(id)];
    }
    pub fn findReady(self: *Dialer, _: PeerId) ?u64 {
        return self.borrowed;
    }
    fn ready(self: *Dialer, id: usize, expected: PeerId) void {
        self.statuses[id] = .{ .state = .ready, .peer_cert_spki = expected.bytes };
    }
};

fn peer(n: u8) PeerId {
    return .{ .bytes = @splat(n) };
}
fn record(n: u8) Member {
    return .{ .desc = .{ .id = peer(n), .addr = Addr.ipv4(.{ 127, 0, 0, n }, 8000) } };
}
fn resolve(_: ?*anyopaque, desc: PeerDesc) !Addr {
    return desc.addr;
}
const resolver: messaging.Resolver = .{ .resolve = resolve };
const Pool = messaging.Pool(Dialer);

test "pool requires demand, protocol readiness and expected certificate identity" {
    var records = [_]Member{ record(1), record(2) };
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{};
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit(&dialer);
    try pool.service(&mesh, &dialer, resolver, 0);
    try expectEqual(@as(usize, 0), dialer.dials);
    try expectEqual(null, try pool.ensure(&mesh, &dialer, resolver, peer(1), 0));
    try expectEqual(@as(usize, 1), dialer.dials);
    try expectEqual(null, pool.lookup(peer(1)));
    try expect(dialer.last_expected.eql(peer(1)));
    // A validly connected DIFFERENT member must not acquire this route.
    dialer.ready(1, peer(2));
    try pool.service(&mesh, &dialer, resolver, 1);
    try expectEqual(null, pool.lookup(peer(1)));
    try expectEqual(@as(u64, 1), pool.stats.identity_mismatches);
    try expectEqual(@as(usize, 1), dialer.closes);
    try pool.service(&mesh, &dialer, resolver, 100_001);
    dialer.ready(2, peer(1));
    try pool.service(&mesh, &dialer, resolver, 100_002);
    try expectEqual(@as(?u64, 2), pool.lookup(peer(1)));
}

test "suspicion preserves ready sessions and confirmed death removes them" {
    var records = [_]Member{record(1)};
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{};
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit(&dialer);
    _ = try pool.ensure(&mesh, &dialer, resolver, peer(1), 0);
    dialer.ready(1, peer(1));
    records[0].state = .suspect;
    records[0].desc.addr = Addr.ipv4(.{ 127, 0, 0, 1 }, 9000);
    try pool.service(&mesh, &dialer, resolver, 1);
    try expectEqual(@as(?u64, 1), pool.lookup(peer(1)));
    try expectEqual(@as(usize, 0), dialer.closes);
    // A contact update during suspicion is deferred; it must not
    // turn a liveness observation into application-session teardown.
    try expectEqual(@as(usize, 1), dialer.dials);
    records[0].state = .alive;
    try pool.service(&mesh, &dialer, resolver, 2);
    try expectEqual(@as(usize, 1), dialer.closes);
    try expectEqual(@as(usize, 2), dialer.dials);
    records[0].state = .dead;
    try pool.service(&mesh, &dialer, resolver, 3);
    try expectEqual(@as(usize, 2), dialer.closes);
    try expectEqual(@as(usize, 0), pool.count());
}

test "membership enumeration cannot evict an omitted peer" {
    var records = [_]Member{ record(1), record(2), record(3) };
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{};
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit(&dialer);
    _ = try pool.ensure(&mesh, &dialer, resolver, peer(3), 0);
    dialer.ready(1, peer(3));
    // There is no scratch buffer or enumeration at the reconciliation
    // seam: only the demanded peer's authoritative point lookup is used.
    try pool.service(&mesh, &dialer, resolver, 1);
    try expectEqual(@as(?u64, 1), pool.lookup(peer(3)));
    try expectEqual(@as(usize, 0), dialer.closes);
}

test "endpoint replacement closes owned route and dials the new endpoint" {
    var records = [_]Member{record(1)};
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{};
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit(&dialer);
    _ = try pool.ensure(&mesh, &dialer, resolver, peer(1), 0);
    dialer.ready(1, peer(1));
    try pool.service(&mesh, &dialer, resolver, 1);
    records[0].desc.addr = Addr.ipv4(.{ 127, 0, 0, 1 }, 9000);
    try pool.service(&mesh, &dialer, resolver, 2);
    try expectEqual(@as(usize, 1), dialer.closes);
    try expectEqual(@as(usize, 2), dialer.dials);
    try expect(dialer.last_endpoint.eql(records[0].desc.addr));
    try expectEqual(null, pool.lookup(peer(1)));
    dialer.ready(2, peer(1));
    try pool.service(&mesh, &dialer, resolver, 3);
    try expectEqual(@as(?u64, 2), pool.lookup(peer(1)));
}

test "independent session failure retries with bounded backoff and dial timeout" {
    var records = [_]Member{record(1)};
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{};
    var pool = try Pool.init(std.testing.allocator, .{ .retry_initial_us = 10, .retry_max_us = 20, .dial_timeout_us = 100 });
    defer pool.deinit(&dialer);
    _ = try pool.ensure(&mesh, &dialer, resolver, peer(1), 0);
    dialer.ready(1, peer(1));
    try pool.service(&mesh, &dialer, resolver, 1);
    dialer.statuses[1] = null;
    try pool.service(&mesh, &dialer, resolver, 2);
    try expectEqual(@as(?u64, 12), pool.nextDeadline());
    try pool.service(&mesh, &dialer, resolver, 11);
    try expectEqual(@as(usize, 1), dialer.dials);
    try pool.service(&mesh, &dialer, resolver, 12);
    try expectEqual(@as(usize, 2), dialer.dials);
    try pool.service(&mesh, &dialer, resolver, 112);
    try expectEqual(@as(?u64, 132), pool.nextDeadline());
    try pool.service(&mesh, &dialer, resolver, 132);
    try expectEqual(@as(usize, 3), dialer.dials);
}

test "borrowed authenticated sessions are reused and survive pool teardown" {
    var records = [_]Member{record(1)};
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{ .borrowed = 7 };
    dialer.ready(7, peer(1));
    var pool = try Pool.init(std.testing.allocator, .{});
    try expectEqual(@as(?u64, 7), try pool.ensure(&mesh, &dialer, resolver, peer(1), 0));
    try expectEqual(@as(usize, 0), dialer.dials);
    pool.deinit(&dialer);
    try expectEqual(@as(usize, 0), dialer.closes);
    try expect(dialer.status(7) != null);
}

test "capacity and idle eviction bound demand leases" {
    var records = [_]Member{ record(1), record(2) };
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{};
    var pool = try Pool.init(std.testing.allocator, .{ .max_peers = 1, .idle_timeout_us = 100 });
    defer pool.deinit(&dialer);
    _ = try pool.ensure(&mesh, &dialer, resolver, peer(1), 0);
    try std.testing.expectError(error.PoolFull, pool.ensure(&mesh, &dialer, resolver, peer(2), 1));
    try pool.service(&mesh, &dialer, resolver, 100);
    try expectEqual(@as(usize, 0), pool.count());
    _ = try pool.ensure(&mesh, &dialer, resolver, peer(2), 100);
    try expectEqual(@as(usize, 2), dialer.dials);
    try std.testing.expectError(error.ClockMovedBackwards, pool.service(&mesh, &dialer, resolver, 99));
}

test "unresolvable or suspect peers do not cause repeated dial attempts" {
    var records = [_]Member{record(1)};
    records[0].desc.addr = .none;
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{};
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit(&dialer);
    _ = try pool.ensure(&mesh, &dialer, resolver, peer(1), 0);
    try pool.service(&mesh, &dialer, resolver, 1);
    try expectEqual(@as(usize, 0), dialer.dials);
    try expectEqual(@as(u64, 1), pool.stats.resolution_failures);
    _ = pool.forget(&dialer, peer(1));
    records[0].state = .suspect;
    try std.testing.expectError(error.PeerSuspected, pool.ensure(&mesh, &dialer, resolver, peer(1), 2));
}

test "resolver formats IPv4 and IPv6 without a service port convention" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("127.0.0.1:4567", try messaging.formatEndpoint(Addr.ipv4(.{ 127, 0, 0, 1 }, 4567), &buf));
    try std.testing.expectEqualStrings("[0:0:0:0:0:0:0:1]:1234", try messaging.formatEndpoint(Addr.ipv6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 1234), &buf));
    try std.testing.expectError(error.NoAddress, messaging.formatEndpoint(.none, &buf));
}

test "temporary resolution loss preserves ready routes but cannot redial stale addresses" {
    var records = [_]Member{record(1)};
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{};
    var pool = try Pool.init(std.testing.allocator, .{ .retry_initial_us = 10, .idle_timeout_us = 0 });
    defer pool.deinit(&dialer);
    _ = try pool.ensure(&mesh, &dialer, resolver, peer(1), 0);
    dialer.ready(1, peer(1));
    records[0].desc.addr = .none;
    try pool.service(&mesh, &dialer, resolver, 1);
    try expectEqual(@as(?u64, 1), pool.lookup(peer(1)));
    try expectEqual(null, pool.nextDeadline());
    dialer.statuses[1] = null;
    try pool.service(&mesh, &dialer, resolver, 2);
    try pool.service(&mesh, &dialer, resolver, 12);
    try expectEqual(@as(usize, 1), dialer.dials);
    try expectEqual(@as(?u64, 32), pool.nextDeadline());
    records[0].desc.addr = record(1).desc.addr;
    try pool.service(&mesh, &dialer, resolver, 32);
    try expectEqual(@as(usize, 2), dialer.dials);
}

test "suspect retry deadlines advance and backwards demand cannot renew a lease" {
    var records = [_]Member{record(1)};
    var mesh: Mesh = .{ .records = &records };
    var dialer: Dialer = .{};
    var pool = try Pool.init(std.testing.allocator, .{ .retry_initial_us = 10, .idle_timeout_us = 100 });
    defer pool.deinit(&dialer);
    _ = try pool.ensure(&mesh, &dialer, resolver, peer(1), 0);
    dialer.statuses[1] = null;
    records[0].state = .suspect;
    try pool.service(&mesh, &dialer, resolver, 10);
    try expectEqual(@as(?u64, 20), pool.nextDeadline());
    try pool.service(&mesh, &dialer, resolver, 20);
    try expectEqual(@as(?u64, 30), pool.nextDeadline());
    try expectEqual(@as(usize, 1), dialer.dials);
    try std.testing.expectError(error.ClockMovedBackwards, pool.ensure(&mesh, &dialer, resolver, peer(1), 19));
    try pool.service(&mesh, &dialer, resolver, 100);
    try expectEqual(@as(usize, 0), pool.count());
}
