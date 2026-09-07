const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- modules ---------------------------------------------------------
    //
    // `qmesh` (src/) is deliberately transport-generic: it does not import
    // quic at all. Every protocol core (hyParView, later SWIM/Plumtree) is
    // a pure state machine parameterized by explicit `now`/`rng` arguments
    // and emitting bounded effect lists, so the library core builds and
    // tests without linking BoringSSL or any transport.
    //
    // `qmesh_sim` (sim/) is the deterministic in-process simulator — a
    // first-class consumer of qmesh, also quic-free.
    //
    // quic enters only through `tests/quic_boundary_test.zig`, which pins
    // the API surface the (next-milestone) QUIC session adapter will build
    // against, so transport-layer drift fails this build instead of a
    // future one.

    const qmesh_mod = b.addModule("qmesh", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const qmesh_sim_mod = b.addModule("qmesh_sim", .{
        .root_source_file = b.path("sim/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    qmesh_sim_mod.addImport("qmesh", qmesh_mod);

    // --- quic dependency -------------------------------------------------
    //
    // `dependencyLazy` (not plain `dependency`) with this option set.
    // The option map must match qmsg's EXACTLY (`target`,
    // `sanitize-c`): Zig keys the dependency cache on
    // {pkg_hash, option-set}, so a binary linking both qmesh and qmsg
    // shares one quic module only while the two maps agree — otherwise
    // BoringSSL compiles twice and two incompatible `quic.Connection`
    // types exist in one program. `.sanitize-c = "trap"` is qmsg's
    // recipe for static-archive BoringSSL objects under ReleaseSafe.
    // `optimize` is deliberately NOT forwarded: quic-zig registers no
    // such option (it exposes `-Drelease` instead), and passing it
    // fails a cold-cache build outright.
    const quic_dep = try b.dependencyLazy("quic", .{
        .target = target,
        .@"sanitize-c" = @as([]const u8, "trap"),
    });
    const quic_mod = quic_dep.module("quic");

    // `qmesh_quic` is the real-QUIC transport: a separate module so the
    // core + simulator never compile against quic/BoringSSL.
    const qmesh_quic_mod = b.addModule("qmesh_quic", .{
        .root_source_file = b.path("src/quic/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    qmesh_quic_mod.addImport("qmesh", qmesh_mod);
    qmesh_quic_mod.addImport("quic", quic_mod);

    // Everything below is DEVELOPMENT-ONLY: the node binary, the test
    // steps, and the tools. `pkg_hash` is empty only for the top-level
    // build, so a downstream consumer that fetched qmesh stops here
    // with the three public modules (`qmesh`, `qmesh_sim`,
    // `qmesh_quic`) registered and nothing else configured. Without
    // this, every consumer built our test executables. quic-zig's
    // build.zig does the same thing.
    if (b.pkg_hash.len != 0) return;

    // Deployment entry point: one mesh node over the supported socket
    // loop (fly smoke tests drive this binary).
    const node_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/quic/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    node_exe_mod.addImport("qmesh", qmesh_mod);
    node_exe_mod.addImport("quic", quic_mod);
    node_exe_mod.addImport("qmesh_quic", qmesh_quic_mod);
    const node_exe = b.addExecutable(.{ .name = "qmesh-node", .root_module = node_exe_mod });
    b.installArtifact(node_exe);

    // --- composition example ---------------------------------------------
    //
    // Option A glue: qmesh names and watches peers, qmsg carries the
    // traffic. The module imports only `qmesh`, so it does NOT couple
    // this package to qmsg — see examples/qmsg_directory.zig.
    const qmsg_directory_mod = b.createModule(.{
        .root_source_file = b.path("examples/qmsg_directory.zig"),
        .target = target,
        .optimize = optimize,
    });
    qmsg_directory_mod.addImport("qmesh", qmesh_mod);

    // --- test steps ------------------------------------------------------

    const test_step = b.step("test", "Run qmesh tests (unit + sim + quic boundary)");

    const directory_tests = b.addTest(.{ .root_module = qmsg_directory_mod });
    test_step.dependOn(&b.addRunArtifact(directory_tests).step);

    const unit_tests = b.addTest(.{ .root_module = qmesh_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const sim_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/sim_scenarios_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_tests_mod.addImport("qmesh", qmesh_mod);
    sim_tests_mod.addImport("qmesh_sim", qmesh_sim_mod);
    const sim_tests = b.addTest(.{ .root_module = sim_tests_mod });
    const run_sim_tests = b.addRunArtifact(sim_tests);
    test_step.dependOn(&run_sim_tests.step);

    const boundary_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/quic_boundary_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    boundary_tests_mod.addImport("quic", quic_mod);
    const boundary_tests = b.addTest(.{ .root_module = boundary_tests_mod });
    const run_boundary_tests = b.addRunArtifact(boundary_tests);
    test_step.dependOn(&run_boundary_tests.step);

    // Multi-node mesh over real UDP sockets (embedder-owned loop).
    const mesh_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/quic_mesh_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_tests_mod.addImport("qmesh", qmesh_mod);
    mesh_tests_mod.addImport("quic", quic_mod);
    mesh_tests_mod.addImport("qmesh_quic", qmesh_quic_mod);
    const mesh_tests = b.addTest(.{ .root_module = mesh_tests_mod });
    const run_mesh_tests = b.addRunArtifact(mesh_tests);
    test_step.dependOn(&run_mesh_tests.step);

    // Milestone-2 acceptance: real mesh sessions over quic.testing
    // Loopback, real mTLS with the vendored test PKI.
    const session_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/quic_session_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    session_tests_mod.addImport("qmesh", qmesh_mod);
    session_tests_mod.addImport("quic", quic_mod);
    session_tests_mod.addImport("qmesh_quic", qmesh_quic_mod);
    const session_tests = b.addTest(.{ .root_module = session_tests_mod });
    const run_session_tests = b.addRunArtifact(session_tests);
    test_step.dependOn(&run_session_tests.step);
}
