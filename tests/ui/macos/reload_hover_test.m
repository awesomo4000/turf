#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

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
static NSInteger turfReadyMessageCount = 0;

void onWindowEvent(int x, int y, int width, int height) { }
void onWindowGeometryEvent(int x, int y, int width, int height) { }
void onWebViewNavigationStarted(unsigned long long generation) { navigationStartedCount += 1; }

void onJavaScriptMessage(const char *message) {
    NSString *body = [NSString stringWithUTF8String:message];
    if ([body containsString:@"probe.ready"])
        readyMessageCount += 1;
    if ([body containsString:@"probe.interaction"])
        interactionMessageCount += 1;
    if ([body containsString:@"turf_ready"])
        turfReadyMessageCount += 1;
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

// WebCore::ContextMenuItemTag values from Source/WebCore/page/ContextMenuItem.h.
// These are private test dependencies, like the WKWebView selectors above.
static const NSInteger WebKitContextMenuItemTagReload = 12;
static const NSInteger WebKitContextMenuItemTagInspectElement = 57;

static NSMenuItem *findMenuItemWithTag(NSMenu *menu, NSInteger tag) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.tag == tag)
            return item;
        if (item.submenu != nil) {
            NSMenuItem *nested = findMenuItemWithTag(item.submenu, tag);
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
    __block BOOL finishedTracking = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    NSTimer *timer = [NSTimer
        timerWithTimeInterval:0.05
        repeats:YES
        block:^(NSTimer *activeTimer) {
            NSMenu *menu = [webView _activeMenu];
            if ([deadline timeIntervalSinceNow] <= 0) {
                [menu cancelTrackingWithoutAnimation];
                [activeTimer invalidate];
                finishedTracking = YES;
                return;
            }
            if (menu == nil)
                return;
            sawInspector = findMenuItemWithTag(
                menu,
                WebKitContextMenuItemTagInspectElement) != nil;
            NSMenuItem *reloadItem = findMenuItemWithTag(
                menu,
                WebKitContextMenuItemTagReload);
            if (reloadItem == nil)
                return;
            NSMenu *itemMenu = reloadItem.menu;
            [itemMenu performActionForItemAtIndex:[itemMenu indexOfItem:reloadItem]];
            [menu cancelTracking];
            [activeTimer invalidate];
            selectedReload = YES;
            finishedTracking = YES;
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
    if (!pumpUntil(^BOOL { return finishedTracking; }, 5.5)) {
        [[webView _activeMenu] cancelTrackingWithoutAnimation];
        [timer invalidate];
    }
    if (foundInspector)
        *foundInspector = sawInspector;
    return selectedReload;
}

static int fail(NSString *message) {
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    return 1;
}

static NSWindow *productionTestWindow = nil;
static BOOL productionPresentationRequestedKey = NO;

static void captureKeyPresentationRequest(id receiver, SEL command, id sender) {
    productionTestWindow = receiver;
    productionPresentationRequestedKey = YES;
}

static void suppressWindowCentering(id receiver, SEL command) { }

static NSWindowOcclusionState reportWindowVisibleForRendering(id receiver, SEL command) {
    return NSWindowOcclusionStateVisible;
}

static BOOL suppressTurfWindowPresentation(void) {
    Class windowClass = [TurfNonactivatingPanel class];
    Method showMethod = class_getInstanceMethod(
        windowClass,
        @selector(makeKeyAndOrderFront:));
    Method centerMethod = class_getInstanceMethod(windowClass, @selector(center));
    Method occlusionMethod = class_getInstanceMethod(
        windowClass,
        @selector(occlusionState));
    return class_addMethod(
               windowClass,
               @selector(makeKeyAndOrderFront:),
               (IMP)captureKeyPresentationRequest,
               method_getTypeEncoding(showMethod)) &&
           class_addMethod(
               windowClass,
               @selector(center),
               (IMP)suppressWindowCentering,
               method_getTypeEncoding(centerMethod)) &&
           class_addMethod(
               windowClass,
               @selector(occlusionState),
               (IMP)reportWindowVisibleForRendering,
               method_getTypeEncoding(occlusionMethod));
}

static const char *probeHTML =
    "<!doctype html><meta charset='utf-8'>"
    "<style>body{margin:0}#probe{position:absolute;left:50px;top:50px;width:100px;height:50px;background:rgb(255,0,0)}#probe:hover{background:rgb(0,128,0)}</style>"
    "<button id='probe'>probe</button>"
    "<script>"
    "window.signatureLifecycle={observed:false,animationDuration:'',removed:false};"
    "let observedSignature=null;"
    "new MutationObserver(records=>{"
    "for(const record of records){"
    "for(const node of record.addedNodes){"
    "if(node.nodeType===Node.ELEMENT_NODE&&node.id==='turf-signature'){"
    "observedSignature=node;"
    "window.signatureLifecycle.observed=true;"
    "window.signatureLifecycle.animationDuration=getComputedStyle(node).animationDuration;"
    "}"
    "}"
    "for(const node of record.removedNodes){"
    "if(node===observedSignature)"
    "window.signatureLifecycle.removed=true;"
    "}"
    "}"
    "}).observe(document.documentElement,{childList:true,subtree:true});"
    "const loads=Number(sessionStorage.getItem('loads')||0)+1;"
    "sessionStorage.setItem('loads',String(loads));"
    "window.webkit.messageHandlers.__turf__.postMessage(JSON.stringify({type:'probe.ready',loads}));"
    "</script>";

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        pid_t frontmostBefore =
            NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        __block BOOL nonactivatingLaunchActivatedSelf = NO;
        id activationObserver = [
            NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceDidActivateApplicationNotification
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *notification) {
                NSRunningApplication *application =
                    notification.userInfo[NSWorkspaceApplicationKey];
                if (application.processIdentifier ==
                    NSProcessInfo.processInfo.processIdentifier) {
                    nonactivatingLaunchActivatedSelf = YES;
                }
            }];

        if (!TurfApplicationLoad(NO))
            return fail(@"production application initialization failed");
        if (NSApp.activationPolicy != NSApplicationActivationPolicyProhibited)
            return fail(@"nonactivating Turf initialization used an activating application policy");
        if (!suppressTurfWindowPresentation())
            return fail(@"could not suppress production window presentation");

        NSString *testFile = [NSString stringWithUTF8String:__FILE__];
        NSString *projectRoot = [[[[testFile
            stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent];
        NSString *bridgePath = [projectRoot
            stringByAppendingPathComponent:@"src/web/turf.js"];
        NSError *bridgeSourceError = nil;
        NSString *bridgeSource = [NSString
            stringWithContentsOfFile:bridgePath
            encoding:NSUTF8StringEncoding
            error:&bridgeSourceError];
        if (bridgeSourceError != nil || bridgeSource == nil)
            return fail(@"could not load the production Turf browser bridge");
        NSCreateWindow(-10000, -10000, 400, 300, "Turf history test", bridgeSource.UTF8String, NO);
        NSWindow *productionWindow = webView.window;
        if (![productionWindow isKindOfClass:[NSPanel class]] ||
            !(productionWindow.styleMask & NSWindowStyleMaskNonactivatingPanel))
            return fail(@"nonactivating Turf launch did not use a nonactivating panel");
        if (!productionWindow.canBecomeKeyWindow)
            return fail(@"nonactivating Turf panel could not become key after user interaction");
        if (![(NSPanel *)productionWindow becomesKeyOnlyIfNeeded])
            return fail(@"nonactivating Turf panel did not defer key status until interaction");
        if (![webView needsPanelToBecomeKey])
            return fail(@"Turf WebView did not request key status for user interaction");
        [productionWindow setIgnoresMouseEvents:YES];
        [productionWindow setAlphaValue:0.0];
        [productionWindow setFrameOrigin:NSMakePoint(-10000, -10000)];
        __block BOOL productionWindowWasVisible = NO;
        __block BOOL closeWakeFallbackRequired = NO;
        dispatch_block_t closeWakeFallback = dispatch_block_create(0, ^{
            closeWakeFallbackRequired = YES;
            NSEvent *wakeEvent = [NSEvent
                otherEventWithType:NSEventTypeApplicationDefined
                location:NSZeroPoint
                modifierFlags:0
                timestamp:0
                windowNumber:0
                context:nil
                subtype:0
                data1:0
                data2:0];
            [NSApp postEvent:wakeEvent atStart:NO];
        });
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            closeWakeFallback);
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                productionWindowWasVisible = productionWindow.visible;
                NSRequestWindowClose();
            });
        NSRunApplication();
        dispatch_block_cancel(closeWakeFallback);
        if (closeWakeFallbackRequired)
            return fail(@"inactive Turf close needed an external wake event");
        [NSWorkspace.sharedWorkspace.notificationCenter
            removeObserver:activationObserver];
        if (nonactivatingLaunchActivatedSelf)
            return fail(@"nonactivating Turf launch transiently activated itself");
        if (productionPresentationRequestedKey)
            return fail(@"nonactivating Turf window requested key status");
        pid_t frontmostAfter =
            NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        if (frontmostAfter != frontmostBefore)
            return fail(@"nonactivating Turf run loop changed the frontmost application");
        if (productionWindow.keyWindow)
            return fail(@"nonactivating Turf launch made its panel key");
        if (!productionWindowWasVisible)
            return fail(@"nonactivating Turf window was not visible before close");
        if (NSApp.activationPolicy != NSApplicationActivationPolicyProhibited)
            return fail(@"nonactivating Turf app changed its prohibited activation policy");
        [productionWindow orderFront:nil];
        if (webView.loading && !pumpUntil(^BOOL { return !webView.loading; }, 5.0))
            return fail(@"production placeholder navigation did not settle");

        TurfTestNavigationDelegate *productionDelegate =
            [[TurfTestNavigationDelegate alloc] init];
        webView.navigationDelegate = productionDelegate;
        NSLoadString(probeHTML);
        if (!pumpUntil(^BOOL {
            return navigationFinishedCount >= 1 && readyMessageCount >= 1;
        }, 5.0))
            return fail(@"production initial Turf page did not finish");
        NSError *bridgeError = nil;
        if (!pumpUntil(^BOOL { return turfReadyMessageCount >= 1; }, 5.0))
            return fail(@"production Turf page did not message native readiness");
        NSNumber *signatureObserved = evaluateSynchronously(
            @"window.signatureLifecycle.observed === true",
            &bridgeError);
        if (bridgeError != nil || !signatureObserved.boolValue)
            return fail(@"production Turf signature was not observed");
        NSString *signatureAnimationDuration = evaluateSynchronously(
            @"window.signatureLifecycle.animationDuration",
            &bridgeError);
        if (bridgeError != nil ||
            ![signatureAnimationDuration isEqualToString:@"1.2s"])
            return fail(@"production Turf signature animation duration was not 1.2s");
        NSNumber *signatureFadeIsNeutral = evaluateSynchronously(
            @"(() => {"
             "const animation=document.getElementById('turf-signature')?.getAnimations()[0];"
             "if(!animation)return false;"
             "const keyframes=animation.effect.getKeyframes();"
             "return [0.75,1].every(offset=>keyframes.some(keyframe=>"
             "keyframe.offset===offset&&keyframe.backgroundImage==='none'));"
             "})()",
            &bridgeError);
        if (bridgeError != nil || !signatureFadeIsNeutral.boolValue)
            return fail(@"production Turf signature fade retained its rainbow background");
        pumpUntil(^BOOL { return NO; }, 1.3);
        NSNumber *signatureRemoved = evaluateSynchronously(
            @"window.signatureLifecycle.removed === true",
            &bridgeError);
        if (bridgeError != nil || !signatureRemoved.boolValue)
            return fail(@"production Turf signature was not removed after its lifecycle");
        NSNumber *signatureAbsent = evaluateSynchronously(
            @"document.getElementById('turf-signature') === null",
            &bridgeError);
        if (bridgeError != nil || !signatureAbsent.boolValue)
            return fail(@"production Turf signature remained in the DOM");
        NSString *bridgeConsole = evaluateSynchronously(
            @"(() => {"
             "const marker='FARMHAND_SECRET_INPUT_7f4c';"
             "const captured=[];"
             "console.log=(...args)=>captured.push(args.map(String).join(' '));"
             "window.turf.send({type:'terminal.input',data:{data_b64:marker}});"
             "window.turf._handleNativeMessage({type:'daemon.message',data:{data_b64:marker}});"
             "return captured.join('\\n');"
             "})()",
            &bridgeError);
        if (bridgeError != nil || [bridgeConsole containsString:@"FARMHAND_SECRET_INPUT_7f4c"])
            return fail(@"Turf browser bridge logged a terminal payload");
        if (webView.backForwardList.backItem != nil)
            return fail(@"production initial Turf page retained prior navigation history");

        NSLoadURL("turf://localhost/?screen=second");
        if (!pumpUntil(^BOOL {
            return navigationFinishedCount >= 2 && readyMessageCount >= 2;
        }, 5.0))
            return fail(@"production second Turf page did not finish");
        NSURL *backURL = webView.backForwardList.backItem.URL;
        if (!webView.canGoBack ||
            ![backURL.absoluteString isEqualToString:@"turf://localhost/index.html"])
            return fail(@"production navigation did not retain real back history");

        [productionWindow setReleasedWhenClosed:NO];
        __block BOOL closeRequestReturned = NO;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSRequestWindowClose();
            closeRequestReturned = YES;
        });
        if (!pumpUntil(^BOOL {
            return closeRequestReturned && !productionWindow.visible;
        }, 5.0))
            return fail(@"thread-safe native close request did not close the Turf window");
        productionTestWindow = nil;
        navigationStartedCount = 0;
        navigationFinishedCount = 0;
        readyMessageCount = 0;

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
        SEL setInspectableSelector = NSSelectorFromString(@"setInspectable:");
        if ([webView respondsToSelector:setInspectableSelector]) {
            typedef void (*SetInspectableFunction)(id, SEL, BOOL);
            SetInspectableFunction function =
                (SetInspectableFunction)[webView methodForSelector:setInspectableSelector];
            function(webView, setInspectableSelector, YES);
        }
        hostWindow.contentView = webView;
        [hostWindow makeKeyAndOrderFront:nil];

        if (!supportsWebKitTestSPI(webView)) {
            fprintf(stdout,
                "SKIP: installed WebKit does not expose the test selectors used by this sample\n");
            return 0;
        }

        NSLoadString(probeHTML);

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
            "PASS: root history, native Reload, hover, state, Inspect Element, and bidirectional messaging\n");
        return 0;
    }
}
