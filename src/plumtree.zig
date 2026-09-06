//! Plumtree-style epidemic broadcast (pure state machine): eager/lazy
//! dissemination with lazy repair — the fast path of the design's
//! "randomized gossip preserves connectivity, direct paths carry
//! sustained traffic, anti-entropy guarantees repair".
//!
//! Same discipline as `hyparview.zig` / `swim.zig`: explicit `now`/
//! `rng`, bounded effect lists, no I/O. Peer sets are FED by the node
//! driver from the overlay's active view (eager ∪ lazy ⊆ active), so
//! the broadcast tree rides the safety mesh without owning it.
//!
//! Model (Leitão et al., "Epidemic Broadcast Trees"):
//!
//! * Eager peers receive the FULL message (`gossip`); lazy peers
//!   receive only `ihave(id)` announcements.
//! * A NEW message from an eager peer is delivered, forwarded eagerly
//!   to the other eager peers, and announced to the lazy ones.
//! * A DUPLICATE arriving via eager push means the edge is redundant:
//!   demote the sender to lazy and tell it (`prune`) — both sides stop
//!   full-pushing over that edge. The eager subgraph collapses toward
//!   a low-redundancy spanning tree.
//! * `ihave(id)` for an unseen id arms a missing-timer; if the eager
//!   copy doesn't arrive in time, `iwant(id)` asks the announcing
//!   peer, and the answer rides a RELIABLE class send (the brief's
//!   "IWANT payload transfer" — completion matters).
//! * A message that arrives because we asked for it promotes the
//!   repair peer back to eager (`graft`) — the tree rebuilds around
//!   failures.
//!
//! Anti-entropy (recent window): every `anti_entropy_period_us`, a
//! node sends `exchange(items = my recent ids)` to a random peer; the
//! receiver compares and pulls gaps through the normal missing→iwant
//! repair, replying once with its own ids. This is deliberately the
//! simplest provable reconciliation ("swap recent id lists, pull
//! gaps"); the exchange payload is the seam where Rateless IBLT
//! summaries slot in later without touching the repair machinery.
//!
//! Class mapping: `gossip` (unsolicited eager push), `ihave`, `iwant`,
//! `prune`, `exchange` are `ephemeral` — loss costs latency, repair
//! fixes it. A `gossip` sent in answer to `iwant` is `reliable`.
//!
//! Delivery contract: delivered messages are staged in a bounded ring
//! (`takeDeliveries`), with payload slices valid UNTIL THE NEXT
//! `handle`/`tick` call — the driver drains them immediately after
//! each call.

const std = @import("std");
const peer_mod = @import("peer.zig");
const frame = @import("frame.zig");
const effects_mod = @import("effects.zig");

const PeerId = peer_mod.PeerId;

pub const proto_id: u8 = frame.Protocol.dissemination;

pub const Config = struct {
    /// How long after an IHAVE an unseen message may take to arrive
    /// via eager push before we IWANT it.
    missing_timeout_us: u64 = 500_000,
    /// How long an IWANT may go unanswered before we stop asking
    /// (anti-entropy owns the repair after that).
    iwant_timeout_us: u64 = 1_000_000,
    /// IHAVE announcements batch up to this long before flushing.
    ihave_flush_us: u64 = 50_000,
    /// Recent-window anti-entropy cadence.
    anti_entropy_period_us: u64 = 10_000_000,
};

pub const msg_type = struct {
    pub const gossip: u8 = 1;
    pub const ihave: u8 = 2;
    pub const iwant: u8 = 3;
    pub const prune: u8 = 4;
    pub const exchange: u8 = 5;
};

pub const MsgId = struct {
    origin: PeerId,
    seq: u64,

    pub fn eql(a: MsgId, b: MsgId) bool {
        return a.seq == b.seq and a.origin.eql(b.origin);
    }
};

pub const max_eager: usize = 32;
pub const max_lazy: usize = 32;
pub const max_payload: usize = 1000;
pub const max_ids_per_msg: usize = 16;
pub const seen_cache: usize = 256;
pub const payload_cache: usize = 32;
pub const max_missing: usize = 32;
pub const max_iwant: usize = 32;
pub const max_pending_ihave: usize = 64;
pub const max_deliveries: usize = 64;

pub const Msg = union(enum) {
    /// Full message. (Also the IWANT answer — the effect's class
    /// distinguishes solicited reliable transfer from eager push.)
    gossip: struct { id: MsgId, payload: []const u8 },
    ihave: struct { items: []const MsgId },
    iwant: struct { items: []const MsgId },
    prune,
    /// Anti-entropy exchange: my recent ids. `reply` is set on the
    /// response half so the exchange terminates after two messages.
    exchange: struct { reply: bool, items: []const MsgId },
};

pub const Effects = effects_mod.Effects(Msg);

