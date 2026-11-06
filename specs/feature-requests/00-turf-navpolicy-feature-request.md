# Feature request: navigation policy for embedded webviews

## Summary

Give embedding applications a callback that approves, denies or takes over
every navigation in a Turf webview: main frame and subframes, from any cause.
With no callback set, Turf behaves exactly as it does today.

## Motivation

An application that ships its own UI as the main page needs that page to stay
loaded. Today several paths replace it:

| Cause | What happens now |
|---|---|
| Automation `navigate` | `automation.m` calls `loadRequest:` / `loadFileURL:` on the window's webview, replacing the page |
| File dropped on the window | WebKit navigates the main frame to the file |
| Page script sets `location` or `top.location` | Main frame navigates |
| Link clicked in the main page | Main frame navigates |

Reproduction: run an embedding app with automation enabled, then
`turfctl SOCKET navigate '{"url":"file:///tmp/x/page.html"}'`. The app's page is
gone; `evaluate` shows `location.href` is the file URL and the app's globals
are undefined.

The embedder has no hook today to refuse or redirect any of these.

## Proposed API

```zig
pub const NavigationRequest = struct {
    url: []const u8,
    main_frame: bool,
    cause: enum { initial, automation, link, script, reload, drop, other },
};

pub const NavigationDecision = enum {
    /// Proceed as today.
    allow,
    /// Cancel. Automation `navigate` replies with an error.
    deny,
    /// Cancel; the embedder carried out the request itself
    /// (for example by loading the URL into an iframe). Automation
    /// `navigate` replies with success.
    handled,
};

// WindowConfig
navigation_policy: ?*const fn (ctx: ?*anyopaque, request: NavigationRequest) NavigationDecision = null,
navigation_context: ?*anyopaque = null,
```

- Called synchronously on the main thread, before the navigation starts.
- `url` is valid only for the duration of the call.
- `initial` covers the embedder's own `loadString` / `loadURL` / `loadFile`, so
  a policy can allow its own page and deny everything after it.
- `automation` is set when the request came from the automation `navigate`
  method, so the embedder can treat it differently from user actions.

## Automation behavior

| Decision | `navigate` reply |
|---|---|
| `allow` | Unchanged: success after the navigation finishes |
| `deny` | Error, new code (e.g. `-32005`, "Navigation refused by host") |
| `handled` | Success immediately, `{"url": ..., "handled": true}` |

## Platform hooks

| Platform | Hook | Cancel with |
|---|---|---|
| macOS | `WKNavigationDelegate webView:decidePolicyForNavigationAction:decisionHandler:` (`targetFrame.isMainFrame`, `navigationType`) | `WKNavigationActionPolicyCancel` |
| Windows | WebView2 `NavigationStarting` (main frame) and `FrameNavigationStarting` (subframes) | `put_Cancel(TRUE)` |
| Linux | WebKitGTK `decide-policy` with `WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION` | `webkit_policy_decision_ignore` |

Mapping `cause`:
- macOS `navigationType`: `linkActivated` → `link`, `reload` → `reload`,
  `other` with a file URL and no pending load → `drop`, script-initiated →
  `script`.
- The automation server sets a flag around its own `load*` call so the
  delegate reports `automation`.
- Where a platform cannot distinguish a cause, report `other`.

## Tests

- Policy denies all main-frame navigations after `initial`: automation
  `navigate` returns the refusal error and the page's globals are intact.
- Policy returns `handled`: automation `navigate` reports success and the page
  is unchanged.
- Subframe navigation reaches the callback with `main_frame = false`.
- No policy set: existing navigation tests pass unchanged.
- File drop is reported as `drop` (or `other`) and can be denied.
