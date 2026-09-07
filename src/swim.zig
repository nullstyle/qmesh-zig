//! SWIM-style membership and failure detection (pure state machine).
//!
//! Same discipline as `hyparview.zig`: explicit `now`/`rng` arguments,
//! bounded effect lists, no I/O — the node driver will multiplex this
//! alongside the overlay on the same sessions (integration next; this
//! module lands the semantics first).
//!
//! Model (SWIM paper + memberlist-style refinements):
//!
//! * Every node tracks a bounded member table: `{desc, incarnation,
//!   state}` with state `alive | suspect | dead`.
//! * Probing: one member per `probe_period`. Direct PING → ACK; on
//!   timeout, PING_REQ to `ping_req_fanout` other members (indirect
//!   probing — the target may be reachable for others but not for
//!   us); on second timeout, SUSPECT the target. Direct ACKs double
//!   as RTT samples: each member carries a smoothed round-trip time,
//!   and probe/indirect/suspicion budgets are
//!   `max(profile floor, factor × smoothed RTT)` — co-located peers
//!   fail fast in multi-region clusters without padding everyone's
//!   timers to the worst region pair.
//! * Suspicion: suspected members keep being probed; if nothing
//!   refutes within `suspicion_timeout_us`, CONFIRM (dead). A member
//!   that observes a SUSPECT about itself refutes by broadcasting
//!   ALIVE with a bumped incarnation (refutation is also the reason
//!   ACKs carry the acker's incarnation).
//! * Incarnation lattice: an event applies iff its incarnation is
//!   strictly greater than the table's, OR equal with a stronger
//!   state (ALIVE < SUSPECT < CONFIRM at the same incarnation).
//!   CONFIRM is terminal for its incarnation; only a greater-
//!   incarnation ALIVE resurrects. Consequence: any interleaving of
//!   the same event set converges to the same table — the property
//!   the randomized test asserts.
//! * Dissemination: a bounded ring of recent events piggybacks on
//!   every PING/ACK (the paper's transport); detections and
//!   refutations additionally go out as standalone messages.
//!   Anti-entropy (later milestone) is the eventual-repair backstop.
//!
//! Lifeguard (first cut): `local_health` scales probe timeouts and
//! the suspicion window when this node is itself struggling (the
//! caller feeds observed scheduler delays via `noteAppDelay`). An
//! unhealthy node probes more patiently and suspects more slowly —
//! the paper's Local Health Multiplier. Buddy-system / T-man props
//! come later.
//!
//! Class mapping: all SWIM traffic is `ephemeral` — probes are
//! periodic by design; lost probes cost one period, never
//! correctness.

const std = @import("std");
const peer_mod = @import("peer.zig");
const frame = @import("frame.zig");
const effects_mod = @import("effects.zig");

const PeerId = peer_mod.PeerId;
const PeerDesc = peer_mod.PeerDesc;

pub const proto_id: u8 = frame.Protocol.membership;

pub const Config = struct {
    /// One probe target per period.
    probe_period_us: u64 = 1_000_000,
    /// Direct-probe round trip budget before indirect probing.
    probe_timeout_us: u64 = 500_000,
    /// Indirect probe budget before suspicion.
    indirect_timeout_us: u64 = 500_000,
    /// How long a suspicion may stand unrefuted before CONFIRM.
    suspicion_timeout_us: u64 = 3_000_000,
    /// PING_REQ fan-out (k).
    ping_req_fanout: u8 = 3,
    /// Events attached to each PING/ACK.
    piggyback_max: u8 = 6,
    /// Local-health cap: probe timeouts scale up to this multiple.
    max_local_health: u8 = 8,
    /// Every Nth probe targets a confirmed-dead member instead of the
    /// round-robin alive/suspect scan — the probe-driven resurrection
    /// trigger (session establishment is the other: `noteSessionAlive`).
    /// Without either, a healed partition stays split forever: both
    /// sides' tables hold the other side CONFIRMed dead, and
    /// equal-incarnation ACKs cannot beat a CONFIRM.
    dead_probe_every: u16 = 8,
};

pub const msg_type = struct {
    pub const ping: u8 = 1;
    pub const ack: u8 = 2;
    pub const ping_req: u8 = 3;
    pub const alive: u8 = 4;
    pub const suspect: u8 = 5;
    pub const confirm: u8 = 6;
};

pub const max_events_per_msg: usize = 8;
pub const max_members: usize = 1024;
pub const max_relays: usize = 4;

/// One membership event — the unit of dissemination (piggybacked or
/// standalone).
pub const Event = union(enum) {
    /// `desc.id` at `incarnation` is alive. `inc == 0` introduces a
    /// new member (carrying its dialable descriptor).
    alive: struct { desc: PeerDesc, incarnation: u32 },
    suspect: struct { id: PeerId, incarnation: u32 },
    confirm: struct { id: PeerId, incarnation: u32 },
};

pub const Msg = union(enum) {
    ping: struct { nonce: u64, events: []const Event },
    ack: struct { nonce: u64, incarnation: u32, events: []const Event },
    ping_req: struct { target: PeerId, nonce: u64 },
    alive: Event,
    suspect: Event,
    confirm: Event,
};

pub const Effects = effects_mod.Effects(Msg);
pub const Effect = Effects.Item;

pub const DecodeError = frame.DecodeError || error{ UnknownType, Malformed };

/// Scratch for decoding event-carrying messages. One per node; a
/// decoded Msg is valid until the next decode.
pub const DecodeScratch = struct {
    events: [max_events_per_msg]Event = undefined,
};

// ---------------------------------------------------------------------------
// codec

pub fn encode(msg: Msg, buf: []u8) frame.EncodeError![]const u8 {
    var w = frame.Writer.init(buf);
    switch (msg) {
        .ping => |m| {
            try frame.encodeHeader(&w, proto_id, msg_type.ping);
            try w.putU64(m.nonce);
            try encodeEvents(&w, m.events);
        },
        .ack => |m| {
            try frame.encodeHeader(&w, proto_id, msg_type.ack);
            try w.putU64(m.nonce);
            try w.putU32(m.incarnation);
            try encodeEvents(&w, m.events);
        },
        .ping_req => |m| {
            try frame.encodeHeader(&w, proto_id, msg_type.ping_req);
            try w.putU64(m.nonce);
            try w.putBytes(&m.target.bytes);
        },
        .alive => |ev| {
            try frame.encodeHeader(&w, proto_id, msg_type.alive);
            try encodeEvent(&w, ev);
        },
        .suspect => |ev| {
            try frame.encodeHeader(&w, proto_id, msg_type.suspect);
            try encodeEvent(&w, ev);
        },
        .confirm => |ev| {
            try frame.encodeHeader(&w, proto_id, msg_type.confirm);
            try encodeEvent(&w, ev);
        },
    }
    return w.written();
}