pub const DecodeError = frame.DecodeError || error{ UnknownType, Malformed };
const plumtree = @This();

pub const DecodeScratch = struct {
    payload: [max_payload]u8 = undefined,
    ids: [max_ids_per_msg]MsgId = undefined,
};

// ---------------------------------------------------------------------------
// codec

pub fn encode(msg: Msg, buf: []u8) frame.EncodeError![]const u8 {
    var w = frame.Writer.init(buf);
    switch (msg) {
        .gossip => |g| {
            try frame.encodeHeader(&w, proto_id, msg_type.gossip);
            try encodeId(&w, g.id);
            try w.putU16(@intCast(g.payload.len));
            try w.putBytes(g.payload);
        },
        .ihave => |m| {
            try frame.encodeHeader(&w, proto_id, msg_type.ihave);
            try encodeIds(&w, m.items);
        },
        .iwant => |m| {
            try frame.encodeHeader(&w, proto_id, msg_type.iwant);
            try encodeIds(&w, m.items);
        },
        .prune => {
            try frame.encodeHeader(&w, proto_id, msg_type.prune);
        },
        .exchange => |m| {
            try frame.encodeHeader(&w, proto_id, msg_type.exchange);
            try w.putU8(if (m.reply) 1 else 0);
            try encodeIds(&w, m.items);
        },
    }
    return w.written();
}

fn encodeId(w: *frame.Writer, id: MsgId) frame.EncodeError!void {
    try w.putBytes(&id.origin.bytes);
    try w.putU64(id.seq);
}

fn encodeIds(w: *frame.Writer, items: []const MsgId) frame.EncodeError!void {
    std.debug.assert(items.len <= max_ids_per_msg);
    try w.putU8(@intCast(items.len));
    for (items) |id| try encodeId(w, id);
}

pub fn decode(bytes: []const u8, scratch: *DecodeScratch) DecodeError!Msg {
    const h = try frame.decodeHeader(bytes);
    if (h.header.protocol != proto_id) return DecodeError.Malformed;
    var r = frame.Reader.init(h.body);
    switch (h.header.msg_type) {
        msg_type.gossip => {
            const id = try decodeId(&r);
            const len = try r.readU16();
            if (len > max_payload) return DecodeError.Malformed;
            const payload = try r.bytes(len);
            @memcpy(scratch.payload[0..len], payload);
            return .{ .gossip = .{ .id = id, .payload = scratch.payload[0..len] } };
        },
        msg_type.ihave => {
            return .{ .ihave = .{ .items = try decodeIds(&r, scratch) } };
        },
        msg_type.iwant => {
            return .{ .iwant = .{ .items = try decodeIds(&r, scratch) } };
        },
        msg_type.prune => return .prune,
        msg_type.exchange => {
            const reply = try r.readU8();
            if (reply > 1) return DecodeError.Malformed;
            return .{ .exchange = .{ .reply = reply == 1, .items = try decodeIds(&r, scratch) } };
        },
        else => return DecodeError.UnknownType,
    }
}

fn decodeId(r: *frame.Reader) plumtree.DecodeError!MsgId {
    const origin = try r.bytes(32);
    var id: MsgId = undefined;
    @memcpy(&id.origin.bytes, origin);
    id.seq = try r.readU64();
    return id;
}

fn decodeIds(r: *frame.Reader, scratch: *DecodeScratch) plumtree.DecodeError![]MsgId {
    const count = try r.readU8();
    if (count > max_ids_per_msg) return DecodeError.Malformed;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        scratch.ids[i] = try decodeId(r);
    }
    return scratch.ids[0..count];
}

// ---------------------------------------------------------------------------
// state machine

pub const Delivery = struct {
    id: MsgId,
    /// Valid until the next handle/tick — copy if you keep it.
    payload: []const u8,
};

const PayloadEntry = struct {
    id: MsgId,
    len: usize,
    bytes: [max_payload]u8 = undefined,
};

const Missing = struct {
    id: MsgId,
    from: PeerId,
    deadline_us: u64,
};

const Iwant = struct {
    id: MsgId,
    from: PeerId,
    deadline_us: u64,
};

const PendingIhave = struct {
    to: PeerId,
    id: MsgId,
};

