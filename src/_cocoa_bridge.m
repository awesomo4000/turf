#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>

// Declare the Zig callback functions
extern void onWindowEvent(int x, int y, int width, int height);
extern void onWindowGeometryEvent(int x, int y, int width, int height);
extern void onJavaScriptMessage(const char* message);


// AppDelegate is the main app delegate that handles the app lifecycle
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
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
static NSOpenPanel *openPanel = nil;
static BOOL isShowingFileDialog = NO;

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

// Navigation delegate methods to persist zoom across reloads
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
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
// Override performKeyEquivalent to prevent beeps while allowing events through
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
    
    // For other command key combinations, let super handle it but return YES
    // to prevent beeping even if not handled
    [super performKeyEquivalent:event];
    
    // Always return YES for command keys to prevent beep
    if ([event modifierFlags] & NSEventModifierFlagCommand) {
        return YES;
    }
    
    return NO;
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

// Custom window class to suppress beeps
@interface TurfWindow : NSWindow
@end

@implementation TurfWindow
// Override performKeyEquivalent to prevent beeps for unhandled shortcuts
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Let the WebView handle all key events first
    if ([self.contentView isKindOfClass:[WKWebView class]]) {
        // Return YES to indicate we've handled it (even if we haven't)
        // This prevents the system beep
        return YES;
    }
    return [super performKeyEquivalent:event];
}
@end

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
    
    [NSApp setMainMenu:mainMenu];

}

@interface NSApplication (Inspector)
- (void)showWebInspector;
@end


bool NSApplicationLoad(void) {
    // Suppress WebKit console warnings
    // setenv("WKWebViewDisableRemoteViewDisplayLinkWarnings", "1", 1);
    // setenv("OS_ACTIVITY_MODE", "disable", 1);
    
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    
    // Set up app delegate
    AppDelegate *appDelegate = [[AppDelegate alloc] init];
    [NSApp setDelegate:appDelegate];
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

void NSLoadURL(const char* url) {
    if (webView != nil) {
        NSURL *nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
        NSURLRequest *request = [NSURLRequest requestWithURL:nsurl];
        [webView loadRequest:request];
    }
}

void NSLoadLocalFile(const char* path) {
    if (webView != nil) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSLog(@"Loading file from path: %@", nsPath);
        NSURL *fileURL = [NSURL fileURLWithPath:nsPath];
        NSLog(@"File URL: %@", fileURL);
        [webView loadFileURL:fileURL 
            allowingReadAccessToURL:[fileURL URLByDeletingLastPathComponent]];        
    } else {
        NSLog(@"WebView is nil when trying to load file: %s", path);
    }

}


void NSLoadString(const char* html_content) {
    if (webView != nil) {
        NSString *htmlString = [NSString stringWithUTF8String:html_content];
        [webView loadHTMLString:htmlString baseURL:nil];
    }
}

void NSCreateWindow(int x, int y, int w, int h, 
                    const char* title, const char* jsInject) {
    NSRect frame = NSMakeRect(x, y, w, h);
    TurfWindow* window = [[TurfWindow alloc] 
        initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled|
                  NSWindowStyleMaskClosable|
                  NSWindowStyleMaskMiniaturizable|
                  NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered
        defer:NO];
    
    // Create a parent view. Webview uses this to avoid the unknown
    // subview traceback message. Add the subview to the window's content view.
    NSView *parentView = [[NSView alloc] initWithFrame:frame];
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
    NSString *scriptSource = [NSString stringWithUTF8String:jsInject];
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

    config.userContentController = userContentController;
    
    // init the webview with the configuration
    webView = [[TurfWebView alloc] 
                      initWithFrame:parentView.bounds configuration:config];
    
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
    [window makeKeyAndOrderFront:nil];
    [window center];
}

void NSRunApplication(void) {
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
}

void NSEvaluateJavaScript(const char* script) {
    if (webView != nil) {
        NSString *jsString = [NSString stringWithUTF8String:script];
        [webView evaluateJavaScript:jsString completionHandler:^(id result, NSError *error) {
            if (error) {
                NSLog(@"Error evaluating JavaScript: %@", error);
            }
        }];
    }
}

void NSShowOpenFileDialog(void) {
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
