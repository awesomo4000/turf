// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

const std = @import("std");
const common = @import("common");

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
extern fn NSEvaluateJavaScriptForGeneration(script: [*:0]const u8, generation: c_ulonglong) bool;
extern fn NSShowOpenFileDialog() void;
extern fn NSShowSaveFileDialog() void;

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

pub export fn onWebViewNavigationStarted(generation: c_ulonglong) void {
    const window = global_platform_window orelse return;
    window.delivery_generation.store(generation, .seq_cst);
    window.delivery_suspended.store(true, .seq_cst);
    const handler = window.message_handler orelse return;
    handler.dispatch("{\"type\":\"turf.navigation_started\"}");
}

fn handleJavaScriptMessage(window: *PlatformWindow, msg: []const u8) !void {
    if (window.message_handler) |handler| {
        handler.dispatch(msg);
    }

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
    if (std.mem.eql(u8, msg_type, "turf_ready")) {
        window.delivery_suspended.store(false, .seq_cst);
        return;
    }

    // Handle different message types
    if (std.mem.eql(u8, msg_type, "show_file_dialog")) {
        NSShowOpenFileDialog();
        return;
    }
    if (std.mem.eql(u8, msg_type, "show_save_dialog")) {
        NSShowSaveFileDialog();
        return;
    }

    if (std.mem.eql(u8, msg_type, "ping")) {
        // Send pong response - match Linux format
        const pong_str = try std.fmt.allocPrint(allocator, "{{\"message\":\"PONG from native!\",\"timestamp\":{d}}}", .{std.Io.Clock.real.now(std.Options.debug_io).toSeconds()});
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
        const time_str = try std.fmt.allocPrint(allocator, "{{\"time\":\"{d}\"}}", .{std.Io.Clock.real.now(std.Options.debug_io).toSeconds()});
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
    _ = .{ x, y, width, height };
}

// Platform implementation
pub const PlatformWindow = struct {
    allocator: std.mem.Allocator,
    config: common.WindowConfig,
    is_window_created: bool = false,
    message_queue: *common.MessageQueue,
    prng: std.Random.DefaultPrng,
    message_handler: ?common.MessageHandler = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    delivery_generation: std.atomic.Value(c_ulonglong) = std.atomic.Value(c_ulonglong).init(0),
    delivery_suspended: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

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
            .prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.real.now(std.Options.debug_io).toNanoseconds())),
        };
    }
    pub fn setMessageHandler(self: *PlatformWindow, handler: ?common.MessageHandler) void {
        self.message_handler = handler;
    }


    pub fn deinit(self: *PlatformWindow) void {
        self.running.store(false, .seq_cst);
        if (global_platform_window == self) global_platform_window = null;
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
        self.running.store(false, .seq_cst);

        thread.join();
    }

    fn messageProcessingThread(self: *PlatformWindow) void {
        var pending: ?std.ArrayList(common.Message) = null;
        var pending_batch_id: u64 = 0;
        var next_batch_id: u64 = 1;
        defer if (pending) |*batch| self.freeMessageBatch(batch);

        while (self.running.load(.seq_cst)) {
            std.Io.sleep(std.Options.debug_io, .fromMilliseconds(16), .awake) catch return;

            if (self.delivery_suspended.load(.seq_cst)) continue;
            if (pending == null) {
                var messages = self.message_queue.popAll() catch continue;
                if (messages.items.len == 0) {
                    messages.deinit(self.allocator);
                    continue;
                }
                pending = messages;
                pending_batch_id = next_batch_id;
                next_batch_id +%= 1;
            }

            if (self.delivery_suspended.load(.seq_cst)) continue;
            const generation = self.delivery_generation.load(.seq_cst);
            const delivered = self.sendMessagesToJS(pending.?.items, generation, pending_batch_id) catch |err| failed: {
                std.debug.print("Error sending messages: {}\n", .{err});
                break :failed false;
            };
            if (!delivered) continue;

            if (pending) |*batch| self.freeMessageBatch(batch);
            pending = null;
            pending_batch_id = 0;
        }
    }

    fn freeMessageBatch(self: *PlatformWindow, messages: *std.ArrayList(common.Message)) void {
        for (messages.items) |message| {
            self.allocator.free(message.type);
            self.allocator.free(message.data);
        }
        messages.deinit(self.allocator);
    }

    fn sendMessagesToJS(
        self: *PlatformWindow,
        messages: []const common.Message,
        generation: c_ulonglong,
        batch_id: u64,
    ) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var js_array: std.Io.Writer.Allocating = .init(arena_allocator);
        defer js_array.deinit();
        const writer = &js_array.writer;

        try writer.print("(() => {{ const batchId = '{d}'; const delivered = window.__turf_delivered_batches || (window.__turf_delivered_batches = new Set()); if (delivered.has(batchId)) return true; if (!window.turf || !window.turf._handleNativeMessage) return false; const messages = [", .{batch_id});
        for (messages, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{type:'{s}',data:{s}}}", .{ msg.type, msg.data });
        }
        try writer.writeAll("]; for (const message of messages) window.turf._handleNativeMessage(message); delivered.add(batchId); return true; })()");

        const js_code = try arena_allocator.dupeSentinel(u8, js_array.written(), 0);
        return NSEvaluateJavaScriptForGeneration(js_code, generation);
    }
};