pub const Plumtree = struct {
    const Self = @This();

    pub const Stats = struct {
        published: u64 = 0,
        eager_pushes: u64 = 0,
        ihaves_sent: u64 = 0,
        iwants_sent: u64 = 0,
        repairs_answered: u64 = 0,
        delivered: u64 = 0,
        duplicates_dropped: u64 = 0,
        demotions: u64 = 0,
        promotions: u64 = 0,
        prunes_received: u64 = 0,
        exchanges_sent: u64 = 0,
    };

    self: PeerId,
    cfg: Config,

    eager: [max_eager]PeerId = undefined,
    eager_len: usize = 0,
    lazy: [max_lazy]PeerId = undefined,
    lazy_len: usize = 0,

    next_seq: u64 = 1,

    seen: [seen_cache]MsgId = undefined,
    seen_len: usize = 0,
    seen_next: usize = 0,

    payloads: [payload_cache]PayloadEntry = undefined,
    payloads_len: usize = 0,
    payloads_next: usize = 0,

    missing: [max_missing]Missing = undefined,
    missing_len: usize = 0,
    iwants: [max_iwant]Iwant = undefined,
    iwants_len: usize = 0,

    /// IHAVEs awaiting batch flush, per destination.
    pending_ihave: [max_pending_ihave]PendingIhave = undefined,
    pending_ihave_len: usize = 0,
    next_ihave_flush_us: u64,

    next_anti_entropy_us: u64,

    /// Scratch for outbound id batches (ihave/iwant/exchange).
    emit_ids: [max_ids_per_msg]MsgId = undefined,
    emit_ids2: [max_ids_per_msg]MsgId = undefined,

    deliveries: [max_deliveries]Delivery = undefined,
    deliveries_len: usize = 0,
    stats: Stats = .{},

    pub fn init(self_id: PeerId, cfg: Config, now: u64) Self {
        return .{
            .self = self_id,
            .cfg = cfg,
            .next_ihave_flush_us = now + cfg.ihave_flush_us,
            .next_anti_entropy_us = now + cfg.anti_entropy_period_us,
        };
    }

    // --- peer set management (fed by the node driver) --------------------

    pub fn addPeer(p: *Self, id: PeerId, now: u64) void {
        _ = now;
        if (id.eql(p.self)) return;
        if (p.inEager(id) != null or p.inLazy(id) != null) return;
        // New peers start eager: let duplicates trim the tree.
        if (p.eager_len < max_eager) {
            p.eager[p.eager_len] = id;
            p.eager_len += 1;
        }
    }

    pub fn removePeer(p: *Self, id: PeerId) void {
        if (p.inEager(id)) |i| {
            p.eager[i] = p.eager[p.eager_len - 1];
            p.eager_len -= 1;
        }
        if (p.inLazy(id)) |i| {
            p.lazy[i] = p.lazy[p.lazy_len - 1];
            p.lazy_len -= 1;
        }
    }

    pub fn inEager(p: *const Self, id: PeerId) ?usize {
        for (p.eager[0..p.eager_len], 0..) |e, i| {
            if (e.eql(id)) return i;
        }
        return null;
    }

    pub fn inLazy(p: *const Self, id: PeerId) ?usize {
        for (p.lazy[0..p.lazy_len], 0..) |e, i| {
            if (e.eql(id)) return i;
        }
        return null;
    }

    pub fn eagerSlice(p: *const Self) []const PeerId {
        return p.eager[0..p.eager_len];
    }

    pub fn lazySlice(p: *const Self) []const PeerId {
        return p.lazy[0..p.lazy_len];
    }

    // --- publish -----------------------------------------------------------

    /// Broadcast a payload. Returns the assigned message id. The
    /// payload is copied into the bounded cache (for IWANT answers).
    pub fn publish(p: *Self, payload: []const u8, now: u64, out: *Effects) MsgId {
        std.debug.assert(payload.len <= max_payload);
        const id = MsgId{ .origin = p.self, .seq = p.next_seq };
        p.next_seq += 1;
        p.markSeen(id);
        p.cachePayload(id, payload);
        p.stats.published += 1;

        for (p.eager[0..p.eager_len]) |peer| {
            out.push(.{ .send = .{
                .to = peer,
                .msg = .{ .gossip = .{ .id = id, .payload = p.cachedPayload(id).? } },
                .class = .ephemeral,
            } });
            p.stats.eager_pushes += 1;
        }
        for (p.lazy[0..p.lazy_len]) |peer| {
            p.queueIhave(peer, id);
        }
        _ = now;
        return id;
    }

    // --- ingress ------------------------------------------------------------

    pub fn handle(
        p: *Self,
        from: PeerId,
        msg: Msg,
        now: u64,
        out: *Effects,
    ) void {
        switch (msg) {
            .gossip => |g| p.handleGossip(from, g.id, g.payload, now, out),
            .ihave => |m| {
                for (m.items) |id| p.noteIhave(from, id, now);
            },
            .iwant => |m| {
                var n: usize = 0;
                for (m.items) |id| {
                    if (p.cachedPayload(id)) |payload| {
                        // Repair transfer: completion matters.
                        out.push(.{ .send = .{
                            .to = from,
                            .msg = .{ .gossip = .{ .id = id, .payload = payload } },
                            .class = .reliable,
                        } });
                        p.stats.repairs_answered += 1;
                    } else {
                        p.emit_ids2[n] = id;
                        n += 1;
                    }
                }
                if (n > 0) {
                    // Tell the requester which of its asks we cannot
                    // satisfy, so its iwant timer can move on.
                    out.push(.{ .send = .{
                        .to = from,
                        .msg = .{ .ihave = .{ .items = p.emit_ids2[0..n] } },
                        .class = .ephemeral,
                    } });
                }
            },
            .prune => {
                p.stats.prunes_received += 1;
                p.demote(from);
            },
            .exchange => |m| {
                for (m.items) |id| p.noteIhave(from, id, now);
                if (!m.reply and (p.inEager(from) != null or p.inLazy(from) != null)) {
                    const items = p.recentIds(&p.emit_ids2);
                    out.push(.{ .send = .{
                        .to = from,
                        .msg = .{ .exchange = .{ .reply = true, .items = items } },
                        .class = .ephemeral,
                    } });
                    p.stats.exchanges_sent += 1;
                }
            },
        }
    }

    fn handleGossip(p: *Self, from: PeerId, id: MsgId, payload: []const u8, now: u64, out: *Effects) void {
        // Resolve any pending interest in this id.
        p.clearMissing(id);
        const solicited = p.clearIwant(from, id);

        if (p.seenId(id)) {
            // Duplicate via eager push: the edge is redundant. Demote,
            // and prune so the peer stops full-pushing to us too.
            p.stats.duplicates_dropped += 1;
            if (!solicited and p.inEager(from) != null) {
                p.demote(from);
                out.push(.{ .send = .{ .to = from, .msg = .prune, .class = .ephemeral } });
            }
            return;
        }

        p.markSeen(id);
        p.cachePayload(id, payload);

        // Solicited repair from a lazy peer: the repair path becomes a
        // tree edge again (graft).
        if (solicited and p.inLazy(from) != null) {
            p.promote(from);
        }

        // Deliver upward.
        if (p.deliveries_len < max_deliveries) {
            p.deliveries[p.deliveries_len] = .{ .id = id, .payload = p.cachedPayload(id).? };
            p.deliveries_len += 1;
        }
        p.stats.delivered += 1;

        // Forward: eager to the rest, lazy announcements to the lazy.
        for (p.eager[0..p.eager_len]) |peer| {
            if (peer.eql(from)) continue;
            out.push(.{ .send = .{
                .to = peer,
                .msg = .{ .gossip = .{ .id = id, .payload = p.cachedPayload(id).? } },
                .class = .ephemeral,
            } });
            p.stats.eager_pushes += 1;
        }
        for (p.lazy[0..p.lazy_len]) |peer| {
            if (peer.eql(from)) continue;
            p.queueIhave(peer, id);
        }
        _ = now;
    }

    fn noteIhave(p: *Self, from: PeerId, id: MsgId, now: u64) void {
        if (id.origin.eql(p.self)) return; // our own message
        if (p.seenId(id)) return;
        if (p.missingIdx(id) != null) return;
        if (p.missing_len >= max_missing) return; // bounded; anti-entropy backstops
        p.missing[p.missing_len] = .{
            .id = id,
            .from = from,
            .deadline_us = now + p.cfg.missing_timeout_us,
        };
        p.missing_len += 1;
    }

    // --- eager/lazy transitions ----------------------------------------------

    fn demote(p: *Self, id: PeerId) void {
        const i = p.inEager(id) orelse return;
        p.eager[i] = p.eager[p.eager_len - 1];
        p.eager_len -= 1;
        if (p.inLazy(id) == null and p.lazy_len < max_lazy) {
            p.lazy[p.lazy_len] = id;
            p.lazy_len += 1;
        }
        p.stats.demotions += 1;
    }

    fn promote(p: *Self, id: PeerId) void {
        const i = p.inLazy(id) orelse return;
        p.lazy[i] = p.lazy[p.lazy_len - 1];
        p.lazy_len -= 1;
        if (p.inEager(id) == null and p.eager_len < max_eager) {
            p.eager[p.eager_len] = id;
            p.eager_len += 1;
        }
        p.stats.promotions += 1;
    }

    // --- caches ----------------------------------------------------------------

    fn markSeen(p: *Self, id: MsgId) void {
        if (p.seen_len < seen_cache) {
            p.seen[p.seen_len] = id;
            p.seen_len += 1;
        } else {
            p.seen[p.seen_next] = id;
            p.seen_next = (p.seen_next + 1) % seen_cache;
        }
    }

    pub fn seenId(p: *const Self, id: MsgId) bool {
        for (p.seen[0..p.seen_len]) |s| {
            if (s.eql(id)) return true;
        }
        return false;
    }

    fn cachePayload(p: *Self, id: MsgId, payload: []const u8) void {
        var slot: *PayloadEntry = undefined;
        if (p.payloads_len < payload_cache) {
            slot = &p.payloads[p.payloads_len];
            p.payloads_len += 1;
        } else {
            slot = &p.payloads[p.payloads_next];
            p.payloads_next = (p.payloads_next + 1) % payload_cache;
        }
        slot.id = id;
        slot.len = payload.len;
        @memcpy(slot.bytes[0..payload.len], payload);
    }

    fn cachedPayload(p: *Self, id: MsgId) ?[]const u8 {
        for (p.payloads[0..p.payloads_len]) |*e| {
            if (e.id.eql(id)) return e.bytes[0..e.len];
        }
        return null;
    }

    fn missingIdx(p: *const Self, id: MsgId) ?usize {
        for (p.missing[0..p.missing_len], 0..) |m, i| {
            if (m.id.eql(id)) return i;
        }
        return null;
    }

    fn clearMissing(p: *Self, id: MsgId) void {
        if (p.missingIdx(id)) |i| {
            p.missing[i] = p.missing[p.missing_len - 1];
            p.missing_len -= 1;
        }
    }

    fn iwantIdx(p: *const Self, from: PeerId, id: MsgId) ?usize {
        for (p.iwants[0..p.iwants_len], 0..) |w, i| {
            if (w.id.eql(id) and w.from.eql(from)) return i;
        }
        return null;
    }

    /// Returns true if this gossip answers an IWANT we sent to `from`.
    fn clearIwant(p: *Self, from: PeerId, id: MsgId) bool {
        if (p.iwantIdx(from, id)) |i| {
            p.iwants[i] = p.iwants[p.iwants_len - 1];
            p.iwants_len -= 1;
            return true;
        }
        return false;
    }

    fn queueIhave(p: *Self, to: PeerId, id: MsgId) void {
        if (p.pending_ihave_len >= max_pending_ihave) return; // bounded
        p.pending_ihave[p.pending_ihave_len] = .{ .to = to, .id = id };
        p.pending_ihave_len += 1;
    }

    /// The most recent ids we can vouch for (exchange / repair view),
    /// newest first.
    fn recentIds(p: *Self, out_ids: []MsgId) []const MsgId {
        const total = p.payloads_len;
        const n = @min(out_ids.len, total);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const back = n - k;
            const slot = if (total < payload_cache)
                total - back
            else
                (p.payloads_next + payload_cache - back) % payload_cache;
            out_ids[k] = p.payloads[slot].id;
        }
        return out_ids[0..n];
    }

    // --- timers -------------------------------------------------------------------

    pub fn nextDeadline(p: *const Self) ?u64 {
        var best: ?u64 = null;
        const consider = struct {
            fn f(b: *?u64, v: u64) void {
                if (b.* == null or v < b.*.?) b.* = v;
            }
        }.f;
        if (p.pending_ihave_len > 0) consider(&best, p.next_ihave_flush_us);
        consider(&best, p.next_anti_entropy_us);
        for (p.missing[0..p.missing_len]) |m| consider(&best, m.deadline_us);
        for (p.iwants[0..p.iwants_len]) |w| consider(&best, w.deadline_us);
        return best;
    }

    pub fn tick(p: *Self, now: u64, rng: std.Random, out: *Effects) void {
        // Flush batched IHAVEs, coalescing per destination.
        if (p.pending_ihave_len > 0 and now >= p.next_ihave_flush_us) {
            p.next_ihave_flush_us = now + p.cfg.ihave_flush_us;
            p.flushIhaves(out);
        }

        // Missing → IWANT.
        var i: usize = 0;
        while (i < p.missing_len) {
            if (now >= p.missing[i].deadline_us) {
                const m = p.missing[i];
                p.missing[i] = p.missing[p.missing_len - 1];
                p.missing_len -= 1;
                if (p.iwants_len < max_iwant) {
                    p.iwants[p.iwants_len] = .{
                        .id = m.id,
                        .from = m.from,
                        .deadline_us = now + p.cfg.iwant_timeout_us,
                    };
                    p.iwants_len += 1;
                    var n: usize = 0;
                    p.emit_ids[n] = m.id;
                    n += 1;
                    // Piggyback any other missing ids from the same peer.
                    var j: usize = 0;
                    while (j < p.missing_len and n < max_ids_per_msg) {
                        if (p.missing[j].from.eql(m.from)) {
                            const mm = p.missing[j];
                            p.missing[j] = p.missing[p.missing_len - 1];
                            p.missing_len -= 1;
                            p.emit_ids[n] = mm.id;
                            n += 1;
                            p.iwants[p.iwants_len] = .{
                                .id = mm.id,
                                .from = mm.from,
                                .deadline_us = now + p.cfg.iwant_timeout_us,
                            };
                            p.iwants_len += 1;
                        } else {
                            j += 1;
                        }
                    }
                    out.push(.{ .send = .{
                        .to = m.from,
                        .msg = .{ .iwant = .{ .items = p.emit_ids[0..n] } },
                        .class = .ephemeral,
                    } });
                    p.stats.iwants_sent += 1;
                }
                continue;
            }
            i += 1;
        }

        // Unanswered IWANTs lapse (anti-entropy owns the rest).
        i = 0;
        while (i < p.iwants_len) {
            if (now >= p.iwants[i].deadline_us) {
                p.iwants[i] = p.iwants[p.iwants_len - 1];
                p.iwants_len -= 1;
                continue;
            }
            i += 1;
        }

        // Periodic recent-window anti-entropy exchange.
        if (now >= p.next_anti_entropy_us) {
            p.next_anti_entropy_us = now + p.cfg.anti_entropy_period_us;
            const pool = p.eager_len + p.lazy_len;
            if (pool > 0) {
                const pick = rng.uintLessThan(usize, pool);
                const dest = if (pick < p.eager_len)
                    p.eager[pick]
                else
                    p.lazy[pick - p.eager_len];
                const items = p.recentIds(&p.emit_ids);
                if (items.len > 0) {
                    out.push(.{ .send = .{
                        .to = dest,
                        .msg = .{ .exchange = .{ .reply = false, .items = items } },
                        .class = .ephemeral,
                    } });
                    p.stats.exchanges_sent += 1;
                }
            }
        }
    }

    fn flushIhaves(p: *Self, out: *Effects) void {
        // Coalesce per destination: drain entries[0]'s destination
        // (up to a full batch), emit, repeat. Every pass removes at
        // least entry[0], so this terminates.
        while (p.pending_ihave_len > 0) {
            const dst = p.pending_ihave[0].to;
            var n: usize = 0;
            var j: usize = 0;
            while (j < p.pending_ihave_len and n < max_ids_per_msg) {
                if (p.pending_ihave[j].to.eql(dst)) {
                    p.emit_ids[n] = p.pending_ihave[j].id;
                    n += 1;
                    p.pending_ihave[j] = p.pending_ihave[p.pending_ihave_len - 1];
                    p.pending_ihave_len -= 1;
                } else {
                    j += 1;
                }
            }
            if (n == 0) unreachable; // entry[0].to == dst by construction
            out.push(.{ .send = .{
                .to = dst,
                .msg = .{ .ihave = .{ .items = p.emit_ids[0..n] } },
                .class = .ephemeral,
            } });
            p.stats.ihaves_sent += 1;
        }
    }

    // --- invariants ----------------------------------------------------------

    pub fn checkInvariants(p: *const Self) void {
        std.debug.assert(p.eager_len <= max_eager);
        std.debug.assert(p.lazy_len <= max_lazy);
        std.debug.assert(p.missing_len <= max_missing);
        std.debug.assert(p.iwants_len <= max_iwant);
        std.debug.assert(p.pending_ihave_len <= max_pending_ihave);
        std.debug.assert(p.deliveries_len <= max_deliveries);
        for (p.eager[0..p.eager_len]) |e| {
            std.debug.assert(!e.eql(p.self));
        }
        for (p.lazy[0..p.lazy_len]) |l| {
            std.debug.assert(!l.eql(p.self));
        }
        for (p.eager[0..p.eager_len]) |e| {
            std.debug.assert(p.inLazy(e) == null); // disjoint sets
        }
    }

    // --- delivery surface ----------------------------------------------------------

    /// Delivered messages staged by the last handle call. Payload
    /// slices are valid until the NEXT handle/tick — drain immediately.
    pub fn takeDeliveries(p: *Self) []const Delivery {
        const out = p.deliveries[0..p.deliveries_len];
        p.deliveries_len = 0;
        return out;
    }
};

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;

