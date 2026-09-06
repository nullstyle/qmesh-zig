//! qmesh wire framing.
//!
//! Every qmesh message — on a QUIC DATAGRAM or inside a stream — is one
//! frame:
//!
//! ```text
//! u8  version    (currently 1)
//! u8  protocol   (0x01 = overlay/hyParView; SWIM, dissemination later)
//! u8  msg type   (protocol-local; 0 is always invalid)
//! ..  body       (protocol-local codec; all integers little-endian)
//! ```
//!
//! Frames are bounded by `max_frame_len` so one frame always fits a QUIC
//! DATAGRAM payload at the 1200-byte QUIC minimum MTU (with headroom for
//! the DATAGRAM frame tag + length varint).
//!
//! Reliable transfer maps frames onto QUIC streams with a u16 length
//! prefix (`stream.encode` / `stream.Decoder`): a stream is a sequence
//! of whole frames, so message-granular senders keep message-granular
//! receivers across the datagram/stream split.

const std = @import("std");
const peer_mod = @import("peer.zig");

pub const version: u8 = 1;

/// Hard frame budget. Protocol codecs may assert tighter bounds; nothing
/// may exceed this.
pub const max_frame_len: usize = 1152;

pub const Protocol = struct {
    pub const overlay: u8 = 0x01;
    pub const membership: u8 = 0x02; // SWIM + Lifeguard (future)
    pub const dissemination: u8 = 0x03; // Plumtree (future)
    pub const anti_entropy: u8 = 0x04; // reconciliation (future)
};

/// Writer-side failures: the destination buffer is too small. Encode
/// paths can fail no other way.
pub const EncodeError = error{NoRoomLeft};

/// Reader-side failures: input too short, or a frame version this
/// build does not speak.
pub const DecodeError = error{ Truncated, UnknownVersion };

/// Bounded cursor writer. All multi-byte integers little-endian.
pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn written(w: *const Writer) []const u8 {
        return w.buf[0..w.pos];
    }

    pub fn putU8(w: *Writer, v: u8) EncodeError!void {
        if (w.pos + 1 > w.buf.len) return error.NoRoomLeft;
        w.buf[w.pos] = v;
        w.pos += 1;
    }

    pub fn putU16(w: *Writer, v: u16) EncodeError!void {
        if (w.pos + 2 > w.buf.len) return error.NoRoomLeft;
        std.mem.writeInt(u16, w.buf[w.pos..][0..2], v, .little);
        w.pos += 2;
    }

    pub fn putU32(w: *Writer, v: u32) EncodeError!void {
        if (w.pos + 4 > w.buf.len) return error.NoRoomLeft;
        std.mem.writeInt(u32, w.buf[w.pos..][0..4], v, .little);
        w.pos += 4;
    }

    pub fn putU64(w: *Writer, v: u64) EncodeError!void {
        if (w.pos + 8 > w.buf.len) return error.NoRoomLeft;
        std.mem.writeInt(u64, w.buf[w.pos..][0..8], v, .little);
        w.pos += 8;
    }

    pub fn putBytes(w: *Writer, bytes: []const u8) EncodeError!void {
        if (w.pos + bytes.len > w.buf.len) return error.NoRoomLeft;
        @memcpy(w.buf[w.pos..][0..bytes.len], bytes);
        w.pos += bytes.len;
    }
};

/// Bounded cursor reader. Every read past the end is
/// `Error.Truncated` — never a panic, never garbage.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn remaining(r: *const Reader) usize {
        return r.buf.len - r.pos;
    }

    pub fn readU8(r: *Reader) error{Truncated}!u8 {
        if (r.remaining() < 1) return error.Truncated;
        const v = r.buf[r.pos];
        r.pos += 1;
        return v;
    }

    pub fn readU16(r: *Reader) error{Truncated}!u16 {
        if (r.remaining() < 2) return error.Truncated;
        const v = std.mem.readInt(u16, r.buf[r.pos..][0..2], .little);
        r.pos += 2;
        return v;
    }

    pub fn readU32(r: *Reader) error{Truncated}!u32 {
        if (r.remaining() < 4) return error.Truncated;
        const v = std.mem.readInt(u32, r.buf[r.pos..][0..4], .little);
        r.pos += 4;
        return v;
    }

    pub fn readU64(r: *Reader) error{Truncated}!u64 {
        if (r.remaining() < 8) return error.Truncated;
        const v = std.mem.readInt(u64, r.buf[r.pos..][0..8], .little);
        r.pos += 8;
        return v;
    }

    pub fn bytes(r: *Reader, n: usize) error{Truncated}![]const u8 {
        if (r.remaining() < n) return error.Truncated;
        const out = r.buf[r.pos..][0..n];
        r.pos += n;
        return out;
    }

    /// Rest of the input. Used by codecs where the body runs to the
    /// end of the frame.
    pub fn rest(r: *Reader) []const u8 {
        const out = r.buf[r.pos..];
        r.pos = r.buf.len;
        return out;
    }
};

