# Changelog

All notable changes to qmesh-zig are documented in this file.

The project is pre-1.0. Any 0.x release may include breaking API
changes.

## [Unreleased]

- **quic-zig v0.29.0** (from v0.27.0; v0.28.0 and v0.28.1 skipped). No
  security fix and no wire change; nothing qmesh calls was removed or
  renamed, and the option map is the same. qmesh needs no code change.
  v0.28.0 keeps the end of a stream that a `tick` reclaimed: `quic.app`
  reports `.fin` or `.reset` for it (it reported `.reaped`), and a
  stream the application stopped now ends as `.reaped` (it was `.fin`).
  qmesh sets no `on_stream_end` hook, and the runner services every
  session before it ticks. qmesh stops a stream only to refuse a peer
  bidi stream, and drops what such a stream delivers. Its one
  `Outbox.finish` follows a push on a stream it just opened. The
  fallback path (quic v0.21.x) reads `streamRecvState`, which did not
  change. v0.28.1 fixes a 32-bit build. v0.29.0: `Server.feed` makes
  no connection for a datagram of which no packet opens, and says
  `.dropped` (through v0.28.1 a peer server's first flight made a
  half-open slot and `.accepted`; qmesh found it, the entry below). The
  runner keeps giving a dial its own datagrams first: the server builds
  no connection for them, and they do not count against its
  per-source Initial cap or meet a full slot table (the fallback to the
  dials runs on `.dropped` only). New test in
  `tests/quic_session_test.zig`: every datagram of A's side goes to B's
  own server first and to B's dial only on `.dropped`; B's server makes
  no slot, and the dial's handshake completes. It fails on v0.27.0
  (`.accepted`) and passes on v0.29.0. Also in v0.29.0: a late packet
  is not a lost packet, a connection costs about 91 KB of heap (was
  1.09 MB), a client connects through handshake loss, a lost
  CONNECTION_CLOSE is sent again, and a Debug build asserts that
  `feed` and `tick` run on one thread (the runner calls both from its
  own loop). qmesh sets none of the new config fields. 127/127 tests,
  25/25 steps, mdns included.
- **quic-zig v0.27.0** (from v0.25.0; v0.26.0 skipped). No security
  fix, and nothing qmesh calls was removed or renamed; the option map
  is the same. What the two releases change and qmesh: tokens are 114
  bytes (were 96), and qmesh's `retry_token_key` / `new_token_key` are
  32-byte keys, not tokens; qmesh never asks for a key update
  (`KeyUpdateBlocked` until the handshake is confirmed); its transport
  parameters go through `Server` and `Client`, which send the
  connection IDs a peer must now send; it never calls
  `setRememberedPeerTransportParams` and sets no session-ticket field.
  No test counts or measures handshake datagrams. One change did break
  qmesh, the next entry.
- **A dial's handshake completes on quic-zig v0.26.0 and later.** A
  node accepts and dials on one socket, and the runner gave every
  datagram to its server first and to the dials only when the server
  dropped it. Since v0.26.0 a server pads its first flight to 1200
  bytes (RFC 9000 section 14.1; it was shorter, and the gate dropped
  it). So a peer's ServerHello passed our server's Initial size gate and
  opened a half-open slot there (`feed` said `.accepted`), and the dial
  never got it. On v0.27.0 the twelve-node mesh test did not converge
  and the mDNS join test failed. Now `Runner.ingest` gives a datagram
  first to the live dial that aims at its source address and owns its
  Destination Connection ID (`Connection.ownsLocalCid`); the rest goes
  to the server first, as before. New test in
  `tests/quic_mesh_test.zig`: two nodes over real UDP, B dials A, both
  sessions establish and no server slot is half open. It failed on
  v0.27.0 before the fix. 126/126 tests, 25/25 steps, mdns included.
- **quic-zig v0.25.0, a security fix:** in every older quic-zig
  release one short datagram from anyone who saw a packet of a
  connection (or a datagram a small receive buffer cut short) made
  `Connection.handle` return an error, and `Server.feed` closed the
  connection. So one such datagram ended a session a peer had dialed
  to us. Our dials were not closed (the runner ignores an error from
  `handle` on a dial connection). v0.25.0 drops such a packet. No API
  changed and the quic option map is the same. qmesh needs no code
  change for the other behavior changes: it never maps
  `error.TooManyInFlight` (`poll` now returns null instead), no test
  counts Initial packets, and the runner ticks every connection on each
  pass instead of parking on `nextTimerDeadline`, so a handshake probe
  deadline needs nothing. Handshakes under loss send more datagrams,
  earlier. The suite passes unchanged on v0.25.0: 125/125 tests, 25/25
  steps, mdns included.
