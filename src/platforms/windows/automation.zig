// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
const std = @import("std");
const geometry = @import("geometry.zig");
const backend = @import("backend.zig");
const wv = @import("webview2.zig");
const win = std.os.windows;
const WINAPI = wv.WINAPI;
const allocator = std.heap.page_allocator;
const Value = std.json.Value;
const PipeRequest = opaque {};
extern fn turf_pipe_start([*:0]const u16, *anyopaque, *const fn (*anyopaque, *PipeRequest, [*]const u8, usize) callconv(.c) void, *const fn (*anyopaque) callconv(.c) void) ?*anyopaque;
extern fn turf_pipe_stop(*anyopaque) void;
extern fn turf_pipe_reply(*PipeRequest, [*]const u8, usize, c_int) void;
extern fn turf_pipe_timeout_response(*PipeRequest, [*]const u8, usize) void;
extern fn turf_pipe_pending(*PipeRequest) c_int;
extern fn turf_pipe_release(*PipeRequest) void;
extern fn turf_crop_png([*]const u8, u32, c_int, c_int, c_int, c_int, *?[*]u8, *u32) i32;
extern fn turf_free_png(?[*]u8) void;
extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(WINAPI) void;
extern "user32" fn SetForegroundWindow(win.HWND) callconv(WINAPI) win.BOOL;
extern "user32" fn GetClientRect(win.HWND, *wv.RECT) callconv(WINAPI) win.BOOL;
extern "user32" fn AdjustWindowRectEx(*wv.RECT, u32, win.BOOL, u32) callconv(WINAPI) win.BOOL;
extern "user32" fn SetWindowPos(win.HWND, ?win.HWND, c_int, c_int, c_int, c_int, u32) callconv(WINAPI) win.BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
var active: ?*Server = null;

pub const Server = struct {
    refs: usize = 1,
    window: *backend.PlatformWindow,
    pipe: ?*anyopaque = null,
    background: bool,
    stopped: bool = false,
    navigation: ?*Request = null,
    diagnostic_enabled: bool = false,
    diagnostic_starting: bool = false,
    diagnostic_session: ?[32]u8 = null,
    diagnostic_script: ?[:0]u16 = null,
    diagnostic_sequence: u64 = 0,
    diagnostic_bytes: usize = 0,
    diagnostics: std.ArrayList([]u8) = .empty,
    fn ref(self: *Server) void {
        self.refs += 1;
    }
    fn unref(self: *Server) void {
        self.refs -= 1;
        if (self.refs == 0) {
            for (self.diagnostics.items) |entry| allocator.free(entry);
            self.diagnostics.deinit(allocator);
            allocator.destroy(self);
        }
    }
    pub fn stop(self: *Server) void {
        if (self.stopped) return;
        diagnosticsStop(self);
        self.stopped = true;
        if (active == self) active = null;
        if (self.pipe) |pipe| turf_pipe_stop(pipe);
        self.pipe = null;
        if (self.navigation) |r| {
            self.navigation = null;
            r.unref();
        }
        self.unref();
    }
};
pub fn start(window: *backend.PlatformWindow, path: [:0]const u8, background: bool) !*Server {
    if (active != null) return error.AutomationAlreadyStarted;
    const name = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(name);
    const s = try allocator.create(Server);
    s.* = .{ .window = window, .background = background };
    s.pipe = turf_pipe_start(name, s, dispatch, closeWindow) orelse {
        allocator.destroy(s);
        return error.AutomationStartFailed;
    };
    active = s;
    return s;
}
fn closeWindow(context: *anyopaque) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(context));
    if (s.window.webview) |view| if (view.hwnd) |hwnd| {
        _ = wv.PostMessageW(hwnd, wv.WM_CLOSE, 0, 0);
    };
}
const Request = struct {
    refs: usize = 1,
    server: *Server,
    native: *PipeRequest,
    arena: std.heap.ArenaAllocator,
    id: Value = .null,
    params: Value = .null,
    done: bool = false,
    diagnostic_source: []const u8 = "",
    screenshot_context: i64 = 0,
    screenshot_width: i32 = 0,
    screenshot_height: i32 = 0,
    screenshot_measurement: []const u8 = "",
    screenshot_geometry: Value = .null,
    screenshot_data: []const u8 = "",
    screenshot_script: []const u8 = "",
    key: []const u8 = "",
    key_code: u32 = 0,
    modifiers: u32 = 0,
    repeat: bool = false,
    x: f64 = 0,
    y: f64 = 0,
    fn alloc(self: *Request) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn ref(self: *Request) void {
        self.refs += 1;
    }
    fn unref(self: *Request) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        turf_pipe_release(self.native);
        self.server.unref();
        self.arena.deinit();
        allocator.destroy(self);
    }
    fn pending(self: *Request) bool {
        return !self.done and !self.server.stopped and turf_pipe_pending(self.native) != 0;
    }
    fn send(self: *Request, value: anytype, close: bool) void {
        if (!self.pending()) return;
        const json = std.json.Stringify.valueAlloc(self.alloc(), value, .{}) catch return;
        if (json.len > 32 * 1024 * 1024) {
            self.fail(-32003, "Result exceeds 32 MiB");
            return;
        }
        self.done = true;
        turf_pipe_reply(self.native, json.ptr, json.len, @intFromBool(close));
    }
    fn result(self: *Request, value: anytype) void {
        self.send(.{ .jsonrpc = "2.0", .id = self.id, .result = value }, false);
    }
    fn failData(self: *Request, code: i32, message: []const u8, data: anytype) void {
        self.send(.{ .jsonrpc = "2.0", .id = self.id, .@"error" = .{ .code = code, .message = message, .data = data } }, false);
    }
    fn fail(self: *Request, code: i32, message: []const u8) void {
        self.send(.{ .jsonrpc = "2.0", .id = self.id, .@"error" = .{ .code = code, .message = message } }, false);
    }
};
fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
fn has(value: Value, name: []const u8) bool {
    return value == .object and value.object.contains(name);
}
fn string(value: Value) ?[]const u8 {
    return if (value == .string and std.mem.indexOfScalar(u8, value.string, 0) == null) value.string else null;
}
fn number(value: Value) ?f64 {
    const n: f64 = switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}
