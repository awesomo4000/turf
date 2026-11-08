// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025-2026 awesomo4000

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>
#import "automation.h"
#include <stdatomic.h>

// Declare the Zig callback functions
extern void onWindowEvent(int x, int y, int width, int height);
extern void onWindowGeometryEvent(int x, int y, int width, int height);
extern void onJavaScriptMessage(const char* message);
extern void onDocumentChanging(void);
static atomic_ullong documentGeneration = 1;
static atomic_ullong pendingMessageGeneration = 0;
static void documentChanging(void) {
    atomic_fetch_add(&documentGeneration, 1);
    onDocumentChanging();
}
bool NSIsMainThread(void) { return NSThread.isMainThread; }
unsigned long long NSMessageGeneration(void) { return atomic_load(&documentGeneration); }
bool NSMessagesReady(void) { return atomic_load(&pendingMessageGeneration) == 0; }

// Only the event loop owned by Turf should return through Window.run().
static BOOL turfRunActive = NO;

// AppDelegate is the main app delegate that handles the app lifecycle
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (!turfRunActive) return NSTerminateNow;
    TurfAutomationStop();
    [sender stop:nil];
    // Wake AppKit if the stop request came from a dispatch callback.
    [sender postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
        context:nil subtype:0 data1:0 data2:0] atStart:YES];
    return NSTerminateCancel;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    TurfAutomationStop();
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end

// Forward declarations
//
// WebView is the main webview that displays the HTML content
// openPanel is the open file dialog
// isShowingFileDialog is a flag to track if the file dialog is showing
//
static WKWebView *webView = nil;
static NSWindow *turfWindow = nil;
static AppDelegate *turfAppDelegate = nil;
static BOOL windowNoFocus = NO;
static BOOL windowStartHidden = NO;
static BOOL windowHiddenTitlebar = NO;
static NSOpenPanel *openPanel = nil;
static BOOL isShowingFileDialog = NO;

// Only an actual, recent mouse press in this window may start a native drag.
static NSEvent *windowDragMouseDown;
static unsigned long long windowDragGeneration;

// Custom WebView class to suppress beeps
@interface TurfWebView : WKWebView
@property (nonatomic) CGFloat currentZoomLevel;
- (void)applyZoom;
@end

//
// WebViewDelegate is the delegate that handles the webview messages
//
@interface WebViewDelegate : NSObject <WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate>
@end

@implementation WebViewDelegate
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqual:@"__turf_drag__"]) {
        NSEvent *event = windowDragMouseDown;
        if (message.frameInfo.mainFrame && event && event.window == turfWindow &&
            windowHiddenTitlebar &&
            windowDragGeneration == NSMessageGeneration() && (NSEvent.pressedMouseButtons & 1) &&
            NSProcessInfo.processInfo.systemUptime - event.timestamp < 0.5) {
            windowDragMouseDown = nil;
            [turfWindow performWindowDragWithEvent:event];
        }
        return;
    }
    NSString *messageBody = [NSString stringWithFormat:@"%@", message.body];
    NSDictionary *jsonDict = nil;
    if ([messageBody isKindOfClass:[NSString class]]) {
        jsonDict = [NSJSONSerialization 
        JSONObjectWithData:[messageBody dataUsingEncoding:NSUTF8StringEncoding]
        options:0
        error:nil];
    } else {
        jsonDict = message.body;
    }
    onJavaScriptMessage([messageBody UTF8String]);
}

// Suppress beeps for unhandled key events
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    completionHandler();
}

- (void)webView:(WKWebView *)view didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    TurfAutomationNavigationFinished(navigation, error);
}
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    TurfAutomationNavigationFinished(navigation, error);
}

- (void)webView:(WKWebView *)view didStartProvisionalNavigation:(WKNavigation *)navigation {
    documentChanging();
}

// Navigation delegate methods to persist zoom across reloads
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    TurfAutomationNavigationFinished(navigation, nil);
    // Reapply zoom level after page load
    if ([webView isKindOfClass:[TurfWebView class]]) {
        TurfWebView *turfWebView = (TurfWebView *)webView;
        if (turfWebView.currentZoomLevel != 0 && turfWebView.currentZoomLevel != 1.0) {
            // Small delay to ensure DOM is ready
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [turfWebView applyZoom];
            });
        }
    }
}
@end

