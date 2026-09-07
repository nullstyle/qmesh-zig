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
/// fleet cards): `t=<us> <kind> peer=<hex16> <label>=<arg>`. Kinds with
/// no subject peer (lh_change) or no arg (session churn) omit fields.
/// The peer prefix is 16 hex chars — the same display grade as the
/// stats line's node id, so cards, timelines, and log greps correlate.
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
            .{ e.at_us, @tagName(e.kind), hex[0..16] },
        ) catch "event?",
        .repair, .repair_lapsed => return std.fmt.bufPrint(
            buf,
            "t={d} {s} peer={s} seq={d}",
            .{ e.at_us, @tagName(e.kind), hex[0..16], e.arg },
        ) catch "event?",
        else => return std.fmt.bufPrint(
            buf,
            "t={d} {s} peer={s} inc={d}",
            .{ e.at_us, @tagName(e.kind), hex[0..16], e.arg },
        ) catch "event?",
    }
}

// ---------------------------------------------------------------------------
// Concept 2 fusion: rule-based fingerprints over a merged timeline

/// One merged timeline entry as the console holds it: the RECORDING
/// node's 16-hex display prefix beside the event (display grade —
/// matches `formatEvent`'s subject prefix and the stats line's node
/// id, so cards, timelines, and annotations all correlate).
pub const Tagged = struct {
    node: [16]u8,
    kind: Kind,
    subj: [16]u8 = @splat('.'),
    arg: u32 = 0,
};

/// One root-cause annotation: the subject it is about (16-hex prefix,
/// dotted when subjectless) plus rendered text.
pub const Note = struct {
    subj: [16]u8,
    text: [160]u8 = undefined,
    len: usize = 0,

    pub fn textSlice(n: *const Note) []const u8 {
        return n.text[0..n.len];
    }
};

