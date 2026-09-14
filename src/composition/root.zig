//! Demand-driven application sessions for qmesh members.
//!
//! Import `qmesh_messaging` separately from the mesh core. `Pool` owns
//! bounded connection demand and retry state; the caller owns scheduling,
//! membership, endpoint resolution, and the messaging Node. No gossip-port
//! convention or hidden loop is imposed. Call `service` after driving the
//! mesh and messaging runtimes, then `ensure` when application traffic needs
//! a peer. `lookup` reflects the last service pass, not a liveness promise.

const std = @import("std");
const qmesh = @import("qmesh");

pub const PeerId = qmesh.PeerId;
pub const PeerDesc = qmesh.PeerDesc;
pub const Addr = qmesh.Addr;
pub const SessionId = u64;

pub const SessionStatus = struct {
    state: enum { connecting, ready, closing },
    peer_cert_spki: ?[32]u8 = null,
};

pub const Resolver = struct {
    context: ?*anyopaque = null,
    /// Returned address names the application service, not the gossip port.
    resolve: *const fn (?*anyopaque, PeerDesc) anyerror!Addr,
};

pub const Options = struct {
    max_peers: usize = 64,
    retry_initial_us: u64 = 100_000,
    retry_max_us: u64 = 10_000_000,
    dial_timeout_us: u64 = 10_000_000,
    /// Zero disables idle eviction. `ensure` renews demand.
    idle_timeout_us: u64 = 60_000_000,
};

pub const Stats = struct {
    dials: u64 = 0,
    dial_failures: u64 = 0,
    identity_mismatches: u64 = 0,
    reused: u64 = 0,
    closed: u64 = 0,
    evicted: u64 = 0,
    endpoint_changes: u64 = 0,
    resolution_failures: u64 = 0,
};

