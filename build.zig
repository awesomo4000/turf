const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_os = target.result.os.tag;

    // Create turf library
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

    // Platform-specific library linking
    switch (target_os) {
        .macos => {
            // macOS deosn't need explicit linking for frameworks
            // when building library
        },
        .linux => {
            lib.linkSystemLibrary("gtk4");
            lib.linkSystemLibrary("webkitgtk-6.0");
            lib.linkSystemLibrary("javascriptcoregtk-6.0");
            lib.linkLibC();
        },
        else => {
            std.debug.panic(
                "Unsupported operating system: {s}\n",
                .{@tagName(target_os)},
            );
        },
    }

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "turf",
        .root_source_file = .{
            .cwd_relative = "src/main.zig",
        },
        .target = target,
        .optimize = optimize,
    });

    // Platform-specific executable configuration
    switch (target_os) {
        .macos => {
            exe.linkFramework("Cocoa");
            exe.linkFramework("WebKit");
            exe.addCSourceFile(.{
                .file = b.path("src/platforms/macos/cocoa_bridge.m"),
                .flags = &[_][]const u8{"-fobjc-arc"},
            });
            exe.linkLibC();
        },
        .linux => {
            exe.linkSystemLibrary("gtk4");
            exe.linkSystemLibrary("webkitgtk-6.0");
            exe.linkSystemLibrary("javascriptcotrgtk-6.0");
            exe.linkLibC();
        },
        else => {},
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Main demo
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("src/demo.zig"),
        .target = target,
        .optimize = optimize,
    });

    demo.root_module.addImport("turf", libturf);

    switch (target_os) {
        .macos => {
            demo.linkFramework("Cocoa");
            demo.linkFramework("WebKit");
            demo.addCSourceFile(.{
                .file = b.path("src/platforms/macos/cocoa_bridge.m"),
                .flags = &[_][]const u8{"-fobjc-arc"},
            });
            demo.linkLibC();
        },
        .linux => {
            demo.linkSystemLibrary("gtk4");
            demo.linkSystemLibrary("webkitgtk-6.0");
            demo.linkSystemLibrary("javascriptcoregtk-6.0");
            demo.linkLibC();
        },
        else => {},
    }

    b.installArtifact(demo);

    const run_demo_cmd = b.addRunArtifact(demo);
    run_demo_cmd.step.dependOn(b.getInstallStep());
    const run_demo_step = b.step(
        "run-demo",
        "Run the demo",
    );
    run_demo_step.dependOn(&run_demo_cmd.step);

    // Test configuration
    const lib_unit_tests = b.addTest(.{ .root_module = libturf });

    // Platform specific test linking
    switch (target_os) {
        .macos => {
            // TODO
        },
        .linux => {
            lib_unit_tests.linkSystemLibrary("gtk4");
            lib_unit_tests.linkSystemLibrary("webkitgtk-6.0");
            lib_unit_tests.linkSystemLibrary("javascriptcoregtk-6.0");
            lib_unit_tests.linkLibC();
        },
        else => {},
    }

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    // Platform-specific test linking for exe module
    switch (target_os) {
        .macos => {
            // TODO
        },
        .linux => {
            exe_unit_tests.linkSystemLibrary("gtk4");
            exe_unit_tests.linkSystemLibrary("webkit-6.0");
            exe_unit_tests.linkSystemLibrary("javascriptcoregtk-6.0");
            exe_unit_tests.linkLibC();
        },
        else => {},
    }
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const tests_step = b.step("test", "Run unit tests");
    tests_step.dependOn(&run_lib_unit_tests.step);
    tests_step.dependOn(&run_exe_unit_tests.step);
}

// Add Cocoa and WebKit frameworks and compile Objective-C file
//     exe.linkFramework("Cocoa");
//     exe.linkFramework("WebKit");
//     exe.addCSourceFile(.{
//         .file = .{ .cwd_relative = "src/cocoa_bridge.m" },
//         .flags = &[_][]const u8{"-fobjc-arc"},
//     });
//     exe.linkLibC();

//     b.installArtifact(exe);

//     const run_cmd = b.addRunArtifact(exe);

//     run_cmd.step.dependOn(b.getInstallStep());

//     if (b.args) |args| {
//         run_cmd.addArgs(args);
//     }

//     const run_step = b.step("run", "Run the app");
//     run_step.dependOn(&run_cmd.step);

//     const lib_unit_tests = b.addTest(.{
//         .root_module = libturf,
//     });

//     const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

//     const exe_unit_tests = b.addTest(.{
//         .root_module = exe_mod,
//     });

//     const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

//     const test_step = b.step("test", "Run unit tests");
//     test_step.dependOn(&run_lib_unit_tests.step);
//     test_step.dependOn(&run_exe_unit_tests.step);
// }
