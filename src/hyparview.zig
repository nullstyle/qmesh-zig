//! HyParView-inspired peer overlay: the active/passive view state
//! machine that owns the randomized safety mesh.
//!
//! This module is a PURE state machine. It performs no I/O: `handle`
//! and `tick` take explicit `now`/`rng` parameters and emit bounded
//! `Effects` for the node driver to apply. Everything here runs
//! identically under the deterministic simulator and over real QUIC.
//!
//! Model (deviations from the 2007 paper are deliberate and noted):
//!
//! * Active view (`active_max`, default 10): peers we keep in the
//!   overlay. Every active edge is an explicitly agreed, session-backed
//!   relationship: one side proposes with JOIN (the bootstrap path) or
//!   NEIGHBOR (everything else), the other accepts or rejects. The
//!   paper treats an open TCP connection as membership; with shared
//!   long-lived QUIC connections we make agreement explicit — a
//!   session can outlive overlay membership and multiplex other
//!   traffic.
//! * Passive view (`passive_max`, default 40): candidate descriptors
//!   (id + address) kept for promotion, refreshed by SHUFFLE gossip.
//! * JOIN: dial the contact, then JOIN (reliable). The contact adds
//!   the joiner to its active view (evicting a random member when
//!   full), ACKs (reliable), and fans FORWARD_JOIN out to its other
//!   active peers.
//! * FORWARD_JOIN walks `forward_join_ttl` random active hops; a
//!   receiver with room proposes membership to the joiner, a receiver
//!   at ttl 0 files the joiner into its passive view.
//! * SHUFFLE periodically exchanges random view samples with a random
//!   active peer. The initiator's sample leads with its own
//!   descriptor (a small paper divergence that spreads origins).
//! * Promotion: whenever the active view drops below `active_min`,
//!   scan cadence proposes NEIGHBOR to a passive candidate. Rejected
//!   or timed-out candidates leave the passive view.
//! * Active rotation (`active_rotate_period_us`): periodically drop a
//!   random active edge (never below `active_min`) so passive samples
//!   keep flowing and healed partitions re-merge. Not in the paper;
//!   without it, two healed halves whose active views refilled while
//!   partitioned never reconnect.
//!
//! Class mapping: JOIN/JOIN_ACK/NEIGHBOR_ACCEPT are `reliable`
//! (membership agreement must complete); everything else is
//! `ephemeral` — a lost FORWARD_JOIN/NEIGHBOR/SHUFFLE only costs an
//! opportunity, and self-healing (timeouts, shuffle, promotion)
//! repairs it.

const std = @import("std");
const peer_mod = @import("peer.zig");
const frame = @import("frame.zig");
const effects_mod = @import("effects.zig");

const PeerId = peer_mod.PeerId;
const PeerDesc = peer_mod.PeerDesc;
const Addr = peer_mod.Addr;

pub const proto_id: u8 = frame.Protocol.overlay;

pub const Config = struct {
    /// Upper bound on the active view. Paper range: 8-12.
    active_max: u8 = 10,
    /// Refill threshold: when active drops below this, promote from
    /// the passive view.
    active_min: u8 = 6,
    /// Upper bound on the passive view. Paper range: 32-64.
    passive_max: u8 = 40,
    /// FORWARD_JOIN time-to-live in hops (paper ARWL).
    forward_join_ttl: u8 = 4,
    /// SHUFFLE period per node.
    shuffle_period_us: u64 = 3_000_000,
    /// Active samples offered per SHUFFLE (paper ka).
    shuffle_active: u8 = 3,
    /// Passive samples offered per SHUFFLE (paper kp).
    shuffle_passive: u8 = 6,
    /// How long a NEIGHBOR proposal waits for ACCEPT/REJECT before the
    /// proposal lapses (the candidate remains a passive candidate;
    /// only an explicit NEIGHBOR_REJECT removes it from the view).
    neighbor_timeout_us: u64 = 1_500_000,
    /// JOIN retry timeout.
    join_timeout_us: u64 = 2_000_000,
    /// JOIN attempts before giving up on a contact (the application
    /// may restart a join with another contact).
    join_max_attempts: u8 = 4,
    /// Promotion scan cadence while under `active_min`.
    promote_period_us: u64 = 500_000,
    /// Locality slots: at most this many lowest-RTT peers (fed via
    /// `notePeerRtt`) get promotion preference and may displace each
    /// other in the active view. 0 disables ranking — the paper's
    /// uniformly random overlay. The remainder of the view stays
    /// random BY CONSTRUCTION: the ranked set is capped, so ranking
    /// can never capture more than this minority of active slots and
    /// the small-world connectivity the random majority provides is
    /// preserved (the multi-region posture: 3 of 10).
    ranked_slots: u8 = 0,
    /// Periodic random active-edge rotation. Null disables. See the
    /// module doc for why this exists.
    active_rotate_period_us: ?u64 = 30_000_000,
};

pub const msg_type = struct {
    pub const join: u8 = 1;
    pub const join_ack: u8 = 2;
    pub const forward_join: u8 = 3;
    pub const neighbor: u8 = 4;
    pub const neighbor_accept: u8 = 5;
    pub const neighbor_reject: u8 = 6;
    pub const disconnect: u8 = 7;
    pub const shuffle: u8 = 8;
    pub const shuffle_reply: u8 = 9;
};

pub const max_sample_descs: usize = 16;

pub const Sample = struct {
    descs: []const PeerDesc,
};

/// One overlay message. Slices (samples) point into either the
/// receiver's decode scratch or the sender's emit scratch, both of
/// which outlive the handle/encode cycle that consumes them.
pub const Msg = union(enum) {
    /// Bootstrap membership request. `desc` is the sender's
    /// self-description; the receiver drops it unless the descriptor
    /// id matches the authenticated sender.
    join: PeerDesc,
    join_ack,
    forward_join: struct { joiner: PeerDesc, ttl: u8 },
    neighbor: struct { desc: PeerDesc, urgent: bool },
    neighbor_accept,
    neighbor_reject,
    /// "You are leaving my active view; file me into yours as a
    /// passive candidate." `desc` is the sender's self-description.
    disconnect: PeerDesc,
    shuffle: Sample,
    shuffle_reply: Sample,
};

pub const Effects = effects_mod.Effects(Msg);
pub const Effect = Effects.Item;
pub const Class = effects_mod.Class;

pub const DecodeError = frame.DecodeError || error{ UnknownType, Malformed };

/// Scratch space for decoding inbound messages that carry descriptor
/// lists. One per node; a decoded Msg is valid until the next decode.
pub const DecodeScratch = struct {
    descs: [max_sample_descs]PeerDesc = undefined,
};

// ---------------------------------------------------------------------------
// codec

