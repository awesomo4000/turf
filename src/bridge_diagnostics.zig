// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

const std = @import("std");

pub const Direction = enum {
    inbound,
    outbound,
};

pub const MessageType = enum {
    counter_update,
    counter_echo,
    counter_reset,
    custom_message,
    show_file_dialog,
    show_save_dialog,
    turf_ready,
    ping,
    pong,
    @"test",
    echo,
    echo_response,
    get_time,
    time_response,
    get_random,
    random_response,
    custom,
    custom_response,
    native_file_selected,
    native_file_destination,
};

pub const ErrorClass = union(enum) {
    parser: anyerror,
    invalid_root,
    missing_type,
    invalid_type,

    fn writeName(self: ErrorClass, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .parser => |err| try writer.writeAll(@errorName(err)),
            .invalid_root => try writer.writeAll("InvalidRoot"),
            .missing_type => try writer.writeAll("MissingType"),
            .invalid_type => try writer.writeAll("InvalidType"),
        }
    }
};

pub const Message = struct {
    direction: Direction,
    message_type: ?MessageType,
    byte_count: usize,
};

pub const ParseFailure = struct {
    direction: Direction,
    byte_count: usize,
    error_class: ErrorClass,
};

pub const Event = union(enum) {
    message: Message,
    not_ready: Message,
    parse_failure: ParseFailure,

    pub fn format(self: Event, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .message => |message| {
                try writer.writeAll(switch (message.direction) {
                    .inbound => "Received JavaScript message",
                    .outbound => "Sending native message",
                });
                try writeMessageStructure(writer, message);
            },
            .not_ready => |message| {
                try writer.writeAll(switch (message.direction) {
                    .inbound => "Inbound bridge not ready; skipped JavaScript message",
                    .outbound => "Page not ready; skipped native message",
                });
                try writeMessageStructure(writer, message);
            },
            .parse_failure => |failure| {
                try writer.writeAll(switch (failure.direction) {
                    .inbound => "Failed to parse JavaScript message: error=",
                    .outbound => "Failed to parse native message: error=",
                });
                try failure.error_class.writeName(writer);
                try writer.print(", bytes={d}\n", .{failure.byte_count});
            },
        }
    }
};

pub fn classifyMessageType(message_type: []const u8) ?MessageType {
    return std.meta.stringToEnum(MessageType, message_type);
}

pub fn write(writer: *std.Io.Writer, event: Event) std.Io.Writer.Error!void {
    return event.format(writer);
}

pub fn writeIfEnabled(writer: *std.Io.Writer, enabled: bool, event: Event) std.Io.Writer.Error!void {
    if (!enabled) return;
    return write(writer, event);
}

pub fn log(enabled: bool, event: Event) void {
    if (!enabled) return;
    std.debug.print("{f}", .{event});
}

fn writeMessageStructure(writer: *std.Io.Writer, message: Message) std.Io.Writer.Error!void {
    if (message.message_type) |message_type| {
        try writer.print(": type={s}, bytes={d}\n", .{ @tagName(message_type), message.byte_count });
    } else {
        try writer.print(": bytes={d}\n", .{message.byte_count});
    }
}