fn encodeEvents(w: *frame.Writer, events: []const Event) frame.EncodeError!void {
    std.debug.assert(events.len <= max_events_per_msg);
    try w.putU8(@intCast(events.len));
    for (events) |ev| try encodeEvent(w, ev);
}

fn encodeEvent(w: *frame.Writer, ev: Event) frame.EncodeError!void {
    switch (ev) {
        .alive => |a| {
            try w.putU8(1);
            try frame.DescCodec.encode(a.desc, w);
            try w.putU32(a.incarnation);
        },
        .suspect => |s| {
            try w.putU8(2);
            try w.putBytes(&s.id.bytes);
            try w.putU32(s.incarnation);
        },
        .confirm => |c| {
            try w.putU8(3);
            try w.putBytes(&c.id.bytes);
            try w.putU32(c.incarnation);
        },
    }
}

pub fn decode(bytes: []const u8, scratch: *DecodeScratch) DecodeError!Msg {
    const h = try frame.decodeHeader(bytes);
    if (h.header.protocol != proto_id) return DecodeError.Malformed;
    var r = frame.Reader.init(h.body);
    switch (h.header.msg_type) {
        msg_type.ping => {
            const nonce = try r.readU64();
            const events = try decodeEvents(&r, scratch);
            return .{ .ping = .{ .nonce = nonce, .events = events } };
        },
        msg_type.ack => {
            const nonce = try r.readU64();
            const incarnation = try r.readU32();
            const events = try decodeEvents(&r, scratch);
            return .{ .ack = .{ .nonce = nonce, .incarnation = incarnation, .events = events } };
        },
        msg_type.ping_req => {
            const nonce = try r.readU64();
            const target = try readPeerId(&r);
            return .{ .ping_req = .{ .target = target, .nonce = nonce } };
        },
        msg_type.alive, msg_type.suspect, msg_type.confirm => {
            const ev = try decodeEvent(&r);
            return switch (h.header.msg_type) {
                msg_type.alive => .{ .alive = ev },
                msg_type.suspect => .{ .suspect = ev },
                msg_type.confirm => .{ .confirm = ev },
                else => unreachable,
            };
        },
        else => return DecodeError.UnknownType,
    }
}

fn decodeEvents(r: *frame.Reader, scratch: *DecodeScratch) DecodeError![]Event {
    const count = try r.readU8();
    if (count > max_events_per_msg) return DecodeError.Malformed;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        scratch.events[i] = try decodeEvent(r);
    }
    return scratch.events[0..count];
}

fn decodeEvent(r: *frame.Reader) DecodeError!Event {
    const tag = try r.readU8();
    return switch (tag) {
        1 => blk: {
            const desc = try frame.DescCodec.decode(r);
            const inc = try r.readU32();
            break :blk .{ .alive = .{ .desc = desc, .incarnation = inc } };
        },
        2 => blk: {
            const id = try readPeerId(r);
            const inc = try r.readU32();
            break :blk .{ .suspect = .{ .id = id, .incarnation = inc } };
        },
        3 => blk: {
            const id = try readPeerId(r);
            const inc = try r.readU32();
            break :blk .{ .confirm = .{ .id = id, .incarnation = inc } };
        },
        else => DecodeError.Malformed,
    };
}

fn readPeerId(r: *frame.Reader) frame.DecodeError!PeerId {
    const b = try r.bytes(32);
    var id: PeerId = undefined;
    @memcpy(&id.bytes, b);
    return id;
}

// ---------------------------------------------------------------------------
// state machine

pub const MemberState = enum { alive, suspect, dead };

pub const Member = struct {
    desc: PeerDesc,
    incarnation: u32,
    state: MemberState,
    /// When the current state was entered (suspect windows, metrics).
    state_since_us: u64,
    /// Smoothed application-level round-trip time to this member,
    /// sampled from direct probe ACKs (0 = never measured). Drives
    /// RTT-aware probe/suspicion budgets: co-located peers fail fast
    /// while high-RTT peers get headroom, so profile timers no longer
    /// need worst-case padding for everyone.
    rtt_us: u64 = 0,
};

const Probe = struct {
    target: PeerId,
    nonce: u64,
    phase: enum { direct, indirect },
    deadline_us: u64,
    /// When the PING left (direct-ACK RTT sampling).
    started_us: u64,
};

const Relay = struct {
    nonce: u64,
    requester: PeerId,
    deadline_us: u64,
};

/// Strength ordering at equal incarnation: alive < suspect < confirm.
fn stateRank(s: MemberState) u8 {
    return switch (s) {
        .alive => 0,
        .suspect => 1,
        .dead => 2,
    };
}

// RTT-budget factors — physics, not deployment policy: a direct probe
// must comfortably cover one round trip, indirect probing spans two
// legs each way, and a suspicion window must survive several
// refutation round trips. Budgets apply as
// `max(profile floor, factor × smoothed member RTT)` per member.
pub const rtt_direct_factor: u64 = 2;
pub const rtt_indirect_factor: u64 = 3;
pub const rtt_suspicion_factor: u64 = 8;

