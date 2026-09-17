//! LAN discovery glue (src/quic/discovery.zig, the `--mdns` path) over
//! real mDNS sockets on the loopback interface only: the `_qmesh._udp`
//! profile round trip, the `SeedSet` -> `Addr.fromIp` seam, and two
//! mesh nodes over real UDP where B joins A by mDNS instead of
//! `--join`. Nothing here reaches the LAN (v4, loopback allow-list).
//!
//! Skips, not failures, when the environment cannot host it: a `*:5353`
//! bind the sandbox refuses or another non-reuse holder owns, no usable
//! loopback, a single-threaded test Io, or `MDNS_HERMETIC=1` (the same
//! switch mdns-zig's own loopback tests honour — a locked-down macOS
//! runner may bind but never deliver the multicast).
//!
//! Certificates: tests/data (tools/gen-test-certs.sh); the a/b PeerIds
//! are the SPKI digests also pinned in tests/quic_session_test.zig.

const std = @import("std");
const Io = std.Io;
const qmesh = @import("qmesh");
const qmesh_quic = @import("qmesh_quic");
const qmesh_mdns = @import("qmesh_mdns");
const mdns = @import("mdns");

const testing = std.testing;
const profile = mdns.profiles.qmesh;

const ca_pem = @embedFile("data/ca.pem");
const node_a_cert = @embedFile("data/node-a.pem");
const node_a_key = @embedFile("data/node-a.key");
const node_b_cert = @embedFile("data/node-b.pem");
const node_b_key = @embedFile("data/node-b.key");
const node_a_hex = "48b3be63f84888a0d5e972492fe74ce3a39fbb564d162ef03462ee75e11ea143";
const node_b_hex = "c43fffee6eebfd655228f20e906aadd12b832623c26beedb9f8cf46dde5fb45e";

fn idFromHex(hex: []const u8) qmesh.PeerId {
    var id: qmesh.PeerId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, hex) catch unreachable;
    return id;
}

