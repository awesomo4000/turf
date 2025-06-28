const std = @import("std");
const turf = @import("turf.zig");

fn onWindowEvent(x: c_int, y: c_int, width: c_int, height: c_int) void {
    std.debug.print(
        "Window event: ({d}, {d}, {d}, {d})\n",
        .{ x, y, width, height },
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(
        .{ .safety = true },
    ){};
    const allocator = gpa.allocator();

    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("Memory leaks detected!\n", .{});
        }
    }

    // Initialize message parsers
    turf.initMessageParsers(allocator);
    defer turf.deinitMessageParsers();

    // Initialize the window
    var window = try turf.Window.init(
        allocator,
        .{
            .x = 100,
            .y = 100,
            .height = 800,
            .width = 600,
            .title = "turf",
        },
    );
    defer window.deinit();

    // Let's modify the order of operations in the Window run method
    // so we create the window first, then load content, then run the app loop
    const file: [:0]const u8 = "src/web/index.html";
    try window.loadFile(file);
    //    window.on(turf.WindowEvent, onWindowEvent);

    // Run the application
    try window.run();
}
