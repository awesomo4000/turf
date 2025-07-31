const std = @import("std");
const common = @import("../../common.zig");

// External Cocoa bridge functions declared in cocoa_bridge.m
extern fn NSApplicationLoad() bool;
extern fn NSCreateWindow(
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    title: [*:0]const u8,
    js_inject: [*:0]const u8,
) void;
extern fn NSRunApplication() void;
extern fn NSLoadURL(url: [*:0]const u8) void;
extern fn NSLoadLocalFile(path: [*:0]const u8) void;
extern fn NSLoadString(html_content: [*:0]const u8) void;
extern fn NSEvaluateJavaScript(script: [*:0]const u8) void;
extern fn NSShowOpenFileDialog() void;

// Global reference to the platform window for message handling
var global_platform_window: ?*PlatformWindow = null;

// JavaScript message handler callback
pub export fn onJavaScriptMessage(message: [*c]const u8) void {
    const msg = std.mem.span(message);
    std.debug.print("Native received JS message: {s}\n", .{msg});

    // Parse the JSON message
    if (global_platform_window) |window| {
        handleJavaScriptMessage(window, msg) catch |err| {
            std.debug.print("Error handling JS message: {}\n", .{err});
        };
    }
}

fn handleJavaScriptMessage(window: *PlatformWindow, msg: []const u8) !void {
    const allocator = window.allocator;

    // Parse JSON
    const parsed = std.json.parseFromSlice(
        struct {
            type: []const u8,
            message: ?[]const u8 = null,
            min: ?i32 = null,
            max: ?i32 = null,
        },
        allocator,
        msg,
        .{},
    ) catch return;
    defer parsed.deinit();

    const msg_type = parsed.value.type;

    // Handle different message types
    if (std.mem.eql(u8, msg_type, "ping")) {
        // Send pong response - match Linux format
        const pong_str = try std.fmt.allocPrint(allocator, "{{\"message\":\"PONG from native!\",\"timestamp\":{d}}}", .{std.time.timestamp()});
        defer allocator.free(pong_str);
        try window.message_queue.pushCopy("pong", pong_str);
    } else if (std.mem.eql(u8, msg_type, "echo")) {
        // Echo back the message - match Linux format
        if (parsed.value.message) |echo_msg| {
            const response = try std.fmt.allocPrint(allocator, "{{\"message\":\"Echo: {s}\"}}", .{echo_msg});
            defer allocator.free(response);
            try window.message_queue.pushCopy("echo_response", response);
        }
    } else if (std.mem.eql(u8, msg_type, "get_time")) {
        // Send current time
        const time_str = try std.fmt.allocPrint(allocator, "{{\"time\":\"{d}\"}}", .{std.time.timestamp()});
        defer allocator.free(time_str);
        try window.message_queue.pushCopy("time_response", time_str);
    } else if (std.mem.eql(u8, msg_type, "get_random")) {
        // Generate random number
        const random = window.prng.random();
        const min = parsed.value.min orelse 0;
        const max = parsed.value.max orelse 100;
        const value = random.intRangeAtMost(i32, min, max);
        const random_str = try std.fmt.allocPrint(allocator, "{{\"value\":{d}}}", .{value});
        defer allocator.free(random_str);
        try window.message_queue.pushCopy("random_response", random_str);
    } else if (std.mem.eql(u8, msg_type, "custom")) {
        // Handle custom message
        if (parsed.value.message) |custom_msg| {
            const response = try std.fmt.allocPrint(allocator, "{{\"message\":\"Received: {s}\"}}", .{custom_msg});
            defer allocator.free(response);
            try window.message_queue.pushCopy("custom_response", response);
        }
    }
}

// Window geometry event callback
pub export fn onWindowGeometryEvent(x: c_int, y: c_int, width: c_int, height: c_int) void {
    std.debug.print("Window geometry changed: x={}, y={}, w={}, h={}\n", .{ x, y, width, height });
}

// Platform implementation
pub const PlatformWindow = struct {
    allocator: std.mem.Allocator,
    config: common.WindowConfig,
    is_window_created: bool = false,
    message_queue: *common.MessageQueue,
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, config: common.WindowConfig, message_queue: *common.MessageQueue) !PlatformWindow {
        // Initialize the Cocoa application
        if (!NSApplicationLoad()) {
            return error.CocoaInitFailed;
        }

        return PlatformWindow{
            .allocator = allocator,
            .config = config,
            .is_window_created = false,
            .message_queue = message_queue,
            .prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp())),
        };
    }

    pub fn deinit(self: *PlatformWindow) void {
        _ = self;
    }

    pub fn createWindow(self: *PlatformWindow, config: common.WindowConfig, turf_js: []const u8) void {
        if (!self.is_window_created) {
            // Store reference for message handling
            global_platform_window = self;

            NSCreateWindow(
                config.geometry.x,
                config.geometry.y,
                config.geometry.width,
                config.geometry.height,
                config.title,
                @ptrCast(turf_js.ptr),
            );
            self.is_window_created = true;
        }
    }

    pub fn show(self: *PlatformWindow) void {
        _ = self;
        // Window is shown automatically on macOS
    }

    pub fn loadURL(self: *PlatformWindow, url: [:0]const u8) void {
        _ = self;
        NSLoadURL(url);
    }

    pub fn loadHTML(self: *PlatformWindow, html: [:0]const u8, base_uri: ?[:0]const u8) void {
        _ = self;
        _ = base_uri;
        NSLoadString(html);
    }

    pub fn evalJS(self: *PlatformWindow, script: [:0]const u8) void {
        _ = self;
        NSEvaluateJavaScript(script);
    }

    pub fn run(self: *PlatformWindow) void {
        // Start message processing thread
        const thread = std.Thread.spawn(.{}, messageProcessingThread, .{self}) catch |err| {
            std.debug.print("Failed to spawn message thread: {}\n", .{err});
            return;
        };

        // Run the native application
        NSRunApplication();

        thread.join();
    }

    fn messageProcessingThread(self: *PlatformWindow) void {
        while (true) {
            std.time.sleep(16 * std.time.ns_per_ms); // 60Hz

            const messages = self.message_queue.popAll() catch continue;
            defer messages.deinit();

            if (messages.items.len > 0) {
                self.sendMessagesToJS(messages.items) catch |err| {
                    std.debug.print("Error sending messages: {}\n", .{err});
                };
            }
        }
    }

    fn sendMessagesToJS(self: *PlatformWindow, messages: []const common.Message) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var js_array = std.ArrayList(u8).init(arena_allocator);
        const writer = js_array.writer();

        // Use the same polling mechanism as Linux
        try writer.writeAll("window.__turf_message_queue.push(");
        for (messages, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try std.fmt.format(writer, "{{type:'{s}',data:{s}}}", .{ msg.type, msg.data });
        }
        try writer.writeAll(");");

        const js_code = try arena_allocator.dupeZ(u8, js_array.items);
        std.debug.print("macOS: Sending JS: {s}\n", .{js_code});
        self.evalJS(js_code);
    }
};
