const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const qmsg = b.dependency("qmsg", .{ .target = target, .optimize = optimize });
    if (b.option(bool, "selected", "Inject selected QUIC into qmsg") orelse false) {
        const quic = b.dependency("quic", .{ .target = target, .release = optimize != .debug, .@"sanitize-c" = @as([]const u8, "trap") });
        qmsg.module("qmsg").addImport("quic", quic.module("quic"));
    }
    const mod = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    mod.addImport("qmsg", qmsg.module("qmsg"));
    mod.addImport("quic", qmsg.module("qmsg").import_table.get("quic").?);
    const exe = b.addExecutable(.{ .name = "application-profile", .root_module = mod });
    b.installArtifact(exe);
}