pub fn encode(msg: Msg, buf: []u8) frame.EncodeError![]const u8 {
    var w = frame.Writer.init(buf);
    switch (msg) {
        .join => |desc| {
            try frame.encodeHeader(&w, proto_id, msg_type.join);
            try frame.DescCodec.encode(desc, &w);
        },
        .join_ack => {
            try frame.encodeHeader(&w, proto_id, msg_type.join_ack);
        },
        .forward_join => |fj| {
            try frame.encodeHeader(&w, proto_id, msg_type.forward_join);
            try frame.DescCodec.encode(fj.joiner, &w);
            try w.putU8(fj.ttl);
        },
        .neighbor => |nb| {
            try frame.encodeHeader(&w, proto_id, msg_type.neighbor);
            try frame.DescCodec.encode(nb.desc, &w);
            try w.putU8(if (nb.urgent) 1 else 0);
        },
        .neighbor_accept => {
            try frame.encodeHeader(&w, proto_id, msg_type.neighbor_accept);
        },
        .neighbor_reject => {
            try frame.encodeHeader(&w, proto_id, msg_type.neighbor_reject);
        },
        .disconnect => |desc| {
            try frame.encodeHeader(&w, proto_id, msg_type.disconnect);
            try frame.DescCodec.encode(desc, &w);
        },
        .shuffle => |s| {
            try frame.encodeHeader(&w, proto_id, msg_type.shuffle);
            try encodeSample(&w, s);
        },
        .shuffle_reply => |s| {
            try frame.encodeHeader(&w, proto_id, msg_type.shuffle_reply);
            try encodeSample(&w, s);
        },
    }
    return w.written();
}

fn encodeSample(w: *frame.Writer, s: Sample) frame.EncodeError!void {
    std.debug.assert(s.descs.len <= max_sample_descs);
    try w.putU8(@intCast(s.descs.len));
    for (s.descs) |d| try frame.DescCodec.encode(d, w);
}

/// Decode a full frame (header included). Verifies the protocol byte
/// and rejects structurally invalid bodies.
pub fn decode(bytes: []const u8, scratch: *DecodeScratch) DecodeError!Msg {
    const h = try frame.decodeHeader(bytes);
    if (h.header.protocol != proto_id) return DecodeError.Malformed;
    var r = frame.Reader.init(h.body);
    switch (h.header.msg_type) {
        msg_type.join => return .{ .join = try frame.DescCodec.decode(&r) },
        msg_type.join_ack => return .join_ack,
        msg_type.forward_join => {
            const joiner = try frame.DescCodec.decode(&r);
            const ttl = try r.readU8();
            return .{ .forward_join = .{ .joiner = joiner, .ttl = ttl } };
        },
        msg_type.neighbor => {
            const desc = try frame.DescCodec.decode(&r);
            const urgent = try r.readU8();
            if (urgent > 1) return DecodeError.Malformed;
            return .{ .neighbor = .{ .desc = desc, .urgent = urgent == 1 } };
        },
        msg_type.neighbor_accept => return .neighbor_accept,
        msg_type.neighbor_reject => return .neighbor_reject,
        msg_type.disconnect => return .{ .disconnect = try frame.DescCodec.decode(&r) },
        msg_type.shuffle, msg_type.shuffle_reply => {
            const count = try r.readU8();
            if (count > max_sample_descs) return DecodeError.Malformed;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                scratch.descs[i] = try frame.DescCodec.decode(&r);
            }
            const sample = Sample{ .descs = scratch.descs[0..count] };
            return if (h.header.msg_type == msg_type.shuffle)
                .{ .shuffle = sample }
            else
                .{ .shuffle_reply = sample };
        },
        else => return DecodeError.UnknownType,
    }
}

// ---------------------------------------------------------------------------
// state machine

pub const max_active: usize = 32;
pub const max_passive: usize = 64;
pub const max_proposals: usize = 4;
pub const max_ranked: usize = 8;

pub const ActiveEntry = struct {
    desc: PeerDesc,
    since_us: u64,
};

const JoinState = struct {
    contact: PeerDesc,
    attempts: u8,
    deadline_us: u64,
};

/// An outstanding NEIGHBOR proposal (ours to them), resolved by the
/// peer's reply or a timeout.
const Proposal = struct {
    desc: PeerDesc,
    deadline_us: u64,
};

/// One locality-ranked candidate: a peer whose RTT we know, preferred
/// for active-slot occupancy up to `ranked_slots` peers.
pub const Ranked = struct {
    id: PeerId,
    rtt_us: u64,
};

