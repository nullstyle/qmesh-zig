//! Bounded effect lists — the output vocabulary of every qmesh
//! protocol core.
//!
//! Protocol state machines (hyParView today; SWIM, Plumtree later) are
//! pure: `handle`/`tick` take explicit `now` and `rng` arguments, mutate
//! only their own state, and emit their outside-world intentions here.
//! The node driver applies effects through its transport. This keeps
//! the cores deterministic, trivially property-testable, and executable
//! against both the simulator and real QUIC without modification.
//!
//! `connect` asks the session layer to establish (or re-confirm) a
//! session to a peer; membership messages ride an established session
//! and are dropped by the transport when none exists — the protocol
//! never blocks on dialing.

const std = @import("std");
const peer_mod = @import("peer.zig");

/// How a message wants to travel. Maps to QUIC DATAGRAM (`ephemeral`:
/// lossy, never retransmitted, safe to lose) or a QUIC stream frame
/// (`reliable`: completion matters). See frame.zig for the stream
/// length-prefix codec.
pub const Class = enum {
    ephemeral,
    reliable,
};

pub fn Effects(comptime Msg: type) type {
    return struct {
        const Self = @This();

        pub const max: usize = 24;

        pub const Send = struct {
            to: peer_mod.PeerId,
            msg: Msg,
            class: Class,
        };

        pub const Item = union(enum) {
            send: Send,
            connect: peer_mod.PeerDesc,
        };

        items: [max]Item = undefined,
        len: usize = 0,

        /// Effect overflow is a protocol bug (each handler's worst case
        /// is bounded by view sizes), so this asserts rather than
        /// silently dropping.
        pub fn push(self: *Self, item: Item) void {
            std.debug.assert(self.len < max);
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const Item {
            return self.items[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub const OverflowCheck = struct {};
    };
}

test "effects push/slice/clear" {
    const M = enum { a, b };
    const E = Effects(M);
    var e: E = .{};
    e.push(.{ .send = .{ .to = .zero, .msg = .a, .class = .ephemeral } });
    e.push(.{ .connect = .{ .id = .zero } });
    try std.testing.expectEqual(@as(usize, 2), e.slice().len);
    e.clear();
    try std.testing.expectEqual(@as(usize, 0), e.slice().len);
}
