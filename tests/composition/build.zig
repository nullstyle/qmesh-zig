const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const qmesh = b.dependency("qmesh", .{ .target = target, .optimize = optimize });
    const qmsg = b.dependency("qmsg", .{ .target = target, .optimize = optimize });

    // Workspace-only validation of coordinated unpublished changes. The
    // libraries retain their released URL/hash pins. Also test with
    // -Dlocal-quic=false to exercise their shared released dependency.
    const local_quic = b.option(bool, "local-quic", "Use the sibling quic-zig checkout") orelse true;
    if (local_quic) {
        const quic = b.dependency("quic", .{ .target = target, .@"sanitize-c" = @as([]const u8, "trap") });
        qmesh.module("qmesh_quic").addImport("quic", quic.module("quic"));
        qmsg.module("qmsg").addImport("quic", quic.module("quic"));
    }

    const mod = b.createModule(.{
        .root_source_file = b.path("../composition_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("qmesh", qmesh.module("qmesh"));
    mod.addImport("qmesh_quic", qmesh.module("qmesh_quic"));
    mod.addImport("qmesh_messaging", qmesh.module("qmesh_messaging"));
    mod.addImport("qmsg", qmsg.module("qmsg"));
    const tests = b.addTest(.{ .root_module = mod });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test mesh discovery and qmsg exchanges/reconnect over real QUIC");
    step.dependOn(&run.step);
    const qmsg_tests = b.addTest(.{ .root_module = qmsg.module("qmsg") });
    const qmsg_step = b.step("test-qmsg", "Run qmsg's module tests with the selected QUIC implementation");
    qmsg_step.dependOn(&b.addRunArtifact(qmsg_tests).step);
    b.default_step = step;
}
