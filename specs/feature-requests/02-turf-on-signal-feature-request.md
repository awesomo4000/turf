# Feature request: `turf.on(topic, handler, {signal})`

## Summary

Let `turf.on` take an optional `AbortSignal`, the same way `addEventListener`
does. Aborting the signal removes every listener registered with it.

```js
const c = new AbortController();
turf.on('build', render, {signal: c.signal});
turf.on('logs', append, {signal: c.signal});
c.abort();   // both listeners removed
```

## Motivation

A host page that shows replaceable content in a same-origin iframe lets the
iframe subscribe through `parent.turf.on(...)`. When the iframe document is
replaced, its listeners stay registered: they keep running against a detached
document and keep counting in `handlers`. (Observed: `handlers` stayed at 2
after the iframe was replaced.)

With a signal, the host keeps one `AbortController` per iframe document and
aborts it on replacement:

```js
// host page
let pane = new AbortController();
function replacePane(html) { pane.abort(); pane = new AbortController(); frame.srcdoc = html; }
window.paneOn = (topic, fn) => turf.on(topic, fn, {signal: pane.signal});

// iframe page
parent.paneOn('build', render);
```

Retained replay during `turf.on` still delivers the current value to each new
document, so the host needs no cache or forwarding of its own.

## Behavior

- `options` is optional; `turf.on(topic, handler)` is unchanged.
- `options.signal`, when present, must be an `AbortSignal`, otherwise
  `TypeError`.
- Already aborted: register nothing, replay nothing, return a no-op
  unsubscribe.
- On abort: remove the listener exactly as the returned unsubscribe does.
- Calling the returned unsubscribe also removes the abort listener from the
  signal, so long-lived signals do not accumulate closures.
- Abort during a dispatch takes effect for later dispatches; the current
  dispatch already took its listener snapshot.
- Same on every platform's `turf.js`.

## Tests

- Two listeners on one signal; `abort()`; next emit reports `handlers: 0`.
- Pre-aborted signal: no replay of retained values, `handlers` unchanged.
- Unsubscribe first, then `abort()`: no error, no double removal.
- Signal shared across topics and `*`: all removed together.
- Retained value replays to a listener registered with a fresh signal after a
  previous signal was aborted.
- Non-signal `options.signal` throws `TypeError`.

# Related: emit at high rates, and the page-to-tool direction

## Retained emits cost grows with retained data

Each retained emit or clear re-serializes every retained topic to check the
4 MiB limit, then rebuilds the replay script and reinstalls all user scripts
(`removeAllUserScripts` and re-add). That is fine every few seconds and costly
for a retained status topic updated many times a second.

- Keep a running byte total per topic instead of re-encoding the whole set.
- Build the replay script lazily, when a main-frame navigation starts, instead
  of on every retained emit.

Test: 1,000 retained emits to one topic at full speed stay flat in per-emit
time, and a reload afterwards replays only the latest value.

## Page-to-tool messages

`emit` covers tool to page. The page also needs to send to tools:

```js
turf.publish('cmd', {action: 'snapshot'});         // page side; turf.send is taken
```
```sh
turfctl "$TURF_SOCKET" listen cmd                   # prints JSON lines
```

- `turf.publish(topic, data)` sends JSON data from the page to automation
  clients. `turf.send` stays as it is: page to the embedding application.
- `listen TOPIC` (or `*`) prints one JSON line per message,
  `{"topic", "seq", "ts", "data"}`, until interrupted.
- Use case: a button in the page publishes `{action: 'snapshot'}`; a script
  in the shell waiting on `listen` runs the job. No server needed.

A blocking `listen` needs the server to serve more than one client at a time;
today one connected client holds the socket and every other command waits.
Either serve clients concurrently, or make `listen` a cursor-based poll
(`recv {"topic":"cmd","after":SEQ,"timeoutMs":N}`) that returns promptly, with
a bounded per-topic queue and an explicit dropped count.
