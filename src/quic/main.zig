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
//! Usage:
//!
//!   qmesh-node --id <64-hex> --bind '[fdxx::1]:4451' \
//!              --cert node.pem --key node.key --ca ca.pem \
//!              [--join <64-hex>:<addr> ...] [--metrics-secs 10]
//!
//! Runtime observability: a compact metrics line on stderr every
//! `--metrics-secs` (gauges: member states, views, tree shape,
//! sessions, Lifeguard health; plus monotonic counters), and every
//! delivered broadcast is logged. SIGTERM/SIGINT stop the loop
//! cleanly. The smoke-test posture: deploy one process per fly
//! machine over the 6pn network, point --bind at the machine's
//! private v6, join at least one node to a seeded peer.

const std = @import("std");
const qmesh = @import("qmesh");
const qmesh_quic = @import("qmesh_quic");

const posix = std.posix;

var shutdown_flag = std.atomic.Value(bool).init(false);

fn onSignal(_: posix.SIG) callconv(.c) void {
    shutdown_flag.store(true, .release);
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

fn printUsage() void {
    std.debug.print(
        \\usage: qmesh-node --id <64-hex-spki-digest> --bind <[v6]:port|v4:port>
        \\                  --cert <pem> --key <pem> --ca <pem>
        \\                  [--join <64-hex>:<addr>] [--metrics-secs <n>]
        \\
    , .{});
}

const Runtime = struct {
    runner: *qmesh_quic.Runner,
    next_metrics_us: u64,
    interval_us: u64,

    fn onIteration(ctx: ?*anyopaque, r: *qmesh_quic.Runner, now_us: u64) anyerror!void {
        _ = r;
        const rt: *Runtime = @ptrCast(@alignCast(ctx.?));
        if (now_us < rt.next_metrics_us) return;
        rt.next_metrics_us = now_us + rt.interval_us;
        const m = rt.runner.endpoint().metrics();
        std.debug.print(
            "metrics alive={d} suspect={d} dead={d} active={d} passive={d} ranked={d} eager={d} lazy={d} sess={d} lh={d} " ++
                "probes={d} suspects={d} confirms={d} frames_tx={d} frames_rx={d} sends_failed={d} closes={d}\n",
            .{
                m.mesh.swim.members_alive,      m.mesh.swim.members_suspect,
                m.mesh.swim.members_dead,       m.mesh.overlay.active,
                m.mesh.overlay.passive,         m.mesh.overlay.ranked,
                m.mesh.broadcast.eager_peers,   m.mesh.broadcast.lazy_peers,
                m.transport.established,        m.mesh.swim.local_health,
                m.mesh.swim.probes_sent,        m.mesh.swim.suspects_declared,
                m.mesh.swim.confirms_declared,  m.mesh.driver.frames_sent,
                m.mesh.driver.frames_received,  m.mesh.driver.sends_failed,
                m.transport.sessions_closed,
            },
        );
    }

    fn onBroadcast(ctx: ?*anyopaque, origin: qmesh.PeerId, seq: u64, payload: []const u8) void {
        _ = ctx;
        const origin_hex = origin.hex();
        std.debug.print("broadcast origin={s} seq={d} len={d}\n", .{ origin_hex, seq, payload.len });
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
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            printUsage();
            return error.BadFlag;
        }
    }

    const id = try idFromHex(id_hex orelse {
        printUsage();
        return error.MissingId;
    });
    const bind = try parseAddr(bind_str orelse {
        printUsage();
        return error.MissingBind;
    });
    const cert = try readFileAlloc(init.io, alloc, cert_path orelse return error.MissingCert);
    defer alloc.free(cert);
    const key = try readFileAlloc(init.io, alloc, key_path orelse return error.MissingKey);
    defer alloc.free(key);
    const ca = try readFileAlloc(init.io, alloc, ca_path orelse return error.MissingCa);
    defer alloc.free(ca);

    installSignalHandlers();

    const profile = qmesh.profiles.fly_multi_region;
    var rt_storage: Runtime = undefined;
    const runner = try qmesh_quic.Runner.init(alloc, .{
        .endpoint = .{
            .self = .{ .id = id, .addr = bind },
            .tls_cert_pem = cert,
            .tls_key_pem = key,
            .ca_pem = ca,
            .dial_server_name = "qmesh",
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
        .interval_us = metrics_secs * std.time.us_per_s,
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