pub const Swim = struct {
    const Self = @This();

    pub const Stats = struct {
        probes_sent: u64 = 0,
        pings_relayed: u64 = 0,
        acks_sent: u64 = 0,
        acks_received: u64 = 0,
        suspects_declared: u64 = 0,
        confirms_declared: u64 = 0,
        refutations: u64 = 0,
        events_applied: u64 = 0,
        events_stale: u64 = 0,
    };

    self: PeerDesc,
    self_incarnation: u32 = 0,
    cfg: Config,

    members: [max_members]Member = undefined,
    members_len: usize = 0,
    probe_cursor: usize = 0,

    probe: ?Probe = null,
    next_nonce: u64 = 1,
    next_probe_us: u64,
    probe_seq: u64 = 0,
    dead_cursor: usize = 0,

    /// Outstanding indirect-probe relays we promised to service.
    relays: [max_relays]Relay = undefined,
    relays_len: usize = 0,

    /// Recent events re-piggybacked on probes (bounded ring window).
    piggyback: [max_events_per_msg]Event = undefined,
    piggyback_len: usize = 0,
    piggyback_next: usize = 0,

    /// Lifeguard local-health exponent: 0 = healthy; each doubling of
    /// observed app delay beyond the probe budget bumps it (capped).
    local_health: u4 = 0,

    emit_scratch: [max_events_per_msg]Event = undefined,
    stats: Stats = .{},

    pub fn init(self_desc: PeerDesc, cfg: Config, now: u64) Self {
        std.debug.assert(cfg.piggyback_max <= max_events_per_msg);
        std.debug.assert(cfg.ping_req_fanout >= 1);
        return .{
            .self = self_desc,
            .cfg = cfg,
            .next_probe_us = now + cfg.probe_period_us,
        };
    }

    // --- membership table ------------------------------------------------

    pub fn memberSlice(s: *const Self) []const Member {
        return s.members[0..s.members_len];
    }

    pub fn find(s: *const Self, id: PeerId) ?usize {
        for (s.members[0..s.members_len], 0..) |m, i| {
            if (m.desc.id.eql(id)) return i;
        }
        return null;
    }

    pub fn stateOf(s: *const Self, id: PeerId) ?MemberState {
        const i = s.find(id) orelse return null;
        return s.members[i].state;
    }

    /// Smoothed application-level RTT to `id` in microseconds
    /// (0 = never measured). Sampled from direct probe ACKs; feeds
    /// per-member budgets and (via the node driver) the overlay's
    /// locality ranking.
    pub fn rttOf(s: *const Self, id: PeerId) u64 {
        const i = s.find(id) orelse return 0;
        return s.members[i].rtt_us;
    }

    /// Learn a member (session up, shuffle sample, ALIVE inc==0).
    /// New members enter `alive` at incarnation 0 unless known.
    pub fn observe(s: *Self, desc: PeerDesc, now: u64) void {
        if (desc.id.eql(s.self.id)) return;
        if (s.find(desc.id) != null) return;
        if (s.members_len >= max_members) return; // bounded; documented
        s.members[s.members_len] = .{
            .desc = desc,
            .incarnation = 0,
            .state = .alive,
            .state_since_us = now,
        };
        s.members_len += 1;
    }

    /// Session (re)establishment to `id`: the transport just completed
    /// an authenticated round trip with this peer NOW, which is direct
    /// liveness evidence of the same class as a probe ACK — and it
    /// outranks a stale CONFIRM/SUSPECT exactly like the `.ping`/`.ack`
    /// overrides. Resurrect or refute at incarnation+1 and disseminate.
    /// The node driver calls this from its session-up hook; without it,
    /// a live peer spuriously CONFIRMed under load can never come back
    /// (the transport keeps closing the session to the "dead" member
    /// before any probe evidence can cross it).
    pub fn noteSessionAlive(s: *Self, id: PeerId, now: u64) void {
        const i = s.find(id) orelse return;
        if (s.members[i].state == .alive) return;
        const ev: Event = .{ .alive = .{
            .desc = s.members[i].desc,
            .incarnation = s.members[i].incarnation + 1,
        } };
        _ = s.apply(ev, now);
        s.disseminate(ev);
    }

    /// Apply one membership event under the incarnation lattice.
    /// Returns true when the table changed. Self-directed suspicions
    /// are handled by `handle` (refutation), not here.
    pub fn apply(s: *Self, ev: Event, now: u64) bool {
        switch (ev) {
            .alive => |a| {
                if (a.desc.id.eql(s.self.id)) {
                    // Someone vouches for us with an old incarnation.
                    if (a.incarnation > s.self_incarnation) {
                        // We cannot have missed our own counter... unless
                        // we restarted at 0. Adopt and bump past it.
                        s.self_incarnation = a.incarnation;
                    }
                    return false;
                }
                const i = s.find(a.desc.id) orelse {
                    if (s.members_len >= max_members) return false;
                    s.members[s.members_len] = .{
                        .desc = a.desc,
                        .incarnation = a.incarnation,
                        .state = .alive,
                        .state_since_us = now,
                    };
                    s.members_len += 1;
                    s.stats.events_applied += 1;
                    return true;
                };
                return s.lattice(i, .alive, a.incarnation, a.desc, now);
            },
            .suspect => |sus| {
                if (sus.id.eql(s.self.id)) return false;
                // Unknown members are still inserted: dropping the event
                // would break commutativity (a peer that saw the ALIVE
                // later would land alive@0 while a peer that saw the
                // SUSPECT lands suspect@3 — same event set, different
                // tables). Entries without descriptors carry state only.
                const i = s.find(sus.id) orelse {
                    if (s.members_len >= max_members) return false;
                    s.members[s.members_len] = .{
                        .desc = .{ .id = sus.id },
                        .incarnation = sus.incarnation,
                        .state = .suspect,
                        .state_since_us = now,
                    };
                    s.members_len += 1;
                    s.stats.events_applied += 1;
                    return true;
                };
                return s.lattice(i, .suspect, sus.incarnation, s.members[i].desc, now);
            },
            .confirm => |c| {
                if (c.id.eql(s.self.id)) return false;
                const i = s.find(c.id) orelse {
                    if (s.members_len >= max_members) return false;
                    s.members[s.members_len] = .{
                        .desc = .{ .id = c.id },
                        .incarnation = c.incarnation,
                        .state = .dead,
                        .state_since_us = now,
                    };
                    s.members_len += 1;
                    s.stats.events_applied += 1;
                    return true;
                };
                return s.lattice(i, .dead, c.incarnation, s.members[i].desc, now);
            },
        }
    }

    fn lattice(s: *Self, i: usize, new_state: MemberState, inc: u32, desc: PeerDesc, now: u64) bool {
        const m = &s.members[i];
        const greater = inc > m.incarnation;
        const equal_stronger = inc == m.incarnation and stateRank(new_state) > stateRank(m.state);
        if (!greater and !equal_stronger) {
            s.stats.events_stale += 1;
            return false;
        }
        m.incarnation = inc;
        m.state = new_state;
        m.state_since_us = now;
        // An ALIVE may carry a fresher descriptor (address change) —
        // but an id-only descriptor (gossip built from a table entry
        // introduced by a SUSPECT/CONFIRM, which carry no address)
        // must never erase a dialable address: resurrection probes
        // need `desc.addr` to re-open the connection.
        if (new_state == .alive and desc.addr != .none) m.desc = desc;
        s.stats.events_applied += 1;
        return true;
    }

    /// Record an event locally (already applied) into the piggyback
    /// ring for dissemination.
    fn disseminate(s: *Self, ev: Event) void {
        if (s.piggyback_len < s.piggyback.len) {
            s.piggyback[s.piggyback_next] = ev;
            s.piggyback_next = (s.piggyback_next + 1) % s.piggyback.len;
            s.piggyback_len += 1;
        } else {
            s.piggyback[s.piggyback_next] = ev;
            s.piggyback_next = (s.piggyback_next + 1) % s.piggyback.len;
        }
    }

    fn takePiggyback(s: *Self, count: usize) []const Event {
        const n = @min(count, s.piggyback_len);
        for (0..n) |k| {
            const idx = (s.piggyback_next + s.piggyback.len - s.piggyback_len + k) % s.piggyback.len;
            s.emit_scratch[k] = s.piggyback[idx];
        }
        return s.emit_scratch[0..n];
    }

    // --- lifeguard --------------------------------------------------------

    /// Feed one observed application-scheduler delay (the gap between
    /// intended and actual wake, e.g. from the node driver's loop).
    /// Delays beyond the probe budget degrade local health; sustained
    /// good behavior recovers it. Growth is PROPORTIONAL to the delay:
    /// a multi-second stall bumps the multiplier until the scaled
    /// windows cover the stall itself — one step per call would leave
    /// the post-stall timer burst confirming live members whose
    /// refutation traffic was merely delayed with them.
    pub fn noteAppDelay(s: *Self, delay_us: u64) void {
        var budget = s.scaledProbeTimeout();
        if (delay_us > budget) {
            const cap: u4 = @intCast(@min(s.cfg.max_local_health, 15));
            while (delay_us > budget and s.local_health < cap) {
                s.local_health += 1;
                budget = s.scaledProbeTimeout();
            }
        } else if (delay_us * 2 < budget and s.local_health > 0) {
            s.local_health -= 1;
        }
    }

    pub fn scaledProbeTimeout(s: *const Self) u64 {
        return s.cfg.probe_timeout_us * (@as(u64, 1) << s.local_health);
    }

    pub fn scaledSuspicionTimeout(s: *const Self) u64 {
        return s.cfg.suspicion_timeout_us * (@as(u64, 1) << s.local_health);
    }

    // Per-member budgets: the Lifeguard-scaled profile floor, or the
    // member's own RTT scaled past it — whichever is larger.

    fn directBudgetFor(s: *const Self, m: Member) u64 {
        return @max(s.scaledProbeTimeout(), rtt_direct_factor *| m.rtt_us);
    }

    fn indirectBudgetFor(s: *const Self, m: Member) u64 {
        return @max(s.scaledIndirectTimeout(), rtt_indirect_factor *| m.rtt_us);
    }

    /// Suspicion window for one member (public: nextDeadline and the
    /// expiry scan share the exact arithmetic).
    pub fn suspicionBudgetFor(s: *const Self, m: Member) u64 {
        return @max(s.scaledSuspicionTimeout(), rtt_suspicion_factor *| m.rtt_us);
    }

    // --- timers -------------------------------------------------------------

    pub fn nextDeadline(s: *const Self) ?u64 {
        var best: ?u64 = null;
        if (s.probe) |p| best = p.deadline_us;
        // Suspicion expiry checks piggyback on probe cadence, but a
        // standing suspicion must not wait a full period: bound by its
        // own deadline.
        for (s.members[0..s.members_len]) |m| {
            if (m.state == .suspect) {
                const d = m.state_since_us + s.suspicionBudgetFor(m);
                if (best == null or d < best.?) best = d;
            }
        }
        // Only arm the next probe START when none is in flight: a
        // probe legitimately outlasting the period (probe_timeout +
        // indirect_timeout > probe_period — e.g. the fly profile's
        // 1s period vs 1.6s of probing) leaves next_probe_us in the
        // past mid-probe, and folding it in here pins the driver's
        // clock at a deadline no tick will advance (sim livelock).
        if (s.probe == null) {
            if (best == null or s.next_probe_us < best.?) best = s.next_probe_us;
        }
        return best;
    }

    /// Effective indirect-phase timeout scales with local health too.
    fn scaledIndirectTimeout(s: *const Self) u64 {
        return s.cfg.indirect_timeout_us * (@as(u64, 1) << s.local_health);
    }

    pub fn tick(s: *Self, now: u64, rng: std.Random, out: *Effects) void {
        // Active probe phases.
        if (s.probe) |*p| {
            if (now >= p.deadline_us) {
                switch (p.phase) {
                    .direct => {
                        // Escalate to indirect probing.
                        p.phase = .indirect;
                        p.deadline_us = now + (if (s.find(p.target)) |i|
                            s.indirectBudgetFor(s.members[i])
                        else
                            s.scaledIndirectTimeout());
                        // One random start, then a single rotation: every
                        // member is considered exactly once, so the
                        // fan-out count is exact (a per-iteration
                        // redraw could land on the target and waste
                        // the slot).
                        const start = rng.uintLessThan(usize, s.members_len);
                        var sent: usize = 0;
                        var step: usize = 0;
                        while (step < s.members_len and sent < s.cfg.ping_req_fanout) : (step += 1) {
                            const m = s.members[(start + step) % s.members_len];
                            if (m.state == .dead) continue;
                            if (m.desc.id.eql(p.target)) continue;
                            out.push(.{ .send = .{
                                .to = m.desc.id,
                                .msg = .{ .ping_req = .{ .target = p.target, .nonce = p.nonce } },
                                .class = .ephemeral,
                            } });
                            sent += 1;
                        }
                    },
                    .indirect => {
                        // Both direct and indirect probing failed: suspect.
                        const target = p.target;
                        s.probe = null;
                        s.suspectMember(target, now, rng, out);
                    },
                }
            }
        } else if (now >= s.next_probe_us) {
            s.next_probe_us = now + s.cfg.probe_period_us;
            s.startProbe(now, out);
        }

        // Suspicion expiry → confirm.
        var i: usize = 0;
        while (i < s.members_len) : (i += 1) {
            const m = s.members[i];
            if (m.state != .suspect) continue;
            if (now >= m.state_since_us + s.suspicionBudgetFor(m)) {
                const ev: Event = .{ .confirm = .{ .id = m.desc.id, .incarnation = m.incarnation } };
                _ = s.apply(ev, now);
                s.disseminate(ev);
                s.stats.confirms_declared += 1;
                if (s.gossipTargetExcluding(m.desc.id, rng)) |dest| {
                    out.push(.{ .send = .{
                        .to = dest,
                        .msg = .{ .confirm = ev },
                        .class = .ephemeral,
                    } });
                }
            }
        }

        // Relay table GC.
        var r: usize = 0;
        while (r < s.relays_len) {
            if (now >= s.relays[r].deadline_us) {
                s.relays[r] = s.relays[s.relays_len - 1];
                s.relays_len -= 1;
                continue;
            }
            r += 1;
        }
    }

    fn startProbe(s: *Self, now: u64, out: *Effects) void {
        if (s.members_len == 0) return;
        s.probe_seq += 1;

        var target: ?usize = null;

        // Resurrection slot: every Nth probe targets a confirmed-dead
        // member — the dial it triggers re-opens the connection, and
        // either the ACK here or the session establishment itself
        // (`noteSessionAlive`) is direct evidence that beats a stale
        // CONFIRM after a partition heals.
        if (s.cfg.dead_probe_every > 0 and s.probe_seq % s.cfg.dead_probe_every == 0) {
            var tries: usize = 0;
            while (tries < s.members_len) : (tries += 1) {
                const idx = (s.dead_cursor + tries) % s.members_len;
                if (s.members[idx].state == .dead) {
                    target = idx;
                    s.dead_cursor = (idx + 1) % s.members_len;
                    break;
                }
            }
        }

        if (target == null) {
            // Alive members round-robin, suspects first (refutation
            // chances).
            var tries: usize = 0;
            var idx: usize = s.probe_cursor % s.members_len;
            var suspect_first: ?usize = null;
            while (tries < s.members_len) : (tries += 1) {
                const m = s.members[idx];
                if (m.state == .suspect and suspect_first == null) suspect_first = idx;
                if (m.state == .alive) break;
                idx = (idx + 1) % s.members_len;
            }
            if (suspect_first) |si| {
                idx = si;
            } else if (s.members[idx].state == .dead) {
                return; // nothing live to probe
            }
            s.probe_cursor = (idx + 1) % s.members_len;
            target = idx;
        }

        const idx = target.?;
        const nonce = s.next_nonce;
        s.next_nonce += 1;
        s.probe = .{
            .target = s.members[idx].desc.id,
            .nonce = nonce,
            .phase = .direct,
            .deadline_us = now + s.directBudgetFor(s.members[idx]),
            .started_us = now,
        };
        const events = s.takePiggyback(s.cfg.piggyback_max);
        out.push(.{ .send = .{
            .to = s.members[idx].desc.id,
            .msg = .{ .ping = .{ .nonce = nonce, .events = events } },
            .class = .ephemeral,
        } });
        // Ask the session layer to (re)confirm a connection: probes
        // ride sessions, and this is the only thing that re-opens one
        // to a member whose overlay passive entry was purged — the
        // partition-recovery bootstrap. Idempotent when connected.
        if (s.members[idx].desc.addr != .none) {
            out.push(.{ .connect = s.members[idx].desc });
        }
        s.stats.probes_sent += 1;
    }

    fn suspectMember(s: *Self, target: PeerId, now: u64, rng: std.Random, out: *Effects) void {
        const i = s.find(target) orelse return;
        const inc = s.members[i].incarnation;
        const ev: Event = .{ .suspect = .{ .id = target, .incarnation = inc } };
        // NOTE: a rejected (already-suspect) re-suspicion must NOT
        // refresh state_since_us — the expiry window is anchored at the
        // FIRST suspicion of this incarnation. Refreshing on every
        // failed re-probe would postpone CONFIRM indefinitely for a
        // member nobody can reach (found in the fleet test: a victim
        // stuck suspect forever because its prober re-suspected faster
        // than the window expired).
        if (!s.apply(ev, now)) return;
        s.disseminate(ev);
        s.stats.suspects_declared += 1;
        if (s.gossipTargetExcluding(target, rng)) |dest| {
            out.push(.{ .send = .{
                .to = dest,
                .msg = .{ .suspect = ev },
                .class = .ephemeral,
            } });
        }
    }

    /// A random non-dead gossip target (standalone detections).
    fn gossipTargetExcluding(s: *Self, exclude: PeerId, rng: std.Random) ?PeerId {
        if (s.members_len == 0) return null;
        const start = rng.uintLessThan(usize, s.members_len);
        var probe: usize = 0;
        while (probe < s.members_len) : (probe += 1) {
            const m = s.members[(start + probe) % s.members_len];
            if (m.state == .dead) continue;
            if (m.desc.id.eql(exclude)) continue;
            return m.desc.id;
        }
        return null;
    }

    // --- message handling -----------------------------------------------------

    pub fn handle(
        s: *Self,
        from: PeerId,
        msg: Msg,
        now: u64,
        rng: std.Random,
        out: *Effects,
    ) void {
        _ = rng; // uniform with overlay.handle; SWIM's handlers are rng-free
        switch (msg) {
            .ping => |m| {
                // Direct-evidence resurrection (mirror of the ack
                // override in `.ack`): a PING we can authenticate from
                // a member our table holds CONFIRMed dead is live-now
                // evidence that outranks the stale gossip. This is
                // what makes healed partitions and resumed pauses
                // recover fast in BOTH directions — without it, each
                // side must wait for its own slow dead-probe rotation.
                if (s.find(from)) |i| {
                    if (s.members[i].state == .dead) {
                        const ev: Event = .{ .alive = .{
                            .desc = s.members[i].desc,
                            .incarnation = s.members[i].incarnation + 1,
                        } };
                        _ = s.apply(ev, now);
                        s.disseminate(ev);
                    }
                }
                for (m.events) |ev| s.applyEventFrom(from, ev, now, out);
                const events = s.takePiggyback(s.cfg.piggyback_max);
                out.push(.{ .send = .{
                    .to = from,
                    .msg = .{ .ack = .{ .nonce = m.nonce, .incarnation = s.self_incarnation, .events = events } },
                    .class = .ephemeral,
                } });
                s.stats.acks_sent += 1;
            },
            .ack => |m| {
                for (m.events) |ev| s.applyEventFrom(from, ev, now, out);
                s.stats.acks_received += 1;

                // Does this ack our own probe? (Direct ack comes from
                // the target; relayed acks arrive from the relay — the
                // nonce matches either way. A collision between our own
                // probe nonce and a nonce we're relaying is possible in
                // principle; target-identity disambiguates.)
                if (s.probe) |*p| {
                    if (p.nonce == m.nonce) {
                        const target = p.target;
                        const started_us = p.started_us;
                        s.probe = null;
                        // RTT sample: a direct ACK from the target times
                        // the PING this probe sent (phase-independent —
                        // a late direct ACK still measures the original
                        // send). Relayed ACKs (from != target) are not
                        // samples of OUR path.
                        if (from.eql(target)) {
                            if (s.find(target)) |ti| {
                                const sample = now -| started_us;
                                const cur = s.members[ti].rtt_us;
                                s.members[ti].rtt_us =
                                    if (cur == 0) sample else (cur + sample) / 2;
                            }
                        }
                        var inc = m.incarnation;
                        if (s.find(target)) |i| {
                            if (s.members[i].state == .dead) {
                                // Deliberate deviation from the strict
                                // lattice: a DIRECT authenticated
                                // round trip witnessed now outranks a
                                // CONFIRM gossiped in the past.
                                // Resurrect at an incarnation above the
                                // confirm so the resulting ALIVE event
                                // also heals other observers' tables
                                // through normal gossip.
                                inc = @max(m.incarnation, s.members[i].incarnation + 1);
                            }
                        }
                        const ev: Event = .{ .alive = .{
                            .desc = s.descFor(target) orelse .{ .id = target },
                            .incarnation = inc,
                        } };
                        _ = s.apply(ev, now);
                        s.disseminate(ev);
                        return;
                    }
                }
                // Otherwise it answers a relay we service: forward.
                for (s.relays[0..s.relays_len]) |rl| {
                    if (rl.nonce == m.nonce) {
                        out.push(.{ .send = .{
                            .to = rl.requester,
                            .msg = .{ .ack = .{ .nonce = m.nonce, .incarnation = m.incarnation, .events = &.{} } },
                            .class = .ephemeral,
                        } });
                        return;
                    }
                }
            },
            .ping_req => |m| {
                if (s.find(m.target) == null) return; // unknown member
                if (s.relays_len >= max_relays) {
                    // Bounded: drop the oldest rather than refuse.
                    s.relays[0] = s.relays[s.relays_len - 1];
                    s.relays_len -= 1;
                }
                s.relays[s.relays_len] = .{
                    .nonce = m.nonce,
                    .requester = from,
                    .deadline_us = now + s.scaledIndirectTimeout(),
                };
                s.relays_len += 1;
                out.push(.{ .send = .{
                    .to = m.target,
                    .msg = .{ .ping = .{ .nonce = m.nonce, .events = &.{} } },
                    .class = .ephemeral,
                } });
                s.stats.pings_relayed += 1;
            },
            .alive => |ev| s.applyEventFrom(from, ev, now, out),
            .suspect => |ev| s.applyEventFrom(from, ev, now, out),
            .confirm => |ev| s.applyEventFrom(from, ev, now, out),
        }
    }

    fn applyEventFrom(s: *Self, from: PeerId, ev: Event, now: u64, out: *Effects) void {
        // Self-directed suspicion: refute with a bumped incarnation.
        switch (ev) {
            .suspect => |sus| {
                if (sus.id.eql(s.self.id)) {
                    s.self_incarnation += 1;
                    const refutation: Event = .{ .alive = .{ .desc = s.self, .incarnation = s.self_incarnation } };
                    s.disseminate(refutation);
                    s.stats.refutations += 1;
                    out.push(.{ .send = .{
                        .to = from,
                        .msg = .{ .alive = refutation },
                        .class = .ephemeral,
                    } });
                    return;
                }
            },
            else => {},
        }
        if (s.apply(ev, now)) s.disseminate(ev);
    }

    fn descFor(s: *const Self, id: PeerId) ?PeerDesc {
        const i = s.find(id) orelse return null;
        return s.members[i].desc;
    }
};

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;
const Addr = peer_mod.Addr;