fn idOf(seed: u64) PeerId {
    var prng = std.Random.DefaultPrng.init(seed);
    return PeerId.fromRandom(prng.random());
}

fn testRng() std.Random {
    var prng = std.Random.DefaultPrng.init(0x51);
    return prng.random();
}

test "codec round trip for every message" {
    var scratch: DecodeScratch = .{};
    var buf: [frame.max_frame_len]u8 = undefined;
    var buf2: [frame.max_frame_len]u8 = undefined;

    const a = idOf(1);
    const b = idOf(2);
    const ids = [_]MsgId{ .{ .origin = a, .seq = 1 }, .{ .origin = b, .seq = 42 } };
    const msgs = [_]Msg{
        .{ .gossip = .{ .id = ids[0], .payload = "hello mesh" } },
        .{ .ihave = .{ .items = &ids } },
        .{ .iwant = .{ .items = ids[0..1] } },
        .prune,
        .{ .exchange = .{ .reply = false, .items = &ids } },
        .{ .exchange = .{ .reply = true, .items = &.{} } },
    };
    for (msgs) |m| {
        const enc = try encode(m, &buf);
        const dec = try decode(enc, &scratch);
        const enc2 = try encode(dec, &buf2);
        try testing.expectEqualSlices(u8, enc, enc2);
    }
}

