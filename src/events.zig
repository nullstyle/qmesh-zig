//! The node event ring: a bounded, per-recorder log of mesh-history
//! transitions — the incidents timeline's data source (Concept 2,
//! docs/observability-ux.md).
//!
//! Observability here follows the same discipline as the protocol
//! cores: each recorder (swim, plumtree, the node driver) owns a
//! fixed-capacity `Ring` and pushes plain-data events at the exact
//! code sites where transitions happen, so the ring is derived state
//! — no callbacks, no allocation, byte-identical under replay. A ring
//! is a RECENT-events window, not a log: oldest entries are
//! overwritten, and the questions it exists to answer are recent-window
//! questions — "which peers were under suspicion when delivery
//! dipped", "what did this node's Lifeguard do during the stall".
//!
//! `at_us` is the recorder's own clock (the `now` the core was already
//! given), so events are comparable within one node but not across
//! nodes; cross-node fusion happens at the display seam, which pairs
//! each ring dump with the recorder's clock origin (see the `events`
//! control command in the QUIC runner).

const std = @import("std");
const peer_mod = @import("peer.zig");

const PeerId = peer_mod.PeerId;

/// What happened. One vocabulary across recorders so a merged timeline
/// renders uniformly; each kind documents its subject peer and `arg`.
pub const Kind = enum(u8) {
    /// SWIM: member alive -> suspect (local detection or gossip).
    /// peer = member, arg = incarnation.
    suspect,
    /// SWIM: member -> dead (local expiry or gossiped CONFIRM).
    /// peer = member, arg = incarnation.
    confirm,
    /// SWIM: suspect -> alive (refutation landed). peer = member,
    /// arg = incarnation.
    refute,
    /// SWIM: dead -> alive — session evidence, direct ACK, or PING
    /// from a member held dead (the resurrection paths). peer =
    /// member, arg = incarnation.
    resurrect,
    /// SWIM: WE refuted a suspicion about ourselves (incarnation
    /// bump). peer = self, arg = new self incarnation.
    self_refute,
    /// Lifeguard local-health exponent changed. peer = none,
    /// arg = new exponent (windows scale by 2^lh).
    lh_change,
    /// Plumtree: an IHAVE'd message did not arrive eagerly in time —
    /// IWANT repair armed. peer = announcer, arg = message seq.
    repair,
    /// Plumtree: an IWANT went unanswered past its window — the
    /// delivery gap stands until anti-entropy. peer = last announcer,
    /// arg = message seq.
    repair_lapsed,
    /// Driver: transport session established. peer = session peer.
    session_up,
    /// Driver: transport session lost. peer = session peer.
    session_down,

    pub fn str(k: Kind) []const u8 {
        return @tagName(k);
    }
};

/// One ring entry: plain data, fully written on push (no undefined
/// bytes below `len` — rings serialize deterministically).
pub const Event = struct {
    at_us: u64,
    kind: Kind,
    peer: PeerId = PeerId.zero,
    arg: u32 = 0,
};

/// Fixed-capacity overwrite-oldest ring. `pushed` counts total pushes
/// ever (monotonic, survives overwrites) so a consumer can drain "new
/// since last look" without a cursor protocol: entries new since a
/// last-seen count `c` are the newest `min(len, pushed - c)`.
pub fn Ring(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const cap = capacity;

        items: [capacity]Event = undefined,
        len: usize = 0,
        next: usize = 0,
        pushed: u64 = 0,

        pub fn push(r: *Self, at_us: u64, kind: Kind, peer: PeerId, arg: u32) void {
            r.items[r.next] = .{ .at_us = at_us, .kind = kind, .peer = peer, .arg = arg };
            r.next = (r.next + 1) % capacity;
            if (r.len < capacity) r.len += 1;
            r.pushed += 1;
        }

        /// The `k`-th newest entry (0 = newest), null when `k` reaches
        /// back past the retained window.
        pub fn atNewest(r: *const Self, k: usize) ?Event {
            if (k >= r.len) return null;
            return r.items[(r.next + capacity - 1 - k) % capacity];
        }

        /// Copy the retained window newest-first into `out`; returns
        /// how many were written (truncated at `out.len`).
        pub fn newestFirst(r: *const Self, out: []Event) usize {
            const n = @min(out.len, r.len);
            for (0..n) |k| out[k] = r.atNewest(k).?;
            return n;
        }

        pub fn clear(r: *Self) void {
            r.len = 0;
            r.next = 0;
        }
    };
}

