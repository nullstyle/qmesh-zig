//! Option A: qmesh names and watches peers; qmsg carries the traffic.
//!
//! The two libraries stay independent. qmesh runs its own Endpoint on
//! its own UDP port and answers "who is in the cluster, are they
//! alive, and where are they". qmsg runs its own Node on its own port
//! and answers "send this message to that peer". Nothing is shared
//! between them except an IDENTITY, and that identity is not invented
//! here: both derive it from the same TLS certificate.
//!
//!   qmesh  PeerId            = Connection.peerCertSpkiDigest()
//!   qmsg   Session.peer_cert_spki = Connection.peerCertSpkiDigest()
//!
//! so `PeerId.hex()` and `Session.certPeerIdHex()` are the same 64
//! characters for the same peer. That is the whole reason this glue
//! is 150 lines instead of a naming layer.
//!
//! What lives here is the embedder's directory: a map from cluster
//! identity to qmsg session, reconciled against the mesh's membership.
//!
//! ```text
//!   qmesh Node.aliveMembers()  ->  reconcile()  ->  qmsg Node.dialQuic()
//!                                       |
//!                                  lookup(PeerId) -> SessionId
//! ```
//!
//! Deliberately NOT here: any shared socket, any shared quic
//! Connection, any qmsg traffic riding a qmesh session. Those are the
//! coupled designs; this is the uncoupled one. Two connections per
//! peer is the price, and it buys qmsg's full wire (1 MiB messages,
//! reliable streams, cancellation) instead of qmesh's 1152-byte
//! single-frame gossip envelope.

const std = @import("std");
const qmesh = @import("qmesh");

pub const PeerId = qmesh.PeerId;
pub const PeerDesc = qmesh.PeerDesc;
pub const Addr = qmesh.Addr;

/// qmsg's `Node.dialQuic` returns this. Kept concrete (rather than
/// inferred from the Dialer) so this module does not need to import
/// qmsg at all — the mesh side stays free of the messaging side.
pub const SessionId = u64;

pub const Options = struct {
    /// qmsg listens on the mesh port plus this offset.
    ///
    /// A qmesh `PeerDesc` carries exactly ONE address (`peer.zig`), so
    /// a second protocol on the same host has to derive its port
    /// rather than learn it. An offset is the simplest convention that
    /// works; every node in the cluster must agree on it.
    qmsg_port_offset: u16 = 1,
};

pub const Error = error{
    /// The peer's address plus the offset overflows a u16 port.
    PortOutOfRange,
    /// The member has no address yet (`Addr.none`): alive, but not
    /// dialable. Callers skip these and retry on a later reconcile.
    NoAddress,
};

/// Longest text `qmsgEndpoint` can produce: a bracketed IPv6 literal
/// plus ":65535".
pub const max_endpoint_len = "[".len + 39 + "]".len + 1 + 5;

/// Render the qmsg endpoint text for a mesh peer's address.
pub fn qmsgEndpoint(addr: Addr, offset: u16, out: []u8) Error![]const u8 {
    switch (addr) {
        .none => return Error.NoAddress,
        .v4 => |v4| {
            const port = std.math.add(u16, v4.port, offset) catch return Error.PortOutOfRange;
            return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}:{d}", .{
                v4.octets[0], v4.octets[1], v4.octets[2], v4.octets[3], port,
            }) catch return Error.PortOutOfRange;
        },
        .v6 => |v6| {
            const port = std.math.add(u16, v6.port, offset) catch return Error.PortOutOfRange;
            // Full eight-group form, no "::" compression. Longer than
            // the canonical rendering but unambiguous, and it parses
            // everywhere — this text goes straight to qmsg's
            // `dialQuic`, not to a human.
            var stream = std.Io.Writer.fixed(out);
            stream.writeByte('[') catch return Error.PortOutOfRange;
            var i: usize = 0;
            while (i < 16) : (i += 2) {
                if (i != 0) stream.writeByte(':') catch return Error.PortOutOfRange;
                const group = (@as(u16, v6.octets[i]) << 8) | v6.octets[i + 1];
                stream.print("{x}", .{group}) catch return Error.PortOutOfRange;
            }
            stream.print("]:{d}", .{port}) catch return Error.PortOutOfRange;
            return stream.buffered();
        },
    }
}

