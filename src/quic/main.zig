//! qmesh-node: the deployment entry point — one mesh node over the
//! supported socket loop (`qmesh_quic.Runner.run`), configured for the
//! multi-region fly.io posture.
//!
//! Identity is provisioned, not negotiated: the node's PeerId is the
//! SHA-256 of its leaf certificate's DER SubjectPublicKeyInfo — the
//! standard pipeline, so the same id other tooling computes is what
//! the mesh uses:
//!
//!   openssl x509 -in node.pem -pubkey -noout \
//!     | openssl pkey -pubin -outform DER | openssl dgst -sha256
//!
//! Usage (every flag has an env fallback of the same meaning —
//! QMESH_ID, QMESH_BIND, QMESH_JOIN (comma-separated), QMESH_CERT /
//! QMESH_KEY / QMESH_CA (file path or inline PEM), QMESH_METRICS_SECS,
//! QMESH_PUBLISH_EVERY):
//!
//!   qmesh-node --id <64-hex> --bind '[fdxx::1]:4451' \
//!              --cert node.pem --key node.key --ca ca.pem \
//!              [--join <64-hex>:<addr> ...] [--metrics-secs 10] \
//!              [--publish-every <secs>] [--pmtu-max 1372]
//!
//! fly note: the 6pn WireGuard interface is MTU 1420, so fly
//! deployments pass --pmtu-max 1372 (1420 - 48 v6+UDP headers) —
//! at the default 1380 full-size packets are silently dropped.
//!
//! Runtime observability: a compact metrics line on stderr every
//! `--metrics-secs` (gauges: member states, views, tree shape,
//! sessions, Lifeguard health, RTT envelope; plus monotonic
//! counters), every delivered broadcast is logged, and
//! `--publish-every` periodically broadcasts a smoke payload (its
//! delivery on the far side is the end-to-end datagram proof).
//! SIGTERM/SIGINT stop the loop cleanly. The smoke-test posture:
//! deploy one process per fly machine over the 6pn network, bind the
//! machine's private v6, join at least one node to a seeded peer.

const std = @import("std");
const qmesh = @import("qmesh");
const qmesh_quic = @import("qmesh_quic");
const quic = @import("quic");

const posix = std.posix;

var shutdown_flag = std.atomic.Value(bool).init(false);

fn onSignal(_: posix.SIG) callconv(.c) void {
    shutdown_flag.store(true, .release);
}

/// Wire-level event counters for `--qlog-count` diagnosis: quic sees
/// every packet before the mesh does, so a gap between these and the
/// swim counters localates loss to one half of the seam. Single
/// thread; the callback fires synchronously from the loop.
var wire = struct {
    packet_sent: u64 = 0,
    packet_received: u64 = 0,
    packet_dropped: u64 = 0,
    drop_min_size: u32 = 0,
    drop_max_size: u32 = 0,
    drop_header: u64 = 0,
    drop_decrypt: u64 = 0,
    drop_version: u64 = 0,
    drop_unknown_cid: u64 = 0,
    drop_too_large: u64 = 0,
    drop_reset: u64 = 0,
    drop_keys: u64 = 0,
    drop_other: u64 = 0,
    loss_detected: u64 = 0,
    packets_lost: u64 = 0,
    enabled: bool = false,
}{};

var qlog_dump = false;

fn qlogDumpSink(_: ?*anyopaque, ev: quic.QlogEvent) void {
    wireCountSink(null, ev);
    if (!qlog_dump) return;
    std.debug.print("EV {s} t={d} pn={d} sz={d} det={s}\n", .{
        @tagName(ev.name),
        ev.at_us,
        ev.packet_number orelse 0,
        ev.packet_size orelse 0,
        ev.details,
    });
}

fn wireCountSink(_: ?*anyopaque, ev: quic.QlogEvent) void {
    switch (ev.name) {
        .packet_sent => wire.packet_sent += 1,
        .packet_received => wire.packet_received += 1,
        .packet_dropped => {
            wire.packet_dropped += 1;
            if (ev.packet_size) |sz| {
                if (wire.drop_min_size == 0 or sz < wire.drop_min_size) wire.drop_min_size = sz;
                if (sz > wire.drop_max_size) wire.drop_max_size = sz;
            }
            const r = ev.drop_reason orelse .other;
            switch (r) {
                .header_decode_failure => wire.drop_header += 1,
                .decryption_failure => wire.drop_decrypt += 1,
                .unsupported_version => wire.drop_version += 1,
                .unknown_connection_id => wire.drop_unknown_cid += 1,
                .payload_too_large => wire.drop_too_large += 1,
                .stateless_reset => wire.drop_reset += 1,
                .keys_unavailable => wire.drop_keys += 1,
                .other => wire.drop_other += 1,
            }
        },
        .loss_detected => wire.loss_detected += 1,
        .packet_lost => wire.packets_lost += 1,
        else => {},
    }
}

