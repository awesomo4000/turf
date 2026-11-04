// SPDX-License-Identifier: MPL-2.0
//! Standalone Turf automation client. No GUI dependencies. One connection per request.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
pub const Value = std.json.Value;
pub const max_request_bytes = 1024 * 1024;
pub const max_response_bytes = 32 * 1024 * 1024;

/// Owns all parsed response data. Values borrowed from this object expire on deinit.
/// RPC failures are replies, not Zig errors, so callers retain code/message/data.
pub const Reply = struct {
    parsed: std.json.Parsed(Value),
    pub fn deinit(self: *Reply) void {
        self.parsed.deinit();
        self.* = undefined;
    }
    pub fn result(self: Reply) ?Value {
        return self.parsed.value.object.get("result");
    }
    pub fn rpcError(self: Reply) ?Value {
        return self.parsed.value.object.get("error");
    }
};

/// Borrows endpoint and allocator/io. Calls are synchronous with a total deadline.
/// No automatic retries of sent requests. A timeout does not cancel remote JS.
/// Concurrent calls require an allocator and Io implementation that support them.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    endpoint: []const u8,
    timeout_ms: u32 = 35_000,

    pub fn request(self: Client, method: []const u8, params: anytype) !Reply {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, params, .{});
        defer self.allocator.free(encoded);
        return self.requestJson(method, encoded);
    }

    pub fn requestJson(self: Client, method: []const u8, params_json: []const u8) !Reply {
        if (params_json.len > max_request_bytes) return error.RequestTooLarge;
        const params = try std.json.parseFromSlice(Value, self.allocator, params_json, .{});
        defer params.deinit();
        if (params.value != .object) return error.ParamsMustBeObject;
        const json = try std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = @as(u32, 1), .method = method, .params = params.value }, .{});
        defer self.allocator.free(json);
        if (json.len > max_request_bytes) return error.RequestTooLarge;
        const wire = try std.fmt.allocPrint(self.allocator, "{s}\n", .{json});
        defer self.allocator.free(wire);
        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(self.allocator);
        const Outcome = union(enum) { exchange: anyerror!void, timer: Io.Cancelable!void };
        var buffer: [2]Outcome = undefined;
        var select = Io.Select(Outcome).init(self.io, &buffer);
        defer select.cancelDiscard();
        // Workers return no owned resources; cancellation joins before response is freed.
        try select.concurrent(.exchange, exchange, .{ self, wire, &response });
        try select.concurrent(.timer, timer, .{ self.io, self.timeout_ms });
        switch (try select.await()) {
            .exchange => |result| try result,
            .timer => |result| {
                try result;
                return error.Timeout;
            },
        }
        select.cancelDiscard();
        return parseReply(self.allocator, response.items);
    }

    pub fn evaluate(self: Client, expression: []const u8) !Reply {
        return self.request("evaluate", .{ .expression = expression });
    }

    /// Save a PNG atomically. On RPC failure, the destination is untouched.
    /// Success returns screenshot metadata and path, omitting the base64 data.
    pub fn screenshot(self: Client, params_json: []const u8, output: []const u8) !Reply {
        var reply = try self.requestJson("screenshot", params_json);
        if (reply.rpcError() != null) return reply;
        defer reply.deinit();
        var result = reply.result().?;
        const data = text(field(result, "data")) orelse return error.InvalidScreenshot;
        if (!std.mem.eql(u8, text(field(result, "format")) orelse "", "png")) return error.InvalidScreenshot;
        const png = try decode(self.allocator, data);
        defer self.allocator.free(png);
        if (png.len < 24 or !std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n")) return error.InvalidScreenshot;
        var file = try Io.Dir.cwd().createFileAtomic(self.io, output, .{ .replace = true });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, png);
        _ = result.object.swapRemove("data");
        try result.object.put(reply.parsed.arena.allocator(), "path", .{ .string = output });
        const metadata = try resultReply(self.allocator, result);
        errdefer {
            var owned = metadata;
            owned.deinit();
        }
        try file.replace(self.io);
        return metadata;
    }

    /// Stream a page-held Blob/URL/expression to an atomic output file.
    /// Each chunk gets its own bounded request; no total blob-size limit is imposed.
    pub fn grab(self: Client, source: []const u8, output: []const u8, chunk_bytes: usize) !Reply {
        if (source.len == 0) return error.EmptyGrabSource;
        if (chunk_bytes == 0 or chunk_bytes > 512 * 1024) return error.InvalidChunkSize;
        var random: [16]u8 = undefined;
        self.io.random(&random);
        const token = try std.fmt.allocPrint(self.allocator, "__turfGrab_{s}", .{std.fmt.hex(std.mem.readInt(u128, &random, .big))});
        defer self.allocator.free(token);
        const source_json = try std.json.Stringify.valueAlloc(self.allocator, source, .{});
        defer self.allocator.free(source_json);
        const prepare = try std.fmt.allocPrint(self.allocator, "{s}(\"{s}\",{s})", .{ @embedFile("grab.js"), token, source_json });
        defer self.allocator.free(prepare);
        defer self.cleanupGrab(token);
        var prepared = try self.evaluate(prepare);
        if (prepared.rpcError() != null) return prepared;
        defer prepared.deinit();
        const metadata = field(prepared.result().?, "value");
        const size = unsigned(field(metadata, "bytes")) orelse return error.InvalidGrabMetadata;
        const mime = text(field(metadata, "mime")) orelse return error.InvalidGrabMetadata;
        var file = try Io.Dir.cwd().createFileAtomic(self.io, output, .{ .replace = true });
        defer file.deinit(self.io);
        var offset: u64 = 0;
        while (offset < size) {
            const count = @min(chunk_bytes, size - offset);
            const script = try std.fmt.allocPrint(self.allocator, "(async()=>{{const state=window[\"{s}\"];if(!state?.blob) throw Error('grab state lost, possibly due to navigation');state.refresh();return await new Promise((resolve,reject)=>{{const reader=new FileReader();reader.onload=()=>resolve(reader.result.split(',')[1]);reader.onerror=()=>reject(reader.error);reader.readAsDataURL(state.blob.slice({d},{d}));}});}})()", .{ token, offset, offset + count });
            defer self.allocator.free(script);
            var chunk_reply = try self.evaluate(script);
            if (chunk_reply.rpcError() != null) return chunk_reply;
            defer chunk_reply.deinit();
            const data = text(field(chunk_reply.result().?, "value")) orelse return error.InvalidGrabChunk;
            const chunk = try decode(self.allocator, data);
            defer self.allocator.free(chunk);
            if (chunk.len != count) return error.InvalidGrabChunk;
            try file.file.writeStreamingAll(self.io, chunk);
            offset += count;
        }
        const reply = try resultReply(self.allocator, .{ .bytes = size, .mime = mime, .path = output });
        errdefer {
            var owned = reply;
            owned.deinit();
        }
        try file.replace(self.io);
        return reply;
    }

    fn cleanupGrab(self: Client, token: []const u8) void {
        const script = std.fmt.allocPrint(self.allocator, "(()=>{{clearTimeout(window[\"{s}\"]?.timer);delete window[\"{s}\"];return true;}})()", .{ token, token }) catch return;
        defer self.allocator.free(script);
        var cleanup = self;
        cleanup.timeout_ms = @min(self.timeout_ms, 2000);
        var reply = cleanup.evaluate(script) catch return;
        reply.deinit();
    }
};