fn dimensions(view: *wv.WebView) struct { width: i32, height: i32 } {
    var rect: wv.RECT = std.mem.zeroes(wv.RECT);
    if (view.hwnd) |hwnd| {
        _ = GetClientRect(hwnd, &rect);
    }
    return .{ .width = rect.right - rect.left, .height = rect.bottom - rect.top };
}
fn property(r: *Request, view: *wv.ICoreWebView2, title: bool) []const u8 {
    var wide: ?[*:0]u16 = null;
    const hr = if (title) view.vtable.get_DocumentTitle(view, &wide) else view.vtable.get_Source(view, &wide);
    if (hr < 0 or wide == null) return "";
    defer CoTaskMemFree(wide.?);
    return std.unicode.utf16LeToUtf8Alloc(r.alloc(), std.mem.span(wide.?)) catch "";
}
fn dispatch(context: *anyopaque, native: *PipeRequest, data: [*]const u8, length: usize) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(context));
    const r = allocator.create(Request) catch {
        turf_pipe_release(native);
        return;
    };
    s.ref();
    r.* = .{ .server = s, .native = native, .arena = std.heap.ArenaAllocator.init(allocator) };
    defer r.unref();
    const parsed = std.json.parseFromSlice(Value, r.alloc(), data[0..length], .{ .allocate = .alloc_always }) catch {
        r.fail(-32700, "Invalid JSON");
        return;
    };
    const root = parsed.value;
    const id = field(root, "id");
    const valid_id = id == .string or (number(id) != null and @abs(number(id).?) <= 9007199254740991);
    const version = string(field(root, "jsonrpc")) orelse "";
    const method = string(field(root, "method")) orelse {
        r.fail(-32600, "Expected a method string");
        return;
    };
    if (!valid_id or !std.mem.eql(u8, version, "2.0")) {
        r.fail(-32600, "Expected JSON-RPC 2.0 and a string or numeric id");
        return;
    }
    r.id = id;
    r.params = if (root.object.get("params")) |params| params else .{ .object = .empty };
    if (r.params != .object) {
        r.fail(-32602, "params must be an object");
        return;
    }
    const timeout = std.json.Stringify.valueAlloc(r.alloc(), .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32001), .message = "Request timed out; execution may still finish", .data = .{ .kind = "timeout", .mayStillRun = true } } }, .{}) catch return;
    turf_pipe_timeout_response(native, timeout.ptr, timeout.len);
    execute(r, method) catch {
        r.fail(-32002, "Automation operation failed");
    };
}
fn execute(r: *Request, method: []const u8) !void {
    const s = r.server;
    const view = s.window.webview orelse {
        r.fail(-32000, "WebView2 is not ready");
        return;
    };
    const web = view.webview orelse {
        r.fail(-32000, "WebView2 is not ready");
        return;
    };
    if (!geometry.visible(view.hwnd.?) and (std.mem.eql(u8, method, "click") or std.mem.eql(u8, method, "key") or std.mem.eql(u8, method, "typeText"))) {
        r.fail(-32004, "Show the window before sending input");
        return;
    }
    if (std.mem.eql(u8, method, "info")) {
        r.result(.{ .protocolVersion = 1, .pid = GetCurrentProcessId(), .engine = "WebView2", .background = s.background, .title = property(r, web, true), .url = property(r, web, false), .loading = !view.is_page_ready, .viewport = dimensions(view), .window = try geometry.info(r.alloc(), view.hwnd.?), .methods = [_][]const u8{ "info", "evaluate", "diagnostics", "navigate", "screenshot", "resize", "screens", "move", "show", "click", "key", "typeText", "close" }, .capabilities = .{ .structuredErrors = true, .diagnostics = true, .windowPosition = true, .deferredShow = true, .windowCoordinates = "win32", .awaitPromises = true, .nativeInput = "webview2-devtools", .backgroundNativeInput = true, .keyRepeat = true, .screenshot = "viewport", .screenshotRegion = true, .maxRequestBytes = 1024 * 1024, .maxResponseBytes = 32 * 1024 * 1024 } });
    } else if (std.mem.eql(u8, method, "screens")) {
        r.result(.{ .screens = try geometry.screens(r.alloc()) });
    } else if (std.mem.eql(u8, method, "show")) {
        s.window.show();
        r.result(try geometry.info(r.alloc(), view.hwnd.?));
    } else if (std.mem.eql(u8, method, "move")) {
        const id = string(field(r.params, "screen")) orelse {
            r.fail(-32602, "screen ID required");
            return;
        };
        const xv = field(r.params, "x");
        const yv = field(r.params, "y");
        const x = if (!r.params.object.contains("x")) 0 else number(xv) orelse -1;
        const y = if (!r.params.object.contains("y")) 0 else number(yv) orelse -1;
        const av = field(r.params, "anchor");
        const anchor = if (!r.params.object.contains("anchor")) "top-left" else string(av) orelse "";
        if (x < 0 or y < 0 or !(std.mem.eql(u8, anchor, "top-left") or std.mem.eql(u8, anchor, "top-right") or std.mem.eql(u8, anchor, "bottom-left") or std.mem.eql(u8, anchor, "bottom-right"))) {
            r.fail(-32602, "move requires nonnegative offsets and a corner anchor");
            return;
        }
        geometry.move(r.alloc(), view.hwnd.?, id, x, y, anchor) catch |err| {
            if (err == error.UnknownScreen) r.fail(-32602, "Unknown screen; call screens again") else if (err == error.WindowStateUnsupported) r.fail(-32004, "Restore the window before moving") else r.fail(-32002, "Window move failed");
            return;
        };
        r.result(try geometry.info(r.alloc(), view.hwnd.?));
    } else if (std.mem.eql(u8, method, "diagnostics")) {
        try diagnosticsRequest(r);
    } else if (std.mem.eql(u8, method, "evaluate")) {
        const expression = string(field(r.params, "expression")) orelse {
            r.fail(-32602, "expression must be a string");
            return;
        };
        const quoted = try std.json.Stringify.valueAlloc(r.alloc(), expression, .{});
        const script = try std.fmt.allocPrint(r.alloc(), "(async()=>{{const expression={s};\n{s}\n}})()", .{ quoted, @embedFile("../../automation/evaluate.js") });
        try call(r, "Runtime.evaluate", .{ .expression = script, .awaitPromise = true, .returnByValue = true }, .evaluate);
    } else if (std.mem.eql(u8, method, "screenshot")) {
        const size = dimensions(view);
        r.screenshot_width = size.width;
        r.screenshot_height = size.height;
        const options = try std.json.Stringify.valueAlloc(r.alloc(), r.params, .{});
        const quoted = try std.json.Stringify.valueAlloc(r.alloc(), options, .{});
        r.screenshot_script = try std.fmt.allocPrint(r.alloc(), "(()=>{{const options={s},viewportWidth={d},viewportHeight={d};\n{s}\n}})()", .{ quoted, size.width, size.height, @embedFile("../../automation/screenshot.js") });
        try call(r, "Page.getFrameTree", .{}, .screenshot_frame);
    } else if (std.mem.eql(u8, method, "navigate")) {
        const url = string(field(r.params, "url")) orelse {
            r.fail(-32602, "url must be a string");
            return;
        };
        if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "file://") or std.mem.startsWith(u8, url, "about:"))) {
            r.fail(-32602, "url must use http, https, file, or about");
            return;
        }
        if (s.navigation != null or !view.is_page_ready) {
            r.fail(-32000, "A navigation is already in progress");
            return;
        }
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(r.alloc(), url);
        r.ref();
        s.navigation = r;
        view.is_page_ready = false;
        if (web.vtable.Navigate(web, wide) < 0) {
            s.navigation = null;
            r.unref();
            view.is_page_ready = true;
            r.fail(-32002, "Navigation failed");
        }
    } else if (std.mem.eql(u8, method, "resize")) {
        const width = number(field(r.params, "width")) orelse 0;
        const height = number(field(r.params, "height")) orelse 0;
        if (width < 1 or width > 8192 or height < 1 or height > 8192) {
            r.fail(-32602, "width and height must be numbers from 1 to 8192");
            return;
        }
        var rect = wv.RECT{ .left = 0, .top = 0, .right = @intFromFloat(width), .bottom = @intFromFloat(height) };
        _ = AdjustWindowRectEx(&rect, 0x00cf0000, .FALSE, 0);
        if (!SetWindowPos(view.hwnd.?, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, 0x0016).toBool()) {
            r.fail(-32002, "Resize failed");
            return;
        }
        r.result(dimensions(view));
    } else if (std.mem.eql(u8, method, "click")) {
        const size = dimensions(view);
        r.x = number(field(r.params, "x")) orelse -1;
        r.y = number(field(r.params, "y")) orelse -1;
        if (r.x < 0 or r.y < 0 or r.x >= @as(f64, @floatFromInt(size.width)) or r.y >= @as(f64, @floatFromInt(size.height)) or !getModifiers(r)) {
            r.fail(-32602, "click requires viewport coordinates and valid modifiers");
            return;
        }
        var zoom: f64 = 1;
        if (view.controller) |controller| {
            _ = controller.vtable.get_ZoomFactor(controller, &zoom);
        }
        if (zoom > 0) {
            r.x /= zoom;
            r.y /= zoom;
        }
        focus(r, view);
        try mouse(r, "mousePressed", .mouse_down);
    } else if (std.mem.eql(u8, method, "key")) {
        r.key = string(field(r.params, "key")) orelse {
            r.fail(-32602, "key must be a string");
            return;
        };
        const repeat: Value = r.params.object.get("repeat") orelse .{ .bool = false };
        if (repeat != .bool or !getModifiers(r)) {
            r.fail(-32602, "Invalid repeat or modifiers");
            return;
        }
        r.repeat = repeat.bool;
        r.key_code = keyCode(r.key) orelse {
            r.fail(-32602, "Unsupported key");
            return;
        };
        if (r.key.len == 1) {
            var character = r.key[0];
            const plain = "1234567890-=[]\\;',./`";
            const shifted = "!@#$%^&*()_+{}|:\"<>?~";
            if (std.ascii.isUpper(character) or std.mem.indexOfScalar(u8, shifted, character) != null) r.modifiers |= 8;
            if (r.modifiers & 8 != 0) {
                if (std.ascii.isLower(character)) character = std.ascii.toUpper(character) else if (std.mem.indexOfScalar(u8, plain, character)) |i| character = shifted[i];
            }
            r.key = try r.alloc().dupe(u8, &.{character});
        }
        focus(r, view);
        try keyEvent(r, false);
    } else if (std.mem.eql(u8, method, "typeText")) {
        const text = string(field(r.params, "text")) orelse {
            r.fail(-32602, "text must be a string");
            return;
        };
        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(r.alloc(), text);
        if (utf16.len > 16384) {
            r.fail(-32602, "text exceeds 16384 UTF-16 code units");
            return;
        }
        focus(r, view);
        try call(r, "Input.insertText", .{ .text = text }, .dispatched);
    } else if (std.mem.eql(u8, method, "close")) {
        r.send(.{ .jsonrpc = "2.0", .id = r.id, .result = .{ .closing = true } }, true);
    } else r.fail(-32601, "Method not found");
}
fn focus(r: *Request, view: *wv.WebView) void {
    if (!r.server.background) {
        _ = SetForegroundWindow(view.hwnd.?);
        if (view.controller) |controller| {
            _ = controller.vtable.MoveFocus(controller, 0);
        }
    }
}
fn getModifiers(r: *Request) bool {
    const values = r.params.object.get("modifiers") orelse return true;
    if (values != .array or values.array.items.len > 16) return false;
    for (values.array.items) |value| {
        const name = string(value) orelse return false;
        if (std.mem.eql(u8, name, "alt")) r.modifiers |= 1 else if (std.mem.eql(u8, name, "control")) r.modifiers |= 2 else if (std.mem.eql(u8, name, "meta")) r.modifiers |= 4 else if (std.mem.eql(u8, name, "shift")) r.modifiers |= 8 else return false;
    }
    return true;
}
fn keyCode(key: []const u8) ?u32 {
    const names = [_][]const u8{ "Backspace", "Tab", "Enter", "Escape", "Space", "PageUp", "PageDown", "End", "Home", "ArrowLeft", "ArrowUp", "ArrowRight", "ArrowDown", "Delete" };
    const codes = [_]u32{ 8, 9, 13, 27, 32, 33, 34, 35, 36, 37, 38, 39, 40, 46 };
    for (names, codes) |name, code| if (std.mem.eql(u8, key, name)) return code;
    if (key.len == 1) {
        const c = key[0];
        if (std.ascii.isAlphanumeric(c) or c == ' ') return std.ascii.toUpper(c);
        const pairs = [_][]const u8{ ";:", "=+", ",<", "-_", ".>", "/?", "`~", "[{", "\\|", "]}", "'\"" };
        const virtual = [_]u32{ 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0, 0xdb, 0xdc, 0xdd, 0xde };
        for (pairs, virtual) |pair, code| if (std.mem.indexOfScalar(u8, pair, c) != null) return code;
        if (std.mem.indexOfScalar(u8, "!@#$%^&*()", c)) |i| return "1234567890"[i];
    }
    return null;
}
const Action = enum(u32) { diagnostic_installed, diagnostic_started, evaluate, screenshot_frame, screenshot_world, screenshot_measure, screenshot_check, screenshot, dispatched, mouse_down, key_down };
fn mouse(r: *Request, kind: []const u8, action: Action) !void {
    try call(r, "Input.dispatchMouseEvent", .{ .type = kind, .x = r.x, .y = r.y, .button = "left", .clickCount = 1, .modifiers = r.modifiers }, action);
}
fn keyEvent(r: *Request, up: bool) !void {
    const printable = r.key.len == 1 or std.mem.eql(u8, r.key, "Space");
    const key = if (std.mem.eql(u8, r.key, "Space")) " " else r.key;
    const text = if (!up and printable and r.modifiers & 7 == 0) key else "";
    try call(r, "Input.dispatchKeyEvent", .{ .type = if (up) @as([]const u8, "keyUp") else "keyDown", .key = key, .text = text, .windowsVirtualKeyCode = r.key_code, .nativeVirtualKeyCode = r.key_code, .modifiers = r.modifiers, .autoRepeat = !up and r.repeat }, if (up) .dispatched else .key_down);
}
const Callback = extern struct {
    vtable: *const VTable = &vtable_impl,
    refs: u32 = 1,
    request: *Request,
    action: Action,
    registered_web: ?*wv.ICoreWebView2 = null,
    const VTable = extern struct {
        query: *const fn (*Callback, *const win.GUID, *?*anyopaque) callconv(WINAPI) i32,
        add: *const fn (*Callback) callconv(WINAPI) u32,
        release: *const fn (*Callback) callconv(WINAPI) u32,
        invoke: *const fn (*Callback, i32, ?[*:0]const u16) callconv(WINAPI) i32,
    };
    const vtable_impl = VTable{ .query = query, .add = add, .release = release, .invoke = invoke };
    fn query(self: *Callback, iid: *const win.GUID, out: *?*anyopaque) callconv(WINAPI) i32 {
        // IUnknown and ICoreWebView2CallDevToolsProtocolMethodCompletedHandler.
        const unknown = win.GUID{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
        const handler = if (self.action == .diagnostic_installed) win.GUID.parse("{b99369f3-9b11-47b5-bc6f-8e7895fcea17}") else win.GUID.parse("{5c4889f0-5ef6-4c5a-952c-d8f1b92d0574}");
        if (std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&unknown)) or std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&handler))) {
            out.* = self;
            _ = add(self);
            return 0;
        }
        out.* = null;
        return @bitCast(@as(u32, 0x80004002));
    }
    fn add(self: *Callback) callconv(WINAPI) u32 {
        self.refs += 1;
        return self.refs;
    }
    fn release(self: *Callback) callconv(WINAPI) u32 {
        self.refs -= 1;
        const count = self.refs;
        if (count == 0) {
            if (self.registered_web) |web| _ = web.vtable.Release(web);
            self.request.unref();
            allocator.destroy(self);
        }
        return count;
    }
    fn invoke(self: *Callback, hr: i32, json: ?[*:0]const u16) callconv(WINAPI) i32 {
        const r = self.request;
        if (!r.pending()) {
            if (self.action == .diagnostic_installed) {
                if (hr >= 0 and json != null) if (self.registered_web) |web| {
                    _ = web.vtable.RemoveScriptToExecuteOnDocumentCreated(web, json.?);
                };
                r.server.diagnostic_starting = false;
                r.server.diagnostic_enabled = false;
            } else if (self.action == .diagnostic_started and !r.server.stopped) diagnosticsStop(r.server);
            return 0;
        }
        if (self.action == .diagnostic_installed) {
            if (hr < 0 or json == null) {
                diagnosticsStop(r.server);
                r.fail(-32002, "Cannot install diagnostics script");
                return 0;
            }
            r.server.diagnostic_script = allocator.dupeSentinel(u16, std.mem.span(json.?), 0) catch {
                if (self.registered_web) |web| _ = web.vtable.RemoveScriptToExecuteOnDocumentCreated(web, json.?);
                diagnosticsStop(r.server);
                r.fail(-32002, "Out of memory");
                return 0;
            };
            call(r, "Runtime.evaluate", .{ .expression = r.diagnostic_source, .returnByValue = true }, .diagnostic_started) catch {
                diagnosticsStop(r.server);
                r.fail(-32002, "Cannot attach diagnostics");
            };
            return 0;
        }
        if (hr < 0 or json == null) {
            if (self.action == .diagnostic_started) diagnosticsStop(r.server);
            r.failData(-32002, "WebView2 operation failed", .{ .kind = "native_error", .context = "main", .nativeCode = hr });
            return 0;
        }
        completed(r, self.action, std.mem.span(json.?)) catch {
            if (self.action == .diagnostic_started) diagnosticsStop(r.server);
            r.fail(-32002, "Invalid WebView2 result");
        };
        return 0;
    }
};
fn call(r: *Request, method: []const u8, params: anytype, action: Action) !void {
    const view = r.server.window.webview.?.webview.?;
    const json = try std.json.Stringify.valueAlloc(r.alloc(), params, .{});
    const name = try std.unicode.utf8ToUtf16LeAllocZ(r.alloc(), method);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(r.alloc(), json);
    const callback = try allocator.create(Callback);
    r.ref();
    callback.* = .{ .request = r, .action = action };
    const hr = view.vtable.CallDevToolsProtocolMethod(view, name, wide, callback);
    if (hr < 0) {
        if (action == .diagnostic_started) diagnosticsStop(r.server);
        r.failData(-32002, "WebView2 rejected the operation", .{ .kind = "native_error", .context = "main", .nativeCode = hr });
    }
    _ = Callback.release(callback);
}
fn screenshotViewportValid(r: *Request) bool {
    const size = dimensions(r.server.window.webview.?);
    if (size.width == r.screenshot_width and size.height == r.screenshot_height) return true;
    r.fail(-32004, "Viewport changed during screenshot; retry");
    return false;
}
fn measureScreenshot(r: *Request, action: Action) !void {
    try call(r, "Runtime.evaluate", .{ .expression = r.screenshot_script, .contextId = r.screenshot_context, .returnByValue = true }, action);
}
fn screenshotResult(r: *Request) !void {
    var data = r.screenshot_data;
    if (data.len < 44) return error.InvalidScreenshot;
    var header: [33]u8 = undefined;
    try std.base64.standard.Decoder.decode(&header, data[0..44]);
    var width = std.mem.readInt(u32, header[16..20], .big);
    var height = std.mem.readInt(u32, header[20..24], .big);
    const region = field(r.screenshot_geometry, "region");
    const x = number(field(region, "x")) orelse return error.InvalidScreenshot;
    const y = number(field(region, "y")) orelse return error.InvalidScreenshot;
    const rw = number(field(region, "width")) orelse return error.InvalidScreenshot;
    const rh = number(field(region, "height")) orelse return error.InvalidScreenshot;
    // Use original PNG dimensions, including Chromium/DPI rounding at viewport edges.
    const sx = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(r.screenshot_width));
    const sy = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(r.screenshot_height));
    const left: c_int = @intFromFloat(@round(x * sx));
    const top: c_int = @intFromFloat(@round(y * sy));
    const right: c_int = @intFromFloat(@round((x + rw) * sx));
    const bottom: c_int = @intFromFloat(@round((y + rh) * sy));
    if (left != 0 or top != 0 or right != width or bottom != height) {
        const png = try r.alloc().alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(data));
        try std.base64.standard.Decoder.decode(png, data);
        var cropped: ?[*]u8 = null;
        var length: u32 = 0;
        const hr = turf_crop_png(png.ptr, @intCast(png.len), left, top, right - left, bottom - top, &cropped, &length);
        defer turf_free_png(cropped);
        if (hr < 0 or cropped == null) {
            r.failData(-32002, "Native PNG crop failed", .{ .nativeCode = hr });
            return;
        }
        const encoded = try r.alloc().alloc(u8, std.base64.standard.Encoder.calcSize(length));
        data = std.base64.standard.Encoder.encode(encoded, cropped.?[0..length]);
        width = @intCast(right - left);
        height = @intCast(bottom - top);
    }
    r.result(.{ .format = "png", .data = data, .width = width, .height = height, .region = region });
}
fn completed(r: *Request, action: Action, wide: []const u16) !void {
    const json = try std.unicode.utf16LeToUtf8Alloc(r.alloc(), wide);
    const parsed = try std.json.parseFromSlice(Value, r.alloc(), json, .{ .allocate = .alloc_always });
    const root = parsed.value;
    if (field(root, "error") != .null or field(root, "exceptionDetails") != .null) {
        if (action == .screenshot_check) {
            r.fail(-32004, "Page changed during screenshot; retry");
            return;
        }
        if (action == .diagnostic_started) diagnosticsStop(r.server);
        r.failData(-32002, "JavaScript or WebView2 operation failed", .{ .kind = "native_error", .context = "main" });
        return;
    }
    switch (action) {
        .diagnostic_installed => unreachable,
        .diagnostic_started => {
            r.server.diagnostic_starting = false;
            const session = r.server.diagnostic_session.?;
            r.result(.{ .enabled = true, .session = &session });
        },
        .evaluate => {
            const result = field(root, "result");
            const value = field(result, "value");
            const encoded = string(value) orelse {
                r.failData(-32003, "JavaScript result is not serializable", .{ .kind = "serialization_error", .context = "main" });
                return;
            };
            const envelope = std.json.parseFromSlice(Value, r.alloc(), encoded, .{}) catch {
                r.failData(-32003, "JavaScript result is not serializable", .{ .kind = "serialization_error", .context = "main" });
                return;
            };
            const ok = field(envelope.value, "ok");
            if (ok != .bool) {
                r.failData(-32003, "JavaScript result is not serializable", .{ .kind = "serialization_error", .context = "main" });
                return;
            }
            const payload = field(envelope.value, if (ok.bool) "result" else "error");
            if (payload != .object) {
                r.failData(-32003, "JavaScript result is not serializable", .{ .kind = "serialization_error", .context = "main" });
                return;
            }
            if (ok.bool) r.result(field(envelope.value, "result")) else {
                const detail = field(envelope.value, "error");
                const kind = string(field(detail, "kind")) orelse "javascript_exception";
                r.failData(if (std.mem.eql(u8, kind, "serialization_error")) -32003 else -32002, string(field(detail, "message")) orelse "JavaScript evaluation failed", detail);
            }
        },
        .screenshot_frame => {
            const frame = string(field(field(field(root, "frameTree"), "frame"), "id")) orelse return error.InvalidScreenshot;
            try call(r, "Page.createIsolatedWorld", .{ .frameId = frame, .worldName = "TurfScreenshot" }, .screenshot_world);
        },
        .screenshot_world => {
            const context = field(root, "executionContextId");
            if (context != .integer) return error.InvalidScreenshot;
            r.screenshot_context = context.integer;
            try measureScreenshot(r, .screenshot_measure);
        },
        .screenshot_measure, .screenshot_check => {
            if (!screenshotViewportValid(r)) return;
            const encoded = string(field(field(root, "result"), "value")) orelse return error.InvalidScreenshot;
            if (action == .screenshot_check) {
                if (!std.mem.eql(u8, encoded, r.screenshot_measurement)) {
                    r.fail(-32004, "Page, selector or viewport changed during screenshot; retry");
                    return;
                }
                try screenshotResult(r);
                return;
            }
            const measured = try std.json.parseFromSlice(Value, r.alloc(), encoded, .{ .allocate = .alloc_always });
            const failure = field(measured.value, "error");
            if (failure != .null) {
                const code = number(field(failure, "code")) orelse return error.InvalidScreenshot;
                r.failData(@intFromFloat(code), string(field(failure, "message")) orelse "Invalid screenshot region", field(failure, "data"));
                return;
            }
            r.screenshot_geometry = measured.value;
            r.screenshot_measurement = encoded;
            try call(r, "Page.captureScreenshot", .{ .format = "png", .captureBeyondViewport = false }, .screenshot);
        },
        .screenshot => {
            if (!screenshotViewportValid(r)) return;
            r.screenshot_data = string(field(root, "data")) orelse return error.InvalidScreenshot;
            try measureScreenshot(r, .screenshot_check);
        },
        .mouse_down => try mouse(r, "mouseReleased", .dispatched),
        .key_down => try keyEvent(r, true),
        .dispatched => r.result(.{ .dispatched = true }),
    }
}
pub fn navigationCompleted(view: *wv.WebView, success: bool) void {
    const s = active orelse return;
    if (s.window.webview != view) return;
    const r = s.navigation orelse return;
    s.navigation = null;
    defer r.unref();
    if (!r.pending()) return;
    if (success) r.result(.{ .url = property(r, view.webview.?, false) }) else r.fail(-32002, "Navigation failed");
}

