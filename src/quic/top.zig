//! qmesh-top: the backend-less fleet console (Concept 1 slice,
//! docs/observability-ux.md). Attaches to qmesh-node control sockets,
//! asks each for its stats line, and renders live fleet cards with a
//! completeness line — nodes that don't answer inside the window are
//! the story. Anywhere you can reach one node, you have fleet sight.
//!
//! Usage: qmesh-top '[::1]:5901' '[::1]:5902' ...   (refresh 2s)

const std = @import("std");
const posix = std.posix;

fn die(comptime msg: []const u8) noreturn {
    std.debug.print(msg ++ "\n", .{});
    std.process.exit(1);
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

    // One UDP socket for all queries; 750ms reply window.
    const sock = posix.system.socket(posix.AF.INET6, posix.SOCK.DGRAM, @intCast(posix.IPPROTO.UDP));
    if (posix.errno(sock) != .SUCCESS) die("socket failed");
    const fd: posix.socket_t = @intCast(sock);
    const tv = posix.timeval{ .sec = 0, .usec = 750_000 };
    _ = posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &tv, @sizeOf(posix.timeval));

    var round: usize = 0;
    while (true) {
        // Ask everyone.
        for (targets[0..n_targets]) |t| {
            const host_end = if (t[0] == '[') std.mem.indexOfScalar(u8, t, ']') orelse continue else std.mem.lastIndexOfScalar(u8, t, ':') orelse continue;
            const port_str = if (t[0] == '[') t[host_end + 2 ..] else t[host_end + 1 ..];
            const port = std.fmt.parseInt(u16, port_str, 10) catch continue;
            var sa: posix.sockaddr.in6 = std.mem.zeroes(posix.sockaddr.in6);
            sa.family = posix.AF.INET6;
            sa.port = std.mem.nativeToBig(u16, port);
            const host = if (t[0] == '[') t[1..host_end] else t[0..host_end];
            if (!std.mem.eql(u8, host, "::1")) continue; // slice: loopback v6 only for now
            @memcpy(&sa.addr, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
            _ = posix.system.sendto(fd, "stats", 5, 0, @ptrCast(&sa), @sizeOf(posix.sockaddr.in6));
        }
        // Collect replies until the window closes.
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
        // Render.
        std.debug.print("\x1b[2J\x1b[H", .{});
        std.debug.print("qmesh top · {d} node(s) · refresh 2s · round {d}\n", .{ n_targets, round });
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
        round += 1;
        var req: std.c.timespec = .{ .sec = 2, .nsec = 0 };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}
