# Brief for a quic-zig session: generic APIs qmesh-zig needs for milestone 2

This document is the work order handed to a quic-zig development
session. qmesh-zig's milestone 2 (the QUIC session adapter: one
`quic.Server` per node + outbound dials implementing qmesh's transport
contract) is designed against the items below. Item 1 is blocking;
item 2 is strongly desired; item 3 is optional. Keep the copy in this
file authoritative — update it (and the README gap list + the boundary
test) as items land.

Baseline: quic-zig `main` @ `2e73330` (v0.19.0+), boringssl-zig pinned
at `b47af8c` (0.6.5 tarball), Zig `0.17.0-dev.1683+5ceec001b`.

---

## Ground rules (from the qmesh design brief)

- The dependency direction is strictly `qmesh-zig -> quic-zig`; no
  gossip/membership concepts (PeerId, SWIM, HyParView, views) may
  enter quic-zig.
- Everything requested below is generic mTLS-embedder functionality —
  any authenticated private-cluster embedder (service mesh, message
  bus, database replication) needs the same primitives.
- No broad refactors: focused additions with tests, please.

## 1. Peer identity/certificate access (blocking)

**Problem.** mTLS verification works today (`Server.Config.client_ca_pem`
requires+verifies client certs; `Client.Config.ca_pem`/`client_cert_pem`
verify the server and present the client cert), but after the
handshake the embedder cannot read *which* authenticated peer it is
talking to: neither `quic.Connection` nor `boringssl.tls.Conn` exposes
the peer certificate or any digest of it. boringssl-zig has no
`SSL_get_peer_certificate` binding.

qmesh's central security property is "PeerId = digest of the peer's
authenticated key material," so the session adapter cannot bind
identity to authentication without this. Interim workaround in qmesh
(announced ids inside the authenticated channel) weakens the property
and we want it gone.

**Request.** A digest accessor on `Connection`, role-agnostic:

```zig
/// SHA-256 of the peer's leaf-certificate SubjectPublicKeyInfo,
/// available once the handshake has completed and the peer presented
/// a certificate. Null otherwise (handshake incomplete, no peer cert
/// in optional-client-cert mode, or connection closed).
pub fn peerCertSpkiDigest(self: *const Connection) ?[32]u8;
```

Design notes:

- **SPKI digest, not full-cert digest.** A leaf-cert digest changes on
  every re-issuance; an SPKI digest is stable across cert renewal as
  long as the keypair is retained — the identity semantic cluster
  memberships want. BoringSSL provides `X509_pubkey_digest` directly,
  so no manual SPKI DER extraction is needed. If you prefer exposing
  the full certificate DER instead (`peerCertificateDer`), that also
  works for qmesh — we will hash it — but the digest form avoids a new
  allocation and an embedding decision for every consumer.
- **Implementation path.** New boringssl-zig bindings
  (`SSL_get_peer_certificate`, `X509_digest`/`X509_pubkey_digest`,
  `X509_free`), then a `boringssl.tls.Conn` method
  (`peerCertSpkiDigest() ?[32]u8`), then the `Connection` thunk that
  gates on handshake completion. Note `SSL_get_peer_certificate`
  returns a reference the caller must free (`X509_free`) —
  `X509_pubkey_digest` needs the `X509*` alive during the call only.
- **Resumption/0-RTT:** the accessor must work on resumed sessions
  (BoringSSL keeps the original peer cert available post-handshake).
  Both roles: server reading the client cert, client reading the
  server cert.
- **Cert pin dance:** boringssl-zig changes require a new tarball pin
  in quic-zig's `build.zig.zon` (URL + hash via the usual
  `tools/fetch-package-hash.sh` flow — not `zig fetch --save`).

**Acceptance tests qmesh expects to see:**

- An mTLS loopback pair where each side's `peerCertSpkiDigest()`
  matches a digest of the corresponding test certificate's public key
  (computed independently in the test fixture).
- Null before handshake completion; null on a server configured for
  optional client certs when none was presented.

## 2. Verify-against-pinned-CA without a name check (strongly desired)

**Problem.** `Client.connect` verifies the server certificate's
identity against `server_name` (SNI name-check). A mesh dials bare
addresses learned from gossip; the peer certificate's identity is its
cluster identity, not the IP we dialed. Today the only escape is
`insecure_skip_verify = true`, which turns off *all* verification
(and cannot even be combined with `ca_pem` — `InvalidConfig`). There
is no "chain must validate against my pinned CA; skip the name check"
posture, which is exactly what private-cluster mutual auth wants.

**Request.** Decouple SNI (still sent, still required) from identity
checking:

```zig
// Client.Config
/// How the server certificate's identity is bound. `.server_name`
/// (default) is today's behavior: verified against server_name.
/// `.none` skips the name check while chain verification against
/// `ca_pem` remains mandatory — the private-CA mesh posture.
/// `.none` without a non-null `ca_pem` is an InvalidConfig error at
/// connect time (it must never silently downgrade to no verification).
identity_verification: enum { server_name, none } = .server_name,
```

**Acceptance tests:** with `.none` + `ca_pem`, a connection succeeds
when the cert's SAN/CN does not match `server_name` but the chain
validates; it fails when the chain does not validate; `.none` without
`ca_pem` returns `InvalidConfig`.

## 4. Expose `streamInitiatedByLocal` on `Connection` (trivial)

`Connection/streams.zig` has `streamInitiatedByLocal(conn, id)` but it
is not thunked onto the embedder-visible `Connection` method surface,
so the qmesh adapter classifies inbound streams via `conn.role` +
the stream-id initiator bit (RFC 9000 §2.1). Works fine; a one-line
thunk would make the intent explicit for every embedder that
multiplexes its own streams with peer streams.

## 3. Handshake-completion notification (optional, non-blocking)

Server-side embedders currently discover new connections by diffing
`Server.iterator()` and poll `Connection.handshakeDone()`/`phase()`.
That works and qmesh can ship milestone 2 on it. If you want to
improve it cheaply: an `on_handshake_complete` callback on
`Server.Config` mirroring the existing `on_connection_will_close`, or
at least a documented iterator-diff pattern in EMBEDDING.md. No rush.

## Considered and not needed

- **RTT / close-cause classification / datagram+stream send-receive
  ergonomics:** sufficient as-is (`pathStats().srtt_us`, `CloseEvent`/
  `CloseSource`, `sendDatagram`/`receiveDatagramInfo`,
  `openNextUni`/`streamWrite`/`streamRead`). No changes requested.
- **Datagram queue bounds** (64 pending / 64 KiB per connection):
  fine; the qmesh adapter treats `DatagramQueueFull` like any
  transport-level send failure (count + drop, protocol timers own
  recovery).

## What qmesh-zig does once these land

Update `tests/quic_boundary_test.zig` to pin the new accessors,
replace the README gap entries with "resolved in quic-zig <version>",
then implement `src/quic/` (SessionManager over `Server`+`Client`,
DATAGRAM for ephemeral frames, `frame.stream` length-prefixed writes
for reliable frames) with a two-node JOIN over
`quic.testing.Loopback` as the acceptance test.
