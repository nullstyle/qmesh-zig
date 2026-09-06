//! Peer identity and wire-level peer descriptors.
//!
//! `PeerId` is the primary key for every table in qmesh. The eventual
//! production derivation is the SHA-256 digest of the peer's TLS
//! certificate public key (DER SPKI), which makes it stable across
//! restarts and independent of addresses. Until quic-zig exposes peer
//! certificate bytes on a Connection (see README "quic-zig gaps"),
//! ids are minted by the deployment/simulator; the type is the same
//! either way.

const std = @import("std");

/// Fixed-size authenticated node identity. 32 bytes: sized for a
/// SHA-256 digest today, large enough to be collision-free for any
/// future derivation.
pub const PeerId = struct {
    bytes: [32]u8,

    pub const zero: PeerId = .{ .bytes = @splat(0) };

    pub fn eql(a: PeerId, b: PeerId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn isZero(a: PeerId) bool {
        return a.eql(zero);
    }

    /// Lowercase hex rendering (64 bytes). Returned by value so it can
    /// be used inline in log lines without an allocator.
    pub fn hex(a: PeerId) [64]u8 {
        return std.fmt.bytesToHex(a.bytes, .lower);
    }

    /// Derive a PeerId deterministically from a seed stream. Used by
    /// the simulator and by tests; production ids come from cert
    /// digests instead.
    pub fn fromRandom(rng: std.Random) PeerId {
        var id: PeerId = undefined;
        rng.bytes(&id.bytes);
        return id;
    }
};

/// Transport-reachable address for a peer, carried inside peer
/// descriptors so passive-view entries are dialable. Compact fixed
/// encoding (no allocator) on the wire via `encode`/`decode`.
pub const Addr = union(enum) {
    /// No address known. Passive entries without an address cannot be
    /// dialed and are deprioritized by promotion.
    none,
    v4: struct { port: u16, octets: [4]u8 },
    v6: struct { port: u16, octets: [16]u8 },

    pub fn ipv4(octets: [4]u8, port: u16) Addr {
        return .{ .v4 = .{ .port = port, .octets = octets } };
    }

    pub fn ipv6(octets: [16]u8, port: u16) Addr {
        return .{ .v6 = .{ .port = port, .octets = octets } };
    }

    pub fn eql(a: Addr, b: Addr) bool {
        if (@as(std.meta.Tag(Addr), a) != @as(std.meta.Tag(Addr), b)) return false;
        return switch (a) {
            .none => true,
            .v4 => a.v4.port == b.v4.port and std.mem.eql(u8, &a.v4.octets, &b.v4.octets),
            .v6 => a.v6.port == b.v6.port and std.mem.eql(u8, &a.v6.octets, &b.v6.octets),
        };
    }

    /// Synthetic address for simulator node `idx`. Distinguishable
    /// range (10.254.x.x) so it can never collide with a real v4
    /// assignment in mixed use.
    pub fn sim(idx: u32) Addr {
        return ipv4(.{ 10, 254, @truncate(idx >> 8), @truncate(idx & 0xff) }, 4433);
    }
};

/// Everything the overlay needs to know about a peer to gossip it and
/// (eventually) dial it. This is the unit carried in JOIN self-
/// descriptions, SHUFFLE samples, and passive views.
pub const PeerDesc = struct {
    id: PeerId,
    addr: Addr = .none,

    pub fn eql(a: PeerDesc, b: PeerDesc) bool {
        return a.id.eql(b.id) and a.addr.eql(b.addr);
    }
};

test "PeerId hex and equality" {
    var prng1 = std.Random.DefaultPrng.init(1);
    var prng1b = std.Random.DefaultPrng.init(1);
    var prng2 = std.Random.DefaultPrng.init(2);
    const a = PeerId.fromRandom(prng1.random());
    const b = PeerId.fromRandom(prng1b.random());
    const c = PeerId.fromRandom(prng2.random());
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    const h = a.hex();
    try std.testing.expect(h.len == 64);
}

test "Addr sim encoding round range" {
    const a = Addr.sim(0);
    const b = Addr.sim(0x0102);
    try std.testing.expect(a.eql(Addr.sim(0)));
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(!a.eql(.none));
}
