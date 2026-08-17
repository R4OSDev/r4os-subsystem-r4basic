const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const frontend_module = b.createModule(.{
        .root_source_file = b.path("src/frontend.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const frontend_tests_module = b.createModule(.{
        .root_source_file = b.path("Tests/frontend_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    frontend_tests_module.addImport("frontend", frontend_module);
    const frontend_tests = b.addTest(.{ .root_module = frontend_tests_module });
    const run_frontend_tests = b.addRunArtifact(frontend_tests);

    const gorilla_module = b.createModule(.{
        .root_source_file = b.path("Tests/gorilla_acceptance.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    gorilla_module.addImport("frontend", frontend_module);
    const gorilla_tests = b.addTest(.{ .root_module = gorilla_module });
    const run_gorilla_tests = b.addRunArtifact(gorilla_tests);

    const test_step = b.step("test", "Run R4BASIC frontend and fixture tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_frontend_tests.step);

    const gorilla_step = b.step("gorilla-test", "Parse the local checksum-bound GORILLA.BAS acceptance source");
    gorilla_step.dependOn(&run_gorilla_tests.step);
}

