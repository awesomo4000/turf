// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const turfctl = @import("turfctl");
pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const endpoint = args.next() orelse {
        try std.Io.File.stderr().writeStreamingAll(init.io, "Missing endpoint. Usage: turfctl-library-test ENDPOINT\nPass a Turf Unix socket path or Windows named pipe.\n");
        return 1;
    };
    const client: turfctl.Client = .{ .allocator = init.gpa, .io = init.io, .endpoint = endpoint };
    var reply = try client.evaluate("Promise.resolve({fromLibrary:42})");
    defer reply.deinit();
    if (reply.rpcError() != null) return error.RemoteFailure;
    const value = turfctl.field(turfctl.field(reply.result().?, "value"), "fromLibrary");
    if (value != .integer or value.integer != 42) return error.WrongResult;
    if (args.next()) |mode| {
        if (!std.mem.eql(u8, mode, "emit")) return error.UnknownMode;
        var emitted = try client.emit("library", .{ .fromLibrary = 42 }, true);
        defer emitted.deinit();
        if (emitted.rpcError() != null) return error.RemoteFailure;
        var cleared = try client.clearTopic("library");
        defer cleared.deinit();
        if (cleared.rpcError() != null) return error.RemoteFailure;
        var received = try client.receive("library", 0, null);
        defer received.deinit();
        if (received.rpcError() != null) return error.RemoteFailure;
        if (turfctl.field(received.result().?, "messages") != .array) return error.WrongResult;
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "PASS: imported turfctl as a Zig library\n");
    return 0;
}
