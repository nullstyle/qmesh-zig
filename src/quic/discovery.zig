//! LAN peer discovery for qmesh-node (`--mdns`): the mdns-zig glue of
//! its docs/integration.md section 3, in one place so the node binary
//! and tests/mdns_discovery_test.zig drive the same code.
//!
//! Development-only. This file is the root of the `qmesh_mdns` module
//! that build.zig creates after the dependency-build early return —
//! no library module imports it, and a consumer that fetched qmesh
//! never downloads mdns-zig (the `.lazy` pin in build.zig.zon).
//!
//! Two `mdns.Service`s, in order, because one Service binds to one
//! clock source for life (mdns-zig section 1 of that guide):
//!
//! 1. Start-up seeds: a short-lived Service does one bounded `lookup`
//!    of `_qmesh._udp` (mode B, its own clock), every result goes
//!    through the `SeedSet`, and each admitted contact is joined the
//!    way `--join` joins — `Endpoint.startJoin`. That Service is
//!    gone before the next exists.
//! 2. The long-lived Service is ticked from `Runner.Options.
//!    on_iteration` with the runner's clock (mode A): it advertises
//!    this node (`_qmesh._udp`, instance = first 16 hex of the PeerId
//!    or `--name`, TXT `id`/`epoch`) and browses; every `resolved`
//!    goes through the same `SeedSet`, so a seed found at start-up is
//!    not joined again a second later, and a peer that re-announces
//!    with a new `epoch` (it restarted) is joined again.
//!
//! The TXT `id` is an unauthenticated selector only: it says which
//! PeerId to expect at that address, and the pinned-CA mTLS handshake
//! plus HELLO (src/quic/hello.zig) is the proof, exactly as for a
//! `--join` contact typed by an operator. A forged advert costs one
//! failed dial. `Addr.fromIp` drops link-local v6 (no scope field, and
//! the socket loop sends scope id 0), counted in `Stats.skipped_addr`.
//!
//! Multicast does not exist on fly 6pn, so this is a LAN and dev
//! convenience, not the production bootstrap; `--join` / QMESH_JOIN
//! remains that.

const std = @import("std");
const qmesh = @import("qmesh");
const qmesh_quic = @import("qmesh_quic");
const mdns = @import("mdns");

const Io = std.Io;
const profile = mdns.profiles.qmesh;

pub const service_type = profile.service_type;
pub const SeedSet = profile.SeedSet;

pub const Options = struct {
    /// First label of the mDNS host name (`<host_label>.local`); the
    /// node binary passes the first 16 hex of its PeerId.
    host_label: []const u8,
    /// Instance label to advertise under, or null for the first 16
    /// hex of the PeerId (the `_qmesh._udp` default).
    instance: ?[]const u8 = null,
    /// Bounds of the start-up seed lookup; zero timeout skips it.
    lookup_timeout_us: u64 = 3 * std.time.us_per_s,
    lookup_quiet_us: u64 = 500 * std.time.us_per_ms,
    /// Forwarded to `mdns.Service.Options` (tests pin the loopback
    /// interface so nothing reaches the LAN).
    ipv6: bool = true,
    include_loopback: bool = false,
    interfaces: ?[]const u32 = null,
    /// `mdns ...` lines on stderr for every join and warning (the
    /// node binary's log level; tests silence it).
    log: bool = true,
};

pub const Stats = struct {
    /// `resolved` results the start-up lookup returned.
    seeds_found: usize = 0,
    /// Contacts handed to `startJoin` (lookup + browse).
    joined: u64 = 0,
    /// Our own advert echoed back (multicast loopback).
    skipped_self: u64 = 0,
    /// Admitted contacts `Addr.fromIp` could not carry.
    skipped_addr: u64 = 0,
    /// `Service.updateTxt` calls after a `boot_epoch` change.
    epoch_updates: u64 = 0,
};

