# Turf

Lightweight web views with message passing between native code (Zig) and
JavaScript. Creates native windows with embedded WebKit webviews. Build desktop applications using web technologies. 

## Features

- Native window management with WebKit integration
- Bidirectional JavaScript ↔ Native communication via Messages
- Cmd-Q works
- Cmd/+ and Cmd/- zoom the window with persitence across reloads
- Native file dialogs


### Prerequisites

- Zig 0.14.1
- macOS / Xcode Command Line Tools
- Linux / GTK4/WebKit6.0/JavaScriptCore

### Building

```bash
# Build the project
zig build

# Run the application
zig build run

# Run tests
zig build test
```

### Usage

```bash
# Launch with default page
./zig-out/bin/turf

# Open a URL
./zig-out/bin/turf https://example.com

# Open a local file
./zig-out/bin/turf path/to/file.html
```

## Keyboard Shortcuts

**MacOS**
- **Cmd +** : Zoom in
- **Cmd -** : Zoom out
- **Cmd 0** : Reset zoom
- **Cmd Q** : Quit

## Architecture

Turf uses a layered architecture:

- **Native Layer** (Zig): Window management and application lifecycle

- **Bridge Layer** 
  - **MacOS** (Objective-C): Platform-specific WebKit integration
  - **Linux** (C): WebKitGTK6.0/JavaScriptCore (GTK4)

- **Web Layer** (JavaScript/HTML): User interface and application logic


Communication between layers uses JSON message passing.

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines and architecture documentation.

