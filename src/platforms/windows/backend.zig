// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

// Windows platform backend using WebView2
const std = @import("std");
const webview2 = @import("webview2.zig");
const common = @import("../../common.zig");
const automation = @import("automation.zig");

const windows = std.os.windows;
const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const RECT = windows.RECT;

pub const PlatformWindow = struct {
    allocator: std.mem.Allocator,
    webview: ?*webview2.WebView,
    message_queue: *common.MessageQueue,
    message_pump_thread: ?std.Thread,
    config: common.WindowConfig,
    js_inject_code: [:0]const u8,
    running: std.atomic.Value(bool),
    initial_html: ?[]const u8,
    prng: std.Random.DefaultPrng,
    automation_server: ?*automation.Server = null,
    initial_url: ?[:0]u8 = null,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        config: common.WindowConfig,
        message_queue: *common.MessageQueue,
    ) !Self {
        return Self{
            .allocator = allocator,
            .webview = null,
            .message_queue = message_queue,
            .message_pump_thread = null,
            .config = config,
            .js_inject_code = "",
            .running = std.atomic.Value(bool).init(true),
            .initial_html = null,
            .prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.real.now(std.Options.debug_io).toNanoseconds())),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stopAutomation();
        if (self.initial_url) |url| self.allocator.free(url);
        self.running.store(false, .seq_cst);
        
        // Clear global reference
        if (global_platform_window == self) {
            global_platform_window = null;
        }
        
        if (self.message_pump_thread) |thread| {
            thread.join();
        }
        
        if (self.webview) |wv| {
            wv.deinit();
        }
        
        if (self.initial_html) |html| {
            self.allocator.free(html);
        }
        
        // Free the copied JavaScript code
        if (self.js_inject_code.len > 0) {
            self.allocator.free(self.js_inject_code);
        }
    }

    pub fn createWindow(self: *Self, config: common.WindowConfig, js_inject_code: [:0]const u8) void {
        std.log.debug("Windows backend: createWindow called", .{});
        std.log.debug("Windows backend: Received {} bytes of JavaScript to inject", .{js_inject_code.len});
        self.config = config;
        
        // Copy the JavaScript code since the caller might free it
        self.js_inject_code = self.allocator.dupeSentinel(u8, js_inject_code, 0) catch {
            std.debug.print("Failed to copy JavaScript code\n", .{});
            self.js_inject_code = "";
            return;
        };
        
        // Store the JavaScript to inject later
        // Window creation happens in run()
        std.log.debug("Windows backend: Window config stored, actual creation deferred to run()", .{});
    }

    pub fn show(self: *Self) void {
        self.config.start_hidden = false;
        if (self.webview) |view| if (view.hwnd) |hwnd| {
            @import("geometry.zig").show(hwnd, view.options.no_focus);
        };
    }

    pub fn setPosition(self: *Self, x: i32, y: i32) !void {
        self.config.geometry.x = x;
        self.config.geometry.y = y;
        if (self.webview) |view| if (view.hwnd) |hwnd| {
            try @import("geometry.zig").setPosition(hwnd, x, y);
        };
    }

    pub fn loadURL(self: *Self, url: [:0]const u8) void {
        if (self.webview) |wv| {
            wv.navigate(url);
        } else {
            const copy = self.allocator.dupeSentinel(u8, url, 0) catch return;
            if (self.initial_url) |old| self.allocator.free(old);
            if (self.initial_html) |old| self.allocator.free(old);
            self.initial_html = null;
            self.initial_url = copy;
        }
    }

    pub fn startAutomation(self: *Self, path: [:0]const u8, background: bool) !void {
        if (self.automation_server != null) return error.AutomationAlreadyStarted;
        self.automation_server = try automation.start(self, path, background);
    }

    pub fn stopAutomation(self: *Self) void {
        if (self.automation_server) |server| server.stop();
        self.automation_server = null;
    }

    pub fn loadHTML(self: *Self, html: [:0]const u8, base_uri: ?[:0]const u8) void {
        _ = base_uri; // WebView2 doesn't use base_uri for data URIs
        
        const html_slice = std.mem.sliceTo(html, 0);
        std.log.debug("Windows backend: loadHTML called with {} bytes of HTML", .{html_slice.len});
        
        if (self.webview) |wv| {
            // If WebView exists, navigate now
            var data_uri_buffer: [65536]u8 = undefined;
            const data_uri = std.fmt.bufPrint(&data_uri_buffer, "data:text/html,{s}", .{html_slice}) catch {
                std.debug.print("Failed to create data URI\n", .{});
                return;
            };
            
            var data_uri_z_buffer: [65536]u8 = undefined;
            const data_uri_z = std.mem.printSentinel(&data_uri_z_buffer, "{s}", .{data_uri}, 0) catch {
                std.debug.print("Failed to create null-terminated URI\n", .{});
                return;
            };
            
            std.log.debug("Windows backend: Navigating to data URI", .{});
            wv.navigate(data_uri_z);
        } else {
            // Store HTML for later when WebView is created
            std.log.debug("Windows backend: Storing HTML for later", .{});
            const copy = self.allocator.dupe(u8, html_slice) catch {
                std.debug.print("Failed to store HTML\n", .{});
                return;
            };
            if (self.initial_html) |old| self.allocator.free(old);
            if (self.initial_url) |old| self.allocator.free(old);
            self.initial_url = null;
            self.initial_html = copy;
        }
    }

    pub fn evalJS(self: *Self, js_code: [:0]const u8) void {
        if (self.webview) |wv| {
            wv.executeScript(js_code);
        }
    }

    pub fn setHTML(self: *Self, html: [:0]const u8) void {
        self.loadHTML(html, null);
    }

    pub fn run(self: *Self) void {
        std.log.debug("Windows backend: run() called", .{});
        
        // Set global reference for message handling now that we have a stable pointer
        global_platform_window = self;
        
        // Create WebView2 now with stored config
        const options = webview2.WebViewOptions{
            .title = self.config.title,
            .start_hidden = self.config.start_hidden,
            .x = self.config.geometry.x,
            .y = self.config.geometry.y,
            .width = @intCast(self.config.geometry.width),
            .height = @intCast(self.config.geometry.height),
            .url = self.initial_url,
            .no_focus = self.config.no_focus or (if (self.automation_server) |server| server.background else false),
            .html = self.initial_html,
            .js_inject = blk: {
                const js = if (self.js_inject_code.len > 0) self.js_inject_code else null;
                if (js) |j| {
                    std.log.debug("Backend passing {} bytes of JS to WebView2", .{j.len});
                    if (j.len > 0) {
                        std.log.debug("First few bytes: ", .{});
                        for (j[0..@min(j.len, 10)]) |byte| {
                            std.log.debug("{x:0>2} ", .{byte});
                        }
                        std.log.debug("", .{});
                    }
                }
                break :blk js;
            },
        };
        
        std.log.debug("Windows backend: Creating WebView2 in run()", .{});
        self.webview = webview2.WebView.init(self.allocator, options) catch |err| {
            std.debug.print("Failed to create WebView2: {}\n", .{err});
            return;
        };
        
        if (self.webview) |wv| {
            std.log.debug("Windows backend: Starting WebView2 message loop", .{});
            wv.run() catch |err| {
                std.debug.print("WebView2 run failed: {}\n", .{err});
            };
            std.log.debug("Windows backend: WebView2 message loop ended", .{});
        }
    }

    pub fn startMessagePump(self: *Self, interval_ms: u32) void {
        const ThreadContext = struct {
            window: *PlatformWindow,
            interval_ms: u32,
        };
        
        const context = ThreadContext{
            .window = self,
            .interval_ms = interval_ms,
        };
        
        self.message_pump_thread = std.Thread.spawn(.{}, messagePumpThread, .{context}) catch |err| {
            std.debug.print("Failed to start message pump thread: {}\n", .{err});
            return;
        };
    }

    fn messagePumpThread(context: anytype) void {
        const window = context.window;
        const interval_ms = context.interval_ms;
        
        while (window.running.load(.seq_cst)) {
            // Process pending messages
            var messages = window.message_queue.popAll() catch {
                std.Io.sleep(std.Options.debug_io, .fromMilliseconds(interval_ms), .awake) catch break;
                continue;
            };
            defer messages.deinit(window.allocator);
            
            for (messages.items) |msg| {
                defer {
                    window.allocator.free(msg.type);
                    window.allocator.free(msg.data);
                }
                
                // Format message for PostWebMessageAsJson
                const json_msg = std.fmt.allocPrint(
                    window.allocator,
                    \\{{
                    \\  "type": "{s}",
                    \\  "data": {s}
                    \\}}
                ,
                    .{ msg.type, msg.data },
                ) catch continue;
                defer window.allocator.free(json_msg);
                
                // Queue message for UI thread delivery
                if (window.webview) |wv| {
                    // Queuing message
                    wv.queueMessage(json_msg) catch {
                        std.debug.print("Failed to queue message\n", .{});
                    };
                }
            }
            
            std.Io.sleep(std.Options.debug_io, .fromMilliseconds(interval_ms), .awake) catch break;
        }
    }
};