pub const Discovery = struct {
    const Self = @This();

    svc: mdns.Service,
    seeds: SeedSet = .{},
    /// Keep in place: `desc()` / `txt()` return slices into it.
    ad: profile.Advert,
    reg: mdns.RegId,
    /// The `boot_epoch` last advertised; `tick` re-announces on change.
    epoch: u128,
    self_id: qmesh.PeerId,
    opts: Options,
    stats: Stats = .{},

    pub const InitError = mdns.Service.InitError || mdns.Service.LookupError ||
        mdns.Service.BrowseError || mdns.Service.AdvertiseError || profile.InitError;

    /// Seed lookup, then the long-lived Service. `runner` must be
    /// initialized (its bound port is advertised) and not yet running;
    /// the seed joins are queued on its endpoint like `--join` contacts
    /// and driven by the first iteration. Wire the result as
    /// `Runner.Options.on_iteration` through `tick`.
    pub fn init(gpa: std.mem.Allocator, io: Io, runner: *qmesh_quic.Runner, opts: Options) InitError!Self {
        const ep = runner.endpoint();
        var d: Self = .{
            .svc = undefined,
            .ad = undefined,
            .reg = undefined,
            .epoch = ep.node.broadcast.boot_epoch,
            .self_id = ep.opts.self.id,
            .opts = opts,
        };
        if (opts.lookup_timeout_us > 0) try d.seedLookup(gpa, io, runner);

        d.svc = try mdns.Service.init(gpa, io, d.serviceOptions());
        errdefer d.svc.deinit();
        _ = try d.svc.browse(service_type);
        d.ad = try profile.Advert.init(.{
            .instance = opts.instance,
            .port = portOf(runner.localAddress()),
            .id = d.self_id.bytes,
            .epoch = d.epoch,
        });
        d.reg = try d.svc.advertise(d.ad.desc());
        if (opts.log) {
            std.debug.print("mdns advertising {s}.{s}.local port={d} host={s}.local on {d} interface(s), seeds joined={d}\n", .{
                d.ad.instanceLabel(), service_type, d.ad.port, opts.host_label, d.svc.interfaces().len, d.stats.joined,
            });
        }
        return d;
    }

    /// Goodbye for our advert, sockets closed.
    pub fn deinit(d: *Self) void {
        d.svc.deinit();
    }

    /// One `on_iteration` pass: re-announce a changed `boot_epoch`,
    /// tick the Service with the runner's clock, admit every
    /// `resolved` through the `SeedSet` and join the new contacts.
    pub fn tick(d: *Self, runner: *qmesh_quic.Runner, now_us: u64) !void {
        const epoch = runner.endpoint().node.broadcast.boot_epoch;
        if (epoch != d.epoch) {
            d.epoch = epoch;
            d.ad.setEpoch(epoch);
            try d.svc.updateTxt(d.reg, d.ad.txt());
            d.stats.epoch_updates += 1;
        }
        try d.svc.tick(now_us);
        var evs: [8]mdns.Event = undefined;
        while (true) {
            const n = d.svc.poll(&evs);
            if (n == 0) break;
            for (evs[0..n]) |*ev| switch (ev.*) {
                .resolved => |*r| d.admit(runner, r),
                .renamed => |r| if (d.opts.log) std.debug.print("mdns renamed {f} -> {f}\n", .{ r.old, r.new }),
                .host_renamed => |h| if (d.opts.log) std.debug.print("mdns host renamed {f} -> {f}\n", .{ h.old, h.new }),
                .warning => |w| if (d.opts.log) switch (w) {
                    .join_failed => |j| std.debug.print("mdns warning join_failed ifindex={d} family={t}\n", .{ j.ifindex, j.family }),
                    .addrs_truncated => |a| std.debug.print("mdns warning addrs_truncated ifindex={d} family={t}\n", .{ a.ifindex, a.family }),
                    else => std.debug.print("mdns warning {t}\n", .{w}),
                },
                else => {},
            };
        }
    }

    /// The `on_iteration` shape, for embedders that need nothing else
    /// per pass; qmesh-node wraps it in its own callback.
    pub fn onIteration(ctx: ?*anyopaque, runner: *qmesh_quic.Runner, now_us: u64) anyerror!void {
        const d: *Self = @ptrCast(@alignCast(ctx.?));
        try d.tick(runner, now_us);
    }

    fn serviceOptions(d: *const Self) mdns.Service.Options {
        return .{
            .host_label = d.opts.host_label,
            .ipv6 = d.opts.ipv6,
            .include_loopback = d.opts.include_loopback,
            .interfaces = d.opts.interfaces,
        };
    }

    /// Mode B on a Service of its own, gone before the mode-A one is
    /// created. No seeds is not an error (the mesh can be joined by
    /// `--join` as well); a cancelation is.
    fn seedLookup(d: *Self, gpa: std.mem.Allocator, io: Io, runner: *qmesh_quic.Runner) InitError!void {
        var boot = try mdns.Service.init(gpa, io, d.serviceOptions());
        defer boot.deinit();
        var found: [16]mdns.Resolved = undefined;
        const n = boot.lookup(service_type, .{
            .timeout_us = d.opts.lookup_timeout_us,
            .quiet_us = d.opts.lookup_quiet_us,
        }, &found) catch |err| switch (err) {
            error.Canceled => return err,
            else => blk: {
                if (d.opts.log) std.debug.print("mdns seed lookup failed: {t}\n", .{err});
                break :blk 0;
            },
        };
        d.stats.seeds_found = n;
        for (found[0..n]) |*r| d.admit(runner, r);
    }

    /// One `resolved` through the `SeedSet`: at most one join per
    /// `(id, epoch)`, never ourselves, never an address `Addr` cannot
    /// carry. A `resolved` is per interface, so a peer heard first on
    /// an interface that only gives it a link-local v6 must not use up
    /// its `(id, epoch)` admission: the set forgets it again, and the
    /// next interface's `resolved` (v4, a global v6) is admitted.
    ///
    /// Public so tests/mdns_discovery_test.zig can feed hand-built
    /// `Resolved` values without a second Service.
    pub fn admit(d: *Self, runner: *qmesh_quic.Runner, r: *const mdns.Resolved) void {
        const c = d.seeds.accept(r) orelse return;
        const id: qmesh.PeerId = .{ .bytes = c.id };
        if (id.eql(d.self_id)) {
            d.stats.skipped_self += 1;
            return;
        }
        const addr = qmesh.Addr.fromIp(c.addr) orelse {
            d.stats.skipped_addr += 1;
            _ = d.seeds.forget(c.id);
            if (d.opts.log) {
                const hex = id.hex();
                std.debug.print("mdns skip id={s} addr={f} (link-local v6 needs a scope Addr cannot carry)\n", .{ hex[0..16], c.addr });
            }
            return;
        };
        runner.endpoint().startJoin(.{ .id = id, .addr = addr });
        d.stats.joined += 1;
        if (d.opts.log) {
            const hex = id.hex();
            std.debug.print("mdns join id={s} addr={f} epoch={x} ifindex={d}\n", .{ hex[0..16], c.addr, c.epoch, c.ifindex });
        }
    }
};

fn portOf(a: qmesh.Addr) u16 {
    return switch (a) {
        .v4 => |v| v.port,
        .v6 => |v| v.port,
        .none => 0,
    };
}
