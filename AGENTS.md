# Turf Project - Agent Guidelines

## Build Commands
- Build: `zig build`
- Run: `zig build run`
- Test: `zig build test` (Note: Tests may fail due to missing Obj-C symbols)
- Clean: `rm -rf zig-out/ .zig-cache/`

## Code Style
- Language: Zig (0.14.0+)
- Imports: Use `@import()` for modules, group std imports first
- Naming: snake_case for variables/functions, PascalCase for types
- Error handling: Use `!` for error unions, handle with `try` or `catch`
- Memory: Always use allocators, defer cleanup with `defer`
- Comments: Use `//` for single-line, avoid unless necessary

## Project Structure
- `src/main.zig`: Entry point with window initialization
- `src/turf.zig`: Core window/webview functionality
- `src/util.zig`: Helper utilities
- `src/cocoa_bridge.m`: Objective-C bridge for macOS
- `src/web/`: Web assets (HTML, JS)

## Key Patterns
- External C functions: Declare with `extern fn`
- Structs: Use explicit field initialization
- Testing: Add tests inline with `test "description" { ... }`