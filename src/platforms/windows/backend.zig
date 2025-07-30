// Windows platform backend using WebView2
const std = @import("std");
const webview2 = @import("webview2.zig");
const common = @import("../../common.zig");

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
            .prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp())),
        };
    }

    pub fn deinit(self: *Self) void {
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
        std.debug.print("Windows backend: createWindow called\n", .{});
        std.debug.print("Windows backend: Received {} bytes of JavaScript to inject\n", .{js_inject_code.len});
        self.config = config;
        
        // Copy the JavaScript code since the caller might free it
        self.js_inject_code = self.allocator.dupeZ(u8, js_inject_code) catch {
            std.debug.print("Failed to copy JavaScript code\n", .{});
            self.js_inject_code = "";
            return;
        };
        
        // Store the JavaScript to inject later
        // Window creation happens in run()
        std.debug.print("Windows backend: Window config stored, actual creation deferred to run()\n", .{});
    }

    pub fn show(self: *Self) void {
        // WebView2 wrapper handles window visibility
        _ = self;
    }

    pub fn loadURL(self: *Self, url: [:0]const u8) void {
        if (self.webview) |wv| {
            wv.navigate(url);
        }
    }

    pub fn loadHTML(self: *Self, html: [:0]const u8, base_uri: ?[:0]const u8) void {
        _ = base_uri; // WebView2 doesn't use base_uri for data URIs
        
        const html_slice = std.mem.sliceTo(html, 0);
        std.debug.print("Windows backend: loadHTML called with {} bytes of HTML\n", .{html_slice.len});
        
        if (self.webview) |wv| {
            // If WebView exists, navigate now
            var data_uri_buffer: [65536]u8 = undefined;
            const data_uri = std.fmt.bufPrint(&data_uri_buffer, "data:text/html,{s}", .{html_slice}) catch {
                std.debug.print("Failed to create data URI\n", .{});
                return;
            };
            
            var data_uri_z_buffer: [65536]u8 = undefined;
            const data_uri_z = std.fmt.bufPrintZ(&data_uri_z_buffer, "{s}", .{data_uri}) catch {
                std.debug.print("Failed to create null-terminated URI\n", .{});
                return;
            };
            
            std.debug.print("Windows backend: Navigating to data URI\n", .{});
            wv.navigate(data_uri_z);
        } else {
            // Store HTML for later when WebView is created
            std.debug.print("Windows backend: Storing HTML for later\n", .{});
            self.initial_html = self.allocator.dupe(u8, html_slice) catch {
                std.debug.print("Failed to store HTML\n", .{});
                return;
            };
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
        std.debug.print("Windows backend: run() called\n", .{});
        
        // Set global reference for message handling now that we have a stable pointer
        global_platform_window = self;
        
        // Create WebView2 now with stored config
        const options = webview2.WebViewOptions{
            .title = self.config.title,
            .width = @intCast(self.config.geometry.width),
            .height = @intCast(self.config.geometry.height),
            .url = null,
            .html = self.initial_html,
            .js_inject = blk: {
                const js = if (self.js_inject_code.len > 0) self.js_inject_code else null;
                if (js) |j| {
                    std.debug.print("Backend passing {} bytes of JS to WebView2\n", .{j.len});
                    if (j.len > 0) {
                        std.debug.print("First few bytes: ", .{});
                        for (j[0..@min(j.len, 10)]) |byte| {
                            std.debug.print("{x:0>2} ", .{byte});
                        }
                        std.debug.print("\n", .{});
                    }
                }
                break :blk js;
            },
        };
        
        std.debug.print("Windows backend: Creating WebView2 in run()\n", .{});
        self.webview = webview2.WebView.init(self.allocator, options) catch |err| {
            std.debug.print("Failed to create WebView2: {}\n", .{err});
            return;
        };
        
        if (self.webview) |wv| {
            std.debug.print("Windows backend: Starting WebView2 message loop\n", .{});
            wv.run() catch |err| {
                std.debug.print("WebView2 run failed: {}\n", .{err});
            };
            std.debug.print("Windows backend: WebView2 message loop ended\n", .{});
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
            const messages = window.message_queue.popAll() catch {
                std.time.sleep(interval_ms * std.time.ns_per_ms);
                continue;
            };
            defer messages.deinit();
            
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
            
            std.time.sleep(interval_ms * std.time.ns_per_ms);
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
        try window.message_queue.push("pong", try window.allocator.dupeZ(u8, "{\"message\":\"Pong from native!\"}"));
    } else if (std.mem.eql(u8, msg_type.string, "echo")) {
        // Echo back the message
        if (root.get("message")) |msg| {
            const response = try std.fmt.allocPrintZ(window.allocator, "{{\"message\":\"{s}\"}}", .{msg.string});
            try window.message_queue.push("echo_response", response);
        }
    } else if (std.mem.eql(u8, msg_type.string, "get_time")) {
        // Send current time
        const timestamp = std.time.timestamp();
        const response = try std.fmt.allocPrintZ(window.allocator, "{{\"time\":\"{}\"}}", .{timestamp});
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
        const response = try std.fmt.allocPrintZ(window.allocator, "{{\"value\":{}}}", .{value});
        try window.message_queue.push("random_response", response);
    } else if (std.mem.eql(u8, msg_type.string, "custom")) {
        // Handle custom message
        if (root.get("message")) |msg| {
            const response = try std.fmt.allocPrintZ(window.allocator, "{{\"message\":\"Received: {s}\"}}", .{msg.string});
            try window.message_queue.push("custom_response", response);
        }
    } else if (std.mem.eql(u8, msg_type.string, "turf_ready")) {
        std.debug.print("Turf JavaScript ready\n", .{});
    }
}