//
// WindowDelegate is the delegate that handles the window events
//

@implementation TurfWebView
// Handle application shortcuts and preserve WebKit's handling result.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // First, let the menu system handle standard shortcuts like Cmd+Q
    if ([[NSApp mainMenu] performKeyEquivalent:event]) {
        return YES;
    }
    
    // Handle zoom shortcuts
    if ([event modifierFlags] & NSEventModifierFlagCommand) {
        NSString *chars = [event charactersIgnoringModifiers];
        
        // Cmd+= (zoom in)
        if ([chars isEqualToString:@"="] || [chars isEqualToString:@"+"]) {
            [self handleZoomIn];
            return YES;
        }
        // Cmd+- (zoom out)
        else if ([chars isEqualToString:@"-"]) {
            [self handleZoomOut];
            return YES;
        }
        // Cmd+0 (reset zoom)
        else if ([chars isEqualToString:@"0"]) {
            [self handleZoomReset];
            return YES;
        }
    }
    
    // Only consume shortcuts WebKit actually handled. Unhandled keys must be
    // allowed to reach the first responder, including terminal applications.
    return [super performKeyEquivalent:event];
}

// Override noResponderFor to prevent beeps
- (void)noResponderFor:(SEL)eventSelector {
    // Do nothing - prevents the beep
    // Default implementation calls NSBeep()
}

// Override keyDown to handle keys properly
- (void)keyDown:(NSEvent *)event {
    // Always call super to let the WebView handle the event
    [super keyDown:event];
    
    // The noResponderFor: override will prevent any beeping
}

// Ensure we can always become first responder
- (BOOL)acceptsFirstResponder {
    return YES;
}

// Zoom handling methods
- (void)handleZoomIn {
    if (self.currentZoomLevel == 0) {
        self.currentZoomLevel = 1.0;
    }
    self.currentZoomLevel *= 1.1; // Increase by 10%
    [self applyZoom];
}

- (void)handleZoomOut {
    if (self.currentZoomLevel == 0) {
        self.currentZoomLevel = 1.0;
    }
    self.currentZoomLevel /= 1.1; // Decrease by 10%
    [self applyZoom];
}

- (void)handleZoomReset {
    self.currentZoomLevel = 1.0;
    [self applyZoom];
}

- (void)applyZoom {
    // Use CSS zoom property for proper reflow
    NSString *script = [NSString stringWithFormat:@"document.body.style.zoom = '%f'", self.currentZoomLevel];
    [self evaluateJavaScript:script completionHandler:nil];
}
@end

// Keep ordinary typing out of the shortcut dispatch path.
@interface TurfWindow : NSWindow
@property (nonatomic) BOOL cmdDragEnabled;
@end

@implementation TurfWindow
// Borderless windows still participate in normal keyboard focus and app menus.
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeLeftMouseDown) {
        if (self.cmdDragEnabled && (event.modifierFlags & NSEventModifierFlagCommand)) {
            windowDragMouseDown = nil;
            [self performWindowDragWithEvent:event];
            return;
        }
        windowDragMouseDown = event;
        windowDragGeneration = NSMessageGeneration();
    } else if (event.type == NSEventTypeLeftMouseUp) {
        windowDragMouseDown = nil;
    }
    [super sendEvent:event];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Ordinary typing belongs to keyDown, not WKWebView's shortcut path.
    // That path can consume printable keys such as unmodified lowercase e.
    NSEventModifierFlags shortcuts = NSEventModifierFlagCommand |
        NSEventModifierFlagControl | NSEventModifierFlagOption;
    if (!(event.modifierFlags & shortcuts)) return NO;

    return [super performKeyEquivalent:event];
}
@end

bool NSCmdDragEnabled(void) { return [(TurfWindow *)turfWindow cmdDragEnabled]; }

@interface WindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation WindowDelegate
- (void)windowDidMove:(NSNotification *)notification {
    NSWindow *window = [notification object];
    NSRect frame = [window frame];
    NSScreen *screen = [NSScreen mainScreen];
    CGFloat screenHeight = screen.frame.size.height;
    CGFloat topLeftY = screenHeight - frame.origin.y - frame.size.height;
    // NSLog(@"windowDidMove: %d, %d, %d, %d", (int)frame.origin.x, (int)topLeftY, 
    //       (int)frame.size.width, (int)frame.size.height);
    onWindowGeometryEvent((int)frame.origin.x, (int)topLeftY, 
                  (int)frame.size.width, (int)frame.size.height);
}

