//! The QUIC endpoint: qmesh's SessionManager over quic-zig.
//!
//! One endpoint per node owns the transport relationships:
//!
//! * a `quic.Server` (via `listen`) accepting inbound sessions,
//! * one `quic.Client` per outbound dial (via the `connect` effect),
//! * at most one session per peer pair (simultaneous dials resolve by
//!   deterministic tiebreak: the connection initiated by the lower
//!   PeerId wins),
//! * ingress dispatch: DATAGRAM frames and length-prefixed stream
//!   frames (`frame.stream`) demux by protocol byte to the HELLO
//!   handler or the mesh node.
//!
//! Identity is CERT-BOUND: the session PeerId is
//! `Connection.peerCertSpkiDigest()` — SHA-256 of the peer leaf
//! certificate's DER SubjectPublicKeyInfo, exactly the standard
//! `openssl x509 -pubkey | openssl pkey -pubin -outform DER | openssl
//! dgst -sha256` preimage, so provisioned PeerIds interoperate with
//! any standard tooling. With `client_ca_pem` set the digest is always
//! present once the handshake completes. The session HELLO (protocol
//! 0x00) remains, reduced to an ADDRESS hint: its descriptor id must
//! equal the cert digest (mismatch — an announced lie — severs the
//! session), and its address feeds the gossip descriptor table. A
//! session becomes overlay-visible once the validated HELLO arrives.
//!
//! Driving model: the embedder owns the event loop and calls
//! `service(now_us)` once per iteration (socket-driven in production,
//! `quic.testing.Loopback` in tests). New dials need `conn.advance()`
//! from the owning loop — Loopback.handshake does it; `runUdpClient`
//! would in production.
//!
//! Ownership/lifetime: `Endpoint` must be address-stable once created
//! (the node's transport holds a pointer). Everything heap-allocates
//! from the provided allocator and frees in `deinit`.

const std = @import("std");
const qmesh = @import("qmesh");
const quic = @import("quic");
const hello_mod = @import("hello.zig");
const transport_mod = @import("transport.zig");

const PeerId = qmesh.PeerId;
const PeerDesc = qmesh.PeerDesc;
const Addr = qmesh.Addr;
const frame = qmesh.frame;

pub const QuicTransport = transport_mod.QuicTransport;
pub const MeshNode = qmesh.node.Node(QuicTransport);

pub const alpn = "qmesh/1";
const alpn_protocols = [_][]const u8{alpn};

pub const Options = struct {
    self: PeerDesc,
    /// PEM chain + key this node presents (server and client roles).
    tls_cert_pem: []const u8,
    tls_key_pem: []const u8,
    /// Cluster CA: trust anchor for dials and the required-client-cert
    /// root on the server side.
    ca_pem: []const u8,
    /// SNI + verification name for dials. Every cluster cert must
    /// carry this SAN (the interim posture documented against README
    /// gap 2: quic-zig cannot yet verify-against-CA without a name
    /// check).
    dial_server_name: []const u8,
    overlay_cfg: qmesh.OverlayConfig = .{},
    swim_cfg: qmesh.swim.Config = .{},
    broadcast_cfg: qmesh.plumtree.Config = .{},
    /// Application delivery callbacks (see Node.Hooks).
    hooks: MeshNode.Hooks = .{},
    rng_seed: u64 = 0,
    now_us: u64 = 0,
};

pub const Stats = struct {
    dials: u64 = 0,
    accepts: u64 = 0,
    hellos_sent: u64 = 0,
    hellos_received: u64 = 0,
    datagrams_received: u64 = 0,
    stream_frames_received: u64 = 0,
    frames_unresolved: u64 = 0,
    sessions_closed: u64 = 0,
    tiebreaks_lost: u64 = 0,
    identity_mismatches: u64 = 0,
};

const SessState = enum { connecting, established, closed };

