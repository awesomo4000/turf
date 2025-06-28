const std = @import("std");
const testing = std.testing;
const util = @import("util.zig");

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

var js_ready: bool = false;
const turf_js_inject = @embedFile("web/turf.js");

const debounce_ms = 1000 * std.time.ns_per_ms;

// Events are sent from the native webview and include events
// from the Application as well as user-sent events from javascript

// Events sent as messages from the native application from the webview
const Event = union(enum) {
    geometry: WindowGeometry,
    willClose: void,
};

// Commands sent as messages from the JavaScript code to the native application
const Command = enum {
    show_file_dialog,
};

// Window configuration struct
pub const WindowConfig = struct {
    geometry: WindowGeometry = .{
        .x = 100,
        .y = 100,
        .width = 600,
        .height = 800,
    },
    title: [:0]const u8 = "Main Window",
};

const WindowGeometry = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

// Window struct
pub const Window = struct {
    allocator: std.mem.Allocator,
    config: WindowConfig,
    is_window_created: bool = false,
    //event_handlers: std.StringHashMap(fn (event: Event) void),
    //geom_change_timer: WindowGeometryEventTimer,
    // Initialize a new window
    pub fn init(allocator: std.mem.Allocator, config: WindowConfig) !Window {
        // Initialize the Cocoa application
        if (!NSApplicationLoad()) {
            return error.CocoaInitFailed;
        }

        // Initialize the module level allocator
        initModuleAllocator(allocator);

        // Initialize the window event timer
        //geom_change_timer = try WindowGeometryEventTimer.init();

        return Window{
            .allocator = allocator,
            .config = config,
            .is_window_created = false,
            //.geom_change_timer = geom_change_timer,
        };
    }

    // Clean up resources
    pub fn deinit(self: *Window) void {
        _ = self;
        // Deinitialize the module level allocator
        // deinitGlobalAllocator();
        // Clean up the window event timer
        //geom_change_timer.deinit();
    }

    // Create the native window
    pub fn createWindow(self: *Window) void {
        if (!self.is_window_created) {
            NSCreateWindow(
                self.config.geometry.x,
                self.config.geometry.y,
                self.config.geometry.width,
                self.config.geometry.height,
                self.config.title,
                turf_js_inject,
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
        const abs_path = try util.getAbsolutePath(
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
    pub fn evalJavaScript(self: *Window, script: [:0]const u8) void {
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
        //try geom_change_timer.startThread();
        // Run the application
        NSRunApplication();
    }

    // fn on(self: *Window, event: Event, callback: fn (event: Event) void) void {
    //     self.event_handlers.put(event, callback);
    // }
};

const WindowGeometryEvent = struct {
    payload: WindowGeometry,
};

// Thread-safe timer for debouncing window events
// const WindowGeometryEventTimer = struct {
//     mutex: std.Thread.Mutex = .{},
//     timer: ?std.time.Timer = null,
//     last_geometry_event: WindowGeometryEvent = .{ .payload = .{} },
//     thread: ?std.Thread = null,
//     should_exit: bool = false,
//     js_ready: bool = false,

//     fn init() !WindowGeometryEventTimer {
//         return WindowGeometryEventTimer{
//             .timer = try std.time.Timer.start(),
//             .js_ready = false,
//         };
//     }

//     fn deinit(self: *WindowGeometryEventTimer) void {
//         self.mutex.lock();
//         defer self.mutex.unlock();
//         self.should_exit = true;
//         if (self.thread) |thread| {
//             thread.join();
//         }
//     }

//     fn startThread(self: *WindowGeometryEventTimer) !void {
//         if (self.thread == null) {
//             self.thread = try std.Thread.spawn(
//                 .{},
//                 processEvents,
//                 .{self},
//             );
//         }
//     }

//     fn processEvents(self: *WindowGeometryEventTimer) void {
//         std.debug.print("Starting window geometry event thread\n", .{});
//         var last_sent_event: WindowGeometryEvent = .{ .payload = .{} };

//         while (true) {
//             self.mutex.lock();
//             if (self.should_exit) {
//                 self.mutex.unlock();
//                 break;
//             }
//             std.debug.print("Processing events\n", .{});
//             const event = self.last_event;
//             const is_ready = self.js_ready;
//             self.mutex.unlock();

//             // Wait for the JavaScript to be ready
//             if (!is_ready) {
//                 std.time.sleep(500 * std.time.ns_per_ms);
//                 continue;
//             }

//             // Sleep for debounce interval
//             std.debug.print("Sleeping for debounce interval\n", .{});
//             std.time.sleep(debounce_ms);
//             std.debug.print("Done sleeping for debounce interval\n", .{});

//             self.mutex.lock();
//             // Only send event if it's different from the last sent event
//             if (!std.meta.eql(event, last_sent_event)) {
//                 // Create JSON response for the web UI
//                 var response_buf: [1024]u8 = undefined;
//                 const response_fmt =
//                     \\window.nativeCommunication.sendToNative({{
//                     \\"type":"window_moved",
//                     \\"data":{{
//                     \\"x":{d},
//                     \\"y":{d},
//                     \\"width":{d},
//                     \\"height":{d}
//                     \\}}
//                     \\}});
//                 ;
//                 const response = std.fmt.bufPrintZ(
//                     &response_buf,
//                     response_fmt,
//                     .{
//                         event.payload.x,
//                         event.payload.y,
//                         event.payload.width,
//                         event.payload.height,
//                     },
//                 ) catch |err| {
//                     std.debug.print("Failed to format response: {}\n", .{err});
//                     self.mutex.unlock();
//                     continue;
//                 };
//                 std.debug.print("Evaluating JavaScript: {s}\n", .{response});
//                 NSEvaluateJavaScript(response);
//                 last_sent_event = event;
//             }
//             self.mutex.unlock();
//         }
//     }
// };

// var geom_change_timer: WindowGeometryEventTimer = undefined;

// pub fn init() !void {
//geom_change_timer = try WindowGeometryEventTimer.init();
//try geom_change_timer.startThread();
//}

// pub fn deinit() void {
//geom_change_timer.deinit();
//}

export fn onWindowGeometryEvent(x: c_int, y: c_int, width: c_int, height: c_int) void {
    _ = x;
    _ = y;
    _ = width;
    _ = height;

    // std.debug.print(
    //     "turf:onWindowGeometryEvent: ({d}, {d}, {d}, {d})\n",
    //     .{ x, y, width, height },
    // );

    // TODO: Send the event to the JavaScript code

    // geom_change_timer.mutex.lock();
    // defer geom_change_timer.mutex.unlock();

    // Update the last event
    //geom_change_timer.last_event = .{
    //    .payload = .{
    //        .x = x,
    //        .y = y,
    //        .width = width,
    //        .height = height,
    //    },
    //};
}

var module_allocator: std.mem.Allocator = undefined;

pub fn initModuleAllocator(allocator: std.mem.Allocator) void {
    module_allocator = allocator;
}
// This function is called when a message is received from the JavaScript code.
// The message is a JSON string that contains the type of message and the data.
// The data is a JSON string that contains the data of the message.
// The type of message is one of the following:
// - "js_ready"
// - "show_file_dialog"
// - "native_file_selected"
export fn onJavaScriptMessage(
    message_cstr: [*:0]const u8,
) callconv(.C) void {
    const message = std.mem.span(message_cstr);
    std.debug.print("ZIG Received message from JavaScript: {s}\n", .{message});

    // Parse JSON message
    const parsed = std.json.parseFromSlice(
        struct {
            type: []const u8,
            message: ?[]const u8 = null,
            path: ?[]const u8 = null,
            value: ?i32 = null,
        },
        module_allocator,
        message,
        .{},
    ) catch |err| {
        std.debug.print("Failed to parse message: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    // Handle different message types
    if (std.mem.eql(u8, parsed.value.type, "js_ready")) {
        js_ready = true;
        //geom_change_timer.mutex.lock();
        //geom_change_timer.js_ready = true;
        //geom_change_timer.mutex.unlock();
    } else if (std.mem.eql(u8, parsed.value.type, "show_file_dialog")) {
        NSShowOpenFileDialog();
    } else if (std.mem.eql(u8, parsed.value.type, "native_file_selected")) {
        if (parsed.value.path) |path| {
            // Create JSON response for the web UI
            var response_buf: [1024]u8 = undefined;
            const response = std.fmt.bufPrintZ(
                &response_buf,
                "window.nativeCommunication.sendToNative({{\"type\":\"file_loaded\",\"data\":{{\"filename\":\"{s}\"}}}})",
                .{path},
            ) catch |err| {
                std.debug.print("Failed to format response: {}\n", .{err});
                return;
            };
            NSEvaluateJavaScript(response);
        }
    }
}