- (void)windowDidResize:(NSNotification *)notification {
    NSWindow *window = [notification object];
    NSRect frame = [window frame];
    NSScreen *screen = [NSScreen mainScreen];
    CGFloat screenHeight = screen.frame.size.height;
    CGFloat topLeftY = screenHeight - frame.origin.y - frame.size.height;
    // NSLog(@"windowDidResize: %d, %d, %d, %d", (int)frame.origin.x, (int)topLeftY, 
    //       (int)frame.size.width, (int)frame.size.height);
    onWindowGeometryEvent((int)frame.origin.x, (int)topLeftY,
                    (int)frame.size.width, (int)frame.size.height);
}

// Ensure WebView keeps focus
- (void)windowDidBecomeKey:(NSNotification *)notification {
    NSWindow *window = [notification object];
    if (webView && [webView window] == window) {
        [window makeFirstResponder:webView];
    }
}
@end

//
// windowDelegate is the delegate that handles the window events
// webViewDelegate is the delegate that handles the webview messages
//
static WindowDelegate *windowDelegate = nil;
static WebViewDelegate *webViewDelegate = nil;

//
// setupMainMenu sets up the main menu
//
static void setupMainMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];
    
    NSMenu *appMenu = [[NSMenu alloc] init];
    NSMenuItem *quitMenuItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                action:@selector(terminate:)
                keyEquivalent:@"q"];
    [appMenu addItem:quitMenuItem];
    [appMenuItem setSubmenu:appMenu];
    
    // Standard edit commands use the responder chain, including WKWebView's editor.
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:NSMenuItem.separatorItem];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];
    [NSApp setMainMenu:mainMenu];

}

@interface NSApplication (Inspector)
- (void)showWebInspector;
@end


bool TurfApplicationLoad(void) {
    @autoreleasepool {
        if (turfAppDelegate) return true;
        // Suppress WebKit console warnings
        // setenv("WKWebViewDisableRemoteViewDisplayLinkWarnings", "1", 1);
        // setenv("OS_ACTIVITY_MODE", "disable", 1);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Set up app delegate
        turfAppDelegate = [[AppDelegate alloc] init];
        [NSApp setDelegate:turfAppDelegate];
        setupMainMenu();
        windowDelegate = [[WindowDelegate alloc] init];
        webViewDelegate = [[WebViewDelegate alloc] init];

        // Initialize the open panel
        openPanel = [NSOpenPanel openPanel];
        [openPanel setCanChooseFiles:YES];
        [openPanel setCanChooseDirectories:NO];
        [openPanel setAllowsMultipleSelection:NO];

        return true;
    }
}

void NSLoadURL(const char* url) {
    @autoreleasepool {
        documentChanging();
        if (webView != nil) {
            NSURL *nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
            NSURLRequest *request = [NSURLRequest requestWithURL:nsurl];
            [webView loadRequest:request];
        }
    }
}

void NSLoadLocalFile(const char* path) {
    @autoreleasepool {
        documentChanging();
        if (webView != nil) {
            NSString *nsPath = [NSString stringWithUTF8String:path];
            NSURL *fileURL = [NSURL fileURLWithPath:nsPath];
            [webView loadFileURL:fileURL
                allowingReadAccessToURL:[fileURL URLByDeletingLastPathComponent]];
        } else {
            NSLog(@"WebView is nil when trying to load file: %s", path);
        }

    }
}


void NSLoadString(const char* html_content) {
    @autoreleasepool {
        documentChanging();
        if (webView != nil) {
            NSString *htmlString = [NSString stringWithUTF8String:html_content];
            [webView loadHTMLString:htmlString baseURL:nil];
        }
    }
}

