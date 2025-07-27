const std = @import("std");
const common = @import("../../common.zig");

// C imports for GTK4 and WebKit6
const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("webkit/webkit.h");
    @cInclude("jsc/jsc.h");
});

// Platform implementation
pub const PlatformWindow = struct {
    allocator: std.mem.Allocator,
    gtk_window: ?*c.GtkWidget = null,
    webview: ?*c.GtkWidget = null,
    user_content_manager: ?*c.WebKitUserContentManager = null,
    message_queue: *common.MessageQueue,
    main_loop: ?*c.GMainLoop = null,

    pub fn init(
        allocator: std.mem.Allocator,
        config: common.WindowConfig,
        message_queue: *common.MessageQueue,
    ) !PlatformWindow {
        _ = config; // Will be used in createWindow

        // Suppress libEGL warnings
        _ = c.g_setenv("EGL_LOG_LEVEL", "fatal", 1);

        // Initialize GTK4
        c.gtk_init();

        // Check if GTK initialized successfully
        if (c.gtk_is_initialized() == 0) {
            return error.GTKInitFailed;
        }

        return PlatformWindow{
            .allocator = allocator,
            .message_queue = message_queue,
        };
    }

    pub fn deinit(self: *PlatformWindow) void {
        _ = self;
    }

    pub fn createWindow(self: *PlatformWindow, config: common.WindowConfig, turf_js: []const u8) void {

        // Create GTK4 window
        self.gtk_window = c.gtk_window_new() orelse return;
        c.gtk_window_set_title(@ptrCast(self.gtk_window), config.title);
        c.gtk_window_set_default_size(@ptrCast(self.gtk_window), config.geometry.width, config.geometry.height);

        // Connect destroy signal
        _ = c.g_signal_connect_data(self.gtk_window, "destroy", @ptrCast(&onWindowDestroy), self, null, 0);

        // Create WebView
        self.webview = c.webkit_web_view_new();

        // Get the user content manager from the WebView
        self.user_content_manager = c.webkit_web_view_get_user_content_manager(@ptrCast(self.webview));

        // Inject the turf.js script that was passed as parameter (includes polling mechanism)
        const script = c.webkit_user_script_new(turf_js.ptr, c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END, null, null);
        c.webkit_user_content_manager_add_script(self.user_content_manager, script);
        c.webkit_user_script_unref(script);

        // Register script message handler
        _ = c.webkit_user_content_manager_register_script_message_handler(self.user_content_manager, "__turf__", null);
        _ = c.g_signal_connect_data(self.user_content_manager, "script-message-received::__turf__", @ptrCast(&onScriptMessage), self, null, 0);

        // Enable developer extras for debugging
        const settings = c.webkit_web_view_get_settings(@ptrCast(self.webview));
        c.webkit_settings_set_enable_developer_extras(settings, 1);
        c.webkit_settings_set_javascript_can_access_clipboard(settings, 1);

        // Add webview to window
        c.gtk_window_set_child(@ptrCast(self.gtk_window), self.webview);

        // Show window
        c.gtk_widget_show(self.gtk_window);
    }

    pub fn show(self: *PlatformWindow) void {
        if (self.gtk_window) |window| {
            c.gtk_widget_show(window);
        }
    }

    pub fn loadURL(self: *PlatformWindow, url: [:0]const u8) void {
        if (self.webview) |webview| {
            c.webkit_web_view_load_uri(@ptrCast(webview), url);
        }
    }

    pub fn loadHTML(self: *PlatformWindow, html: [:0]const u8, base_uri: ?[:0]const u8) void {
        if (self.webview) |webview| {
            c.webkit_web_view_load_html(@ptrCast(webview), html, base_uri orelse null);
        }
    }

    pub fn evalJS(self: *PlatformWindow, script: [:0]const u8) void {
        if (self.webview) |webview| {
            c.webkit_web_view_evaluate_javascript(@ptrCast(webview), script, -1, null, null, null, null, null);
        }
    }

    pub fn run(self: *PlatformWindow) void {
        // GTK4 uses GMainLoop
        self.main_loop = c.g_main_loop_new(null, 0);
        defer {
            if (self.main_loop) |loop| {
                c.g_main_loop_unref(loop);
                self.main_loop = null;
            }
        }

        // Don't start message pump automatically - let the app control it
        // The working Linux version calls startMessagePump separately

        if (self.main_loop) |loop| {
            c.g_main_loop_run(loop);
        }
    }

    // Start a periodic message pump (call this after window is created)
    pub fn startMessagePump(self: *PlatformWindow, interval_ms: u32) void {
        std.debug.print("Linux: Starting message pump with interval {}ms\n", .{interval_ms});
        // Try using g_timeout_add_full with default priority
        const timer_id = c.g_timeout_add_full(c.G_PRIORITY_DEFAULT, interval_ms, @ptrCast(&messagePumpCallback), self, null);
        std.debug.print("Linux: Timer ID: {}\n", .{timer_id});
    }
};