/// `Dialer` must provide, matching qmsg's `Node`:
///
/// ```zig
/// fn dial(d: *Dialer, endpoint: []const u8) !SessionId
/// fn close(d: *Dialer, id: SessionId) void
/// ```
///
/// The real implementation forwards to `Node.dialQuic` and
/// `Node.closeQuicSession`; see `wiring` at the bottom of this file.
pub fn Directory(comptime Dialer: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            session: SessionId,
            addr: Addr,
        };

        pub const Stats = struct {
            dialed: u64 = 0,
            closed: u64 = 0,
            dial_failures: u64 = 0,
            skipped_no_address: u64 = 0,
            /// Members that did not fit the caller's scratch buffer on
            /// some reconcile. Non-zero means the directory is
            /// incomplete — enlarge the scratch.
            truncated: u64 = 0,
        };

        entries: std.AutoHashMapUnmanaged([32]u8, Entry) = .empty,
        options: Options = .{},
        stats: Stats = .{},

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
            self.* = undefined;
        }

        /// The qmsg session for a cluster member, or null if the
        /// member is unknown, addressless, or its dial has not landed.
        pub fn lookup(self: *const Self, id: PeerId) ?SessionId {
            const entry = self.entries.get(id.bytes) orelse return null;
            return entry.session;
        }

        pub fn count(self: *const Self) usize {
            return self.entries.count();
        }

        /// Bring the directory in line with the mesh's membership:
        /// dial alive members that have no session, close sessions for
        /// members that are gone.
        ///
        /// `scratch` bounds how many members one pass can consider; a
        /// short buffer is counted in `stats.truncated`, never a silent
        /// partial result. A dial that fails is counted and retried on
        /// the next pass — a peer that is up but not yet accepting is
        /// the normal case during a rolling restart, not an error.
        pub fn reconcile(
            self: *Self,
            allocator: std.mem.Allocator,
            mesh: anytype,
            dialer: *Dialer,
            scratch: []PeerDesc,
        ) !void {
            const n = mesh.aliveMembers(scratch);
            if (n == scratch.len) self.stats.truncated += 1;
            const alive = scratch[0..n];

            // Sweep: anything no longer alive loses its session.
            var doomed: std.ArrayListUnmanaged([32]u8) = .empty;
            defer doomed.deinit(allocator);
            var it = self.entries.iterator();
            while (it.next()) |kv| {
                const still_alive = for (alive) |desc| {
                    if (std.mem.eql(u8, &desc.id.bytes, kv.key_ptr)) break true;
                } else false;
                if (!still_alive) try doomed.append(allocator, kv.key_ptr.*);
            }
            for (doomed.items) |key| {
                const entry = self.entries.fetchRemove(key).?;
                dialer.close(entry.value.session);
                self.stats.closed += 1;
            }

            // Mark: alive members without a session get one.
            var buf: [max_endpoint_len]u8 = undefined;
            for (alive) |desc| {
                if (self.entries.contains(desc.id.bytes)) continue;
                const endpoint = qmsgEndpoint(desc.addr, self.options.qmsg_port_offset, &buf) catch |err| switch (err) {
                    Error.NoAddress => {
                        self.stats.skipped_no_address += 1;
                        continue;
                    },
                    else => return err,
                };
                const session = dialer.dial(endpoint) catch {
                    self.stats.dial_failures += 1;
                    continue;
                };
                try self.entries.put(allocator, desc.id.bytes, .{
                    .session = session,
                    .addr = desc.addr,
                });
                self.stats.dialed += 1;
            }
        }
    };
}

// ---- tests --------------------------------------------------------