test "codec rejects malformed" {
    var scratch: DecodeScratch = .{};
    try testing.expectError(DecodeError.UnknownType, decode(&[_]u8{ frame.version, proto_id, 99 }, &scratch));
    // oversized payload length
    var w_buf: [64]u8 = undefined;
    var w = frame.Writer.init(&w_buf);
    try frame.encodeHeader(&w, proto_id, msg_type.gossip);
    try w.putBytes(&idOf(3).bytes);
    try w.putU64(1);
    try w.putU16(max_payload + 1);
    try testing.expectError(DecodeError.Malformed, decode(w.written(), &scratch));
    // id count beyond bound
    try testing.expectError(
        DecodeError.Malformed,
        decode(&[_]u8{ frame.version, proto_id, msg_type.ihave, 17 }, &scratch),
    );
}

fn fanoutSetup() struct { p: Plumtree, a: PeerId, b: PeerId, c: PeerId } {
    var p = Plumtree.init(idOf(10), .{}, 0);
    const a = idOf(11);
    const b = idOf(12);
    const c = idOf(13);
    p.addPeer(a, 0);
    p.addPeer(b, 0);
    p.addPeer(c, 0);
    return .{ .p = p, .a = a, .b = b, .c = c };
}

test "publish fans out eagerly and delivers new messages exactly once" {
    const s = fanoutSetup();
    var p = s.p;
    var fx: Effects = .{};

    const id = p.publish("payload-1", 0, &fx);
    try testing.expectEqual(@as(u64, 1), id.seq);
    try testing.expectEqual(@as(usize, 3), fx.len); // eager push to a, b, c
    for (fx.slice()) |e| {
        try testing.expect(e.send.msg == .gossip);
        try testing.expect(e.send.class == .ephemeral);
    }

    // New message from an eager peer: delivered, forwarded to other
    // eager peers, sender excluded.
    fx.clear();
    const foreign = MsgId{ .origin = s.a, .seq = 7 };
    p.handle(s.a, .{ .gossip = .{ .id = foreign, .payload = "x" } }, 1, &fx);
    const deliveries = p.takeDeliveries();
    try testing.expectEqual(@as(usize, 1), deliveries.len);
    try testing.expect(deliveries[0].id.eql(foreign));
    try testing.expectEqualSlices(u8, "x", deliveries[0].payload);
    var forwards: usize = 0;
    for (fx.slice()) |e| {
        if (e.send.msg == .gossip and !e.send.to.eql(s.a)) forwards += 1;
    }
    try testing.expectEqual(@as(usize, 2), forwards);

    // Duplicate via eager push: dropped, no delivery, demotion + prune.
    fx.clear();
    p.handle(s.a, .{ .gossip = .{ .id = foreign, .payload = "x" } }, 2, &fx);
    try testing.expectEqual(@as(usize, 0), p.takeDeliveries().len);
    try testing.expectEqual(@as(u64, 1), p.stats.duplicates_dropped);
    try testing.expect(p.inEager(s.a) == null); // demoted
    try testing.expect(p.inLazy(s.a) != null);
    var prunes: usize = 0;
    for (fx.slice()) |e| {
        if (e.send.msg == .prune) prunes += 1;
    }
    try testing.expectEqual(@as(usize, 1), prunes);
    p.checkInvariants();
}

