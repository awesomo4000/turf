// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_os = target.result.os.tag;
    const macos_sdk = b.option([]const u8, "macos-sdk", "Path to a macOS SDK for cross-compilation");

    const coverage_objects = b.option([]const u8, "macos-coverage-objects", "Directory of the Apple Clang coverage bridge (tools/coverage-macos.py)");
    if (coverage_objects != null and target_os != .macos) @panic("macOS coverage objects require a macOS target");

    // A standalone client module for embedders and scripts, without GUI dependencies.
    const client_mod = b.addModule("turfctl", .{
        .root_source_file = b.path("src/turfctl/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ctl_mod = b.createModule(.{
        .root_source_file = b.path("src/turfctl/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctl_mod.addImport("turfctl", client_mod);
    const ctl = b.addExecutable(.{ .name = "turfctl", .root_module = ctl_mod });
    const install_ctl = b.addInstallArtifact(ctl, .{});
    b.getInstallStep().dependOn(&install_ctl.step);
    b.step("turfctl", "Build only the standalone automation client").dependOn(&install_ctl.step);
    const client_example_mod = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/turfctl/library.zig"),
        .target = target, .optimize = optimize,
    });
    client_example_mod.addImport("turfctl", client_mod);
    const client_example = b.addExecutable(.{ .name = "turfctl-library-test", .root_module = client_example_mod });
    const install_example = b.addInstallArtifact(client_example, .{});
    const client_integration = b.step("test-turfctl-build", "Build client and library integration fixture");
    client_integration.dependOn(&install_example.step);
    client_integration.dependOn(&install_ctl.step);
    const client_tests = b.addTest(.{ .root_module = client_mod });
    const run_client_tests = b.addRunArtifact(client_tests);
    b.step("test-turfctl", "Test the standalone automation client").dependOn(&run_client_tests.step);

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
            lib.root_module.addCSourceFile(.{
                .file = b.path("src/platforms/linux/automation.c"),
                .flags = &.{"-std=c11", "-Wall", "-Wextra"},
            });
            lib.root_module.linkSystemLibrary("x11", .{});
            lib.root_module.linkSystemLibrary("dl", .{});
            lib.root_module.linkSystemLibrary("gtk4", .{});
            lib.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
            lib.root_module.linkSystemLibrary("javascriptcoregtk-6.0", .{});
            lib.root_module.link_libc = true;
        },
        .windows => {
            lib.root_module.addCSourceFile(.{ .file = b.path("src/platforms/windows/screenshot.c"), .flags = &.{"-std=c11", "-Wall", "-Wextra"} });
            lib.root_module.addCSourceFile(.{
                .file = b.path("src/platforms/windows/automation_transport.c"),
                .flags = &.{"-std=c11", "-Wall", "-Wextra"},
            });
            lib.root_module.linkSystemLibrary("advapi32", .{});
            lib.root_module.linkSystemLibrary("ole32", .{});
            lib.root_module.linkSystemLibrary("user32", .{});
            lib.root_module.link_libc = true;
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
        .root_module = exe_mod,
    });

    if (coverage_objects != null) exe.rdynamic = true;

    // Platform-specific executable configuration
    switch (target_os) {
        .macos => {
            addMacOSSDK(b, exe.root_module, macos_sdk);
            exe.root_module.linkFramework("Cocoa", .{});
            exe.root_module.linkFramework("WebKit", .{});
            exe.root_module.linkFramework("CoreGraphics", .{});
            addMacOSBridge(b, exe.root_module, coverage_objects);
            exe.root_module.link_libc = true;
        },
        .linux => {
            exe.root_module.linkSystemLibrary("gtk4", .{});
            exe.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
            exe.root_module.linkSystemLibrary("javascriptcoregtk-6.0", .{});
            exe.root_module.link_libc = true;
        },
        .windows => {
            // Get target architecture for WebView2Loader selection
            const arch = target.result.cpu.arch;
            const arch_dir = switch (arch) {
                .x86_64 => "windows-x86_64",
                .aarch64 => "windows-aarch64",
                .x86 => "windows-x86",
                else => @panic("Unsupported Windows architecture"),
            };
            
            // Add WebView2Loader library
            exe.root_module.addLibraryPath(b.path(b.fmt("src/platforms/windows/lib/{s}", .{arch_dir})));
            exe.root_module.linkSystemLibrary("WebView2Loader", .{});
            exe.root_module.linkSystemLibrary("ole32", .{});
            exe.root_module.linkSystemLibrary("shell32", .{});
            exe.root_module.linkSystemLibrary("shlwapi", .{});
            exe.root_module.linkSystemLibrary("user32", .{});
            exe.root_module.linkSystemLibrary("gdi32", .{});
            exe.root_module.link_libc = true;
        },
        else => {},
    }

    b.installArtifact(exe);
    
    // Copy WebView2Loader.dll to output directory on Windows
    if (target_os == .windows) {
        const arch = target.result.cpu.arch;
        const arch_dir = switch (arch) {
            .x86_64 => "windows-x86_64",
            .aarch64 => "windows-aarch64",
            .x86 => "windows-x86",
            else => @panic("Unsupported Windows architecture"),
        };
        const dll_path = b.fmt("src/platforms/windows/lib/{s}/WebView2Loader.dll", .{arch_dir});
        const install_dll = b.addInstallBinFile(b.path(dll_path), "WebView2Loader.dll");
        b.getInstallStep().dependOn(&install_dll.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Main demo
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/demo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = demo_mod,
    });

    demo_mod.addImport("turf", libturf);
    if (coverage_objects != null) demo.rdynamic = true;

    switch (target_os) {
        .macos => {
            addMacOSSDK(b, demo.root_module, macos_sdk);
            demo.root_module.linkFramework("Cocoa", .{});
            demo.root_module.linkFramework("WebKit", .{});
            demo.root_module.linkFramework("CoreGraphics", .{});
            addMacOSBridge(b, demo.root_module, coverage_objects);
            demo.root_module.link_libc = true;
        },
        .linux => {
            demo.root_module.linkSystemLibrary("gtk4", .{});
            demo.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
            demo.root_module.linkSystemLibrary("javascriptcoregtk-6.0", .{});
            demo.root_module.link_libc = true;
        },
        .windows => {
            // Get target architecture for WebView2Loader selection
            const arch = target.result.cpu.arch;
            const arch_dir = switch (arch) {
                .x86_64 => "windows-x86_64",
                .aarch64 => "windows-aarch64",
                .x86 => "windows-x86",
                else => @panic("Unsupported Windows architecture"),
            };
            
            // Add WebView2Loader library
            demo.root_module.addLibraryPath(b.path(b.fmt("src/platforms/windows/lib/{s}", .{arch_dir})));
            demo.root_module.linkSystemLibrary("WebView2Loader", .{});
            demo.root_module.linkSystemLibrary("ole32", .{});
            demo.root_module.linkSystemLibrary("shell32", .{});
            demo.root_module.linkSystemLibrary("shlwapi", .{});
            demo.root_module.linkSystemLibrary("user32", .{});
            demo.root_module.linkSystemLibrary("gdi32", .{});
            demo.root_module.link_libc = true;
        },
        else => {},
    }

    b.installArtifact(demo);
    
    // Copy WebView2Loader.dll for demo too
    if (target_os == .windows) {
        // DLL copy is already handled above for main exe
    }

    const run_demo_cmd = b.addRunArtifact(demo);
    run_demo_cmd.step.dependOn(b.getInstallStep());
    const run_demo_step = b.step(
        "run-demo",
        "Run the demo",
    );
    run_demo_step.dependOn(&run_demo_cmd.step);

    // A real consumer of the public API, separate from the Turf CLI.
    if (target_os == .macos) {
        const embedder_mod = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/embedder/lifecycle.zig"),
            .target = target,
            .optimize = optimize,
        });
        embedder_mod.addImport("turf", libturf);
        const embedder = b.addExecutable(.{ .name = "embedder-lifecycle", .root_module = embedder_mod });
        addMacOSSDK(b, embedder_mod, macos_sdk);
        for ([_][]const u8{ "Cocoa", "WebKit", "CoreGraphics" }) |framework| embedder_mod.linkFramework(framework, .{});
        addMacOSBridge(b, embedder_mod, null);
        embedder_mod.addCSourceFile(.{ .file = b.path("tests/fixtures/embedder/control.m"), .flags = &.{"-fobjc-arc"} });
        embedder_mod.link_libc = true;
        const install_embedder = b.addInstallArtifact(embedder, .{});
        b.step("test-embedder-build", "Build the macOS embedder lifecycle fixture").dependOn(&install_embedder.step);
    }

    // Test configuration
    const lib_unit_tests = b.addTest(.{
        .root_module = libturf,
    });

    // Platform specific test linking
    switch (target_os) {
        .macos => {
            // TODO
        },
        .linux => {
            lib_unit_tests.root_module.linkSystemLibrary("gtk4", .{});
            lib_unit_tests.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
            lib_unit_tests.root_module.linkSystemLibrary("javascriptcoregtk-6.0", .{});
            lib_unit_tests.root_module.link_libc = true;
        },
        .windows => {
            // Windows test linking
            lib_unit_tests.root_module.link_libc = true;
        },
        else => {},
    }

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_test_mod.addImport("turf", libturf);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_test_mod,
    });

    // Platform-specific test linking for exe module
    switch (target_os) {
        .macos => {
            // TODO
        },
        .linux => {
            exe_unit_tests.root_module.linkSystemLibrary("gtk4", .{});
            exe_unit_tests.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
            exe_unit_tests.root_module.linkSystemLibrary("javascriptcoregtk-6.0", .{});
            exe_unit_tests.root_module.link_libc = true;
        },
        .windows => {
            // Windows test linking
            exe_unit_tests.root_module.link_libc = true;
        },
        else => {},
    }
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Isolated shared-code fuzzing needs no native frameworks or GUI session.
    const fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    b.step("fuzz", "Fuzz queue/message properties; use --fuzz=10000 for a bounded run").dependOn(&run_fuzz.step);

    const tests_step = b.step("test", "Run unit tests");
    tests_step.dependOn(&run_client_tests.step);
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

// Zig does not automatically discover SDK paths when cross-compiling macOS.
fn addMacOSSDK(b: *std.Build, module: *std.Build.Module, sdk_path: ?[]const u8) void {
    if (sdk_path) |sdk| {
        module.addSystemFrameworkPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "System/Library/Frameworks" })));
        module.addSystemIncludePath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/include" })));
        module.addLibraryPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/lib" })));
    }
}

// The coverage bridge is linked by Apple Clang with its matching profiling runtime.
// Ordinary builds continue to compile the bridge with Zig's bundled Clang.
fn addMacOSBridge(b: *std.Build, module: *std.Build.Module, coverage_objects: ?[]const u8) void {
    if (coverage_objects) |directory| {
        module.addLibraryPath(b.graph.cwdRelativePath(directory));
        module.addRPath(b.graph.cwdRelativePath(directory));
        module.linkSystemLibrary("turf_coverage_bridge", .{});
    } else {
        for ([_][]const u8{ "cocoa_bridge.m", "automation.m" }) |name| {
            module.addCSourceFile(.{ .file = b.path(b.fmt("src/platforms/macos/{s}", .{name})), .flags = &.{"-fobjc-arc"} });
        }
    }
}