void NSCreateWindow(int x, int y, int w, int h,
                    const char* title, const char* jsInject, bool no_focus, bool start_hidden, bool hidden_titlebar,
                    bool hidden_controls, bool square_corners, bool cmd_drag) {
    @autoreleasepool {
        atomic_fetch_add(&documentGeneration, 1);
        atomic_store(&pendingMessageGeneration, 0);
        windowNoFocus = no_focus;
        windowStartHidden = start_hidden;
        hidden_titlebar = hidden_titlebar || square_corners;
        hidden_controls = hidden_controls || square_corners;
        windowHiddenTitlebar = hidden_titlebar;
        NSRect frame = NSMakeRect(x, y, w, h);
        TurfWindow* window = [[TurfWindow alloc]
            initWithContentRect:frame
            styleMask:(square_corners ? NSWindowStyleMaskBorderless : NSWindowStyleMaskTitled)|
                      NSWindowStyleMaskClosable|
                      NSWindowStyleMaskMiniaturizable|
                      NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered
            defer:NO];
        window.releasedWhenClosed = NO;
        window.cmdDragEnabled = cmd_drag;
        turfWindow = window;
        if (hidden_controls) {
            for (NSNumber *kind in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)])
                [window standardWindowButton:kind.unsignedIntegerValue].hidden = YES;
        }
        if (hidden_titlebar && !square_corners) {
            window.styleMask |= NSWindowStyleMaskFullSizeContentView;
            window.titleVisibility = NSWindowTitleHidden;
            window.titlebarAppearsTransparent = YES;
            window.movableByWindowBackground = NO;
            [window setContentSize:NSMakeSize(w, h)];
        }

        // Create a parent view. Webview uses this to avoid the unknown
        // subview traceback message. Add the subview to the window's content view.
        NSView *parentView = [[NSView alloc] initWithFrame:window.contentView.bounds];
        [parentView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [window.contentView addSubview:parentView];

        // Create and configure WebView
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];

        // Enable developer extras directly in configuration
        config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
        [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];


        //
        // Inject a script that will be executed when the page is loaded.
        // This script will be used to send messages to the webview.
        //
        NSString *scriptSource = [NSString stringWithFormat:@"const turfHiddenTitlebar = %@;\n%@",
            hidden_titlebar ? @"true" : @"false", [NSString stringWithUTF8String:jsInject]];
        //
        // The script will be executed when the page is loaded.
        WKUserScript *script = [[WKUserScript alloc]
            initWithSource:scriptSource
            injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
            forMainFrameOnly:YES];

        WKUserContentController *userContentController =
                                          [[WKUserContentController alloc] init];
        [userContentController addUserScript:script];

        //
        // Allow JavaScript code can send messages to the webview by calling
        // window.webkit.messageHandlers.__turf__.postMessage(message);
        //
        [userContentController
            addScriptMessageHandler:webViewDelegate name:@"__turf__"];

        if (hidden_titlebar) [userContentController addScriptMessageHandler:webViewDelegate name:@"__turf_drag__"];
        config.userContentController = userContentController;

        // init the webview with the configuration
        NSRect webFrame = parentView.bounds;
        webView = [[TurfWebView alloc]
                          initWithFrame:webFrame configuration:config];

        // Initialize zoom level
        ((TurfWebView *)webView).currentZoomLevel = 1.0;

        // Set the UI delegate to handle key events
        webView.UIDelegate = webViewDelegate;

        // Set the navigation delegate to handle page loads
        webView.navigationDelegate = webViewDelegate;

        // Enable zoom
        [webView setAllowsMagnification:YES];
        [webView setMagnification:1.0];

        // Enable mouse wheel zooming with Command key
        NSScrollView *scrollView = [webView enclosingScrollView];
        [scrollView setAllowsMagnification:YES];
        [scrollView setMagnification:1.0];

        // Enable layer backing for the WebView
        [webView setWantsLayer:YES];
        webView.layer.contentsScale = window.backingScaleFactor;

        // Set autoresizing mask to fill parent view
        [webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        // Fix display layer issue and enable inspector
        // [webView fixDisplayLayerAndEnableInspector];

        [parentView addSubview:webView];


        // Make sure the WebView has focus
        [window makeFirstResponder:webView];

        // Load a default URL
        NSURL *url = [NSURL URLWithString:@"about:blank"];
        NSURLRequest *request = [NSURLRequest requestWithURL:url];
        [webView loadRequest:request];

        // Set webView as the window's content view
        [window setContentView:parentView];
        [window setTitle:[NSString stringWithUTF8String:title]];
        [window setDelegate:windowDelegate];
        [window center];
    }
}

