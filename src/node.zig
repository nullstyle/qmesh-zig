//! The mesh node driver: glue between pure protocol cores and a
//! transport.
//!
//! A `Node(Transport)` owns the protocol state machines for one
//! cluster node and applies their effects through the smallest
//! transport surface qmesh needs:
//!
//! ```zig
//! Transport must provide (comptime duck-typed):
//!   fn now(t: *T) u64
//!       Node-local monotonic clock, microseconds.
//!   fn rng(t: *T) std.Random
//!       Node-local deterministic random stream (never global state —
//!       determinism requires per-node seeds).
//!   fn sendDatagram(t: *T, to: PeerId, bytes: []const u8) !void
//!       Lossy send. `bytes` is borrowed for the call only; the
//!       transport copies. No session ⇒ error (counted, dropped).
//!   fn sendReliable(t: *T, to: PeerId, bytes: []const u8) !void
//!       Completion-guaranteed send of one frame (see frame.stream).
//!       Same borrowing and session rules as sendDatagram.
//!   fn connect(t: *T, desc: PeerDesc) !void
//!       Ask the session manager to establish a session (idempotent;
//!       deduplicates concurrent dials between the same pair).
//! ```
//!
//! The simulator and the future QUIC adapter are the two Transport
//! implementations; nothing else should need one.
//!
//! Time model: the node runs entirely on the transport's clock. A
//! driver loop (sim event loop, or a QUIC embedder's iteration hook)
//! polls `nextDeadline`, sleeps or simulates until it, then calls
//! `tick` — the same shape as `quic.Connection.tick` +
//! `nextTimerDeadline`, so a QUIC embedder drives both clocks in one
//! place.

const std = @import("std");
const peer_mod = @import("peer.zig");
const frame = @import("frame.zig");
const hv = @import("hyparview.zig");

const PeerId = peer_mod.PeerId;
const PeerDesc = peer_mod.PeerDesc;

pub fn Node(comptime Transport: type) type {
    return struct {
        const Self = @This();

        pub const Stats = struct {
            frames_received: u64 = 0,
            frames_sent: u64 = 0,
            decode_errors: u64 = 0,
            unknown_protocol: u64 = 0,
            sends_failed: u64 = 0,
            connects_issued: u64 = 0,
            sessions_up: u64 = 0,
            sessions_down: u64 = 0,
        };

        transport: *Transport,
        overlay: hv.Overlay,
        stats: Stats = .{},

        decode_scratch: hv.DecodeScratch = .{},
        enc_buf: [frame.max_frame_len]u8 = undefined,
        fx: hv.Effects = .{},

        pub fn init(self_desc: PeerDesc, cfg: hv.Config, transport: *Transport) Self {
            return .{
                .transport = transport,
                .overlay = hv.Overlay.init(self_desc, cfg, transport.now()),
            };
        }

        pub fn id(self: *const Self) PeerId {
            return self.overlay.self.id;
        }

        pub fn selfDesc(self: *const Self) PeerDesc {
            return self.overlay.self;
        }

        /// Begin mesh membership through a bootstrap contact.
        pub fn startJoin(self: *Self, contact: PeerDesc) void {
            self.fx.clear();
            self.overlay.startJoin(contact, self.transport.now(), &self.fx);
            self.applyEffects();
        }

        /// Feed one received frame (already demuxed from datagram or
        /// stream transport). Malformed input is counted and dropped —
        /// a hostile peer cannot crash the node.
        pub fn handleWire(self: *Self, from: PeerId, bytes: []const u8) void {
            self.stats.frames_received += 1;
            const h = frame.decodeHeader(bytes) catch {
                self.stats.decode_errors += 1;
                return;
            };
            if (h.header.protocol != hv.proto_id) {
                self.stats.unknown_protocol += 1;
                return;
            }
            const msg = hv.decode(bytes, &self.decode_scratch) catch {
                self.stats.decode_errors += 1;
                return;
            };
            self.fx.clear();
            self.overlay.handle(from, msg, self.transport.now(), self.transport.rng(), &self.fx);
            self.applyEffects();
        }

        pub fn onSessionUp(self: *Self, peer: PeerId) void {
            self.stats.sessions_up += 1;
            self.fx.clear();
            self.overlay.onSessionUp(peer, self.transport.now(), &self.fx);
            self.applyEffects();
        }

        pub fn onSessionDown(self: *Self, peer: PeerId) void {
            self.stats.sessions_down += 1;
            self.overlay.onSessionDown(peer, self.transport.now());
            // onSessionDown emits nothing; no effects to apply.
        }

        /// Advance all protocol timers whose deadlines have passed on
        /// the transport clock. The driver calls this when the clock
        /// reaches `nextDeadline` (or periodically; ticks between
        /// deadlines are harmless no-ops).
        pub fn tick(self: *Self) void {
            self.fx.clear();
            self.overlay.tick(self.transport.now(), self.transport.rng(), &self.fx);
            self.applyEffects();
        }

        /// Soonest armed protocol deadline on the transport clock, for
        /// the driver loop's sleep calculation.
        pub fn nextDeadline(self: *const Self) ?u64 {
            return self.overlay.nextDeadline();
        }

        fn applyEffects(self: *Self) void {
            for (self.fx.slice()) |item| switch (item) {
                .send => |s| {
                    const bytes = hv.encode(s.msg, &self.enc_buf) catch |err| switch (err) {
                        // Message bodies are bounded by config asserts;
                        // hitting this is a codec bug.
                        error.NoRoomLeft => unreachable,
                    };
                    const result = switch (s.class) {
                        .ephemeral => self.transport.sendDatagram(s.to, bytes),
                        .reliable => self.transport.sendReliable(s.to, bytes),
                    };
                    if (result) |_| {
                        self.stats.frames_sent += 1;
                    } else |_| {
                        // Failed sends (no session, peer gone, queue
                        // full, OOM) are expected: the overlay's
                        // timeouts and retries own recovery. Count and
                        // move on.
                        self.stats.sends_failed += 1;
                    }
                },
                .connect => |desc| {
                    if (self.transport.connect(desc)) |_| {
                        self.stats.connects_issued += 1;
                    } else |_| {
                        self.stats.sends_failed += 1;
                    }
                },
            };
        }
    };
}