// Periodic message pump callback
fn messagePumpCallback(user_data: ?*anyopaque) callconv(.C) c.gboolean {
    if (user_data) |window_ptr| {
        const window: *PlatformWindow = @ptrCast(@alignCast(window_ptr));

        // Check if we have a webview before processing
        if (window.webview == null) {
            return 1;
        }

        // Process message queue
        _ = processMessageQueue(window);
    }

    return 1; // Return TRUE to keep the timer running
}

// Process the message queue
fn processMessageQueue(window: *PlatformWindow) c.gboolean {
    const messages = window.message_queue.popAll() catch |err| {
        std.debug.print("Error popping messages: {}\n", .{err});
        return 1; // Keep timer running even on error
    };
    defer messages.deinit();

    if (messages.items.len == 0) return 1; // Keep timer running

    std.debug.print("Processing {} messages from queue\n", .{messages.items.len});

    // Build JavaScript to inject messages
    var arena = std.heap.ArenaAllocator.init(window.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var js_buffer = std.ArrayList(u8).init(allocator);
    const writer = js_buffer.writer();

    // Add each message to the queue
    writer.writeAll("window.__turf_message_queue.push(") catch return 1;
    for (messages.items, 0..) |msg, i| {
        if (i > 0) writer.writeAll(",") catch return 1;
        // Send the data as a JavaScript object, not a string
        std.fmt.format(writer, "{{type:'{s}',data:{s}}}", .{ msg.type, msg.data }) catch return 1;
        std.debug.print("Sending message to JS: type={s}, data={s}\n", .{ msg.type, msg.data });
    }
    writer.writeAll(");") catch return 1;

    const js_code = allocator.dupeZ(u8, js_buffer.items) catch return 1;

    // Execute JavaScript
    if (window.webview) |webview| {
        c.webkit_web_view_evaluate_javascript(@ptrCast(webview), js_code, -1, null, null, null, null, null);
    }

    // Free the messages
    for (messages.items) |msg| {
        window.allocator.free(msg.type);
        window.allocator.free(msg.data);
    }

    return 1; // Keep timer running
}

// Window destroy callback
fn onWindowDestroy(widget: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.C) void {
    _ = widget;
    if (user_data) |data| {
        const window = @as(*PlatformWindow, @ptrCast(@alignCast(data)));
        if (window.main_loop) |loop| {
            c.g_main_loop_quit(loop);
        }
    }
}

// Handle JavaScript messages from the webview
fn onScriptMessage(
    content_manager: *c.WebKitUserContentManager,
    js_value: *c.JSCValue,
    user_data: ?*anyopaque,
) callconv(.C) void {
    _ = content_manager;

    // Convert to string
    const js_string = c.jsc_value_to_string(js_value);
    if (js_string == null) return;
    defer c.g_free(js_string);

    // Convert to Zig string
    const message = std.mem.span(js_string);

    std.debug.print("Native received JS message: {s}\n", .{message});

    // Parse JSON message
    if (user_data) |window_ptr| {
        const window: *PlatformWindow = @ptrCast(@alignCast(window_ptr));

        var arena = std.heap.ArenaAllocator.init(window.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch |err| {
            std.debug.print("Failed to parse JSON message: {}\n", .{err});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            std.debug.print("Message is not a JSON object\n", .{});
            return;
        }

        const msg_type = root.object.get("type") orelse {
            std.debug.print("Message missing 'type' field\n", .{});
            return;
        };

        if (msg_type != .string) {
            std.debug.print("Message type is not a string\n", .{});
            return;
        }

        const type_str = msg_type.string;

        // Handle different message types
        if (std.mem.eql(u8, type_str, "counter_update")) {
            if (root.object.get("value")) |value| {
                if (value == .integer) {
                    std.debug.print("Counter updated to: {}\n", .{value.integer});
                    // Send echo back to JS
                    const echo_data = std.fmt.allocPrint(window.allocator, "{{\"value\":{}}}", .{value.integer}) catch return;
                    const echo_data_z = window.allocator.dupeZ(u8, echo_data) catch {
                        window.allocator.free(echo_data);
                        return;
                    };
                    window.allocator.free(echo_data); // Free the original, keep the dupeZ

                    // Don't free echo_data_z - the queue takes ownership
                    window.message_queue.push("counter_echo", echo_data_z) catch |err| {
                        std.debug.print("Failed to push echo message: {}\n", .{err});
                        window.allocator.free(echo_data_z);
                    };
                }
            }
        } else if (std.mem.eql(u8, type_str, "counter_reset")) {
            std.debug.print("Counter reset\n", .{});
        } else if (std.mem.eql(u8, type_str, "custom_message")) {
            if (root.object.get("message")) |msg| {
                if (msg == .string) {
                    std.debug.print("Custom message: {s}\n", .{msg.string});
                }
            }
        } else if (std.mem.eql(u8, type_str, "show_file_dialog")) {
            std.debug.print("File dialog requested (not implemented on Linux)\n", .{});
        } else if (std.mem.eql(u8, type_str, "turf_ready")) {
            std.debug.print("Turf ready!\n", .{});
        } else if (std.mem.eql(u8, type_str, "ping")) {
            std.debug.print("Ping received, sending pong...\n", .{});

            // Message queue is always valid (it's a pointer to the Window's queue)

            // Send pong response
            const pong_data = std.fmt.allocPrint(window.allocator, "{{\"message\":\"PONG from native!\",\"timestamp\":{}}}", .{std.time.timestamp()}) catch {
                std.debug.print("Failed to format pong data\n", .{});
                return;
            };

            const pong_data_z = window.allocator.dupeZ(u8, pong_data) catch {
                std.debug.print("Failed to dupeZ pong data\n", .{});
                window.allocator.free(pong_data);
                return;
            };
            window.allocator.free(pong_data); // Free the original, keep the dupeZ

            // Don't free pong_data_z - the queue takes ownership
            window.message_queue.push("pong", pong_data_z) catch |err| {
                std.debug.print("Failed to push pong message: {}\n", .{err});
                window.allocator.free(pong_data_z);
            };
        } else if (std.mem.eql(u8, type_str, "test")) {
            if (root.object.get("message")) |msg| {
                if (msg == .string) {
                    std.debug.print("Test message received: {s}\n", .{msg.string});
                }
            }
        } else if (std.mem.eql(u8, type_str, "echo")) {
            std.debug.print("Echo message received, root object keys:\n", .{});
            var iter = root.object.iterator();
            while (iter.next()) |entry| {
                std.debug.print("  key: {s}\n", .{entry.key_ptr.*});
            }

            if (root.object.get("message")) |msg| {
                std.debug.print("Found message field, type: {}\n", .{msg});
                if (msg == .string) {
                    std.debug.print("Echo request: {s}\n", .{msg.string});

                    // Send echo response
                    const echo_response = std.fmt.allocPrint(window.allocator, "{{\"message\":\"Echo: {s}\"}}", .{msg.string}) catch return;
                    const echo_response_z = window.allocator.dupeZ(u8, echo_response) catch {
                        window.allocator.free(echo_response);
                        return;
                    };
                    window.allocator.free(echo_response);

                    window.message_queue.push("echo_response", echo_response_z) catch |err| {
                        std.debug.print("Failed to push echo response: {}\n", .{err});
                        window.allocator.free(echo_response_z);
                    };
                } else {
                    std.debug.print("Message field is not a string\n", .{});
                }
            } else {
                std.debug.print("No message field found in echo request\n", .{});
            }
        } else if (std.mem.eql(u8, type_str, "get_time")) {
            std.debug.print("Time requested\n", .{});

            // Get current time and format it
            const timestamp = std.time.timestamp();
            const time_str = std.fmt.allocPrint(window.allocator, "{{\"time\":\"{d}\"}}", .{timestamp}) catch return;
            const time_str_z = window.allocator.dupeZ(u8, time_str) catch {
                window.allocator.free(time_str);
                return;
            };
            window.allocator.free(time_str);

            window.message_queue.push("time_response", time_str_z) catch |err| {
                std.debug.print("Failed to push time response: {}\n", .{err});
                window.allocator.free(time_str_z);
            };
        } else if (std.mem.eql(u8, type_str, "get_random")) {
            // Check both data.min/max and direct min/max
            var min: i64 = 0;
            var max: i64 = 100;

            if (root.object.get("data")) |data| {
                if (data.object.get("min")) |m| {
                    if (m == .integer) min = m.integer;
                }
                if (data.object.get("max")) |m| {
                    if (m == .integer) max = m.integer;
                }
            } else {
                if (root.object.get("min")) |m| {
                    if (m == .integer) min = m.integer;
                }
                if (root.object.get("max")) |m| {
                    if (m == .integer) max = m.integer;
                }
            }

            // Generate random number
            var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
            const random_value = prng.random().intRangeAtMost(i64, min, max);

            const random_str = std.fmt.allocPrint(window.allocator, "{{\"value\":{}}}", .{random_value}) catch return;
            const random_str_z = window.allocator.dupeZ(u8, random_str) catch {
                window.allocator.free(random_str);
                return;
            };
            window.allocator.free(random_str);

            window.message_queue.push("random_response", random_str_z) catch |err| {
                std.debug.print("Failed to push random response: {}\n", .{err});
                window.allocator.free(random_str_z);
            };
        } else if (std.mem.eql(u8, type_str, "custom")) {
            // Check both data.message and direct message
            const msg = if (root.object.get("data")) |data|
                data.object.get("message")
            else
                root.object.get("message");

            if (msg) |msg_value| {
                if (msg_value == .string) {
                    std.debug.print("Custom message: {s}\n", .{msg_value.string});

                    // Send custom response
                    const response = std.fmt.allocPrint(window.allocator, "{{\"message\":\"Received: {s}\"}}", .{msg_value.string}) catch return;
                    const response_z = window.allocator.dupeZ(u8, response) catch {
                        window.allocator.free(response);
                        return;
                    };
                    window.allocator.free(response);

                    window.message_queue.push("custom_response", response_z) catch |err| {
                        std.debug.print("Failed to push custom response: {}\n", .{err});
                        window.allocator.free(response_z);
                    };
                }
            }
        } else {
            std.debug.print("Unknown message type: {s}\n", .{type_str});
        }
    }
}
