//! qmesh-top: the backend-less fleet console (docs/observability-ux.md).
//! Attaches to qmesh-node control sockets anywhere the network reaches
//! one node, and renders two views per round:
//!
//! * fleet cards — the `stats` line of every node that answers, with a
//!   completeness line (nodes that don't answer inside the window are
//!   the story);
//! * the incident timeline — every node's `events` ring dump, merged
//!   across nodes on wall clock (each reply pairs the node's monotonic
//!   ring clock with unix-epoch now, so per-process origins cancel) and
//!   rendered newest-first: membership transitions, Lifeguard changes,
//!   session churn, and broadcast repairs in one causal view —
//!   Concept 2's data, live.
//!
//! Usage: qmesh-top '[::1]:5901' '[::1]:5902' ...   (refresh ~3.5s)

const std = @import("std");
const posix = std.posix;

fn die(comptime msg: []const u8) noreturn {
    std.debug.print(msg ++ "\n", .{});
    std.process.exit(1);
}

fn parseU64(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// One timeline entry, mapped onto wall clock at collection time.
const Ev = struct {
    wall_us: u64,
    node: [8]u8,
    tail: [72]u8 = undefined,
    tail_len: usize = 0,
};

fn fmtUtc(us: u64, buf: []u8) []const u8 {
    const secs = us / std.time.us_per_s;
    const ms = (us % std.time.us_per_s) / std.time.ns_per_ms;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        (secs / 3600) % 24,
        (secs / 60) % 60,
        secs % 60,
        ms,
    }) catch "??:??:??.???";
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args.deinit();
    _ = args.next();

    var targets: [16][]const u8 = undefined;
    var n_targets: usize = 0;
    while (args.next()) |a| {
        if (n_targets == targets.len) die("too many targets (max 16)");
        targets[n_targets] = a;
        n_targets += 1;
    }
    if (n_targets == 0) die("usage: qmesh-top '[v6]:port' ...");

    // One UDP socket for all queries; 750ms reply window per phase.
    const sock = posix.system.socket(posix.AF.INET6, posix.SOCK.DGRAM, @intCast(posix.IPPROTO.UDP));
    if (posix.errno(sock) != .SUCCESS) die("socket failed");
    const fd: posix.socket_t = @intCast(sock);
    const tv = posix.timeval{ .sec = 0, .usec = 750_000 };
    _ = posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(posix.timeval));

    var round: usize = 0;
    while (true) {
        // Phase 1: fleet cards (stats).
        for (targets[0..n_targets]) |t| {
            const ip = std.Io.net.IpAddress.parseLiteral(t) catch continue;
            switch (ip) {
                .ip6 => |v6| {
                    var sa: posix.sockaddr.in6 = std.mem.zeroes(posix.sockaddr.in6);
                    sa.family = posix.AF.INET6;
                    sa.port = std.mem.nativeToBig(u16, v6.port);
                    sa.addr = v6.bytes;
                    _ = posix.system.sendto(fd, "stats", 5, 0, @ptrCast(&sa), @sizeOf(posix.sockaddr.in6));
                },
                .ip4 => continue, // slice: v6 literals only
            }
        }
        var answered: usize = 0;
        var lines: [16][256]u8 = undefined;
        var lens: [16]usize = @splat(0);
        while (answered < n_targets) {
            var buf: [256]u8 = undefined;
            const rc = posix.system.recvfrom(fd, &buf, buf.len, 0, null, null);
            if (posix.errno(rc) != .SUCCESS) break; // timeout: completeness time
            const n: usize = @intCast(rc);
            if (n == 0 or answered >= lines.len) continue;
            @memcpy(lines[answered][0..n], buf[0..n]);
            lens[answered] = n;
            answered += 1;
        }

        // Phase 2: incident timeline (events) — merged on wall clock.
        for (targets[0..n_targets]) |t| {
            const ip = std.Io.net.IpAddress.parseLiteral(t) catch continue;
            switch (ip) {
                .ip6 => |v6| {
                    var sa: posix.sockaddr.in6 = std.mem.zeroes(posix.sockaddr.in6);
                    sa.family = posix.AF.INET6;
                    sa.port = std.mem.nativeToBig(u16, v6.port);
                    sa.addr = v6.bytes;
                    _ = posix.system.sendto(fd, "events", 6, 0, @ptrCast(&sa), @sizeOf(posix.sockaddr.in6));
                },
                .ip4 => continue,
            }
        }
        var timeline: [384]Ev = undefined;
        var n_evs: usize = 0;
        var ev_answers: usize = 0;
        while (ev_answers < n_targets) {
            var buf: [1280]u8 = undefined;
            const rc = posix.system.recvfrom(fd, &buf, buf.len, 0, null, null);
            if (posix.errno(rc) != .SUCCESS) break;
            const n: usize = @intCast(rc);
            if (n == 0) continue;
            ev_answers += 1;
            n_evs = parseEventsReply(buf[0..n], &timeline, n_evs);
        }
        // Newest first (insertion sort: n is at most a few hundred).
        var i: usize = 1;
        while (i < n_evs) : (i += 1) {
            const e = timeline[i];
            var j = i;
            while (j > 0 and timeline[j - 1].wall_us < e.wall_us) : (j -= 1) {
                timeline[j] = timeline[j - 1];
            }
            timeline[j] = e;
        }

        // Render.
        std.debug.print("\x1b[2J\x1b[H", .{});
        std.debug.print("qmesh top · {d} node(s) · round {d}\n", .{ n_targets, round });
        std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
        for (lines[0..answered], 0..) |l, li| {
            std.debug.print("{s}\n", .{l[0..lens[li]]});
        }
        std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
        if (answered == n_targets) {
            std.debug.print("completeness: {d}/{d} answered\n", .{ answered, n_targets });
        } else {
            std.debug.print("completeness: {d}/{d} answered — {d} silent (suspect/down; their data anti-entropies in when they resume)\n", .{ answered, n_targets, n_targets - answered });
        }
        const show = @min(n_evs, 15);
        std.debug.print("recent fleet events (merged, UTC) · {d} collected\n", .{n_evs});
        if (show == 0) {
            std.debug.print("  (no events reported — steady state)\n", .{});
        }
        for (timeline[0..show]) |e| {
            var tbuf: [16]u8 = undefined;
            std.debug.print("  {s} {s} {s}\n", .{
                fmtUtc(e.wall_us, &tbuf),
                e.node[0..],
                e.tail[0..e.tail_len],
            });
        }
        round += 1;
        var req: std.c.timespec = .{ .sec = 2, .nsec = 0 };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

/// Parse one `events` reply into `out` (header line first, then
/// `t=<us> <text>` lines), mapping each event onto wall clock via the
/// header's mono/wall pairing. Returns the new fill level.
fn parseEventsReply(reply: []const u8, out: []Ev, fill: usize) usize {
    var n = fill;
    const header_end = std.mem.indexOfScalar(u8, reply, '\n') orelse return n;
    var hit = std.mem.tokenizeAny(u8, reply[0..header_end], " ");
    _ = hit.next(); // "events"
    var node: [8]u8 = @splat('.');
    var mono: u64 = 0;
    var wall: u64 = 0;
    while (hit.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "id=")) {
            const v = tok[3..];
            const c = @min(v.len, node.len);
            @memcpy(node[0..c], v[0..c]);
        } else if (std.mem.startsWith(u8, tok, "mono=")) {
            mono = parseU64(tok[5..]) orelse 0;
        } else if (std.mem.startsWith(u8, tok, "wall=")) {
            wall = parseU64(tok[5..]) orelse 0;
        }
    }
    var rest = reply[header_end + 1 ..];
    while (rest.len > 0) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..line_end];
        rest = if (line_end < rest.len) rest[line_end + 1 ..] else rest[0..0];
        if (n == out.len) break;
        if (!std.mem.startsWith(u8, line, "t=")) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const at = parseU64(line[2..sp]) orelse continue;
        // wall_now - (mono_now - at): the event's wall-clock instant.
        const delta = mono -| at;
        var ev: Ev = .{ .wall_us = wall -| delta, .node = node };
        const tail = line[sp + 1 ..];
        const c = @min(tail.len, ev.tail.len);
        @memcpy(ev.tail[0..c], tail[0..c]);
        ev.tail_len = c;
        out[n] = ev;
        n += 1;
    }
    return n;
}
