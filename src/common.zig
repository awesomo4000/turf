const std = @import("std");

// Common geometry structure
pub const Geometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

// Common window configuration
pub const WindowConfig = struct {
    geometry: Geometry,
    title: [:0]const u8,
};

// Message structure for queuing
pub const Message = struct {
    type: []const u8,
    data: [:0]const u8,  // Null-terminated for C API
};

// Thread-safe message queue for outgoing messages (native -> JS)
pub const MessageQueue = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    mutex: std.Thread.Mutex,
    
    pub fn init(allocator: std.mem.Allocator) MessageQueue {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList(Message).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn deinit(self: *MessageQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.messages.items) |msg| {
            self.allocator.free(msg.type);
            self.allocator.free(msg.data);
        }
        self.messages.deinit();
    }
    
    pub fn push(self: *MessageQueue, msg_type: []const u8, data: [:0]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.messages.append(.{
            .type = try self.allocator.dupe(u8, msg_type),
            .data = data, // Caller must ensure data remains valid and pass ownership
        });
    }
    
    // Alternative method that copies the data
    pub fn pushCopy(self: *MessageQueue, msg_type: []const u8, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.messages.append(.{
            .type = try self.allocator.dupe(u8, msg_type),
            .data = try self.allocator.dupeZ(u8, data),
        });
    }
    
    pub fn popAll(self: *MessageQueue) !std.ArrayList(Message) {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var result = std.ArrayList(Message).init(self.allocator);
        try result.appendSlice(self.messages.items);
        self.messages.clearRetainingCapacity();
        return result;
    }
};