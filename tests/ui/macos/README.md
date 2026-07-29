# Testing Turf WKWebView UI Behavior on macOS

## What this sample tests

`reload_hover_test.m` is a compiled example for interaction bugs that cannot be covered by JavaScript alone. It creates a real `WKWebView`, loads embedded HTML through Turf's `turf://localhost/index.html` handler, opens WebKit's native context menu, selects Reload, and verifies that the reloaded page still handles native pointer state and bridge traffic.

The sample checks:

- Turf's stable application URL;
- no prior `WKBackForwardList` item on the first application document;
- normal Back history after a later application navigation;
- WebKit's native Reload and Inspect Element menu items;
- CSS `:hover` before and after Reload;
- `sessionStorage` across Reload;
- JavaScript-to-native messages;
- native-to-JavaScript evaluation;
- navigation-start callbacks.

It is sample and regression code, not a supported Turf testing API.

## Why DOM MouseEvent is insufficient

JavaScript can construct `MouseEvent` or call `dispatchEvent`, but those events are untrusted. Dispatching `mouseover` does not make WebKit's native hit-testing pipeline move its pointer, and it does not reliably establish CSS `:hover`.

Public `WKWebView` APIs are enough to load pages, evaluate JavaScript, and take view-local snapshots. They do not provide trusted offscreen mouse movement. A test for the pointer pipeline must inject an AppKit event through WebKit rather than merely invoke a DOM listener.

## Choosing native or DOM testing

The native harness and DOM interaction tests cover different failure classes. Keep both.

Use this harness for AppKit/WebKit event routing, native context menus, reload lifecycle, pointer state, and UI-thread liveness. The native Reload path exposed an earlier architecture defect that left the UI hung. A DOM `click()` or dispatched event would not have crossed that native path and could not have detected the failure.

For ordinary application behavior after native plumbing is known-good, prefer DOM interaction. DOM tests are the practical default for controls, rendering, state transitions, validation, and bridge messages. They are faster and less coupled to private WebKit SPI.

Neither approach requires foreground OS automation. Do not use `osascript`, activate the tested application, or move the workstation pointer from tests.

## Initial navigation history

Before creating the interaction host, the sample invokes Turf's real `NSApplicationLoad`, `NSCreateWindow`, and `NSLoadString` sequence. Test-only method overrides capture the production `TurfWindow` without presenting or centering it. After `turf://localhost/index.html` finishes loading, the sample requires `webView.backForwardList.backItem` to be `nil`.

Turf therefore does not manufacture an `about:blank` history entry before application content. WebKit naturally omits Back on the first screen, while applications that later create real history retain normal Back behavior. This check uses public `WKWebView` history APIs and does not depend on the private pointer SPI used by the interaction checks.

## How the offscreen host window works

The sample uses a borderless `NSWindow` located at `(-10000, -10000)`. Its test subclass reports itself as key within the process and posts the corresponding notification, matching the basic approach used by WebKit's own API tests.

The process uses `NSApplicationActivationPolicyProhibited`. It does not:

- activate the application;
- run `osascript` or other AppleScript;
- move or click the workstation pointer;
- post `CGEvent` input;
- capture the screen.

The window remains necessary because WebKit mouse and context-menu handling expects a real AppKit window and window number, even when the UI is not visible.

## Private WebKit test selectors and tags

The sample declares three selectors in a test-only Objective-C category:

```objective-c
- (void)_simulateMouseMove:(NSEvent *)event;
- (void)_doAfterProcessingAllPendingMouseEvents:(void (^)(void))completion;
- (NSMenu *)_activeMenu;
```

These are private WebKit test SPI, patterned after WebKit's `TestWKWebView` harness. They are runtime-checked before use. If the installed WebKit framework does not expose them, the sample prints `SKIP` and exits successfully.

The context-menu items are matched by WebCore's internal `ContextMenuItemTag` values (`Reload = 12`, `Inspect Element = 57`) rather than localized display text. Those values are private too and may change with WebKit. A five-second tracking deadline cancels the menu and fails the sample if the expected command is absent.

Never add these selectors or tags to Turf's production Cocoa bridge or ship code that depends on them. Apple may rename, renumber, or remove them in any macOS release.

## Native context-menu Reload

The sample sends right-mouse `NSEvent` objects to the offscreen host window. While WebKit tracks its menu, a timer reads `_activeMenu`, recursively locates Reload and Inspect Element, invokes Reload with `performActionForItemAtIndex`, and cancels menu tracking.

This exercises WebKit's actual menu action. It does not call `WKWebView.reload` directly and therefore catches bugs caused specifically by context-menu tracking and navigation.

## Running the sample

Turf currently declares Zig 0.16 as its minimum version. From the Turf root:

```bash
zig build test-ui-macos
```

A supported WebKit version prints:

```text
PASS: root history, native Reload, hover, state, Inspect Element, and bidirectional messaging
```

A WebKit version without the required test selectors prints an explicit `SKIP` message.

The target is intentionally separate from:

```bash
zig build test
```

The default step stays cross-platform and does not link private macOS test machinery.

## Adapting the pattern in another Zig project

For a project-specific regression:

1. Copy `reload_hover_test.m` into that project's test tree.
2. Keep its textual `#include` of the production Cocoa bridge. The unmodified sample depends on file-static bridge state, so the bridge must be included in this translation unit exactly once and must not also be compiled separately into the test executable.
3. Supply the native callback symbols expected by the bridge.
4. Replace the sample HTML and callback counters with the project's observable contract.
5. Add a macOS-only Zig build target that compiles Objective-C with `-fobjc-arc` and `-fblocks`, then links Cocoa and WebKit.
6. Keep the target explicit and keep all private selector declarations in the test translation unit.

If a project wants to link its bridge as a separate object instead, first refactor the sample to drive exported application boundaries rather than Turf's file-static `webView` and `appSchemeHandler` state.

For example, the relevant Zig build shape is:

```zig
const ui_test_module = b.createModule(.{
    .target = target,
    .optimize = optimize,
});
ui_test_module.addCSourceFile(.{
    .file = b.path("tests/ui/macos/reload_hover_test.m"),
    .flags = &.{ "-fobjc-arc", "-fblocks" },
});
ui_test_module.linkFramework("Cocoa", .{});
ui_test_module.linkFramework("WebKit", .{});
ui_test_module.link_libc = true;
```

Treat the copied code as an example to adapt, not as a stable API imported from Turf.

## Limitations and XCUITest alternative

The private selectors exercise WebKit's native test path, but the events are still synthetic and run in an offscreen process-local window. They do not prove every WindowServer, accessibility, focus, permission, or physical-device behavior.

For a true foreground pointer test, use XCUITest on a dedicated macOS GUI runner or virtual machine. `XCUIElement.rightClick()` and `XCUIElement.hover()` drive the real pointer pipeline, but they also focus and interact with the tested application. Do not run that style of test on an active workstation.
