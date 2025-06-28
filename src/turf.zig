const std = @import("std");
const testing = std.testing;

// External Cocoa bridge functions declared in cocoa_bridge.m
extern fn NSApplicationLoad() bool;
extern fn NSCreateWindow(x: c_int, y: c_int, w: c_int, h: c_int, title: [*:0]const u8) void;
extern fn NSRunApplication() void;
extern fn NSLoadURL(url: [*:0]const u8) void;
extern fn NSLoadLocalFile(path: [*:0]const u8) void;
extern fn NSLoadString(html_content: [*:0]const u8) void;
extern fn NSEvaluateJavaScript(script: [*:0]const u8) void;
extern fn NSShowOpenFileDialog() void;

// Helper function to get absolute path
fn getAbsolutePath(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
) ![:0]const u8 {
    // Check if path is already absolute (starts with '/')
    if (path.len > 0 and path[0] == '/') {
        return allocator.dupeZ(u8, path);
    }

    // Get current working directory
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Create absolute path by joining cwd and path
    const abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, path });
    return allocator.dupeZ(u8, abs_path);
}

// Message handling
var message_parser_allocator: std.mem.Allocator = undefined;
var message_parsers = std.StringHashMap(MessageParser).init(undefined);

// Function type for message handlers
pub const MessageParser = *const fn (allocator: std.mem.Allocator, message: []const u8) anyerror!void;

// Initialize the message parsers
pub fn initMessageParsers(allocator: std.mem.Allocator) void {
    message_parser_allocator = allocator;
    message_parsers = std.StringHashMap(MessageParser).init(allocator);
}

// Clean up message parsers
pub fn deinitMessageParsers() void {
    message_parsers.deinit();
}

// Register a new message parser
pub fn registerMessageParser(message_type: []const u8, parser: MessageParser) !void {
    try message_parsers.put(message_type, parser);
}

// Window configuration struct
pub const WindowConfig = struct {
    x: i32 = 100,
    y: i32 = 100,
    width: i32 = 800,
    height: i32 = 600,
    title: [:0]const u8 = "Turf Window",
};

// Window struct
pub const Window = struct {
    allocator: std.mem.Allocator,
    config: WindowConfig,
    is_window_created: bool = false,

    // Initialize a new window
    pub fn init(allocator: std.mem.Allocator, config: WindowConfig) !Window {
        // Initialize the Cocoa application
        if (!NSApplicationLoad()) {
            return error.CocoaInitFailed;
        }

        // Initialize the window event timer
        window_event_timer = try WindowEventTimer.init();
        try window_event_timer.startThread();

        return Window{
            .allocator = allocator,
            .config = config,
            .is_window_created = false,
        };
    }

    // Clean up window resources
    pub fn deinit(self: *Window) void {
        _ = self;
        // Clean up the window event timer
        window_event_timer.deinit();
    }

    // Create the native window
    pub fn createWindow(self: *Window) void {
        if (!self.is_window_created) {
            NSCreateWindow(
                self.config.x,
                self.config.y,
                self.config.width,
                self.config.height,
                self.config.title,
            );
            self.is_window_created = true;
        }
    }

    // Load a URL in the window
    pub fn loadURL(self: *Window, url: [:0]const u8) void {
        // Create window if not already created
        if (!self.is_window_created) {
            self.createWindow();
        }
        NSLoadURL(url);
    }

    // Load a local file in the window
    pub fn loadFile(self: *Window, path: [:0]const u8) !void {
        // Create window if not already created
        if (!self.is_window_created) {
            self.createWindow();
        }

        // Convert to absolute path if needed
        const abs_path = try getAbsolutePath(
            self.allocator,
            path,
        );
        defer self.allocator.free(abs_path);

        std.debug.print(
            "Loading file from path: {s}\n",
            .{abs_path},
        );
        NSLoadLocalFile(abs_path);
    }

    // Load HTML content as a string
    pub fn loadString(self: *Window, html_content: [:0]const u8) void {
        // Create window if not already created
        if (!self.is_window_created) {
            self.createWindow();
        }
        NSLoadString(html_content);
    }

    // Evaluate JavaScript in the window
    pub fn evaluateJavaScript(self: *Window, script: [:0]const u8) void {
        // Create window if not already created
        if (!self.is_window_created) {
            self.createWindow();
        }
        NSEvaluateJavaScript(script);
    }

    // Show an open file dialog
    pub fn showOpenFileDialog(self: *Window) void {
        // Create window if not already created
        if (!self.is_window_created) {
            self.createWindow();
        }
        NSShowOpenFileDialog();
    }

    // Run the application
    pub fn run(self: *Window) !void {
        // Create the window if it hasn't been created yet
        if (!self.is_window_created) {
            self.createWindow();
        }

        // Run the application
        NSRunApplication();
    }
};