/// Default ring capacity per recorder. Sized so a full mass-restart
/// burst (suspects + confirms + resurrections + session churn for a
/// 32-peer view, or a repair storm under heavy loss) still retains
/// the whole incident, at ~48 B/entry.
pub const default_cap: usize = 64;

/// Compact single-line rendering (greppable in chaos logs, tight in
/// fleet cards): `t=<us> <kind> peer=<hex8> <label>=<arg>`. Kinds with
/// no subject peer (lh_change) or no arg (session churn) omit fields.
pub fn formatEvent(e: Event, buf: []u8) []const u8 {
    const hex = e.peer.hex();
    switch (e.kind) {
        .lh_change => return std.fmt.bufPrint(
            buf,
            "t={d} {s} lh={d}",
            .{ e.at_us, @tagName(e.kind), e.arg },
        ) catch "event?",
        .session_up, .session_down => return std.fmt.bufPrint(
            buf,
            "t={d} {s} peer={s}",
            .{ e.at_us, @tagName(e.kind), hex[0..8] },
        ) catch "event?",
        .repair, .repair_lapsed => return std.fmt.bufPrint(
            buf,
            "t={d} {s} peer={s} seq={d}",
            .{ e.at_us, @tagName(e.kind), hex[0..8], e.arg },
        ) catch "event?",
        else => return std.fmt.bufPrint(
            buf,
            "t={d} {s} peer={s} inc={d}",
            .{ e.at_us, @tagName(e.kind), hex[0..8], e.arg },
        ) catch "event?",
    }
}

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;

test "ring overwrites oldest and reports newest-first" {
    var r: Ring(4) = .{};
    var i: u32 = 0;
    while (i < 6) : (i += 1) r.push(i, .suspect, .{ .bytes = @splat(@intCast(i)) }, i);

    // Capacity bounded; the two oldest are gone.
    try testing.expectEqual(@as(usize, 4), r.len);
    try testing.expectEqual(@as(u64, 6), r.pushed);

    var out: [8]Event = undefined;
    const n = r.newestFirst(&out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(u64, 5), out[0].at_us); // newest first
    try testing.expectEqual(@as(u64, 2), out[3].at_us);
    try testing.expectEqual(@as(u32, 5), out[0].arg);

    // Indexed access agrees and stops at the window edge.
    try testing.expectEqual(@as(u64, 5), r.atNewest(0).?.at_us);
    try testing.expect(r.atNewest(4) == null);

    // Truncation at the caller's buffer.
    var tiny: [2]Event = undefined;
    try testing.expectEqual(@as(usize, 2), r.newestFirst(&tiny));
    try testing.expectEqual(@as(u64, 5), tiny[0].at_us);
}

test "formatEvent renders each kind shape" {
    var buf: [96]u8 = undefined;
    const id: PeerId = .{ .bytes = @splat(0xab) };

    const lh = formatEvent(.{ .at_us = 42, .kind = .lh_change, .arg = 3 }, &buf);
    try testing.expectEqualStrings("t=42 lh_change lh=3", lh);

    const sus = formatEvent(.{ .at_us = 43, .kind = .suspect, .peer = id, .arg = 7 }, &buf);
    try testing.expectEqualStrings("t=43 suspect peer=abababab inc=7", sus);

    const rep = formatEvent(.{ .at_us = 44, .kind = .repair, .peer = id, .arg = 9 }, &buf);
    try testing.expectEqualStrings("t=44 repair peer=abababab seq=9", rep);

    const down = formatEvent(.{ .at_us = 45, .kind = .session_down, .peer = id }, &buf);
    try testing.expectEqualStrings("t=45 session_down peer=abababab", down);
}
