//! qmesh — a QUIC-native cluster mesh substrate.
//!
//! Layers (see README.md for the full map):
//!
//! ```text
//! peer identity      peer.PeerId / PeerDesc
//! wire framing       frame (version/protocol/type envelopes)
//! session boundary   session (vocabulary; QUIC adapter next milestone)
//! overlay            hyparview (active/passive views — pure state machine)
//! node driver        node.Node(Transport) — applies effects over a transport
//! ```
//!
//! The library core is transport-generic and allocation-light: every
//! protocol core is a pure state machine parameterized by explicit
//! `now`/`rng` arguments emitting bounded effect lists
//! (`effects.Effects`). The deterministic simulator lives in the
//! `qmesh_sim` module (sim/); real QUIC arrives through
//! `Node(QuicTransport)` without touching the cores.

const std = @import("std");

pub const peer = @import("peer.zig");
pub const frame = @import("frame.zig");
pub const effects = @import("effects.zig");
pub const session = @import("session.zig");
pub const hyparview = @import("hyparview.zig");
pub const swim = @import("swim.zig");
pub const plumtree = @import("plumtree.zig");
pub const node = @import("node.zig");

// Convenience re-exports for the types every consumer names.
pub const PeerId = peer.PeerId;
pub const PeerDesc = peer.PeerDesc;
pub const Addr = peer.Addr;

pub const Overlay = hyparview.Overlay;
pub const OverlayConfig = hyparview.Config;
pub const OverlayMsg = hyparview.Msg;

pub fn Node(comptime Transport: type) type {
    return node.Node(Transport);
}

test {
    _ = peer;
    _ = frame;
    _ = effects;
    _ = session;
    _ = hyparview;
    _ = swim;
    _ = plumtree;
    _ = node;
}
