//! Simulated node: `qmesh.node.Node(SimTransport)` bound to a `World`.
//!
//! SimTransport is the simulator's implementation of the node driver's
//! transport contract (see src/node.zig): node-local frozen-while-
//! paused clock, per-node deterministic PRNG, sends that route through
//! the world's loss/delay/partition policy, and connects that map onto
//! the world's virtual session table.

const std = @import("std");
const qmesh = @import("qmesh");
const net = @import("network.zig");
const world_mod = @import("world.zig");

const NodeId = net.NodeId;
const World = world_mod.World;

pub const SimTransport = struct {
    world: *World,
    idx: NodeId,

    pub fn now(t: *SimTransport) u64 {
        return t.world.localNow(t.idx);
    }

    pub fn rng(t: *SimTransport) std.Random {
        return t.world.nodeRng(t.idx);
    }

    pub fn sendDatagram(t: *SimTransport, to: qmesh.PeerId, bytes: []const u8) !void {
        try t.send(to, bytes, false);
    }

    pub fn sendReliable(t: *SimTransport, to: qmesh.PeerId, bytes: []const u8) !void {
        try t.send(to, bytes, true);
    }

    fn send(t: *SimTransport, to: qmesh.PeerId, bytes: []const u8, reliable: bool) !void {
        const dst = t.world.index.get(to) orelse return error.UnknownPeer;
        if (!t.world.alive.items[t.idx] or !t.world.alive.items[dst]) return error.PeerDown;
        // Membership traffic without an established session is dropped:
        // the overlay's timeouts/retries own recovery. (Mirrors the
        // real adapter, which needs a live QUIC connection to send.)
        if (!t.world.sessions.establishedPair(t.idx, dst)) return error.NoSession;
        try t.world.sendMessage(t.idx, dst, bytes, reliable);
    }

    pub fn connect(t: *SimTransport, desc: qmesh.PeerDesc) !void {
        const dst = t.world.index.get(desc.id) orelse return error.UnknownPeer;
        try t.world.dial(t.idx, dst);
    }

    pub fn descOf(t: *SimTransport, id: qmesh.PeerId) ?qmesh.PeerDesc {
        const idx = t.world.index.get(id) orelse return null;
        return t.world.descs.items[idx];
    }
};

pub const SimNode = struct {
    transport: SimTransport,
    node: qmesh.node.Node(SimTransport),
};
