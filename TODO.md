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
- [ ] Add evaluation file/stdin input.
- [ ] Add bounded condition waits with useful timeout diagnostics and no automatic mutation retries.
- [ ] Add rectangular screenshots with capture geometry; keep pane selection in the embedding app.
- [ ] Add bounded chunked upload alongside grab.
- [ ] Allow independent macOS connections to progress without an idle connection monopolizing the server.
- [ ] Define explicit frame targeting and navigation identity; distinguish same-origin helpers from cross-origin automation.
- [ ] Design an optional gateway around explicitly supplied session endpoints, ownership, and operation grouping. No automatic global discovery requirement.
- [ ] Validate Windows/Linux error and diagnostic parity after the macOS contract settles.

Keep PTY input, terminal grids, pane layouts, persistent overlays, animation seek
hooks, and per-pane policy in the companion application. Preserve promise-aware
evaluation and explicit socket selection. A timeout does not imply cancellation.

Local GUI tests take their display choice from TURF_TEST_SCREEN, not committed
machine names. Use the selected display's lower-third center and preserve focus.