test "ihave → missing timeout → iwant → reliable repair → graft" {
    const s = fanoutSetup();
    var p = s.p;
    var fx: Effects = .{};
    const rng = testRng();

    // Repairs realistically come from lazy edges; make c lazy first.
    p.handle(s.c, .prune, 0, &fx);
    try testing.expect(p.inLazy(s.c) != null);

    const mid = MsgId{ .origin = s.b, .seq = 5 };
    p.handle(s.c, .{ .ihave = .{ .items = &.{mid} } }, 0, &fx);

    // Nothing requested before the timeout.
    p.tick(p.cfg.missing_timeout_us - 1, rng, &fx);
    var wants: usize = 0;
    for (fx.slice()) |e| {
        if (e.send.msg == .iwant) wants += 1;
    }
    try testing.expectEqual(@as(usize, 0), wants);

    // At the timeout: IWANT to the announcer.
    p.tick(p.cfg.missing_timeout_us, rng, &fx);
    wants = 0;
    for (fx.slice()) |e| {
        if (e.send.msg == .iwant) {
            wants += 1;
            try testing.expect(e.send.to.eql(s.c));
        }
    }
    try testing.expectEqual(@as(usize, 1), wants);

    // The repair arrives — solicited, from a lazy peer — and grafts
    // the repair path back into the eager set.
    fx.clear();
    p.handle(s.c, .{ .gossip = .{ .id = mid, .payload = "repair" } }, p.cfg.missing_timeout_us + 1, &fx);
    try testing.expectEqual(@as(usize, 1), p.takeDeliveries().len);
    try testing.expectEqual(@as(u64, 1), p.stats.promotions);
    try testing.expect(p.inEager(s.c) != null);

    // And we can answer IWANTs from our cache, reliably.
    fx.clear();
    p.handle(s.a, .{ .iwant = .{ .items = &.{mid} } }, 3, &fx);
    var repairs: usize = 0;
    for (fx.slice()) |e| {
        if (e.send.msg == .gossip) {
            repairs += 1;
            try testing.expect(e.send.class == .reliable);
            try testing.expect(e.send.to.eql(s.a));
        }
    }
    try testing.expectEqual(@as(usize, 1), repairs);
    p.checkInvariants();
}

