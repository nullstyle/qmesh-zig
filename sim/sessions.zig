//! Virtual peer sessions: the simulator's SessionManager.
//!
//! Models the QUIC connection layer the real adapter will own: at most
//! one session per peer pair, dials take `policy.dial_delay_us`,
//! concurrent dials between the same pair deduplicate, and kills /
//! partitions sever established sessions (both endpoints notified).
//!
//! Records live in a list (insertion-ordered for deterministic
//! iteration) with a pair→index map for O(1) lookup.

const std = @import("std");
const net = @import("network.zig");
const world_mod = @import("world.zig");

const NodeId = net.NodeId;
const World = world_mod.World;

fn pairKey(a: NodeId, b: NodeId) u64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return (@as(u64, hi) << 32) | lo;
}

pub const Sessions = struct {
    pub const State = enum { connecting, established };

    pub const Rec = struct {
        a: NodeId,
        b: NodeId,
        state: State,
        dial_at: u64,
    };

    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Rec) = .empty,
    index: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) Sessions {
        return .{ .allocator = allocator };
    }

    pub fn deinit(s: *Sessions) void {
        s.list.deinit(s.allocator);
        s.index.deinit(s.allocator);
    }

    pub fn find(s: *const Sessions, a: NodeId, b: NodeId) ?*Rec {
        const i = s.index.get(pairKey(a, b)) orelse return null;
        return &s.list.items[i];
    }

    pub fn establishedPair(s: *const Sessions, a: NodeId, b: NodeId) bool {
        const rec = s.find(a, b) orelse return false;
        return rec.state == .established;
    }

    pub fn establishedCount(s: *const Sessions) usize {
        var n: usize = 0;
        for (s.list.items) |r| {
            if (r.state == .established) n += 1;
        }
        return n;
    }

    /// Dial (or confirm) a session between `a` and `b`. Deduplicates;
    /// re-dials only after the stale-dial window elapses. Blocked or
    /// dead pairs never get a session — the overlay's neighbor timeout
    /// cleans up, exactly like a real QUIC handshake timing out.
    pub fn ensure(s: *Sessions, w: *World, a: NodeId, b: NodeId) !void {
        if (s.find(a, b)) |rec| {
            if (rec.state == .established) return;
            if (w.now_us -| rec.dial_at <= w.policy.dial_retry_us) return;
            s.removePair(a, b); // abandoned dial; fall through to re-dial
        }
        try s.list.append(s.allocator, .{
            .a = a,
            .b = b,
            .state = .connecting,
            .dial_at = w.now_us,
        });
        try s.index.put(s.allocator, pairKey(a, b), @intCast(s.list.items.len - 1));
        try w.network.schedule(w.now_us + w.policy.dial_delay_us, .{ .session_up = .{ .a = a, .b = b } });
    }

    pub fn removePair(s: *Sessions, a: NodeId, b: NodeId) void {
        const i = s.index.get(pairKey(a, b)) orelse return;
        _ = s.index.remove(pairKey(a, b));
        const moved = s.list.items.len - 1;
        if (i != moved) {
            const m = s.list.items[moved];
            s.list.items[i] = m;
            s.index.put(s.allocator, pairKey(m.a, m.b), i) catch {
                // HashMap put failure on fixup would corrupt lookups;
                // OOM here is fatal to simulation integrity.
                @panic("session index fixup OOM");
            };
        }
        _ = s.list.pop();
    }

    /// Sever every established session involving `node`, notifying
    /// surviving endpoints. Connecting dials vanish silently.
    pub fn killNode(s: *Sessions, w: *World, node: NodeId) !void {
        var i = s.list.items.len;
        while (i > 0) {
            i -= 1;
            const r = s.list.items[i];
            if (r.a != node and r.b != node) continue;
            if (r.state == .established) {
                try w.network.schedule(w.now_us, .{ .session_down = .{ .a = r.a, .b = r.b } });
            }
            s.removePair(r.a, r.b);
        }
    }

    /// Sever established sessions across the active partition.
    pub fn severBlocked(s: *Sessions, w: *World) !void {
        var i = s.list.items.len;
        while (i > 0) {
            i -= 1;
            const r = s.list.items[i];
            if (r.state != .established) continue;
            if (!w.blocked(r.a, r.b)) continue;
            try w.network.schedule(w.now_us, .{ .session_down = .{ .a = r.a, .b = r.b } });
            s.removePair(r.a, r.b);
        }
    }
};