const FakeDialer = struct {
    next: SessionId = 1,
    fail_next: bool = false,
    dialed: std.ArrayListUnmanaged([]u8) = .empty,
    closed: std.ArrayListUnmanaged(SessionId) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(d: *FakeDialer) void {
        for (d.dialed.items) |e| d.allocator.free(e);
        d.dialed.deinit(d.allocator);
        d.closed.deinit(d.allocator);
    }

    fn dial(d: *FakeDialer, endpoint: []const u8) !SessionId {
        if (d.fail_next) {
            d.fail_next = false;
            return error.ConnectionRefused;
        }
        try d.dialed.append(d.allocator, try d.allocator.dupe(u8, endpoint));
        defer d.next += 1;
        return d.next;
    }

    fn close(d: *FakeDialer, id: SessionId) void {
        d.closed.append(d.allocator, id) catch {};
    }
};

/// Stands in for a qmesh `Node`: `reconcile` only ever calls
/// `aliveMembers`.
const FakeMesh = struct {
    alive: []const PeerDesc,

    fn aliveMembers(m: *const FakeMesh, out: []PeerDesc) usize {
        const n = @min(out.len, m.alive.len);
        @memcpy(out[0..n], m.alive[0..n]);
        return n;
    }
};

fn peerAt(seed: u8, octet: u8, port: u16) PeerDesc {
    return .{ .id = .{ .bytes = @splat(seed) }, .addr = Addr.ipv4(.{ 10, 0, 0, octet }, port) };
}

test "qmsgEndpoint derives the messaging port from the mesh port" {
    var buf: [max_endpoint_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "10.0.0.7:4434",
        try qmsgEndpoint(Addr.ipv4(.{ 10, 0, 0, 7 }, 4433), 1, &buf),
    );
    // A different agreed offset.
    try std.testing.expectEqualStrings(
        "10.0.0.7:4533",
        try qmsgEndpoint(Addr.ipv4(.{ 10, 0, 0, 7 }, 4433), 100, &buf),
    );
    // IPv6 keeps the brackets so the port stays unambiguous.
    const v6_octets: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const v6 = try qmsgEndpoint(Addr.ipv6(v6_octets, 4433), 1, &buf);
    try std.testing.expect(v6[0] == '[');
    try std.testing.expect(std.mem.endsWith(u8, v6, "]:4434"));
    // An addressless member is alive but not dialable.
    try std.testing.expectError(Error.NoAddress, qmsgEndpoint(.none, 1, &buf));
    // The offset must not silently wrap into a different port.
    try std.testing.expectError(
        Error.PortOutOfRange,
        qmsgEndpoint(Addr.ipv4(.{ 10, 0, 0, 7 }, 65535), 1, &buf),
    );
}

test "the directory dials alive members and maps them by cluster identity" {
    const allocator = std.testing.allocator;
    var dialer = FakeDialer{ .allocator = allocator };
    defer dialer.deinit();

    const a = peerAt(0xaa, 1, 4433);
    const b = peerAt(0xbb, 2, 4433);
    var mesh = FakeMesh{ .alive = &.{ a, b } };

    var dir: Directory(FakeDialer) = .{};
    defer dir.deinit(allocator);

    var scratch: [8]PeerDesc = undefined;
    try dir.reconcile(allocator, &mesh, &dialer, &scratch);

    try std.testing.expectEqual(@as(usize, 2), dir.count());
    try std.testing.expectEqual(@as(u64, 2), dir.stats.dialed);
    // Looked up by the peer's CERTIFICATE identity, not an address.
    try std.testing.expect(dir.lookup(a.id) != null);
    try std.testing.expect(dir.lookup(b.id) != null);
    try std.testing.expect(dir.lookup(.{ .bytes = @splat(0xcc) }) == null);
    // Each dial went to the derived qmsg port.
    try std.testing.expectEqualStrings("10.0.0.1:4434", dialer.dialed.items[0]);

    // Reconciling again is idempotent: no re-dial, no churn.
    try dir.reconcile(allocator, &mesh, &dialer, &scratch);
    try std.testing.expectEqual(@as(u64, 2), dir.stats.dialed);
    try std.testing.expectEqual(@as(usize, 2), dialer.dialed.items.len);
}

