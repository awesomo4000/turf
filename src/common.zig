// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

const std = @import("std");

// Common geometry structure
pub const Geometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// Controls the bottom-right logo on each page load.
pub const StartupLogo = enum {
    off,
    in_out,
    stay,
};

// Common window configuration
pub const WindowConfig = struct {
    geometry: Geometry,
    title: [:0]const u8,
    startup_logo: StartupLogo = .off,
    /// Show without activating the application.
    no_focus: bool = false,
    /// Run without showing until show() or the automation show method.
    start_hidden: bool = false,
};

// Message structure for queuing
pub const Message = struct {
    type: []const u8,
    data: [:0]const u8,  // Null-terminated JSON for C API

    pub fn format(self: Message, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{{\"type\":{f},\"data\":{s}}}", .{ std.json.fmt(self.type, .{}), self.data });
    }
};

// Thread-safe message queue for outgoing messages (native -> JS)
pub const MessageQueue = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    mutex: std.Io.Mutex,
    limits: Limits = .{},
    pending_bytes: usize = 0,

    pub const Limits = struct {
        max_messages: usize = 1024,
        /// Includes copied names and payload sentinel bytes, excluding list capacity.
        max_bytes: usize = 8 * 1024 * 1024,
    };

    /// Allocator must support concurrent allocation/free when producers and the
    /// window pump run on different threads. Stop/join users before deinit.
    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) MessageQueue {
        var result = init(allocator);
        result.limits = limits;
        return result;
    }
    
    pub fn init(allocator: std.mem.Allocator) MessageQueue {
        return .{
            .allocator = allocator,
            .messages = .empty,
            .mutex = .init,
        };
    }
    
    pub fn deinit(self: *MessageQueue) void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        
        for (self.messages.items) |msg| {
            self.allocator.free(msg.type);
            self.allocator.free(msg.data);
        }
        self.messages.deinit(self.allocator);
    }
    
    /// Takes ownership of data on success only. Allocate data with this queue's allocator.
    pub fn push(self: *MessageQueue, msg_type: []const u8, data: [:0]const u8) !void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        
        try self.checkCapacity(msg_type.len, data.len);
        try self.pushLocked(msg_type, data);
    }

    fn pushLocked(self: *MessageQueue, msg_type: []const u8, data: [:0]const u8) !void {
        const owned_type = try self.allocator.dupe(u8, msg_type);
        errdefer self.allocator.free(owned_type);
        try self.messages.append(self.allocator, .{
            .type = owned_type,
            .data = data,
        });
        self.pending_bytes += msg_type.len + data.len + 1;
    }
    
    // Alternative method that copies the data
    pub fn pushCopy(self: *MessageQueue, msg_type: []const u8, data: []const u8) !void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        try self.checkCapacity(msg_type.len, data.len);
        const owned_data = try self.allocator.dupeSentinel(u8, data, 0);
        errdefer self.allocator.free(owned_data);
        try self.pushLocked(msg_type, owned_data);
    }

    fn checkCapacity(self: *MessageQueue, name_len: usize, data_len: usize) !void {
        const size = std.math.add(usize, name_len, data_len) catch return error.QueueFull;
        const terminated_size = std.math.add(usize, size, 1) catch return error.QueueFull;
        if (self.messages.items.len >= self.limits.max_messages or
            terminated_size > self.limits.max_bytes -| self.pending_bytes) return error.QueueFull;
    }

    /// Discard messages belonging to a document that is being replaced.
    pub fn clear(self: *MessageQueue) void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        for (self.messages.items) |msg| {
            self.allocator.free(msg.type);
            self.allocator.free(msg.data);
        }
        self.messages.clearRetainingCapacity();
        self.pending_bytes = 0;
    }

    /// Caller owns the returned list and each message, using this queue's allocator.
    pub fn popAll(self: *MessageQueue) !std.ArrayList(Message) {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        
        var result: std.ArrayList(Message) = .empty;
        try result.appendSlice(self.allocator, self.messages.items);
        self.messages.clearRetainingCapacity();
        self.pending_bytes = 0;
        return result;
    }
};

