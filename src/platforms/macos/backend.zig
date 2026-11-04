// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

const std = @import("std");
const common = @import("../../common.zig");

// External Cocoa bridge functions declared in cocoa_bridge.m
extern fn TurfApplicationLoad() bool;
extern fn NSCreateWindow(
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    title: [*:0]const u8,
    js_inject: [*:0]const u8,
    no_focus: bool,
    start_hidden: bool,
) void;
extern fn NSRunApplication() void;
extern fn NSDestroyWindow() void;
extern fn NSShowWindow() void;
extern fn NSSetWindowPosition(x: c_int, y: c_int) void;
extern fn NSLoadURL(url: [*:0]const u8) void;
extern fn NSLoadLocalFile(path: [*:0]const u8) void;
extern fn NSLoadString(html_content: [*:0]const u8) void;
extern fn NSEvaluateJavaScript(script: [*:0]const u8) void;
extern fn NSShowOpenFileDialog() void;
extern fn NSStartAutomation(path: [*:0]const u8, background: bool) c_int;
extern fn NSStopAutomation() void;
extern fn NSIsMainThread() bool;
extern fn NSMessageGeneration() u64;
extern fn NSMessagesReady() bool;
extern fn NSDeliverMessages(script: [*:0]const u8, generation: u64) void;

pub export fn onDocumentChanging() void {
    if (global_platform_window) |window| window.message_queue.clear();
}

// Global reference to the platform window for message handling
var global_platform_window: ?*PlatformWindow = null;

// JavaScript message handler callback
pub export fn onJavaScriptMessage(message: [*c]const u8) void {
    const msg = std.mem.span(message);

    // Parse the JSON message
    if (global_platform_window) |window| {
        @import("../../native_messages.zig").handle(window.allocator, window.message_queue, &window.prng, msg) catch |err| {
            std.debug.print("Error handling JS message: {}\n", .{err});
        };
    }
}

// Window geometry event callback
pub export fn onWindowGeometryEvent(x: c_int, y: c_int, width: c_int, height: c_int) void {
    _ = x;
    _ = y;
    _ = width;
    _ = height;
}

// Platform implementation
pub const PlatformWindow = struct {
    allocator: std.mem.Allocator,
    config: common.WindowConfig,
    is_window_created: bool = false,
    message_queue: *common.MessageQueue,
    prng: std.Random.DefaultPrng,
    pumping: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, config: common.WindowConfig, message_queue: *common.MessageQueue) !PlatformWindow {
        if (!NSIsMainThread()) return error.WrongThread;
        // Initialize the Cocoa application
        if (!TurfApplicationLoad()) {
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

    pub fn deinit(self: *PlatformWindow) void {
        std.debug.assert(NSIsMainThread());
        self.stopAutomation();
        if (global_platform_window == self) {
            global_platform_window = null;
            NSDestroyWindow();
        }
        self.is_window_created = false;
    }

    pub fn createWindow(self: *PlatformWindow, config: common.WindowConfig, turf_js: []const u8) void {
        std.debug.assert(NSIsMainThread());
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
                config.no_focus,
                config.start_hidden,
            );
            self.is_window_created = true;
        }
    }

    pub fn startAutomation(self: *PlatformWindow, socket_path: [:0]const u8, background: bool) !void {
        if (!NSIsMainThread()) return error.WrongThread;
        if (!self.is_window_created) return error.WindowNotCreated;
        const result = NSStartAutomation(socket_path, background);
        if (result != 0) {
            std.log.err("Cannot start automation socket: errno {d}", .{result});
            return error.AutomationStartFailed;
        }
    }

    pub fn stopAutomation(self: *PlatformWindow) void {
        std.debug.assert(NSIsMainThread());
        _ = self;
        NSStopAutomation();
    }

    pub fn show(self: *PlatformWindow) void {
        std.debug.assert(NSIsMainThread());
        _ = self;
        NSShowWindow();
    }

    pub fn setPosition(self: *PlatformWindow, x: i32, y: i32) !void {
        if (!NSIsMainThread()) return error.WrongThread;
        if (!self.is_window_created) return error.WindowNotCreated;
        NSSetWindowPosition(x, y);
    }

    pub fn loadURL(self: *PlatformWindow, url: [:0]const u8) void {
        std.debug.assert(NSIsMainThread());
        _ = self;
        NSLoadURL(url);
    }

    pub fn loadFile(self: *PlatformWindow, path: [:0]const u8) void {
        std.debug.assert(NSIsMainThread());
        _ = self;
        NSLoadLocalFile(path);
    }

    pub fn loadHTML(self: *PlatformWindow, html: [:0]const u8, base_uri: ?[:0]const u8) void {
        std.debug.assert(NSIsMainThread());
        _ = self;
        _ = base_uri;
        NSLoadString(html);
    }

    pub fn evalJS(self: *PlatformWindow, script: [:0]const u8) void {
        std.debug.assert(NSIsMainThread());
        _ = self;
        NSEvaluateJavaScript(script);
    }

    pub fn run(self: *PlatformWindow) void {
        std.debug.assert(NSIsMainThread());
        self.pumping.store(true, .release);
        defer self.pumping.store(false, .release);
        // Start message processing thread
        const thread = std.Thread.spawn(.{}, messageProcessingThread, .{self}) catch |err| {
            std.debug.print("Failed to spawn message thread: {}\n", .{err});
            return;
        };

        // Run the native application
        NSRunApplication();

        self.pumping.store(false, .release);
        thread.join();
    }

    fn messageProcessingThread(self: *PlatformWindow) void {
        while (self.pumping.load(.acquire)) {
            std.Io.sleep(std.Options.debug_io, .fromMilliseconds(16), .awake) catch return; // 60Hz

            if (!self.pumping.load(.acquire)) break;
            if (!NSMessagesReady()) continue;
            const generation = NSMessageGeneration();
            var messages = self.message_queue.popAll() catch continue;
            defer common.freeMessages(self.message_queue.allocator, &messages);

            if (messages.items.len > 0) {
                self.sendMessagesToJS(messages.items, generation) catch |err| {
                    std.debug.print("Error sending messages: {}\n", .{err});
                };
            }
        }
    }

    fn sendMessagesToJS(self: *PlatformWindow, messages: []const common.Message, generation: u64) !void {
        _ = self;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var messages_json: std.Io.Writer.Allocating = .init(arena_allocator);
        defer messages_json.deinit();
        const json_writer = &messages_json.writer;
        try json_writer.writeAll("[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try json_writer.writeAll(",");
            try json_writer.print("{f}", .{msg});
        }
        try json_writer.writeAll("]");

        var js_array: std.Io.Writer.Allocating = .init(arena_allocator);
        defer js_array.deinit();
        const writer = &js_array.writer;
        // Parse JSON rather than evaluating object literals: __proto__ is data.
        // Direct delivery does not depend on timers in hidden WebKit pages.
        try writer.writeAll("for (const message of JSON.parse(");
        try writer.print("{f}", .{std.json.fmt(messages_json.written(), .{})});
        try writer.writeAll(")) { try { if (typeof window.turf?._handleNativeMessage === 'function') window.turf._handleNativeMessage(message); } catch (error) { try { console.error('Turf message handler failed', error); } catch (_) {} } }");

        const js_code = try arena_allocator.dupeSentinel(u8, js_array.written(), 0);
        NSDeliverMessages(js_code, generation);
    }
};