// Global reference for message handling
var global_platform_window: ?*PlatformWindow = null;

// Export message handler for turf
pub fn onJavaScriptMessage(message: []const u8) void {
    // Parse the message and handle it
    if (global_platform_window) |window| {
        handleJavaScriptMessage(window, message) catch |err| {
            std.debug.print("Error handling JS message: {}\n", .{err});
        };
    } else {
        std.debug.print("No platform window set for message handling\n", .{});
    }
}

fn handleJavaScriptMessage(window: *PlatformWindow, message: []const u8) !void {
    // For the demo app, we'll handle messages directly here
    // Parse the JSON message
    const parsed = std.json.parseFromSlice(std.json.Value, window.allocator, message, .{}) catch {
        std.debug.print("Failed to parse message: {s}\n", .{message});
        return;
    };
    defer parsed.deinit();
    
    const root = parsed.value.object;
    const msg_type = root.get("type") orelse return;
    
    // Handle different message types
    if (std.mem.eql(u8, msg_type.string, "ping")) {
        // Send pong response
        try window.message_queue.push("pong", try window.allocator.dupeSentinel(u8, "{\"message\":\"Pong from native!\"}", 0));
    } else if (std.mem.eql(u8, msg_type.string, "echo")) {
        // Echo back the message
        if (root.get("message")) |msg| {
            const response = try std.fmt.allocPrintSentinel(window.allocator, "{{\"message\":\"{s}\"}}", .{msg.string}, 0);
            try window.message_queue.push("echo_response", response);
        }
    } else if (std.mem.eql(u8, msg_type.string, "get_time")) {
        // Send current time
        const timestamp = std.Io.Clock.real.now(std.Options.debug_io).toSeconds();
        const response = try std.fmt.allocPrintSentinel(window.allocator, "{{\"time\":\"{}\"}}", .{timestamp}, 0);
        try window.message_queue.push("time_response", response);
    } else if (std.mem.eql(u8, msg_type.string, "get_random")) {
        // Generate random number using stored PRNG
        const random = window.prng.random();
        
        var min: u32 = 1;
        var max: u32 = 100;
        
        // The message structure is flattened, so check for min/max directly
        if (root.get("min")) |min_val| {
            min = @intCast(min_val.integer);
        }
        if (root.get("max")) |max_val| {
            max = @intCast(max_val.integer);
        }
        
        const value = random.intRangeAtMost(u32, min, max);
        const response = try std.fmt.allocPrintSentinel(window.allocator, "{{\"value\":{}}}", .{value}, 0);
        try window.message_queue.push("random_response", response);
    } else if (std.mem.eql(u8, msg_type.string, "custom")) {
        // Handle custom message
        if (root.get("message")) |msg| {
            const response = try std.fmt.allocPrintSentinel(window.allocator, "{{\"message\":\"Received: {s}\"}}", .{msg.string}, 0);
            try window.message_queue.push("custom_response", response);
        }
    } else if (std.mem.eql(u8, msg_type.string, "turf_ready")) {
        std.log.debug("Turf JavaScript ready", .{});
    }
}
