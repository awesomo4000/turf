const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");

// Import platform-specific backend
const backend = switch (builtin.os.tag) {
    .macos => @import("platforms/macos/backend.zig"),
    .linux => @import("platforms/linux/backend.zig"),
    else => @compileError("Unsupported platform"),
};

// JavaScript bridge code to inject
const turf_js_inject = @embedFile("web/turf.js");

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
    \\    // Poll for messages every 16ms (~60Hz)
    \\    setInterval(function() {
    \\        const messages = window.__turf_get_messages();
    \\        if (messages.length > 0) {
    \\            console.log('Polling got messages:', messages);
    \\        }
    \\        messages.forEach(function(msg) {
    \\            if (window.turf && window.turf._handleNativeMessage) {
    \\                console.log('Calling _handleNativeMessage with:', msg);
    \\                window.turf._handleNativeMessage(msg);
    \\            }
    \\        });
    \\    }, 16);
    \\})();
;

// Re-export common types
pub const WindowConfig = common.WindowConfig;
pub const Geometry = common.Geometry;
pub const MessageQueue = common.MessageQueue;

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
        const js_code = std.fmt.allocPrintZ(
            self.allocator,
            "{s}\n{s}",
            .{ turf_js_inject, polling_js },
        ) catch {
            // If allocation fails, use just the turf.js
            // (it's already null-terminated from embedFile)
            self.platform.createWindow(self.config, turf_js_inject);
            return;
        };
        defer self.allocator.free(js_code);

        self.platform.createWindow(self.config, js_code);
    }

    pub fn show(self: *Window) void {
        self.platform.show();
    }

    pub fn loadURL(self: *Window, url: [:0]const u8) void {
        self.platform.loadURL(url);
    }

    pub fn loadFile(self: *Window, path: [:0]const u8) !void {
        // Convert to absolute path if needed
        const abs_path = try getAbsolutePath(self.allocator, path);
        defer self.allocator.free(abs_path);

        // Construct file:// URL
        const file_url = try std.fmt.allocPrintZ(
            self.allocator,
            "file://{s}",
            .{abs_path},
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
        const json_data = try std.json.stringifyAlloc(
            self.allocator,
            data,
            .{},
        );
        defer self.allocator.free(json_data);

        const json_data_z = try self.allocator.dupeZ(u8, json_data);
        // Don't free json_data_z - the queue takes ownership

        try self.message_queue.push(message_type, json_data_z);
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
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }

    return std.fs.path.join(allocator, &[_][]const u8{ cwd, path });
}

// Export platform-specific callbacks
pub usingnamespace backend;