fn sleepMs(ms: u64) void {
    // libc nanosleep (std.Thread.sleep is gone in this toolchain).
    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

fn hermetic() bool {
    if (std.c.getenv("MDNS_HERMETIC")) |v| return v[0] != 0 and v[0] != '0';
    return false;
}

/// The loopback interface's index (the one owning a 127/8 address).
fn loopbackIndex() ?u32 {
    const snap = mdns.platform.ifaces.snapshot(.{ .include_loopback = true, .ipv6 = false }) catch return null;
    for (snap.slice()) |*iface| {
        for (iface.v4.slice()) |p| if (p.addr[0] == 127) return iface.index;
    }
    return null;
}

/// Per-process host labels: another test binary on this host hears
/// everything multicast on loopback, and equal host names would rename
/// against each other. Instances are the PeerId hex, which the
/// `SeedSet` keys on `(id, epoch)` anyway, so a rename is harmless.
fn hostLabel(buf: *[24]u8, base: []const u8) []const u8 {
    var seed: [2]u8 = undefined;
    testing.io.random(&seed);
    return std.fmt.bufPrint(buf, "{s}-{x:0>4}", .{ base, std.mem.readInt(u16, &seed, .little) }) catch unreachable;
}

/// `mdns.Service.Options` for a loopback-only, v4-only Service, or a
/// skip when this host cannot provide one.
fn loopbackOptions(host_label: []const u8, allow: *[1]u32) !mdns.Service.Options {
    if (hermetic()) return error.SkipZigTest;
    allow[0] = loopbackIndex() orelse return error.SkipZigTest;
    return .{ .host_label = host_label, .include_loopback = true, .ipv6 = false, .interfaces = allow };
}

fn initServiceOrSkip(opts: mdns.Service.Options) !mdns.Service {
    var svc = mdns.Service.init(testing.allocator, testing.io, opts) catch |err| switch (err) {
        error.PermissionDenied, error.AddressInUse => return error.SkipZigTest,
        else => return err,
    };
    if (svc.joinedCountFor(.v4) == 0) {
        svc.deinit();
        return error.SkipZigTest;
    }
    return svc;
}

/// `Service.run` as a Group task (`run` returns `anyerror`; the Group
/// wants a plain task).
fn runService(svc: *mdns.Service, shutdown: *std.atomic.Value(bool)) void {
    svc.run(shutdown, null) catch {};
}

test "qmesh advert on loopback: lookup + SeedSet yields A's PeerId, port and a dialable Addr" {
    var label_a: [24]u8 = undefined;
    var allow_a: [1]u32 = undefined;
    var adv = try initServiceOrSkip(try loopbackOptions(hostLabel(&label_a, "qmesh-a"), &allow_a));
    defer adv.deinit();
    var label_b: [24]u8 = undefined;
    var allow_b: [1]u32 = undefined;
    var brw = try initServiceOrSkip(try loopbackOptions(hostLabel(&label_b, "qmesh-b"), &allow_b));
    defer brw.deinit();

    const id_a = idFromHex(node_a_hex);
    var ad = try profile.Advert.init(.{ .port = 4451, .id = id_a.bytes, .epoch = 0x1234_5678_9abc });
    _ = try adv.advertise(ad.desc());

    // A runs in mode B on its own task so it probes, announces and
    // answers while this thread blocks in B's lookup.
    var shutdown: std.atomic.Value(bool) = .init(false);
    var group: Io.Group = .init;
    group.concurrent(testing.io, runService, .{ &adv, &shutdown }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    defer {
        shutdown.store(true, .release);
        group.await(testing.io) catch {};
    }
    sleepMs(2_500); // probe + announce (about 2 s)

    var found: [8]mdns.Resolved = undefined;
    const n = try brw.lookup(profile.service_type, .{ .timeout_us = 5 * std.time.us_per_s, .quiet_us = 500 * std.time.us_per_ms }, &found);
    try testing.expect(n >= 1);

    // Another `_qmesh._udp` advertiser on this host's loopback would
    // also be in `found`; the assertion is about A's contact.
    var seeds: qmesh_mdns.SeedSet = .{};
    var contact: ?profile.Contact = null;
    for (found[0..n]) |*r| {
        if (seeds.accept(r, brw.interfaces())) |c| {
            if (std.mem.eql(u8, &c.id, &id_a.bytes)) contact = c;
        }
    }
    const c = contact orelse return error.ContactNotFound;
    try testing.expectEqual(@as(u128, 0x1234_5678_9abc), c.epoch);
    try testing.expect(c.addr == .ip4);
    try testing.expectEqual(@as(u16, 4451), c.addr.ip4.port);
    try testing.expectEqual(@as(u8, 127), c.addr.ip4.bytes[0]);
    const addr = qmesh.Addr.fromIp(c.addr) orelse return error.AddrNotDialable;
    try testing.expect(addr.eql(qmesh.Addr.ipv4(c.addr.ip4.bytes, 4451)));
    // 127.0.0.1 is inside the loopback prefix of the interface it was
    // heard on: the best rank there is.
    try testing.expectEqual(mdns.AddrRank.on_link_same_if, c.rank);
    // The same (id, epoch) is not admitted twice; `seeds.stats` says why.
    for (found[0..n]) |*r| {
        if (seeds.accept(r, brw.interfaces())) |again| try testing.expect(!std.mem.eql(u8, &again.id, &id_a.bytes));
    }
    try testing.expect(seeds.stats.duplicates >= 1);
    try testing.expectEqual(@as(u64, 0), seeds.stats.rejected);
}

/// Node A's half of the two-node test: a runner plus its `Discovery`,
/// stepped from a Group task so A answers B's lookup while this
/// thread blocks in it. Only this task touches A until `stop`.
const NodeTask = struct {
    runner: *qmesh_quic.Runner,
    discovery: *qmesh_mdns.Discovery,
    shutdown: std.atomic.Value(bool) = .init(false),
    group: Io.Group = .init,
    failed: std.atomic.Value(bool) = .init(false),

    fn loop(t: *NodeTask) void {
        while (!t.shutdown.load(.acquire)) {
            t.runner.step() catch {
                t.failed.store(true, .release);
                return;
            };
            t.discovery.tick(t.runner, qmesh_quic.Runner.clockUs()) catch {
                t.failed.store(true, .release);
                return;
            };
            sleepMs(2);
        }
    }

    fn start(t: *NodeTask) !void {
        t.group.concurrent(testing.io, NodeTask.loop, .{t}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.SkipZigTest,
        };
    }

    fn stop(t: *NodeTask) void {
        t.shutdown.store(true, .release);
        t.group.await(testing.io) catch {};
    }
};

fn initRunner(id: qmesh.PeerId, cert: []const u8, key: []const u8) !*qmesh_quic.Runner {
    // Port 0: the runner advertises whatever it bound, exactly the
    // value `Discovery` puts in the SRV. v4 loopback so the resolved
    // 127.0.0.1 is the address the runner is reachable on.
    const addr = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 0);
    return qmesh_quic.Runner.init(testing.allocator, .{
        .endpoint = .{
            .self = .{ .id = id, .addr = addr },
            .tls_cert_pem = cert,
            .tls_key_pem = key,
            .ca_pem = ca_pem,
            .dial_server_name = "qmesh-test",
            .overlay_cfg = .{ .join_timeout_us = 500_000, .neighbor_timeout_us = 400_000 },
            .swim_cfg = .{ .probe_period_us = 150_000, .probe_timeout_us = 300_000, .indirect_timeout_us = 300_000, .suspicion_timeout_us = 1_500_000 },
        },
        .bind = addr,
    });
}

/// A `Resolved` as the Engine would emit it for `ad` on `ifindex`, with
/// the given addresses.
fn resolvedFrom(ad: *profile.Advert, addrs: []const Io.net.IpAddress, ifindex: u32) !mdns.Resolved {
    const desc = ad.desc();
    var name_buf: [128]u8 = undefined;
    var r: mdns.Resolved = .{
        .instance = try mdns.Name.parse(try std.fmt.bufPrint(&name_buf, "{s}.{s}.local", .{ desc.instance, desc.service_type })),
        .service_type = try mdns.Name.parse(try std.fmt.bufPrint(&name_buf, "{s}.local", .{desc.service_type})),
        .host = try mdns.Name.parse("peer-host.local"),
        .port = desc.port,
        .txt = try mdns.Txt.build(desc.txt),
        .ifindex = ifindex,
        .ttl_s = 120,
    };
    for (addrs) |a| try r.addrs.append(a);
    return r;
}

/// A Discovery for `runner` on the loopback only, no seed lookup, or a
/// skip when this host cannot bind it.
fn loopbackDiscovery(runner: *qmesh_quic.Runner, opts: mdns.Service.Options) !qmesh_mdns.Discovery {
    const d = qmesh_mdns.Discovery.init(testing.allocator, testing.io, runner, .{
        .host_label = opts.host_label,
        .lookup_timeout_us = 0,
        .ipv6 = false,
        .include_loopback = true,
        .interfaces = opts.interfaces,
        .log = false,
    }) catch |err| switch (err) {
        error.PermissionDenied, error.AddressInUse => return error.SkipZigTest,
        else => return err,
    };
    if (d.svc.joinedCountFor(.v4) == 0) {
        var dd = d;
        dd.deinit();
        return error.SkipZigTest;
    }
    return d;
}

test "a link-local-only resolve does not use up the peer's (id, epoch) admission" {
    var label: [24]u8 = undefined;
    var allow: [1]u32 = undefined;
    const opts = try loopbackOptions(hostLabel(&label, "qmesh-a"), &allow);
    const runner = try initRunner(idFromHex(node_a_hex), node_a_cert, node_a_key);
    defer runner.deinit();
    var disc = try loopbackDiscovery(runner, opts);
    defer disc.deinit();

    const id_b = idFromHex(node_b_hex);
    var ad = try profile.Advert.init(.{ .port = 4461, .id = id_b.bytes, .epoch = 0x77 });
    var link_local: [16]u8 = @splat(0);
    link_local[0] = 0xfe;
    link_local[1] = 0x80;
    link_local[15] = 9;
    // Heard first on an interface that only has B's fe80:: address: no
    // Addr can carry it, and the admission is released again.
    const on_v6_iface = try resolvedFrom(&ad, &.{.{ .ip6 = .{ .bytes = link_local, .port = 0, .interface = .{ .index = 12 } } }}, 12);
    disc.admit(runner, &on_v6_iface);
    try testing.expectEqual(@as(u64, 1), disc.stats.skipped_addr);
    try testing.expectEqual(@as(u64, 0), disc.stats.joined);
    try testing.expect(!disc.seeds.contains(id_b.bytes, 0x77));
    // The next interface's resolve carries a v4 address: joined.
    const on_v4_iface = try resolvedFrom(&ad, &.{.{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } }}, allow[0]);
    disc.admit(runner, &on_v4_iface);
    try testing.expectEqual(@as(u64, 1), disc.stats.joined);
    try testing.expect(disc.seeds.contains(id_b.bytes, 0x77));
    try testing.expectEqual(@as(u64, 0), disc.seeds.stats.duplicates);
    // Once joined, the same (id, epoch) again is a duplicate, whichever
    // interface it arrives on.
    disc.admit(runner, &on_v4_iface);
    disc.admit(runner, &on_v6_iface);
    try testing.expectEqual(@as(u64, 1), disc.stats.joined);
    try testing.expectEqual(@as(u64, 2), disc.seeds.stats.duplicates);
    try testing.expectEqual(@as(u64, 1), disc.stats.skipped_addr);
    // Our own advert echoed back is skipped without an admission either.
    var own = try profile.Advert.init(.{ .port = 4461, .id = idFromHex(node_a_hex).bytes, .epoch = 0x78 });
    const echo = try resolvedFrom(&own, &.{.{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } }}, allow[0]);
    disc.admit(runner, &echo);
    try testing.expectEqual(@as(u64, 1), disc.stats.skipped_self);
    try testing.expectEqual(@as(u64, 1), disc.stats.joined);
}