test "prune demotes the sender" {
    const s = fanoutSetup();
    var p = s.p;
    var fx: Effects = .{};
    p.handle(s.b, .prune, 0, &fx);
    try testing.expect(p.inEager(s.b) == null);
    try testing.expect(p.inLazy(s.b) != null);
    try testing.expectEqual(@as(u64, 1), p.stats.prunes_received);
    p.checkInvariants();
}

test "anti-entropy exchange swaps recent ids and terminates in two messages" {
    const s = fanoutSetup();
    var p = s.p;
    var fx: Effects = .{};
    const rng = testRng();

    _ = p.publish("m1", 0, &fx);
    _ = p.publish("m2", 0, &fx);

    // Period due: exchange (not a reply) with our recent ids.
    p.tick(p.cfg.anti_entropy_period_us, rng, &fx);
    var exchanges: usize = 0;
    for (fx.slice()) |e| {
        if (e.send.msg == .exchange) {
            exchanges += 1;
            try testing.expect(!e.send.msg.exchange.reply);
            try testing.expect(e.send.msg.exchange.items.len == 2);
        }
    }
    try testing.expectEqual(@as(usize, 1), exchanges);

    // A reply does not trigger another reply (termination), but its
    // ids arm missing-timers for what we lack.
    fx.clear();
    const foreign = MsgId{ .origin = s.a, .seq = 100 };
    p.handle(s.a, .{ .exchange = .{ .reply = true, .items = &.{foreign} } }, p.cfg.anti_entropy_period_us + 1, &fx);
    for (fx.slice()) |e| {
        try testing.expect(e.send.msg != .exchange);
    }
    // missing timer armed (visible via the next tick's iwant)
    p.tick(p.cfg.anti_entropy_period_us + 1 + p.cfg.missing_timeout_us, rng, &fx);
    var wants: usize = 0;
    for (fx.slice()) |e| {
        if (e.send.msg == .iwant) wants += 1;
    }
    try testing.expectEqual(@as(usize, 1), wants);
    p.checkInvariants();
}