pub const Overlay = struct {
    const Self = @This();

    pub const Stats = struct {
        joins_received: u64 = 0,
        forward_joins_received: u64 = 0,
        shuffles_sent: u64 = 0,
        shuffles_received: u64 = 0,
        promotions_proposed: u64 = 0,
        evictions: u64 = 0,
        disconnects_received: u64 = 0,
        ranked_displacements: u64 = 0,
    };

    self: PeerDesc,
    cfg: Config,

    active: [max_active]ActiveEntry = undefined,
    active_len: usize = 0,
    passive: [max_passive]PeerDesc = undefined,
    passive_len: usize = 0,

    /// The bounded locality minority (see Config.ranked_slots):
    /// lowest-RTT peers, refreshed by `notePeerRtt`, dropped by
    /// `purge` or displacement by a better candidate.
    ranked: [max_ranked]Ranked = undefined,
    ranked_len: usize = 0,

    join: ?JoinState = null,
    proposals: [max_proposals]Proposal = undefined,
    proposals_len: usize = 0,

    next_shuffle_us: u64,
    next_scan_us: u64,
    next_rotate_us: u64,

    /// Outbound SHUFFLE/SHUFFLE_REPLY sample staging. Valid until the
    /// next emit; the node driver encodes effects before returning.
    emit_scratch: [max_sample_descs]PeerDesc = undefined,

    stats: Stats = .{},

    pub fn init(self_desc: PeerDesc, cfg: Config, now: u64) Self {
        std.debug.assert(cfg.active_max <= max_active);
        std.debug.assert(cfg.active_min <= cfg.active_max);
        std.debug.assert(cfg.passive_max <= max_passive);
        std.debug.assert(cfg.shuffle_active + cfg.shuffle_passive <= max_sample_descs);
        std.debug.assert(cfg.forward_join_ttl >= 1);
        std.debug.assert(cfg.ranked_slots <= max_ranked);
        return .{
            .self = self_desc,
            .cfg = cfg,
            .next_shuffle_us = now + cfg.shuffle_period_us,
            .next_scan_us = now + cfg.promote_period_us,
            .next_rotate_us = if (cfg.active_rotate_period_us) |p| now + p else std.math.maxInt(u64),
        };
    }

    // --- queries ---------------------------------------------------------

    pub fn activeSlice(o: *const Self) []const ActiveEntry {
        return o.active[0..o.active_len];
    }

    pub fn passiveSlice(o: *const Self) []const PeerDesc {
        return o.passive[0..o.passive_len];
    }

    pub fn inActive(o: *const Self, id: PeerId) ?usize {
        for (o.active[0..o.active_len], 0..) |e, i| {
            if (e.desc.id.eql(id)) return i;
        }
        return null;
    }

    pub fn inPassive(o: *const Self, id: PeerId) ?usize {
        for (o.passive[0..o.passive_len], 0..) |d, i| {
            if (d.id.eql(id)) return i;
        }
        return null;
    }

    fn proposedIdx(o: *const Self, id: PeerId) ?usize {
        for (o.proposals[0..o.proposals_len], 0..) |p, i| {
            if (p.desc.id.eql(id)) return i;
        }
        return null;
    }

    fn inRanked(o: *const Self, id: PeerId) ?usize {
        for (o.ranked[0..o.ranked_len], 0..) |r, i| {
            if (r.id.eql(id)) return i;
        }
        return null;
    }

    fn removeRankedAt(o: *Self, i: usize) void {
        std.debug.assert(i < o.ranked_len);
        o.ranked[i] = o.ranked[o.ranked_len - 1];
        o.ranked_len -= 1;
    }

    /// Soonest deadline among all armed timers (an absolute time on
    /// the caller's clock), or null when none is armed. Shuffle/scan
    /// timers are always armed, so this only returns null if rotation
    /// is the sole timer and disabled — practically never.
    pub fn nextDeadline(o: *const Self) ?u64 {
        var best: ?u64 = null;
        const consider = struct {
            fn f(b: *?u64, v: u64) void {
                if (b.* == null or v < b.*.?) b.* = v;
            }
        }.f;
        consider(&best, o.next_shuffle_us);
        consider(&best, o.next_scan_us);
        consider(&best, o.next_rotate_us);
        if (o.join) |j| consider(&best, j.deadline_us);
        for (o.proposals[0..o.proposals_len]) |p| consider(&best, p.deadline_us);
        return best;
    }

    // --- lifecycle hooks ---------------------------------------------------

    /// Begin joining the mesh through `contact`. Emits a JOIN (which
    /// the transport drops until the session is up) and a connect; the
    /// session-up hook re-sends JOIN once dialable.
    pub fn startJoin(o: *Self, contact: PeerDesc, now: u64, out: *Effects) void {
        if (contact.id.eql(o.self.id)) return;
        o.join = .{
            .contact = contact,
            .attempts = 1,
            .deadline_us = now + o.cfg.join_timeout_us,
        };
        out.push(.{ .send = .{ .to = contact.id, .msg = .{ .join = o.self }, .class = .reliable } });
        out.push(.{ .connect = contact });
    }

    pub fn onSessionUp(o: *Self, peer: PeerId, now: u64, out: *Effects) void {
        _ = now;
        if (o.join) |j| {
            if (j.contact.id.eql(peer)) {
                out.push(.{ .send = .{ .to = peer, .msg = .{ .join = o.self }, .class = .reliable } });
            }
        }
        if (o.proposedIdx(peer) != null) {
            // Proposals always carry urgent: they exist to repair an
            // under-full view or wire in a joiner, so the receiver
            // should make room.
            out.push(.{ .send = .{
                .to = peer,
                .msg = .{ .neighbor = .{ .desc = o.self, .urgent = true } },
                .class = .ephemeral,
            } });
        }
    }

    pub fn onSessionDown(o: *Self, peer: PeerId, now: u64) void {
        if (o.inActive(peer)) |i| {
            const desc = o.active[i].desc;
            o.removeActiveAt(i);
            // The peer may still be alive (local session issue): keep
            // it as a passive candidate.
            o.addPassive(desc);
        }
        if (o.proposedIdx(peer)) |i| o.removeProposalAt(i, false);
        if (o.active_len < o.cfg.active_min) o.next_scan_us = now;
    }

    // --- message handling ---------------------------------------------------

    pub fn handle(
        o: *Self,
        from: PeerId,
        msg: Msg,
        now: u64,
        rng: std.Random,
        out: *Effects,
    ) void {
        switch (msg) {
            .join => |desc| {
                if (!desc.id.eql(from)) return; // descriptor/sender mismatch
                o.stats.joins_received += 1;
                if (o.inActive(from) != null) {
                    // Idempotent re-JOIN from an active peer.
                    out.push(.{ .send = .{ .to = from, .msg = .join_ack, .class = .reliable } });
                    return;
                }
                // addActive owns full-view eviction (ranked-aware).
                o.addActive(desc, now, rng, out);
                out.push(.{ .send = .{ .to = from, .msg = .join_ack, .class = .reliable } });
                const fj: Msg = .{ .forward_join = .{ .joiner = desc, .ttl = o.cfg.forward_join_ttl } };
                for (o.active[0..o.active_len]) |e| {
                    if (e.desc.id.eql(from)) continue;
                    out.push(.{ .send = .{ .to = e.desc.id, .msg = fj, .class = .ephemeral } });
                }
            },
            .join_ack => {
                if (o.join) |j| {
                    if (j.contact.id.eql(from)) {
                        o.addActive(j.contact, now, rng, out);
                        o.join = null;
                    }
                }
            },
            .forward_join => |fj| {
                if (fj.joiner.id.eql(o.self.id)) return;
                o.stats.forward_joins_received += 1;
                if (o.active_len < o.cfg.active_max) {
                    // Accept: propose membership to the joiner.
                    _ = o.propose(fj.joiner, now, out);
                } else if (fj.ttl == 0) {
                    o.addPassive(fj.joiner);
                } else if (o.pickForwardTarget(from, rng)) |next| {
                    out.push(.{ .send = .{
                        .to = next,
                        .msg = .{ .forward_join = .{ .joiner = fj.joiner, .ttl = fj.ttl - 1 } },
                        .class = .ephemeral,
                    } });
                } else {
                    // No one else to forward to: file the joiner.
                    o.addPassive(fj.joiner);
                }
            },
            .neighbor => |nb| {
                if (!nb.desc.id.eql(from)) return;
                if (o.inActive(from) != null) {
                    // Idempotent: re-ack an existing active edge.
                    out.push(.{ .send = .{ .to = from, .msg = .neighbor_accept, .class = .reliable } });
                    return;
                }
                const has_room = o.active_len < o.cfg.active_max;
                if (has_room or nb.urgent) {
                    // addActive owns full-view eviction (ranked-aware:
                    // an urgent ranked newcomer displaces the worst
                    // ranked active, an urgent random one a random).
                    o.addActive(nb.desc, now, rng, out);
                    out.push(.{ .send = .{ .to = from, .msg = .neighbor_accept, .class = .reliable } });
                } else {
                    out.push(.{ .send = .{ .to = from, .msg = .neighbor_reject, .class = .ephemeral } });
                }
            },
            .neighbor_accept => {
                if (o.proposedIdx(from)) |i| {
                    const p = o.proposals[i];
                    o.removeProposalAt(i, false);
                    o.addActive(p.desc, now, rng, out);
                }
            },
            .neighbor_reject => {
                if (o.proposedIdx(from)) |i| o.removeProposalAt(i, true);
            },
            .disconnect => |desc| {
                if (!desc.id.eql(from)) return;
                o.stats.disconnects_received += 1;
                if (o.inActive(from)) |i| o.removeActiveAt(i);
                o.addPassive(desc);
            },
            .shuffle => |s| {
                o.stats.shuffles_received += 1;
                o.mergePassive(s.descs);
                const count = @min(s.descs.len, @as(usize, o.cfg.shuffle_active) + o.cfg.shuffle_passive);
                const sample = o.buildSample(count, from, true, rng);
                out.push(.{ .send = .{
                    .to = from,
                    .msg = .{ .shuffle_reply = .{ .descs = sample } },
                    .class = .ephemeral,
                } });
            },
            .shuffle_reply => |s| {
                o.stats.shuffles_received += 1;
                o.mergePassive(s.descs);
            },
        }
    }

    // --- timers ---------------------------------------------------------------

    pub fn tick(o: *Self, now: u64, rng: std.Random, out: *Effects) void {
        // JOIN retry / give-up. A node with NO active edges keeps
        // knocking on its provisioned contact forever (saturating the
        // attempt counter): a cold-starting cluster's joiners must
        // outlive their seed's restart — the fly smoke test watched a
        // lone joiner exhaust join_max_attempts against a down seed
        // and then never dial again, with nothing in any view to
        // recover from. With any active edge the stale join lapses as
        // before (the application may restart a join elsewhere).
        if (o.join) |*j| {
            if (now >= j.deadline_us) {
                if (j.attempts >= o.cfg.join_max_attempts and o.active_len > 0) {
                    o.join = null;
                } else {
                    j.attempts +|= 1;
                    j.deadline_us = now + o.cfg.join_timeout_us;
                    out.push(.{ .send = .{
                        .to = j.contact.id,
                        .msg = .{ .join = o.self },
                        .class = .reliable,
                    } });
                    out.push(.{ .connect = j.contact });
                }
            }
        }

        // Proposal timeouts. The candidate STAYS in the passive view:
        // passive entries are addresses, not liveness claims (the
        // paper's stance), and purging on timeout would let a partition
        // permanently drain the other side from every passive view,
        // making healed halves undiscoverable. Only an explicit
        // NEIGHBOR_REJECT purges.
        var i: usize = 0;
        while (i < o.proposals_len) {
            if (now >= o.proposals[i].deadline_us) {
                o.removeProposalAt(i, false);
                continue; // re-examine the entry swapped into slot i
            }
            i += 1;
        }

        // Periodic shuffle.
        if (now >= o.next_shuffle_us) {
            o.next_shuffle_us = now + o.cfg.shuffle_period_us;
            if (o.active_len > 0) {
                const target = o.active[rng.uintLessThan(usize, o.active_len)].desc.id;
                const want: usize = @as(usize, o.cfg.shuffle_active) + o.cfg.shuffle_passive;
                const sample = o.buildSample(want, target, false, rng);
                out.push(.{ .send = .{
                    .to = target,
                    .msg = .{ .shuffle = .{ .descs = sample } },
                    .class = .ephemeral,
                } });
                o.stats.shuffles_sent += 1;
            }
        }

        // Active rotation (partition re-merge insurance).
        if (now >= o.next_rotate_us) {
            o.next_rotate_us = now + o.cfg.active_rotate_period_us.?;
            if (o.active_len > o.cfg.active_min) {
                const victim = rng.uintLessThan(usize, o.active_len);
                const desc = o.active[victim].desc;
                o.removeActiveAt(victim);
                o.addPassive(desc);
                out.push(.{ .send = .{
                    .to = desc.id,
                    .msg = .{ .disconnect = o.self },
                    .class = .ephemeral,
                } });
            }
        }

        // Promotion scan.
        if (now >= o.next_scan_us) {
            o.next_scan_us = now + o.cfg.promote_period_us;
            if (o.active_len < o.cfg.active_min and o.proposals_len < max_proposals) {
                if (o.pickPromotionCandidate(rng)) |cand| {
                    _ = o.propose(cand, now, out);
                    o.stats.promotions_proposed += 1;
                }
            }
        }
    }

    /// Offer a peer as a passive candidate (idempotent). Used when
    /// SWIM reports a member alive that the views have forgotten —
    /// the partition-recovery path.
    pub fn notePeer(o: *Self, desc: PeerDesc) void {
        o.addPassive(desc);
    }

    /// Feed an observed RTT for a peer (0 = unknown, ignored). The
    /// bounded ranked set holds the `ranked_slots` lowest-RTT peers —
    /// the locality minority that gets promotion preference and may
    /// displace only each other. Entries survive demotions (a ranked
    /// passive peer is a preferred promotion candidate); they leave
    /// via `purge` or displacement by a better candidate.
    pub fn notePeerRtt(o: *Self, id: PeerId, rtt_us: u64) void {
        if (rtt_us == 0) return;
        if (id.eql(o.self.id)) return;
        if (o.cfg.ranked_slots == 0) return;
        for (o.ranked[0..o.ranked_len]) |*r| {
            if (r.id.eql(id)) {
                r.rtt_us = rtt_us;
                return;
            }
        }
        if (o.ranked_len < o.cfg.ranked_slots) {
            o.ranked[o.ranked_len] = .{ .id = id, .rtt_us = rtt_us };
            o.ranked_len += 1;
            return;
        }
        // Full: displace the worst ranked peer when the newcomer
        // beats it — the set stays the best-known minority.
        var worst: usize = 0;
        for (o.ranked[0..o.ranked_len], 0..) |r, i| {
            if (r.rtt_us > o.ranked[worst].rtt_us) worst = i;
        }
        if (rtt_us < o.ranked[worst].rtt_us) {
            o.ranked[worst] = .{ .id = id, .rtt_us = rtt_us };
            o.stats.ranked_displacements += 1;
        }
    }

    /// Drop a peer from the passive view and cancel any outstanding
    /// promotion proposal or ranking toward it (idempotent). Used
    /// when SWIM confirms the peer dead.
    pub fn purge(o: *Self, id: PeerId) void {
        if (o.inPassive(id)) |i| o.removePassiveAt(i);
        if (o.proposedIdx(id)) |i| o.removeProposalAt(i, false);
        if (o.inRanked(id)) |i| o.removeRankedAt(i);
    }

    // --- internal -----------------------------------------------------------------

    fn removeActiveAt(o: *Self, i: usize) void {
        std.debug.assert(i < o.active_len);
        o.active[i] = o.active[o.active_len - 1];
        o.active_len -= 1;
    }

    fn removePassiveAt(o: *Self, i: usize) void {
        std.debug.assert(i < o.passive_len);
        o.passive[i] = o.passive[o.passive_len - 1];
        o.passive_len -= 1;
    }

    fn removeProposalAt(o: *Self, i: usize, also_passive: bool) void {
        std.debug.assert(i < o.proposals_len);
        const p = o.proposals[i];
        o.proposals[i] = o.proposals[o.proposals_len - 1];
        o.proposals_len -= 1;
        if (also_passive) {
            if (o.inPassive(p.desc.id)) |pi| o.removePassiveAt(pi);
        }
    }

    /// Single chokepoint for active insertion: dedupes, detaches from
    /// passive and proposals, evicts when full.
    fn addActive(o: *Self, desc: PeerDesc, now: u64, rng: std.Random, out: *Effects) void {
        if (desc.id.eql(o.self.id)) return;
        if (o.inActive(desc.id) != null) return;
        if (o.active_len >= o.cfg.active_max) {
            o.evictForEntry(desc.id, rng, out);
        }
        if (o.inPassive(desc.id)) |pi| o.removePassiveAt(pi);
        if (o.proposedIdx(desc.id)) |pi| o.removeProposalAt(pi, false);
        o.active[o.active_len] = .{ .desc = desc, .since_us = now };
        o.active_len += 1;
    }

    /// Choose whom an incoming active member displaces when the view
    /// is full. A RANKED newcomer displaces the worst ranked ACTIVE
    /// member — locality churns within its own minority. Everyone
    /// else keeps the paper's uniform random eviction, so ranking can
    /// only ever occupy its bounded minority of the view.
    fn evictForEntry(o: *Self, incoming: PeerId, rng: std.Random, out: *Effects) void {
        if (o.cfg.ranked_slots > 0 and o.inRanked(incoming) != null) {
            var worst_active: ?usize = null;
            var worst_rtt: u64 = 0;
            for (o.active[0..o.active_len], 0..) |e, i| {
                const ri = o.inRanked(e.desc.id) orelse continue;
                if (worst_active == null or o.ranked[ri].rtt_us > worst_rtt) {
                    worst_active = i;
                    worst_rtt = o.ranked[ri].rtt_us;
                }
            }
            if (worst_active) |i| {
                o.evictActiveAt(i, out);
                o.stats.ranked_displacements += 1;
                return;
            }
        }
        o.evictRandomActive(rng, out);
    }

    fn evictRandomActive(o: *Self, rng: std.Random, out: *Effects) void {
        std.debug.assert(o.active_len > 0);
        const i = rng.uintLessThan(usize, o.active_len);
        o.evictActiveAt(i, out);
    }

    /// Remove active slot `i` with the paper's demotion courtesy:
    /// both sides park the other in passive, DISCONNECT notifies.
    fn evictActiveAt(o: *Self, i: usize, out: *Effects) void {
        std.debug.assert(i < o.active_len);
        const victim = o.active[i].desc;
        o.removeActiveAt(i);
        o.stats.evictions += 1;
        o.addPassive(victim);
        out.push(.{ .send = .{
            .to = victim.id,
            .msg = .{ .disconnect = o.self },
            .class = .ephemeral,
        } });
    }

    /// Insert into the passive view if eligible; random eviction when
    /// full (the paper's policy — it preserves uniformity).
    fn addPassive(o: *Self, desc: PeerDesc) void {
        if (desc.id.eql(o.self.id)) return;
        if (o.inActive(desc.id) != null) return;
        if (o.inPassive(desc.id) != null) return;
        if (o.passive_len >= o.cfg.passive_max) {
            const i = fixedRngForPassiveEvict(o, desc);
            o.removePassiveAt(i);
        }
        o.passive[o.passive_len] = desc;
        o.passive_len += 1;
    }

    /// Passive eviction wants randomness but `addPassive` is also
    /// called from session-down paths with no rng at hand. Rather than
    /// thread rng through every failure path, derive a deterministic
    /// (state-dependent) eviction index — the position choice here is
    /// not security- or correctness-relevant, only spread.
    fn fixedRngForPassiveEvict(o: *const Self, incoming: PeerDesc) usize {
        var h: u64 = 0x9e3779b97f4a7c15;
        for (o.passive[0..o.passive_len]) |d| {
            h ^= std.mem.readInt(u64, d.id.bytes[0..8], .little);
            h = h *% 0x100000001b3;
        }
        h ^= std.mem.readInt(u64, incoming.id.bytes[0..8], .little);
        return @intCast(h % o.passive_len);
    }

    /// Register a NEIGHBOR proposal toward `desc` (immediate proposal
    /// send — dropped by the transport until the session is up — plus
    /// a connect; the session-up hook re-sends once dialable).
    /// Returns false when the proposal table is full.
    fn propose(o: *Self, desc: PeerDesc, now: u64, out: *Effects) bool {
        if (desc.id.eql(o.self.id)) return false;
        if (o.inActive(desc.id) != null) return true; // already there
        if (o.proposedIdx(desc.id) != null) return true; // already proposed
        if (o.proposals_len >= max_proposals) return false;
        o.proposals[o.proposals_len] = .{
            .desc = desc,
            .deadline_us = now + o.cfg.neighbor_timeout_us,
        };
        o.proposals_len += 1;
        out.push(.{ .send = .{
            .to = desc.id,
            .msg = .{ .neighbor = .{ .desc = o.self, .urgent = true } },
            .class = .ephemeral,
        } });
        out.push(.{ .connect = desc });
        return true;
    }

    fn pickForwardTarget(o: *const Self, sender: PeerId, rng: std.Random) ?PeerId {
        if (o.active_len == 0) return null;
        const start = rng.uintLessThan(usize, o.active_len);
        var probe: usize = 0;
        while (probe < o.active_len) : (probe += 1) {
            const e = o.active[(start + probe) % o.active_len];
            if (!e.desc.id.eql(sender)) return e.desc.id;
        }
        return null;
    }

    fn pickPromotionCandidate(o: *const Self, rng: std.Random) ?PeerDesc {
        if (o.passive_len == 0) return null;
        // Locality first: the lowest-RTT ranked peer that is a dialable
        // passive candidate (ranked peers already active need nothing;
        // ranked peers outside both views are re-filed by the driver's
        // alive sweep before they can be proposed).
        if (o.cfg.ranked_slots > 0) {
            var best: ?PeerDesc = null;
            var best_rtt: u64 = std.math.maxInt(u64);
            for (o.ranked[0..o.ranked_len]) |r| {
                const pi = o.inPassive(r.id) orelse continue;
                const d = o.passive[pi];
                if (d.addr == .none) continue;
                if (o.proposedIdx(r.id) != null) continue;
                if (r.rtt_us < best_rtt) {
                    best = d;
                    best_rtt = r.rtt_us;
                }
            }
            if (best) |d| return d;
        }
        const start = rng.uintLessThan(usize, o.passive_len);
        // First pass: dialable (has an address), no outstanding proposal.
        var probe: usize = 0;
        while (probe < o.passive_len) : (probe += 1) {
            const d = o.passive[(start + probe) % o.passive_len];
            if (d.addr != .none and o.proposedIdx(d.id) == null) return d;
        }
        // Second pass: anything not currently proposed.
        probe = 0;
        while (probe < o.passive_len) : (probe += 1) {
            const d = o.passive[(start + probe) % o.passive_len];
            if (o.proposedIdx(d.id) == null) return d;
        }
        return null;
    }

    fn mergePassive(o: *Self, descs: []const PeerDesc) void {
        for (descs) |d| o.addPassive(d);
    }

    /// Uniform sample of `count` descriptors from self (unless reply),
    /// active, and passive views, excluding `exclude`, staged into
    /// `emit_scratch`. Reservoir sampling: one pass, uniform marginals
    /// without staging the whole candidate set.
    fn buildSample(
        o: *Self,
        count: usize,
        exclude: PeerId,
        is_reply: bool,
        rng: std.Random,
    ) []const PeerDesc {
        var n: usize = 0;
        var needed = count;

        const includes_self = !is_reply;
        const total = o.active_len + o.passive_len + @as(usize, if (includes_self) 1 else 0);
        if (total == 0 or count == 0) return o.emit_scratch[0..0];

        // The initiator's sample always leads with its own descriptor.
        if (includes_self) {
            o.emit_scratch[n] = o.self;
            n += 1;
            needed -= 1;
            if (needed == 0) return o.emit_scratch[0..n];
        }

        // Remaining candidates after the guaranteed self slot.
        var pool = total - @as(usize, if (includes_self) 1 else 0);
        var idx: usize = 0;
        while (idx < o.active_len + o.passive_len and pool > 0) {
            const d = if (idx < o.active_len)
                o.active[idx].desc
            else
                o.passive[idx - o.active_len];
            idx += 1;
            if (d.id.eql(exclude)) continue;
            // Accept with probability needed/pool (classic reservoir).
            const draw = rng.uintLessThan(usize, pool);
            pool -= 1;
            if (draw < needed) {
                o.emit_scratch[n] = d;
                n += 1;
                needed -= 1;
                if (needed == 0) break;
            }
        }
        return o.emit_scratch[0..n];
    }

    // --- invariants ---------------------------------------------------------

    /// Assert every documented view invariant. Called by tests after
    /// arbitrary operation storms.
    pub fn checkInvariants(o: *const Self) void {
        std.debug.assert(o.active_len <= o.cfg.active_max);
        std.debug.assert(o.passive_len <= o.cfg.passive_max);
        std.debug.assert(o.proposals_len <= max_proposals);
        std.debug.assert(o.ranked_len <= o.cfg.ranked_slots);

        var i: usize = 0;
        while (i < o.active_len) : (i += 1) {
            std.debug.assert(!o.active[i].desc.id.eql(o.self.id));
            var j = i + 1;
            while (j < o.active_len) : (j += 1) {
                std.debug.assert(!o.active[i].desc.id.eql(o.active[j].desc.id));
            }
        }
        i = 0;
        while (i < o.passive_len) : (i += 1) {
            std.debug.assert(!o.passive[i].id.eql(o.self.id));
            var j = i + 1;
            while (j < o.passive_len) : (j += 1) {
                std.debug.assert(!o.passive[i].id.eql(o.passive[j].id));
            }
        }
        i = 0;
        while (i < o.ranked_len) : (i += 1) {
            std.debug.assert(!o.ranked[i].id.eql(o.self.id));
            std.debug.assert(o.ranked[i].rtt_us > 0);
            var j = i + 1;
            while (j < o.ranked_len) : (j += 1) {
                std.debug.assert(!o.ranked[i].id.eql(o.ranked[j].id));
            }
        }
        for (o.active[0..o.active_len]) |e| {
            std.debug.assert(o.inPassive(e.desc.id) == null);
        }
        for (o.proposals[0..o.proposals_len]) |p| {
            std.debug.assert(!p.desc.id.eql(o.self.id));
            std.debug.assert(o.inActive(p.desc.id) == null);
        }
        // The structural random-majority guarantee: ranking can never
        // occupy more than its bounded minority of the active view.
        var ranked_active: usize = 0;
        for (o.active[0..o.active_len]) |e| {
            if (o.inRanked(e.desc.id) != null) ranked_active += 1;
        }
        std.debug.assert(ranked_active <= o.cfg.ranked_slots);
    }
};

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;

