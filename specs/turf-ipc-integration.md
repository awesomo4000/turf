# Turf IPC Integration Plan

## Current Turf Capabilities

Turf already has most of what we need:

1. **`evalJavaScript(script: [:0]const u8)`** - Execute JS in webview
2. **`MessageQueue`** - Thread-safe message passing
3. **`sendMessage(type, data)`** - Native → JS communication
4. **Message handling** - JS → Native via callbacks

## Integration Options

### Option 1: Add IPC Mode to Turf (Recommended)

Add a simple stdin/stdout JSON protocol to Turf:

```zig
// turf --ipc
// Launches Turf in IPC mode - reads commands from stdin, writes responses to stdout

// In main.zig
pub fn main() !void {
    // ... existing setup ...
    
    // Check for IPC mode
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name
    
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ipc")) {
            return runIPCMode(&window);
        }
    }
    
    // ... normal GUI mode ...
}

fn runIPCMode(window: *Window) !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    
    var buf: [8192]u8 = undefined;
    
    // Send ready signal
    try stdout.print("{{\"ready\":true}}\n", .{});
    
    // Main IPC loop
    while (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const cmd = try parseCommand(line);
        const response = try executeCommand(window, cmd);
        try stdout.print("{s}\n", .{response});
        
        // Flush to ensure cdptun receives it
        try stdout.flush();
    }
}
```

### Option 2: Add Message Handler for IPC

Use Turf's existing message system:

```zig
// In turf.zig or platform backend
pub fn enableIPCMode(self: *Window) !void {
    // Set up handler for IPC messages from JS
    self.onMessage = handleIPCMessage;
    
    // Inject IPC bridge into page
    const ipc_bridge =
        \\window.__turf_ipc = {
        \\    eval: function(code) {
        \\        try {
        \\            const result = eval(code);
        \\            window.webkit.messageHandlers.turf.postMessage({
        \\                type: 'eval_result',
        \\                value: JSON.stringify(result)
        \\            });
        \\        } catch(e) {
        \\            window.webkit.messageHandlers.turf.postMessage({
        \\                type: 'eval_error',
        \\                error: e.toString()
        \\            });
        \\        }
        \\    }
        \\};
    ;
    self.evalJavaScript(ipc_bridge);
}

fn handleIPCMessage(msg: Message) void {
    // Route to stdout for cdptun
    const stdout = std.io.getStdOut().writer();
    stdout.print("{s}\n", .{msg.data}) catch {};
}
```

### Option 3: Direct CDP Mode

Add minimal CDP WebSocket server to Turf:

```zig
// turf --cdp 9222
// Starts Turf with embedded CDP server

const CDPServer = struct {
    window: *Window,
    server: std.net.StreamServer,
    
    pub fn init(window: *Window, port: u16) !CDPServer {
        var server = std.net.StreamServer.init(.{});
        const addr = try std.net.Address.parseIp("127.0.0.1", port);
        try server.listen(addr);
        
        return CDPServer{
            .window = window,
            .server = server,
        };
    }
    
    pub fn run(self: *CDPServer) !void {
        while (true) {
            const conn = try self.server.accept();
            // Handle WebSocket upgrade
            try self.handleConnection(conn.stream);
        }
    }
    
    fn handleCDPCommand(self: *CDPServer, cmd: CDPCommand) !CDPResponse {
        switch (cmd.method) {
            "Runtime.evaluate" => {
                const result = self.window.evalJavaScript(cmd.params.expression);
                return CDPResponse{
                    .id = cmd.id,
                    .result = .{ .result = .{ .value = result } },
                };
            },
            "Page.navigate" => {
                self.window.loadURL(cmd.params.url);
                return CDPResponse{ .id = cmd.id, .result = .{} };
            },
            else => {
                // Return empty success for unknown commands
                return CDPResponse{ .id = cmd.id, .result = .{} };
            }
        }
    }
};
```

## IPC Protocol Design

### Simple Line-Delimited JSON

Commands from cdptun → Turf:

```json
{"id":1,"cmd":"eval","code":"document.title"}
{"id":2,"cmd":"navigate","url":"https://example.com"}
{"id":3,"cmd":"url"}
{"id":4,"cmd":"html"}
{"id":5,"cmd":"close"}
```

Responses from Turf → cdptun:

```json
{"id":1,"result":"Page Title"}
{"id":2,"result":"ok"}
{"id":3,"result":"https://example.com"}
{"id":4,"result":"<html>...</html>"}
{"id":5,"result":"closing"}
```

### Error Handling

```json
// Error response
{
  "id": 1,
  "error": "ReferenceError: foo is not defined",
  "type": "js_error"
}
```

