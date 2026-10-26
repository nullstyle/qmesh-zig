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

    // Public application workloads are opt-in: the immutable qmsg pin
    // predates reliable publication. Reuse the selected consumer modules.
    const pubsub_workload = b.createModule(.{
        .root_source_file = qmsg.path("examples/reliable_pubsub_workload.zig"),
        .target = target,
        .optimize = optimize,
    });
    pubsub_workload.addImport("qmsg", qmsg.module("qmsg"));
    const recovery_workload = b.createModule(.{
        .root_source_file = qmesh.path("examples/snapshot_recovery.zig"),
        .target = target,
        .optimize = optimize,
    });
    recovery_workload.addImport("qmesh", qmesh.module("qmesh"));
    recovery_workload.addImport("qmesh_quic", qmesh.module("qmesh_quic"));
    recovery_workload.addImport("qmesh_messaging", qmesh.module("qmesh_messaging"));
    recovery_workload.addImport("qmsg", qmsg.module("qmsg"));
    const sprint3_mod = b.createModule(.{
        .root_source_file = b.path("../sprint3_composition_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sprint3_mod.addImport("pubsub_workload", pubsub_workload);
    sprint3_mod.addImport("snapshot_recovery", recovery_workload);
    const sprint3_tests = b.addTest(.{ .root_module = sprint3_mod });
    const sprint3_step = b.step("test-sprint3", "Test reliable publication and missed-announcement snapshot recovery");
    sprint3_step.dependOn(&b.addRunArtifact(sprint3_tests).step);

    const pubsub_cli = b.createModule(.{
        .root_source_file = qmsg.path("examples/quic_pubsub_localhost.zig"),
        .target = target,
        .optimize = optimize,
    });
    pubsub_cli.addImport("qmsg", qmsg.module("qmsg"));
    const pubsub_exe = b.addExecutable(.{ .name = "qmsg-pubsub-workload", .root_module = pubsub_cli });
    const run_pubsub = b.addRunArtifact(pubsub_exe);
    run_pubsub.addPassthruArgs();
    b.step("run-pubsub-workload", "Run the public reliable publication workload with this transport").dependOn(&run_pubsub.step);

    const recovery_exe = b.addExecutable(.{ .name = "qmesh-snapshot-recovery", .root_module = recovery_workload });
    const run_recovery = b.addRunArtifact(recovery_exe);
    run_recovery.addPassthruArgs();
    b.step("run-recovery", "Run the public missed-announcement snapshot recovery example").dependOn(&run_recovery.step);
    const install_workloads = b.step("install-workloads", "Install both public application workloads for profiling outside the build");
    install_workloads.dependOn(&b.addInstallArtifact(pubsub_exe, .{}).step);
    install_workloads.dependOn(&b.addInstallArtifact(recovery_exe, .{}).step);

    const public_faults = b.createModule(.{
        .root_source_file = qmsg.path("examples/public_fault_workload.zig"),
        .target = target,
        .optimize = optimize,
    });
    public_faults.addImport("qmsg", qmsg.module("qmsg"));
    const mesh_chaos = b.createModule(.{
        .root_source_file = qmesh.path("examples/seeded_recovery_chaos.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_chaos.addImport("qmesh", qmesh.module("qmesh"));
    mesh_chaos.addImport("qmesh_quic", qmesh.module("qmesh_quic"));
    mesh_chaos.addImport("qmesh_messaging", qmesh.module("qmesh_messaging"));
    mesh_chaos.addImport("qmsg", qmsg.module("qmsg"));
    const sprint4_mod = b.createModule(.{
        .root_source_file = b.path("../sprint4_composition_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sprint4_mod.addImport("public_faults", public_faults);
    sprint4_mod.addImport("mesh_chaos", mesh_chaos);
    const sprint4_tests = b.addTest(.{ .root_module = sprint4_mod });
    b.step("test-sprint4", "Qualify public messaging faults and seeded mesh recovery").dependOn(&b.addRunArtifact(sprint4_tests).step);

    const faults_cli = b.createModule(.{
        .root_source_file = qmsg.path("examples/quic_public_faults.zig"),
        .target = target,
        .optimize = optimize,
    });
    faults_cli.addImport("qmsg", qmsg.module("qmsg"));
    const faults_exe = b.addExecutable(.{ .name = "qmsg-public-faults", .root_module = faults_cli });
    const run_faults = b.addRunArtifact(faults_exe);
    run_faults.addPassthruArgs();
    b.step("run-public-faults", "Run public messaging failure and shutdown qualification").dependOn(&run_faults.step);
    b.step("install-public-faults", "Install the public messaging fault qualifier").dependOn(&b.addInstallArtifact(faults_exe, .{}).step);

    const chaos_exe = b.addExecutable(.{ .name = "qmesh-recovery-chaos", .root_module = mesh_chaos });
    const run_chaos = b.addRunArtifact(chaos_exe);
    run_chaos.addPassthruArgs();
    b.step("run-chaos", "Run seeded multi-node application recovery").dependOn(&run_chaos.step);
    b.step("install-chaos", "Install the seeded recovery qualifier for bounded replay").dependOn(&b.addInstallArtifact(chaos_exe, .{}).step);

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