fn descOf(seed: u64) PeerDesc {
    var prng = std.Random.DefaultPrng.init(seed);
    return .{ .id = PeerId.fromRandom(prng.random()), .addr = Addr.sim(@truncate(seed)) };
}

fn testRng() std.Random {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    return prng.random();
}

test "encode/decode round trip for every message type" {
    var scratch: DecodeScratch = .{};
    var buf: [frame.max_frame_len]u8 = undefined;

    const cases = [_]Msg{
        .{ .join = descOf(1) },
        .join_ack,
        .{ .forward_join = .{ .joiner = descOf(2), .ttl = 4 } },
        .{ .neighbor = .{ .desc = descOf(3), .urgent = true } },
        .{ .neighbor = .{ .desc = descOf(33), .urgent = false } },
        .neighbor_accept,
        .neighbor_reject,
        .{ .disconnect = descOf(4) },
        .{ .shuffle = .{ .descs = &.{ descOf(5), descOf(6), descOf(7) } } },
        .{ .shuffle_reply = .{ .descs = &.{} } },
    };
    for (cases) |m| {
        const enc = try encode(m, &buf);
        const dec = try decode(enc, &scratch);
        // Structural equality via re-encode (decoded slices point into
        // scratch, so compare wire forms).
        var buf2: [frame.max_frame_len]u8 = undefined;
        const enc2 = try encode(dec, &buf2);
        try testing.expectEqualSlices(u8, enc, enc2);
    }
}