fn hexEql(a: [16]u8, b: [16]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Rule-based root-cause fingerprints (docs/observability-ux.md,
/// Concept 2): patterns in a merged timeline that already mean
/// something specific — each learned from an incident class this
/// project actually hit.
///
/// * STARVED-ONLY SUSPECTOR (the Lifeguard pause fingerprint): a peer
///   suspected by exactly one node while that node's own local-health
///   exponent rose in the window — the buddy-set logic's display
///   twin ("it's us or our path"): the suspicion probably describes
///   the suspector's stall, not the peer's death.
///
/// * RESTART CHURN (the churn-amplifier family): a peer CONFIRMEd
///   dead and then seen returning (resurrection, or a fresh session
///   to it) on the same recorder — one cycle is a restart; three or
///   more in one window is a churn loop.
///
/// * DELIVERY GAP: three or more lapsed repairs — the eager tree and
///   IWANT both missed; anti-entropy is carrying delivery.
///
/// `win` is newest-first, merged on wall clock (qmesh-top's merge).
/// Per-recorder subsequences keep chronological order, which is all
/// these rules need — they never order events ACROSS nodes (each
/// node's ring clock has its own origin). Tables are bounded; an
/// over-wide window degrades by ignoring extras, never by guessing.
/// Emits at most 2 starved + 2 churn + 1 delivery notes, truncated
/// at `notes.len` — a console renders leads, not a report.
pub fn annotate(win: []const Tagged, notes: []Note) usize {
    const max_nodes = 16;
    const max_subj = 24;
    var ntab: [max_nodes][16]u8 = undefined;
    var nlen: usize = 0;
    var maxlh: [max_nodes]u32 = @splat(0);
    var lh_rose: [max_nodes]bool = @splat(false);

    var stab: [max_subj][16]u8 = undefined;
    var slen: usize = 0;
    var sus_mask: [max_subj]u32 = @splat(0);
    var conf: [max_subj][max_nodes]u32 = std.mem.zeroes([max_subj][max_nodes]u32);
    var ret: [max_subj][max_nodes]u32 = std.mem.zeroes([max_subj][max_nodes]u32);
    var lapse_total: u32 = 0;

    // Oldest → newest so per-recorder sequences read chronologically.
    var ci = win.len;
    while (ci > 0) {
        ci -= 1;
        const t = win[ci];
        const ni: ?usize = blk: {
            for (ntab[0..nlen], 0..) |n, i| {
                if (hexEql(n, t.node)) break :blk i;
            }
            if (nlen == max_nodes) break :blk null;
            ntab[nlen] = t.node;
            nlen += 1;
            break :blk nlen - 1;
        };
        switch (t.kind) {
            .lh_change => {
                // A real rise reaches exponent ≥2 (0→1 is one
                // scheduling hiccup, and Lifeguard's own decay makes
                // 1 the noise floor under load).
                if (ni) |i| {
                    if (t.arg > maxlh[i] and t.arg >= 2) lh_rose[i] = true;
                    if (t.arg > maxlh[i]) maxlh[i] = t.arg;
                }
            },
            .repair_lapsed => lapse_total += 1,
            .suspect => {
                if (ni) |i| {
                    if (subjIdx(&stab, &slen, t.subj)) |si| {
                        sus_mask[si] |= @as(u32, 1) << @intCast(i);
                    }
                }
            },
            .confirm => {
                if (ni) |i| {
                    if (subjIdx(&stab, &slen, t.subj)) |si| conf[si][i] += 1;
                }
            },
            .resurrect, .session_up => {
                if (ni) |i| {
                    if (subjIdx(&stab, &slen, t.subj)) |si| ret[si][i] += 1;
                }
            },
            else => {},
        }
    }

    var written: usize = 0;

    // Starved-only suspectors.
    var budget: usize = 2;
    for (stab[0..slen], 0..) |s, si| {
        if (budget == 0 or written == notes.len) break;
        const mask = sus_mask[si];
        if (@popCount(mask) != 1) continue;
        const i: usize = @intCast(@ctz(mask));
        if (!lh_rose[i]) continue;
        writeNote(&notes[written], s, "suspected only by {s} while its lh rose — probable self-descriptive suspicion (Lifeguard pause fingerprint)", .{&ntab[i]});
        written += 1;
        budget -= 1;
    }

    // Restart churn.
    budget = 2;
    for (stab[0..slen], 0..) |s, si| {
        if (budget == 0 or written == notes.len) break;
        var best: u32 = 0;
        var best_i: usize = 0;
        for (0..nlen) |i| {
            const c = @min(conf[si][i], ret[si][i]);
            if (c > best) {
                best = c;
                best_i = i;
            }
        }
        if (best == 0) continue;
        const shape: []const u8 = if (best >= 3) "restart churn LOOP" else "restart churn";
        writeNote(&notes[written], s, "{s}: confirmed dead then returned x{d} (on {s})", .{ shape, best, &ntab[best_i] });
        written += 1;
        budget -= 1;
    }

    // Delivery gap.
    if (lapse_total >= 3 and written < notes.len) {
        writeNote(&notes[written], @splat('.'), "delivery gap: {d} lapsed repairs — anti-entropy carrying delivery", .{lapse_total});
        written += 1;
    }
    return written;
}

fn subjIdx(tab: *[24][16]u8, len: *usize, s: [16]u8) ?usize {
    for (tab[0..len.*], 0..) |t, i| {
        if (hexEql(t, s)) return i;
    }
    if (len.* == tab.len) return null;
    tab[len.*] = s;
    len.* += 1;
    return len.* - 1;
}

fn writeNote(n: *Note, subj: [16]u8, comptime fmt: []const u8, args: anytype) void {
    n.subj = subj;
    const s = std.fmt.bufPrint(&n.text, fmt, args) catch {
        n.len = 0;
        return;
    };
    n.len = s.len;
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
    try testing.expectEqualStrings("t=43 suspect peer=abababababababab inc=7", sus);

    const rep = formatEvent(.{ .at_us = 44, .kind = .repair, .peer = id, .arg = 9 }, &buf);
    try testing.expectEqualStrings("t=44 repair peer=abababababababab seq=9", rep);

    const down = formatEvent(.{ .at_us = 45, .kind = .session_down, .peer = id }, &buf);
    try testing.expectEqualStrings("t=45 session_down peer=abababababababab", down);
}

fn hx16(comptime c: u8) [16]u8 {
    return @splat(c);
}

test "fingerprints: starved-only suspector flagged; corroborated not" {
    const a = hx16('a'); // recorder
    const b = hx16('b'); // corroborator
    const p = hx16('c'); // suspected peer

    // Newest-first window: A's lh climbed to 2 and it suspects P.
    var notes: [5]Note = undefined;
    const w1 = [_]Tagged{
        .{ .node = a, .kind = .suspect, .subj = p },
        .{ .node = a, .kind = .lh_change, .arg = 2 },
        .{ .node = a, .kind = .lh_change, .arg = 0 },
    };
    var n = annotate(&w1, &notes);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(std.mem.indexOf(u8, notes[0].textSlice(), "suspected only by") != null);
    try testing.expect(std.mem.eql(u8, &notes[0].subj, &p));

    // Corroborated by a healthy second node: no note.
    const w2 = [_]Tagged{
        .{ .node = a, .kind = .suspect, .subj = p },
        .{ .node = a, .kind = .lh_change, .arg = 2 },
        .{ .node = a, .kind = .lh_change, .arg = 0 },
        .{ .node = b, .kind = .suspect, .subj = p },
    };
    n = annotate(&w2, &notes);
    try testing.expectEqual(@as(usize, 0), n);

    // lh 0→1 alone is the load noise floor, not starvation: no note.
    const w3 = [_]Tagged{
        .{ .node = a, .kind = .suspect, .subj = p },
        .{ .node = a, .kind = .lh_change, .arg = 1 },
        .{ .node = a, .kind = .lh_change, .arg = 0 },
    };
    n = annotate(&w3, &notes);
    try testing.expectEqual(@as(usize, 0), n);
}

test "fingerprints: restart churn counts dead-then-return cycles" {
    const a = hx16('a');
    const p = hx16('c');

    // One confirm + one return on the same recorder: a restart.
    var notes: [5]Note = undefined;
    const w1 = [_]Tagged{
        .{ .node = a, .kind = .session_up, .subj = p },
        .{ .node = a, .kind = .confirm, .subj = p },
    };
    var n = annotate(&w1, &notes);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(std.mem.indexOf(u8, notes[0].textSlice(), "restart churn") != null);
    try testing.expect(std.mem.indexOf(u8, notes[0].textSlice(), "LOOP") == null);

    // Three cycles inside one window: the loop shape.
    const w2 = [_]Tagged{
        .{ .node = a, .kind = .session_up, .subj = p },
        .{ .node = a, .kind = .confirm, .subj = p },
        .{ .node = a, .kind = .resurrect, .subj = p },
        .{ .node = a, .kind = .confirm, .subj = p },
        .{ .node = a, .kind = .session_up, .subj = p },
        .{ .node = a, .kind = .confirm, .subj = p },
    };
    n = annotate(&w2, &notes);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(std.mem.indexOf(u8, notes[0].textSlice(), "LOOP") != null);

    // Transient suspicion refuted without a confirm: not churn.
    const w3 = [_]Tagged{
        .{ .node = a, .kind = .refute, .subj = p },
        .{ .node = a, .kind = .suspect, .subj = p },
    };
    n = annotate(&w3, &notes);
    try testing.expectEqual(@as(usize, 0), n);
}

test "fingerprints: lapsed repairs annotate a delivery gap, bounded" {
    const a = hx16('a');
    const p = hx16('c');

    var win: [3]Tagged = undefined;
    for (&win) |*t| t.* = .{ .node = a, .kind = .repair_lapsed, .subj = p };
    var notes: [5]Note = undefined;
    try testing.expectEqual(@as(usize, 1), annotate(&win, &notes));
    try testing.expect(std.mem.indexOf(u8, notes[0].textSlice(), "delivery gap") != null);

    // Two lapses are repair noise, not a gap.
    try testing.expectEqual(@as(usize, 0), annotate(win[0..2], &notes));

    // Truncation honors the caller's buffer.
    var one: [1]Note = undefined;
    var win3 = win;
    win3[0] = .{ .node = a, .kind = .suspect, .subj = p };
    win3[1] = .{ .node = a, .kind = .lh_change, .arg = 3 };
    win3[2] = .{ .node = a, .kind = .lh_change, .arg = 0 };
    try testing.expectEqual(@as(usize, 1), annotate(&win3, &one));
}
