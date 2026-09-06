//! QuicTransport: the node driver's transport contract implemented
//! over an `Endpoint`. Outgress only — ingress flows from
//! `Endpoint.service` into the node, so this struct stays tiny.

const std = @import("std");
const qmesh = @import("qmesh");
const endpoint_mod = @import("endpoint.zig");

pub const QuicTransport = struct {
    endpoint: *endpoint_mod.Endpoint,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

    pub fn now(t: *QuicTransport) u64 {
        return t.endpoint.now_us;
    }

    pub fn rng(t: *QuicTransport) std.Random {
        return t.prng.random();
    }

    pub fn sendDatagram(t: *QuicTransport, to: qmesh.PeerId, bytes: []const u8) !void {
        try t.endpoint.sendDatagram(to, bytes);
    }

    pub fn sendReliable(t: *QuicTransport, to: qmesh.PeerId, bytes: []const u8) !void {
        try t.endpoint.sendReliable(to, bytes);
    }

    pub fn connect(t: *QuicTransport, desc: qmesh.PeerDesc) !void {
        try t.endpoint.connectPeer(desc);
    }
};
