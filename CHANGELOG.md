# Changelog

All notable changes to qmesh-zig are documented in this file.

The project is pre-1.0. Any 0.x release may include breaking API
changes.

## [Unreleased]

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

- Added `LICENSE` (Apache-2.0, matching quic-zig) and this changelog.

### Feature state at 0.1.0

HyParView overlay, SWIM + Lifeguard failure detection with
corroborated-suspicion acceleration and RTT-scaled budgets, Plumtree
broadcast with IWANT repair, recent-window anti-entropy, a
deterministic simulator with fault injection, the `qmesh_quic`
Endpoint/Runner over real QUIC with cert-bound identity, and a
twelve-node real-socket mesh test. See README.md for the detailed
status list.
