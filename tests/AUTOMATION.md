# Local macOS automation tests

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
across models. Windows/Linux parity, frame targeting, connection concurrency,
and gateway design remain deferred in the root TODO.md.