fn installSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
}

/// Parse `[v6]:port` / `v4:port` into a qmesh.Addr (delegates to the
/// stdlib's IP-literal parser; port 0 is rejected — a mesh node must
/// be dialable).
fn parseAddr(s: []const u8) !qmesh.Addr {
    const ip = std.Io.net.IpAddress.parseLiteral(s) catch return error.BadAddr;
    return switch (ip) {
        .ip4 => |v4| blk: {
            if (v4.port == 0) return error.BadAddr;
            break :blk qmesh.Addr.ipv4(v4.bytes, v4.port);
        },
        .ip6 => |v6| blk: {
            if (v6.port == 0) return error.BadAddr;
            break :blk qmesh.Addr.ipv6(v6.bytes, v6.port);
        },
    };
}

fn idFromHex(hex: []const u8) !qmesh.PeerId {
    var id: qmesh.PeerId = undefined;
    if (hex.len != 64) return error.BadId;
    _ = std.fmt.hexToBytes(&id.bytes, hex) catch return error.BadId;
    return id;
}

/// `<64-hex>:<addr>` join contact.
fn parseJoin(s: []const u8) !qmesh.PeerDesc {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.BadJoin;
    const id = try idFromHex(s[0..colon]);
    // v6 hosts arrive bracketed; the rest of the string after the id's
    // colon is the address.
    const addr = try parseAddr(s[colon + 1 ..]);
    return .{ .id = id, .addr = addr };
}

fn readFileAlloc(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20));
}

/// Resolve PEM material: explicit flag (always a path), else the
/// `env_name` env var holding either a file path or inline PEM
/// (detected by its header). Returns allocator-owned bytes.
fn resolvePem(
    init: std.process.Init,
    alloc: std.mem.Allocator,
    flag_path: ?[]const u8,
    env_name: []const u8,
    err: anyerror,
) ![]u8 {
    if (flag_path) |p| return readFileAlloc(init.io, alloc, p);
    if (init.environ_map.get(env_name)) |v| {
        if (std.mem.startsWith(u8, v, "-----BEGIN")) {
            return alloc.dupe(u8, v);
        }
        return readFileAlloc(init.io, alloc, v);
    }
    return err;
}

/// Flag value with env fallback (`env_name`).
fn flagOrEnv(init: std.process.Init, flag_val: ?[]const u8, env_name: []const u8) ?[]const u8 {
    return flag_val orelse init.environ_map.get(env_name);
}

fn printUsage() void {
    std.debug.print(
        \\usage: qmesh-node --id <64-hex-spki-digest> --bind <[v6]:port|v4:port>
        \\                  --cert <pem> --key <pem> --ca <pem>
        \\                  [--join <64-hex>:<addr>] [--metrics-secs <n>]
        \\                  [--publish-every <secs>]
        \\  (env fallbacks: QMESH_ID, QMESH_BIND, QMESH_JOIN (comma list),
        \\   QMESH_CERT/QMESH_KEY/QMESH_CA (path or inline PEM),
        \\   QMESH_METRICS_SECS, QMESH_PUBLISH_EVERY)
        \\
    , .{});
}

