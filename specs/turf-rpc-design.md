<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2025-2026 awesomo4000 -->

# Turf RPC Design: Bidirectional JavaScript Calls

## Current State

Turf has one-way message passing:
- Native → JS: `evalJavaScript(code)`
- JS → Native: `window.webkit.messageHandlers.turf.postMessage(data)`

But there's no correlation between a request and its response.

## The Problem

```zig
// Current: Fire and forget
window.evalJavaScript("document.title");
// How do we get the result back?

// Desired: Call and response
const title = try window.callJavaScript("document.title");
```

## Solution: Call ID Based RPC

### 1. Call ID Assignment

```zig
const CallManager = struct {
    next_call_id: u32 = 1,
    pending_calls: std.AutoHashMap(u32, CallContext),
    
    const CallContext = struct {
        id: u32,
        code: []const u8,
        callback: ?fn(result: []const u8) void,
        promise: ?*Promise,
        timestamp: i64,
    };
    
    pub fn newCall(self: *CallManager) u32 {
        const id = self.next_call_id;
        self.next_call_id += 1;
        return id;
    }
};
```

### 2. Request Wrapping

When native code calls JS, wrap it with response handling:

```zig
pub fn callJavaScript(self: *Window, code: []const u8) ![]const u8 {
    const call_id = self.call_manager.newCall();
    
    // Wrap the JS code to capture result and send it back
    const wrapped = try std.fmt.allocPrint(allocator,
        \\(function() {{
        \\    const __call_id = {d};
        \\    try {{
        \\        const __result = eval({s});
        \\        
        \\        // Check if result is a Promise
        \\        if (__result && typeof __result.then === 'function') {{
        \\            // Handle promise
        \\            __result.then(function(value) {{
        \\                window.webkit.messageHandlers.turf.postMessage({{
        \\                    type: 'call_response',
        \\                    call_id: __call_id,
        \\                    success: true,
        \\                    result: value
        \\                }});
        \\            }}).catch(function(error) {{
        \\                window.webkit.messageHandlers.turf.postMessage({{
        \\                    type: 'call_response',
        \\                    call_id: __call_id,
        \\                    success: false,
        \\                    error: error.toString()
        \\                }});
        \\            }});
        \\            
        \\            // Return placeholder for async
        \\            window.webkit.messageHandlers.turf.postMessage({{
        \\                type: 'call_pending',
        \\                call_id: __call_id
        \\            }});
        \\        }} else {{
        \\            // Synchronous result
        \\            window.webkit.messageHandlers.turf.postMessage({{
        \\                type: 'call_response',
        \\                call_id: __call_id,
        \\                success: true,
        \\                result: __result
        \\            }});
        \\        }}
        \\    }} catch(e) {{
        \\        window.webkit.messageHandlers.turf.postMessage({{
        \\            type: 'call_response',
        \\            call_id: __call_id,
        \\            success: false,
        \\            error: e.toString()
        \\        }});
        \\    }}
        \\}})();
    , .{call_id, code});
    
    // Store pending call
    try self.call_manager.pending_calls.put(call_id, .{
        .id = call_id,
        .code = code,
        .callback = null,
        .promise = null,
        .timestamp = std.time.milliTimestamp(),
    });
    
    // Execute wrapped code
    self.evalJavaScript(wrapped);
    
    // Wait for response (blocking)
    return self.waitForResponse(call_id);
}
```

### 3. Response Handling

```zig
fn handleMessage(self: *Window, message: Message) void {
    switch (message.type) {
        .call_response => {
            const call_id = message.data.call_id;
            if (self.call_manager.pending_calls.get(call_id)) |call| {
                if (call.callback) |cb| {
                    // Async callback
                    cb(message.data.result);
                } else if (call.promise) |promise| {
                    // Resolve promise
                    promise.resolve(message.data.result);
                }
                
                // Clean up
                self.call_manager.pending_calls.remove(call_id);
            }
        },
        .call_pending => {
            // Mark call as async, continue waiting
            if (self.call_manager.pending_calls.getPtr(call_id)) |call| {
                call.is_async = true;
            }
        },
        else => {
            // Regular message handling
        }
    }
}
```

## Handling Promises

### JavaScript Side

```javascript
// Injected helper for promise handling
window.__turf_rpc = {
    // Store unresolved promises
    pending_promises: new Map(),
    
    // Execute code and handle promises
    execute: async function(call_id, code) {
        try {
            const result = eval(code);
            
            if (result && typeof result.then === 'function') {
                // Store promise reference
                this.pending_promises.set(call_id, result);
                
                // Notify native that this is async
                this.sendMessage({
                    type: 'call_pending',
                    call_id: call_id,
                    promise_id: call_id  // Use call_id as promise_id
                });
                
                // Wait for promise
                const value = await result;
                
                // Clean up
                this.pending_promises.delete(call_id);
                
                // Send resolved value
                this.sendMessage({
                    type: 'call_response',
                    call_id: call_id,
                    success: true,
                    result: this.serialize(value)
                });
            } else {
                // Synchronous result
                this.sendMessage({
                    type: 'call_response',
                    call_id: call_id,
                    success: true,
                    result: this.serialize(result)
                });
            }
        } catch(error) {
            this.sendMessage({
                type: 'call_response',
                call_id: call_id,
                success: false,
                error: error.toString()
            });
        }
    },
    
    // Serialize values for transmission
    serialize: function(value) {
        if (value === undefined) return { type: 'undefined' };
        if (value === null) return { type: 'null' };
        if (typeof value === 'function') return { type: 'function', string: value.toString() };
        if (typeof value === 'object') return { type: 'object', json: JSON.stringify(value) };
        return { type: typeof value, value: value };
    },
    
    sendMessage: function(data) {
        window.webkit.messageHandlers.turf.postMessage(data);
    }
};
```

