// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

const std = @import("std");
const diagnostics = @import("bridge_diagnostics");

const marker = "FARMHAND_SECRET_INPUT_7f4c";

fn expectPayloadAbsent(output: []const u8, payload: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, output, marker) == null);
    try std.testing.expect(std.mem.indexOf(u8, output, payload) == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"body\"") == null);
}

test "message type validation rejects arbitrary text" {
    try std.testing.expectEqual(@as(?diagnostics.MessageType, .echo), diagnostics.classifyMessageType("echo"));
    try std.testing.expect(diagnostics.classifyMessageType(marker) == null);
}

test "inbound diagnostic contains structure without payload" {
    const payload = "{\"type\":\"echo\",\"body\":\"FARMHAND_SECRET_INPUT_7f4c\"}";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try diagnostics.write(&output.writer, .{ .message = .{
        .direction = .inbound,
        .message_type = .echo,
        .byte_count = payload.len,
    } });

    try std.testing.expectEqualStrings("Received JavaScript message: type=echo, bytes=51\n", output.written());
    try expectPayloadAbsent(output.written(), payload);
}

test "outbound diagnostic contains structure without payload" {
    const payload = "{\"body\":\"FARMHAND_SECRET_INPUT_7f4c\"}";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try diagnostics.write(&output.writer, .{ .message = .{
        .direction = .outbound,
        .message_type = .echo_response,
        .byte_count = payload.len,
    } });

    try std.testing.expectEqualStrings("Sending native message: type=echo_response, bytes=37\n", output.written());
    try expectPayloadAbsent(output.written(), payload);
}

test "not-ready diagnostic contains structure without payload" {
    const payload = "{\"body\":\"FARMHAND_SECRET_INPUT_7f4c\"}";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try diagnostics.write(&output.writer, .{ .not_ready = .{
        .direction = .outbound,
        .message_type = null,
        .byte_count = payload.len,
    } });

    try std.testing.expectEqualStrings("Page not ready; skipped native message: bytes=37\n", output.written());
    try expectPayloadAbsent(output.written(), payload);
}

test "malformed diagnostic reports error class without source" {
    const malformed = "{\"body\":\"FARMHAND_SECRET_INPUT_7f4c\"";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try diagnostics.write(&output.writer, .{ .parse_failure = .{
        .direction = .inbound,
        .byte_count = malformed.len,
        .error_class = .{ .parser = error.InvalidCharacter },
    } });

    try std.testing.expectEqualStrings("Failed to parse JavaScript message: error=InvalidCharacter, bytes=36\n", output.written());
    try expectPayloadAbsent(output.written(), malformed);
}
