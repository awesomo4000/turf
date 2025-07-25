# Turf

Lightweight web views with message passing between native code (Zig) and
JavaScript. Creates native windows with embedded WebKit webviews. Build desktop applications using web technologies. 

## Features

- Native window management with WebKit integration
- Bidirectional JavaScript ↔ Native communication via Messages
- Cmd-Q works
- Cmd/+ and Cmd/- zoom the window with persitence across reloads
- Native file dialogs
- Small binary size (~250kb in --release=small)


### Prerequisites

- Zig 0.14.1
- macOS (currently the only supported platform)
- Xcode Command Line Tools

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

- **Cmd +** : Zoom in
- **Cmd -** : Zoom out
- **Cmd 0** : Reset zoom
- **Cmd Q** : Quit

## Architecture

Turf uses a layered architecture:

- **Native Layer** (Zig): Window management and application lifecycle
- **Bridge Layer** (Objective-C): Platform-specific WebKit integration
- **Web Layer** (JavaScript/HTML): User interface and application logic

Communication between layers uses JSON message passing, allowing for clean separation of concerns.

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines and architecture documentation.

## License

This project is open source. See LICENSE file for details.
