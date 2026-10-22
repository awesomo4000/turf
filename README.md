<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2025-2026 awesomo4000 -->

<p align="left">
  <img src="img/turf.png" alt="Turf: portable webviews for desktop applications" width="660">
</p>

# turf

Lightweight webviews with message passing between native code (Zig) and JavaScript. Turf creates native windows with platform webviews for building portable desktop applications using web technologies.

## Features

- Native window management with platform webview integration
- Bidirectional JSON message passing between JavaScript and Zig
- URL, local file, and HTML content loading
- JavaScript evaluation from native code
- Persistent zoom controls and standard application quit behavior on macOS

## Supported OSes

| Operating system | Native window layer | Web technology | Requirements |
| --- | --- | --- | --- |
| macOS | Cocoa | WebKit (`WKWebView`) | Xcode Command Line Tools |
| Linux | GTK4 | WebKitGTK 6.0 and JavaScriptCoreGTK 6.0 | GTK4 and WebKitGTK development packages |
| Windows | Win32 | Microsoft Edge WebView2 | WebView2 Runtime |

### Prerequisites

- Zig 0.16.0
- The platform requirements listed above

### Building

```bash
# Build the project
zig build

# Run the application
zig build run

# Run the messaging demo
zig build run-demo

# Run tests
zig build test
```

### Usage

```bash
# Show usage
./zig-out/bin/turf --help

# Launch with default page
./zig-out/bin/turf

# Open a URL
./zig-out/bin/turf https://example.com

# Open a local file
./zig-out/bin/turf path/to/file.html
```

### Startup logo API

Set `WindowConfig.startup_logo` when creating a window:

```zig
const config: turf.WindowConfig = .{
    .geometry = .{ .x = 100, .y = 100, .width = 600, .height = 800 },
    .title = "My app",
    .startup_logo = .in_out,
};
```

- `.off` is the default and hides the bottom-right Turf logo.
- `.in_out` plays the rainbow animation, returns to gray, then fades out and removes the logo.
- `.stay` plays the rainbow animation and leaves the gray logo visible.

The setting applies whenever a page loads in the window. It is available only through the Zig API.

### macOS automation

Automation is opt-in and uses an explicit Unix socket path. There is no discovery
or hibrow integration yet. Create a private directory, then launch Turf:

```bash
automation_dir=$(mktemp -d /tmp/turf-automation.XXXXXX)
echo "$automation_dir/control.sock"
./zig-out/bin/turf --automation-socket "$automation_dir/control.sock"
```

From another terminal, use the actual socket path printed by
`echo "$automation_dir/control.sock"` in the first shell:

```bash
python3 tools/turf-client.py /tmp/turf-automation.XXXXXX/control.sock info
python3 tools/turf-client.py /tmp/turf-automation.XXXXXX/control.sock evaluate '{"expression":"document.title"}'
python3 tools/turf-client.py /tmp/turf-automation.XXXXXX/control.sock navigate '{"url":"https://example.com"}'
python3 tools/turf-client.py /tmp/turf-automation.XXXXXX/control.sock resize '{"width":800,"height":600}'
python3 tools/turf-client.py /tmp/turf-automation.XXXXXX/control.sock screenshot -o /tmp/turf.png
python3 tools/turf-client.py /tmp/turf-automation.XXXXXX/control.sock close
```

Embedding applications enable the same endpoint on the main thread after creating
the window and before entering its event loop:

```zig
window.createWindow();
try window.startAutomation("/absolute/private-directory/control.sock");
try window.run();
// window.deinit() stops automation; window.stopAutomation() can stop it earlier.
```

The parent directory must already exist, belong to the current user, and have no
group or other permissions, typically mode `0700`. Turf creates a `0600` socket
and accepts connections only from the same user. Existing paths are never
replaced. Normal shutdown removes the socket; after a crash, use a new path or
remove the stale socket yourself. Automation controls this application, including
executing page JavaScript and closing its window. Keep it disabled when unused.
No SIP changes or private WebKit automation APIs are required.

The macOS bridge now includes `automation.m` alongside `cocoa_bridge.m`; embedding
builds that compile the bridge themselves must compile both with ARC and link
Cocoa and WebKit. The bundled executable and demo build already do this.

#### Socket protocol, version 1

Each request and response is one UTF-8 JSON line using JSON-RPC 2.0. Requests need
a string or numeric `id`, a string `method`, and an optional object `params`.
Notifications and batches are not supported. Unknown methods return `-32601`.

```json
{"jsonrpc":"2.0","id":1,"method":"evaluate","params":{"expression":"document.title"}}
{"jsonrpc":"2.0","id":1,"result":{"type":"string","value":"Welcome"}}
```

| Method | Parameters | Result |
| --- | --- | --- |
| `info` | None | Protocol version, PID, engine, page title, URL, loading state, and methods |
| `evaluate` | `expression` string | `{type, value}` after awaiting promises; `undefined` omits `value` |
| `navigate` | Absolute `url`, using http, https, file, or about | Final URL after navigation finishes; failure returns an error |
| `screenshot` | None | Viewport PNG as base64 `data`, plus `format`, pixel `width`, and pixel `height` |
| `resize` | Numeric `width` and `height`, 1–8192 | Webview dimensions in points after resizing the window content |
| `close` | None | `{closing: true}`, followed by closing the window |

Evaluation runs in the main frame and page world and requires macOS 11 or newer.
Values use JavaScript JSON serialization: cycles and BigInts produce errors;
non-finite numbers become null, and function/undefined object properties are
omitted. Object handles, native input, cross-origin frame selection, and debugger
breakpoints are not part of this protocol.

Commands execute sequentially, with one active client connection at a time.
Clients may reuse a connection or reconnect for each request. An incomplete or
idle request has a 10-second read deadline. Operations and response writes have
30-second deadlines. A timed-out JavaScript operation may still finish; its late
result is discarded. Requests are limited to 1 MiB and responses to 32 MiB.
A navigation response means the page finished loading, not that application
fetches, fonts, or rendering have settled; use evaluation to wait for app readiness.

Run the integration checks from a macOS GUI session:

```bash
python3 tests/automation_macos.py
```

These checks launch the actual system WKWebView and use disposable files under
`/tmp`, including a check that an existing file cannot be overwritten by startup.

## Keyboard Shortcuts

These shortcuts are currently available on macOS:

| Shortcut | Action |
| --- | --- |
| <kbd>Cmd</kbd> + <kbd>+</kbd> | Zoom in |
| <kbd>Cmd</kbd> + <kbd>-</kbd> | Zoom out |
| <kbd>Cmd</kbd> + <kbd>0</kbd> | Reset zoom |
| <kbd>Cmd</kbd> + <kbd>Q</kbd> | Quit |

## Architecture

Turf uses a layered architecture:

- **Native layer** (Zig): Window management and application lifecycle
- **Bridge layer**: Platform-specific Cocoa/WebKit, GTK4/WebKitGTK, or Win32/WebView2 integration
- **Web layer** (JavaScript/HTML): User interface and application logic

Communication between the native and web layers uses JSON message passing.

## Development

See [DEVELOP.md](DEVELOP.md) for detailed development guidelines and architecture documentation.

## License

Copyright (c) 2025-2026 awesomo4000. Original Turf code is licensed under the
[Mozilla Public License 2.0](LICENSE).
When MPL-covered Turf files are distributed with modifications, those files and
their modifications must remain available under MPL-2.0. Separate applications
and source files that merely import, link to, or use Turf may remain proprietary
or use another license.

Microsoft WebView2 loader binaries retain their upstream terms and are not
covered by Turf's MPL-2.0 license. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.
