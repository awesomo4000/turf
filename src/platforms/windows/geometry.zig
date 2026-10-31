// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
// Coordinates follow the host process's Win32 DPI-awareness context.
const std = @import("std");
const w = std.os.windows;
const WINAPI = @import("webview2.zig").WINAPI;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const MonitorInfo = extern struct { size: u32 = @sizeOf(MonitorInfo), frame: Rect = undefined, work: Rect = undefined, flags: u32 = 0, device: [32]u16 = undefined };
const Monitor = *anyopaque;
extern "user32" fn EnumDisplayMonitors(?*anyopaque, ?*const Rect, *const fn (Monitor, ?*anyopaque, *Rect, isize) callconv(WINAPI) w.BOOL, isize) callconv(WINAPI) w.BOOL;
extern "user32" fn GetMonitorInfoW(Monitor, *MonitorInfo) callconv(WINAPI) w.BOOL;
extern "user32" fn MonitorFromWindow(w.HWND, u32) callconv(WINAPI) ?Monitor;
extern "user32" fn GetWindowRect(w.HWND, *Rect) callconv(WINAPI) w.BOOL;
extern "user32" fn IsWindowVisible(w.HWND) callconv(WINAPI) w.BOOL;
extern "user32" fn IsZoomed(w.HWND) callconv(WINAPI) w.BOOL;
extern "user32" fn IsIconic(w.HWND) callconv(WINAPI) w.BOOL;
extern "user32" fn GetForegroundWindow() callconv(WINAPI) ?w.HWND;
extern "user32" fn SetWindowPos(w.HWND, ?w.HWND, i32, i32, i32, i32, u32) callconv(WINAPI) w.BOOL;
extern "user32" fn ShowWindow(w.HWND, i32) callconv(WINAPI) w.BOOL;
extern "user32" fn SetForegroundWindow(w.HWND) callconv(WINAPI) w.BOOL;
pub const Frame = struct { x: i32, y: i32, width: i32, height: i32 };
fn frame(r: Rect) Frame {
    return .{ .x = r.left, .y = r.top, .width = r.right - r.left, .height = r.bottom - r.top };
}
pub const Screen = struct { id: []const u8, name: []const u8, isPrimary: bool, isBuiltIn: ?bool = null, scaleFactor: ?f64 = null, frame: Frame, workArea: Frame };
const Context = struct { allocator: std.mem.Allocator, list: std.ArrayList(Screen) = .empty, failed: bool = false };
fn screen(a: std.mem.Allocator, mi: MonitorInfo) !Screen {
    const id = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.sliceTo(&mi.device, 0));
    return .{ .id = id, .name = id, .isPrimary = mi.flags & 1 != 0, .frame = frame(mi.frame), .workArea = frame(mi.work) };
}
fn collect(m: Monitor, _: ?*anyopaque, _: *Rect, data: isize) callconv(WINAPI) w.BOOL {
    const context: *Context = @ptrFromInt(@as(usize, @bitCast(data)));
    var mi: MonitorInfo = .{};
    if (!GetMonitorInfoW(m, &mi).toBool()) {
        context.failed = true;
        return .FALSE;
    }
    const item = screen(context.allocator, mi) catch {
        context.failed = true;
        return .FALSE;
    };
    context.list.append(context.allocator, item) catch {
        context.failed = true;
        return .FALSE;
    };
    return .TRUE;
}
pub fn screens(a: std.mem.Allocator) ![]Screen {
    var context: Context = .{ .allocator = a };
    if (!EnumDisplayMonitors(null, null, collect, @bitCast(@intFromPtr(&context))).toBool() or context.failed) return error.DisplayEnumerationFailed;
    return context.list.toOwnedSlice(a);
}
pub const WindowInfo = struct { screen: []const u8, frame: Frame, x: i32, y: i32, visible: bool, focused: bool };
pub fn info(a: std.mem.Allocator, hwnd: w.HWND) !WindowInfo {
    const monitor = MonitorFromWindow(hwnd, 2) orelse return error.NoMonitor;
    var mi: MonitorInfo = .{};
    var rect: Rect = undefined;
    if (!GetMonitorInfoW(monitor, &mi).toBool() or !GetWindowRect(hwnd, &rect).toBool()) return error.WindowGeometryFailed;
    return .{ .screen = (try screen(a, mi)).id, .frame = frame(rect), .x = rect.left - mi.work.left, .y = rect.top - mi.work.top, .visible = visible(hwnd), .focused = GetForegroundWindow() == hwnd };
}
pub fn visible(hwnd: w.HWND) bool {
    return IsWindowVisible(hwnd).toBool();
}
pub fn show(hwnd: w.HWND, background: bool) void {
    if (visible(hwnd)) return;
    _ = ShowWindow(hwnd, if (background) 4 else 1);
    if (!background) _ = SetForegroundWindow(hwnd);
}
pub fn setPosition(hwnd: w.HWND, x: i32, y: i32) !void {
    if (!SetWindowPos(hwnd, null, x, y, 0, 0, 0x0015).toBool()) return error.WindowMoveFailed; // NOSIZE|NOZORDER|NOACTIVATE
}
pub fn move(a: std.mem.Allocator, hwnd: w.HWND, id: []const u8, x: f64, y: f64, anchor: []const u8) !void {
    if (IsZoomed(hwnd).toBool() or IsIconic(hwnd).toBool()) return error.WindowStateUnsupported;
    var rect: Rect = undefined;
    if (!GetWindowRect(hwnd, &rect).toBool()) return error.WindowGeometryFailed;
    for (try screens(a)) |item| {
        if (!std.mem.eql(u8, id, item.id)) continue;
        const max_x: f64 = @floatFromInt(@max(0, item.workArea.width - (rect.right - rect.left)));
        const max_y: f64 = @floatFromInt(@max(0, item.workArea.height - (rect.bottom - rect.top)));
        const left = std.math.clamp(if (std.mem.endsWith(u8, anchor, "right")) max_x - x else x, 0, max_x);
        const top = std.math.clamp(if (std.mem.startsWith(u8, anchor, "bottom")) max_y - y else y, 0, max_y);
        return setPosition(hwnd, item.workArea.x + @as(i32, @intFromFloat(left)), item.workArea.y + @as(i32, @intFromFloat(top)));
    }
    return error.UnknownScreen;
}
