// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

const std = @import("std");

// Helper function to get absolute path
pub fn getAbsolutePath(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
) ![:0]const u8 {
    // Check if path is already absolute (starts with '/')
    if (path.len > 0 and path[0] == '/') {
        return allocator.dupeSentinel(u8, path, 0);
    }

    // Get current working directory
    const cwd = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
    defer allocator.free(cwd);

    // Create absolute path by joining cwd and path
    const abs_path = try std.fs.path.join(
        allocator,
        &[_][]const u8{ cwd, path },
    );
    return allocator.dupeSentinel(u8, abs_path, 0);
}
