# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Turf is a cross-platform application framework written in Zig that creates native windows with embedded WebKit webviews. It bridges Objective-C/Cocoa on macOS with a JavaScript runtime, allowing for native desktop applications with web-based UIs.

## Build Commands

- **Build**: `zig build`
- **Run**: `zig build run`
- **Test**: `zig build test` (Note: Tests may fail due to missing Obj-C symbols)
- **Clean**: `rm -rf zig-out/ .zig-cache/`

## Architecture

### Core Components

1. **Native Layer** (`src/turf.zig`): Main window management API
   - Window creation, configuration, and lifecycle
   - JavaScript injection and evaluation
   - Message passing between native and web layers
   - File dialog integration

2. **Platform Bridge** (`src/cocoa_bridge.m`): Objective-C bridge for macOS
   - WebKit integration
   - Native window management
   - Event handling and message passing

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

- **Zig Version**: Requires 0.14.0+
- **Platform**: Currently macOS-only (Cocoa/WebKit frameworks required)
- **Error Handling**: Use error unions (`!`) and handle with `try`/`catch`
- **Testing**: Unit tests can be added inline with `test "description" { ... }`