//! Deployment timer profiles.
//!
//! Timers must be sized against measured network reality, not
//! defaults: probe timeouts against the worst region-pair RTT (plus
//! scheduler jitter), suspicion windows against platform lifecycle
//! pauses (a live migration that stalls a machine for seconds must
//! not escalate to CONFIRM + eviction churn — the pause-recover
//! simulator scenario is the acceptance test for that).

const swim = @import("swim.zig");
const hyparview = @import("hyparview.zig");
const plumtree = @import("plumtree.zig");

pub const Profile = struct {
    overlay: hyparview.Config,
    swim: swim.Config,
    broadcast: plumtree.Config,
};

/// Multi-region fly.io posture: 6pn cross-region RTT runs roughly
/// 50-300ms; machine live-migrations pause for hundreds of ms up to a
/// few seconds. Probe budgets sit above 2x worst RTT; the suspicion
/// window sits at ~3x a pessimistic migration pause so a migration
/// costs at most one suspicion cycle, never a CONFIRM. Validated by
/// the "fly migration pause" simulator scenario.
pub const fly_multi_region: Profile = .{
    .overlay = .{
        .active_max = 10,
        .active_min = 6,
        .shuffle_period_us = 5_000_000,
        .promote_period_us = 1_000_000,
        .neighbor_timeout_us = 2_000_000,
        .join_timeout_us = 3_000_000,
        .active_rotate_period_us = 60_000_000,
    },
    .swim = .{
        .probe_period_us = 1_000_000,
        .probe_timeout_us = 800_000,
        .indirect_timeout_us = 800_000,
        .suspicion_timeout_us = 8_000_000,
        .ping_req_fanout = 3,
        .dead_probe_every = 8,
    },
    .broadcast = .{
        .missing_timeout_us = 1_000_000,
        .iwant_timeout_us = 2_000_000,
        .ihave_flush_us = 50_000,
        .anti_entropy_period_us = 10_000_000,
    },
};
