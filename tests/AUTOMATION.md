# Local automation tests

Build Turf with the repository's Zig toolchain, then run:

```bash
zig build
zig build test
TURF_TEST_SCREEN='your display name' python3 tests/automation_diagnostics_macos.py
```

The display selector must match exactly one screen name (case insensitive).
The suite launches hidden with `--no-focus`, places a small window at the selected
display's lower-third center, then shows it. A passive native observer checks that
Turf never becomes the foreground application. Do not interact with that test
window during the run. Fixtures use disposable temporary directories and a
loopback HTTP server on an automatically allocated port; no external site is
required. The process, observer, server, and temporary files are cleaned up.

The macOS runner and portable runners use the same `diagnostics_contract.py` assertions.
The suite checks evaluation results and promises, thrown primitives and objects,
syntax errors, rejected promises, serialization failures, native fallback,
CLI failure status, startup console capture, uncaught errors, frame metadata,
file-origin error redaction, independent cursors, pagination, bounded previews,
page/native overflow, navigation, invalid requests, stop/restart and script
restoration. It also exercises native input, large chunked grab, atomic failure
cleanup, PNG geometry, timeout with late completion, and recovery. The timeout
case deliberately takes just over 30 seconds. Assertions poll observable
conditions with deadlines; they do not assume application readiness from a load
notification or a fixed sleep.

# Zig unit tests

`zig build test` now exercises the native-to-JavaScript queue and public
`Window.sendMessage` without opening a window. Tests cover empty messages, FIFO,
copied buffers, ownership after dequeue, separate window/queue allocators,
retry after a failed dequeue, and JSON escaping of message names and payloads.
Allocation-failure tests fail each allocation in turn, including queue growth,
and check for leaks. These are behavioral checks, not a whole-library coverage
claim. The test runner currently reports fifteen tests, including one import-only
block that discovers the shared queue tests.

Queue ownership matters for embedders: `push` takes a sentinel-terminated JSON
buffer allocated with the queue allocator, and transfers ownership only on
success. `pushCopy` copies its inputs. `popAll` transfers the list and its
message buffers to the caller, who must free all of them with the queue
allocator. `Window.sendMessage` serializes a Zig value and copies it into the
queue, so the window and queue can use different allocators. Keep the queue
and its allocator alive while the window's message pump is using them.

# Embedder lifecycle and fuzzing

Build and run the macOS fixture independently of the CLI:

```bash
zig build test-embedder-build
TURF_TEST_SCREEN='your display name' python3 tests/embedder_lifecycle_macos.py
```

The fixture imports the public Turf module. It stops/restarts automation before
running, closes a never-shown window and an unfocused visible window, and checks
that `run()` returns before window and caller-owned queue cleanup. A checked Zig
allocator fails on leaks. The test delivers 200 native replies before closing
while more messages are being produced. Hidden-page delivery is checked without
manually draining JavaScript queues or relying on page timers. It also checks socket
removal and observes foreground application changes.

On macOS, terminating the event loop owned by `Window.run()` now returns to its
caller instead of exiting the process. The message worker stops and joins before
return. Call window lifecycle APIs on the main thread and deinitialize the window
before its queue/allocator. This fixture does not establish support for concurrent
windows or integration into an independently managed native application event loop.

The broader failure-mode suite keeps every window hidden:

```bash
python3 tests/embedder_failure_modes_macos.py
```

It runs twelve create/run/close/deinit cycles in one process, checking native window,
thread, and descriptor counts after warm-up. It closes during pending evaluation,
navigation, diagnostics activity, and a large response, then starts a replacement
window in the same process to expose stale callbacks. It also checks partial
request/response disconnects, write-half-closed connections, prompt recovery after
abandoned evaluation/navigation, hidden-page overload, a throwing message handler,
old-document message rejection, wrong-thread initialization, and direct public
position/evaluation/file-loading APIs. File fixtures include spaces, `#`, `%`, `?`,
and Unicode. Echo/custom responses include quotes, control characters, and Unicode;
reversed random bounds are ignored and equal bounds return the exact value.

The fixture's separate main-thread control timer simulates the embedding app
closing or navigating while its automation connection is busy. It is linked only
into the test executable. These checks do not claim that a second automation
connection can interrupt a connected client; the server still serves one client
at a time. Disconnecting abandons the response wait but may leave JavaScript or
navigation running. A half-close of the request side still permits a response.