const Runtime = struct {
    runner: *qmesh_quic.Runner,
    next_metrics_us: u64,
    metrics_interval_us: u64,
    /// Periodic smoke broadcast (0 disables).
    publish_interval_us: u64,
    next_publish_us: u64,
    publish_count: u64 = 0,

    fn onIteration(ctx: ?*anyopaque, r: *qmesh_quic.Runner, now_us: u64) anyerror!void {
        _ = r;
        const rt: *Runtime = @ptrCast(@alignCast(ctx.?));
        if (now_us >= rt.next_metrics_us) {
            rt.next_metrics_us = now_us + rt.metrics_interval_us;
            rt.logMetrics();
        }
        if (rt.publish_interval_us > 0 and now_us >= rt.next_publish_us) {
            rt.next_publish_us = now_us + rt.publish_interval_us;
            rt.publish_count += 1;
            var payload_buf: [64]u8 = undefined;
            const payload = std.fmt.bufPrint(&payload_buf, "qmesh-smoke/{d}", .{rt.publish_count}) catch unreachable;
            if (rt.runner.endpoint().publish(payload) != null) {
                std.debug.print("published seq={d}\n", .{rt.publish_count});
            } else {
                std.debug.print("publish failed (payload too large?)\n", .{});
            }
        }
    }

    fn logMetrics(rt: *Runtime) void {
        const m = rt.runner.endpoint().metrics();
        std.debug.print(
            "metrics alive={d} suspect={d} dead={d} active={d} passive={d} ranked={d} eager={d} lazy={d} sess={d} lh={d} rtt_min={d}us rtt_max={d}us " ++
                "probes={d} acks_tx={d} acks_rx={d} suspects={d} confirms={d} frames_tx={d} frames_rx={d} sends_failed={d} closes={d}\n",
            .{
                m.mesh.swim.members_alive,      m.mesh.swim.members_suspect,
                m.mesh.swim.members_dead,       m.mesh.overlay.active,
                m.mesh.overlay.passive,         m.mesh.overlay.ranked,
                m.mesh.broadcast.eager_peers,   m.mesh.broadcast.lazy_peers,
                m.transport.established,        m.mesh.swim.local_health,
                m.mesh.swim.rtt_min_us,         m.mesh.swim.rtt_max_us,
                m.mesh.swim.probes_sent,        m.mesh.swim.acks_sent,
                m.mesh.swim.acks_received,      m.mesh.swim.suspects_declared,
                m.mesh.swim.confirms_declared,  m.mesh.driver.frames_sent,
                m.mesh.driver.frames_received,  m.mesh.driver.sends_failed,
                m.transport.sessions_closed,
            },
        );
        std.debug.print("transport sessrec={d} shed={d} ep_dgram_rx={d} decode_err={d} unknown_proto={d}\n", .{ m.transport.session_records, m.transport.datagrams_shed, m.transport.datagrams_received, m.mesh.driver.decode_errors, m.mesh.driver.unknown_protocol });
        if (wire.enabled) {
            std.debug.print(
                "wire pkt_tx={d} pkt_rx={d} dropped={d} [hdr={d} dec={d} ver={d} cid={d} big={d} rst={d} keys={d} other={d} sz={d}-{d}] loss_ev={d} lost={d}\n",
                .{ wire.packet_sent, wire.packet_received, wire.packet_dropped, wire.drop_header, wire.drop_decrypt, wire.drop_version, wire.drop_unknown_cid, wire.drop_too_large, wire.drop_reset, wire.drop_keys, wire.drop_other, wire.drop_min_size, wire.drop_max_size, wire.loss_detected, wire.packets_lost },
            );
        }
    }

    fn onBroadcast(ctx: ?*anyopaque, origin: qmesh.PeerId, seq: u64, payload: []const u8) void {
        _ = ctx;
        const origin_hex = origin.hex();
        std.debug.print("broadcast origin={s} seq={d} payload={s}\n", .{ origin_hex, seq, payload });
    }
};

