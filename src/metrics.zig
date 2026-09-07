//! Point-in-time metrics snapshot for one mesh node.
//!
//! Plain old data, no allocator: the embedder takes a snapshot
//! (`Node.metrics()` / `qmesh_quic.Endpoint.metrics()`), serializes or
//! exposes it however it likes, and drops it. Counters are monotonic
//! since node start; gauges are current view sizes. Everything here is
//! derived from the pure cores' own state, so the same snapshot works
//! in the simulator and over real QUIC.
//!
//! This is the observability seam for long-running deployments; quic's
//! per-connection qlog events (the wire-level view) are wired
//! separately through `qmesh_quic.Endpoint.Options.qlog_callback`.

const hv = @import("hyparview.zig");
const swim_mod = @import("swim.zig");
const plum_mod = @import("plumtree.zig");

/// Overlay (HyParView) view sizes and lifetime counters.
pub const OverlayMetrics = struct {
    // Gauges.
    active: usize,
    passive: usize,
    ranked: usize,
    proposals: usize,
    // Counters.
    joins_received: u64,
    forward_joins_received: u64,
    shuffles_sent: u64,
    shuffles_received: u64,
    promotions_proposed: u64,
    evictions: u64,
    ranked_displacements: u64,
    disconnects_received: u64,
};

/// Membership (SWIM) table shape, Lifeguard state, and counters.
pub const SwimMetrics = struct {
    // Gauges.
    members_alive: usize,
    members_suspect: usize,
    members_dead: usize,
    /// Lifeguard local-health exponent (0 = healthy; windows scale
    /// by 2^local_health).
    local_health: u4,
    /// Smoothed-RTT envelope over members with a measurement
    /// (0 = nothing measured yet) — the cheap RTT matrix.
    rtt_min_us: u64,
    rtt_max_us: u64,
    // Counters.
    probes_sent: u64,
    acks_received: u64,
    suspects_declared: u64,
    confirms_declared: u64,
    refutations: u64,
};

/// Broadcast (Plumtree) tree shape and traffic counters.
pub const BroadcastMetrics = struct {
    // Gauges.
    eager_peers: usize,
    lazy_peers: usize,
    // Counters.
    published: u64,
    eager_pushes: u64,
    ihaves_sent: u64,
    iwants_sent: u64,
    repairs_answered: u64,
    delivered: u64,
    duplicates_dropped: u64,
    demotions: u64,
    promotions: u64,
    exchanges_sent: u64,
};

/// Node-driver frame flow and session transitions.
pub const DriverMetrics = struct {
    frames_received: u64,
    frames_sent: u64,
    decode_errors: u64,
    unknown_protocol: u64,
    sends_failed: u64,
    connects_issued: u64,
    sessions_up: u64,
    sessions_down: u64,
};

pub const Metrics = struct {
    overlay: OverlayMetrics,
    swim: SwimMetrics,
    broadcast: BroadcastMetrics,
    driver: DriverMetrics,
};

/// Snapshot the overlay core's counters and view sizes.
pub fn overlay(o: *const hv.Overlay) OverlayMetrics {
    return .{
        .active = o.active_len,
        .passive = o.passive_len,
        .ranked = o.ranked_len,
        .proposals = o.proposals_len,
        .joins_received = o.stats.joins_received,
        .forward_joins_received = o.stats.forward_joins_received,
        .shuffles_sent = o.stats.shuffles_sent,
        .shuffles_received = o.stats.shuffles_received,
        .promotions_proposed = o.stats.promotions_proposed,
        .evictions = o.stats.evictions,
        .ranked_displacements = o.stats.ranked_displacements,
        .disconnects_received = o.stats.disconnects_received,
    };
}

/// Snapshot the membership core's table shape and counters.
pub fn swim(s: *const swim_mod.Swim) SwimMetrics {
    var m: SwimMetrics = .{
        .members_alive = 0,
        .members_suspect = 0,
        .members_dead = 0,
        .local_health = s.local_health,
        .rtt_min_us = 0,
        .rtt_max_us = 0,
        .probes_sent = s.stats.probes_sent,
        .acks_received = s.stats.acks_received,
        .suspects_declared = s.stats.suspects_declared,
        .confirms_declared = s.stats.confirms_declared,
        .refutations = s.stats.refutations,
    };
    for (s.memberSlice()) |mem| switch (mem.state) {
        .alive => m.members_alive += 1,
        .suspect => m.members_suspect += 1,
        .dead => m.members_dead += 1,
    };
    for (s.memberSlice()) |mem| {
        if (mem.rtt_us == 0) continue;
        if (m.rtt_min_us == 0 or mem.rtt_us < m.rtt_min_us) m.rtt_min_us = mem.rtt_us;
        if (mem.rtt_us > m.rtt_max_us) m.rtt_max_us = mem.rtt_us;
    }
    return m;
}

/// Snapshot the broadcast core's tree shape and counters.
pub fn broadcast(b: *const plum_mod.Plumtree) BroadcastMetrics {
    return .{
        .eager_peers = b.eager_len,
        .lazy_peers = b.lazy_len,
        .published = b.stats.published,
        .eager_pushes = b.stats.eager_pushes,
        .ihaves_sent = b.stats.ihaves_sent,
        .iwants_sent = b.stats.iwants_sent,
        .repairs_answered = b.stats.repairs_answered,
        .delivered = b.stats.delivered,
        .duplicates_dropped = b.stats.duplicates_dropped,
        .demotions = b.stats.demotions,
        .promotions = b.stats.promotions,
        .exchanges_sent = b.stats.exchanges_sent,
    };
}

/// Assemble a whole-node snapshot from the cores' public state.
pub fn node(
    o: *const hv.Overlay,
    s: *const swim_mod.Swim,
    b: *const plum_mod.Plumtree,
    d: DriverMetrics,
) Metrics {
    return .{
        .overlay = overlay(o),
        .swim = swim(s),
        .broadcast = broadcast(b),
        .driver = d,
    };
}
