const std = @import("std");
const turf = @import("turf.zig");

export fn onWindowEvent(x: c_int, y: c_int, width: c_int, height: c_int) void {
    std.debug.print(
        "123 Window event: ({d}, {d}, {d}, {d})\n",
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

    // Initialize the window
    const win_config: turf.WindowConfig = .{
        .geometry = .{
            .x = 100,
            .y = 100,
            .height = 800,
            .width = 600,
        },
        .title = "turf",
    };

    var window = try turf.Window.init(
        allocator,
        win_config,
    );
    defer window.deinit();
    window.evalJavaScript("console.log('Hello from Zig!')");
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip over the program name

    if (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "http://") or std.mem.startsWith(u8, arg, "https://")) {
            window.loadURL(arg);
        } else {
            try window.loadFile(arg);
        }
    } else {
        const file: [:0]const u8 = "src/web/index.html";
        try window.loadFile(file);
    }
    //    window.on(turf.WindowEvent, onWindowEvent);

    // Run the application
    try window.run();
}