pub fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
pub fn text(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
fn unsigned(value: Value) ?u64 {
    return if (value == .integer and value.integer >= 0) @intCast(value.integer) else null;
}
fn decode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(data));
    errdefer allocator.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, data);
    return bytes;
}
fn resultReply(allocator: std.mem.Allocator, result: anytype) !Reply {
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = @as(u32, 1), .result = result }, .{});
    defer allocator.free(json);
    return parseReply(allocator, json);
}
fn parseReply(allocator: std.mem.Allocator, json: []const u8) !Reply {
    const parsed = try std.json.parseFromSlice(Value, allocator, json, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const value = parsed.value;
    if (value != .object or !std.mem.eql(u8, text(field(value, "jsonrpc")) orelse "", "2.0") or unsigned(field(value, "id")) != 1) return error.InvalidResponse;
    const has_result = value.object.contains("result");
    const failure = value.object.get("error");
    if (has_result == (failure != null)) return error.InvalidResponse;
    if (failure) |detail| {
        if (detail != .object or field(detail, "code") != .integer or text(field(detail, "message")) == null) return error.InvalidResponse;
    }
    return .{ .parsed = parsed };
}
fn timer(io: Io, milliseconds: u32) Io.Cancelable!void {
    return io.sleep(.fromMilliseconds(milliseconds), .awake);
}
fn exchange(self: Client, wire: []const u8, response: *std.ArrayList(u8)) !void {
    if (self.endpoint.len == 0 or std.mem.indexOfScalar(u8, self.endpoint, 0) != null) return error.InvalidEndpoint;
    const connection = if (builtin.os.tag == .windows) blk: {
        if (!std.mem.startsWith(u8, self.endpoint, "\\\\.\\pipe\\")) return error.ExpectedLocalNamedPipe;
        while (true) {
            const file = Io.Dir.cwd().openFile(self.io, self.endpoint, .{ .mode = .read_write }) catch |err| switch (err) {
                error.PipeBusy => {
                    try self.io.sleep(.fromMilliseconds(20), .awake);
                    continue;
                },
                else => return err,
            };
            break :blk file;
        }
    } else blk: {
        const address = try Io.net.UnixAddress.init(self.endpoint);
        break :blk try address.connect(self.io);
    };
    defer connection.close(self.io);
    if (builtin.os.tag == .windows) try connection.writeStreamingAll(self.io, wire) else {
        var writer = connection.writer(self.io, &.{});
        try writer.interface.writeAll(wire);
    }
    var buffer: [65536]u8 = undefined;
    var slices = [_][]u8{&buffer};
    while (true) {
        const count = if (builtin.os.tag == .windows) try connection.readStreaming(self.io, &slices) else (try connection.readWithControl(self.io, &slices, &.{})).data_len;
        if (count == 0) return error.IncompleteResponse;
        const end = std.mem.indexOfScalar(u8, buffer[0..count], '\n');
        const part = buffer[0 .. end orelse count];
        if (part.len > max_response_bytes - response.items.len) return error.ResponseTooLarge;
        try response.appendSlice(self.allocator, part);
        if (end != null) return;
    }
}

test "strict response envelopes preserve null results and structured errors" {
    const a = std.testing.allocator;
    var good = try parseReply(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}");
    defer good.deinit();
    try std.testing.expect(good.result().? == .null);
    var failure = try parseReply(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32002,\"message\":\"boom\",\"data\":{\"stack\":\"here\"}}}");
    defer failure.deinit();
    try std.testing.expectEqualStrings("here", text(field(field(failure.rpcError().?, "data"), "stack")).?);
    for ([_][]const u8{ "[]", "{}", "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":1}", "{\"jsonrpc\":\"2.0\",\"id\":1}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"error\":{}}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":true,\"message\":\"bad\"}}" }) |bad| try std.testing.expectError(error.InvalidResponse, parseReply(a, bad));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var reply = try parseReply(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"nested\":[1,2,\"text\"]}}");
    defer reply.deinit();
}
test "response parsing frees partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "invalid params fail before transport" {
    const client: Client = .{ .allocator = std.testing.allocator, .io = std.testing.io, .endpoint = "unused" };
    try std.testing.expectError(error.ParamsMustBeObject, client.requestJson("info", "[]"));
    try std.testing.expectError(error.ParamsMustBeObject, client.requestJson("info", "null"));
}
