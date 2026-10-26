const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const qmesh = b.dependency("qmesh", .{ .target = target, .optimize = optimize });
    const qmsg = b.dependency("qmsg", .{ .target = target, .optimize = optimize });

    // Controlled-source validation: inject one exact QUIC module into
    // both consumers. The default source is pinned in this package;
    // tools/check-composition.py can select a working tree or archive.
    // -Dlocal-quic=false exercises each consumer's native released pin.
    // Retain the option name for existing local development commands.
    const local_quic = b.option(bool, "local-quic", "Inject this package's selected QUIC source into both consumers") orelse true;
    if (local_quic) {
        const quic = b.dependency("quic", .{ .target = target, .release = optimize != .debug, .@"sanitize-c" = @as([]const u8, "trap") });
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

    // Opt-in because the immutable baseline qmsg pin predates QuicSocket.
    // The composition wrapper selects a Sprint 2 qmsg source explicitly.
    const public_mod = b.createModule(.{
        .root_source_file = b.path("../sprint2_composition_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    public_mod.addImport("qmesh", qmesh.module("qmesh"));
    public_mod.addImport("qmesh_quic", qmesh.module("qmesh_quic"));
    public_mod.addImport("qmsg", qmsg.module("qmsg"));
    const public_tests = b.addTest(.{ .root_module = public_mod });
    const public_step = b.step("test-sprint2", "Test public messaging sockets alongside deadline-driven mesh runners");
    public_step.dependOn(&b.addRunArtifact(public_tests).step);

    const qmsg_tests = b.addTest(.{ .root_module = qmsg.module("qmsg") });
    const qmsg_step = b.step("test-qmsg", "Run qmsg unit, QUIC runtime, and real-UDP pair tests with the selected QUIC implementation");
    qmsg_step.dependOn(&b.addRunArtifact(qmsg_tests).step);

    // qmsg's root module alone omits these executable test roots.
    // Reuse the actual imported modules after the selected QUIC override.
    const qmsg_module = qmsg.module("qmsg");
    const runtime_mod = b.createModule(.{
        .root_source_file = qmsg.path("src/quic_transport_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_mod.addImport("quic", qmsg_module.import_table.get("quic").?);
    const runtime_tests = b.addTest(.{ .root_module = runtime_mod });
    const run_runtime = b.addRunArtifact(runtime_tests);
    const runtime_step = b.step("test-qmsg-runtime", "Run qmsg's QUIC runtime tests with the selected transport");
    runtime_step.dependOn(&run_runtime.step);
    qmsg_step.dependOn(&run_runtime.step);

    const pairs_mod = b.createModule(.{
        .root_source_file = qmsg.path("src/node_pair_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pairs_mod.addImport("quic", qmsg_module.import_table.get("quic").?);
    pairs_mod.addImport("paseto", qmsg_module.import_table.get("paseto").?);
    const pairs_tests = b.addTest(.{ .root_module = pairs_mod });
    const run_pairs = b.addRunArtifact(pairs_tests);
    const pairs_step = b.step("test-qmsg-pairs", "Run qmsg's independent Node UDP tests with the selected transport");
    pairs_step.dependOn(&run_pairs.step);
    qmsg_step.dependOn(&run_pairs.step);
    b.default_step = step;
}
