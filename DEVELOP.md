# Development Guide

This document describes the project architecture and development conventions.

## Overview

Turf is a cross-platform application framework written in Zig that creates native windows with embedded webviews. It uses WebKit on macOS, WebKitGTK on Linux, and WebView2 on Windows to support native desktop applications with web-based interfaces.

## Build Commands

- **Build**: `zig build`
- **Run**: `zig build run`
- **Test**: `zig build test`
- **Clean**: `rm -rf zig-out/ .zig-cache/`

## Architecture

### Core Components

1. **Native Layer** (`src/turf.zig`): Main window management API
   - Window creation, configuration, and lifecycle
   - JavaScript injection and evaluation
   - Message passing between native and web layers

2. **Platform Bridges**
   - macOS: Objective-C bridge in `src/platforms/macos/cocoa_bridge.m`
   - Linux: GTK4 and WebKitGTK 6.0 integration
   - Windows: WebView2 integration
   - Native window management, event handling, and message passing

3. **Entry Point** (`src/main.zig`): Application initialization
   - Command-line argument handling (URLs or local files)
   - Window configuration and startup

4. **Web Layer** (`src/web/`): JavaScript and HTML assets
   - `turf.js`: Injected into every page for native communication
   - `index.html`: Default UI when no URL/file specified

### Key Patterns

- **Message Passing**: JSON-based communication between JavaScript and native code via `onJavaScriptMessage` export
- **Event System**: Window geometry events and JavaScript readiness signals
- **Memory Management**: Uses Zig allocators with leak detection in debug builds
- **JavaScript Injection**: `turf.js` is embedded at compile time and injected into all loaded pages

## Development Guidelines

- **Zig Version**: Requires 0.16.0
- **Platforms**: Keep platform-specific code under `src/platforms/`
- **Error Handling**: Use error unions (`!`) and handle with `try`/`catch`
- **Testing**: Unit tests can be added inline with `test "description" { ... }`
