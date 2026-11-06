Yes, I'd much rather have that than `evaluate`. Today every update I send is JavaScript text, quoted twice to cross two layers (host page, then pane), written to a file and evaluated. A data channel would remove all of that and let any tool feed a page without knowing JavaScript.

What I'd want, based on what hurt in this session:

**1. `emit` sends data only, never code**
```sh
turfctl "$TURF_SOCKET" emit '{"topic":"burn","data":{...}}'
some-tool --json | turfctl "$TURF_SOCKET" emit burn -        # payload from stdin
```
On the page:
```js
companion.on('burn', (data, meta) => render(data));   // meta: {topic, seq, ts}
companion.on('*', ...)                                 // optional catch-all
```
Sending no code means no quoting problems and no injection risk. The page decides what to do with the data.

**2. Keep the last message per topic.** This matters most. A page that loads late, or reloads after `showHTML`, should get the current value as soon as it subscribes. I had to build a "hold the latest payload until the tab loads" queue by hand. Every rebuild then lost its state until the next feeder tick. Something like `emit --retain`, or retain by default for "state" topics.

**3. A streaming mode.** One process reads JSON lines and sends one message per line:
```sh
tail -f app.log | jq -c . | turfctl "$TURF_SOCKET" emit logs --lines
```
Without it, every update starts a new `turfctl` process, which is fine every 30 seconds but bad at high rates. For fast topics, an option to keep only the latest message per topic, so a busy page doesn't fall behind.

**4. Useful replies.** By default `emit` returns how many handlers received the message, so a tool can tell "page not listening" apart from "delivered". An optional `--reply` waits for the handler's return value. I used that as a check with `{ok, verdict}` coming back from the burn page.

**5. The reverse direction (optional, but it makes the loop complete).** The page calls `companion.emit('cmd', {...})` and a tool runs `turfctl "$TURF_SOCKET" listen cmd`, which prints JSON lines to stdout. Then a button in the pane could trigger `tokenburn snapshot` or start a job, with no server.

**6. Nested pages.** The tab bar loads each page as a separate page inside the pane, and I had to forward messages to the burn page myself. Either expose `companion.on` inside pages nested in the pane, or document one forwarding pattern.

With that in place, the live burn feed becomes:
```sh
while sleep 30; do tokenburn snapshot >/dev/null; tokenburn project --json; done \
  | turfctl "$TURF_SOCKET" emit burn --lines --retain
```
and the page just runs `companion.on('burn', render)`. `tokenburn project --json` doesn't exist today; my feeder computed the same figures in Python, but a CLI flag like that is the natural fit.

One limit stays: requests are capped at 1 MiB of JSON. That's plenty for state messages; bigger data would need to be split up or go a separate route.

I'd build #1 and #2 first. They cover most of what went wrong in this session, and #3 can come next.