test "re-admitted contact with a better address replaces a connecting dial" {
    var label: [24]u8 = undefined;
    var allow: [1]u32 = undefined;
    const opts = try loopbackOptions(hostLabel(&label, "qmesh-a"), &allow);
    const runner = try initRunner(idFromHex(node_a_hex), node_a_cert, node_a_key);
    defer runner.deinit();
    var disc = try loopbackDiscovery(runner, opts);
    defer disc.deinit();
    const ep = runner.endpoint();

    const id_b = idFromHex(node_b_hex);
    var ad = try profile.Advert.init(.{ .port = 4471, .id = id_b.bytes, .epoch = 0x79 });
    // Heard first with an address on no local prefix (the multi-homed
    // case: a bridge or VPN address of B's this host cannot reach).
    // The dial goes out at once; nothing answers.
    const foreign = try resolvedFrom(&ad, &.{.{ .ip4 = .{ .bytes = .{ 10, 9, 9, 9 }, .port = 0 } }}, allow[0]);
    disc.admit(runner, &foreign);
    try testing.expectEqual(@as(u64, 1), disc.stats.joined);
    try testing.expectEqual(@as(u64, 1), ep.metrics().transport.dials);
    try testing.expectEqual(@as(u64, 0), ep.metrics().transport.sessions_closed);
    try testing.expect(ep.node.overlay.join.?.contact.addr.eql(qmesh.Addr.ipv4(.{ 10, 9, 9, 9 }, 4471)));
    // The same (id, epoch) again with the same address: a duplicate,
    // no second dial.
    disc.admit(runner, &foreign);
    try testing.expectEqual(@as(u64, 1), disc.seeds.stats.duplicates);
    try testing.expectEqual(@as(u64, 1), ep.metrics().transport.dials);
    // Then 127.0.0.1 heard across some other interface (ifindex 12 is
    // not in the table): inside the loopback prefix, so on-link, a
    // strictly better rank than the foreign subnet, and the set
    // re-admits the pair. The in-flight dial to 10.9.9.9 would block
    // `connectPeer` until its handshake timed out; the glue drops it
    // first, and the join now points at the better address.
    const on_link = try resolvedFrom(&ad, &.{.{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } }}, 12);
    disc.admit(runner, &on_link);
    try testing.expectEqual(@as(u64, 1), disc.seeds.stats.readmitted);
    try testing.expectEqual(@as(u64, 1), disc.stats.redialed);
    try testing.expectEqual(@as(u64, 0), disc.stats.readmit_ignored);
    try testing.expectEqual(@as(u64, 2), disc.stats.joined);
    try testing.expectEqual(@as(u64, 2), ep.metrics().transport.dials);
    try testing.expectEqual(@as(u64, 1), ep.metrics().transport.sessions_closed);
    try testing.expect(ep.node.overlay.join.?.contact.addr.eql(qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4471)));
    // The same 127.0.0.1 heard on the loopback interface itself ranks
    // better still (on-link on the arrival interface), so the set
    // re-admits once more, but the address is the one already being
    // dialed: that handshake is kept, no third dial, no close.
    const on_link_same_if = try resolvedFrom(&ad, &.{.{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } }}, allow[0]);
    disc.admit(runner, &on_link_same_if);
    try testing.expectEqual(@as(u64, 2), disc.seeds.stats.readmitted);
    try testing.expectEqual(@as(u64, 1), disc.stats.redialed);
    try testing.expectEqual(@as(u64, 1), disc.stats.readmit_ignored);
    try testing.expectEqual(@as(u64, 2), disc.stats.joined);
    try testing.expectEqual(@as(u64, 2), ep.metrics().transport.dials);
    try testing.expectEqual(@as(u64, 1), ep.metrics().transport.sessions_closed);
    // A worse or equal rank after that is a duplicate again: no third
    // dial, and the abandoned record is not touched.
    disc.admit(runner, &foreign);
    disc.admit(runner, &on_link);
    disc.admit(runner, &on_link_same_if);
    try testing.expectEqual(@as(u64, 4), disc.seeds.stats.duplicates);
    try testing.expectEqual(@as(u64, 2), ep.metrics().transport.dials);
    try testing.expectEqual(@as(u64, 1), ep.metrics().transport.sessions_closed);
    // An id with no dial in flight has nothing to abandon; a dial in
    // flight to the very address asked for is left alone.
    const dialed = qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, 4471);
    try testing.expectEqual(qmesh_quic.Endpoint.AbandonResult.none, ep.abandonDial(idFromHex(node_a_hex), dialed));
    try testing.expectEqual(qmesh_quic.Endpoint.AbandonResult.same_addr, ep.abandonDial(id_b, dialed));
    try testing.expectEqual(@as(u64, 1), ep.metrics().transport.sessions_closed);
}

