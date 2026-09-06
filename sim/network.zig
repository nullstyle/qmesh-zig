//! Deterministic virtual network event queue.
//!
//! Pure mechanism: a totally-ordered event heap ((time, seq) keys) plus
//! counters. All policy — loss, delay, partitions, dial latency — is
//! applied by `World` before events are scheduled, so the queue itself
//! never touches randomness. Ordering is fully deterministic: equal
//! timestamps process in schedule order.

const std = @import("std");

pub const NodeId = u32;

/// Link-layer fault policy. All values are per-world constants; the
/// scenario mutates them directly (e.g. `world.policy.drop_bp = 500`)
/// and subsequent traffic follows the new policy.
pub const Policy = struct {
    /// Datagram-class drop probability in basis points (500 = 5%).
    drop_bp: u32 = 0,
    /// Stream-class drop probability. Defaults to 0: QUIC streams
    /// don't drop; only partitions sever them.
    reliable_drop_bp: u32 = 0,
    delay_min_us: u64 = 250,
    delay_max_us: u64 = 750,
    /// Virtual QUIC handshake latency for dials.
    dial_delay_us: u64 = 5_000,
    /// A dial that has not completed after this long is considered
    /// abandoned (a fresh `connect` may re-dial).
    dial_retry_us: u64 = 25_000,
};

pub const EventKind = union(enum) {
    /// One frame delivered src→dst. `bytes` is heap-owned by the
    /// queue; the dispatcher frees it.
    deliver: struct { src: NodeId, dst: NodeId, bytes: []u8, reliable: bool },
    /// A dial completed: the pair's session became established.
    session_up: struct { a: NodeId, b: NodeId },
    /// A session ended: both endpoints are notified.
    session_down: struct { a: NodeId, b: NodeId },
    /// A paused node unpaused; its local clock resumes (unfreeze).
    unpause: struct { node: NodeId },
};

pub const Event = struct {
    at: u64,
    seq: u64,
    kind: EventKind,
};

fn eventOrder(_: void, a: Event, b: Event) std.math.Order {
    if (a.at != b.at) return std.math.order(a.at, b.at);
    return std.math.order(a.seq, b.seq);
}

pub const Stats = struct {
    scheduled: u64 = 0,
    delivered: u64 = 0,
    dropped_loss: u64 = 0,
    dropped_partition: u64 = 0,
    dropped_dead: u64 = 0,
    dropped_paused: u64 = 0,
    dropped_no_session: u64 = 0,
};

pub const Network = struct {
    allocator: std.mem.Allocator,
    heap: std.PriorityQueue(Event, void, eventOrder) = .empty,
    seq: u64 = 0,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) Network {
        return .{ .allocator = allocator };
    }

    pub fn deinit(n: *Network) void {
        // Free any undelivered payload bytes, then the heap storage.
        for (n.heap.items) |e| switch (e.kind) {
            .deliver => |d| n.allocator.free(d.bytes),
            else => {},
        };
        n.heap.deinit(n.allocator);
    }

    pub fn schedule(n: *Network, at: u64, kind: EventKind) !void {
        n.seq += 1;
        try n.heap.push(n.allocator, .{ .at = at, .seq = n.seq, .kind = kind });
        n.stats.scheduled += 1;
    }

    pub fn peek(n: *const Network) ?Event {
        return n.heap.peek();
    }

    pub fn pop(n: *Network) ?Event {
        return n.heap.pop();
    }
};

test "event order is (at, seq)" {
    var n = Network.init(std.testing.allocator);
    defer n.deinit();
    try n.schedule(100, .{ .unpause = .{ .node = 1 } });
    try n.schedule(50, .{ .unpause = .{ .node = 2 } });
    try n.schedule(100, .{ .unpause = .{ .node = 3 } });
    const first = n.pop().?;
    try std.testing.expectEqual(@as(u64, 50), first.at);
    try std.testing.expectEqual(@as(u32, 2), first.kind.unpause.node);
    const second = n.pop().?;
    try std.testing.expectEqual(@as(u64, 100), second.at);
    try std.testing.expectEqual(@as(u32, 1), second.kind.unpause.node); // seq tiebreak
    const third = n.pop().?;
    try std.testing.expectEqual(@as(u32, 3), third.kind.unpause.node);
    try std.testing.expectEqual(@as(?Event, null), n.pop());
}
