#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>

// Declare the Zig callback functions
extern void onWindowEvent(int x, int y, int width, int height);
extern void onJavaScriptMessage(const char* message);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end

// Forward declarations

static WKWebView *webView = nil;
static NSOpenPanel *openPanel = nil;
static BOOL isShowingFileDialog = NO;


@interface WebViewDelegate : NSObject <WKScriptMessageHandler>
@end

@implementation WebViewDelegate
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"zigCallback"]) {
        NSString *messageBody = [NSString stringWithFormat:@"%@", message.body];
        onJavaScriptMessage([messageBody UTF8String]);
    }
}
@end

@interface WindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation WindowDelegate
- (void)windowDidMove:(NSNotification *)notification {
    NSWindow *window = notification.object;
    NSRect frame = [window frame];
    NSScreen *screen = [NSScreen mainScreen];
    CGFloat screenHeight = screen.frame.size.height;
    CGFloat topLeftY = screenHeight - frame.origin.y - frame.size.height;
    
    onWindowEvent((int)frame.origin.x, (int)topLeftY, 
                  (int)frame.size.width, (int)frame.size.height);
}

- (void)windowDidResize:(NSNotification *)notification {
    NSWindow *window = notification.object;
    NSRect frame = [window frame];
    NSScreen *screen = [NSScreen mainScreen];
    CGFloat screenHeight = screen.frame.size.height;
    CGFloat topLeftY = screenHeight - frame.origin.y - frame.size.height;
    
    onWindowEvent((int)frame.origin.x, (int)topLeftY,
                    (int)frame.size.width, (int)frame.size.height);
}
@end

static WindowDelegate *windowDelegate = nil;
static WebViewDelegate *webViewDelegate = nil;

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

void NSCreateWindow(int x, int y, int w, int h, const char* title) {
    NSRect frame = NSMakeRect(x, y, w, h);
    NSWindow* window = [[NSWindow alloc] 
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

    WKUserContentController *userContentController = 
                                      [[WKUserContentController alloc] init];
    [userContentController 
                   addScriptMessageHandler:webViewDelegate name:@"zigCallback"];

    config.userContentController = userContentController;
    
    // init the webview with the configuration
    webView = [[WKWebView alloc] 
                      initWithFrame:parentView.bounds configuration:config];
    
    // Enable layer backing for the WebView
    [webView setWantsLayer:YES];
    webView.layer.contentsScale = window.backingScaleFactor;
    
    // Set autoresizing mask to fill parent view
    [webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // Fix display layer issue and enable inspector
    // [webView fixDisplayLayerAndEnableInspector];

    [parentView addSubview:webView];

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