pub fn main(init: std.process.Init) !void {
    // Init's gpa is the toolchain-sanctioned general-purpose allocator
    // (leak-checked in Debug); the runner keeps it for session churn,
    // config buffers are freed explicitly below.
    const alloc = init.gpa;

    var id_hex: ?[]const u8 = null;
    var bind_str: ?[]const u8 = null;
    var cert_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var ca_path: ?[]const u8 = null;
    var metrics_secs: u64 = 10;
    var publish_secs: u64 = 0;
    var pmtu_max: u16 = 1380;
    var qlog_count = false;
    var joins_buf: [8]qmesh.PeerDesc = undefined;
    var joins_len: usize = 0;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args.deinit();
    _ = args.next(); // argv0
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--id")) {
            id_hex = args.next() orelse return badFlag("--id needs a value");
        } else if (std.mem.eql(u8, arg, "--bind")) {
            bind_str = args.next() orelse return badFlag("--bind needs a value");
        } else if (std.mem.eql(u8, arg, "--cert")) {
            cert_path = args.next() orelse return badFlag("--cert needs a path");
        } else if (std.mem.eql(u8, arg, "--key")) {
            key_path = args.next() orelse return badFlag("--key needs a path");
        } else if (std.mem.eql(u8, arg, "--ca")) {
            ca_path = args.next() orelse return badFlag("--ca needs a path");
        } else if (std.mem.eql(u8, arg, "--join")) {
            const j = args.next() orelse return badFlag("--join needs <id>:<addr>");
            if (joins_len == joins_buf.len) return error.TooManyJoins;
            joins_buf[joins_len] = try parseJoin(j);
            joins_len += 1;
        } else if (std.mem.eql(u8, arg, "--metrics-secs")) {
            const v = args.next() orelse return badFlag("--metrics-secs needs a number");
            metrics_secs = std.fmt.parseInt(u64, v, 10) catch return error.BadMetricsSecs;
        } else if (std.mem.eql(u8, arg, "--publish-every")) {
            const v = args.next() orelse return badFlag("--publish-every needs a number");
            publish_secs = std.fmt.parseInt(u64, v, 10) catch return error.BadPublishSecs;
        } else if (std.mem.eql(u8, arg, "--pmtu-max")) {
            const v = args.next() orelse return badFlag("--pmtu-max needs a number");
            pmtu_max = std.fmt.parseInt(u16, v, 10) catch return error.BadPmtuMax;
        } else if (std.mem.eql(u8, arg, "--qlog-count")) {
            qlog_count = true;
        } else if (std.mem.eql(u8, arg, "--qlog-dump")) {
            qlog_dump = true;
            qlog_count = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            printUsage();
            return error.BadFlag;
        }
    }

    // Env fallbacks (fly machine env / secrets posture).
    if (init.environ_map.get("QMESH_METRICS_SECS")) |v| {
        metrics_secs = std.fmt.parseInt(u64, v, 10) catch return error.BadMetricsSecs;
    }
    if (init.environ_map.get("QMESH_PUBLISH_EVERY")) |v| {
        publish_secs = std.fmt.parseInt(u64, v, 10) catch return error.BadPublishSecs;
    }
    if (init.environ_map.get("QMESH_PMTU_MAX")) |v| {
        pmtu_max = std.fmt.parseInt(u16, v, 10) catch return error.BadPmtuMax;
    }
    if (init.environ_map.get("QMESH_QLOG_COUNT")) |v| {
        qlog_count = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    if (joins_len == 0) {
        if (init.environ_map.get("QMESH_JOIN")) |joined| {
            var it = std.mem.splitScalar(u8, joined, ',');
            while (it.next()) |j| {
                if (j.len == 0) continue;
                if (joins_len == joins_buf.len) return error.TooManyJoins;
                joins_buf[joins_len] = try parseJoin(j);
                joins_len += 1;
            }
        }
    }

    const id = try idFromHex(flagOrEnv(init, id_hex, "QMESH_ID") orelse {
        printUsage();
        return error.MissingId;
    });
    const bind = try parseAddr(flagOrEnv(init, bind_str, "QMESH_BIND") orelse {
        printUsage();
        return error.MissingBind;
    });
    const cert = try resolvePem(init, alloc, cert_path, "QMESH_CERT", error.MissingCert);
    defer alloc.free(cert);
    const key = try resolvePem(init, alloc, key_path, "QMESH_KEY", error.MissingKey);
    defer alloc.free(key);
    const ca = try resolvePem(init, alloc, ca_path, "QMESH_CA", error.MissingCa);
    defer alloc.free(ca);

    installSignalHandlers();
    wire.enabled = qlog_count;

    const profile = qmesh.profiles.fly_multi_region;
    var rt_storage: Runtime = undefined;
    const runner = try qmesh_quic.Runner.init(alloc, .{
        .endpoint = .{
            .self = .{ .id = id, .addr = bind },
            .tls_cert_pem = cert,
            .tls_key_pem = key,
            .ca_pem = ca,
            .dial_server_name = "qmesh",
            .pmtu_max = pmtu_max,
            .qlog_callback = if (qlog_dump or qlog_count) qlogDumpSink else null,
            .qlog_packet_events = qlog_count,
            .overlay_cfg = profile.overlay,
            .swim_cfg = profile.swim,
            .broadcast_cfg = profile.broadcast,
            .hooks = .{ .ctx = null, .onBroadcast = Runtime.onBroadcast },
        },
        .bind = bind,
        .on_iteration = Runtime.onIteration,
        .on_iteration_ctx = &rt_storage,
        .shutdown = &shutdown_flag,
    });
    defer runner.deinit();
    rt_storage = .{
        .runner = runner,
        .next_metrics_us = 0,
        .metrics_interval_us = metrics_secs * std.time.us_per_s,
        .publish_interval_us = publish_secs * std.time.us_per_s,
        .next_publish_us = 0,
    };

    const id_hex_str = id.hex();
    std.debug.print("qmesh-node id={s} joins={d} metrics every {d}s\n", .{ id_hex_str[0..], joins_len, metrics_secs });
    for (joins_buf[0..joins_len]) |contact| {
        runner.endpoint().startJoin(contact);
    }

    try runner.run();
    std.debug.print("qmesh-node stopped\n", .{});
}

fn badFlag(msg: []const u8) anyerror {
    std.debug.print("{s}\n", .{msg});
    printUsage();
    return error.BadFlag;
}