/// Dialer provides dial(PeerId, Addr), status(SessionId), close(SessionId),
/// and findReady(PeerId). Sends are made through the caller's messaging
/// Node after `ensure` returns a ready SessionId. The dialer must enforce
/// the expected identity before admitting application traffic; the pool
/// independently checks it before exposing a mapping.
///
/// Mesh provides member(PeerId) returning a record with .desc and .state
/// (alive/suspect/dead). This point lookup never mistakes an incomplete
/// enumeration for removal. Existing sessions survive suspicion; new
/// sessions wait until the member is alive again.
pub fn Pool(comptime Dialer: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            peer: PeerId,
            endpoint: Addr = .none,
            session: ?SessionId = null,
            owned: bool = false,
            ready: bool = false,
            retry_at_us: u64 = 0,
            dial_started_us: u64 = 0,
            last_used_us: u64,
            backoff_us: u64 = 0,
        };

        allocator: std.mem.Allocator,
        options: Options,
        entries: []Entry,
        len: usize = 0,
        now_us: u64 = 0,
        stats: Stats = .{},

        pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
            if (options.max_peers == 0 or options.retry_initial_us == 0 or
                options.retry_max_us < options.retry_initial_us or options.dial_timeout_us == 0)
                return error.InvalidOptions;
            return .{ .allocator = allocator, .options = options, .entries = try allocator.alloc(Entry, options.max_peers) };
        }

        /// The pool closes only connections it dialed. Adopted incoming
        /// sessions remain owned by the messaging Node.
        pub fn deinit(self: *Self, dialer: *Dialer) void {
            for (self.entries[0..self.len]) |*entry| self.release(dialer, entry);
            self.allocator.free(self.entries);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn lookup(self: *const Self, peer: PeerId) ?SessionId {
            const i = self.indexOf(peer) orelse return null;
            const entry = self.entries[i];
            return if (entry.ready) entry.session else null;
        }

        /// Start or renew demand. Null means a bounded dial/retry is in
        /// flight. Errors describe admission (unknown/dead/suspect member,
        /// capacity, or a nonmonotonic clock), not a failed wire delivery.
        pub fn ensure(self: *Self, mesh: anytype, dialer: *Dialer, resolver: Resolver, peer: PeerId, now_us: u64) !?SessionId {
            try self.advanceClock(now_us);
            const member = mesh.member(peer) orelse {
                _ = self.forget(dialer, peer);
                return error.UnknownPeer;
            };
            if (member.state == .dead) {
                _ = self.forget(dialer, peer);
                return error.PeerDead;
            }
            const i = self.indexOf(peer) orelse blk: {
                if (member.state == .suspect) return error.PeerSuspected;
                if (self.len == self.entries.len) return error.PoolFull;
                const next = self.len;
                self.entries[next] = .{ .peer = peer, .last_used_us = now_us };
                self.len += 1;
                break :blk next;
            };
            const entry = &self.entries[i];
            entry.last_used_us = now_us;
            self.refresh(dialer, resolver, member, entry);
            return if (entry.ready) entry.session else null;
        }

        /// Refreshes demanded peers only; never creates an all-to-all
        /// application mesh. Failure/backoff for one peer cannot abort
        /// servicing other peers. It does not consume Node poll events.
        pub fn service(self: *Self, mesh: anytype, dialer: *Dialer, resolver: Resolver, now_us: u64) !void {
            try self.advanceClock(now_us);
            var i: usize = 0;
            while (i < self.len) {
                const entry = &self.entries[i];
                const member = mesh.member(entry.peer);
                const idle = self.options.idle_timeout_us != 0 and now_us - entry.last_used_us >= self.options.idle_timeout_us;
                if (member == null or member.?.state == .dead or idle) {
                    self.remove(dialer, i);
                    if (idle) self.stats.evicted += 1;
                    continue;
                }
                self.refresh(dialer, resolver, member.?, entry);
                i += 1;
            }
        }

        pub fn forget(self: *Self, dialer: *Dialer, peer: PeerId) bool {
            const i = self.indexOf(peer) orelse return false;
            self.remove(dialer, i);
            return true;
        }

        /// Next pool wakeup; combine with mesh and messaging deadlines.
        pub fn nextDeadline(self: *const Self) ?u64 {
            var best: ?u64 = null;
            for (self.entries[0..self.len]) |entry| {
                if (entry.session == null) earliest(&best, entry.retry_at_us);
                if (entry.session != null and !entry.ready) earliest(&best, entry.dial_started_us +| self.options.dial_timeout_us);
                if (self.options.idle_timeout_us != 0) earliest(&best, entry.last_used_us +| self.options.idle_timeout_us);
            }
            return best;
        }

        fn advanceClock(self: *Self, now_us: u64) !void {
            if (now_us < self.now_us) return error.ClockMovedBackwards;
            self.now_us = now_us;
        }

        fn refresh(self: *Self, dialer: *Dialer, resolver: Resolver, member: anytype, entry: *Entry) void {
            // A missing/temporarily unresolvable advertisement does not
            // invalidate an established authenticated session.
            const resolved = resolver.resolve(resolver.context, member.desc) catch .none;
            if (resolved != .none and !entry.endpoint.eql(resolved) and
                (member.state == .alive or entry.session == null))
            {
                if (entry.endpoint != .none) {
                    self.stats.endpoint_changes += 1;
                    self.release(dialer, entry);
                }
                entry.endpoint = resolved;
                entry.retry_at_us = self.now_us;
                entry.backoff_us = 0;
            }

            if (entry.session) |id| {
                if (dialer.status(id)) |status| {
                    if (status.state == .ready) {
                        if (status.peer_cert_spki) |digest| {
                            if (std.mem.eql(u8, &entry.peer.bytes, &digest)) {
                                entry.ready = true;
                                entry.backoff_us = 0;
                                return;
                            }
                        }
                        self.stats.identity_mismatches += 1;
                    } else if (status.state == .connecting and self.now_us - entry.dial_started_us < self.options.dial_timeout_us) {
                        return;
                    }
                }
                self.failed(dialer, entry);
            }

            if (member.state == .suspect) {
                entry.retry_at_us = self.now_us +| self.options.retry_initial_us;
                return;
            }
            if (self.now_us < entry.retry_at_us) return;
            if (dialer.findReady(entry.peer)) |id| {
                if (dialer.status(id)) |status| {
                    if (status.state == .ready and status.peer_cert_spki != null and
                        std.mem.eql(u8, &entry.peer.bytes, &status.peer_cert_spki.?))
                    {
                        entry.session = id;
                        entry.owned = false;
                        entry.ready = true;
                        self.stats.reused += 1;
                        return;
                    }
                }
            }
            if (resolved == .none) {
                self.stats.resolution_failures += 1;
                self.scheduleRetry(entry);
                return;
            }
            const id = dialer.dial(entry.peer, entry.endpoint) catch {
                self.stats.dial_failures += 1;
                self.scheduleRetry(entry);
                return;
            };
            entry.session = id;
            entry.owned = true;
            entry.ready = false;
            entry.dial_started_us = self.now_us;
            self.stats.dials += 1;
        }

        fn failed(self: *Self, dialer: *Dialer, entry: *Entry) void {
            self.release(dialer, entry);
            self.stats.dial_failures += 1;
            self.scheduleRetry(entry);
        }

        fn scheduleRetry(self: *Self, entry: *Entry) void {
            entry.backoff_us = if (entry.backoff_us == 0) self.options.retry_initial_us else @min(entry.backoff_us *| 2, self.options.retry_max_us);
            entry.retry_at_us = self.now_us +| entry.backoff_us;
        }

        fn release(self: *Self, dialer: *Dialer, entry: *Entry) void {
            if (entry.owned) if (entry.session) |id| {
                dialer.close(id);
                self.stats.closed += 1;
            };
            entry.session = null;
            entry.owned = false;
            entry.ready = false;
        }

        fn remove(self: *Self, dialer: *Dialer, i: usize) void {
            self.release(dialer, &self.entries[i]);
            self.len -= 1;
            self.entries[i] = self.entries[self.len];
        }

        fn indexOf(self: *const Self, peer: PeerId) ?usize {
            for (self.entries[0..self.len], 0..) |entry, i| if (entry.peer.eql(peer)) return i;
            return null;
        }
    };
}