pub const Header = struct {
    version: u8,
    protocol: u8,
    msg_type: u8,
};

pub fn encodeHeader(w: *Writer, protocol: u8, msg_type: u8) EncodeError!void {
    try w.putU8(version);
    try w.putU8(protocol);
    try w.putU8(msg_type);
}

/// Decode a frame header and return the body slice. `UnknownVersion`
/// for anything but the current version; the protocol byte is returned
/// as-is so callers can route to the right codec (and count unknown
/// protocols rather than tear down).
pub fn decodeHeader(buf: []const u8) DecodeError!struct { header: Header, body: []const u8 } {
    var r = Reader.init(buf);
    const ver = try r.readU8();
    if (ver != version) return error.UnknownVersion;
    const proto = try r.readU8();
    const mtype = try r.readU8();
    return .{ .header = .{ .version = ver, .protocol = proto, .msg_type = mtype }, .body = r.rest() };
}

// --- descriptor codec (shared by every protocol that gossips peers) ---

pub const AddrCodec = struct {
    pub fn encode(addr: peer_mod.Addr, w: *Writer) EncodeError!void {
        switch (addr) {
            .none => try w.putU8(0),
            .v4 => |v4| {
                try w.putU8(1);
                try w.putU16(v4.port);
                try w.putBytes(&v4.octets);
            },
            .v6 => |v6| {
                try w.putU8(2);
                try w.putU16(v6.port);
                try w.putBytes(&v6.octets);
            },
        }
    }

    pub fn decode(r: *Reader) error{Truncated}!peer_mod.Addr {
        const tag = try r.readU8();
        return switch (tag) {
            0 => .none,
            1 => blk: {
                const port = try r.readU16();
                const oct = try r.bytes(4);
                var out: [4]u8 = undefined;
                @memcpy(&out, oct);
                break :blk peer_mod.Addr.ipv4(out, port);
            },
            2 => blk: {
                const port = try r.readU16();
                const oct = try r.bytes(16);
                var out: [16]u8 = undefined;
                @memcpy(&out, oct);
                break :blk peer_mod.Addr.ipv6(out, port);
            },
            else => error.Truncated, // invalid tag: treat as malformed
        };
    }
};

pub const DescCodec = struct {
    pub fn encode(desc: peer_mod.PeerDesc, w: *Writer) EncodeError!void {
        try w.putBytes(&desc.id.bytes);
        try AddrCodec.encode(desc.addr, w);
    }

    pub fn decode(r: *Reader) error{Truncated}!peer_mod.PeerDesc {
        const id_bytes = try r.bytes(32);
        var id: peer_mod.PeerId = undefined;
        @memcpy(&id.bytes, id_bytes);
        const addr = try AddrCodec.decode(r);
        return .{ .id = id, .addr = addr };
    }
};