void NSSetWindowPosition(int x, int y) {
    @autoreleasepool {
        CGFloat desktopTop = NSMaxY(NSScreen.screens.firstObject.frame);
        [webView.window setFrameOrigin:NSMakePoint(x, desktopTop - y - webView.window.frame.size.height)];
    }
}

void NSShowWindow(void) {
    @autoreleasepool {
        if (!webView.window || webView.window.visible) return;
        if (windowNoFocus || TurfAutomationIsBackground()) {
            // Show above other windows without taking keyboard focus. Ordering behind
            // them can make WebKit report hidden and suspend animation frames.
            [webView.window orderFrontRegardless];
        } else {
            [webView.window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
        }
    }
}

void NSRunApplication(void) {
    @autoreleasepool {
        if (!windowStartHidden) NSShowWindow();
        turfRunActive = YES;
        [NSApp run];
        turfRunActive = NO;
    }
}

void NSDestroyWindow(void) {
    windowDragMouseDown = nil;
    @autoreleasepool {
        atomic_fetch_add(&documentGeneration, 1);
        TurfAutomationStop();
        [webView stopLoading];
        [webView.configuration.userContentController removeScriptMessageHandlerForName:@"__turf__"];
        webView.navigationDelegate = nil;
        webView.UIDelegate = nil;
        NSWindow *window = turfWindow;
        window.delegate = nil;
        [window close];
        window.contentView = nil;
        webView = nil;
        turfWindow = nil;
    }
}

void NSEvaluateJavaScript(const char* script) {
    @autoreleasepool {
        // Copy before a possible dispatch and keep all WebKit access on the main
        // thread. Teardown may clear webView before queued work runs.
        NSString *jsString = [NSString stringWithUTF8String:script];
        if (!jsString) return;
        WKWebView *target = webView;
        void (^evaluate)(void) = ^{
            // A late delivery from the old pump must not enter a replacement window.
            if (webView != target) return;
            [target evaluateJavaScript:jsString completionHandler:^(id result, NSError *error) {
                if (error) NSLog(@"Error evaluating JavaScript: %@", error);
            }];
        };
        if ([NSThread isMainThread]) evaluate();
        else dispatch_async(dispatch_get_main_queue(), evaluate);
    }
}

// Only one batch may be waiting on the main queue/WebKit at a time. The native
// queue supplies backpressure while a handler is slow, even on a hidden page.
void NSDeliverMessages(const char *script, unsigned long long generation) {
    @autoreleasepool {
        if (generation != atomic_load(&documentGeneration)) return;
        unsigned long long empty = 0;
        if (!atomic_compare_exchange_strong(&pendingMessageGeneration, &empty, generation)) return;
        NSString *source = [NSString stringWithUTF8String:script];
        WKWebView *target = webView;
        void (^finished)(void) = ^{
            unsigned long long expected = generation;
            atomic_compare_exchange_strong(&pendingMessageGeneration, &expected, 0);
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!source || target != webView || generation != atomic_load(&documentGeneration)) {
                finished(); return;
            }
            [target evaluateJavaScript:source completionHandler:^(id value, NSError *error) { finished(); }];
        });
    }
}

void NSShowOpenFileDialog(void) {
    @autoreleasepool {
        NSLog(@"Showing open file dialog");
        if (isShowingFileDialog) {
            NSLog(@"File dialog already showing");
            return;
        }

        if (openPanel == nil || webView == nil) {
            NSLog(@"Panel or webView is nil");
            return;
        }

        NSWindow *window = [webView window];
        if (window == nil) {
            NSLog(@"Window is nil");
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            isShowingFileDialog = YES;
            [openPanel beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
                isShowingFileDialog = NO;
                if (result == NSModalResponseOK) {
                    NSURL *selectedFile = openPanel.URLs.firstObject;
                    NSString *path = selectedFile.path;
                    NSLog(@"Selected file: %@", path);

                    // Create a JSON message with the file path
                    NSString *jsonMsg =
                    [NSString stringWithFormat:
                    @"{\"type\":\"native_file_selected\",\"path\":\"%@\"}", path];
                    onJavaScriptMessage([jsonMsg UTF8String]);
                }
            }];
        });
    }
}

int NSStartAutomation(const char *path, bool background) {
    @autoreleasepool {
        return TurfAutomationStart(webView, path, background);
    }
}
void NSStopAutomation(void) {
    @autoreleasepool {
        TurfAutomationStop();
    }
}
