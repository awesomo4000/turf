const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_os = target.result.os.tag;

    // Resolve Windows library directory (used by module linking and DLL copy)
    const win_arch_dir: ?[]const u8 = if (target_os == .windows) switch (target.result.cpu.arch) {
        .x86_64 => "windows-x86_64",
        .aarch64 => "windows-aarch64",
        .x86 => "windows-x86",
        else => @panic("Unsupported Windows architecture"),
    } else null;

    // Create turf library
    const libturf = b.createModule(.{
        .root_source_file = b.path("src/turf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Platform-specific dependencies on the library module.
    // All consumers (exe, demo, tests) inherit these through module imports.
    switch (target_os) {
        .macos => {
            libturf.addCSourceFile(.{
                .file = b.path("src/platforms/macos/cocoa_bridge.m"),
                .flags = &[_][]const u8{"-fobjc-arc"},
            });
            libturf.linkFramework("Cocoa", .{});
            libturf.linkFramework("WebKit", .{});
            libturf.link_libc = true;
        },
        .linux => {
            libturf.linkSystemLibrary("gtk4", .{});
            libturf.linkSystemLibrary("webkitgtk-6.0", .{});
            libturf.linkSystemLibrary("javascriptcoregtk-6.0", .{});
            libturf.link_libc = true;
        },
        .windows => {
            libturf.addLibraryPath(b.path(b.fmt("src/platforms/windows/lib/{s}", .{win_arch_dir.?})));
            libturf.linkSystemLibrary("WebView2Loader", .{});
            libturf.linkSystemLibrary("ole32", .{});
            libturf.linkSystemLibrary("shell32", .{});
            libturf.linkSystemLibrary("shlwapi", .{});
            libturf.linkSystemLibrary("user32", .{});
            libturf.linkSystemLibrary("gdi32", .{});
            libturf.link_libc = true;
        },
        else => @panic("Unsupported operating system"),
    }

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
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Copy WebView2Loader.dll to output directory on Windows
    if (win_arch_dir) |dir| {
        const dll_path = b.fmt("src/platforms/windows/lib/{s}/WebView2Loader.dll", .{dir});
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

    b.installArtifact(demo);

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

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const tests_step = b.step("test", "Run unit tests");
    tests_step.dependOn(&run_lib_unit_tests.step);
}
