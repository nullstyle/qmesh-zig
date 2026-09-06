//! qmesh_quic — the real-QUIC transport for qmesh.
//!
//! A separate module from `qmesh` on purpose: the library core and the
//! simulator stay quic-free (no BoringSSL compile, no transport
//! dependency), while consumers that want the real thing import this
//! module and drive `Endpoint.service` from their own event loop.
//!
//! ```zig
//! const ep = try qmesh_quic.Endpoint.init(allocator, .{
//!     .self = my_desc,
//!     .tls_cert_pem = cert, .tls_key_pem = key, .ca_pem = ca,
//!     .dial_server_name = "qmesh-test",
//!     .rng_seed = seed,
//! });
//! defer ep.deinit();
//! _ = try ep.listen();
//! ep.startJoin(contact_desc);
//! // each loop iteration: feed/poll sockets, then
//! try ep.service(now_us);
//! ```

pub const hello = @import("hello.zig");
pub const endpoint = @import("endpoint.zig");
pub const transport = @import("transport.zig");
pub const loop = @import("loop.zig");

pub const Endpoint = endpoint.Endpoint;
pub const Options = endpoint.Options;
pub const Runner = loop.Runner;
pub const QuicTransport = transport.QuicTransport;
pub const MeshNode = endpoint.MeshNode;
pub const alpn = endpoint.alpn;

test {
    _ = hello;
    _ = endpoint;
    _ = transport;
    _ = loop;
}
