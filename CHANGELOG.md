# Changelog

All notable changes to qmesh-zig are documented in this file.

The project is pre-1.0. Any 0.x release may include breaking API
changes.

## [Unreleased]

## [0.2.1] - 2026-09-06

- **README: why the composition is worth it, with numbers.** qmsg
  0.7.0's two-node test measures its dead-peer detection at the QUIC
  idle timeout — 2169ms at a 2s negotiated timeout, and the default is
  30s. qmesh's SWIM defaults CONFIRM a death in roughly 5s cluster-wide
  and distinguish a dead peer from a dead path, which a per-connection
  timeout cannot. Documented in the "Composing with qmsg" section.

## [0.2.0] - 2026-09-06

- **`examples/qmsg_directory.zig`: composing qmesh with qmsg without
  coupling them.** qmesh names and watches peers; qmsg carries the
  traffic. Each runs its own endpoint on its own port, and the only
  thing they share is an identity neither invents: both derive it from
  the same TLS certificate, so `qmesh.PeerId.hex()` and qmsg's
  `Session.certPeerIdHex()` are the same 64 characters for the same
  peer.

  The module is a `Directory`: a map from cluster identity to qmsg
  session, reconciled against `aliveMembers` — dial members that gained
  liveness, close sessions for members that lost it. Dial failures are
  counted and retried rather than cached as absence; addressless
  members are skipped; a short scratch buffer is reported in
  `stats.truncated` instead of silently truncating the view. It imports
  only `qmesh`, so this package still does not depend on qmsg.

  Deliberately not offered: a shared socket, a shared quic Connection,
  or qmsg traffic riding a qmesh session. Two connections per peer is
  the price; it buys qmsg's full wire instead of qmesh's 1152-byte
  single-frame gossip envelope.

  Verified against the PUBLISHED packages: a program importing `qmesh`,
  `qmesh_quic` and `qmsg` 0.6.1 compiles to a single quic module and
  runs. This requires qmsg >= 0.6.1 — earlier releases forwarded a
  different option set to quic-zig, which instantiated quic twice and
  failed with `file exists in modules 'quic' and 'quic0'`.

## [0.1.0] - 2026-09-06

First published release: qmesh becomes a consumable Zig package.

The library itself has been developed against a sibling `quic-zig`
checkout. That is not something another project can fetch — a `.path`
dependency resolves against the package directory, so a fetched qmesh
failed to configure at all. This release fixes the packaging and pins
a real quic-zig release.

- **quic-zig is a tarball pin (v0.21.0), not `.path = "../quic-zig"`.**
  The URL+hash form is what makes qmesh fetchable. v0.21.0 is also the
  release that exposes `Connection.peerCertSpkiDigest()`, the API
  qmesh's cert-bound `PeerId` is built on — qmesh previously required
  unreleased quic-zig HEAD.

- **The option map forwarded to quic-zig matches qmsg's exactly**
  (`target`, `sanitize-c`). Zig keys the dependency cache on
  `{pkg_hash, option-set}`, so one binary linking both qmesh and qmsg
  now shares a single quic module instead of compiling BoringSSL twice
  and minting two incompatible `quic.Connection` types. `optimize` is
  deliberately not forwarded: quic-zig registers no such option, and
  passing it failed a cold-cache build.

- **Downstream builds stop after the public modules.** `build.zig` now
  returns early when `b.pkg_hash` is non-empty, so a consumer that
  fetched qmesh gets `qmesh`, `qmesh_sim` and `qmesh_quic` registered
  and nothing else configured — previously every consumer also
  configured the node binary, the test steps and the tools.

- **Docs: the Transport contract is six decls, not five.** The README
  omitted `descOf` and still described the QUIC adapter as future
  work; `qmesh_quic.Endpoint` has been the real implementation for
  some time.

- **`Node.aliveMembers(out)`: the directory an embedder dials from.**
  `Hooks` carried only `onBroadcast`, and `descOf` answers for one
  already-known peer rather than enumerating membership, so nothing
  could answer "who is in the cluster and how do I reach them".
  `aliveMembers` snapshots the peers SWIM currently holds alive into a
  caller-owned buffer. A descriptor's `addr` may be `.none` — alive but
  not dialable — and callers must skip those. `Member` and
  `MemberState` are re-exported from the root module.

- Added `LICENSE` (Apache-2.0, matching quic-zig) and this changelog.

### Feature state at 0.1.0

HyParView overlay, SWIM + Lifeguard failure detection with
corroborated-suspicion acceleration and RTT-scaled budgets, Plumtree
broadcast with IWANT repair, recent-window anti-entropy, a
deterministic simulator with fault injection, the `qmesh_quic`
Endpoint/Runner over real QUIC with cert-bound identity, and a
twelve-node real-socket mesh test. See README.md for the detailed
status list.