fn descOf(seed: u64) PeerDesc {
    var prng = std.Random.DefaultPrng.init(seed);
    return .{ .id = PeerId.fromRandom(prng.random()), .addr = Addr.sim(@truncate(seed)) };
}

fn testRng() std.Random {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    return prng.random();
}

test "event/msg codec round trip" {
    var scratch: DecodeScratch = .{};
    var buf: [frame.max_frame_len]u8 = undefined;
    var buf2: [frame.max_frame_len]u8 = undefined;

    const a = descOf(1);
    const b = descOf(2);
    const events = [_]Event{
        .{ .alive = .{ .desc = a, .incarnation = 3 } },
        .{ .suspect = .{ .id = b.id, .incarnation = 4 } },
        .{ .confirm = .{ .id = a.id, .incarnation = 5 } },
    };
    const msgs = [_]Msg{
        .{ .ping = .{ .nonce = 42, .events = &events } },
        .{ .ack = .{ .nonce = 42, .incarnation = 7, .events = &events } },
        .{ .ping_req = .{ .target = b.id, .nonce = 42 } },
        .{ .alive = events[0] },
        .{ .suspect = events[1] },
        .{ .confirm = events[2] },
    };
    for (msgs) |m| {
        const enc = try encode(m, &buf);
        const dec = try decode(enc, &scratch);
        const enc2 = try encode(dec, &buf2);
        try testing.expectEqualSlices(u8, enc, enc2);
    }
}

