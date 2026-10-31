// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
// Diagnostic uses Turf's actual Cocoa bridge, without adding test-only RPC methods.
#import "../src/platforms/macos/cocoa_bridge.m"

void onWindowEvent(int x, int y, int w, int h) {}
void onWindowGeometryEvent(int x, int y, int w, int h) {}
void onJavaScriptMessage(const char *message) {}

static NSWindow *cover;
static NSRunningApplication *previousApp;
static BOOL background;
static NSUInteger phase;
static int failures;
static NSString * const probe = @"JSON.stringify({visibility:document.visibilityState,focus:document.hasFocus(),frames:window.framesSeen,events:window.eventsSeen})";

static void sample(void);
static void uncoverAfterActivation(NSWindow *window) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [window orderFrontRegardless]; });
}
static void advance(void) {
    NSWindow *window = webView.window;
    switch (phase) {
        case 0: break; // Untouched startup.
        case 1:
            [previousApp activateWithOptions:0];
            uncoverAfterActivation(window);
            break;
        case 2:
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            break;
        case 3:
            [previousApp activateWithOptions:0];
            uncoverAfterActivation(window);
            break;
        case 4:
            cover = [[NSWindow alloc] initWithContentRect:window.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            cover.backgroundColor = NSColor.grayColor;
            cover.opaque = YES;
            [cover orderFrontRegardless];
            break;
        case 5: [cover orderOut:nil]; break;
        case 6: [window miniaturize:nil]; break;
        case 7:
            [window deminiaturize:nil];
            [previousApp activateWithOptions:0];
            uncoverAfterActivation(window);
            break;
        default:
            [previousApp activateWithOptions:0];
            if (failures) fprintf(stderr, "%d visibility checks failed in %s mode\n", failures, background ? "no-focus" : "normal");
            exit(failures ? 1 : 0);
    }
    // Allow native visibility and IPC updates to settle before measuring.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ sample(); });
}
static void sample(void) {
    [webView evaluateJavaScript:@"window.framesSeen=0" completionHandler:^(id unused, NSError *resetError) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [webView evaluateJavaScript:probe completionHandler:^(id value, NSError *error) {
                NSArray *names = @[@"startup", @"unfocused-uncovered-first", @"focused", @"unfocused-uncovered", @"covered", @"uncovered", @"minimized", @"restored"];
                NSWindow *window = webView.window;
                NSDictionary *page = value ? [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : @{};
                BOOL visible = (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
                NSDictionary *row = @{ @"mode": background ? @"no-focus" : @"normal", @"phase": names[phase],
                    @"native": @{ @"visible": @(window.visible), @"unoccluded": @(visible), @"key": @(window.keyWindow), @"active": @(NSApp.active), @"minimized": @(window.miniaturized), @"viewHidden": @(webView.hiddenOrHasHiddenAncestor) },
                    @"page": page, @"error": (error ?: resetError).localizedDescription ?: @"" };
                NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
                puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
                fflush(stdout);
                if (error || resetError || !page[@"visibility"]) failures++;
                BOOL uncoveredPhase = phase == 0 || phase == 1 || phase == 2 || phase == 3 || phase == 5 || phase == 7;
                if (uncoveredPhase && !visible) failures++;
                if (((phase == 0 && background) || phase == 1 || phase == 3) && (window.keyWindow || NSApp.active || [page[@"focus"] boolValue])) failures++;
                if (phase == 2 && (!window.keyWindow || ![page[@"focus"] boolValue])) failures++;
                if ((phase == 4 || phase == 6) && (visible || ![page[@"visibility"] isEqual:@"hidden"])) failures++;
                if (visible && !window.miniaturized && (![page[@"visibility"] isEqual:@"visible"] || [page[@"frames"] integerValue] == 0)) failures++;
                phase++;
                advance();
            }];
        });
    }];
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        background = argc > 1 && strcmp(argv[1], "--no-focus") == 0;
        previousApp = NSWorkspace.sharedWorkspace.frontmostApplication;
        TurfApplicationLoad();
        NSScreen *target = nil;
        for (NSScreen *screen in NSScreen.screens) {
            if ([screen.localizedName.lowercaseString containsString:@"dell"]) { target = screen; break; }
        }
        if (!target) { fprintf(stderr, "Dell unavailable; refusing to show on another screen\n"); return 1; }
        NSCreateWindow(0, 0, 420, 220, "Turf visibility diagnostic", "", background, false);
        NSRect work = target.visibleFrame, frame = webView.window.frame;
        CGFloat x = NSMinX(work) + (work.size.width - frame.size.width) / 2;
        CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame) - NSMaxY(work);
        CGFloat y = top + work.size.height * 5 / 6 - frame.size.height / 2;
        NSSetWindowPosition((int)x, (int)y);
        NSLoadString("<!doctype html><title>Visibility diagnostic</title><h1>Turf visibility test</h1><script>window.framesSeen=0;window.eventsSeen=[];function frame(){framesSeen++;requestAnimationFrame(frame)}requestAnimationFrame(frame);for(const type of ['visibilitychange','focus','blur']){(type==='visibilitychange'?document:window).addEventListener(type,()=>eventsSeen.push({type,time:performance.now(),visibility:document.visibilityState,focus:document.hasFocus()}));}</script>");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ advance(); });
        NSRunApplication();
    }
}