// Thread-safe timer for debouncing window events
const WindowEventTimer = struct {
    mutex: std.Thread.Mutex = .{},
    timer: ?std.time.Timer = null,
    last_event: struct {
        x: c_int = 0,
        y: c_int = 0,
        width: c_int = 0,
        height: c_int = 0,
    } = .{},
    thread: ?std.Thread = null,
    should_exit: bool = false,
    js_ready: bool = false,

    fn init() !WindowEventTimer {
        return WindowEventTimer{
            .timer = try std.time.Timer.start(),
            .js_ready = false,
        };
    }

    fn deinit(self: *WindowEventTimer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.should_exit = true;
        if (self.thread) |thread| {
            thread.join();
        }
    }

    fn startThread(self: *WindowEventTimer) !void {
        if (self.thread == null) {
            self.thread = try std.Thread.spawn(
                .{},
                processEvents,
                .{self},
            );
        }
    }

    fn processEvents(self: *WindowEventTimer) void {
        while (true) {
            self.mutex.lock();
            if (self.should_exit) {
                self.mutex.unlock();
                break;
            }
            const event = self.last_event;
            const is_ready = self.js_ready;
            self.mutex.unlock();

            if (!is_ready) {
                std.time.sleep(50 * std.time.ns_per_ms);
                continue;
            }

            // Sleep for debounce interval (100ms)
            std.time.sleep(100 * std.time.ns_per_ms);

            self.mutex.lock();
            // Only send event if it matches the last event (no new events during sleep)
            if (std.meta.eql(event, self.last_event)) {
                // Create JSON response for the web UI
                var response_buf: [1024]u8 = undefined;
                const response_fmt =
                    \\window.onZigMessage({{"type":"window_moved",
                    \\"x":{d},
                    \\"y":{d},
                    \\"width":{d},
                    \\"height":{d}
                    \\}});
                ;
                const response = std.fmt.bufPrintZ(
                    &response_buf,
                    response_fmt,
                    .{ event.x, event.y, event.width, event.height },
                ) catch |err| {
                    std.debug.print("Failed to format response: {}\n", .{err});
                    self.mutex.unlock();
                    continue;
                };
                NSEvaluateJavaScript(response);
            }
            self.mutex.unlock();
        }
    }
};

var window_event_timer: WindowEventTimer = undefined;

pub fn init() !void {
    window_event_timer = try WindowEventTimer.init();
    try window_event_timer.startThread();
}

pub fn deinit() void {
    window_event_timer.deinit();
}

export fn onWindowEvent(x: c_int, y: c_int, width: c_int, height: c_int) void {
    window_event_timer.mutex.lock();
    defer window_event_timer.mutex.unlock();

    // Update the last event
    window_event_timer.last_event = .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };
}

export fn onJavaScriptMessage(message_cstr: [*:0]const u8) void {
    const message = std.mem.span(message_cstr);
    std.debug.print("Received message from JavaScript: {s}\n", .{message});

    // Parse JSON message
    const parsed = std.json.parseFromSlice(
        struct {
            type: []const u8,
            message: ?[]const u8 = null,
            path: ?[]const u8 = null,
            value: ?i32 = null,
        },
        message_parser_allocator,
        message,
        .{},
    ) catch |err| {
        std.debug.print("Failed to parse message: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    // Handle different message types
    if (std.mem.eql(u8, parsed.value.type, "js_ready")) {
        window_event_timer.mutex.lock();
        window_event_timer.js_ready = true;
        window_event_timer.mutex.unlock();
    } else if (std.mem.eql(u8, parsed.value.type, "show_file_dialog")) {
        NSShowOpenFileDialog();
    } else if (std.mem.eql(u8, parsed.value.type, "native_file_selected")) {
        if (parsed.value.path) |path| {
            // Create JSON response for the web UI
            var response_buf: [1024]u8 = undefined;
            const response = std.fmt.bufPrintZ(
                &response_buf,
                "window.onZigMessage({{\"type\":\"file_loaded\",\"filename\":\"{s}\"}})",
                .{path},
            ) catch |err| {
                std.debug.print("Failed to format response: {}\n", .{err});
                return;
            };
            NSEvaluateJavaScript(response);
        }
    }
}