test "codec rejects malformed input" {
    var scratch: DecodeScratch = .{};
    try testing.expectError(DecodeError.UnknownType, decode(&[_]u8{ frame.version, proto_id, 99 }, &scratch));
    try testing.expectError(DecodeError.Malformed, decode(&[_]u8{ frame.version, 0x01, 1 }, &scratch));
    // event count beyond bound: header + 8-byte nonce + count=9
    try testing.expectError(
        DecodeError.Malformed,
        decode(&[_]u8{ frame.version, proto_id, msg_type.ping, 0, 0, 0, 0, 0, 0, 0, 0, 9 }, &scratch),
    );
    // unknown event tag
    try testing.expectError(
        DecodeError.Malformed,
        decode(&[_]u8{ frame.version, proto_id, msg_type.alive, 9 }, &scratch),
    );
}

test "incarnation lattice: monotone convergence under random interleavings" {
    // The same event set applied in any order must yield the same
    // table — the property that makes gossip-order tolerance work.
    var prng = std.Random.DefaultPrng.init(1234);
    const rng = prng.random();

    const peers = [_]PeerDesc{ descOf(10), descOf(11), descOf(12) };
    const events = [_]Event{
        .{ .alive = .{ .desc = peers[0], .incarnation = 0 } },
        .{ .alive = .{ .desc = peers[1], .incarnation = 2 } },
        .{ .suspect = .{ .id = peers[1].id, .incarnation = 2 } },
        .{ .alive = .{ .desc = peers[1], .incarnation = 5 } },
        .{ .confirm = .{ .id = peers[2].id, .incarnation = 1 } },
        .{ .suspect = .{ .id = peers[2].id, .incarnation = 1 } }, // stale rank
        .{ .alive = .{ .desc = peers[2], .incarnation = 1 } }, // stale vs confirm
        .{ .suspect = .{ .id = peers[0].id, .incarnation = 3 } },
        .{ .alive = .{ .desc = peers[0], .incarnation = 3 } }, // stale: suspect wins at equal inc
    };

    const expected_states = [_]MemberState{ .suspect, .alive, .dead };
    const expected_incs = [_]u32{ 3, 5, 1 };

    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        var s = Swim.init(descOf(99), .{}, 0);
        var order = events;
        rng.shuffle(Event, &order);
        for (order) |ev| _ = s.apply(ev, 1);
        for (peers, 0..) |p, i| {
            const idx = s.find(p.id).?;
            try testing.expectEqual(expected_states[i], s.members[idx].state);
            try testing.expectEqual(expected_incs[i], s.members[idx].incarnation);
        }
    }
}