test "a boot_epoch change re-announces the advert with the new epoch" {
    var label: [24]u8 = undefined;
    var allow: [1]u32 = undefined;
    const opts = try loopbackOptions(hostLabel(&label, "qmesh-a"), &allow);
    const runner = try initRunner(idFromHex(node_a_hex), node_a_cert, node_a_key);
    defer runner.deinit();
    var disc = try loopbackDiscovery(runner, opts);
    defer disc.deinit();

    const first = runner.endpoint().node.broadcast.boot_epoch;
    try testing.expectEqual(first, disc.epoch);
    try disc.tick(runner, qmesh_quic.Runner.clockUs());
    try testing.expectEqual(@as(u64, 0), disc.stats.epoch_updates);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.bufPrint(&expected, "{x:0>32}", .{first});
    try testing.expectEqualStrings("epoch", disc.ad.txt()[4].key);
    try testing.expectEqualStrings(&expected, disc.ad.txt()[4].value.?);

    // The epoch is a plain field (plumtree.zig); nothing changes it
    // in-process today, so the re-announce path is driven by hand.
    runner.endpoint().node.broadcast.boot_epoch = first +% 1;
    try disc.tick(runner, qmesh_quic.Runner.clockUs());
    try testing.expectEqual(@as(u64, 1), disc.stats.epoch_updates);
    try testing.expectEqual(first +% 1, disc.epoch);
    _ = try std.fmt.bufPrint(&expected, "{x:0>32}", .{first +% 1});
    try testing.expectEqualStrings(&expected, disc.ad.txt()[4].value.?);
    // Unchanged: no second update.
    try disc.tick(runner, qmesh_quic.Runner.clockUs());
    try testing.expectEqual(@as(u64, 1), disc.stats.epoch_updates);
}

