// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_os = target.result.os.tag;

    const turf_common = b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bridge_diagnostics = b.createModule(.{
        .root_source_file = b.path("src/bridge_diagnostics.zig"),
        .target = target,
        .optimize = optimize,
    });
    const turf_backend = b.createModule(.{
        .root_source_file = b.path(turfBackendPath(target_os)),
        .target = target,
        .optimize = optimize,
    });
    turf_backend.addImport("common", turf_common);
    turf_backend.addImport("bridge_diagnostics", bridge_diagnostics);

    // Create turf library
    const libturf = b.createModule(.{
        .root_source_file = b.path("src/turf.zig"),
        .target = target,
        .optimize = optimize,
    });
    libturf.addImport("common", turf_common);
    libturf.addImport("backend", turf_backend);


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
            lib.root_module.linkSystemLibrary("gtk4", .{});
            lib.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
            lib.root_module.linkSystemLibrary("javascriptcoregtk-6.0", .{});
            lib.root_module.link_libc = true;
        },
        .windows => {
            // Windows uses WebView2
            // Libraries will be linked when building executable
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

    // Platform-specific executable configuration
    switch (target_os) {
        .macos => {
            exe.root_module.linkFramework("Cocoa", .{});
            exe.root_module.linkFramework("WebKit", .{});
            exe.root_module.addCSourceFile(.{
                .file = b.path("src/platforms/macos/cocoa_bridge.m"),
                .flags = &[_][]const u8{"-fobjc-arc"},
            });
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

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

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

    switch (target_os) {
        .macos => {
            demo.root_module.linkFramework("Cocoa", .{});
            demo.root_module.linkFramework("WebKit", .{});
            demo.root_module.addCSourceFile(.{
                .file = b.path("src/platforms/macos/cocoa_bridge.m"),
                .flags = &[_][]const u8{"-fobjc-arc"},
            });
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

    const bridge_diagnostics_test_module = b.createModule(.{
        .root_source_file = b.path("src/bridge_diagnostics_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_diagnostics_test_module.addImport("bridge_diagnostics", bridge_diagnostics);
    const bridge_diagnostics_tests = b.addTest(.{
        .root_module = bridge_diagnostics_test_module,
    });
    const run_bridge_diagnostics_tests = b.addRunArtifact(bridge_diagnostics_tests);

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

    const tests_step = b.step("test", "Run unit tests");
    tests_step.dependOn(&run_lib_unit_tests.step);
    tests_step.dependOn(&run_exe_unit_tests.step);
    tests_step.dependOn(&run_bridge_diagnostics_tests.step);

    if (target_os == .macos) {
        const ui_test_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        });
        ui_test_module.addCSourceFile(.{
            .file = b.path("tests/ui/macos/reload_hover_test.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        ui_test_module.linkFramework("Cocoa", .{});
        ui_test_module.linkFramework("WebKit", .{});
        ui_test_module.link_libc = true;

        const ui_test = b.addExecutable(.{
            .name = "turf-macos-ui-test",
            .root_module = ui_test_module,
        });
        const run_ui_test = b.addRunArtifact(ui_test);
        const ui_test_step = b.step(
            "test-ui-macos",
            "Run the offscreen macOS WebKit UI testing sample",
        );
        ui_test_step.dependOn(&run_ui_test.step);
    }
}

fn turfBackendPath(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "src/platforms/macos/backend.zig",
        .linux => "src/platforms/linux/backend.zig",
        .windows => "src/platforms/windows/backend.zig",
        else => @panic("unsupported Turf platform"),
    };
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