/// Releases a batch returned by popAll, using the queue allocator.
pub fn freeMessages(allocator: std.mem.Allocator, batch: *std.ArrayList(Message)) void {
    for (batch.items) |msg| {
        allocator.free(msg.type);
        allocator.free(msg.data);
    }
    batch.deinit(allocator);
}

test "queue copies buffers, preserves FIFO, and supports empty messages" {
    const allocator = std.testing.allocator;
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();
    var kind = [_]u8{ 'a', 'b' };
    var data = [_]u8{ '1', '2' };
    try queue.pushCopy(&kind, &data);
    @memset(&kind, 'x');
    @memset(&data, 'x');
    try queue.pushCopy("", "");
    var batch = try queue.popAll();
    defer freeMessages(allocator, &batch);
    try std.testing.expectEqual(2, batch.items.len);
    try std.testing.expectEqualStrings("ab", batch.items[0].type);
    try std.testing.expectEqualStrings("12", batch.items[0].data);
    try std.testing.expectEqual(0, batch.items[0].data[batch.items[0].data.len]);
    try std.testing.expectEqualStrings("", batch.items[1].type);
    try std.testing.expectEqualStrings("", batch.items[1].data);
    var empty = try queue.popAll();
    defer freeMessages(allocator, &empty);
    try std.testing.expectEqual(0, empty.items.len);
    try queue.pushCopy("again", "null");
}

test "dequeued messages outlive the queue" {
    const allocator = std.testing.allocator;
    var queue = MessageQueue.init(allocator);
    try queue.pushCopy("event", "true");
    var batch = queue.popAll() catch |err| {
        queue.deinit();
        return err;
    };
    queue.deinit();
    defer freeMessages(allocator, &batch);
    try std.testing.expectEqualStrings("event", batch.items[0].type);
    try std.testing.expectEqualStrings("true", batch.items[0].data);
}

fn exerciseCopyFailures(allocator: std.mem.Allocator) !void {
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();
    for (0..20) |_| try queue.pushCopy("event", "{\"value\":42}");
    var batch = try queue.popAll();
    defer freeMessages(allocator, &batch);
    try std.testing.expectEqual(20, batch.items.len);
}

test "copy queue is leak-free at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseCopyFailures, .{});
}

fn exerciseTransferFailures(allocator: std.mem.Allocator) !void {
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();
    const data = try allocator.dupeSentinel(u8, "null", 0);
    queue.push("event", data) catch |err| {
        allocator.free(data);
        return err;
    };
    var batch = try queue.popAll();
    defer freeMessages(allocator, &batch);
    try std.testing.expect(batch.items[0].data.ptr == data.ptr);
}

test "push transfers ownership only on success" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseTransferFailures, .{});
}

test "failed pop preserves queued messages for retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();
    try queue.pushCopy("retry", "42");
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, queue.popAll());
    failing.fail_index = std.math.maxInt(usize);
    var batch = try queue.popAll();
    defer freeMessages(allocator, &batch);
    try std.testing.expectEqual(1, batch.items.len);
    try std.testing.expectEqualStrings("42", batch.items[0].data);
}

test "message envelope escapes names and retains structured JSON" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "quote'\"\\\n\r\t", "nul\x00byte", "otter 🦦", "');throw new Error('injected');//" }) |kind| {
        const message: Message = .{ .type = kind, .data = "{\"items\":[null,true,42,\"quoted\\\"text\"]}" };
        const encoded = try std.fmt.allocPrint(allocator, "{f}", .{message});
        defer allocator.free(encoded);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(kind, parsed.value.object.get("type").?.string);
        const items = parsed.value.object.get("data").?.object.get("items").?.array.items;
        try std.testing.expectEqual(.null, std.meta.activeTag(items[0]));
        try std.testing.expect(items[1].bool);
        try std.testing.expectEqual(42, items[2].integer);
        try std.testing.expectEqualStrings("quoted\"text", items[3].string);
    }
}