test "decode rejects unknown type, oversized sample, wrong protocol, bad flag" {
    var scratch: DecodeScratch = .{};
    try testing.expectError(
        DecodeError.UnknownType,
        decode(&[_]u8{ frame.version, proto_id, 200 }, &scratch),
    );
    try testing.expectError(
        DecodeError.Malformed,
        decode(&[_]u8{ frame.version, 0x7f, 1 }, &scratch),
    );
    try testing.expectError(
        DecodeError.Malformed,
        decode(&[_]u8{ frame.version, proto_id, msg_type.shuffle, 17 }, &scratch),
    );
    var buf: [64]u8 = undefined;
    var w = frame.Writer.init(&buf);
    try frame.encodeHeader(&w, proto_id, msg_type.neighbor);
    try frame.DescCodec.encode(descOf(9), &w);
    try w.putU8(2);
    try testing.expectError(DecodeError.Malformed, decode(w.written(), &scratch));
}

test "join accepted with room: ack, active insert" {
    var o = Overlay.init(descOf(100), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();

    const joiner = descOf(101);
    o.handle(joiner.id, .{ .join = joiner }, 1, rng, &fx);

    var acks: usize = 0;
    var fanouts: usize = 0;
    for (fx.slice()) |e| switch (e) {
        .send => |s| switch (s.msg) {
            .join_ack => {
                acks += 1;
                try testing.expect(s.to.eql(joiner.id));
                try testing.expect(s.class == .reliable);
            },
            .forward_join => fanouts += 1,
            else => return error.Unexpected,
        },
        .connect => return error.Unexpected,
    };
    try testing.expectEqual(@as(usize, 1), acks);
    try testing.expectEqual(@as(usize, 0), fanouts); // no other actives yet
    try testing.expect(o.inActive(joiner.id) != null);
    o.checkInvariants();
}

test "join when full evicts one and fans out to the rest" {
    var o = Overlay.init(descOf(200), .{ .active_max = 3, .active_min = 1 }, 0);
    var fx: Effects = .{};
    const rng = testRng();

    var peers: [3]PeerDesc = undefined;
    for (&peers, 0..) |*p, i| p.* = descOf(300 + i);
    for (peers) |p| o.handle(p.id, .{ .join = p }, 1, rng, &fx);
    try testing.expectEqual(@as(usize, 3), o.active_len);

    fx.clear();
    const late = descOf(400);
    o.handle(late.id, .{ .join = late }, 2, rng, &fx);
    try testing.expectEqual(@as(usize, 3), o.active_len); // bounded
    try testing.expect(o.inActive(late.id) != null);
    var disconnects: usize = 0;
    var fanouts: usize = 0;
    for (fx.slice()) |e| switch (e) {
        .send => |s| switch (s.msg) {
            .join_ack => {},
            .forward_join => fanouts += 1,
            .disconnect => disconnects += 1,
            else => return error.Unexpected,
        },
        else => return error.Unexpected,
    };
    try testing.expectEqual(@as(usize, 1), disconnects);
    try testing.expectEqual(@as(usize, 2), fanouts);
    o.checkInvariants();
}

test "forward join: room proposes, ttl 0 full files passive, else forwards" {
    var o = Overlay.init(descOf(500), .{ .active_max = 2, .active_min = 1 }, 0);
    var fx: Effects = .{};
    const rng = testRng();

    const a = descOf(501);
    const b = descOf(504);
    o.handle(a.id, .{ .join = a }, 1, rng, &fx);
    o.handle(b.id, .{ .join = b }, 1, rng, &fx); // active full (max 2)

    fx.clear();
    const joiner = descOf(502);
    o.handle(a.id, .{ .forward_join = .{ .joiner = joiner, .ttl = 2 } }, 2, rng, &fx);
    var forwarded: usize = 0;
    for (fx.slice()) |e| switch (e) {
        .send => |s| switch (s.msg) {
            .forward_join => |fj| {
                forwarded += 1;
                try testing.expect(s.to.eql(b.id)); // not back to the sender
                try testing.expectEqual(@as(u8, 1), fj.ttl);
            },
            else => return error.Unexpected,
        },
        else => return error.Unexpected,
    };
    try testing.expectEqual(@as(usize, 1), forwarded);

    fx.clear();
    const joiner2 = descOf(503);
    o.handle(a.id, .{ .forward_join = .{ .joiner = joiner2, .ttl = 0 } }, 3, rng, &fx);
    try testing.expect(o.inPassive(joiner2.id) != null);

    var fresh = Overlay.init(descOf(510), .{}, 0);
    fx.clear();
    fresh.handle(descOf(511).id, .{ .forward_join = .{ .joiner = joiner, .ttl = 4 } }, 4, rng, &fx);
    var proposes: usize = 0;
    var connects: usize = 0;
    for (fx.slice()) |e| switch (e) {
        .send => |s| switch (s.msg) {
            .neighbor => |nb| {
                proposes += 1;
                try testing.expect(nb.urgent);
                try testing.expect(s.to.eql(joiner.id));
            },
            else => return error.Unexpected,
        },
        .connect => |c| {
            connects += 1;
            try testing.expect(c.id.eql(joiner.id));
        },
    };
    try testing.expectEqual(@as(usize, 1), proposes);
    try testing.expectEqual(@as(usize, 1), connects);
    o.checkInvariants();
}

test "neighbor handshake accept / urgent-evict / reject" {
    var o = Overlay.init(descOf(600), .{ .active_max = 2, .active_min = 1 }, 0);
    var fx: Effects = .{};
    const rng = testRng();

    const a = descOf(601);
    const b = descOf(602);
    const c = descOf(603);

    o.handle(a.id, .{ .neighbor = .{ .desc = a, .urgent = false } }, 1, rng, &fx);
    try testing.expect(o.inActive(a.id) != null);
    var accepts: usize = 0;
    for (fx.slice()) |e| switch (e) {
        .send => |s| {
                if (s.msg == .neighbor_accept) accepts += 1;
            },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), accepts);

    fx.clear();
    o.handle(b.id, .{ .neighbor = .{ .desc = b, .urgent = true } }, 2, rng, &fx);
    try testing.expectEqual(@as(usize, 2), o.active_len);
    try testing.expect(o.inActive(b.id) != null);

    fx.clear();
    o.handle(c.id, .{ .neighbor = .{ .desc = c, .urgent = false } }, 3, rng, &fx);
    try testing.expect(o.inActive(c.id) == null);
    var rejects: usize = 0;
    for (fx.slice()) |e| switch (e) {
        .send => |s| {
                if (s.msg == .neighbor_reject) rejects += 1;
            },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), rejects);
    o.checkInvariants();
}

