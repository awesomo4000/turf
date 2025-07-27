const std = @import("std");
const turf = @import("turf");

// Demo showcasing full bidirectional messaging capabilities
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create message queue externally
    var message_queue = turf.MessageQueue.init(allocator);
    defer message_queue.deinit();

    const config = turf.WindowConfig{
        .geometry = .{ .x = 100, .y = 100, .width = 900, .height = 700 },
        .title = "Turf Bidirectional Messaging Demo",
    };

    var window = try turf.Window.init(allocator, config, &message_queue);
    defer window.deinit();

    window.createWindow();

    // Start message pump at 60Hz for responsive communication
    window.startMessagePump(16);

    // Start a thread to send periodic updates from native to JS
    const thread = try std.Thread.spawn(.{}, nativeMessageThread, .{&window});

    const html: [:0]const u8 =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <style>
        \\        body { 
        \\            font-family: system-ui, -apple-system, sans-serif; 
        \\            padding: 20px;
        \\            background: #f5f5f5;
        \\        }
        \\        .container {
        \\            max-width: 800px;
        \\            margin: 0 auto;
        \\            background: white;
        \\            padding: 30px;
        \\            border-radius: 10px;
        \\            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        \\        }
        \\        h1 { color: #333; margin-bottom: 10px; }
        \\        .subtitle { color: #666; margin-bottom: 30px; }
        \\        
        \\        .section {
        \\            margin: 20px 0;
        \\            padding: 20px;
        \\            background: #f9f9f9;
        \\            border-radius: 8px;
        \\            border: 1px solid #e0e0e0;
        \\        }
        \\        
        \\        button {
        \\            background: #007bff;
        \\            color: white;
        \\            border: none;
        \\            padding: 10px 20px;
        \\            border-radius: 5px;
        \\            cursor: pointer;
        \\            font-size: 14px;
        \\            margin: 5px;
        \\        }
        \\        button:hover {
        \\            background: #0056b3;
        \\        }
        \\        button:active {
        \\            transform: translateY(1px);
        \\        }
        \\        
        \\        .message-log {
        \\            background: #f0f0f0;
        \\            padding: 15px;
        \\            border-radius: 5px;
        \\            max-height: 200px;
        \\            overflow-y: auto;
        \\            font-family: monospace;
        \\            font-size: 12px;
        \\            margin: 10px 0;
        \\        }
        \\        
        \\        .message-item {
        \\            margin: 5px 0;
        \\            padding: 5px;
        \\            background: white;
        \\            border-radius: 3px;
        \\        }
        \\        .message-from-js { border-left: 3px solid #28a745; }
        \\        .message-from-native { border-left: 3px solid #dc3545; }
        \\        
        \\        .stats {
        \\            display: grid;
        \\            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
        \\            gap: 15px;
        \\            margin: 15px 0;
        \\        }
        \\        .stat-box {
        \\            background: white;
        \\            padding: 15px;
        \\            border-radius: 5px;
        \\            text-align: center;
        \\            border: 1px solid #e0e0e0;
        \\        }
        \\        .stat-value {
        \\            font-size: 24px;
        \\            font-weight: bold;
        \\            color: #007bff;
        \\        }
        \\        .stat-label {
        \\            font-size: 12px;
        \\            color: #666;
        \\            margin-top: 5px;
        \\        }
        \\        
        \\        input[type="text"] {
        \\            padding: 8px;
        \\            border: 1px solid #ddd;
        \\            border-radius: 4px;
        \\            width: 300px;
        \\            margin-right: 10px;
        \\        }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <h1>🔄 Bidirectional Messaging Demo</h1>
        \\        <p class="subtitle">Real-time communication between JavaScript and Native</p>
        \\        
        \\        <div class="section">
        \\            <h3>📤 Send Messages to Native</h3>
        \\            <button onclick="sendPing()">Send Ping</button>
        \\            <button onclick="sendEcho()">Send Echo Request</button>
        \\            <button onclick="sendTime()">Request Time</button>
        \\            <button onclick="sendRandom()">Request Random Number</button>
        \\            <div style="margin-top: 15px;">
        \\                <strong>Last Random Number:</strong> 
        \\                <span id="randomNumber" style="font-size: 20px; color: #007bff; font-weight: bold;">-</span>
        \\            </div>
        \\            <div style="margin-top: 15px;">
        \\                <input type="text" id="customMessage" placeholder="Enter custom message">
        \\                <button onclick="sendCustom()">Send Custom</button>
        \\            </div>
        \\        </div>
        \\        
        \\        <div class="section">
        \\            <h3>📊 Statistics</h3>
        \\            <div class="stats">
        \\                <div class="stat-box">
        \\                    <div class="stat-value" id="sentCount">0</div>
        \\                    <div class="stat-label">Messages Sent</div>
        \\                </div>
        \\                <div class="stat-box">
        \\                    <div class="stat-value" id="receivedCount">0</div>
        \\                    <div class="stat-label">Messages Received</div>
        \\                </div>
        \\                <div class="stat-box">
        \\                    <div class="stat-value" id="nativeCounter">0</div>
        \\                    <div class="stat-label">Native Counter</div>
        \\                </div>
        \\                <div class="stat-box">
        \\                    <div class="stat-value" id="latency">-</div>
        \\                    <div class="stat-label">Latency (ms)</div>
        \\                </div>
        \\            </div>
        \\        </div>
        \\        
        \\        <div class="section">
        \\            <h3>📜 Message Log</h3>
        \\            <div class="message-log" id="messageLog"></div>
        \\            <button onclick="clearLog()">Clear Log</button>
        \\        </div>
        \\    </div>
        \\
        \\    <script>
        \\        let sentCount = 0;
        \\        let receivedCount = 0;
        \\        let pingTimestamp = null;
        \\        
        \\        function updateStats() {
        \\            document.getElementById('sentCount').textContent = sentCount;
        \\            document.getElementById('receivedCount').textContent = receivedCount;
        \\        }
        \\        
        \\        function addToLog(message, fromNative = false) {
        \\            const log = document.getElementById('messageLog');
        \\            const item = document.createElement('div');
        \\            item.className = 'message-item ' + (fromNative ? 'message-from-native' : 'message-from-js');
        \\            const timestamp = new Date().toLocaleTimeString();
        \\            item.textContent = `[${timestamp}] ${fromNative ? '← Native' : '→ JS'}: ${message}`;
        \\            log.insertBefore(item, log.firstChild);
        \\            
        \\            // Keep only last 50 messages
        \\            while (log.children.length > 50) {
        \\                log.removeChild(log.lastChild);
        \\            }
        \\        }
        \\        
        \\        function clearLog() {
        \\            document.getElementById('messageLog').innerHTML = '';
        \\        }
        \\        
        \\        function sendPing() {
        \\            if (window.turf) {
        \\                pingTimestamp = Date.now();
        \\                window.turf.send({type: 'ping', data: {}});
        \\                sentCount++;
        \\                updateStats();
        \\                addToLog('Sent ping');
        \\            }
        \\        }
        \\        
        \\        function sendEcho() {
        \\            if (window.turf) {
        \\                const message = 'Hello from JavaScript!';
        \\                const payload = {type: 'echo', data: {message: message}};
        \\                console.log('Sending echo payload:', payload);
        \\                window.turf.send(payload);
        \\                sentCount++;
        \\                updateStats();
        \\                addToLog(`Sent echo: "${message}"`);
        \\            }
        \\        }
        \\        
        \\        function sendTime() {
        \\            if (window.turf) {
        \\                window.turf.send({type: 'get_time', data: {}});
        \\                sentCount++;
        \\                updateStats();
        \\                addToLog('Requested current time');
        \\            }
        \\        }
        \\        
        \\        function sendRandom() {
        \\            if (window.turf) {
        \\                window.turf.send({type: 'get_random', data: {min: 1, max: 100}});
        \\                sentCount++;
        \\                updateStats();
        \\                addToLog('Requested random number (1-100)');
        \\            }
        \\        }
        \\        
        \\        function sendCustom() {
        \\            const input = document.getElementById('customMessage');
        \\            const message = input.value.trim();
        \\            if (window.turf && message) {
        \\                window.turf.send({type: 'custom', data: {message: message}});
        \\                sentCount++;
        \\                updateStats();
        \\                addToLog(`Sent custom: "${message}"`);
        \\                input.value = '';
        \\            }
        \\        }
        \\        
        \\        // Set up message handlers when turf is ready
        \\        function setupHandlers() {
        \\            if (!window.turf) {
        \\                setTimeout(setupHandlers, 100);
        \\                return;
        \\            }
        \\            
        \\            console.log('Setting up Turf message handlers...');
        \\            
        \\            // Handle pong responses
        \\            window.turf.onMessage('pong', function(data) {
        \\                console.log('Pong received:', data);
        \\                receivedCount++;
        \\                updateStats();
        \\                
        \\                if (pingTimestamp) {
        \\                    const latency = Date.now() - pingTimestamp;
        \\                    document.getElementById('latency').textContent = latency;
        \\                    pingTimestamp = null;
        \\                }
        \\                
        \\                addToLog(`Pong: ${data.message}`, true);
        \\            });
        \\            
        \\            // Handle echo responses
        \\            window.turf.onMessage('echo_response', function(data) {
        \\                receivedCount++;
        \\                updateStats();
        \\                addToLog(`Echo response: "${data.message}"`, true);
        \\            });
        \\            
        \\            // Handle time responses
        \\            window.turf.onMessage('time_response', function(data) {
        \\                receivedCount++;
        \\                updateStats();
        \\                addToLog(`Time: ${data.time}`, true);
        \\            });
        \\            
        \\            // Handle random number responses
        \\            window.turf.onMessage('random_response', function(data) {
        \\                console.log('Random response received:', data);
        \\                receivedCount++;
        \\                updateStats();
        \\                // Update the random number display
        \\                document.getElementById('randomNumber').textContent = data.value;
        \\                addToLog(`Random number: ${data.value}`, true);
        \\            });
        \\            
        \\            // Handle counter updates from native
        \\            window.turf.onMessage('counter_update', function(data) {
        \\                receivedCount++;
        \\                updateStats();
        \\                document.getElementById('nativeCounter').textContent = data.value;
        \\                addToLog(`Counter update: ${data.value}`, true);
        \\            });
        \\            
        \\            // Handle custom responses
        \\            window.turf.onMessage('custom_response', function(data) {
        \\                receivedCount++;
        \\                updateStats();
        \\                addToLog(`Custom response: "${data.message}"`, true);
        \\            });
        \\            
        \\            // Log that we're ready
        \\            addToLog('Turf messaging system ready');
        \\            
        \\            // Allow Enter key in custom message input
        \\            document.getElementById('customMessage').addEventListener('keypress', function(e) {
        \\                if (e.key === 'Enter') {
        \\                    sendCustom();
        \\                }
        \\            });
        \\        }
        \\        
        \\        // Start setting up handlers
        \\        setupHandlers();
        \\    </script>
        \\</body>
        \\</html>
    ;

    window.loadString(html);

    try window.run();

    // Signal thread to stop and wait for it
    window.running.store(false, .seq_cst);
    thread.join();
}

// Thread that sends periodic messages from native to JavaScript
fn nativeMessageThread(window: *turf.Window) !void {
    var counter: u32 = 0;

    while (window.isRunning()) {
        // Send counter update every second
        counter += 1;
        try window.sendMessage("counter_update", .{ .value = counter });

        std.time.sleep(1 * std.time.ns_per_s);
    }
}