test "probe lifecycle: direct ack resolves; timeout escalates to indirect then suspect" {
    var s = Swim.init(descOf(20), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();
    const target = descOf(21);
    s.observe(target, 0);
    // Indirect probing needs bystanders to ask.
    s.observe(descOf(22), 0);
    s.observe(descOf(23), 0);
    s.observe(descOf(24), 0);

    // First probe tick: PING out plus the session (re)confirm connect.
    s.tick(s.cfg.probe_period_us, rng, &fx);
    try testing.expect(s.probe != null);
    try testing.expectEqual(@as(usize, 2), fx.len);
    const ping = fx.slice()[0].send;
    try testing.expect(ping.msg == .ping);
    try testing.expect(fx.slice()[1] == .connect);

    // ACK resolves the probe and marks the member alive.
    fx.clear();
    const ack_msg: Msg = .{ .ack = .{ .nonce = s.probe.?.nonce, .incarnation = 0, .events = &.{} } };
    s.handle(target.id, ack_msg, s.cfg.probe_period_us + 10, rng, &fx);
    try testing.expect(s.probe == null);
    try testing.expectEqual(MemberState.alive, s.stateOf(target.id).?);

    // Probes run on a fixed cadence, round-robin over members — probe 2
    // may target a different member than probe 1, so follow the cursor.
    fx.clear();
    var t: u64 = 2 * s.cfg.probe_period_us; // probe 2 starts
    s.tick(t, rng, &fx);
    try testing.expect(s.probe != null);
    const t2 = s.probe.?.target;
    t += s.cfg.probe_timeout_us + 1;
    s.tick(t, rng, &fx); // escalate → ping_req fan-out
    var reqs: usize = 0;
    for (fx.slice()) |e| {
        switch (e) {
            .send => |send| {
                if (send.msg == .ping_req) reqs += 1;
            },
            .connect => {},
        }
    }
    try testing.expectEqual(@as(usize, s.cfg.ping_req_fanout), reqs);
    t += s.cfg.indirect_timeout_us + 1;
    fx.clear();
    s.tick(t, rng, &fx); // give up → SUSPECT
    try testing.expectEqual(MemberState.suspect, s.stateOf(t2).?);

    // Unrefuted suspicion expires to CONFIRM.
    const sus = s.find(t2).?;
    const confirm_at = s.members[sus].state_since_us + s.cfg.suspicion_timeout_us + 1;
    fx.clear();
    s.tick(confirm_at, rng, &fx);
    try testing.expectEqual(MemberState.dead, s.stateOf(t2).?);
}

test "suspicion refutation: target bumps incarnation and clears suspicion" {
    var s = Swim.init(descOf(30), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();
    const target = descOf(31);
    s.observe(target, 0);

    // Externally-reported suspicion at the member's incarnation.
    _ = s.apply(.{ .suspect = .{ .id = target.id, .incarnation = 0 } }, 1);
    try testing.expectEqual(MemberState.suspect, s.stateOf(target.id).?);

    // The target (modeled directly) refutes via ALIVE with a bumped
    // incarnation — arriving piggybacked on anything.
    _ = s.apply(.{ .alive = .{ .desc = target, .incarnation = 1 } }, 2);
    try testing.expectEqual(MemberState.alive, s.stateOf(target.id).?);
    try testing.expectEqual(@as(u32, 1), s.members[s.find(target.id).?].incarnation);

    // A stale alive at the old incarnation must not resurrect a dead.
    _ = s.apply(.{ .confirm = .{ .id = target.id, .incarnation = 2 } }, 3);
    try testing.expectEqual(MemberState.dead, s.stateOf(target.id).?);
    _ = s.apply(.{ .alive = .{ .desc = target, .incarnation = 2 } }, 4);
    try testing.expectEqual(MemberState.dead, s.stateOf(target.id).?);
    _ = s.apply(.{ .alive = .{ .desc = target, .incarnation = 3 } }, 5);
    try testing.expectEqual(MemberState.alive, s.stateOf(target.id).?);

    // Self-directed suspicion triggers refutation.
    fx.clear();
    const self_suspect: Event = .{ .suspect = .{ .id = s.self.id, .incarnation = 7 } };
    s.handle(descOf(32).id, .{ .suspect = self_suspect }, 6, rng, &fx);
    try testing.expectEqual(@as(u32, 1), s.self_incarnation);
    try testing.expectEqual(@as(usize, 1), fx.len); // ALIVE sent back
    try testing.expect(fx.slice()[0].send.msg == .alive);
}

test "session evidence resurrects the dead and refutes suspects" {
    var s = Swim.init(descOf(70), .{}, 0);
    const x = descOf(71);
    s.observe(x, 0);

    // Suspect, then session-up: refuted at incarnation+1.
    _ = s.apply(.{ .suspect = .{ .id = x.id, .incarnation = 0 } }, 1);
    try testing.expectEqual(MemberState.suspect, s.stateOf(x.id).?);
    s.noteSessionAlive(x.id, 2);
    try testing.expectEqual(MemberState.alive, s.stateOf(x.id).?);
    try testing.expectEqual(@as(u32, 1), s.members[s.find(x.id).?].incarnation);

    // Confirm, then session-up: resurrected at incarnation+1.
    _ = s.apply(.{ .confirm = .{ .id = x.id, .incarnation = 1 } }, 3);
    try testing.expectEqual(MemberState.dead, s.stateOf(x.id).?);
    s.noteSessionAlive(x.id, 4);
    try testing.expectEqual(MemberState.alive, s.stateOf(x.id).?);
    try testing.expectEqual(@as(u32, 2), s.members[s.find(x.id).?].incarnation);

    // Already alive: no-op (no incarnation inflation).
    s.noteSessionAlive(x.id, 5);
    try testing.expectEqual(@as(u32, 2), s.members[s.find(x.id).?].incarnation);

    // Unknown member: no-op (observe owns introductions).
    s.noteSessionAlive(descOf(72).id, 6);
    try testing.expect(s.find(descOf(72).id) == null);
}

test "repeated failed re-suspicion does not postpone confirm" {
    var s = Swim.init(descOf(80), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();
    const x = descOf(81);
    s.observe(x, 0);

    const first_suspicion: u64 = 1_000;
    s.suspectMember(x.id, first_suspicion, rng, &fx);
    try testing.expectEqual(MemberState.suspect, s.stateOf(x.id).?);
    try testing.expectEqual(first_suspicion, s.members[s.find(x.id).?].state_since_us);

    // Failed re-probes re-suspect at the same incarnation; the expiry
    // window stays anchored at the FIRST suspicion.
    s.suspectMember(x.id, first_suspicion + 500, rng, &fx);
    try testing.expectEqual(MemberState.suspect, s.stateOf(x.id).?);
    try testing.expectEqual(first_suspicion, s.members[s.find(x.id).?].state_since_us);

    // So CONFIRM lands at first_suspicion + window, not later —
    // unreachable members always converge to dead.
    s.tick(first_suspicion + s.cfg.suspicion_timeout_us, rng, &fx);
    try testing.expectEqual(MemberState.dead, s.stateOf(x.id).?);
}

test "id-only alive events never erase a dialable descriptor" {
    var s = Swim.init(descOf(90), .{}, 0);
    const x = descOf(91); // carries a dialable addr
    s.observe(x, 0);
    try testing.expect(s.members[s.find(x.id).?].desc.addr != .none);

    // Resurrect via an event whose descriptor is id-only (built from a
    // table entry introduced by address-less SUSPECT/CONFIRM gossip):
    // the state flips but the dialable address survives.
    _ = s.apply(.{ .confirm = .{ .id = x.id, .incarnation = 2 } }, 1);
    _ = s.apply(.{ .alive = .{ .desc = .{ .id = x.id }, .incarnation = 3 } }, 2);
    try testing.expectEqual(MemberState.alive, s.stateOf(x.id).?);
    try testing.expect(s.members[s.find(x.id).?].desc.addr != .none);
}

test "rtt: direct acks sample a smoothed rtt; budgets scale per member" {
    var s = Swim.init(descOf(95), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();
    const target = descOf(96);
    s.observe(target, 0);

    // Probe 1: ACKed 40ms after the PING left — one sample lands.
    s.tick(s.cfg.probe_period_us, rng, &fx);
    const started1 = s.probe.?.started_us;
    try testing.expectEqual(s.cfg.probe_period_us, started1);
    s.handle(target.id, .{ .ack = .{ .nonce = s.probe.?.nonce, .incarnation = 0, .events = &.{} } }, started1 + 40_000, rng, &fx);
    try testing.expectEqual(@as(u64, 40_000), s.rttOf(target.id));

    // Probe 2: 70ms round trip smooths toward the mean ((40+70)/2).
    s.tick(started1 + s.cfg.probe_period_us, rng, &fx);
    const started2 = s.probe.?.started_us;
    s.handle(target.id, .{ .ack = .{ .nonce = s.probe.?.nonce, .incarnation = 0, .events = &.{} } }, started2 + 70_000, rng, &fx);
    try testing.expectEqual(@as(u64, 55_000), s.rttOf(target.id));

    // Budgets: with a small rtt the profile floors dominate; a
    // high-rtt member extends past them by its factors.
    const m0 = s.members[s.find(target.id).?];
    try testing.expectEqual(s.scaledProbeTimeout(), s.directBudgetFor(m0));
    try testing.expectEqual(s.scaledSuspicionTimeout(), s.suspicionBudgetFor(m0));

    s.members[s.find(target.id).?].rtt_us = 400_000; // 400ms cross-region peer
    const m1 = s.members[s.find(target.id).?];
    try testing.expectEqual(rtt_direct_factor * 400_000, s.directBudgetFor(m1));
    try testing.expectEqual(rtt_indirect_factor * 400_000, s.indirectBudgetFor(m1));
    try testing.expectEqual(rtt_suspicion_factor * 400_000, s.suspicionBudgetFor(m1));

    // Arming honors the member budget: probe to the high-rtt member
    // gets the extended direct deadline.
    fx.clear();
    s.tick(started2 + 2 * s.cfg.probe_period_us, rng, &fx);
    try testing.expect(s.probe != null);
    try testing.expectEqual(started2 + 2 * s.cfg.probe_period_us + rtt_direct_factor * 400_000, s.probe.?.deadline_us);
}

test "ping_req relay: forward ping, route the ack back to the requester" {
    var s = Swim.init(descOf(40), .{}, 0); // the relay
    var fx: Effects = .{};
    const rng = testRng();
    const prober = descOf(41);
    const target = descOf(42);
    s.observe(target, 0);

    // Prober asks us to probe target on its behalf.
    s.handle(prober.id, .{ .ping_req = .{ .target = target.id, .nonce = 77 } }, 1, rng, &fx);
    var pings: usize = 0;
    for (fx.slice()) |e| {
        if (e.send.msg == .ping and e.send.to.eql(target.id)) {
            pings += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), pings);

    // Target acks; we relay to the prober.
    fx.clear();
    s.handle(target.id, .{ .ack = .{ .nonce = 77, .incarnation = 3, .events = &.{} } }, 2, rng, &fx);
    var relayed: usize = 0;
    for (fx.slice()) |e| {
        if (e.send.msg == .ack and e.send.to.eql(prober.id)) {
            relayed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), relayed);
}

test "lifeguard: local health scales probe and suspicion windows" {
    var s = Swim.init(descOf(50), .{}, 0);
    const base_probe = s.scaledProbeTimeout();
    const base_suspicion = s.scaledSuspicionTimeout();

    // A bad app delay doubles the windows.
    s.noteAppDelay(base_probe * 2);
    try testing.expectEqual(@as(u4, 1), s.local_health);
    try testing.expectEqual(base_probe * 2, s.scaledProbeTimeout());
    try testing.expectEqual(base_suspicion * 2, s.scaledSuspicionTimeout());

    // Sustained good delays recover one step at a time.
    s.noteAppDelay(base_probe / 4);
    try testing.expectEqual(@as(u4, 0), s.local_health);
    try testing.expectEqual(base_probe, s.scaledProbeTimeout());
}

test "piggyback: disseminated events ride pings and acks, bounded" {
    var s = Swim.init(descOf(60), .{}, 0);
    var fx: Effects = .{};
    const rng = testRng();
    const target = descOf(61);
    const other = descOf(62);
    s.observe(target, 0);
    s.observe(other, 0);

    // A detection enters the ring...
    _ = s.apply(.{ .suspect = .{ .id = other.id, .incarnation = 0 } }, 1);
    s.disseminate(.{ .suspect = .{ .id = other.id, .incarnation = 0 } });

    // ...the next probe carries it.
    s.tick(s.cfg.probe_period_us, rng, &fx);
    const ping = fx.slice()[0].send.msg.ping;
    try testing.expect(ping.events.len >= 1);
    try testing.expect(ping.events[0] == .suspect);

    // And so does every ack we send.
    fx.clear();
    s.handle(target.id, .{ .ping = .{ .nonce = 1, .events = &.{} } }, 2, rng, &fx);
    const ack = fx.slice()[0].send.msg.ack;
    try testing.expect(ack.events.len >= 1);
    try testing.expect(ack.events[0] == .suspect);
}