fn fuzzMessageRoundTrip(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var name_buffer: [256]u8 = undefined;
    var data_buffer: [1024]u8 = undefined;
    const name = name_buffer[0..smith.slice(&name_buffer)];
    const data = data_buffer[0..smith.slice(&data_buffer)];
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();
    // The low-level queue must preserve bytes, including embedded nulls.
    try queue.pushCopy(name, data);
    var batch = try queue.popAll();
    defer freeMessages(allocator, &batch);
    try std.testing.expectEqual(1, batch.items.len);
    try std.testing.expectEqualSlices(u8, name, batch.items[0].type);
    try std.testing.expectEqualSlices(u8, data, batch.items[0].data);
    try std.testing.expectEqual(0, batch.items[0].data[data.len]);

    // JSON text accepts UTF-8; arbitrary bytes above still exercise the queue.
    if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(data)) return;
    const json_data = try std.fmt.allocPrintSentinel(allocator, "{f}", .{std.json.fmt(data, .{})}, 0);
    defer allocator.free(json_data);
    const encoded = try std.fmt.allocPrint(allocator, "{f}", .{Message{ .type = name, .data = json_data }});
    defer allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(name, parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings(data, parsed.value.object.get("data").?.string);
}

test "fuzz queue and message JSON round trips" {
    try std.testing.fuzz({}, fuzzMessageRoundTrip, .{
        .corpus = &.{ "", "quotes'\"\\\n\x00", "🦦", "{}[]nulltrue", "\xff\xfe\x00" },
    });
}


test "queue bounds reject before allocation and recover after drain or clear" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var queue = MessageQueue.initWithLimits(allocator, .{ .max_messages = 2, .max_bytes = 6 });
    defer queue.deinit();
    try queue.pushCopy("a", "1");
    try queue.pushCopy("b", "2");
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.QueueFull, queue.pushCopy("", ""));
    failing.fail_index = std.math.maxInt(usize);
    var batch = try queue.popAll();
    defer freeMessages(allocator, &batch);
    try std.testing.expectEqual(0, queue.pending_bytes);
    try std.testing.expectError(error.QueueFull, queue.pushCopy("large", "payload"));
    const transferred = try allocator.dupeSentinel(u8, "123456", 0);
    defer allocator.free(transferred);
    try std.testing.expectError(error.QueueFull, queue.push("", transferred));
    try queue.pushCopy("", "12345");
    queue.clear();
    try std.testing.expectEqual(0, queue.messages.items.len);
    try std.testing.expectEqual(0, queue.pending_bytes);
    try queue.pushCopy("c", "3");
}

fn queueProducer(queue: *MessageQueue, producer: usize, failed: *std.atomic.Value(bool)) void {
    for (0..200) |index| {
        var buffer: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(&buffer, "{d}:{d}", .{producer, index}) catch unreachable;
        queue.pushCopy("producer", payload) catch {
            failed.store(true, .release);
            return;
        };
    }
}

test "concurrent producers preserve every message and producer ordering" {
    var queue = MessageQueue.init(std.testing.allocator);
    defer queue.deinit();
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    // Join even if thread creation fails.
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, queueProducer, .{ &queue, index, &failed });
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    try std.testing.expect(!failed.load(.acquire));
    var batch = try queue.popAll();
    defer freeMessages(queue.allocator, &batch);
    try std.testing.expectEqual(800, batch.items.len);
    var next: [4]usize = @splat(0);
    for (batch.items) |msg| {
        var parts = std.mem.splitScalar(u8, msg.data, ':');
        const producer = try std.fmt.parseInt(usize, parts.next().?, 10);
        const index = try std.fmt.parseInt(usize, parts.next().?, 10);
        try std.testing.expectEqual(next[producer], index);
        next[producer] += 1;
    }
    for (next) |count| try std.testing.expectEqual(200, count);
}