test "eager tree trims: second broadcast pushes fewer full messages" {
    const s = fanoutSetup();
    var p = s.p;
    var fx: Effects = .{};

    const before = p.stats.eager_pushes;
    _ = p.publish("one", 0, &fx);
    const first = p.stats.eager_pushes - before;

    // Each peer echoes our message back through its eager push —
    // duplicates via eager edges, demoting them.
    const mine = MsgId{ .origin = p.self, .seq = 1 };
    for ([_]PeerId{ s.a, s.b, s.c }) |peer| {
        p.handle(peer, .{ .gossip = .{ .id = mine, .payload = "one" } }, 1, &fx);
    }
    try testing.expect(p.stats.demotions > 0);

    _ = p.publish("two", 2, &fx);
    const second = p.stats.eager_pushes - before - first;
    try testing.expect(second < first);
    p.checkInvariants();
}

test "invariants: bounded, disjoint, no self" {
    const s = fanoutSetup();
    var p = s.p;
    var fx: Effects = .{};
    const rng = testRng();

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        fx.clear();
        var buf: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "m{d}", .{i}) catch unreachable;
        _ = p.publish(n, i * 1000, &fx);
        p.handle(s.a, .{ .gossip = .{ .id = .{ .origin = s.a, .seq = i }, .payload = n } }, i * 1000 + 1, &fx);
        p.handle(s.b, .{ .ihave = .{ .items = &.{.{ .origin = s.b, .seq = i }} } }, i * 1000 + 2, &fx);
        p.tick(i * 1000 + 3, rng, &fx);
        _ = p.takeDeliveries();
        p.checkInvariants();
    }
}
