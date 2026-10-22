// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000

// The public C ABI used by Turf. Keep GTK/WebKit objects opaque: importing the
// full headers hits unsupported GLib macros in Zig 0.16's C translator.
pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const WebKitWebView = opaque {};
pub const WebKitSettings = opaque {};
pub const WebKitUserContentManager = opaque {};
pub const WebKitUserScript = opaque {};
pub const JSCValue = opaque {};
pub const GMainLoop = opaque {};
pub const GMainContext = opaque {};
pub const GCancellable = opaque {};
pub const GObject = opaque {};
pub const GAsyncResult = opaque {};
pub const GClosure = opaque {};
pub const gboolean = c_int;
pub const GCallback = *const fn () callconv(.c) void;
pub const GClosureNotify = *const fn (?*anyopaque, ?*GClosure) callconv(.c) void;
pub const GSourceFunc = *const fn (?*anyopaque) callconv(.c) gboolean;
pub const GDestroyNotify = *const fn (?*anyopaque) callconv(.c) void;
pub const GAsyncReadyCallback = *const fn (?*GObject, ?*GAsyncResult, ?*anyopaque) callconv(.c) void;
pub const G_PRIORITY_DEFAULT: c_int = 0;
pub const WEBKIT_USER_CONTENT_INJECT_TOP_FRAME: c_uint = 1;
pub const WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END: c_uint = 1;

pub extern fn g_setenv([*:0]const u8, [*:0]const u8, gboolean) gboolean;
pub extern fn g_free(?*anyopaque) void;
pub extern fn g_signal_connect_data(?*anyopaque, [*:0]const u8, GCallback, ?*anyopaque, ?GClosureNotify, c_uint) c_ulong;
pub extern fn g_timeout_add_full(c_int, c_uint, GSourceFunc, ?*anyopaque, ?GDestroyNotify) c_uint;
pub extern fn g_main_loop_new(?*GMainContext, gboolean) ?*GMainLoop;
pub extern fn g_main_loop_run(?*GMainLoop) void;
pub extern fn g_main_loop_quit(?*GMainLoop) void;
pub extern fn g_main_loop_unref(?*GMainLoop) void;

pub extern fn gtk_init() void;
pub extern fn gtk_is_initialized() gboolean;
pub extern fn gtk_window_new() ?*GtkWidget;
pub extern fn gtk_window_set_title(?*GtkWindow, [*:0]const u8) void;
pub extern fn gtk_window_set_default_size(?*GtkWindow, c_int, c_int) void;
pub extern fn gtk_window_set_child(?*GtkWindow, ?*GtkWidget) void;
pub extern fn gtk_widget_show(?*GtkWidget) void;

pub extern fn webkit_web_view_new() ?*GtkWidget;
pub extern fn webkit_web_view_get_user_content_manager(?*WebKitWebView) ?*WebKitUserContentManager;
pub extern fn webkit_web_view_get_settings(?*WebKitWebView) ?*WebKitSettings;
pub extern fn webkit_web_view_load_uri(?*WebKitWebView, [*:0]const u8) void;
pub extern fn webkit_web_view_load_html(?*WebKitWebView, [*:0]const u8, ?[*:0]const u8) void;
pub extern fn webkit_web_view_evaluate_javascript(?*WebKitWebView, [*:0]const u8, isize, ?[*:0]const u8, ?[*:0]const u8, ?*GCancellable, ?GAsyncReadyCallback, ?*anyopaque) void;
pub extern fn webkit_settings_set_enable_developer_extras(?*WebKitSettings, gboolean) void;
pub extern fn webkit_settings_set_javascript_can_access_clipboard(?*WebKitSettings, gboolean) void;
pub extern fn webkit_user_script_new([*:0]const u8, c_uint, c_uint, ?[*]const [*:0]const u8, ?[*]const [*:0]const u8) ?*WebKitUserScript;
pub extern fn webkit_user_script_unref(?*WebKitUserScript) void;
pub extern fn webkit_user_content_manager_add_script(?*WebKitUserContentManager, ?*WebKitUserScript) void;
pub extern fn webkit_user_content_manager_register_script_message_handler(?*WebKitUserContentManager, [*:0]const u8, ?[*:0]const u8) gboolean;
pub extern fn jsc_value_to_string(*JSCValue) ?[*:0]u8;
