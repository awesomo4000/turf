// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");

// Import platform-specific backend
const backend = switch (builtin.target.os.tag) {
    .macos => @import("platforms/macos/backend.zig"),
    .linux => @import("platforms/linux/backend.zig"),
    .windows => @import("platforms/windows/backend.zig"),
    else => @compileError("Unsupported platform"),
};

// JavaScript bridge code to inject (platform-specific)
const turf_js_inject = switch (builtin.target.os.tag) {
    .windows => @embedFile("web/platforms/windows/turf.js"),
    else => @embedFile("web/turf.js"),
};

// Additional JavaScript for polling-based communication (used by both platforms)
const polling_js =
    \\// Polling mechanism for native messages
    \\(function() {
    \\    window.__turf_pending_messages = [];
    \\    window.__turf_message_queue = [];
    \\    
    \\    // Function to get messages from queue
    \\    window.__turf_get_messages = function() {
    \\        if (window.__turf_message_queue.length > 0) {
    \\            const messages = window.__turf_message_queue;
    \\            window.__turf_message_queue = [];
    \\            return messages;
    \\        }
    \\        return [];
    \\    };
    \\    
    \\    // Poll for messages at a reasonable rate
    \\    setInterval(function() {
    \\        const messages = window.__turf_get_messages();
    \\        messages.forEach(function(msg) {
    \\            if (window.turf && window.turf._handleNativeMessage) {
    \\                window.turf._handleNativeMessage(msg);
    \\            }
    \\        });
    \\    }, 10);
    \\})();
;

// Re-export common types
pub const WindowConfig = common.WindowConfig;
pub const Titlebar = common.Titlebar;
pub const WindowControls = common.WindowControls;
pub const StartupLogo = common.StartupLogo;
pub const Geometry = common.Geometry;
pub const MessageQueue = common.MessageQueue;

pub const AutomationOptions = struct {
    /// Keep startup and automated input from activating the window.
    background: bool = false,
};

// Window struct provides cross-platform API
pub const Window = struct {
    allocator: std.mem.Allocator,
    config: WindowConfig,
    message_queue: *MessageQueue,
    platform: backend.PlatformWindow,
    running: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        config: WindowConfig,
        message_queue: *MessageQueue,
    ) !Window {
        if (builtin.target.os.tag != .macos and (config.titlebar == .hidden or
            config.window_controls == .hidden or config.square_corners or config.cmd_drag))
            return error.WindowChromeUnsupported;
        const platform = try backend.PlatformWindow.init(
            allocator,
            config,
            message_queue,
        );

        return Window{
            .allocator = allocator,
            .config = config,
            .message_queue = message_queue,
            .platform = platform,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *Window) void {
        self.running.store(false, .seq_cst);
        self.platform.deinit();
        // Don't deinit message_queue - caller owns it
    }

    pub fn createWindow(self: *Window) void {
        // Combine turf.js with polling mechanism - ensure null termination
        const js_code = std.fmt.allocPrintSentinel(
            self.allocator,
            "(function() {{ const startupLogo = '{s}';\n{s}\n{s}\n}})();",
            .{ @tagName(self.config.startup_logo), turf_js_inject, polling_js },
            0,
        ) catch {
            // If allocation fails, use just the turf.js
            // (it's already null-terminated from embedFile)
            self.platform.createWindow(self.config, turf_js_inject);
            return;
        };
        defer self.allocator.free(js_code);

        self.platform.createWindow(self.config, js_code);
    }

    /// Enable local automation after createWindow, before run.
    /// Use an owner-private Unix socket path or a local Windows named pipe.
    pub fn startAutomation(self: *Window, socket_path: [:0]const u8) !void {
        try self.startAutomationWithOptions(socket_path, .{});
    }

    /// Enable automation with explicit focus behavior. Call before run to control startup too.
    pub fn startAutomationWithOptions(self: *Window, socket_path: [:0]const u8, options: AutomationOptions) !void {
        if (comptime @hasDecl(backend.PlatformWindow, "startAutomation")) {
            try self.platform.startAutomation(socket_path, options.background or self.config.no_focus);
        } else return error.AutomationUnsupported;
    }

    /// Stop accepting automation requests and remove the owned socket.
    pub fn stopAutomation(self: *Window) void {
        if (comptime @hasDecl(backend.PlatformWindow, "stopAutomation")) {
            self.platform.stopAutomation();
        }
    }

    /// Position the outer window in desktop points before or after showing.
    /// Origin is the primary screen's top-left. Supported on macOS, Windows, and Linux/X11.
    pub fn setPosition(self: *Window, x: i32, y: i32) !void {
        if (comptime @hasDecl(backend.PlatformWindow, "setPosition")) {
            try self.platform.setPosition(x, y);
        } else return error.WindowPositionUnsupported;
    }

    pub fn show(self: *Window) void {
        self.platform.show();
    }

    pub fn loadURL(self: *Window, url: [:0]const u8) void {
        self.platform.loadURL(url);
    }

    pub fn loadFile(self: *Window, path: [:0]const u8) !void {
        if (comptime @hasDecl(backend.PlatformWindow, "loadFile")) {
            const absolute = try getAbsolutePath(self.allocator, path);
            defer self.allocator.free(absolute);
            const terminated = try self.allocator.dupeSentinel(u8, absolute, 0);
            defer self.allocator.free(terminated);
            self.platform.loadFile(terminated);
            return;
        }
        // Convert to absolute path if needed
        const abs_path = try getAbsolutePath(self.allocator, path);
        defer self.allocator.free(abs_path);

        // Construct file:// URL
        const file_url = try std.fmt.allocPrintSentinel(
            self.allocator,
            "file://{s}",
            .{abs_path},
            0,
        );
        defer self.allocator.free(file_url);

        self.platform.loadURL(file_url);
    }

    pub fn loadString(self: *Window, html_content: [:0]const u8) void {
        self.platform.loadHTML(html_content, null);
    }

    pub fn evalJavaScript(self: *Window, script: [:0]const u8) void {
        self.platform.evalJS(script);
    }

    pub fn sendMessage(
        self: *Window,
        message_type: []const u8,
        data: anytype,
    ) !void {
        const json_data = try std.fmt.allocPrint(
            self.allocator,
            "{f}",
            .{std.json.fmt(data, .{})},
        );
        defer self.allocator.free(json_data);

        // The queue may use a different allocator from the window.
        try self.message_queue.pushCopy(message_type, json_data);
    }

    pub fn run(self: *Window) !void {
        self.platform.run();
        self.running.store(false, .seq_cst);
    }

    pub fn startMessagePump(self: *Window, interval_ms: u32) void {
        if (@hasDecl(backend.PlatformWindow, "startMessagePump")) {
            self.platform.startMessagePump(interval_ms);
        }
    }

    pub fn isRunning(self: *Window) bool {
        return self.running.load(.seq_cst);
    }
};

