// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const turfctl = @import("turfctl");
pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const endpoint = args.next() orelse return error.MissingEndpoint;
    const client: turfctl.Client = .{ .allocator = init.gpa, .io = init.io, .endpoint = endpoint };
    var reply = try client.evaluate("Promise.resolve({fromLibrary:42})");
    defer reply.deinit();
    if (reply.rpcError() != null) return error.RemoteFailure;
    const value = turfctl.field(turfctl.field(reply.result().?, "value"), "fromLibrary");
    if (value != .integer or value.integer != 42) return error.WrongResult;
    try std.Io.File.stdout().writeStreamingAll(init.io, "PASS: imported turfctl as a Zig library\n");
}