/// Length-prefixed stream framing for reliable transfer. One stream
/// message = `u16le length || frame`. The simulator treats reliable
/// sends atomically (it never splits or reorders them), so this codec
/// is exercised directly by unit tests and pinned for the QUIC adapter
/// that will push the same bytes through real streams.
pub const stream = struct {
    pub const prefix_len: usize = 2;
    pub const max_stream_message: usize = prefix_len + max_frame_len;

    pub fn encode(frame_bytes: []const u8, buf: []u8) EncodeError![]const u8 {
        if (frame_bytes.len > max_frame_len) return error.NoRoomLeft;
        if (buf.len < prefix_len + frame_bytes.len) return error.NoRoomLeft;
        std.mem.writeInt(u16, buf[0..2], @intCast(frame_bytes.len), .little);
        @memcpy(buf[2..][0..frame_bytes.len], frame_bytes);
        return buf[0 .. prefix_len + frame_bytes.len];
    }

    /// Incremental decoder over a byte stream. Feed chunks; whole
    /// frames pop out.
    pub const Decoder = struct {
        buf: [max_stream_message]u8 = undefined,
        len: usize = 0,
        expect: ?usize = null,

        pub const Frame = struct { bytes: []const u8 };

        /// Push one chunk, returning a whole frame once one is complete.
        /// `Error.NoRoomLeft` means the peer violated the frame budget —
        /// the connection should be dropped, not resized.
        pub fn push(d: *Decoder, chunk: []const u8) error{ NoRoomLeft, Truncated }!?Frame {
            var in = chunk;
            while (in.len > 0) {
                if (d.expect) |want| {
                    const take = @min(in.len, want - d.len);
                    @memcpy(d.buf[d.len..][0..take], in[0..take]);
                    d.len += take;
                    in = in[take..];
                    if (d.len == want) {
                        d.expect = null;
                        return Frame{ .bytes = d.buf[prefix_len..d.len] };
                    }
                    continue;
                }
                // collecting length prefix
                const take = @min(in.len, prefix_len - d.len);
                @memcpy(d.buf[d.len..][0..take], in[0..take]);
                d.len += take;
                in = in[take..];
                if (d.len == prefix_len) {
                    const n = std.mem.readInt(u16, d.buf[0..2], .little);
                    if (n == 0) return error.Truncated; // zero-length frame is invalid
                    const want = prefix_len + @as(usize, n);
                    if (want > d.buf.len) return error.NoRoomLeft; // frame budget violation
                    d.expect = want;
                }
            }
            return null;
        }
    };
};

test "header round trip" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try encodeHeader(&w, Protocol.overlay, 7);
    try w.putU16(0xbeef);
    const enc = w.written();

    const dec = try decodeHeader(enc);
    try std.testing.expectEqual(version, dec.header.version);
    try std.testing.expectEqual(Protocol.overlay, dec.header.protocol);
    try std.testing.expectEqual(@as(u8, 7), dec.header.msg_type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xef, 0xbe }, dec.body);
}

test "header rejects truncation and wrong version" {
    try std.testing.expectError(error.Truncated, decodeHeader(&[_]u8{ 1, 1 }));
    try std.testing.expectError(error.UnknownVersion, decodeHeader(&[_]u8{ 2, 1, 1 }));
}

test "desc codec round trip" {
    var id: peer_mod.PeerId = undefined;
    id.bytes = @splat(0xab);
    const desc = peer_mod.PeerDesc{ .id = id, .addr = peer_mod.Addr.sim(0x0304) };

    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try DescCodec.encode(desc, &w);
    var r = Reader.init(w.written());
    const back = try DescCodec.decode(&r);
    try std.testing.expect(desc.eql(back));
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "desc codec rejects truncated body" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try DescCodec.encode(.{ .id = .zero, .addr = .none }, &w);
    const full = w.written().len;
    var r = Reader.init(w.written()[0 .. full - 1]);
    try std.testing.expectError(error.Truncated, DescCodec.decode(&r));
}

test "stream framing round trip with fragmentation" {
    const frame = [_]u8{ 1, Protocol.overlay, 3, 9, 9 };
    var msg_buf: [stream.max_stream_message]u8 = undefined;
    const msg = try stream.encode(&frame, &msg_buf);

    var dec: stream.Decoder = .{};
    // feed one byte at a time; the frame must pop out exactly once, whole
    var got: ?stream.Decoder.Frame = null;
    for (msg) |b| {
        if (try dec.push(&[_]u8{b})) |f| got = f;
    }
    try std.testing.expect(got != null);
    try std.testing.expectEqualSlices(u8, &frame, got.?.bytes);
    // and nothing more
    try std.testing.expectEqual(@as(?stream.Decoder.Frame, null), try dec.push(&.{}));
}

test "stream decoder rejects oversized frame" {
    // hand-encode an over-budget length rather than going through
    // stream.encode, which refuses it
    var prefix: [2]u8 = undefined;
    std.mem.writeInt(u16, &prefix, max_frame_len + 1, .little);
    var dec: stream.Decoder = .{};
    try std.testing.expectError(error.NoRoomLeft, dec.push(&prefix));
}
