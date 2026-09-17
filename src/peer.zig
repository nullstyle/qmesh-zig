//! Peer identity and wire-level peer descriptors.
//!
//! `PeerId` keys every membership table. Production QUIC adapters derive
//! it from SHA-256 of the peer leaf certificate's DER SubjectPublicKeyInfo.
//! It survives certificate renewal with the same key; key rotation creates
//! a new member. Simulation injects deterministic IDs. Addresses are
//! contact information, not identity or proof of liveness.

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

    pub const CertPemError = error{
        /// No `-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----`
        /// block, or the text between the markers is not base64.
        InvalidPem,
        /// The decoded bytes do not walk as a DER X.509 Certificate as
        /// far as its SubjectPublicKeyInfo.
        InvalidCertificate,
        OutOfMemory,
    };

    /// The PeerId a node presenting `cert_pem` resolves to: SHA-256 over
    /// the DER SubjectPublicKeyInfo of the first certificate in the PEM,
    /// the same bytes `quic.Connection.peerCertSpkiDigest()` gives the
    /// other end after the handshake and the `openssl x509 -pubkey |
    /// openssl pkey -pubin -outform DER | openssl dgst -sha256`
    /// fingerprint. Lets a node check its provisioned `--id` against its
    /// `--cert` before announcing it. Only the DER structure is walked;
    /// the pinned-CA handshake is what vouches for the key.
    pub fn fromCertPem(gpa: std.mem.Allocator, cert_pem: []const u8) CertPemError!PeerId {
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";
        const start = (std.mem.indexOf(u8, cert_pem, begin) orelse return error.InvalidPem) + begin.len;
        const finish = std.mem.indexOfPos(u8, cert_pem, start, end) orelse return error.InvalidPem;
        const body = cert_pem[start..finish];

        const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
        const der_buf = try gpa.alloc(u8, decoder.calcSizeUpperBound(body.len));
        defer gpa.free(der_buf);
        const der_len = decoder.decode(der_buf, body) catch return error.InvalidPem;
        const der = der_buf[0..der_len];

        // Certificate ::= SEQUENCE { tbsCertificate, ... };
        // TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
        // signature, issuer, validity, subject, subjectPublicKeyInfo, ... }
        // (RFC 5280 section 4.1). The digest covers the whole SPKI element,
        // tag and length included (what `i2d_X509_PUBKEY` emits).
        const certificate = try derElement(der, 0);
        const tbs = try derElement(der, certificate.start);
        const version_or_serial = try derElement(der, tbs.start);
        const serial = if (der[version_or_serial.tag_index] == 0xa0)
            try derElement(der, version_or_serial.end)
        else
            version_or_serial;
        const signature = try derElement(der, serial.end);
        const issuer = try derElement(der, signature.end);
        const validity = try derElement(der, issuer.end);
        const subject = try derElement(der, validity.end);
        const spki = try derElement(der, subject.end);
        if (spki.end > tbs.end) return error.InvalidCertificate;

        var id: PeerId = undefined;
        std.crypto.hash.sha2.Sha256.hash(der[subject.end..spki.end], &id.bytes, .{});
        return id;
    }

    const DerElement = struct { tag_index: u32, start: u32, end: u32 };

    /// One DER TLV header at `index`, bounds-checked: a truncated or
    /// garbage body is refused instead of read past `der`.
    fn derElement(der: []const u8, index: u32) CertPemError!DerElement {
        if (der.len > std.math.maxInt(u32)) return error.InvalidCertificate;
        const len: u32 = @intCast(der.len);
        if (index > len or len - index < 2) return error.InvalidCertificate;
        const size_byte = der[index + 1];
        var content_start: u32 = index + 2;
        var content_len: u32 = size_byte;
        if ((size_byte >> 7) != 0) {
            // Long form: the low bits count the length bytes that follow.
            const len_size: u32 = size_byte & 0x7f;
            if (len_size == 0 or len_size > @sizeOf(u32) or len - content_start < len_size) return error.InvalidCertificate;
            content_len = 0;
            for (der[content_start..][0..len_size]) |byte| content_len = (content_len << 8) | byte;
            content_start += len_size;
        }
        if (len - content_start < content_len) return error.InvalidCertificate;
        return .{ .tag_index = index, .start = content_start, .end = content_start + content_len };
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

    /// Project a std IP address (an mDNS `Resolved` address, a parsed
    /// literal) onto the fixed encoding. Null when the address cannot
    /// be dialed through this encoding: a link-local IPv6 (`fe80::/10`)
    /// needs the interface scope that `Addr` has no field for — and
    /// the socket loop's `sockaddr_in6` carries scope id 0 anyway, so
    /// even an unscoped `fe80::` literal is unroutable there. Global
    /// and ULA v6 and every v4 project unchanged. Port 0 is kept as
    /// is: the caller decides whether an undialable port is an error
    /// (`qmesh-node` rejects it for `--join`; mDNS adverts never carry
    /// one).
    pub fn fromIp(ip: std.Io.net.IpAddress) ?Addr {
        return switch (ip) {
            .ip4 => |v4| ipv4(v4.bytes, v4.port),
            .ip6 => |v6| if (v6.isLinkLocal()) null else ipv6(v6.bytes, v6.port),
        };
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

test "Addr.fromIp projects v4 and global v6, drops link-local v6" {
    const IpAddress = std.Io.net.IpAddress;
    const v4 = Addr.fromIp(.{ .ip4 = .{ .bytes = .{ 10, 0, 0, 5 }, .port = 4433 } }).?;
    try std.testing.expect(v4.eql(Addr.ipv4(.{ 10, 0, 0, 5 }, 4433)));

    const global6: [16]u8 = .{ 0x2a, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7 };
    const v6 = Addr.fromIp(.{ .ip6 = .{ .bytes = global6, .port = 4451 } }).?;
    try std.testing.expect(v6.eql(Addr.ipv6(global6, 4451)));

    // ULA (fd00::/8, the fly 6pn shape) is not link-local: kept.
    var ula: [16]u8 = @splat(0);
    ula[0] = 0xfd;
    ula[15] = 1;
    try std.testing.expect(Addr.fromIp(.{ .ip6 = .{ .bytes = ula, .port = 1 } }) != null);

    // Link-local is dropped whether or not the scope is set: Addr has
    // no field for it and the socket loop sends scope id 0.
    var ll: [16]u8 = @splat(0);
    ll[0] = 0xfe;
    ll[1] = 0x80;
    ll[15] = 1;
    try std.testing.expect(Addr.fromIp(.{ .ip6 = .{ .bytes = ll, .port = 4433, .interface = .{ .index = 12 } } }) == null);
    try std.testing.expect(Addr.fromIp(.{ .ip6 = .{ .bytes = ll, .port = 4433 } }) == null);
    // fe80::/10 covers febf::; fec0:: is outside it.
    ll[1] = 0xbf;
    try std.testing.expect(Addr.fromIp(.{ .ip6 = .{ .bytes = ll, .port = 4433 } }) == null);
    ll[1] = 0xc0;
    try std.testing.expect(Addr.fromIp(.{ .ip6 = .{ .bytes = ll, .port = 4433 } }) != null);

    // The parsed-literal path agrees with the hand-built values.
    const lit = try IpAddress.parseLiteral("[2a01::7]:4451");
    try std.testing.expect(Addr.fromIp(lit).?.eql(v6));
}

test "Addr sim encoding round range" {
    const a = Addr.sim(0);
    const b = Addr.sim(0x0102);
    try std.testing.expect(a.eql(Addr.sim(0)));
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(!a.eql(.none));
}