fn earliest(best: *?u64, at: u64) void {
    if (best.* == null or at < best.*.?) best.* = at;
}

/// The concrete qmsg adapter is instantiated with `@import("qmsg")`.
/// This keeps qmsg optional without a second copy of its module/types.
pub fn QmsgDialer(comptime qmsg: type) type {
    return struct {
        node: *qmsg.Node,
        options: qmsg.node.QuicDialOptions,

        pub fn dial(self: *@This(), peer: PeerId, endpoint: Addr) !SessionId {
            var buf: [64]u8 = undefined;
            var options = self.options;
            options.expected_peer_spki = peer.bytes;
            return self.node.dialQuic(try formatEndpoint(endpoint, &buf), options);
        }

        pub fn status(self: *@This(), id: SessionId) ?SessionStatus {
            const result = self.node.sessionStatus(id) orelse return null;
            return .{ .state = switch (result.state) {
                .connecting => .connecting,
                .ready => .ready,
                .closing => .closing,
            }, .peer_cert_spki = result.peer_cert_spki };
        }

        pub fn findReady(self: *@This(), peer: PeerId) ?SessionId {
            return self.node.findReadySessionSupporting(peer.bytes, self.options.transport.required_peer_patterns);
        }

        pub fn close(self: *@This(), id: SessionId) void {
            self.node.closeQuicSession(id) catch {};
        }
    };
}

pub fn formatEndpoint(addr: Addr, out: []u8) ![]const u8 {
    return switch (addr) {
        .none => error.NoAddress,
        .v4 => |v4| std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}:{d}", .{ v4.octets[0], v4.octets[1], v4.octets[2], v4.octets[3], v4.port }),
        .v6 => |v6| blk: {
            var w = std.Io.Writer.fixed(out);
            try w.writeByte('[');
            var i: usize = 0;
            while (i < 16) : (i += 2) {
                if (i != 0) try w.writeByte(':');
                try w.print("{x}", .{(@as(u16, v6.octets[i]) << 8) | v6.octets[i + 1]});
            }
            try w.print("]:{d}", .{v6.port});
            break :blk w.buffered();
        },
    };
}

test {
    _ = @import("pool_test.zig");
}
