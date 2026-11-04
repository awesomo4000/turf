// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const common = @import("common.zig");

pub fn handle(allocator: std.mem.Allocator, queue: *common.MessageQueue, prng: *std.Random.DefaultPrng, msg: []const u8) !void {

    // Parse JSON
    const parsed = std.json.parseFromSlice(
        struct {
            type: []const u8,
            message: ?[]const u8 = null,
            min: ?i32 = null,
            max: ?i32 = null,
        },
        allocator,
        msg,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();

    const msg_type = parsed.value.type;

    // Handle different message types
    if (std.mem.eql(u8, msg_type, "ping")) {
        // Send pong response - match Linux format
        const pong_str = try std.fmt.allocPrint(allocator, "{{\"message\":\"PONG from native!\",\"timestamp\":{d}}}", .{std.Io.Clock.real.now(std.Options.debug_io).toSeconds()});
        defer allocator.free(pong_str);
        try queue.pushCopy("pong", pong_str);
    } else if (std.mem.eql(u8, msg_type, "echo")) {
        // Echo back the message - match Linux format
        if (parsed.value.message) |echo_msg| {
            const text = try std.fmt.allocPrint(allocator, "Echo: {s}", .{echo_msg});
            defer allocator.free(text);
            const response = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .message = text }, .{})});
            defer allocator.free(response);
            try queue.pushCopy("echo_response", response);
        }
    } else if (std.mem.eql(u8, msg_type, "get_time")) {
        // Send current time
        const time_str = try std.fmt.allocPrint(allocator, "{{\"time\":\"{d}\"}}", .{std.Io.Clock.real.now(std.Options.debug_io).toSeconds()});
        defer allocator.free(time_str);
        try queue.pushCopy("time_response", time_str);
    } else if (std.mem.eql(u8, msg_type, "get_random")) {
        // Generate random number
        const random = prng.random();
        const min = parsed.value.min orelse 0;
        const max = parsed.value.max orelse 100;
        if (min > max) return; // Invalid requests are ignored, as with malformed JSON.
        const value = random.intRangeAtMost(i32, min, max);
        const random_str = try std.fmt.allocPrint(allocator, "{{\"value\":{d}}}", .{value});
        defer allocator.free(random_str);
        try queue.pushCopy("random_response", random_str);
    } else if (std.mem.eql(u8, msg_type, "custom")) {
        // Handle custom message
        if (parsed.value.message) |custom_msg| {
            const text = try std.fmt.allocPrint(allocator, "Received: {s}", .{custom_msg});
            defer allocator.free(text);
            const response = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .message = text }, .{})});
            defer allocator.free(response);
            try queue.pushCopy("custom_response", response);
        }
    }
}

test "native handler escapes text, rejects bad ranges and survives malformed requests" {
    const allocator = std.testing.allocator;
    var queue = common.MessageQueue.init(allocator);
    defer queue.deinit();
    var prng = std.Random.DefaultPrng.init(0);
    for ([_][]const u8{ "not JSON", "[]", "{\"type\":4}", "{\"type\":\"get_random\",\"min\":2,\"max\":1}", "{\"type\":\"get_random\",\"min\":2147483648}" }) |input| {
        try handle(allocator, &queue, &prng, input);
        try std.testing.expectEqual(0, queue.messages.items.len);
    }
    const text = "quotes\"'\\\n\x00🦦";
    for ([_][]const u8{ "echo", "custom" }) |kind| {
        const input = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .type = kind, .message = text }, .{})});
        defer allocator.free(input);
        try handle(allocator, &queue, &prng, input);
        var batch = try queue.popAll();
        defer common.freeMessages(allocator, &batch);
        try std.testing.expectEqual(1, batch.items.len);
        const value = try std.json.parseFromSlice(std.json.Value, allocator, batch.items[0].data, .{});
        defer value.deinit();
        const prefix = if (std.mem.eql(u8, kind, "echo")) "Echo: " else "Received: ";
        const expected = try std.mem.concat(allocator, u8, &.{ prefix, text });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, value.value.object.get("message").?.string);
    }
    try handle(allocator, &queue, &prng, "{\"type\":\"get_random\",\"min\":-2147483648,\"max\":2147483647}");
    try handle(allocator, &queue, &prng, "{\"type\":\"get_random\",\"min\":42,\"max\":42}");
    try std.testing.expectEqualStrings("{\"value\":42}", queue.messages.items[1].data);
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var queue = common.MessageQueue.init(allocator);
    defer queue.deinit();
    var prng = std.Random.DefaultPrng.init(0);
    try handle(allocator, &queue, &prng, "{\"type\":\"echo\",\"message\":\"quote\\\"text\"}");
}

test "native handler releases allocations on every failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
