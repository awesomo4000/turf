// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const turf = @import("turf");

extern fn TestInstallControl(path: [*:0]const u8) void;
extern fn TestRemoveControl() void;
extern fn TestClose() void;
extern fn TestResources() void;
var active: ?*turf.Window = null;
pub export fn embedderTestCommand(command: [*:0]const u8) void {
    const text = std.mem.span(command);
    const window = active orelse return;
    if (std.mem.eql(u8, text, "close")) {
        TestClose();
    } else if (std.mem.eql(u8, text, "stop")) {
        window.stopAutomation();
    } else if (std.mem.startsWith(u8, text, "eval:")) {
        window.evalJavaScript(text[5.. :0]);
    } else if (std.mem.startsWith(u8, text, "file:")) {
        window.loadFile(text[5.. :0]) catch @panic("loadFile failed");
    } else if (std.mem.startsWith(u8, text, "url:")) {
        window.loadURL(text[4.. :0]);
    } else if (std.mem.startsWith(u8, text, "navigate-flood:")) {
        for (0..1000) |index| window.sendMessage("old-page", .{ .index = index }) catch break;
        window.loadURL(text[15.. :0]);
    } else if (std.mem.eql(u8, text, "prototype")) {
        window.sendMessage("prototype", .{ .__proto__ = .{ .marker = true } }) catch @panic("send failed");
    } else if (std.mem.eql(u8, text, "send-new")) {
        window.sendMessage("new-page", true) catch @panic("send failed");
    } else if (std.mem.eql(u8, text, "resources")) {
        TestResources();
    } else if (std.mem.eql(u8, text, "flood")) {
        var accepted: usize = 0;
        for (0..10000) |index| {
            window.sendMessage("flood", .{ .index = index }) catch break;
            accepted += 1;
        }
        std.debug.print("FLOOD_ACCEPTED {d}\n", .{accepted});
    }
}

pub fn main(init: std.process.Init) !void {
    var checked: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer if (checked.deinit() != 0) @panic("embedder leaked memory");
    const allocator = checked.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const endpoint = args.next() orelse return error.MissingEndpoint;
    const round_arg = args.next();
    if (round_arg) |value| {
        if (std.mem.eql(u8, value, "wrong-thread")) {
            const thread = try std.Thread.spawn(.{}, wrongThread, .{});
            thread.join();
            return;
        }
    }
    const rounds = if (round_arg) |value| try std.fmt.parseInt(usize, value, 10) else 1;
    const control = try std.fmt.allocPrintSentinel(allocator, "{s}.command", .{endpoint}, 0);
    defer allocator.free(control);
    for (0..rounds) |round| {
        const round_endpoint = if (rounds == 1) try allocator.dupeSentinel(u8, endpoint, 0) else try std.fmt.allocPrintSentinel(allocator, "{s}.{d}", .{ endpoint, round }, 0);
        defer allocator.free(round_endpoint);
        var queue = turf.MessageQueue.init(allocator);
        {
            defer queue.deinit();
            var window = try turf.Window.init(allocator, .{
                .geometry = .{ .x = 0, .y = 0, .width = 520, .height = 200 },
                .title = "Turf embedder lifecycle test",
                .no_focus = true,
                .start_hidden = true,
            }, &queue);
            {
                defer window.deinit();
                active = &window;
                defer active = null;
                TestInstallControl(control);
                defer TestRemoveControl();
                window.createWindow();
                try window.setPosition(12, 34);
                window.loadString("<!doctype html><title>Embedder lifecycle</title><p>Lifecycle test</p>");
                try window.startAutomation(round_endpoint);
                // Stopping and restarting before run must release the endpoint.
                window.stopAutomation();
                window.stopAutomation();
                try window.startAutomation(round_endpoint);
                try window.run();
                if (window.isRunning()) return error.StillRunning;
                std.debug.print("RUN_RETURNED\n", .{});
                window.stopAutomation();
            }
            // Queue ownership stays with the embedder after window teardown.
            try queue.pushCopy("after-close", "null");
            std.debug.print("WINDOW_DEINITIALIZED\n", .{});
        }
        TestResources();
        std.debug.print("QUEUE_DEINITIALIZED round={d}\n", .{round});
    }
}

fn wrongThread() void {
    var queue = turf.MessageQueue.init(std.heap.page_allocator);
    defer queue.deinit();
    var window = turf.Window.init(std.heap.page_allocator, .{
        .geometry = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        .title = "Wrong-thread probe",
        .no_focus = true,
        .start_hidden = true,
    }, &queue) catch |err| {
        if (err != error.WrongThread) @panic("unexpected initialization error");
        std.debug.print("WRONG_THREAD_REJECTED\n", .{});
        return;
    };
    window.deinit();
    @panic("initialization on worker thread was accepted");
}
