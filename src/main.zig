const std = @import("std");
const turf = @import("turf.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("Memory leaks detected!\n", .{});
        }
    }

    // Create message queue externally
    var message_queue = turf.MessageQueue.init(allocator);
    defer message_queue.deinit();

    // Initialize the window
    const win_config: turf.WindowConfig = .{
        .geometry = .{
            .x = 100,
            .y = 100,
            .width = 600,
            .height = 800,
        },
        .title = "Turf",
    };

    var window = try turf.Window.init(
        allocator,
        win_config,
        &message_queue,
    );
    defer window.deinit();

    // Create window first
    window.createWindow();

    // Process command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    if (args.next()) |arg| {
        if (std.mem.startsWith(
            u8,
            arg,
            "http://",
        ) or std.mem.startsWith(
            u8,
            arg,
            "https://",
        )) {
            const url_z = try allocator.dupeZ(u8, arg);
            defer allocator.free(url_z);
            window.loadURL(url_z);
        } else {
            // Handle file path
            const path_z = try allocator.dupeZ(u8, arg);
            defer allocator.free(path_z);
            try window.loadFile(path_z);
        }
    } else {
        // No argument provided - show usage or load default page
        std.debug.print("Usage: turf [URL or file path]\n", .{});
        std.debug.print("Examples:\n", .{});
        std.debug.print("  turf https://example.com\n", .{});
        std.debug.print("  turf index.html\n", .{});
        std.debug.print("  turf /path/to/file.html\n", .{});

        // Load a default page
        const welcome_html: [:0]const u8 =
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\    <title>Turf Browser</title>
            \\    <style>
            \\        body { font-family: system-ui; padding: 40px; background: #f5f5f5; }
            \\        .container { max-width: 600px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
            \\        h1 { color: #333; }
            \\        code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
            \\        .example { margin: 10px 0; padding: 10px; background: #f8f8f8; border-radius: 4px; font-family: monospace; }
            \\    </style>
            \\</head>
            \\<body>
            \\    <div class="container">
            \\        <h1>Welcome to Turf</h1>
            \\        <p>Turf is a cross-platform desktop browser framework.</p>
            \\        <h3>Usage:</h3>
            \\        <div class="example">turf [URL or file path]</div>
            \\        <h3>Examples:</h3>
            \\        <div class="example">turf https://example.com</div>
            \\        <div class="example">turf index.html</div>
            \\        <div class="example">turf /path/to/file.html</div>
            \\    </div>
            \\</body>
            \\</html>
        ;
        window.loadString(welcome_html);
    }

    // Run the application
    try window.run();
}
