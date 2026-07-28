#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include "../../../src/platforms/macos/cocoa_bridge.m"

@interface WKWebView (TurfTestSPI)
- (void)_simulateMouseMove:(NSEvent *)event;
- (void)_doAfterProcessingAllPendingMouseEvents:(void (^)(void))completion;
- (NSMenu *)_activeMenu;
@end

static NSInteger navigationStartedCount = 0;
static NSInteger navigationFinishedCount = 0;
static NSInteger readyMessageCount = 0;
static NSInteger interactionMessageCount = 0;

void onWindowEvent(int x, int y, int width, int height) { }
void onWindowGeometryEvent(int x, int y, int width, int height) { }
void onWebViewNavigationStarted(unsigned long long generation) { navigationStartedCount += 1; }

void onJavaScriptMessage(const char *message) {
    NSString *body = [NSString stringWithUTF8String:message];
    if ([body containsString:@"probe.ready"])
        readyMessageCount += 1;
    if ([body containsString:@"probe.interaction"])
        interactionMessageCount += 1;
}

@interface TurfTestNavigationDelegate : WebViewDelegate
@end

@implementation TurfTestNavigationDelegate
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation {
    [super webView:view didFinishNavigation:navigation];
    navigationFinishedCount += 1;
}
@end

@interface TurfTestWindow : NSWindow
@property (nonatomic) BOOL testKeyWindow;
@end

@implementation TurfTestWindow
- (BOOL)isKeyWindow { return self.testKeyWindow; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)makeKeyWindow {
    self.testKeyWindow = YES;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSWindowDidBecomeKeyNotification
        object:self];
}
- (void)resignKeyWindow { self.testKeyWindow = NO; }
@end

static BOOL supportsWebKitTestSPI(WKWebView *view) {
    return [view respondsToSelector:@selector(_simulateMouseMove:)] &&
           [view respondsToSelector:@selector(_doAfterProcessingAllPendingMouseEvents:)] &&
           [view respondsToSelector:@selector(_activeMenu)];
}

static BOOL pumpUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

static id evaluateSynchronously(NSString *script, NSError **evaluationError) {
    __block BOOL done = NO;
    __block id result = nil;
    __block NSError *error = nil;
    [webView evaluateJavaScript:script completionHandler:^(id value, NSError *valueError) {
        result = value;
        error = valueError;
        done = YES;
    }];
    if (!pumpUntil(^BOOL { return done; }, 5.0)) {
        if (evaluationError) {
            *evaluationError = [NSError
                errorWithDomain:@"TurfReloadTest"
                code:1
                userInfo:@{NSLocalizedDescriptionKey: @"JavaScript evaluation timed out"}];
        }
        return nil;
    }
    if (evaluationError)
        *evaluationError = error;
    return result;
}

static void waitForPendingMouseEvents(void) {
    __block BOOL done = NO;
    [webView _doAfterProcessingAllPendingMouseEvents:^{ done = YES; }];
    pumpUntil(^BOOL { return done; }, 5.0);
}

static void moveMouse(NSWindow *hostWindow, NSPoint point) {
    NSEvent *event = [NSEvent
        mouseEventWithType:NSEventTypeMouseMoved
        location:point
        modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:hostWindow.windowNumber
        context:nil
        eventNumber:1
        clickCount:0
        pressure:0];
    [webView _simulateMouseMove:event];
    waitForPendingMouseEvents();
}

static NSMenuItem *findMenuItem(NSMenu *menu, NSString *title) {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.title isEqualToString:title])
            return item;
        if (item.submenu != nil) {
            NSMenuItem *nested = findMenuItem(item.submenu, title);
            if (nested != nil)
                return nested;
        }
    }
    return nil;
}

static BOOL selectReloadFromContextMenu(
    NSWindow *hostWindow,
    NSPoint point,
    BOOL *foundInspector
) {
    __block BOOL selectedReload = NO;
    __block BOOL sawInspector = NO;
    NSTimer *timer = [NSTimer
        timerWithTimeInterval:0.05
        repeats:YES
        block:^(NSTimer *activeTimer) {
            NSMenu *menu = [webView _activeMenu];
            if (menu == nil)
                return;
            sawInspector = findMenuItem(menu, @"Inspect Element") != nil;
            NSMenuItem *reloadItem = findMenuItem(menu, @"Reload");
            if (reloadItem == nil)
                return;
            NSMenu *itemMenu = reloadItem.menu;
            [itemMenu performActionForItemAtIndex:[itemMenu indexOfItem:reloadItem]];
            [menu cancelTracking];
            [activeTimer invalidate];
            selectedReload = YES;
        }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode];

    NSEvent *down = [NSEvent
        mouseEventWithType:NSEventTypeRightMouseDown
        location:point
        modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:hostWindow.windowNumber
        context:nil
        eventNumber:2
        clickCount:1
        pressure:0];
    NSEvent *up = [NSEvent
        mouseEventWithType:NSEventTypeRightMouseUp
        location:point
        modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:hostWindow.windowNumber
        context:nil
        eventNumber:3
        clickCount:1
        pressure:0];
    [hostWindow sendEvent:down];
    [hostWindow sendEvent:up];
    pumpUntil(^BOOL { return selectedReload; }, 5.0);
    if (foundInspector)
        *foundInspector = sawInspector;
    return selectedReload;
}