test "node B joins node A through mdns discovery instead of --join" {
    var label_a: [24]u8 = undefined;
    var allow_a: [1]u32 = undefined;
    const opts_a = try loopbackOptions(hostLabel(&label_a, "qmesh-a"), &allow_a);
    var label_b: [24]u8 = undefined;
    var allow_b: [1]u32 = undefined;
    const opts_b = try loopbackOptions(hostLabel(&label_b, "qmesh-b"), &allow_b);

    const id_a = idFromHex(node_a_hex);
    const id_b = idFromHex(node_b_hex);
    // Both runners on this thread first: the runner clock's origin is
    // fixed by the first `init`, before any task reads it.
    const runner_a = try initRunner(id_a, node_a_cert, node_a_key);
    defer runner_a.deinit();
    const runner_b = try initRunner(id_b, node_b_cert, node_b_key);
    defer runner_b.deinit();

    // A advertises only (no seed lookup: nothing is up yet, and a
    // 3 s wait for nothing is what `--join`-less first nodes pay).
    var disc_a = qmesh_mdns.Discovery.init(testing.allocator, testing.io, runner_a, .{
        .host_label = opts_a.host_label,
        .lookup_timeout_us = 0,
        .ipv6 = false,
        .include_loopback = true,
        .interfaces = opts_a.interfaces,
        .log = false,
    }) catch |err| switch (err) {
        error.PermissionDenied, error.AddressInUse => return error.SkipZigTest,
        else => return err,
    };
    defer disc_a.deinit();
    if (disc_a.svc.joinedCountFor(.v4) == 0) return error.SkipZigTest;
    var task_a: NodeTask = .{ .runner = runner_a, .discovery = &disc_a };
    try task_a.start();
    defer task_a.stop();
    sleepMs(2_500); // A probes and announces

    // B: the `--mdns` start-up path — seed lookup, then the long-lived
    // Service browses beside the runner. The lookup is best effort
    // here, not asserted: on ONE host every Service shares the
    // loopback source address, and mdns-zig 0.1.0 classifies a peer's
    // bare PTR query as its own echo when it is byte-identical to a
    // query it sent within the last 2 s (core/echo_ring.zig window),
    // so B's 3 s lookup is unanswered whenever it lands inside A's
    // browse cadence. Two hosts on a LAN never collide this way.
    var disc_b = try qmesh_mdns.Discovery.init(testing.allocator, testing.io, runner_b, .{
        .host_label = opts_b.host_label,
        .ipv6 = false,
        .include_loopback = true,
        .interfaces = opts_b.interfaces,
        .log = false,
    });
    defer disc_b.deinit();
    try testing.expectEqual(@as(u64, 0), disc_b.stats.skipped_addr);
    if (disc_b.stats.seeds_found > 0) try testing.expect(disc_b.stats.joined >= 1);

    // Drive B (main thread) until a session with A is up. Either side
    // may dial: B's lookup or browse joins A's bound port with A's
    // PeerId as the expected identity, and A's browse joins B once
    // B's (unique, never echo-shaped) announcement arrives. Both are
    // this glue's `SeedSet` -> `Addr.fromIp` -> `startJoin` path, and
    // the mTLS handshake proves the PeerId either way.
    var waited: u64 = 0;
    while (waited < 20_000) : (waited += 2) {
        if (runner_b.endpoint().establishedWith(id_a)) break;
        try runner_b.step();
        try disc_b.tick(runner_b, qmesh_quic.Runner.clockUs());
        sleepMs(2);
    }
    try testing.expect(runner_b.endpoint().establishedWith(id_a));
    try testing.expect(!task_a.failed.load(.acquire));
    task_a.stop();
    try testing.expect(runner_a.endpoint().establishedWith(id_b));
    try testing.expect(disc_a.stats.joined + disc_b.stats.joined >= 1);
    try testing.expectEqual(@as(u64, 0), disc_a.stats.skipped_addr);
    // Our own advert echoes back on loopback and is skipped by id,
    // never joined: neither node ever dialed itself.
    try testing.expect(!runner_a.endpoint().establishedWith(id_a));
    try testing.expect(!runner_b.endpoint().establishedWith(id_b));

    // A re-admission against the established session: whichever side
    // dialed, B's set may or may not hold A's real epoch, so A is
    // admitted under a fresh one first, at a foreign address (a plain
    // admission: `connectPeer` is a no-op for an id with a session,
    // and the JOIN it re-sends is idempotent to an active neighbour).
    // Then the same epoch at a strictly better-ranked address is a
    // re-admission, and the session in use wins: ignored, no dial, no
    // close, still established.
    const ep_b = runner_b.endpoint();
    const dials_before = ep_b.metrics().transport.dials;
    const closed_before = ep_b.metrics().transport.sessions_closed;
    const joined_before = disc_b.stats.joined;
    var ad_a = try profile.Advert.init(.{ .port = disc_a.ad.port, .id = id_a.bytes, .epoch = disc_a.epoch +% 1 });
    const foreign = try resolvedFrom(&ad_a, &.{.{ .ip4 = .{ .bytes = .{ 10, 9, 9, 9 }, .port = 0 } }}, allow_b[0]);
    disc_b.admit(runner_b, &foreign);
    try testing.expectEqual(joined_before + 1, disc_b.stats.joined);
    try testing.expectEqual(@as(u64, 0), disc_b.seeds.stats.readmitted);
    const on_link = try resolvedFrom(&ad_a, &.{.{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } }}, allow_b[0]);
    disc_b.admit(runner_b, &on_link);
    try testing.expectEqual(@as(u64, 1), disc_b.seeds.stats.readmitted);
    try testing.expectEqual(@as(u64, 1), disc_b.stats.readmit_ignored);
    try testing.expectEqual(@as(u64, 0), disc_b.stats.redialed);
    try testing.expectEqual(joined_before + 1, disc_b.stats.joined);
    try testing.expectEqual(dials_before, ep_b.metrics().transport.dials);
    try testing.expectEqual(closed_before, ep_b.metrics().transport.sessions_closed);
    try testing.expect(ep_b.establishedWith(id_a));
    try testing.expectEqual(qmesh_quic.Endpoint.AbandonResult.kept, ep_b.abandonDial(id_a, qmesh.Addr.ipv4(.{ 127, 0, 0, 1 }, disc_a.ad.port)));
}