- **Toolchain and quic pin (branch `nest-pin`):** the tagged Zig
  `0.17.0` (was dev.1786) and quic-zig `v0.24.1` (was v0.22.0), in
  `mise.toml`, `minimum_zig_version` and the composition workspace.
  quic v0.24.1's build.zig refuses every 0.17.0-dev build, so the two
  move together. The same quic pin as qmsg and nest. v0.24.1 has the
  `src/` of v0.24.0 and also accepts `optimize`. v0.24.0 removes
  the 4096-stream lifetime cap: the stream limit is a window of streams
  open at once, and an id comes back only when its stream is closed in
  both directions. qmesh opens only unidirectional streams and finishes
  each one. The suite passed unchanged at the move (122/122 tests on
  v0.24.0, mdns included). With the tests that the bidi-stream and
  receive-table entries below add, it passes 125/125 on v0.24.1.
- **quic and BoringSSL follow the build mode:** the quic option map is
  `{target, release = optimize != .debug, sanitize-c = "trap"}`, the
  same as qmsg's and nest's. Through v0.24.0 quic-zig had no
  `optimize` option, only the `release` bool, so before this a
  `-Doptimize=ReleaseSafe` build compiled quic and BoringSSL in Debug
  (v0.24.1 accepts `optimize` too; the map keeps `release`). Zig
  0.17.0 makes a map that differs between parents a compile error
  ("file exists in modules 'quic' and 'quic0'"). The composition
  workspace's local quic takes the same `release`.
- **A peer bidirectional stream is refused in both halves:**
  STOP_SENDING and RESET_STREAM. qmesh frames travel only on
  unidirectional streams. On the `quic.app.ConnectionDriver` path (quic
  v0.22.0 and later, so the pinned v0.24.1) the driver tracked a peer
  bidi stream while its table had room: it delivered the frame and never
  ended our half. The fallback path (quic v0.21.x) did the same, and
  when it refused a stream it sent STOP_SENDING only. On v0.24.0 such a
  stream holds a place in the peer's stream window for the life of the
  connection. `tests/quic_boundary_test.zig` now pins the driver.
