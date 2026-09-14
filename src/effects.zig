//! Bounded effect lists — the output vocabulary of every qmesh
//! protocol core.
//!
//! Protocol state machines (HyParView, SWIM, and Plumtree) are
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
const frame = @import("frame.zig");

/// How a message wants to travel. Maps to QUIC DATAGRAM (`ephemeral`:
/// lossy, never retransmitted, safe to lose) or a QUIC stream frame
/// (`reliable`: local admission to a reliable stream, not delivery acknowledgement). See frame.zig for the stream
/// length-prefix codec.
pub const Class = enum {
    ephemeral,
    reliable,
};

pub fn Effects(comptime Msg: type) type {
    return struct {
        const Self = @This();

        pub const max: usize = if (@hasDecl(Msg, "effect_capacity")) Msg.effect_capacity else 32;

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
        // A pushed message owns all slice contents. Protocol scratch may
        // be reused immediately; emitted messages live until clear().
        // Do not move a populated Effects value: its slices refer here.
        payloads: [max][frame.max_frame_len]u8 align(16) = undefined,

        /// Effect overflow is a protocol bug (each handler's worst case
        /// is bounded by view sizes), so this asserts rather than
        /// silently dropping.
        pub fn push(self: *Self, item: Item) void {
            std.debug.assert(self.len < max);
            self.items[self.len] = item;
            if (item == .send) {
                var arena = std.heap.FixedBufferAllocator.init(&self.payloads[self.len]);
                self.items[self.len].send.msg = capture(Msg, item.send.msg, arena.allocator());
            }
            self.len += 1;
        }

        pub fn remaining(self: *const Self) usize {
            return max - self.len;
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

/// Copy all borrowed slices recursively into one effect's bounded storage.
fn capture(comptime T: type, value: T, allocator: std.mem.Allocator) T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) @compileError("effect messages may only contain slice pointers");
            const copy = allocator.alloc(p.child, value.len) catch @panic("effect payload exceeds frame budget");
            for (value, copy) |v, *dest| dest.* = capture(p.child, v, allocator);
            return copy;
        },
        .@"struct" => |s| {
            var copy = value;
            inline for (s.field_names, s.field_types) |name, Field| @field(copy, name) = capture(Field, @field(value, name), allocator);
            return copy;
        },
        .@"union" => |u| {
            inline for (u.field_names, u.field_types) |name, Field| {
                if (std.meta.activeTag(value) == @field(std.meta.Tag(T), name))
                    return @unionInit(T, name, capture(Field, @field(value, name), allocator));
            }
            unreachable;
        },
        else => return value,
    }
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