The default native queue accepts at most 1,024 messages and 8 MiB of names/payloads,
including payload terminators. `MessageQueue.initWithLimits` customizes those
bounds; a full queue returns `error.QueueFull` before copying new input and retains
caller ownership for failed `push` calls. A dequeue frees capacity. The macOS pump
allows one additional batch in flight, delivers directly to handlers even when
hidden, and catches handler exceptions separately, even if error logging throws.
Payloads are parsed as JSON so `__proto__` remains an ordinary data key. This bounds Turf-owned pending
delivery, not data retained by application handlers or WebKit's total memory.
Linux/Windows have the shared native-queue limit but their downstream delivery
paths have not yet been given this macOS bound/navigation policy.

On macOS, initiating navigation discards undelivered old-document messages. A
message accepted by `sendMessage` is queued, not acknowledged as delivered. Wait
for the target document to be ready before sending it application messages.
`Window` lifecycle, loading, and evaluation APIs belong on the main thread.
Initialization, position, and automation-start return `WrongThread`; void native
entry points assert this contract in safety-enabled builds. `sendMessage` supports
concurrent producers if its window allocator is thread-safe. The queue allocator
must support concurrent allocation/free by producers and the consumer. Stop/join
application producers before deinitializing the window, then deinitialize its
caller-owned queue and allocators. The macOS pump uses its own temporary allocator.

The fast, GUI-free Zig fuzz target exercises byte-preserving queue operations and
UTF-8 JSON message round trips:

```bash
zig build fuzz --fuzz=100000 --summary all
zig build test
```

The `--fuzz` limit is an execution count, not a duration; the runner may overshoot
it slightly. Zig retains coverage/corpus progress in the build cache. The ordinary
test command runs the supplied seed corpus without an open-ended fuzz campaign.
Keep allocation-failure tests too: fuzzing input bytes does not replace systematic
out-of-memory testing. The fuzz coverage report describes its instrumented test
binary, including dependencies, not Turf's whole-project coverage.

Exercise the actual macOS automation parser and socket framing with bounded,
reproducible mutations:

```bash
python3 tests/fuzz_automation_macos.py --seed 20261103 --cases 2000
python3 tests/fuzz_automation_macos.py --replay zig-out/fuzz-failures/automation-SEED-INDEX.json
```

This runner uses the hidden embedder fixture and disposable `/tmp` sockets. It
sends harmless info/unknown requests, invalid evaluation/navigation parameter
types, malformed JSON/UTF-8, fragmented writes, and request-size boundary cases.
Each request has a timeout and a following health check. Every run also includes a
fixed regression corpus. Failures save exact wire bytes, seed/index, expected code,
and host logs. Arbitrary replay files are sent verbatim; use artifacts generated
by this runner. Protocol mutations are not coverage-guided Objective-C fuzzing.

# Supervised agent trials

`agent_tasks.json` is the supervisor's manifest. Do not give it or fixture source
to the agent. The agent gets only the prepared prompt, explicit socket, and
`python3 tools/turf-client.py --help`. No discovery or gateway is required.

For a trial, launch a separate test Turf with `--start-hidden --no-focus` and an
explicit socket in a private temporary directory. Use `screens`, `resize`, and
`move` to select the intended display and location before `show`. Serve
`tests/fixtures/automation` over loopback HTTP using an available local port:

```bash
python3 -m http.server 8000 --bind 127.0.0.1 --directory tests/fixtures/automation
python3 tests/agent_tasks.py prepare --socket "$socket" --task condition-wait \
  --fixture-url http://127.0.0.1:8000/diagnostics.html
```

Available tasks are error-detail, frame-context, condition-wait,
console-diagnosis, cursor-replay, and bounded-console. Run each trial against
fresh state (prefer a fresh process), record the full command/output transcript,
and save the agent's JSON answer. Verify it separately:

```bash
python3 tests/agent_tasks.py verify --socket "$socket" --task condition-wait \
  --answer /tmp/turf-trial/answer.json --transcript /tmp/turf-trial/transcript.jsonl
```

Verification checks expected answers and independent DOM state where applicable.
It deliberately reports `answerAndStatePassed`, not overall agent success.
A supervisor must review the transcript: an asserted boolean does not prove
cursor replay, overflow handling, or condition-based waiting. Record model and
version, reasoning effort, elapsed time, command count, help usage, source access,
target guesses, fixed sleeps, and recovery from errors. Compare multiple trials
and model capabilities with the same starting conditions. Fail source inspection
or unsupported claims even when the answer happens to match.

The automated suite tests the supervisor's prepare/verify interface, including
rejecting a correct answer with incorrect DOM state. Actual trials with different
agents remain a separate TODO; passing this suite does not establish CLI usability
across models. Frame targeting, connection concurrency, and gateway design remain deferred in
the root TODO.md.

