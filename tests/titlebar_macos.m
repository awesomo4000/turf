// SPDX-License-Identifier: MPL-2.0
#import "../src/platforms/macos/cocoa_bridge.m"
#include <assert.h>
void onWindowEvent(int x, int y, int w, int h) {}
void onWindowGeometryEvent(int x, int y, int w, int h) {}
void onJavaScriptMessage(const char *message) {}
void onDocumentChanging(void) {}
@interface DragProbe : TurfWindow
@property NSUInteger dragCalls;
@end
@implementation DragProbe
- (void)performWindowDragWithEvent:(NSEvent *)event { self.dragCalls++; }
@end

int main(void) {
    @autoreleasepool {
        pid_t foreground = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        TurfApplicationLoad();
        for (int mode = 0; mode < 5; mode++) {
            BOOL hidden = mode == 1 || mode == 3;
            BOOL controlsHidden = mode >= 2;
            BOOL square = mode == 4;
            NSCreateWindow(0, 0, 420, 220, "Title fixture 🦦", "", true, true,
                hidden, controlsHidden, square, true);
            NSWindow *window = webView.window;
            assert(!window.visible && !window.keyWindow);
            assert(window.canBecomeKeyWindow && window.canBecomeMainWindow);
            assert([window.title isEqual:@"Title fixture 🦦"]);
            assert((window.styleMask & NSWindowStyleMaskResizable) != 0);
            assert(NSCmdDragEnabled());
            if (square) assert(!(window.styleMask & NSWindowStyleMaskTitled));
            else {
                assert((window.titleVisibility == NSWindowTitleHidden) == hidden);
                assert(window.titlebarAppearsTransparent == hidden);
            }
            for (NSNumber *kind in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
                NSButton *button = [window standardWindowButton:kind.unsignedIntegerValue];
                if (controlsHidden) assert(!button || button.hidden);
                else assert(button && !button.hidden);
            }
            assert(webView.bounds.size.width == 420 && webView.bounds.size.height == 220);
            CGFloat reserved = window.contentView.bounds.size.height - webView.bounds.size.height;
            assert(reserved == 0);
            [window setContentSize:NSMakeSize(520, 300)];
            [window.contentView layoutSubtreeIfNeeded];
            assert(webView.bounds.size.width == 520 && webView.bounds.size.height == 300);
            assert(NSEqualRects(webView.frame, window.contentView.bounds));
            if (hidden || square) assert(window.frame.size.height == webView.bounds.size.height);
            NSDestroyWindow();
        }
        // Observe native drag dispatch without entering AppKit's interactive drag loop.
        DragProbe *probe = [[DragProbe alloc] initWithContentRect:NSMakeRect(0,0,200,100)
            styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        probe.releasedWhenClosed = NO;
        NSEvent *(^down)(NSEventModifierFlags) = ^NSEvent *(NSEventModifierFlags flags) {
            return [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(50,50)
                modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:probe.windowNumber
                context:nil eventNumber:0 clickCount:1 pressure:1];
        };
        probe.cmdDragEnabled = YES;
        [probe sendEvent:down(NSEventModifierFlagCommand)];
        assert(probe.dragCalls == 1 && !windowDragMouseDown);
        NSEvent *plain = down(0);
        [probe sendEvent:plain];
        assert(probe.dragCalls == 1 && windowDragMouseDown == plain);
        NSEvent *option = down(NSEventModifierFlagOption);
        [probe sendEvent:option];
        assert(probe.dragCalls == 1 && windowDragMouseDown == option);
        probe.cmdDragEnabled = NO;
        NSEvent *command = down(NSEventModifierFlagCommand);
        [probe sendEvent:command];
        assert(probe.dragCalls == 1 && windowDragMouseDown == command);
        windowDragMouseDown = nil;
        [probe close];
        assert(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == foreground);
        puts("PASS: native styles, controls, square mode, keyboard eligibility, resize, Command-drag dispatch, no activation");
    }
}