test "a member that leaves the cluster loses its qmsg session" {
    const allocator = std.testing.allocator;
    var dialer = FakeDialer{ .allocator = allocator };
    defer dialer.deinit();

    const a = peerAt(0xaa, 1, 4433);
    const b = peerAt(0xbb, 2, 4433);
    var mesh = FakeMesh{ .alive = &.{ a, b } };

    var dir: Directory(FakeDialer) = .{};
    defer dir.deinit(allocator);
    var scratch: [8]PeerDesc = undefined;
    try dir.reconcile(allocator, &mesh, &dialer, &scratch);
    const b_session = dir.lookup(b.id).?;

    // SWIM confirms b dead; it drops out of aliveMembers.
    mesh.alive = &.{a};
    try dir.reconcile(allocator, &mesh, &dialer, &scratch);

    try std.testing.expectEqual(@as(usize, 1), dir.count());
    try std.testing.expect(dir.lookup(b.id) == null);
    try std.testing.expect(dir.lookup(a.id) != null);
    try std.testing.expectEqual(@as(u64, 1), dir.stats.closed);
    try std.testing.expectEqual(b_session, dialer.closed.items[0]);
}

test "a failed dial is retried, not remembered as a session" {
    const allocator = std.testing.allocator;
    var dialer = FakeDialer{ .allocator = allocator, .fail_next = true };
    defer dialer.deinit();

    const a = peerAt(0xaa, 1, 4433);
    var mesh = FakeMesh{ .alive = &.{a} };

    var dir: Directory(FakeDialer) = .{};
    defer dir.deinit(allocator);
    var scratch: [8]PeerDesc = undefined;

    // Peer is up but not yet accepting: counted, not mapped.
    try dir.reconcile(allocator, &mesh, &dialer, &scratch);
    try std.testing.expectEqual(@as(usize, 0), dir.count());
    try std.testing.expectEqual(@as(u64, 1), dir.stats.dial_failures);
    try std.testing.expect(dir.lookup(a.id) == null);

    // Next pass succeeds.
    try dir.reconcile(allocator, &mesh, &dialer, &scratch);
    try std.testing.expectEqual(@as(usize, 1), dir.count());
    try std.testing.expect(dir.lookup(a.id) != null);
}

test "an addressless member is skipped, not dialed" {
    const allocator = std.testing.allocator;
    var dialer = FakeDialer{ .allocator = allocator };
    defer dialer.deinit();

    const ghost = PeerDesc{ .id = .{ .bytes = @splat(0xdd) }, .addr = .none };
    var mesh = FakeMesh{ .alive = &.{ghost} };

    var dir: Directory(FakeDialer) = .{};
    defer dir.deinit(allocator);
    var scratch: [8]PeerDesc = undefined;
    try dir.reconcile(allocator, &mesh, &dialer, &scratch);

    try std.testing.expectEqual(@as(usize, 0), dir.count());
    try std.testing.expectEqual(@as(u64, 1), dir.stats.skipped_no_address);
    try std.testing.expectEqual(@as(usize, 0), dialer.dialed.items.len);
}

test "a short scratch buffer is reported, never a silent partial view" {
    const allocator = std.testing.allocator;
    var dialer = FakeDialer{ .allocator = allocator };
    defer dialer.deinit();

    const members = [_]PeerDesc{ peerAt(0xa1, 1, 4433), peerAt(0xa2, 2, 4433), peerAt(0xa3, 3, 4433) };
    var mesh = FakeMesh{ .alive = &members };

    var dir: Directory(FakeDialer) = .{};
    defer dir.deinit(allocator);
    var scratch: [2]PeerDesc = undefined;
    try dir.reconcile(allocator, &mesh, &dialer, &scratch);

    try std.testing.expectEqual(@as(usize, 2), dir.count());
    try std.testing.expectEqual(@as(u64, 1), dir.stats.truncated);
}
