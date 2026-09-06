//! Session HELLO — protocol 0x00, the first frame on every new qmesh
//! session.
//!
//! This is the documented PeerId workaround for quic-zig gap 1 (no
//! peer-certificate access; see README): until `Connection` exposes an
//! authenticated identity digest, each endpoint announces its
//! `PeerDesc` inside the mutually-authenticated TLS channel, and the
//! session manager resolves the connection's PeerId from the received
//! HELLO. Trust = the TLS handshake (both sides present cluster-CA
//! certificates); the announced id is *claimed* identity within that
//! channel — any cluster member can currently announce any id, which
//! is acceptable for a cooperative cluster and is exactly what the
//! quic-zig brief asks to fix.
//!
//! A qmesh session is not "up" (from the protocol cores' perspective)
//! until the peer's HELLO has been received and decoded.

const std = @import("std");
const qmesh = @import("qmesh");
const frame = qmesh.frame;

pub const proto_id: u8 = 0x00;

pub const msg_type = struct {
    pub const hello: u8 = 1;
};

pub const Msg = struct {
    desc: qmesh.PeerDesc,
};

pub const DecodeError = frame.DecodeError || error{ UnknownType, Malformed };

pub fn encode(msg: Msg, buf: []u8) frame.EncodeError![]const u8 {
    var w = frame.Writer.init(buf);
    try frame.encodeHeader(&w, proto_id, msg_type.hello);
    try frame.DescCodec.encode(msg.desc, &w);
    return w.written();
}

pub fn decode(bytes: []const u8) DecodeError!Msg {
    const h = try frame.decodeHeader(bytes);
    if (h.header.protocol != proto_id) return error.Malformed;
    if (h.header.msg_type != msg_type.hello) return error.UnknownType;
    var r = frame.Reader.init(h.body);
    return .{ .desc = try frame.DescCodec.decode(&r) };
}

test "hello round trip and rejection" {
    var buf: [frame.max_frame_len]u8 = undefined;
    const desc = qmesh.PeerDesc{ .id = .{ .bytes = @splat(7) }, .addr = qmesh.Addr.sim(9) };
    const enc = try encode(.{ .desc = desc }, &buf);
    const dec = try decode(enc);
    try std.testing.expect(dec.desc.eql(desc));

    // wrong protocol / unknown type / truncated
    try std.testing.expectError(error.Malformed, decode(&[_]u8{ frame.version, 0x01, 1 }));
    try std.testing.expectError(error.UnknownType, decode(&[_]u8{ frame.version, proto_id, 9 }));
    try std.testing.expectError(error.Truncated, decode(&[_]u8{ frame.version, proto_id, 1, 0x01 }));
}
