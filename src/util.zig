const std = @import("std");

// Helper function to get absolute path
pub fn getAbsolutePath(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
) ![:0]const u8 {
    // Check if path is already absolute (starts with '/')
    if (path.len > 0 and path[0] == '/') {
        return allocator.dupeZ(u8, path);
    }

    // Get current working directory
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Create absolute path by joining cwd and path
    const abs_path = try std.fs.path.join(
        allocator,
        &[_][]const u8{ cwd, path },
    );
    return allocator.dupeZ(u8, abs_path);
}
