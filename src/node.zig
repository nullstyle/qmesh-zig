//! The mesh node driver: glue between pure protocol cores and a
//! transport.
//!
//! A `Node(Transport)` owns the protocol state machines for one
//! cluster node — the HyParView overlay and the SWIM membership layer
//! — multiplexing both on the same frames-in/effects-out cycle:
//!
//! ```text
//! ingress frame ──decode──▶ route by protocol byte
//!     0x01 overlay  → overlay.handle → effects
//!     0x02 swim     → swim.handle    → effects
//! effects ──encode──▶ transport.sendDatagram / sendReliable / connect
//! timers: min(overlay.nextDeadline, swim.nextDeadline) → tick both
//! ```
//!
//! Cross-protocol coupling lives HERE, never inside the cores: session
//! establishment feeds SWIM's member table (`observe`) and is direct
//! liveness evidence (`noteSessionAlive` — an authenticated handshake
//! with a member held suspect/dead resurrects it); SWIM CONFIRM purges
//! the overlay's passive view (`overlay.purge`); SWIM's measured member
//! RTTs feed the overlay's locality ranking (`overlay.notePeerRtt` —
//! the ranked active-slot minority).
//!
//! Transport contract (comptime duck-typed):
//!
//! ```zig
//! fn now(t: *T) u64
//!     Node-local monotonic clock, microseconds.
//! fn rng(t: *T) std.Random
//!     Node-local deterministic random stream (never global state —
//!     determinism requires per-node seeds).
//! fn sendDatagram(t: *T, to: PeerId, bytes: []const u8) !void
//!     Lossy send. `bytes` is borrowed for the call only; the
//!     transport copies. No session ⇒ error (counted, dropped).
//! fn sendReliable(t: *T, to: PeerId, bytes: []const u8) !void
//!     Completion-guaranteed send of one frame (see frame.stream).
//!     Same borrowing and session rules as sendDatagram.
//! fn connect(t: *T, desc: PeerDesc) !void
//!     Ask the session manager to establish a session (idempotent;
//!     deduplicates concurrent dials between the same pair).
//! fn descOf(t: *T, id: PeerId) ?PeerDesc
//!     Best-known descriptor for a connected peer (session HELLO /
//!     world table), so SWIM's member entries carry dialable
//!     addresses. Null when unknown.
//! ```
//!
//! The simulator and the QUIC adapter are the two Transport
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
const swim_mod = @import("swim.zig");
const plum_mod = @import("plumtree.zig");

const PeerId = peer_mod.PeerId;
const PeerDesc = peer_mod.PeerDesc;