### Native Side (Zig)

```zig
pub fn callJavaScriptAsync(self: *Window, code: []const u8) !Promise {
    const call_id = self.call_manager.newCall();
    
    // Create promise
    var promise = Promise.init(allocator);
    
    // Store with promise
    try self.call_manager.pending_calls.put(call_id, .{
        .id = call_id,
        .code = code,
        .callback = null,
        .promise = &promise,
        .timestamp = std.time.milliTimestamp(),
    });
    
    // Execute via helper
    const wrapped = try std.fmt.allocPrint(allocator,
        "window.__turf_rpc.execute({d}, {s})",
        .{call_id, std.json.stringify(code)}
    );
    
    self.evalJavaScript(wrapped);
    
    return promise;
}

// Usage
const promise = try window.callJavaScriptAsync("fetch('/api/data').then(r => r.json())");
const result = try promise.wait(5000); // Wait up to 5 seconds
```

## Synchronous vs Asynchronous

### Synchronous (Blocking)

```zig
// Blocks until response received
const title = try window.callJavaScript("document.title");
print("Title: {s}", .{title});
```

### Asynchronous (Non-blocking)

```zig
// Returns immediately with a promise
const promise = try window.callJavaScriptAsync("fetch('/api/data')");

// Do other work...

// Wait when ready
const data = try promise.wait(5000);
```

### Callback Style

```zig
// Fire and forget with callback
try window.callJavaScriptWithCallback(
    "document.querySelector('button').click()",
    struct {
        fn callback(result: []const u8) void {
            print("Click result: {s}\n", .{result});
        }
    }.callback
);
```

## Implementation Steps

### Step 1: Add Call ID to evalJavaScript

```zig
pub fn evalJavaScriptWithId(self: *Window, call_id: u32, code: []const u8) void {
    // Wrap code with call_id
    const wrapped = std.fmt.allocPrint(allocator,
        "window.__turf_call({d}, function() {{ return {s}; }})",
        .{call_id, code}
    );
    
    self.platform.evalJS(wrapped);
}
```

### Step 2: Inject RPC Helper on Init

```zig
pub fn init() !Window {
    var window = Window{...};
    
    // Inject RPC system
    window.evalJavaScript(@embedFile("turf_rpc.js"));
    
    return window;
}
```

### Step 3: Message Router

```zig
fn routeMessage(self: *Window, raw_message: []const u8) !void {
    const message = try std.json.parse(Message, raw_message);
    
    switch (message.type) {
        .call_response, .call_pending => {
            try self.call_manager.handleResponse(message);
        },
        .user_message => {
            // Regular app messages
            if (self.onMessage) |handler| {
                handler(message);
            }
        },
        else => {}
    }
}
```

## Error Handling

```javascript
// JavaScript side - comprehensive error handling
window.__turf_rpc = {
    execute: async function(call_id, code) {
        const timeout = setTimeout(() => {
            this.sendMessage({
                type: 'call_response',
                call_id: call_id,
                success: false,
                error: 'Execution timeout after 30 seconds'
            });
        }, 30000);
        
        try {
            const result = await eval(code);
            clearTimeout(timeout);
            // ... send result
        } catch(e) {
            clearTimeout(timeout);
            this.sendMessage({
                type: 'call_response',
                call_id: call_id,
                success: false,
                error: {
                    message: e.message,
                    stack: e.stack,
                    type: e.constructor.name
                }
            });
        }
    }
};
```

## Benefits

1. **Bidirectional Communication**: True request/response pattern
2. **Promise Support**: Handle async JavaScript naturally  
3. **Type Safety**: Can add type information to responses
4. **Error Handling**: Proper error propagation
5. **Timeout Support**: Prevent hanging on failed calls
6. **Multiple Calling Styles**: Sync, async, callback

## Example Usage

```zig
// Simple synchronous call
const title = try window.call("document.title");

// Async fetch
const data = try window.call("fetch('/api/user').then(r => r.json())");

// Complex interaction
const result = try window.call(
    \\(() => {
    \\    const form = document.querySelector('form');
    \\    const data = new FormData(form);
    \\    return fetch('/submit', {
    \\        method: 'POST',
    \\        body: data
    \\    }).then(r => r.json());
    \\})()
);

// With timeout
const result = window.callWithTimeout("longRunningOperation()", 10000) catch |err| {
    print("Operation timed out: {}", .{err});
    return default_value;
};
```

## Conclusion

By adding call IDs and a thin RPC layer on top of Turf's existing message passing, we get full bidirectional communication with promise support. The JavaScript side handles the async complexity, while the Zig side can choose between blocking, async, or callback patterns based on the use case.
