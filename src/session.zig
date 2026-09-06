//! The session boundary: qmesh's contract with transport-layer
//! connection management.
//!
//! A **PeerSession** is a stable, authenticated relationship with one
//! other cluster node — normally exactly one QUIC connection,
//! multiplexed by every qmesh protocol and eventually by application
//! traffic. Protocol cores never touch sessions directly; they emit
//! `connect` effects and consume session-up/down events, which keeps
//! them pure and transport-agnostic.
//!
//! A **SessionManager** owns the relationships:
//!
//! ```zig
//! sessions.ensure(peer_desc);            // dial if needed, dedupe
//! sessions.sendDatagram(peer, bytes);    // QUIC DATAGRAM frame
//! sessions.sendReliable(peer, bytes);    // one frame on a QUIC stream
//! var stream = try sessions.openStream(peer);
//! ```
//!
//! so higher layers say `ensure(peer)` rather than dialing QUIC
//! themselves. HyParView decides a peer belongs in the active view;
//! the session layer realizes that as a connection.
//!
//! This module currently defines only the shared state vocabulary and
//! the future QUIC mapping notes; the concrete implementations are:
//!
//! * `qmesh_sim` sessions — the simulator's virtual sessions (dial
//!   latency, kill/partition semantics), used by the scenario tests.
//! * `src/quic_sessions.zig` (next milestone) — the real one: one
//!   `quic.Server` + `quic.Client` per node, `PeerId` pinned to the
//!   TLS identity, DATAGRAM for `ephemeral` frames, one stream per
//!   `reliable` frame (u16 length-prefixed, see `frame.stream`).
//!
//! QUIC mapping notes for the real implementation:
//!
//! * `established` ⇔ `Connection.handshakeDone()` with the qmesh ALPN
//!   negotiated.
//! * `lost` reasons map from `quic.CloseEvent`/`CloseSource`: idle
//!   timeout, stateless reset, peer close, transport error. A QUIC
//!   *path* failure (migration candidate rejected) is NOT a session
//!   loss — only connection-level teardown is.
//! * RTT comes from `Connection.pathStats(.{...}).srtt_us`.
//! * Sends to a peer without an established session fail with
//!   `NoSession` — matching the simulator — and the overlay's retry
//!   paths absorb it.

/// Lifecycle state of the relationship with one peer, as observed by
/// protocol cores.
pub const SessionState = enum {
    /// No relationship.
    none,
    /// Dial (or handshake) in flight.
    connecting,
    /// Authenticated and usable.
    established,
};

/// Why a session ended. Transport-specific detail is deliberately
/// coarsened to what protocol cores act on: an overlay peer is always
/// demoted to passive regardless of reason; the reason exists for
/// metrics and debugging.
pub const SessionLostReason = enum {
    /// Local side closed (shutdown, eviction policy, resource cap).
    local_close,
    /// Peer closed cleanly.
    remote_close,
    /// Idle timeout / unresponsive peer.
    idle_timeout,
    /// Stateless reset — the peer process is gone or restarted.
    reset,
    /// QUIC transport error.
    transport_error,
    /// The dial never completed.
    dial_failed,
    /// Simulated fault injection (simulator only).
    simulated_fault,
};

/// Event delivered to a node driver when the transport layer's
/// relationship with a peer changes.
pub const SessionEvent = union(enum) {
    established: struct { peer: @import("peer.zig").PeerId },
    lost: struct { peer: @import("peer.zig").PeerId, reason: SessionLostReason },
};

test "session vocabulary" {
    // Compile-level sanity: the vocabulary is complete enough to name
    // every close path quic.CloseSource exposes today.
    const reasons = [_]SessionLostReason{ .local_close, .remote_close, .idle_timeout, .reset, .transport_error, .dial_failed, .simulated_fault };
    try @import("std").testing.expect(reasons.len == 7);
}