- **The driver's receive table is the stream window:** qmesh advertises
  `initial_max_streams_uni = 64` and `initial_max_streams_bidi = 0`
  (was quic's default: 64 and 1000), and the driver tracks 64 receive
  streams (was 16). The driver handles every stream that opened in a
  service pass before it reads one, and it refused (STOP_SENDING) each
  stream past its table. So of a burst of complete one-frame streams
  that arrived in one pass, only 16 were delivered; the rest were lost
  with no error at the sender. The fallback path (quic v0.21.x, which
  nest ran before this pin move) frees a slot as soon as its stream
  ends, so it delivered them all. Measured with the new session test
  (B fills its places in A's window in one burst, 63 streams): 16
  delivered before, 63 after, 0 refused. A sender past the window now
  gets a temporary `StreamLimitExceeded` from `sendReliable`, which the
  node counts in `sends_failed`. A peer cannot open a bidi stream: its
  quic refuses to open one, and ours closes a connection whose peer
  sends one anyway (STREAM_LIMIT_ERROR). Memory: the driver table is
  76,800 bytes per session (64 x 1,200; was 19,200).
- **Toolchain pin bump:** zig `0.17.0-dev.1786+75044cb04` (was
  dev.1683), the same build qmsg, shared-studio and mdns-zig pin, in
  `mise.toml` and `minimum_zig_version`. No source change was needed:
  every std API qmesh uses is unchanged between the two builds, and the
  full suite passes on the new pin as is.
- **`qmesh-node --mdns` LAN discovery** (`src/quic/discovery.zig`, the
  dev-only `qmesh_mdns` module): one bounded `_qmesh._udp` lookup at
  start-up joins every advertising node like a `--join` contact, then
  the node advertises itself (instance `--name` / `QMESH_NAME` or the
  first 16 hex of its id, TXT `id` + boot `epoch`) and keeps browsing
  from `Runner.Options.on_iteration`, joining each new `(id, epoch)`
  through the same `SeedSet`. The TXT id only selects; the mTLS
  handshake proves the peer. LAN/dev convenience only: multicast does
  not exist on fly 6pn. Env: `QMESH_MDNS`, `QMESH_NAME`.
- **`Addr.fromIp(std.Io.net.IpAddress) ?Addr`:** v4 and global/ULA v6
  project unchanged; link-local v6 (`fe80::/10`) is null whether or not
  its scope is set — `Addr` has no scope field and the socket loop
  sends scope id 0, so no link-local destination is routable through
  it.
- **`Runner.clockUs()`:** the loop's monotonic clock (the `now_us`
  `on_iteration` receives), for embedders that `step()` and tick a
  side-car on the same time base.
- **`--mdns` address ranking and re-admission** (mdns-zig 0.1.1): a
  `resolved` is per interface, and on a multi-homed Mac the first one
  for a peer can carry an address this host cannot dial (a VM bridge's
  subnet base `192.168.215.0`, a VPN tunnel); B was observed joining A
  at `192.168.215.0:4471` while A listened on `192.168.1.75`. The
  `SeedSet` now ranks each contact's address against the Service's own
  interface table (`Service.interfaces()`, passed at both the start-up
  lookup and the `on_iteration` browse: on-link on the arrival
  interface first, then on-link anywhere, global v6, foreign-subnet v4,
  scoped link-local; a local prefix's network base is never dialable)
  and re-admits an `(id, epoch)` once per strictly better rank. The
  glue treats a re-admitted contact as a correction: a dial to that id
  still handshaking is dropped first (new `Endpoint.abandonDial(peer,
  addr)` -> `.dropped` / `.none` / `.kept` / `.same_addr`; only a
  client-side session that never bound its peer identity is closed,
  with no overlay notification) so the `startJoin` that follows dials
  the better address at once instead of after the QUIC handshake
  timeout plus the 2 s join retry; a peer that already has a session
  (established, or handshake done and HELLO pending) keeps it and the
  contact is ignored (`mdns readmit ignored ...`,
  `Stats.readmit_ignored`), as does a dial in flight to the re-admitted
  address itself (a better rank is not always a different address: the
  same one heard across a bridge, then on its own interface).
  `Stats.redialed` counts the replaced dials; the join line is now
  `mdns join|rejoin id=... addr=... rank=<AddrRank> epoch=...
  ifindex=...`. Tests: `re-admitted contact with a better address
  replaces a connecting dial` and the re-admission tail of `node B
  joins node A through mdns discovery` (tests/mdns_discovery_test.zig).
- **Lazy `mdns` dependency:** mdns-zig v0.1.1 as a tarball pin marked
  `.lazy`; resolved in build.zig only after the dependency-build early
  return, so no library module imports it and a consumer that fetched
  qmesh never downloads it. mdns-zig refuses ReleaseFast/ReleaseSmall,
  so build.zig resolves it only for Debug/ReleaseSafe (the fly
  posture) or `-Dmdns=true`; a ReleaseFast `qmesh-node` still builds
  and refuses `--mdns` at start-up (`build_options.mdns`).
- **`PeerId.fromCertPem(gpa, pem)`:** the SPKI digest of the first
  certificate in a PEM, bounds-checked DER walk, std only. `qmesh-node`
  refuses an `--id` that is not the digest of `--cert`
  (`error.IdCertMismatch`) so a mistyped id is never gossiped or
  announced over mDNS.
- **Discovery admission:** a `resolved` that only carries a link-local
  v6 address no longer uses up the peer's `(id, epoch)` admission; the
  next interface's `resolved` with a dialable address is joined.
- **Tests:** `tests/mdns_discovery_test.zig` — two mdns Services on
  loopback with the qmesh profile (advertise as A, lookup from B,
  `SeedSet` yields A's PeerId, port and a dialable `Addr`), and two
  runners over real UDP where B and A find each other by mDNS with no
  `--join` and establish a real mTLS session. Skips without a `*:5353`
  bind, a loopback interface, or under `MDNS_HERMETIC=1`.
- **Wire version 2:** broadcast IDs include a boot epoch; the protocol now
  uses frame version 2 and ALPN `qmesh/2`. Raw `Node` initialization requires
  `boot_epoch`, while `Endpoint` generates it securely by default. Broadcast
  callbacks receive the complete `MsgId`. See the README migration notes;
  peers must upgrade together.
- **Supported messaging composition:** `qmesh_messaging` replaces the old
  directory example with a bounded demand-driven peer pool, explicit endpoint
  resolution, authenticated qmsg readiness, retry/backoff, session reuse and
  idle eviction. Suspect members keep existing sessions. qmsg remains optional.
- **Membership and effects:** complete member snapshots report truncation and
  preserve suspect/dead state. Authenticated contact updates refresh live
  members' addresses. Effects own captured slice data, and mass failure
  notifications drain in bounded batches.
- **QUIC integration:** use the shared `ConnectionDriver` when available;
  retain compatibility with released quic 0.21.1 and align its pin with qmsg.
  Harden HELLO staging, stream refusal, framing errors and session teardown.
  Runner supports ephemeral bind ports through `localAddress()`.
- Document bounded dissemination and recent repair, with restart, cache
  eviction, real-session and combined qmesh/qmsg regression coverage.

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
