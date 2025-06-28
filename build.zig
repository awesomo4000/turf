const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libturf = b.createModule(.{
        .root_source_file = b.path("src/turf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("turf", libturf);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "turf",
        .root_module = libturf,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "turf",
        .root_source_file = .{
            .cwd_relative = "src/main.zig",
        },
        .target = target,
        .optimize = optimize,
    });

    // Add Cocoa and WebKit frameworks and compile Objective-C file
    exe.linkFramework("Cocoa");
    exe.linkFramework("WebKit");
    exe.addCSourceFile(.{
        .file = .{ .cwd_relative = "src/cocoa_bridge.m" },
        .flags = &[_][]const u8{"-fobjc-arc"},
    });
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = libturf,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
