# Automation work

Work in order; macOS first. Windows/Linux ports follow verified contracts.

- [x] Capture evaluation exceptions and rejected promises as structured RPC errors.
- [x] Distinguish JavaScript exceptions, result serialization failures, native errors, and timeouts.
- [x] Add opt-in bounded console, uncaught-error, and unhandled-rejection diagnostics.
- [x] Give diagnostics independent read cursors, sequence numbers, document/frame metadata, and explicit loss reporting.
- [x] Add repeatable local fixtures and independent assertions for errors, frames, navigation, flooding, and late completion.
- [x] Provide an agent task pack using only CLI help; record success, command count, source-inspection escapes, guesses, and arbitrary sleeps.
- [ ] Run the task pack with agents of different capabilities; fix confusing contracts and help before expanding features.
- [x] Improve evaluation CLI help and document error/cursor contracts.
- [x] Replace the production Python client with turfctl, a standalone Zig CLI and reusable Zig module; retain an independent Python reference only for tests.
- [x] Add evaluation file/stdin input through turfctl, plus JSON parameter files/stdin.
- [ ] Add bounded condition waits with useful timeout diagnostics and no automatic mutation retries.
- [x] Add macOS rect/selector screenshots with padding and capture geometry; keep pane selection in the embedding app.
- [x] Port regional screenshots to Windows/Linux and run the shared pixel/geometry contract on each backend, including baseline PNG compatibility and scaled Windows desktop captures.
- [x] Obtain user verification of 2x Retina regional screenshots, including hidden capture, padding, rounding, clamping, and iframe coordinates. Automated native pixel comparisons currently use the selected 1x test display.
- [ ] Run the automated regional screenshot pixel comparisons on a Retina display.
- [x] Investigate blank macOS file:// iframes: loadFile and automation navigate allow the host directory tree; outside-tree files remain blank, while same-tree and srcdoc content render. Added hidden/visible pixel and execution regressions. Original report paths remain unknown.
- [ ] Design an explicit macOS file-read-root option and consistent loadURL(file://) handling; the generic URL loader currently has different observed access behavior. Preserve the containing-directory default for loadFile/navigation.
- [ ] Add bounded chunked upload alongside grab.
- [ ] Allow independent macOS connections to progress without an idle connection monopolizing the server.
- [ ] Define explicit frame targeting and navigation identity; distinguish same-origin helpers from cross-origin automation.
- [ ] Design an optional gateway around explicitly supplied session endpoints, ownership, and operation grouping. No automatic global discovery requirement.
- [x] Port structured errors and diagnostics to Windows/Linux; run the shared contract and native regressions.

Keep PTY input, terminal grids, pane layouts, persistent overlays, animation seek
hooks, and per-pane policy in the companion application. Preserve promise-aware
evaluation and explicit socket selection. A timeout does not imply cancellation.

Local GUI tests take their display choice from TURF_TEST_SCREEN, not committed
machine names. Use the selected display's lower-third center and preserve focus.

## Coverage

- [x] Measure macOS Objective-C bridge line/function/branch coverage with the existing integration suites and generate HTML/JSON reports.
- [x] Add macOS embedder tests for direct URL/file loading, JavaScript evaluation, position, and explicit automation-stop APIs.
- [x] Add Zig queue/message edge-case tests with exhaustive allocation-failure checks, escaped names, and separate allocators; fix ownership and delivery cleanup.
- [x] Exercise macOS embedder-owned windows through graceful shutdown and queue teardown, with native message traffic; stop and join the message pump.
- [x] Test macOS public loadFile with spaces, #, %, ?, and Unicode in disposable paths; use the native file-URL loader.
- [ ] Port file-path and built-in message validation fixes/tests to Windows/Linux.
- [x] Test macOS built-in native echo/custom handlers with escaped payloads and get_random with invalid bounds.
- [ ] Exercise navigation failure callbacks and controlled native-dialog behavior.
- [x] Validate macOS Zig line coverage with known hit/miss paths and run the integration suites under kcov.
- [ ] Measure injected-JavaScript coverage separately; do not treat native percentages as whole-project coverage.

## Fuzzing

- [x] Add a bounded coverage-guided Zig queue/message round-trip target, also run as seed-corpus tests under `zig build test`.
- [x] Add seeded macOS automation wire mutations with response assertions, fragmentation, 1 MiB boundaries, recovery checks, and replay artifacts.
- [ ] Port the parser mutation runner and lifecycle fixture to Windows/Linux.
- [ ] Fuzz chunked-transfer offsets, interrupted transfers, and lifecycle operation sequences.
- [ ] Add a standalone native request-parser target for coverage-guided fuzzing without starting WebKit.

## Embedder failure modes (macOS first)

- [x] Repeated create/run/close/deinit in one process: stale callbacks, native windows, threads, descriptors, and Zig allocations.
- [x] Shutdown with evaluation, navigation, diagnostics, and a large response pending.
- [x] Queue overload with slow/hidden consumers: measure retention and define bounds/backpressure.
- [x] Navigation during native message delivery: define and test document ownership.
- [x] Client disconnect during partial requests/responses or pending work; verify recovery.
- [x] Main-thread API contract and concurrent queue producers with supported allocators.
- [x] Input validation: unusual local paths, reversed random bounds, and escaped built-in handler payloads.


The failure-mode checks above use deterministic regression scenarios, not arbitrary
lifecycle fuzzing. Native windows/descriptors and checked Zig allocations are
measured; WebKit helper-thread counts allow warm-up variation. Windows/Linux
runtime validation of these new behaviors remains pending. Concurrent macOS
windows, idle-client multiplexing, native dialogs, and an externally owned Cocoa
event loop are outside this pass.