// A tiny fake transport exercising the contract from tests.
test "node drives overlay over a fake transport" {
    const FakeTransport = struct {
        clock: u64 = 0,
        prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(7),
        sent: std.ArrayListUnmanaged(struct { to: PeerId, bytes: []u8, reliable: bool }) = .empty,
        connects: std.ArrayListUnmanaged(PeerDesc) = .empty,
        allocator: std.mem.Allocator,

        fn now(t: *@This()) u64 {
            return t.clock;
        }
        fn rng(t: *@This()) std.Random {
            return t.prng.random();
        }
        fn sendDatagram(t: *@This(), to: PeerId, bytes: []const u8) !void {
            try t.sent.append(t.allocator, .{ .to = to, .bytes = try t.allocator.dupe(u8, bytes), .reliable = false });
        }
        fn sendReliable(t: *@This(), to: PeerId, bytes: []const u8) !void {
            try t.sent.append(t.allocator, .{ .to = to, .bytes = try t.allocator.dupe(u8, bytes), .reliable = true });
        }
        fn connect(t: *@This(), desc: PeerDesc) !void {
            try t.connects.append(t.allocator, desc);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var transport: FakeTransport = .{ .allocator = alloc };
    var prng1 = std.Random.DefaultPrng.init(1);
    var prng2 = std.Random.DefaultPrng.init(2);
    const me = PeerDesc{ .id = PeerId.fromRandom(prng1.random()), .addr = peer_mod.Addr.sim(1) };
    const contact = PeerDesc{ .id = PeerId.fromRandom(prng2.random()), .addr = peer_mod.Addr.sim(2) };

    var node = Node(FakeTransport).init(me, .{}, &transport);
    node.startJoin(contact);

    // JOIN (reliable) + connect emitted; the wire bytes decode back.
    try std.testing.expectEqual(@as(usize, 1), transport.sent.items.len);
    try std.testing.expectEqual(@as(usize, 1), transport.connects.items.len);
    try std.testing.expect(transport.sent.items[0].reliable);

    var scratch: hv.DecodeScratch = .{};
    const msg = try hv.decode(transport.sent.items[0].bytes, &scratch);
    try std.testing.expect(msg == .join);
    try std.testing.expect(msg.join.id.eql(me.id));

    // Session up re-sends JOIN; contact ACK makes it active.
    node.onSessionUp(contact.id);
    try std.testing.expectEqual(@as(usize, 2), transport.sent.items.len);
    var ack_buf: [frame.max_frame_len]u8 = undefined;
    node.handleWire(contact.id, try hv.encode(.join_ack, &ack_buf));
    try std.testing.expect(node.overlay.inActive(contact.id) != null);

    // A malformed frame is counted, not fatal.
    const before = node.stats.frames_received;
    node.handleWire(contact.id, &[_]u8{0xff, 0xff});
    try std.testing.expectEqual(before + 1, node.stats.frames_received);
    try std.testing.expectEqual(@as(u64, 1), node.stats.decode_errors);
}
