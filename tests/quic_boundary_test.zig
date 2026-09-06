//! Pins the quic-zig API surface qmesh's QUIC session adapter (next
//! milestone) will build against.
//!
//! qmesh's core is transport-generic and never imports quic; this test
//! exists so that changes to quic-zig that would break the adapter
//! fail HERE, at qmesh build time, with a precise message — instead of
//! surfacing months later as cryptic type errors mid-implementation.
//! Each block names the qmesh feature that depends on it.

const std = @import("std");
const quic = @import("quic");

test "server config: mTLS posture the mesh requires" {
    // SessionManager: one quic.Server per node; membership is only as
    // trustworthy as mandatory client certificates.
    try std.testing.expect(@hasField(quic.Server.Config, "client_ca_pem"));
    try std.testing.expect(@hasField(quic.Server.Config, "tls_cert_pem"));
    try std.testing.expect(@hasField(quic.Server.Config, "tls_key_pem"));
    try std.testing.expect(@hasField(quic.Server.Config, "alpn_protocols"));
    try std.testing.expect(@hasField(quic.Server.Config, "transport_params"));
    try std.testing.expect(@hasField(quic.Server.Config, "max_concurrent_connections"));
}

test "client config: dialing peers by address with a pinned CA" {
    try std.testing.expect(@hasField(quic.Client.Config, "ca_pem"));
    try std.testing.expect(@hasField(quic.Client.Config, "client_cert_pem"));
    try std.testing.expect(@hasField(quic.Client.Config, "client_key_pem"));
    try std.testing.expect(@hasField(quic.Client.Config, "server_name"));
    try std.testing.expect(@hasField(quic.Client.Config, "transport_params"));
    // Resolved on quic-zig main (post-0.20.0): the private-CA dial
    // posture — chain validates against ca_pem, name check skipped.
    // .none requires ca_pem at connect time (InvalidConfig otherwise),
    // so the posture can never silently downgrade.
    try std.testing.expect(@hasField(quic.Client.Config, "identity_verification"));
}

test "peer identity: cert digest + handshake-complete discovery (resolved on quic-zig main)" {
    // PeerId = digest of the peer's authenticated key material.
    // SHA-256 over the leaf cert's DER SubjectPublicKeyInfo —
    // renewal-stable, both roles, works on resumed sessions.
    try std.testing.expect(@hasDecl(quic.Connection, "peerCertSpkiDigest"));
    // Session establishment without iterator-diffing: fires once per
    // slot from feed when the TLS handshake completes.
    try std.testing.expect(@hasField(quic.Server.Config, "on_handshake_complete"));
    try std.testing.expect(@hasField(quic.Server.Config, "on_handshake_complete_user_data"));
}

test "connection: datagram + stream + lifecycle surface" {
    try std.testing.expect(@hasDecl(quic.Connection, "sendDatagram"));
    try std.testing.expect(@hasDecl(quic.Connection, "receiveDatagramInfo"));
    try std.testing.expect(@hasDecl(quic.Connection, "nextDatagramSize"));
    try std.testing.expect(@hasDecl(quic.Connection, "maxDatagramPayload"));
    try std.testing.expect(@hasDecl(quic.Connection, "openNextUni"));
    try std.testing.expect(@hasDecl(quic.Connection, "openNextBidi"));
    try std.testing.expect(@hasDecl(quic.Connection, "streamWrite"));
    try std.testing.expect(@hasDecl(quic.Connection, "streamRead"));
    try std.testing.expect(@hasDecl(quic.Connection, "streamFinish"));
    try std.testing.expect(@hasDecl(quic.Connection, "streamRecvState"));
    try std.testing.expect(@hasDecl(quic.Connection, "handle"));
    try std.testing.expect(@hasDecl(quic.Connection, "pollDatagram"));
    try std.testing.expect(@hasDecl(quic.Connection, "tick"));
    try std.testing.expect(@hasDecl(quic.Connection, "nextTimerDeadline"));
    try std.testing.expect(@hasDecl(quic.Connection, "isClosed"));
    try std.testing.expect(@hasDecl(quic.Connection, "closeEvent"));
    try std.testing.expect(@hasDecl(quic.Connection, "phase"));
    // Session-loss classification (session.SessionLostReason mapping).
    try std.testing.expect(@hasDecl(quic, "CloseEvent"));
    try std.testing.expect(@hasDecl(quic, "CloseSource"));
    try std.testing.expect(@hasDecl(quic, "CloseState"));
}

test "connection: rtt and path stats" {
    // PeerSession.rtt() maps onto per-path RTT snapshots.
    try std.testing.expect(@hasField(quic.PathStats, "srtt_us"));
    try std.testing.expect(@hasField(quic.PathStats, "min_rtt_us"));
    try std.testing.expect(@hasField(quic.PathStats, "rttvar_us"));
    try std.testing.expect(@hasField(quic.PathStats, "state"));
    try std.testing.expect(@hasDecl(quic.Connection, "pathStats"));
    try std.testing.expect(@hasDecl(quic.Connection, "activePathId"));
}

test "server: embedder-owned loop integration points" {
    // The adapter drives Server.feed / tick / reap itself (it owns the
    // event loop shape); these must exist with embedder-visible state.
    try std.testing.expect(@hasDecl(quic.Server, "feed"));
    try std.testing.expect(@hasDecl(quic.Server, "tick"));
    try std.testing.expect(@hasDecl(quic.Server, "reap"));
    try std.testing.expect(@hasDecl(quic.Server, "iterator"));
    try std.testing.expect(@hasField(quic.Server.Slot, "conn"));
    try std.testing.expect(@hasField(quic.Server.Slot, "peer_addr"));
    try std.testing.expect(@hasField(quic.Server.Slot, "user_data"));
    try std.testing.expect(@hasField(quic.Server.Slot, "slot_id"));
    // Client dial returns a full Connection.
    try std.testing.expect(@hasField(quic.Client, "conn"));
}

test "adapter surface exercised by the session layer" {
    // Pinned by src/quic/endpoint.zig — drift here breaks the adapter,
    // not just the tests.
    try std.testing.expect(@hasField(quic.Connection, "role"));
    try std.testing.expect(@hasDecl(quic.Connection, "close"));
    try std.testing.expect(@hasDecl(quic.Connection, "negotiatedAlpn"));
    // Pre-destruction notification used for server-side session
    // teardown (connection memory belongs to the Server's lifecycle).
    try std.testing.expect(@hasField(quic.Server.Config, "on_connection_will_close"));
    try std.testing.expect(@hasField(quic.Server.Config, "on_connection_will_close_user_data"));
    // Inbound stream discovery on connections.
    try std.testing.expect(@hasDecl(quic.Connection, "streamIterator"));
    // In-memory harness the two-node JOIN acceptance test rides on.
    try std.testing.expect(@hasDecl(quic.testing.Loopback, "handshake"));
    try std.testing.expect(@hasDecl(quic.testing.Loopback, "step"));
}

test "transport params: datagram + stream budgets exist" {
    const Params = quic.Connection.TransportParams;
    try std.testing.expect(@hasField(Params, "max_datagram_frame_size"));
    try std.testing.expect(@hasField(Params, "initial_max_data"));
    try std.testing.expect(@hasField(Params, "initial_max_streams_bidi"));
    try std.testing.expect(@hasField(Params, "initial_max_streams_uni"));
    try std.testing.expect(@hasField(Params, "max_idle_timeout_ms"));
}

test "in-memory loopback harness ships in the package" {
    // Two-node integration tests (join over real TLS) will use this.
    try std.testing.expect(@hasDecl(quic.testing, "Loopback"));
}
