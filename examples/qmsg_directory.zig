//! qmesh membership + qmsg application traffic.
//!
//! The supported implementation lives in the `qmesh_messaging` module:
//!
//! ```zig
//! const messaging = @import("qmesh_messaging");
//! const qmsg = @import("qmsg");
//! const local_peer_hex = local_peer_id.hex();
//! var dialer = messaging.QmsgDialer(qmsg){
//!     .node = &message_node,
//!     .options = .{
//!         .server_name = "cluster",
//!         .identity_verification = .none,
//!         .ca_pem = ca,
//!         .client_cert_pem = cert,
//!         .client_key_pem = key,
//!         .transport = .{
//!             .peer_id = &local_peer_hex,
//!             .supported_patterns = qmsg.control.PatternBits.req | qmsg.control.PatternBits.rep,
//!             .required_peer_patterns = qmsg.control.PatternBits.req | qmsg.control.PatternBits.rep,
//!         },
//!     },
//! };
//! var pool = try messaging.Pool(@TypeOf(dialer)).init(allocator, .{});
//! defer pool.deinit(&dialer);
//! // In the caller's loop, after driving mesh and qmsg:
//! try pool.service(&mesh.node, &dialer, resolver, now_us);
//! if (try pool.ensure(&mesh.node, &dialer, resolver, peer_id, now_us)) |session| {
//!     _ = try message_node.request(.{ .quic = session }, outgoing);
//! }
//! ```
//!
//! The resolver explicitly supplies the application's endpoint. Membership
//! may be enumerated with Node.members (which reports completeness), but
//! reconciliation uses point lookups, so truncated snapshots cannot close
//! healthy sessions. Demand survives independent qmsg reconnects; only
//! authenticated, HELLO-ready sessions are returned. See
//! `tests/composition` for the executable real-library integration test.

const messaging = @import("qmesh_messaging");
pub const Pool = messaging.Pool;
pub const QmsgDialer = messaging.QmsgDialer;
pub const Resolver = messaging.Resolver;

test "composition example exports the supported implementation" {
    _ = Pool;
    _ = QmsgDialer;
    _ = Resolver;
}