test "accept resolves proposal into active; timeout keeps the passive entry" {
    var o = Overlay.init(descOf(700), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();

    const x = descOf(701);
    TestHooks.addPassive(&o, x);
    try testing.expect(o.inPassive(x.id) != null);

    // First scan proposes; the timeout lapses the proposal but keeps
    // the candidate in the passive view (addresses, not liveness).
    o.tick(o.cfg.promote_period_us, rng, &fx);
    try testing.expectEqual(@as(usize, 1), TestHooks.proposalsLen(&o));
    o.tick(o.cfg.promote_period_us + o.cfg.neighbor_timeout_us, rng, &fx);
    try testing.expect(o.inPassive(x.id) != null);
    // Still under active_min with the candidate still passive, the
    // next scan immediately re-proposes it (retry semantics).
    try testing.expectEqual(@as(usize, 1), TestHooks.proposalsLen(&o));

    // Re-add, propose again, accept: lands in active, leaves passive.
    TestHooks.addPassive(&o, x);
    o.tick(10 * o.cfg.promote_period_us, rng, &fx);
    o.handle(x.id, .neighbor_accept, 10 * o.cfg.promote_period_us + 1, rng, &fx);
    try testing.expect(o.inActive(x.id) != null);
    try testing.expect(o.inPassive(x.id) == null);
    o.checkInvariants();
}

test "disconnect and session loss demote to passive" {
    var o = Overlay.init(descOf(800), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();

    const a = descOf(801);
    o.handle(a.id, .{ .join = a }, 1, rng, &fx);
    try testing.expect(o.inActive(a.id) != null);

    o.handle(a.id, .{ .disconnect = a }, 2, rng, &fx);
    try testing.expect(o.inActive(a.id) == null);
    try testing.expect(o.inPassive(a.id) != null);

    const b = descOf(802);
    o.handle(b.id, .{ .join = b }, 3, rng, &fx);
    o.onSessionDown(b.id, 4);
    try testing.expect(o.inActive(b.id) == null);
    try testing.expect(o.inPassive(b.id) != null);
    o.checkInvariants();
}

test "shuffle merges samples; reply bounded and never contains self" {
    var o = Overlay.init(descOf(900), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();

    const sender = descOf(901);
    const s1 = descOf(902);
    const s2 = descOf(903);
    const incoming = [_]PeerDesc{ s1, s2 };
    o.handle(sender.id, .{ .shuffle = .{ .descs = &incoming } }, 1, rng, &fx);
    try testing.expect(o.inPassive(s1.id) != null);
    try testing.expect(o.inPassive(s2.id) != null);

    var replies: usize = 0;
    var reply_len: usize = std.math.maxInt(usize);
    for (fx.slice()) |e| switch (e) {
        .send => |s| switch (s.msg) {
            .shuffle_reply => |rep| {
                replies += 1;
                reply_len = rep.descs.len;
                for (rep.descs) |d| {
                    try testing.expect(!d.id.eql(o.self.id));
                }
            },
            else => return error.Unexpected,
        },
        else => return error.Unexpected,
    };
    try testing.expectEqual(@as(usize, 1), replies);
    try testing.expect(reply_len <= incoming.len);
    o.checkInvariants();
}

test "initiated shuffle leads with self and respects sample bound" {
    var o = Overlay.init(descOf(950), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();

    const a = descOf(951);
    o.handle(a.id, .{ .join = a }, 1, rng, &fx);

    var found = false;
    const deadline = o.next_shuffle_us;
    o.tick(deadline, rng, &fx);
    for (fx.slice()) |e| switch (e) {
        .send => |s| switch (s.msg) {
            .shuffle => |rep| {
                found = true;
                try testing.expect(rep.descs.len <= @as(usize, o.cfg.shuffle_active) + o.cfg.shuffle_passive);
                if (rep.descs.len > 0) {
                    try testing.expect(rep.descs[0].id.eql(o.self.id));
                }
            },
            else => {},
        },
        else => {},
    };
    try testing.expect(found);
    o.checkInvariants();
}

test "lone node keeps retrying its join contact; meshed node gives up" {
    var o = Overlay.init(descOf(1200), .{ .join_timeout_us = 100, .join_max_attempts = 2, .active_min = 1 }, 0);
    var fx: Effects = .{};
    const rng = testRng();
    const contact = descOf(1201);
    o.startJoin(contact, 0, &fx);

    // Burn past join_max_attempts with no answer and no mesh: the
    // lone node keeps knocking (JOIN + connect every timeout).
    o.tick(100, rng, &fx); // attempt 2
    o.tick(200, rng, &fx); // attempts exhausted — alone, so re-armed
    try testing.expect(o.join != null);
    fx.clear();
    o.tick(300, rng, &fx);
    try testing.expect(o.join != null);
    var saw_join = false;
    var saw_connect = false;
    for (fx.slice()) |e| switch (e) {
        .send => |s| {
            if (s.msg == .join) saw_join = true;
        },
        .connect => saw_connect = true,
    };
    try testing.expect(saw_join);
    try testing.expect(saw_connect);

    // With any active edge, the stale join lapses instead.
    const peer = descOf(1202);
    o.handle(peer.id, .{ .join = peer }, 301, rng, &fx);
    try testing.expect(o.inActive(peer.id) != null);
    o.tick(401, rng, &fx); // deadline 300 + 100 passed
    try testing.expect(o.join == null);
    o.checkInvariants();
}

test "view invariants survive a randomized operation storm" {
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const rng = prng.random();
    var o = Overlay.init(descOf(1000), .{ .active_max = 5, .passive_max = 8, .active_min = 2 }, 0);
    var fx: Effects = .{};

    var t: u64 = 0;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        t += rng.uintLessThan(u64, 100_000);
        const choice = rng.uintLessThan(u8, 12);
        const who = descOf(rng.int(u64));
        switch (choice) {
            0 => o.handle(who.id, .{ .join = who }, t, rng, &fx),
            1 => o.handle(who.id, .join_ack, t, rng, &fx),
            2 => o.handle(who.id, .{ .forward_join = .{ .joiner = who, .ttl = rng.uintLessThan(u8, 6) } }, t, rng, &fx),
            3 => o.handle(who.id, .{ .neighbor = .{ .desc = who, .urgent = rng.boolean() } }, t, rng, &fx),
            4 => o.handle(who.id, .neighbor_accept, t, rng, &fx),
            5 => o.handle(who.id, .neighbor_reject, t, rng, &fx),
            6 => o.handle(who.id, .{ .disconnect = who }, t, rng, &fx),
            7 => {
                const sample = [_]PeerDesc{ who, descOf(rng.int(u64)) };
                o.handle(who.id, .{ .shuffle = .{ .descs = &sample } }, t, rng, &fx);
            },
            8 => o.onSessionDown(who.id, t),
            9 => o.tick(t, rng, &fx),
            10 => o.notePeerRtt(who.id, rng.uintLessThan(u64, 500_000) + 1),
            11 => o.purge(who.id),
            else => unreachable,
        }
        o.checkInvariants();
        fx.clear();
    }
}

test "ranked minority: best-rtt set, capped, purged, and never displacing random actives" {
    var o = Overlay.init(descOf(1100), .{ .active_max = 3, .active_min = 3, .ranked_slots = 2 }, 0);
    var fx: Effects = .{};
    const rng = testRng();

    // RTT=0 (unknown) is ignored; self is ignored.
    const a = descOf(1101);
    o.notePeerRtt(a.id, 0);
    o.notePeerRtt(o.self.id, 10_000);
    try testing.expectEqual(@as(usize, 0), TestHooks.rankedSlice(&o).len);

    // Fill the ranked set: two best win; the worst is displaced by a
    // better newcomer.
    const b = descOf(1102);
    const c = descOf(1103);
    const d = descOf(1104);
    o.notePeerRtt(a.id, 100_000);
    o.notePeerRtt(b.id, 200_000);
    o.notePeerRtt(c.id, 50_000); // displaces b (200ms)
    try testing.expectEqual(@as(usize, 2), TestHooks.rankedSlice(&o).len);
    for (TestHooks.rankedSlice(&o)) |r| {
        try testing.expect(!r.id.eql(b.id));
    }
    o.notePeerRtt(d.id, 300_000); // worse than both: ignored
    try testing.expectEqual(@as(usize, 2), TestHooks.rankedSlice(&o).len);

    // Purge drops the entry (SWIM confirm).
    o.purge(c.id);
    try testing.expectEqual(@as(usize, 1), TestHooks.rankedSlice(&o).len);

    // Displacement discipline: view full of random actives + one
    // ranked active; a ranked newcomer must displace the RANKED
    // member, never a random one.
    o.notePeerRtt(c.id, 50_000);
    const r1 = descOf(1105);
    const r2 = descOf(1106);
    o.handle(r1.id, .{ .join = r1 }, 1, rng, &fx);
    o.handle(r2.id, .{ .join = r2 }, 2, rng, &fx);
    o.handle(a.id, .{ .join = a }, 3, rng, &fx); // a is ranked
    try testing.expectEqual(@as(usize, 3), o.active_len);
    try testing.expect(o.inActive(a.id) != null);

    fx.clear();
    o.handle(c.id, .{ .neighbor = .{ .desc = c, .urgent = true } }, 4, rng, &fx); // c ranked, better rtt
    try testing.expectEqual(@as(usize, 3), o.active_len);
    try testing.expect(o.inActive(c.id) != null); // ranked newcomer in
    try testing.expect(o.inActive(a.id) == null); // ranked member out
    try testing.expect(o.inActive(r1.id) != null); // random majority intact
    try testing.expect(o.inActive(r2.id) != null);
    try testing.expect(o.stats.ranked_displacements >= 1);
    o.checkInvariants();

    // Promotion preference: with the view under active_min, the best
    // ranked passive candidate is proposed first — deterministically,
    // regardless of what the uniform scan would have drawn (b sits in
    // passive as the decoy; it never enters the set at 200ms).
    fx.clear();
    TestHooks.addPassive(&o, b);
    o.onSessionDown(c.id, 5); // 2 actives < active_min 3: scan armed
    o.tick(5, rng, &fx);
    var proposed: ?PeerId = null;
    for (fx.slice()) |e| switch (e) {
        .send => |s| {
            if (s.msg == .neighbor) proposed = s.to;
        },
        else => {},
    };
    // Best dialable ranked passive not already active/proposed: c
    // (50ms) beats a (100ms) beats the unranked decoy b (200ms).
    try testing.expect(proposed != null);
    try testing.expect(proposed.?.eql(c.id));
    o.checkInvariants();
}

// Test-only hooks so tests can stage state without going through the
// message flow. Named to make non-test use obvious.
pub const TestHooks = struct {
    pub fn addPassive(o: *Overlay, d: PeerDesc) void {
        o.addPassive(d);
    }
    pub fn proposalsLen(o: *const Overlay) usize {
        return o.proposals_len;
    }
    /// The current locality minority (assertion surface for scenarios).
    pub fn rankedSlice(o: *const Overlay) []const Ranked {
        return o.ranked[0..o.ranked_len];
    }
};