static int fail(NSString *message) {
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    return 1;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
        appSchemeHandler = [[TurfURLSchemeHandler alloc] init];
        [configuration setURLSchemeHandler:appSchemeHandler forURLScheme:@"turf"];
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = YES;
        [configuration.preferences setValue:@YES forKey:@"developerExtrasEnabled"];

        WKUserContentController *controller = [[WKUserContentController alloc] init];
        TurfTestNavigationDelegate *delegate = [[TurfTestNavigationDelegate alloc] init];
        [controller addScriptMessageHandler:delegate name:@"__turf__"];
        configuration.userContentController = controller;

        TurfTestWindow *hostWindow = [[TurfTestWindow alloc]
            initWithContentRect:NSMakeRect(-10000, -10000, 400, 300)
            styleMask:NSWindowStyleMaskBorderless
            backing:NSBackingStoreBuffered
            defer:NO];
        webView = [[TurfWebView alloc]
            initWithFrame:NSMakeRect(0, 0, 400, 300)
            configuration:configuration];
        webView.UIDelegate = delegate;
        webView.navigationDelegate = delegate;
        if ([webView respondsToSelector:@selector(setInspectable:)])
            webView.inspectable = YES;
        hostWindow.contentView = webView;
        [hostWindow makeKeyAndOrderFront:nil];

        if (!supportsWebKitTestSPI(webView)) {
            fprintf(stdout,
                "SKIP: installed WebKit does not expose the test selectors used by this sample\n");
            return 0;
        }

        const char *html =
            "<!doctype html><meta charset='utf-8'>"
            "<style>body{margin:0}#probe{position:absolute;left:50px;top:50px;width:100px;height:50px;background:rgb(255,0,0)}#probe:hover{background:rgb(0,128,0)}</style>"
            "<button id='probe'>probe</button>"
            "<script>"
            "const loads=Number(sessionStorage.getItem('loads')||0)+1;"
            "sessionStorage.setItem('loads',String(loads));"
            "window.webkit.messageHandlers.__turf__.postMessage(JSON.stringify({type:'probe.ready',loads}));"
            "</script>";
        NSLoadString(html);

        if (!pumpUntil(^BOOL {
            return navigationFinishedCount >= 1 && readyMessageCount >= 1;
        }, 5.0))
            return fail(@"initial turf:// page did not finish and message native");

        NSError *error = nil;
        NSString *initialURL = evaluateSynchronously(@"location.href", &error);
        if (error != nil || ![initialURL isEqualToString:@"turf://localhost/index.html"])
            return fail(@"initial page did not use the stable Turf URL");

        moveMouse(hostWindow, NSMakePoint(100, 225));
        NSNumber *initialHover = evaluateSynchronously(
            @"document.querySelector('#probe').matches(':hover')",
            &error);
        if (error != nil || !initialHover.boolValue)
            return fail(@"offscreen mouse harness could not establish CSS hover before Reload");
        moveMouse(hostWindow, NSMakePoint(300, 250));

        BOOL foundInspector = NO;
        if (!selectReloadFromContextMenu(
            hostWindow,
            NSMakePoint(250, 150),
            &foundInspector))
            return fail(@"WebKit context menu did not expose an actionable Reload item");
        if (!foundInspector)
            return fail(@"WebKit context menu did not preserve Inspect Element");

        if (!pumpUntil(^BOOL {
            return navigationFinishedCount >= 2 && readyMessageCount >= 2;
        }, 5.0))
            return fail(@"native context-menu Reload did not complete and restore UI messaging");

        NSNumber *loadCount = evaluateSynchronously(
            @"Number(sessionStorage.getItem('loads'))",
            &error);
        if (error != nil || loadCount.integerValue != 2)
            return fail(@"sessionStorage did not survive native Reload");

        moveMouse(hostWindow, NSMakePoint(100, 225));
        NSNumber *hovered = evaluateSynchronously(
            @"document.querySelector('#probe').matches(':hover')",
            &error);
        if (error != nil || !hovered.boolValue)
            return fail(@"CSS hover did not update after native Reload");

        evaluateSynchronously(
            @"window.webkit.messageHandlers.__turf__.postMessage(JSON.stringify({type:'probe.interaction'})); true",
            &error);
        if (error != nil || !pumpUntil(^BOOL {
            return interactionMessageCount == 1;
        }, 5.0))
            return fail(@"UI-to-native message did not arrive after Reload");

        NSNumber *nativeToUI = evaluateSynchronously(
            @"window.nativeResponse='received'; window.nativeResponse === 'received'",
            &error);
        if (error != nil || !nativeToUI.boolValue)
            return fail(@"native-to-UI JavaScript did not execute after Reload");

        if (navigationStartedCount < 2)
            return fail(@"navigation-start lifecycle was not emitted for initial load and Reload");

        [hostWindow orderOut:nil];
        fprintf(stdout,
            "PASS: native Reload preserved hover, state, Inspect Element, and bidirectional messaging\n");
        return 0;
    }
}