pub fn windowClosing(view: *wv.WebView) void {
    const s = active orelse return;
    if (s.window.webview == view) s.window.stopAutomation();
}

fn diagnosticsStop(s: *Server) void {
    s.diagnostic_enabled = false;
    s.diagnostic_starting = false;
    if (s.window.webview) |view| if (view.webview) |web| {
        if (s.diagnostic_script) |id| {
            _ = web.vtable.RemoveScriptToExecuteOnDocumentCreated(web, id);
            allocator.free(id);
            s.diagnostic_script = null;
        }
        if (s.diagnostic_session) |session| {
            var buffer: [128]u8 = undefined;
            const cleanup = std.fmt.bufPrint(&buffer, "window['__turfDiagnostics{s}']?.stop()", .{session}) catch unreachable;
            const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, cleanup) catch return;
            defer allocator.free(wide);
            _ = web.vtable.ExecuteScript(web, wide, null);
        }
    };
}
fn diagnosticsRequest(r: *Request) !void {
    const s = r.server;
    const action = if (!has(r.params, "action")) "read" else string(field(r.params, "action")) orelse "invalid";
    if (s.diagnostic_starting) {
        r.fail(-32000, "Diagnostics installation is pending");
        return;
    }
    if (std.mem.eql(u8, action, "start")) {
        if (!s.diagnostic_enabled) {
            for (s.diagnostics.items) |entry| allocator.free(entry);
            s.diagnostics.clearRetainingCapacity();
            s.diagnostic_bytes = 0;
            s.diagnostic_sequence = 0;
            var guid: win.GUID = undefined;
            if (CoCreateGuid(&guid) < 0) return error.GuidFailed;
            s.diagnostic_session = std.fmt.bytesToHex(std.mem.asBytes(&guid), .lower);
            const source = try std.fmt.allocPrint(r.alloc(), "(()=>{{const HANDLER_NAME='turfDiagnostics{s}',STATE_KEY='__turfDiagnostics{s}';\n{s}\n}})()", .{ s.diagnostic_session.?, s.diagnostic_session.?, @embedFile("../../automation/diagnostics.js") });
            r.diagnostic_source = source;
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(r.alloc(), source);
            const callback = try allocator.create(Callback);
            r.ref();
            callback.* = .{ .request = r, .action = .diagnostic_installed };
            s.diagnostic_starting = true;
            s.diagnostic_enabled = true;
            const web = s.window.webview.?.webview.?;
            _ = web.vtable.AddRef(web);
            callback.registered_web = web;
            const hr = web.vtable.AddScriptToExecuteOnDocumentCreated(web, wide, callback);
            if (hr < 0) {
                s.diagnostic_starting = false;
                diagnosticsStop(s);
                r.fail(-32002, "Cannot install diagnostics script");
            }
            _ = Callback.release(callback);
            return;
        }
    } else if (std.mem.eql(u8, action, "stop")) diagnosticsStop(s) else if (!std.mem.eql(u8, action, "read")) {
        r.fail(-32602, "action must be start, read, or stop");
        return;
    }
    const session: ?[]const u8 = if (s.diagnostic_session) |*id| id else null;
    if (!std.mem.eql(u8, action, "read")) {
        r.result(.{ .enabled = s.diagnostic_enabled, .session = session });
        return;
    }
    if (has(r.params, "session")) {
        const supplied = string(field(r.params, "session")) orelse "";
        if (session == null or !std.mem.eql(u8, supplied, session.?)) {
            r.fail(-32004, "Diagnostic session changed; read again without the old cursor");
            return;
        }
    }
    const after = if (!has(r.params, "after")) 0 else number(field(r.params, "after")) orelse -1;
    const limit = if (!has(r.params, "limit")) 64 else number(field(r.params, "limit")) orelse -1;
    if (after < 0 or after > @as(f64, @floatFromInt(s.diagnostic_sequence)) or @floor(after) != after or limit < 1 or limit > 256 or @floor(limit) != limit) {
        r.fail(-32602, "after must be an existing nonnegative cursor; limit must be 1 through 256");
        return;
    }
    var entries: std.ArrayList(Value) = .empty;
    var available: u64 = 0;
    var cursor = s.diagnostic_sequence;
    for (s.diagnostics.items) |json| {
        const entry = (try std.json.parseFromSlice(Value, r.alloc(), json, .{})).value;
        const sequence: u64 = @intFromFloat(number(field(entry, "sequence")).?);
        if (@as(f64, @floatFromInt(sequence)) > after) {
            available += 1;
            if (@as(f64, @floatFromInt(entries.items.len)) < limit) {
                try entries.append(r.alloc(), entry);
                cursor = sequence;
            }
        }
    }
    r.result(.{ .enabled = s.diagnostic_enabled, .session = session, .entries = entries.items, .nextCursor = cursor, .latestCursor = s.diagnostic_sequence, .droppedSinceCursor = s.diagnostic_sequence - @as(u64, @intFromFloat(after)) - available, .capacity = 256, .maxBytes = 1024 * 1024, .bufferBytes = s.diagnostic_bytes });
}
extern "ole32" fn CoCreateGuid(*win.GUID) callconv(WINAPI) i32;
const FileTime = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetSystemTimeAsFileTime(*FileTime) callconv(WINAPI) void;
fn receivedMilliseconds() f64 {
    var time: FileTime = undefined;
    GetSystemTimeAsFileTime(&time);
    return @as(f64, @floatFromInt((@as(u64, time.high) << 32) | time.low)) / 10000.0 - 11644473600000.0;
}
// Called before the embedding application's message callback. Diagnostic batches
// remain private to this endpoint; arbitrary application messages still pass through.
pub fn diagnosticMessage(message: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSlice(Value, a, message, .{}) catch return false;
    const marker = string(field(parsed.value, "turfDiagnostics")) orelse return false;
    if (!std.mem.startsWith(u8, marker, "__turfDiagnostics")) return false;
    const s = active orelse return true;
    const session = s.diagnostic_session orelse return true;
    if (!s.diagnostic_enabled or !std.mem.eql(u8, marker["__turfDiagnostics".len..], &session)) return true;
    diagnosticBatch(s, a, field(parsed.value, "body")) catch {};
    return true;
}
fn diagnosticBatch(s: *Server, a: std.mem.Allocator, body: Value) !void {
    const document = string(field(body, "documentId")) orelse return;
    const entries = field(body, "entries");
    if (document.len > 128 or entries != .array or entries.array.items.len > 64) return;
    const lost = number(field(body, "dropped")) orelse 0;
    if (lost > 0) s.diagnostic_sequence += @intFromFloat(@min(lost, 1000000));
    for (entries.array.items) |item| {
        if (item != .object) continue;
        var entry = item;
        s.diagnostic_sequence += 1;
        try entry.object.put(a, "sequence", .{ .integer = @intCast(s.diagnostic_sequence) });
        try entry.object.put(a, "documentId", .{ .string = document });
        const url = string(field(body, "url")) orelse "";
        try entry.object.put(a, "url", .{ .string = url });
        try entry.object.put(a, "isMainFrame", field(body, "isMainFrame"));
        try entry.object.put(a, "receivedAt", .{ .float = receivedMilliseconds() });
        const encoded = try std.json.Stringify.valueAlloc(a, entry, .{});
        if (encoded.len > 8192) continue;
        const owned = try allocator.dupe(u8, encoded);
        s.diagnostics.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
        s.diagnostic_bytes += owned.len;
        while (s.diagnostics.items.len > 256 or s.diagnostic_bytes > 1024 * 1024) {
            const old = s.diagnostics.orderedRemove(0);
            s.diagnostic_bytes -= old.len;
            allocator.free(old);
        }
    }
}