## Implementation Steps

### Step 1: Add Basic IPC Loop

```zig
// Minimal IPC handler
fn runIPCMode(window: *Window) !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var buf: [8192]u8 = undefined;
    
    while (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        // Parse JSON
        var parser = std.json.Parser.init(allocator, false);
        defer parser.deinit();
        
        var tree = try parser.parse(line);
        defer tree.deinit();
        
        const root = tree.root;
        const id = root.Object.get("id").?.Integer;
        const cmd = root.Object.get("cmd").?.String;
        
        // Execute command
        const result = switch (cmd) {
            "eval" => blk: {
                const code = root.Object.get("code").?.String;
                const js_result = window.evalJavaScript(code);
                break :blk js_result;
            },
            "navigate" => blk: {
                const url = root.Object.get("url").?.String;
                window.loadURL(url);
                break :blk "ok";
            },
            else => "unknown command",
        };
        
        // Send response
        try stdout.print(
            \\{{"id":{},"result":"{s}"}}
        , .{ id, result });
        try stdout.print("\n", .{});
    }
}
```

### Step 2: Add Result Callback

Since `evalJavaScript` might be async, we need a way to get results:

```zig
// Add to Window struct
result_callback: ?fn([]const u8) void,

pub fn evalJavaScriptWithCallback(
    self: *Window,
    script: [:0]const u8,
    callback: fn([]const u8) void
) void {
    self.result_callback = callback;
    
    // Wrap script to capture result
    const wrapped = std.fmt.allocPrintZ(
        allocator,
        \\(function() {{
        \\    const result = {s};
        \\    window.webkit.messageHandlers.turf.postMessage({{
        \\        type: 'eval_result',
        \\        value: JSON.stringify(result)
        \\    }});
        \\    return result;
        \\}})()
    , .{script});
    
    self.platform.evalJS(wrapped);
}
```

### Step 3: Handle Async Results

```zig
// Message handler
fn handleMessage(self: *Window, msg: Message) void {
    if (std.mem.eql(u8, msg.type, "eval_result")) {
        if (self.result_callback) |callback| {
            callback(msg.data);
            self.result_callback = null;
        }
    }
}
```

## Testing the Integration

### Test Script

```bash
#!/bin/bash
# test_ipc.sh

# Start Turf in IPC mode
mkfifo turf_in turf_out
turf --ipc < turf_in > turf_out &
TURF_PID=$!

# Send commands
echo '{"id":1,"cmd":"navigate","url":"https://example.com"}' > turf_in
echo '{"id":2,"cmd":"eval","code":"document.title"}' > turf_in

# Read responses
while read response; do
    echo "Response: $response"
done < turf_out

kill $TURF_PID
```

### Integration Test with cdptun

```bash
# Terminal 1: Start cdptun
cdptun --backend turf --port 9222

# Terminal 2: Test with Bromux
bromux launch test --cdp-port 9222
bromux tab eval test "document.title"
```

## Benefits of This Approach

1. **Minimal Changes to Turf** - Just add IPC mode
2. **Clean Separation** - cdptun handles CDP complexity
3. **Reusable** - IPC mode useful for other integrations
4. **Testable** - Can test IPC independently
5. **Performant** - Simple JSON over pipes is fast

## Alternative: Embedded CDP

If we want Turf to directly support CDP without cdptun:

```zig
// Minimal WebSocket server in Turf
const MiniCDP = struct {
    pub fn handleRequest(window: *Window, request: []const u8) ![]const u8 {
        // Parse CDP JSON-RPC
        var parser = std.json.Parser.init(allocator, false);
        var tree = try parser.parse(request);
        defer tree.deinit();
        
        const method = tree.root.Object.get("method").?.String;
        const id = tree.root.Object.get("id").?.Integer;
        
        const result = switch (method) {
            "Runtime.evaluate" => {
                const expr = tree.root.Object.get("params").?.Object.get("expression").?.String;
                const js_result = window.evalJavaScript(expr);
                return std.fmt.allocPrint(allocator,
                    \\{{"id":{},"result":{{"result":{{"type":"string","value":"{s}"}}}}}}
                , .{ id, js_result });
            },
            else => {
                return std.fmt.allocPrint(allocator,
                    \\{{"id":{},"result":{{}}}}
                , .{id});
            },
        };
        
        return result;
    }
};
```

## Conclusion

The simplest path:
1. Add `--ipc` mode to Turf for stdin/stdout JSON
2. Create cdptun as a separate bridge process
3. cdptun translates CDP ↔ Simple JSON
4. Bromux/Playwright/Puppeteer → cdptun → Turf

This gives us CDP compatibility without bloating Turf!