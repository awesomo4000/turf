// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const api = @import("turfctl");
const Io = std.Io;
const help =
    \\Usage: turfctl ENDPOINT METHOD [JSON] [OPTIONS]
    \\Send automation commands to an explicit Turf Unix socket or Windows named pipe.
    \\JSON defaults to {}. Success prints result JSON to stdout. RPC errors print the
    \\original error object to stderr and exit 1; local errors use kind=client_error.
    \\
    \\Methods and parameters:
    \\  info, screens, show, close      No parameters
    \\  evaluate                       {"expression":"JavaScript"}; awaits promises
    \\  emit                           {"topic":"name","data":JSON,"retain":false}
    \\  navigate                       {"url":"absolute URL"}
    \\  screenshot                     Optional rect or selector, plus padding
    \\  resize                         {"width":800,"height":600}
    \\  move                           {"screen":"ID","anchor":"top-left","x":0,"y":0}
    \\  diagnostics                    {"action":"start|read|stop",...}
    \\  click                          {"x":100,"y":120}
    \\  key                            {"key":"Enter","modifiers":[],"repeat":false}
    \\  typeText                       {"text":"Unicode text"}
    \\  grab                           {"source":"URL or JS expression","chunkBytes":262144}
    \\
    \\Emit shorthand: turfctl ENDPOINT emit TOPIC JSON [--retain]
    \\  JSON may be - for stdin, or use TOPIC --data-file PATH.
    \\  Clear retention with emit '{"topic":"name","clear":true}'.
    \\  macOS first; main frame only. Page API: turf.on(topic, (data, meta) => ...).
    \\  Replies count synchronous handler calls/failures, not rendering or async completion.
    \\  Retention: 128 topics / 4 MiB; exact-URL reload replay; no disk persistence.
    \\Options:
    \\  -h, --help                     Show this help
    \\  -o, --output PATH              Save screenshot PNG or grabbed bytes atomically
    \\  --params-file PATH             Read the JSON object from a file; - means stdin
    \\  --expression-file PATH         Evaluate JS from a file; - means stdin
    \\  --timeout-ms N                 Total deadline per request, default 35000
    \\
    \\Examples:
    \\  turfctl /tmp/turf/control.sock info
    \\  turfctl /tmp/turf/control.sock evaluate --expression-file scene.js
    \\  turfctl /tmp/turf/control.sock screenshot '{"selector":"#panel","padding":8}' -o panel.png
    \\  turfctl /tmp/turf/control.sock grab '{"source":"new Blob([\"hello\"])"}' -o hello.txt
    \\  turfctl \\.\pipe\turf-dev info
    \\
    \\Screenshot rect={x,y,width,height} and returned region use info.viewport units;
    \\image width/height use pixels. rect and selector are mutually exclusive.
    \\Selectors use the main frame. Padding must be nonnegative and needs a region.
    \\grab requires --output and streams 1..524288-byte chunks, including files >32 MiB.
    \\Diagnostics are opt-in: start before navigation. Read with session and
    \\after=nextCursor; inspect droppedSinceCursor. Reading does not clear entries.
    \\Requests allow 1 MiB of JSON; responses allow 32 MiB. A timeout does not cancel
    \\remote JavaScript. No automatic retries of sent commands are performed.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    return run(init) catch |err| {
        const message = switch (err) {
            error.MissingEndpoint => "Missing endpoint. Specify a Turf Unix socket path or Windows named pipe. Usage: turfctl ENDPOINT METHOD [JSON] [OPTIONS]. Run turfctl --help for examples.",
            error.MissingMethod => "Missing method after the endpoint. Usage: turfctl ENDPOINT METHOD [JSON] [OPTIONS]. Run turfctl --help for available commands.",
            error.TooManyArguments => "Too many positional arguments. Pass parameters as one quoted JSON object, or use --params-file PATH. Run turfctl --help for examples.",
            else => @errorName(err),
        };
        try printJson(init.io, init.gpa, Io.File.stderr(), .{ .kind = "client_error", .message = message });
        return 1;
    };
}
fn printJson(io: Io, allocator: std.mem.Allocator, output: Io.File, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    try output.writeStreamingAll(io, json);
    try output.writeStreamingAll(io, "\n");
}
fn readInput(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var buffer: [4096]u8 = undefined;
        var reader = Io.File.stdin().readerStreaming(io, &buffer);
        return reader.interface.allocRemaining(allocator, .limited(api.max_request_bytes));
    }
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(api.max_request_bytes));
}
fn run(init: std.process.Init) !u8 {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    defer args.deinit();
    _ = args.next();
    var positionals: std.ArrayList([]const u8) = .empty;
    var output: ?[]const u8 = null;
    var params_file: ?[]const u8 = null;
    var expression_file: ?[]const u8 = null;
    var retain = false;
    var data_file: ?[]const u8 = null;
    var timeout: u32 = 35_000;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try Io.File.stdout().writeStreamingAll(init.io, help);
            return 0;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (output != null) return error.DuplicateOption;
            output = args.next() orelse return error.MissingOutputPath;
        } else if (std.mem.eql(u8, arg, "--params-file")) {
            if (params_file != null) return error.DuplicateOption;
            params_file = args.next() orelse return error.MissingParamsPath;
        } else if (std.mem.eql(u8, arg, "--expression-file")) {
            if (expression_file != null) return error.DuplicateOption;
            expression_file = args.next() orelse return error.MissingExpressionPath;
        } else if (std.mem.eql(u8, arg, "--retain")) {
            retain = true;
        } else if (std.mem.eql(u8, arg, "--data-file")) {
            if (data_file != null) return error.DuplicateOption;
            data_file = args.next() orelse return error.MissingDataPath;
        } else if (std.mem.eql(u8, arg, "-")) {
            try positionals.append(a, arg);
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            timeout = try std.fmt.parseInt(u32, args.next() orelse return error.MissingTimeout, 10);
            if (timeout == 0) return error.InvalidTimeout;
        } else if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption else try positionals.append(a, arg);
    }
    if (positionals.items.len == 0 or positionals.items[0].len == 0) return error.MissingEndpoint;
    if (positionals.items.len == 1 or positionals.items[1].len == 0) return error.MissingMethod;
    const method = positionals.items[1];
    const emit_short = std.mem.eql(u8, method, "emit") and (positionals.items.len == 4 or data_file != null);
    if (positionals.items.len > (if (emit_short) @as(usize, 4) else 3)) return error.TooManyArguments;
    if ((retain or data_file != null) and !std.mem.eql(u8, method, "emit")) return error.EmitOptionRequiresEmit;
    if (retain and !emit_short) return error.RetainRequiresTopicAndData;
    if (emit_short and (positionals.items.len < 3 or params_file != null or expression_file != null or
        (data_file != null and positionals.items.len != 3))) return error.ConflictingInputOptions;
    if ((params_file != null and expression_file != null) or ((params_file != null or expression_file != null) and positionals.items.len == 3)) return error.ConflictingInputOptions;
    const params_json = if (emit_short) blk: {
        const input = if (data_file) |path| try readInput(init.io, a, path)
            else if (std.mem.eql(u8, positionals.items[3], "-")) try readInput(init.io, a, "-")
            else positionals.items[3];
        const parsed = try std.json.parseFromSlice(api.Value, a, input, .{});
        break :blk try std.json.Stringify.valueAlloc(a, .{ .topic = positionals.items[2], .data = parsed.value, .retain = retain }, .{});
    } else if (params_file) |path| try readInput(init.io, a, path) else if (expression_file) |path| blk: {
        if (!std.mem.eql(u8, method, "evaluate")) return error.ExpressionFileRequiresEvaluate;
        break :blk try std.json.Stringify.valueAlloc(a, .{ .expression = try readInput(init.io, a, path) }, .{});
    } else if (positionals.items.len == 3) positionals.items[2] else "{}";
    const client: api.Client = .{ .allocator = init.gpa, .io = init.io, .endpoint = positionals.items[0], .timeout_ms = timeout };
    var reply = if (std.mem.eql(u8, method, "grab")) blk: {
        const path = output orelse return error.GrabRequiresOutput;
        const params = try std.json.parseFromSlice(api.Value, a, params_json, .{});
        if (params.value != .object) return error.ParamsMustBeObject;
        const source = api.text(api.field(params.value, "source")) orelse return error.GrabRequiresSource;
        const chunk = api.field(params.value, "chunkBytes");
        const size: usize = if (chunk == .null and !params.value.object.contains("chunkBytes")) 256 * 1024 else if (chunk == .integer and chunk.integer > 0 and chunk.integer <= 512 * 1024) @intCast(chunk.integer) else return error.InvalidChunkSize;
        break :blk try client.grab(source, path, size);
    } else if (output) |path| blk: {
        if (!std.mem.eql(u8, method, "screenshot")) return error.OutputRequiresScreenshotOrGrab;
        break :blk try client.screenshot(params_json, path);
    } else try client.requestJson(method, params_json);
    defer reply.deinit();
    if (reply.rpcError()) |failure| {
        try printJson(init.io, init.gpa, Io.File.stderr(), failure);
        return 1;
    }
    try printJson(init.io, init.gpa, Io.File.stdout(), reply.result().?);
    return 0;
}
