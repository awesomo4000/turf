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
fn getAbsolutePath(allocator: std.mem.Allocator, path: [:0]const u8) ![:0]const u8 {
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

        return Window{
            .allocator = allocator,
            .config = config,
            .is_window_created = false,
        };
    }

    // Clean up window resources
    pub fn deinit(self: *Window) void {
        _ = self;
        // Any cleanup needed goes here
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
        const abs_path = try getAbsolutePath(self.allocator, path);
        defer self.allocator.free(abs_path);

        std.debug.print("Loading file from path: {s}\n", .{abs_path});
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

// Callback functions for the Cocoa bridge

export fn onWindowMoved(x: c_int, y: c_int, width: c_int, height: c_int) void {
    std.debug.print("Window moved to: ({d}, {d}) with size: {d}x{d}\n", .{ x, y, width, height });
}

export fn onWindowResized(x: c_int, y: c_int, width: c_int, height: c_int) void {
    std.debug.print("Window resized to: ({d}, {d}) with size: {d}x{d}\n", .{ x, y, width, height });
}

export fn onJavaScriptMessage(message_cstr: [*:0]const u8) void {
    const message = std.mem.span(message_cstr);
    std.debug.print("Received message from JavaScript: {s}\n", .{message});

    // In a real implementation, you would parse the message to get the type
    // and dispatch to the appropriate parser
    // For now, we'll just log it
}