/// One peer relationship. Server-side sessions reference their slot by
/// id (the Server owns the connection); client-side sessions own their
/// `quic.Client`.
const Session = struct {
    state: SessState,
    conn: *quic.Connection,
    /// Resolved once the peer's HELLO arrives; null until then.
    peer: ?PeerId = null,
    /// The peer's announced self-description (kept for descOf).
    peer_desc: ?PeerDesc = null,
    /// Dial target (client-side only), for connect dedupe.
    target: ?PeerId = null,
    /// Client ownership + the dial address the embedder's packet loop
    /// routes outbound datagrams to.
    client: ?*quic.Client = null,
    dial_addr: quic.Address = .unspecified,
    slot_id: ?u64 = null,
    hello_sent: bool = false,
    /// Set once the owning loop advanced this dial's handshake flight
    /// (Loopback.handshake / a socket loop does this; see connectPeer).
    advanced: bool = false,
    /// Per-stream length-prefix decoders. Streams may interleave, so
    /// decoder state is per stream id, never per session.
    stream_rx: [max_rx_streams]StreamRx = undefined,
    stream_rx_len: usize = 0,
};

const max_rx_streams: usize = 16;

const StreamRx = struct {
    stream_id: u64,
    dec: frame.stream.Decoder,
};

pub const Endpoint = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    opts: Options,
    now_us: u64,

    node: MeshNode,
    transport: QuicTransport,

    server: ?*quic.Server = null,
    sessions: std.ArrayListUnmanaged(*Session) = .empty,
    by_peer: std.AutoHashMapUnmanaged(PeerId, *Session) = .empty,

    datagram_buf: [1500]u8 = undefined,
    dead_close_scratch: [16]*Session = undefined,
    stream_buf: [4096]u8 = undefined,
    frame_buf: [frame.max_frame_len]u8 = undefined,
    stream_msg_buf: [frame.stream.max_stream_message]u8 = undefined,

    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, opts: Options) !*Self {
        const e = try allocator.create(Self);
        errdefer allocator.destroy(e);
        e.* = .{
            .allocator = allocator,
            .opts = opts,
            .now_us = opts.now_us,
            .node = undefined,
            .transport = .{
                .endpoint = e,
                .prng = std.Random.DefaultPrng.init(opts.rng_seed),
            },
        };
        e.node = MeshNode.init(
            opts.self,
            .{ .overlay = opts.overlay_cfg, .swim = opts.swim_cfg, .broadcast = opts.broadcast_cfg },
            &e.transport,
            opts.hooks,
        );
        return e;
    }

    pub fn deinit(e: *Self) void {
        // Server first: its deinit fires will-close hooks back into
        // us while everything is still addressable.
        if (e.server) |srv| {
            srv.deinit();
            e.allocator.destroy(srv);
        }
        for (e.sessions.items) |s| e.destroySession(s);
        e.sessions.deinit(e.allocator);
        e.by_peer.deinit(e.allocator);
        e.allocator.destroy(e);
    }

    fn destroySession(e: *Self, s: *Session) void {
        if (s.client) |cli| {
            cli.deinit();
            e.allocator.destroy(cli);
        }
        e.allocator.destroy(s);
    }

    /// Start (or return) the accepting side. The will-close hook is
    /// the Server's sanctioned pre-destruction notification: it fires
    /// (from `reap`/`deinit`) while the slot is still valid, which is
    /// what lets us stop touching the connection before it is freed.
    pub fn listen(e: *Self) !*quic.Server {
        if (e.server) |srv| return srv;
        const srv = try e.allocator.create(quic.Server);
        errdefer e.allocator.destroy(srv);
        srv.* = try quic.Server.init(.{
            .allocator = e.allocator,
            .tls_cert_pem = e.opts.tls_cert_pem,
            .tls_key_pem = e.opts.tls_key_pem,
            .client_ca_pem = e.opts.ca_pem,
            .alpn_protocols = &alpn_protocols,
            .transport_params = meshTransportParams(),
            .max_concurrent_connections = 256,
            .on_connection_will_close = willCloseHook,
            .on_connection_will_close_user_data = e,
            .on_handshake_complete = handshakeCompleteHook,
            .on_handshake_complete_user_data = e,
        });
        e.server = srv;
        return srv;
    }

    fn willCloseHook(user_data: ?*anyopaque, slot: *quic.Server.Slot) void {
        const e: *Self = @ptrCast(@alignCast(user_data.?));
        for (e.sessions.items) |s| {
            if (s.slot_id == slot.slot_id) {
                e.closeSession(s, .remote_close);
                return;
            }
        }
    }

    /// Session discovery: fires exactly once per slot from inside
    /// `feed`, connection established and open. Binds the session to
    /// the CERT-DERIVED PeerId immediately (authenticated; with
    /// `client_ca_pem` the digest is always present here). Contract:
    /// endpoint-state mutation only — HELLO emission and any Server
    /// calls happen in the next service pass.
    fn handshakeCompleteHook(user_data: ?*anyopaque, slot: *quic.Server.Slot) void {
        const e: *Self = @ptrCast(@alignCast(user_data.?));
        const digest = slot.conn.peerCertSpkiDigest() orelse {
            // Unreachable with client_ca_pem set (required client
            // certs); treat as a protocol violation and ignore the
            // slot entirely.
            return;
        };
        e.registerAcceptedSession(.{ .bytes = digest }, slot);
    }

    fn registerAcceptedSession(e: *Self, peer: PeerId, slot: *quic.Server.Slot) void {
        // Simultaneous dials resolve by AUTHENTICATED id: the
        // connection initiated by the lower PeerId wins.
        if (e.by_peer.get(peer)) |existing| {
            if (existing != e.sessionForSlot(slot.slot_id)) {
                const mine_lower = orderIds(e.opts.self.id, peer) == .lt;
                // The incoming slot was PEER-initiated; we keep ours
                // (our dial) only when ours is the lower initiator.
                if (mine_lower) {
                    e.stats.tiebreaks_lost += 1;
                    return; // our outbound dial stays; ignore this slot
                }
            }
        }
        const s = e.allocator.create(Session) catch return;
        s.* = .{
            .state = .connecting,
            .conn = slot.conn,
            .peer = peer,
            .slot_id = slot.slot_id,
        };
        e.sessions.append(e.allocator, s) catch {
            e.allocator.destroy(s);
            return;
        };
        if (e.by_peer.get(peer) == null) {
            e.by_peer.put(e.allocator, peer, s) catch @panic("qmesh by_peer OOM");
        }
        e.stats.accepts += 1;
    }

    fn sessionForSlot(e: *Self, slot_id: u64) ?*Session {
        for (e.sessions.items) |s| {
            if (s.slot_id) |sid| {
                if (sid == slot_id) return s;
            }
        }
        return null;
    }

    /// Begin mesh membership through a bootstrap contact (thin sugar
    /// over `node.startJoin`).
    pub fn startJoin(e: *Self, contact: PeerDesc) void {
        e.node.startJoin(contact);
    }

    /// Broadcast a payload cluster-wide. Returns null when the payload
    /// exceeds the frame budget.
    pub fn publish(e: *Self, payload: []const u8) ?qmesh.plumtree.MsgId {
        return e.node.publish(payload);
    }

    // --- transport surface (called by QuicTransport / the node) ------

    pub fn sendDatagram(e: *Self, to: PeerId, bytes: []const u8) !void {
        const s = e.by_peer.get(to) orelse return error.NoSession;
        if (s.state != .established) return error.NoSession;
        try s.conn.sendDatagram(bytes);
    }

    pub fn sendReliable(e: *Self, to: PeerId, bytes: []const u8) !void {
        const s = e.by_peer.get(to) orelse return error.NoSession;
        if (s.state != .established) return error.NoSession;
        const msg = try frame.stream.encode(bytes, &e.stream_msg_buf);
        const stream = try s.conn.openNextUni();
        const n = try s.conn.streamWrite(stream.id, msg);
        // Frames are ≤ ~1.2 KiB against a 1 MiB initial uni window; a
        // short write means flow-control math changed — surface it
        // loudly rather than truncating silently.
        std.debug.assert(n == msg.len);
        try s.conn.streamFinish(stream.id);
    }

    /// Establish (or confirm) a session to `desc`. The owning loop is
    /// responsible for advancing the fresh connection's handshake
    /// (`conn.advance()`); Loopback.handshake / runUdpClient do.
    pub fn connectPeer(e: *Self, desc: PeerDesc) !void {
        if (desc.id.eql(e.opts.self.id)) return error.SelfConnect;
        if (e.by_peer.get(desc.id)) |_| return; // established
        for (e.sessions.items) |s| {
            if (s.target) |t| {
                if (t.eql(desc.id) and s.state == .connecting) return; // dial in flight
            }
        }

        const qaddr = toQuicAddr(desc.addr) orelse return error.NoRoute;

        const cli = try e.allocator.create(quic.Client);
        errdefer e.allocator.destroy(cli);
        cli.* = try quic.Client.connect(.{
            .allocator = e.allocator,
            .server_name = e.opts.dial_server_name,
            .alpn_protocols = &alpn_protocols,
            .transport_params = meshTransportParams(),
            .ca_pem = e.opts.ca_pem,
            .client_cert_pem = e.opts.tls_cert_pem,
            .client_key_pem = e.opts.tls_key_pem,
            // Mesh posture: the peer's identity is its CERTIFICATE (the
            // SPKI digest becomes the PeerId), never the dialed name —
            // gossip addresses are IPs, cert names are cluster ids.
            .identity_verification = .none,
        });
        e.stats.dials += 1;

        const s = try e.allocator.create(Session);
        errdefer e.allocator.destroy(s);
        s.* = .{
            .state = .connecting,
            .conn = cli.conn,
            .target = desc.id,
            .client = cli,
            .dial_addr = qaddr,
        };
        try e.sessions.append(e.allocator, s);
    }

    // --- the service loop ------------------------------------------------

    /// One iteration of mesh work over every connection. Call from the
    /// embedder's loop (or Loopback driver) with the current time.
    pub fn service(e: *Self, now_us: u64) !void {
        e.now_us = now_us;

        // Server-side sessions arrive via the on_handshake_complete
        // hook (cert-bound, fires inside `feed`); nothing to scan.
        for (e.sessions.items) |s| {
            try e.serviceSession(s);
        }

        // Protocol timers.
        if (e.node.nextDeadline()) |d| {
            if (d <= e.now_us) e.node.tick();
        }

        // SWIM-confirmed-dead peers lose their transport: close the
        // session (idempotent with the node's own demotion sweep).
        // Without this, a crashed peer's connection sits idle until
        // the QUIC idle timeout while the overlay has already
        // declared it dead.
        var it = e.by_peer.iterator();
        const dead_peers = &e.dead_close_scratch;
        var dead_len: usize = 0;
        while (it.next()) |entry| {
            if (e.node.swim.stateOf(entry.key_ptr.*) == .dead) {
                if (dead_len < dead_peers.len) {
                    dead_peers[dead_len] = entry.value_ptr.*;
                    dead_len += 1;
                }
            }
        }
        for (dead_peers[0..dead_len]) |s| {
            e.closeSession(s, .reset);
        }
    }

    /// Service one session. Closed sessions stay on their records (the
    /// embedder's loop may still be pumping the connection) but get no
    /// further I/O.
    fn serviceSession(e: *Self, s: *Session) !void {
        if (s.state == .closed) return;

        // Close detection (event and state forms). The will-close hook
        // covers server-side reaping without a close event.
        while (s.conn.pollEvent()) |ev| switch (ev) {
            .close => {
                e.closeSession(s, .transport_error);
                return;
            },
            else => {},
        };
        if (s.conn.isClosed()) {
            e.closeSession(s, .transport_error);
            return;
        }

        // Client-side sessions bind the cert digest at handshake
        // completion (the server side binds inside the hook).
        if (s.client != null and s.peer == null and s.conn.handshakeDone()) {
            const digest = s.conn.peerCertSpkiDigest() orelse {
                e.closeSession(s, .transport_error);
                return;
            };
            e.bindDialSession(.{ .bytes = digest }, s);
        }

        // HELLO (address hint) as soon as the handshake completes.
        if (!s.hello_sent and s.conn.handshakeDone()) {
            try e.sendHello(s);
        }

        // Ingress: datagrams then streams.
        while (s.conn.receiveDatagramInfo(&e.datagram_buf)) |dg| {
            e.stats.datagrams_received += 1;
            e.ingress(s, e.datagram_buf[0..dg.len]);
        }
        try e.serviceStreams(s);
    }

    /// Bind an outbound dial to the authenticated remote identity.
    /// Simultaneous dials between the same pair resolve by authenticated
    /// id: the connection initiated by the lower PeerId wins.
    fn bindDialSession(e: *Self, peer: PeerId, s: *Session) void {
        s.peer = peer;
        if (e.by_peer.get(peer)) |existing| {
            if (existing != s) {
                const mine_lower = orderIds(e.opts.self.id, peer) == .lt;
                if (mine_lower) {
                    // Our dial wins; the redundant one is dropped.
                    return;
                }
                // Their dial (already registered) wins; ours closes.
                e.stats.tiebreaks_lost += 1;
                e.dropSession(s);
            }
            return;
        }
        e.by_peer.put(e.allocator, peer, s) catch @panic("qmesh by_peer OOM");
    }

    fn sendHello(e: *Self, s: *Session) !void {
        const bytes = try hello_mod.encode(.{ .desc = e.opts.self }, &e.frame_buf);
        const msg = try frame.stream.encode(bytes, &e.stream_msg_buf);
        const stream = try s.conn.openNextUni();
        const n = try s.conn.streamWrite(stream.id, msg);
        std.debug.assert(n == msg.len);
        try s.conn.streamFinish(stream.id);
        s.hello_sent = true;
        e.stats.hellos_sent += 1;
    }

    fn serviceStreams(e: *Self, s: *Session) !void {
        var it = s.conn.streamIterator();
        while (it.next()) |entry| {
            const stream_id = entry.key_ptr.*;
            // Only peer-initiated streams carry inbound frames. Stream
            // id bit 0 encodes the initiator (RFC 9000 §2.1: client
            // ids are even, server ids odd); `streamInitiatedByLocal`
            // exists in Connection/streams.zig but is not thunked onto
            // `Connection` itself (noted in the README gap list).
            const local_is_client = s.conn.role == .client;
            const initiated_by_client = (stream_id & 1) == 0;
            if (initiated_by_client == local_is_client) continue;
            const rx = streamRxFor(s, stream_id) orelse continue;

            while (true) {
                const n = s.conn.streamRead(stream_id, &e.stream_buf) catch |err| switch (err) {
                    error.StreamNotFound => break,
                    else => return err,
                };
                if (n == 0) break;
                if (try rx.push(e.stream_buf[0..n])) |fr| {
                    e.stats.stream_frames_received += 1;
                    e.ingress(s, fr.bytes);
                }
            }
        }
    }

    fn streamRxFor(s: *Session, stream_id: u64) ?*frame.stream.Decoder {
        for (s.stream_rx[0..s.stream_rx_len]) |*rx| {
            if (rx.stream_id == stream_id) return &rx.dec;
        }
        if (s.stream_rx_len >= max_rx_streams) return null; // bounded; defensive drop
        s.stream_rx[s.stream_rx_len] = .{ .stream_id = stream_id, .dec = .{} };
        const dec = &s.stream_rx[s.stream_rx_len].dec;
        s.stream_rx_len += 1;
        return dec;
    }

    /// Route one whole frame by protocol byte: HELLO is transport-
    /// local; everything else goes to the node driver, which demuxes
    /// overlay / swim / broadcast and counts unknown protocols.
    fn ingress(e: *Self, s: *Session, bytes: []const u8) void {
        const h = frame.decodeHeader(bytes) catch {
            e.stats.frames_unresolved += 1;
            return;
        };
        if (h.header.protocol == hello_mod.proto_id) {
            e.handleHello(s, bytes);
            return;
        }
        const peer = s.peer orelse {
            // Protocol traffic before identity resolution.
            e.stats.frames_unresolved += 1;
            return;
        };
        e.node.handleWire(peer, bytes);
    }

    /// The HELLO is an ADDRESS hint, not an identity claim: identity
    /// is the cert digest bound at handshake completion. The announced
    /// descriptor id must match the digest (a mismatch is a lie — or a
    /// version skew — and severs the session). On validation the
    /// session becomes overlay-visible.
    fn handleHello(e: *Self, s: *Session, bytes: []const u8) void {
        const msg = hello_mod.decode(bytes) catch {
            e.stats.frames_unresolved += 1;
            return;
        };
        e.stats.hellos_received += 1;

        const peer = s.peer orelse {
            // HELLO before the digest was bound (should not happen —
            // HELLOs flow only after handshake completion).
            e.stats.frames_unresolved += 1;
            return;
        };
        if (!msg.desc.id.eql(peer)) {
            // Announced id ≠ authenticated identity.
            e.stats.identity_mismatches += 1;
            e.dropSession(s);
            return;
        }
        if (peer.eql(e.opts.self.id)) {
            e.dropSession(s);
            return;
        }

        if (s.state == .connecting) {
            s.peer_desc = msg.desc;
            s.state = .established;
            if (e.by_peer.get(peer) == null) {
                e.by_peer.put(e.allocator, peer, s) catch @panic("qmesh by_peer OOM");
            }
            e.node.onSessionUp(peer);
        }
    }

    /// Mark a session finished: unmap it, tell the node (once), and
    /// stop all I/O on it. The record — and any client we own — stays
    /// allocated until `deinit`: the embedder's loop may still pump
    /// the connection (Loopback does; a socket loop drains it), so
    /// freeing here would pull memory out from under the pump.
    fn closeSession(e: *Self, s: *Session, reason: qmesh.session.SessionLostReason) void {
        if (s.state == .closed) return;
        s.state = .closed;
        if (s.peer) |peer| {
            if (e.by_peer.get(peer)) |cur| {
                if (cur == s) _ = e.by_peer.remove(peer);
            }
            e.node.onSessionDown(peer);
        }
        _ = reason;
        e.stats.sessions_closed += 1;
    }

    /// Tiebreak loser / self-dial: close the transport we own and mark
    /// finished without an overlay notification (the overlay never saw
    /// this session — its peer identity never resolved).
    fn dropSession(e: *Self, s: *Session) void {
        if (s.client) |cli| {
            if (!cli.conn.isClosed()) cli.conn.close(true, 0, "qmesh dedupe");
        }
        e.closeSession(s, .local_close);
    }

    // --- queries ----------------------------------------------------------

    pub fn sessionCount(e: *const Self) usize {
        return e.sessions.items.len;
    }

    pub fn establishedWith(e: *const Self, peer: PeerId) bool {
        const s = e.by_peer.get(peer) orelse return false;
        return s.state == .established;
    }

    /// Best-known descriptor for a connected peer (HELLO-announced).
    pub fn descOf(e: *const Self, peer: PeerId) ?PeerDesc {
        const s = e.by_peer.get(peer) orelse return null;
        return s.peer_desc;
    }
};

pub fn meshTransportParams() quic.Connection.TransportParams {
    var p = quic.Server.Config.defaultTransportParams();
    p.max_datagram_frame_size = 1400;
    return p;
}

fn toQuicAddr(a: Addr) ?quic.Address {
    return switch (a) {
        .none => null,
        .v4 => |v4| .{ .ipv4 = .{ .addr = v4.octets, .port = v4.port } },
        .v6 => |v6| .{ .ipv6 = .{ .addr = v6.octets, .port = v6.port } },
    };
}

fn orderIds(a: PeerId, b: PeerId) std.math.Order {
    return std.mem.order(u8, &a.bytes, &b.bytes);
}