## Linux and Windows

Build and run unit tests natively with Zig 0.17.0. Linux needs GTK4, WebKitGTK 6,
Xvfb, xauth, and dbus-run-session. Run diagnostics on a private X display:

```bash
python3 tests/automation_xvfb.py --diagnostics
python3 tests/automation_xvfb.py
python3 tests/linux_abi.py
```

On Windows, use an existing interactive desktop session for WebView2. From SSH,
the wrapper creates a temporary scheduled task in that session and removes it
when the test ends. No stored password or debugging port is used:

```powershell
./tests/automation_windows_session.ps1 -Binary ./zig-out/bin/turf.exe -Diagnostics
./tests/automation_windows_session.ps1 -Binary ./zig-out/bin/turf.exe -Protocol
./tests/automation_windows_session.ps1 -Binary ./zig-out/bin/turf.exe -Placement
```

The shared contract also checks cross-origin iframe logging and teardown, malformed
evaluation envelopes, and preservation of host scripts after stopping capture.
Native stack formats and file-origin error redaction differ across engines; tests
assert available metadata and messages without requiring identical engine text.

Windows/Linux use `src/automation/*.js`. After changing those sources, run
`python3 tools/automation-scripts.py` to regenerate the committed C header used by
Linux. `python3 tools/automation-scripts.py --check` verifies it is current. No
Python dependency is added to library builds or embedding applications.

## macOS Objective-C coverage

Run the existing diagnostics and deferred-display suites with coverage enabled:

```bash
TURF_TEST_SCREEN='your display name' python3 tools/coverage-macos.py
```

Use `--zig /path/to/zig` if Zig 0.17.0 is not on PATH. Each run creates a fresh
`zig-out/coverage-macos/run-*` directory containing an HTML report, `summary.txt`,
`coverage.json`, merged/raw profiles, the instrumented build, and `run.json` with
scope and toolchain information. The report path is printed when the run finishes.
A test or profile-processing failure makes the command fail instead of reporting
successful coverage. Keep the directory intact if you want to regenerate reports.

This measures `automation.m` and `cocoa_bridge.m` only. It excludes Zig, injected
JavaScript, system frameworks, and the browser engine. Line/function/branch
percentages describe the paths these integration suites execute, not the strength
of their assertions. A high percentage is not a correctness guarantee.

For this build only, Apple Clang compiles and links an instrumented bridge dylib
with its matching profiling runtime. Zig builds the host and exports its bridge
callbacks. This avoids invalid profile relocations observed when linking the
instrumented objects directly through the normal Zig link. Normal builds keep
their existing bridge compilation and do not acquire a dylib dependency.

The runner passes `-Dmacos-coverage-objects=<directory>` to the build and selects
the resulting host using `TURF_TEST_BINARY`. Both GUI suites retain the explicit
screen selection, lower-third placement, and focus checks. Profiles from previous
runs are never merged into a new result. No Xcode project is required; the Apple
command-line compiler and LLVM coverage tools must be installed.

## macOS Zig line coverage

With Zig 0.17.0 and `kcov` installed, run:

```bash
TURF_TEST_SCREEN='your display name' python3 tools/coverage-zig-macos.py
```

Use `--zig /path/to/zig` or `--kcov /path/to/kcov` to select tools explicitly.
The runner first compiles a small runtime-branch probe and checks two separate
kcov reports. The known hit and miss lines must exchange states when the input
changes. A failure aborts the run before any Turf coverage percentage is reported.
This was validated with kcov 43 on this project's macOS ARM64 development setup;
the probe should be rerun after compiler or coverage-tool upgrades.

After validation, the runner builds a separate Debug Turf binary and launches it
under kcov through the existing diagnostics and deferred-display suites. The
focus checks use the host PID returned by `info`, rather than the coverage
launcher's PID. Tests retain explicit screen selection and lower-third placement.

Each run gets a fresh `zig-out/coverage-zig-macos/run-*` directory with both probe
reports, the Turf HTML/Cobertura reports, `summary.txt`, and `run.json`. Only this
run's Turf processes accumulate into its report. The program is measured through
its debug line information; no source instrumentation or production build change
is required.

The denominator is **mapped, emitted runtime lines**, not every line of Zig in the
repository. Unused functions that Zig omits, comptime execution, and other platform
backends are outside this result. Source filters exclude the standard library,
dependencies, Objective-C, and headers. JavaScript is also outside this report.
These are line-coverage results, not branch coverage; do not interpret placeholder
branch fields in kcov's Cobertura XML as measured branches. Keep this report
separate from the LLVM Objective-C report rather than averaging their percentages.