// Utility function to get absolute path
fn getAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    const cwd = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &[_][]const u8{ cwd, path });
}

// Export platform-specific types
pub const PlatformWindow = backend.PlatformWindow;

test {
    _ = @import("common.zig");
    _ = @import("native_messages.zig");
}

// sendMessage only uses the allocator and queue; no native window is needed.
fn exerciseSendMessage(allocator: std.mem.Allocator) !void {
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();
    var window: Window = undefined;
    window.allocator = allocator;
    window.message_queue = &queue;
    try window.sendMessage("event", .{ .text = "quote\"\\\n🦦", .optional = @as(?u32, null), .values = [_]i32{ -1, 0, 42 } });
    var batch = try queue.popAll();
    defer common.freeMessages(allocator, &batch);
    try std.testing.expectEqual(1, batch.items.len);
    try std.testing.expectEqualStrings("{\"text\":\"quote\\\"\\\\\\n🦦\",\"optional\":null,\"values\":[-1,0,42]}", batch.items[0].data);
}

test "sendMessage serializes structured values and cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSendMessage, .{});
}

test "sendMessage supports separate window and queue allocators" {
    var queue = MessageQueue.init(std.testing.allocator);
    defer queue.deinit();
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var window: Window = undefined;
        window.allocator = arena.allocator();
        window.message_queue = &queue;
        try window.sendMessage("event", "owned by queue");
    }
    var batch = try queue.popAll();
    defer common.freeMessages(queue.allocator, &batch);
    try std.testing.expectEqualStrings("\"owned by queue\"", batch.items[0].data);
}

fn sendFromWorker(window: *Window, producer: usize, failed: *std.atomic.Value(bool)) void {
    for (0..100) |index| {
        window.sendMessage("worker", .{ .producer = producer, .index = index }) catch {
            failed.store(true, .release);
            return;
        };
    }
}

test "sendMessage supports concurrent producers while a consumer drains" {
    var queue = MessageQueue.init(std.testing.allocator);
    defer queue.deinit();
    var window: Window = undefined;
    window.allocator = std.testing.allocator;
    window.message_queue = &queue;
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads, 0..) |*thread, producer| {
        thread.* = try std.Thread.spawn(.{}, sendFromWorker, .{ &window, producer, &failed });
        started += 1;
    }
    var next: [4]usize = @splat(0);
    var received: usize = 0;
    var attempts: usize = 0;
    while (received < 400 and attempts < 10000) : (attempts += 1) {
        try std.testing.expect(!failed.load(.acquire));
        var batch = try queue.popAll();
        defer common.freeMessages(queue.allocator, &batch);
        for (batch.items) |message| {
            const parsed = try std.json.parseFromSlice(struct { producer: usize, index: usize }, std.testing.allocator, message.data, .{});
            defer parsed.deinit();
            try std.testing.expectEqual(next[parsed.value.producer], parsed.value.index);
            next[parsed.value.producer] += 1;
            received += 1;
        }
        if (batch.items.len == 0) try std.Io.sleep(std.Options.debug_io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(400, received);
    for (next) |count| try std.testing.expectEqual(100, count);
}