pub fn Node(comptime Transport: type) type {
    return struct {
        const Self = @This();

        pub const Config = struct {
            overlay: hv.Config = .{},
            swim: swim_mod.Config = .{},
            broadcast: plum_mod.Config = .{},
        };

        /// Driver-level application callbacks. The cores stay pure;
        /// deliveries surface here, with payload slices valid for the
        /// duration of the call only.
        pub const Hooks = struct {
            ctx: ?*anyopaque = null,
            onBroadcast: ?*const fn (
                ctx: ?*anyopaque,
                origin: PeerId,
                seq: u64,
                payload: []const u8,
            ) void = null,
        };

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
        swim: swim_mod.Swim,
        broadcast: plum_mod.Plumtree,
        hooks: Hooks = .{},
        stats: Stats = .{},

        decode_scratch: hv.DecodeScratch = .{},
        swim_scratch: swim_mod.DecodeScratch = .{},
        plum_scratch: plum_mod.DecodeScratch = .{},
        enc_buf: [frame.max_frame_len]u8 = undefined,
        fx: hv.Effects = .{},
        swim_fx: swim_mod.Effects = .{},
        plum_fx: plum_mod.Effects = .{},

        pub fn init(self_desc: PeerDesc, cfg: Config, transport: *Transport, hooks: Hooks) Self {
            const now = transport.now();
            return .{
                .transport = transport,
                .overlay = hv.Overlay.init(self_desc, cfg.overlay, now),
                .swim = swim_mod.Swim.init(self_desc, cfg.swim, now),
                .broadcast = plum_mod.Plumtree.init(self_desc.id, cfg.broadcast, now),
                .hooks = hooks,
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
            self.applyFx(hv.Msg, hv.encode, &self.fx);
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
            switch (h.header.protocol) {
                hv.proto_id => {
                    const msg = hv.decode(bytes, &self.decode_scratch) catch {
                        self.stats.decode_errors += 1;
                        return;
                    };
                    self.fx.clear();
                    self.overlay.handle(from, msg, self.transport.now(), self.transport.rng(), &self.fx);
                    self.applyFx(hv.Msg, hv.encode, &self.fx);
                    self.syncBroadcastPeers();
                },
                swim_mod.proto_id => {
                    const msg = swim_mod.decode(bytes, &self.swim_scratch) catch {
                        self.stats.decode_errors += 1;
                        return;
                    };
                    self.swim_fx.clear();
                    self.swim.handle(from, msg, self.transport.now(), self.transport.rng(), &self.swim_fx);
                    self.applyFx(swim_mod.Msg, swim_mod.encode, &self.swim_fx);
                },
                plum_mod.proto_id => {
                    const msg = plum_mod.decode(bytes, &self.plum_scratch) catch {
                        self.stats.decode_errors += 1;
                        return;
                    };
                    self.plum_fx.clear();
                    self.broadcast.handle(from, msg, self.transport.now(), &self.plum_fx);
                    self.applyFx(plum_mod.Msg, plum_mod.encode, &self.plum_fx);
                    self.drainDeliveries();
                },
                else => self.stats.unknown_protocol += 1,
            }
        }

        /// Broadcast a payload cluster-wide (eager/lazy tree). Returns
        /// null when the payload exceeds the frame budget.
        pub fn publish(self: *Self, payload: []const u8) ?plum_mod.MsgId {
            if (payload.len > plum_mod.max_payload) return null;
            self.plum_fx.clear();
            const msg_id = self.broadcast.publish(payload, self.transport.now(), &self.plum_fx);
            self.applyFx(plum_mod.Msg, plum_mod.encode, &self.plum_fx);
            return msg_id;
        }

        pub fn onSessionUp(self: *Self, peer: PeerId) void {
            self.stats.sessions_up += 1;
            const now = self.transport.now();
            // SWIM learns the member with its best-known descriptor;
            // if the table holds it suspect/dead, the session's
            // authenticated handshake is direct liveness evidence that
            // outranks the stale gossip (resurrection path).
            const desc = self.transport.descOf(peer) orelse PeerDesc{ .id = peer };
            self.swim.observe(desc, now);
            self.swim.noteSessionAlive(peer, now);
            self.fx.clear();
            self.overlay.onSessionUp(peer, now, &self.fx);
            self.applyFx(hv.Msg, hv.encode, &self.fx);
        }

        pub fn onSessionDown(self: *Self, peer: PeerId) void {
            self.stats.sessions_down += 1;
            // Session loss is an overlay concern; SWIM owns liveness
            // separately (a dropped session ≠ a dead member). The
            // broadcast tree loses the peer with the connection.
            self.overlay.onSessionDown(peer, self.transport.now());
            self.broadcast.removePeer(peer);
        }

        /// Advance all protocol timers whose deadlines have passed on
        /// the transport clock. The driver calls this when the clock
        /// reaches `nextDeadline` (or periodically; ticks between
        /// deadlines are harmless no-ops).
        pub fn tick(self: *Self) void {
            const now = self.transport.now();
            const rng = self.transport.rng();

            self.fx.clear();
            self.overlay.tick(now, rng, &self.fx);
            self.applyFx(hv.Msg, hv.encode, &self.fx);

            self.swim_fx.clear();
            self.swim.tick(now, rng, &self.swim_fx);
            self.applyFx(swim_mod.Msg, swim_mod.encode, &self.swim_fx);

            self.plum_fx.clear();
            self.broadcast.tick(now, rng, &self.plum_fx);
            self.applyFx(plum_mod.Msg, plum_mod.encode, &self.plum_fx);

            // The broadcast tree rides the overlay's active view: new
            // actives join (eager first, duplicates trim), departed
            // actives leave. Done here and after overlay ingress so
            // both sides of a membership change converge quickly.
            self.syncBroadcastPeers();

            // Cross-protocol coupling (partition recovery included):
            // confirmed-dead members leave the overlay entirely (their
            // active edge demotes as if the session dropped — the
            // transport layer closes the connection when SWIM
            // confirms; see Endpoint.service) and the broadcast tree
            // drops them; alive members with dialable addresses the
            // views have forgotten re-enter the passive view; measured
            // member RTTs feed the overlay's locality ranking (the
            // ranked minority — plumtree inherits locality through the
            // active view). All idempotent — the full sweep is the
            // honest cheap thing.
            for (self.swim.memberSlice()) |m| {
                switch (m.state) {
                    .dead => {
                        if (self.overlay.inActive(m.desc.id) != null) {
                            self.overlay.onSessionDown(m.desc.id, now);
                        }
                        self.overlay.purge(m.desc.id);
                        self.broadcast.removePeer(m.desc.id);
                    },
                    .alive, .suspect => {
                        if (m.state == .alive and
                            m.desc.addr != .none and
                            self.overlay.inActive(m.desc.id) == null and
                            self.overlay.inPassive(m.desc.id) == null)
                        {
                            self.overlay.notePeer(m.desc);
                        }
                        if (m.rtt_us > 0) self.overlay.notePeerRtt(m.desc.id, m.rtt_us);
                    },
                }
            }
        }

        /// Soonest armed protocol deadline on the transport clock, for
        /// the driver loop's sleep calculation.
        pub fn nextDeadline(self: *const Self) ?u64 {
            var best: ?u64 = null;
            for ([_]?u64{
                self.overlay.nextDeadline(),
                self.swim.nextDeadline(),
                self.broadcast.nextDeadline(),
            }) |d| {
                if (d) |v| {
                    if (best == null or v < best.?) best = v;
                }
            }
            return best;
        }

        fn syncBroadcastPeers(self: *Self) void {
            const now = self.transport.now();
            for (self.overlay.activeSlice()) |e| {
                self.broadcast.addPeer(e.desc.id, now);
            }
            var i: usize = 0;
            while (i < self.broadcast.eager_len) {
                const peer = self.broadcast.eagerSlice()[i];
                if (self.overlay.inActive(peer) != null) {
                    i += 1;
                    continue;
                }
                self.broadcast.removePeer(peer);
            }
            i = 0;
            while (i < self.broadcast.lazy_len) {
                const peer = self.broadcast.lazySlice()[i];
                if (self.overlay.inActive(peer) != null) {
                    i += 1;
                    continue;
                }
                self.broadcast.removePeer(peer);
            }
        }

        fn drainDeliveries(self: *Self) void {
            for (self.broadcast.takeDeliveries()) |d| {
                // A staged payload must always be a bounded cache slice.
                std.debug.assert(d.payload.len <= plum_mod.max_payload);
                if (self.hooks.onBroadcast) |cb| {
                    cb(self.hooks.ctx, d.id.origin, d.id.seq, d.payload);
                }
            }
        }

        fn applyFx(
            self: *Self,
            comptime Msg: type,
            comptime encodeFn: fn (Msg, []u8) frame.EncodeError![]const u8,
            fx: *const @import("effects.zig").Effects(Msg),
        ) void {
            for (fx.slice()) |item| switch (item) {
                .send => |s| {
                    const bytes = encodeFn(s.msg, &self.enc_buf) catch |err| switch (err) {
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
                        // full, OOM) are expected: the protocol timers
                        // own recovery. Count and move on.
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
        fn descOf(t: *@This(), id: PeerId) ?PeerDesc {
            _ = t;
            return PeerDesc{ .id = id };
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

    var node = Node(FakeTransport).init(me, .{}, &transport, .{});
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

test "node multiplexes swim beside the overlay and purges on confirm" {
    const FakeTransport = struct {
        clock: u64 = 0,
        prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(9),
        sent: std.ArrayListUnmanaged(struct { to: PeerId, bytes: []u8, reliable: bool }) = .empty,
        connects: std.ArrayListUnmanaged(PeerDesc) = .empty,
        allocator: std.mem.Allocator,

        fn now(t: *@This()) u64 {
            return t.clock;
        }
        fn rng(t: *@This()) std.Random {
            return t.prng.random();
        }
        fn descOf(t: *@This(), id: PeerId) ?PeerDesc {
            _ = t;
            return PeerDesc{ .id = id };
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
    var prng1 = std.Random.DefaultPrng.init(3);
    var prng2 = std.Random.DefaultPrng.init(4);
    const me = PeerDesc{ .id = PeerId.fromRandom(prng1.random()), .addr = peer_mod.Addr.sim(1) };
    const victim = PeerDesc{ .id = PeerId.fromRandom(prng2.random()), .addr = peer_mod.Addr.sim(2) };

    var node = Node(FakeTransport).init(me, .{}, &transport, .{});

    // Session up: SWIM observes the member.
    node.onSessionUp(victim.id);
    try std.testing.expect(node.swim.stateOf(victim.id) != null);

    // A SWIM frame routes to the membership layer.
    var buf: [frame.max_frame_len]u8 = undefined;
    const ping = try swim_mod.encode(.{ .ping = .{ .nonce = 5, .events = &.{} } }, &buf);
    node.handleWire(victim.id, ping);
    try std.testing.expectEqual(@as(u64, 1), node.swim.stats.acks_sent);
    try std.testing.expectEqual(@as(u64, 1), node.stats.frames_sent);

    // A confirmed-dead member purges from the overlay passive view on
    // the next tick.
    hv.TestHooks.addPassive(&node.overlay, victim);
    try std.testing.expect(node.overlay.inPassive(victim.id) != null);
    _ = node.swim.apply(.{ .confirm = .{ .id = victim.id, .incarnation = 1 } }, 1);
    node.tick();
    try std.testing.expect(node.overlay.inPassive(victim.id) == null);
    try std.testing.expect(node.swim.stateOf(victim.id) == .dead);

    // A later session re-establishment is direct liveness evidence:
    // the member resurrects (the post-crash/spurious-confirm wedge
    // exit — without it the transport keeps tearing the session to the
    // "dead" member before any probe evidence can cross it).
    node.onSessionUp(victim.id);
    try std.testing.expect(node.swim.stateOf(victim.id) == .alive);
}
