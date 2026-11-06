// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import "automation.h"
#import "automation_scripts.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>

static const NSUInteger maxRequestBytes = 1024 * 1024;
static const NSUInteger maxResponseBytes = 32 * 1024 * 1024;
extern unsigned long long NSMessageGeneration(void);

typedef void (^AutomationReply)(id result, NSInteger code, NSString *message);

@interface TurfAutomationServer : NSObject <WKScriptMessageHandler>
@property (nonatomic, strong) NSMutableDictionary *retainedTopics;
@property (nonatomic, strong) WKUserScript *retainedScript;
@property (nonatomic) unsigned long long emitSequence;
@property (atomic) BOOL stopped;
@property (nonatomic) BOOL background;
@property (atomic) BOOL closeRequested;
@property (nonatomic, strong) WKWebView *view;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) int listener;
@property (nonatomic) ino_t socketInode;
@property (nonatomic) dev_t socketDevice;
@property (nonatomic, strong) WKNavigation *navigation;
@property (nonatomic, copy) AutomationReply navigationReply;
@property (nonatomic, strong) NSMutableArray *diagnostics;
@property (nonatomic, strong) NSMutableDictionary *diagnosticFrames;
@property (nonatomic) NSUInteger diagnosticBytes;
@property (nonatomic) unsigned long long diagnosticSequence;
@property (nonatomic, copy) NSString *diagnosticSession;
@property (nonatomic, copy) NSString *diagnosticHandler;
@property (nonatomic, copy) NSString *diagnosticState;
@property (nonatomic, strong) WKUserScript *diagnosticScript;
- (void)stopDiagnostics;
- (void)updateRetainedScript;
- (void)emitRequest:(NSDictionary *)params reply:(AutomationReply)reply;
- (void)serve;
- (void)execute:(NSDictionary *)request reply:(AutomationReply)reply;
- (void)removeSocket;
- (void)screenshot:(NSDictionary *)params reply:(AutomationReply)reply;
- (void)captureRegion:(NSRect)region fullViewport:(BOOL)full generation:(unsigned long long)generation bounds:(NSRect)bounds reply:(AutomationReply)reply;
@end

static TurfAutomationServer *automationServer;

// Polling bounds shutdown latency without closing a descriptor from another thread.
static BOOL waitForSocket(int fd, short events, TurfAutomationServer *server, NSTimeInterval deadline) {
    while (!server.stopped && [NSDate timeIntervalSinceReferenceDate] < deadline) {
        struct pollfd p = { .fd = fd, .events = events };
        int result = poll(&p, 1, 100);
        if (result > 0) return (p.revents & events) != 0;
        if (result < 0 && errno != EINTR) return NO;
    }
    return NO;
}

static BOOL clientDisconnected(int fd) {
    struct pollfd state = { .fd = fd, .events = POLLIN };
    if (poll(&state, 1, 0) <= 0) return NO;
    if (state.revents & (POLLERR | POLLNVAL)) return YES;
    if (state.revents & (POLLIN | POLLHUP)) {
        char byte;
        ssize_t count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
        if (count == 0 || (state.revents & POLLHUP)) {
            // Darwin reports POLLHUP for SHUT_WR too. A zero-byte send checks
            // whether the peer still accepts a response without changing framing.
            return send(fd, "", 0, 0) < 0 && errno != EINTR && errno != EAGAIN;
        }
        return count < 0 && errno != EINTR && errno != EAGAIN;
    }
    return NO;
}

static NSData *responseData(id requestID, id result, NSInteger code, NSString *message) {
    NSMutableDictionary *detail = [@{ @"code": @(code), @"message": message ?: @"Request failed" } mutableCopy];
    if (code && result) detail[@"data"] = result;
    NSDictionary *response = code
        ? @{ @"jsonrpc": @"2.0", @"id": requestID ?: NSNull.null,
             @"error": detail }
        : @{ @"jsonrpc": @"2.0", @"id": requestID ?: NSNull.null, @"result": result ?: NSNull.null };
    NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (!json || json.length > maxResponseBytes) {
        return responseData(requestID, nil, -32003, @"Result is not JSON-serializable or exceeds 32 MiB");
    }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    return line;
}

static NSDictionary *snapshotRegion(NSRect rect) {
    return @{ @"x": @(rect.origin.x), @"y": @(rect.origin.y),
        @"width": @(rect.size.width), @"height": @(rect.size.height) };
}

// Coordinates are webview points from the top-left, independent of screen scale.
static BOOL automationNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}

static BOOL snapshotRect(id value, NSRect *rect) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"x", @"y", @"width", @"height"]) {
        if (!automationNumber(value[key])) return NO;
    }
    *rect = NSMakeRect([value[@"x"] doubleValue], [value[@"y"] doubleValue],
        [value[@"width"] doubleValue], [value[@"height"] doubleValue]);
    return rect->size.width > 0 && rect->size.height > 0;
}

static BOOL clipSnapshotRect(NSRect requested, double padding, NSSize viewport, NSRect *result) {
    double left = requested.origin.x - padding, top = requested.origin.y - padding;
    double right = requested.origin.x + requested.size.width + padding;
    double bottom = requested.origin.y + requested.size.height + padding;
    if (!isfinite(left) || !isfinite(top) || !isfinite(right) || !isfinite(bottom)) return NO;
    left = MAX(0, left); top = MAX(0, top);
    right = MIN(viewport.width, right); bottom = MIN(viewport.height, bottom);
    if (right <= left || bottom <= top) return NO;
    // WebKit snapshots enclose the source rect in whole view coordinates. Report
    // that same outward-rounded region so annotation offsets remain meaningful.
    left = floor(left); top = floor(top);
    right = MIN(viewport.width, ceil(right)); bottom = MIN(viewport.height, ceil(bottom));
    *result = NSMakeRect(left, top, right - left, bottom - top);
    return YES;
}

static BOOL automationModifiers(id values, NSEventModifierFlags *flags) {
    *flags = 0;
    if (!values) return YES;
    if (![values isKindOfClass:NSArray.class]) return NO;
    NSDictionary *names = @{ @"shift": @(NSEventModifierFlagShift), @"control": @(NSEventModifierFlagControl),
        @"alt": @(NSEventModifierFlagOption), @"meta": @(NSEventModifierFlagCommand) };
    for (id value in values) {
        if (![value isKindOfClass:NSString.class] || !names[value]) return NO;
        *flags |= [names[value] unsignedIntegerValue];
    }
    return YES;
}

// Public automation coordinates use logical points, with a top-left origin.
// Cocoa's desktop coordinates use a bottom-left origin, so convert at the edge.
static NSDictionary *automationRect(NSRect rect) {
    CGFloat desktopTop = NSMaxY(NSScreen.screens.firstObject.frame);
    return @{ @"x": @(NSMinX(rect)), @"y": @(desktopTop - NSMaxY(rect)),
        @"width": @(rect.size.width), @"height": @(rect.size.height) };
}

static NSString *automationScreenID(NSScreen *screen) {
    if (!screen) return @"";
    CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return [NSString stringWithFormat:@"display-%u", display];
    NSString *result = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    return result;
}

static NSDictionary *automationScreenInfo(NSScreen *screen) {
    CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    return @{ @"id": automationScreenID(screen), @"name": screen.localizedName,
        @"isBuiltIn": @(CGDisplayIsBuiltin(display) != 0),
        @"isPrimary": @(screen == NSScreen.screens.firstObject),
        @"scaleFactor": @(screen.backingScaleFactor),
        @"frame": automationRect(screen.frame), @"workArea": automationRect(screen.visibleFrame) };
}

static NSDictionary *automationWindowInfo(NSWindow *window) {
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    NSRect frame = window.frame, work = screen.visibleFrame;
    return @{ @"screen": automationScreenID(screen), @"frame": automationRect(frame),
        @"x": @(NSMinX(frame) - NSMinX(work)), @"y": @(NSMaxY(work) - NSMaxY(frame)),
        @"visible": @(window.visible), @"focused": @(window.isKeyWindow) };
}

// Resolve menu shortcuts against this window instead of the application's key window.
static BOOL automationMenuKey(NSMenu *menu, NSEvent *event, NSResponder *responder) {
    NSEventModifierFlags mask = NSEventModifierFlagCommand | NSEventModifierFlagShift |
        NSEventModifierFlagControl | NSEventModifierFlagOption;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu && automationMenuKey(item.submenu, event, responder)) return YES;
        if (item.keyEquivalent.length && [item.keyEquivalent.lowercaseString isEqual:event.charactersIgnoringModifiers.lowercaseString] &&
            (item.keyEquivalentModifierMask & mask) == (event.modifierFlags & mask) && !item.target && item.action) {
            return [responder tryToPerform:item.action with:item];
        }
    }
    return NO;
}

// Named navigation keys and US-layout printable keys. Unicode text uses typeText.
static BOOL automationKey(NSString *key, NSString **characters, unsigned short *code, BOOL *function) {
    NSDictionary *named = @{
        @"ArrowLeft": @[@(NSLeftArrowFunctionKey), @123], @"ArrowRight": @[@(NSRightArrowFunctionKey), @124],
        @"ArrowDown": @[@(NSDownArrowFunctionKey), @125], @"ArrowUp": @[@(NSUpArrowFunctionKey), @126],
        @"Home": @[@(NSHomeFunctionKey), @115], @"End": @[@(NSEndFunctionKey), @119],
        @"PageUp": @[@(NSPageUpFunctionKey), @116], @"PageDown": @[@(NSPageDownFunctionKey), @121],
        @"Delete": @[@(NSDeleteFunctionKey), @117], @"Backspace": @[@127, @51],
        @"Enter": @[@13, @36], @"Tab": @[@9, @48], @"Escape": @[@27, @53], @"Space": @[@32, @49]
    };
    NSArray *entry = named[key];
    if (entry) {
        unichar character = [entry[0] unsignedShortValue];
        *characters = [NSString stringWithCharacters:&character length:1];
        *code = [entry[1] unsignedShortValue]; *function = character >= 0xF700;
        return YES;
    }
    NSDictionary *codes = @{ @"a": @0, @"s": @1, @"d": @2, @"f": @3, @"h": @4, @"g": @5,
        @"z": @6, @"x": @7, @"c": @8, @"v": @9, @"b": @11, @"q": @12, @"w": @13,
        @"e": @14, @"r": @15, @"y": @16, @"t": @17, @"1": @18, @"2": @19, @"3": @20,
        @"4": @21, @"6": @22, @"5": @23, @"=": @24, @"9": @25, @"7": @26, @"-": @27,
        @"8": @28, @"0": @29, @"]": @30, @"o": @31, @"u": @32, @"[": @33, @"i": @34,
        @"p": @35, @"l": @37, @"j": @38, @"'": @39, @"k": @40, @";": @41, @"\\": @42,
        @",": @43, @"/": @44, @"n": @45, @"m": @46, @".": @47, @"`": @50, @" ": @49 };
    NSString *base = key.lowercaseString;
    NSString *shifted = @"~!@#$%^&*()_+{}|:\"<>?";
    NSString *unshifted = @"`1234567890-=[]\\;',./";
    NSRange index = [shifted rangeOfString:key];
    if (key.length == 1 && index.location != NSNotFound) base = [unshifted substringWithRange:NSMakeRange(index.location, 1)];
    NSNumber *number = codes[base];
    if (!number) return NO;
    *characters = key; *code = number.unsignedShortValue; *function = NO;
    return YES;
}

@implementation TurfAutomationServer
// Only the script owned by this server is replaced; preserve embedder scripts.
- (void)updateRetainedScript {
    WKUserContentController *controller = self.view.configuration.userContentController;
    if (self.retainedScript) {
        NSMutableArray *scripts = [NSMutableArray array];
        for (WKUserScript *script in controller.userScripts)
            if (![script.source isEqual:self.retainedScript.source]) [scripts addObject:script];
        [controller removeAllUserScripts];
        for (WKUserScript *script in scripts) [controller addUserScript:script];
        self.retainedScript = nil;
    }
    if (!self.retainedTopics.count) return;
    NSArray *packets = [self.retainedTopics.allValues sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [a[@"seq"] compare:b[@"seq"]];
    }];
    NSData *json = [NSJSONSerialization dataWithJSONObject:packets options:0 error:nil];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    NSData *literal = [NSJSONSerialization dataWithJSONObject:text options:NSJSONWritingFragmentsAllowed error:nil];
    NSString *source = [NSString stringWithFormat:
        @"(() => { for (const p of JSON.parse(%@)) { if (location.href === p.url) window.turf?._emit(p, true); } })();",
        [[NSString alloc] initWithData:literal encoding:NSUTF8StringEncoding]];
    self.retainedScript = [[WKUserScript alloc] initWithSource:source
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [controller addUserScript:self.retainedScript];
}
- (void)emitRequest:(NSDictionary *)params reply:(AutomationReply)reply {
    NSString *topic = params[@"topic"];
    id retain = params[@"retain"], clear = params[@"clear"];
    if (![topic isKindOfClass:NSString.class] || !topic.length ||
        [topic lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 256 || [topic isEqual:@"*"] ||
        (retain && (![retain isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)retain) != CFBooleanGetTypeID())) ||
        (clear && (![clear isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)clear) != CFBooleanGetTypeID())) ||
        ([clear boolValue] ? (params[@"data"] != nil || retain != nil) : params[@"data"] == nil)) {
        reply(nil, -32602, @"emit requires topic (1..256 UTF-8 bytes, not *), data, optional boolean retain; clear:true requires no data or retain"); return;
    }
    if (@available(macOS 11.0, *)) {
        NSString *url = self.view.URL.absoluteString;
        if (!url.length) url = @"about:blank";
        if (self.view.loading) { reply(nil, -32004, @"emit requires a loaded main document"); return; }
        NSData *data = [NSJSONSerialization dataWithJSONObject:params[@"data"] ?: NSNull.null
            options:NSJSONWritingFragmentsAllowed error:nil];
        if (!data) { reply(nil, -32602, @"emit data must be JSON"); return; }
        if (!self.retainedTopics) self.retainedTopics = [NSMutableDictionary dictionary];
        NSMutableDictionary *packet = [@{ @"topic": topic, @"json": [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding],
            @"seq": @(self.emitSequence + 1), @"ts": @(NSDate.date.timeIntervalSince1970 * 1000),
            @"retain": @([retain boolValue]), @"clear": @([clear boolValue]), @"url": url } mutableCopy];
        if ([retain boolValue]) {
            NSMutableDictionary *candidate = [self.retainedTopics mutableCopy];
            candidate[topic] = packet;
            NSData *encoded = [NSJSONSerialization dataWithJSONObject:candidate options:0 error:nil];
            if (candidate.count > 128 || encoded.length > 4 * 1024 * 1024) {
                reply(nil, -32004, @"Retained topic limit exceeded (128 topics / 4 MiB); clear unused topics"); return;
            }
        }
        // Commit host retention before dispatch. A failed or timed-out dispatch must not be retried blindly.
        self.emitSequence++;
        if ([clear boolValue]) [self.retainedTopics removeObjectForKey:topic];
        else if ([retain boolValue]) self.retainedTopics[topic] = packet;
        if ([clear boolValue] || [retain boolValue]) [self updateRetainedScript];
        unsigned long long generation = NSMessageGeneration();
        [self.view callAsyncJavaScript:
            @"if (location.href !== packet.url || typeof window.turf?._emit !== 'function') throw new Error('Turf topic delivery unavailable'); return window.turf._emit(packet);"
            arguments:@{ @"packet": packet } inFrame:nil inContentWorld:WKContentWorld.pageWorld
            completionHandler:^(id result, NSError *error) {
                if (self.stopped) return;
                if (error || NSMessageGeneration() != generation || ![result isKindOfClass:NSDictionary.class]) {
                    reply(@{ @"accepted": @YES, @"retained": @([retain boolValue]), @"seq": packet[@"seq"] },
                        -32002, error.localizedDescription ?: @"Document changed during emit"); return;
                }
                reply(@{ @"accepted": @YES, @"retained": @([retain boolValue]), @"cleared": @([clear boolValue]),
                    @"seq": packet[@"seq"], @"handlers": result[@"handlers"] ?: @0,
                    @"failures": result[@"failures"] ?: @0 }, 0, nil);
            }];
    } else reply(nil, -32000, @"emit requires macOS 11 or newer");
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (self.stopped || !self.diagnosticScript || ![message.name isEqual:self.diagnosticHandler]) return;
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    if (![body[@"documentId"] isKindOfClass:NSString.class] || [body[@"documentId"] length] > 128 ||
        ![body[@"entries"] isKindOfClass:NSArray.class] || [body[@"entries"] count] > 64) return;
    NSNumber *lost = body[@"dropped"];
    if (automationNumber(lost) && lost.doubleValue > 0) self.diagnosticSequence += (unsigned long long)MIN(lost.doubleValue, 1000000);
    if (self.diagnosticFrames.count < 128) self.diagnosticFrames[body[@"documentId"]] = message.frameInfo;
    for (id item in body[@"entries"]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *entry = [item mutableCopy];
        entry[@"sequence"] = @(++self.diagnosticSequence);
        entry[@"documentId"] = body[@"documentId"];
        entry[@"isMainFrame"] = @(message.frameInfo.mainFrame);
        NSString *url = message.frameInfo.request.URL.absoluteString ?: @"";
        entry[@"url"] = [url substringToIndex:MIN(url.length, 2048)];
        entry[@"receivedAt"] = @(NSDate.date.timeIntervalSince1970 * 1000);
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
        if (!encoded || encoded.length > 8192) continue; // The sequence gap reports this loss.
        [self.diagnostics addObject:@{ @"entry": entry, @"bytes": @(encoded.length) }];
        self.diagnosticBytes += encoded.length;
        while (self.diagnostics.count > 256 || self.diagnosticBytes > 1024 * 1024) {
            self.diagnosticBytes -= [self.diagnostics.firstObject[@"bytes"] unsignedIntegerValue];
            [self.diagnostics removeObjectAtIndex:0];
        }
    }
}
- (void)stopDiagnostics {
    if (!self.diagnosticScript) return;
    WKUserContentController *controller = self.view.configuration.userContentController;
    [controller removeScriptMessageHandlerForName:self.diagnosticHandler];
    // Materialize the collection before removing scripts: WebKit exposes a live array.
    NSMutableArray *scripts = [NSMutableArray array];
    for (WKUserScript *script in controller.userScripts) {
        if (![script.source isEqual:self.diagnosticScript.source]) [scripts addObject:script];
    }
    [controller removeAllUserScripts];
    for (WKUserScript *script in scripts) [controller addUserScript:script];
    if (@available(macOS 11.0, *)) {
        NSString *cleanup = @"const state = window[key]; if (state) state.stop();";
        [self.view callAsyncJavaScript:cleanup arguments:@{ @"key": self.diagnosticState }
            inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
        for (WKFrameInfo *frame in self.diagnosticFrames.allValues) {
            if (!frame.mainFrame) [self.view callAsyncJavaScript:cleanup arguments:@{ @"key": self.diagnosticState }
                inFrame:frame inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
        }
    }
    self.diagnosticScript = nil;
    [self.diagnosticFrames removeAllObjects];
}
- (void)diagnosticsRequest:(NSDictionary *)params reply:(AutomationReply)reply {
    NSString *action = params[@"action"] ?: @"read";
    if ([action isEqual:@"start"]) {
        if (!self.diagnosticScript) {
            self.diagnostics = [NSMutableArray array]; self.diagnosticFrames = [NSMutableDictionary dictionary];
            self.diagnosticBytes = 0; self.diagnosticSequence = 0;
            self.diagnosticSession = NSUUID.UUID.UUIDString;
            NSString *token = [self.diagnosticSession stringByReplacingOccurrencesOfString:@"-" withString:@""];
            self.diagnosticHandler = [@"turfDiagnostics" stringByAppendingString:token];
            self.diagnosticState = [@"__turfDiagnostics" stringByAppendingString:token];
            NSString *source = [turfDiagnosticsScript stringByReplacingOccurrencesOfString:@"HANDLER_NAME"
                withString:[NSString stringWithFormat:@"\"%@\"", self.diagnosticHandler]];
            source = [source stringByReplacingOccurrencesOfString:@"STATE_KEY"
                withString:[NSString stringWithFormat:@"\"%@\"", self.diagnosticState]];
            self.diagnosticScript = [[WKUserScript alloc] initWithSource:source
                injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
            WKUserContentController *controller = self.view.configuration.userContentController;
            [controller addScriptMessageHandler:self name:self.diagnosticHandler];
            [controller addUserScript:self.diagnosticScript];
            [self.view evaluateJavaScript:source completionHandler:^(id value, NSError *error) {
                if (error) { [self stopDiagnostics]; reply(nil, -32002, error.localizedDescription); }
                else reply(@{ @"enabled": @YES, @"session": self.diagnosticSession }, 0, nil);
            }];
        } else reply(@{ @"enabled": @YES, @"session": self.diagnosticSession }, 0, nil);
        return;
    }
    if ([action isEqual:@"stop"]) {
        [self stopDiagnostics];
        reply(@{ @"enabled": @NO, @"session": self.diagnosticSession ?: (id)NSNull.null }, 0, nil);
        return;
    }
    if (![action isEqual:@"read"]) { reply(nil, -32602, @"diagnostics action must be start, read, or stop"); return; }
    id after = params[@"after"] ?: @0, limit = params[@"limit"] ?: @64;
    if (!automationNumber(after) || [after doubleValue] < 0 || floor([after doubleValue]) != [after doubleValue] ||
        [after doubleValue] > self.diagnosticSequence || !automationNumber(limit) || [limit doubleValue] < 1 ||
        [limit doubleValue] > 256 || floor([limit doubleValue]) != [limit doubleValue]) {
        reply(nil, -32602, @"after must be an existing nonnegative cursor; limit must be 1 through 256"); return;
    }
    if (params[@"session"] && ![params[@"session"] isEqual:self.diagnosticSession]) {
        reply(nil, -32004, @"Diagnostic session changed; read again without the old cursor"); return;
    }
    unsigned long long cursor = [after unsignedLongLongValue], available = 0;
    NSMutableArray *entries = [NSMutableArray array];
    for (NSDictionary *record in self.diagnostics) {
        NSDictionary *entry = record[@"entry"];
        if ([entry[@"sequence"] unsignedLongLongValue] <= cursor) continue;
        available++;
        if (entries.count < [limit unsignedIntegerValue]) [entries addObject:entry];
    }
    reply(@{ @"enabled": self.diagnosticScript ? @YES : @NO, @"session": self.diagnosticSession ?: (id)NSNull.null,
        @"entries": entries, @"nextCursor": entries.count ? entries.lastObject[@"sequence"] : @(self.diagnosticSequence),
        @"latestCursor": @(self.diagnosticSequence), @"droppedSinceCursor": @(self.diagnosticSequence - cursor - available),
        @"capacity": @256, @"maxBytes": @(1024 * 1024), @"bufferBytes": @(self.diagnosticBytes) }, 0, nil);
}
- (void)removeSocket {
    struct stat st;
    if (lstat(self.path.fileSystemRepresentation, &st) == 0 && S_ISSOCK(st.st_mode)
        && st.st_ino == self.socketInode && st.st_dev == self.socketDevice) {
        unlink(self.path.fileSystemRepresentation);
    }
}

- (NSData *)handleLine:(NSData *)line client:(int)fd {
    id request = [NSJSONSerialization JSONObjectWithData:line options:NSJSONReadingFragmentsAllowed error:nil];
    if (!request) return responseData(nil, nil, -32700, @"Invalid JSON");
    if (![request isKindOfClass:NSDictionary.class]) return responseData(nil, nil, -32600, @"Expected a JSON-RPC request object");
    id requestID = request[@"id"];
    BOOL validID = [requestID isKindOfClass:NSString.class] ||
        ([requestID isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)requestID) != CFBooleanGetTypeID());
    if (!validID || ![request[@"jsonrpc"] isEqual:@"2.0"] || ![request[@"method"] isKindOfClass:NSString.class]) {
        return responseData(nil, nil, -32600, @"Expected jsonrpc 2.0, a string method, and a string or numeric id");
    }
    if (request[@"params"] && ![request[@"params"] isKindOfClass:NSDictionary.class]) {
        return responseData(requestID, nil, -32602, @"params must be an object");
    }
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    NSObject *lock = [NSObject new];
    __block BOOL completed = NO;
    __block NSData *response;
    AutomationReply reply = ^(id value, NSInteger code, NSString *message) {
        @synchronized(lock) {
            if (completed) return;
            completed = YES;
            response = responseData(requestID, value, code, message);
        }
        dispatch_semaphore_signal(finished);
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(lock) { if (completed) return; }
        if (!self.stopped) [self execute:request reply:reply];
        else reply(nil, -32000, @"Automation stopped");
    });
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 30;
    while (!self.stopped && [NSDate timeIntervalSinceReferenceDate] < deadline) {
        if (clientDisconnected(fd)) {
            @synchronized(lock) {
                if (!completed) {
                    completed = YES;
                    response = responseData(requestID, @{ @"mayStillRun": @YES }, -32000, @"Client disconnected");
                }
            }
            break;
        }
        if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) == 0) break;
    }
    @synchronized(lock) {
        if (!completed) {
            completed = YES;
            response = responseData(requestID, @{ @"kind": @"timeout", @"mayStillRun": @YES }, -32001, @"Request timed out; execution may still finish");
        }
    }
    return response;
}

- (BOOL)writeResponse:(NSData *)response to:(int)fd {
    NSUInteger offset = 0;
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 30;
    while (offset < response.length) {
        if (!waitForSocket(fd, POLLOUT, self, deadline)) return NO;
        ssize_t count = send(fd, (const char *)response.bytes + offset, response.length - offset, 0);
        if (count > 0) offset += count;
        else if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        else return NO;
    }
    return YES;
}

- (void)serveClient:(int)fd {
    NSMutableData *buffer = [NSMutableData data];
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 10;
    while (waitForSocket(fd, POLLIN, self, deadline)) {
        char bytes[8192];
        ssize_t count = recv(fd, bytes, sizeof(bytes), 0);
        if (count <= 0) {
            if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            return;
        }
        [buffer appendBytes:bytes length:(NSUInteger)count];
        while (YES) {
            const char *newline = memchr(buffer.bytes, '\n', buffer.length);
            NSUInteger length = newline ? (NSUInteger)(newline - (const char *)buffer.bytes) : buffer.length;
            if (length > maxRequestBytes) {
                [self writeResponse:responseData(nil, nil, -32600, @"Request exceeds 1 MiB") to:fd];
                return;
            }
            if (!newline) break;
            NSData *line = [buffer subdataWithRange:NSMakeRange(0, length)];
            [buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
            @autoreleasepool {
                BOOL written = [self writeResponse:[self handleLine:line client:fd] to:fd];
                // Close only after the acknowledgement has been written.
                if (self.closeRequested) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (automationServer != self || self.stopped) return;
                        NSWindow *window = self.view.window;
                        BOOL wasVisible = window.visible;
                        TurfAutomationStop();
                        [window close];
                        // AppKit does not trigger last-window termination for a
                        // window that was never ordered onscreen. Honor the host's
                        // termination policy explicitly in that case.
                        if (!wasVisible) {
                            for (NSWindow *other in NSApp.windows) {
                                if (other.visible) return;
                            }
                            id<NSApplicationDelegate> delegate = NSApp.delegate;
                            if ([delegate respondsToSelector:@selector(applicationShouldTerminateAfterLastWindowClosed:)] &&
                                [delegate applicationShouldTerminateAfterLastWindowClosed:NSApp]) [NSApp terminate:nil];
                        }
                    });
                    return;
                }
                if (!written) return;
            }
            deadline = [NSDate timeIntervalSinceReferenceDate] + 10;
        }
    }
}

- (void)serve {
    while (!self.stopped) {
        @autoreleasepool {
            if (!waitForSocket(self.listener, POLLIN, self, [NSDate timeIntervalSinceReferenceDate] + 1)) continue;
            int client = accept(self.listener, NULL, NULL);
            if (client < 0) continue;
            uid_t uid; gid_t gid;
            if (getpeereid(client, &uid, &gid) == 0 && uid == geteuid()) {
                int yes = 1;
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
                fcntl(client, F_SETFL, O_NONBLOCK);
                fcntl(client, F_SETFD, FD_CLOEXEC);
                [self serveClient:client];
            }
            close(client);
        }
    }
    close(self.listener);
    [self removeSocket];
}

- (void)captureRegion:(NSRect)region fullViewport:(BOOL)full generation:(unsigned long long)generation bounds:(NSRect)bounds reply:(AutomationReply)reply {
    WKWebView *view = self.view;
    if (self.stopped || generation != NSMessageGeneration() || !NSEqualRects(view.bounds, bounds)) {
        reply(nil, -32004, @"Page or viewport changed during screenshot; retry"); return;
    }
    WKSnapshotConfiguration *configuration = nil;
    if (!full) {
        configuration = [WKSnapshotConfiguration new];
        NSRect native = region;
        if (!view.isFlipped) native.origin.y = bounds.size.height - NSMaxY(region);
        native.origin.x += bounds.origin.x; native.origin.y += bounds.origin.y;
        configuration.rect = NSRectToCGRect(native);
    }
    // Keep the original nil configuration and PNG encoder for a full capture.
    [view takeSnapshotWithConfiguration:configuration completionHandler:^(NSImage *image, NSError *error) {
        if (self.stopped || view != self.view || generation != NSMessageGeneration() || !NSEqualRects(view.bounds, bounds)) {
            reply(nil, -32004, @"Page or viewport changed during screenshot; retry"); return;
        }
        if (error || !image) { reply(nil, -32002, error.localizedDescription ?: @"Snapshot failed"); return; }
        NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!png) reply(nil, -32002, @"PNG encoding failed");
        else reply(@{ @"format": @"png", @"data": [png base64EncodedStringWithOptions:0],
            @"width": @(bitmap.pixelsWide), @"height": @(bitmap.pixelsHigh), @"region": snapshotRegion(region) }, 0, nil);
    }];
}

- (void)screenshot:(NSDictionary *)params reply:(AutomationReply)reply {
    BOOL hasRect = params[@"rect"] != nil, hasSelector = params[@"selector"] != nil;
    id paddingValue = params[@"padding"];
    if (hasRect && hasSelector) {
        reply(nil, -32602, @"rect and selector are mutually exclusive; provide only one"); return;
    }
    if (paddingValue && !hasRect && !hasSelector) {
        reply(nil, -32602, @"padding requires rect or selector"); return;
    }
    if (paddingValue && (!automationNumber(paddingValue) || [paddingValue doubleValue] < 0)) {
        reply(nil, -32602, @"padding must be a finite nonnegative number"); return;
    }
    double padding = paddingValue ? [paddingValue doubleValue] : 0;
    NSRect bounds = self.view.bounds;
    unsigned long long generation = NSMessageGeneration();
    if (bounds.size.width <= 0 || bounds.size.height <= 0) {
        reply(nil, -32004, @"Viewport has no visible area"); return;
    }
    if (!hasRect && !hasSelector) {
        [self captureRegion:NSMakeRect(0, 0, bounds.size.width, bounds.size.height)
            fullViewport:YES generation:generation bounds:bounds reply:reply];
        return;
    }
    if (hasRect) {
        NSRect requested, region;
        if (!snapshotRect(params[@"rect"], &requested) || !clipSnapshotRect(requested, padding, bounds.size, &region)) {
            reply(nil, -32602, @"rect requires finite x/y and positive width/height, with a nonempty viewport intersection after padding"); return;
        }
        [self captureRegion:region fullViewport:NO generation:generation bounds:bounds reply:reply];
        return;
    }
    NSString *selector = params[@"selector"];
    if (![selector isKindOfClass:NSString.class] || selector.length == 0) {
        reply(nil, -32602, @"selector must be a nonempty CSS selector string"); return;
    }
    if (@available(macOS 11.0, *)) {
        NSString *source = @"let element; try { element = document.querySelector(selector); } catch (_) { return {error:'syntax'}; }"
            @"if (!element) return {error:'missing'}; const r = element.getBoundingClientRect();"
            @"return {rect:{x:r.x,y:r.y,width:r.width,height:r.height},viewport:{width:innerWidth,height:innerHeight}};";
        // Argument passing avoids interpolating selectors into executable script.
        // The isolated world also avoids page overrides of DOM measurement APIs.
        [self.view callAsyncJavaScript:source arguments:@{ @"selector": selector } inFrame:nil
            inContentWorld:[WKContentWorld worldWithName:@"TurfScreenshot"] completionHandler:^(id value, NSError *error) {
            if (error) { reply(nil, -32002, error.localizedDescription); return; }
            if (![value isKindOfClass:NSDictionary.class]) { reply(nil, -32002, @"Could not measure screenshot selector"); return; }
            if ([value[@"error"] isEqual:@"syntax"]) {
                reply(@{ @"selector": selector }, -32602, [NSString stringWithFormat:@"Invalid CSS selector: %@", selector]); return;
            }
            if ([value[@"error"] isEqual:@"missing"]) {
                reply(@{ @"selector": selector }, -32004, [NSString stringWithFormat:@"No element matches selector: %@", selector]); return;
            }
            NSRect measured, region;
            NSDictionary *viewport = value[@"viewport"];
            if (!snapshotRect(value[@"rect"], &measured) || ![viewport isKindOfClass:NSDictionary.class] ||
                !automationNumber(viewport[@"width"]) || !automationNumber(viewport[@"height"]) ||
                [viewport[@"width"] doubleValue] <= 0 || [viewport[@"height"] doubleValue] <= 0) {
                reply(nil, -32602, @"Selected element has no positive screenshot area"); return;
            }
            // DOM coordinates are CSS viewport units; normally these ratios are 1.
            double sx = bounds.size.width / [viewport[@"width"] doubleValue];
            double sy = bounds.size.height / [viewport[@"height"] doubleValue];
            measured.origin.x *= sx; measured.origin.y *= sy;
            measured.size.width *= sx; measured.size.height *= sy;
            if (!clipSnapshotRect(measured, padding, bounds.size, &region)) {
                reply(nil, -32602, @"Selected element has no viewport intersection after padding"); return;
            }
            AutomationReply checkedReply = ^(id image, NSInteger code, NSString *message) {
                if (code) { reply(image, code, message); return; }
                // A snapshot crosses the WebKit process boundary. Detect geometry
                // changes across that interval rather than promising a DOM freeze.
                [self.view callAsyncJavaScript:source arguments:@{ @"selector": selector } inFrame:nil
                    inContentWorld:[WKContentWorld worldWithName:@"TurfScreenshot"] completionHandler:^(id after, NSError *checkError) {
                    if (checkError || self.stopped || generation != NSMessageGeneration() ||
                        !NSEqualRects(self.view.bounds, bounds) || ![after isEqual:value]) {
                        reply(@{ @"selector": selector }, -32004,
                            [NSString stringWithFormat:@"Selector or viewport changed during screenshot; retry: %@", selector]);
                    } else reply(image, 0, nil);
                }];
            };
            [self captureRegion:region fullViewport:NO generation:generation bounds:bounds reply:checkedReply];
        }];
    } else reply(nil, -32000, @"Selector screenshots require macOS 11 or newer");
}

- (void)execute:(NSDictionary *)request reply:(AutomationReply)reply {
    NSString *method = request[@"method"];
    NSDictionary *params = request[@"params"] ?: @{};
    WKWebView *view = self.view;
    if (!view.window.visible && ([@[@"click", @"key", @"typeText"] containsObject:method])) {
        reply(nil, -32004, @"Show the window before sending input"); return;
    }
    if ([method isEqual:@"info"]) {
        reply(@{ @"protocolVersion": @1, @"pid": @(getpid()), @"engine": @"WKWebView",
            @"background": @(self.background), @"window": automationWindowInfo(view.window), @"title": view.title ?: @"", @"url": view.URL.absoluteString ?: @"", @"loading": @(view.loading),
            @"methods": @[@"emit", @"info", @"evaluate", @"navigate", @"screenshot", @"resize", @"diagnostics", @"show", @"screens", @"move", @"click", @"key", @"typeText", @"close"],
            @"capabilities": @{ @"emit": @YES, @"nativeInput": @"appkit", @"windowPosition": @YES, @"deferredShow": @YES, @"structuredErrors": @YES, @"diagnostics": @YES, @"awaitPromises": @YES, @"screenshot": @"viewport", @"screenshotRegion": @YES,
                @"maxRequestBytes": @(maxRequestBytes), @"maxResponseBytes": @(maxResponseBytes) },
            @"viewport": @{ @"width": @(view.bounds.size.width), @"height": @(view.bounds.size.height) } }, 0, nil);
    } else if ([method isEqual:@"diagnostics"]) {
        [self diagnosticsRequest:params reply:reply];
    } else if ([method isEqual:@"show"]) {
        NSShowWindow();
        reply(automationWindowInfo(view.window), 0, nil);
    } else if ([method isEqual:@"screens"]) {
        NSMutableArray *screens = [NSMutableArray array];
        for (NSScreen *screen in NSScreen.screens) [screens addObject:automationScreenInfo(screen)];
        reply(@{ @"screens": screens }, 0, nil);
    } else if ([method isEqual:@"move"]) {
        NSString *screenID = params[@"screen"];
        id x = params[@"x"] ?: @0, y = params[@"y"] ?: @0;
        NSString *anchor = params[@"anchor"] ?: @"top-left";
        if (![screenID isKindOfClass:NSString.class] || !automationNumber(x) || !automationNumber(y) ||
            [x doubleValue] < 0 || [y doubleValue] < 0 ||
            ![anchor isKindOfClass:NSString.class] ||
            ![@[@"top-left", @"top-right", @"bottom-left", @"bottom-right"] containsObject:anchor]) {
            reply(nil, -32602, @"move requires a screen ID, nonnegative x/y offsets in points, and a valid corner anchor"); return;
        }
        NSScreen *selected = nil;
        for (NSScreen *screen in NSScreen.screens) {
            if ([automationScreenID(screen) isEqual:screenID]) { selected = screen; break; }
        }
        if (!selected) { reply(nil, -32602, @"Unknown or disconnected screen; call screens again"); return; }
        NSWindow *window = view.window;
        if (window.styleMask & NSWindowStyleMaskFullScreen) {
            reply(nil, -32004, @"Exit fullscreen before moving the window"); return;
        }
        NSRect work = selected.visibleFrame, frame = window.frame;
        CGFloat maxX = MAX(0, work.size.width - frame.size.width);
        CGFloat maxY = MAX(0, work.size.height - frame.size.height);
        CGFloat left = [anchor hasSuffix:@"right"] ? maxX - [x doubleValue] : [x doubleValue];
        CGFloat top = [anchor hasPrefix:@"bottom"] ? maxY - [y doubleValue] : [y doubleValue];
        left = MIN(maxX, MAX(0, left)); top = MIN(maxY, MAX(0, top));
        [window setFrameOrigin:NSMakePoint(NSMinX(work) + left, NSMaxY(work) - top - frame.size.height)];
        // Moving never activates or raises the window, even in foreground mode.
        reply(automationWindowInfo(window), 0, nil);

    } else if ([method isEqual:@"evaluate"]) {
        if (![params[@"expression"] isKindOfClass:NSString.class]) { reply(nil, -32602, @"expression must be a string"); return; }
        if (@available(macOS 11.0, *)) {
            // Return JSON by value. JSON.stringify errors reject cycles and BigInts explicitly.
            NSString *body = turfEvaluateScript;
            [view callAsyncJavaScript:body arguments:@{ @"expression": params[@"expression"] }
                inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
                if (error) { reply(@{ @"kind": @"native_error", @"nativeDomain": error.domain, @"nativeCode": @(error.code), @"context": @"main" }, -32002, error.localizedDescription); return; }
                NSData *data = [result isKindOfClass:NSString.class] ? [result dataUsingEncoding:NSUTF8StringEncoding] : nil;
                id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (![value isKindOfClass:NSDictionary.class] || ![value[@"ok"] isKindOfClass:NSNumber.class] ||
                    (![value[@"result"] isKindOfClass:NSDictionary.class] && ![value[@"error"] isKindOfClass:NSDictionary.class])) {
                    reply(@{ @"kind": @"serialization_error", @"context": @"main" }, -32003, @"JavaScript result cannot be serialized");
                }
                else if ([value[@"ok"] boolValue]) reply(value[@"result"], 0, nil);
                else {
                    NSDictionary *detail = value[@"error"];
                    NSInteger code = [detail[@"kind"] isEqual:@"serialization_error"] ? -32003 : -32002;
                    NSString *message = [detail[@"message"] isKindOfClass:NSString.class] ? detail[@"message"] : @"JavaScript evaluation failed";
                    reply(detail, code, message);
                }
            }];
        } else reply(nil, -32000, @"Evaluation requires macOS 11 or newer");
    } else if ([method isEqual:@"emit"]) {
        [self emitRequest:params reply:reply];
    } else if ([method isEqual:@"navigate"]) {
        NSString *urlString = params[@"url"];
        NSURL *url = [urlString isKindOfClass:NSString.class] ? [NSURL URLWithString:urlString] : nil;
        if (!url || ![@[@"http", @"https", @"file", @"about"] containsObject:url.scheme.lowercaseString]) {
            reply(nil, -32602, @"url must be an absolute http, https, file, or about URL"); return;
        }
        if (self.navigationReply) { reply(nil, -32004, @"A navigation is already pending"); return; }
        self.navigationReply = reply;
        self.navigation = url.isFileURL
            ? [view loadFileURL:url allowingReadAccessToURL:[url URLByDeletingLastPathComponent]]
            : [view loadRequest:[NSURLRequest requestWithURL:url]];
        WKNavigation *navigation = self.navigation;
        if (!navigation) { self.navigationReply = nil; reply(nil, -32002, @"Navigation could not start"); return; }
        __weak TurfAutomationServer *weakServer = self;
        __weak WKNavigation *weakNavigation = navigation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 29 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            TurfAutomationServer *server = weakServer;
            WKNavigation *expected = weakNavigation;
            if (server && !server.stopped && expected && server.navigation == expected && server.navigationReply) {
                AutomationReply pending = server.navigationReply;
                server.navigationReply = nil; server.navigation = nil;
                [server.view stopLoading];
                pending(nil, -32001, @"Navigation timed out");
            }
        });
    } else if ([method isEqual:@"screenshot"]) {
        [self screenshot:params reply:reply];
    } else if ([method isEqual:@"resize"]) {
        id width = params[@"width"], height = params[@"height"];
        BOOL valid = [width isKindOfClass:NSNumber.class] && [height isKindOfClass:NSNumber.class];
        if (!valid || CFGetTypeID((__bridge CFTypeRef)width) == CFBooleanGetTypeID() ||
            CFGetTypeID((__bridge CFTypeRef)height) == CFBooleanGetTypeID() ||
            [width doubleValue] < 1 || [width doubleValue] > 8192 || [height doubleValue] < 1 || [height doubleValue] > 8192) {
            reply(nil, -32602, @"width and height must be numbers from 1 to 8192"); return;
        }
        [view.window setContentSize:NSMakeSize([width doubleValue], [height doubleValue])];
        [view.window.contentView layoutSubtreeIfNeeded];
        reply(@{ @"width": @(view.bounds.size.width), @"height": @(view.bounds.size.height) }, 0, nil);
    } else if ([method isEqual:@"click"]) {
        id x = params[@"x"], y = params[@"y"];
        NSEventModifierFlags modifiers;
        if (!automationNumber(x) || !automationNumber(y) ||
            !automationModifiers(params[@"modifiers"], &modifiers) ||
            [x doubleValue] < 0 || [y doubleValue] < 0 ||
            [x doubleValue] >= view.bounds.size.width || [y doubleValue] >= view.bounds.size.height) {
            reply(nil, -32602, @"click requires x/y inside the viewport and valid modifiers"); return;
        }
        NSWindow *window = view.window;
        if (!self.background) {
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
        }
        NSPoint point = NSMakePoint([x doubleValue], view.isFlipped ? [y doubleValue] : view.bounds.size.height - [y doubleValue]);
        point = [view convertPoint:point toView:nil];
        NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:modifiers
            timestamp:timestamp windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:modifiers
            timestamp:timestamp + 0.01 windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:0];
        NSView *target = [view hitTest:[view.superview convertPoint:point fromView:nil]];
        [window makeFirstResponder:target];
        [target mouseDown:down];
        [target mouseUp:up];
        reply(@{ @"dispatched": @YES }, 0, nil);
    } else if ([method isEqual:@"key"]) {
        NSString *key = params[@"key"], *characters = nil;
        NSEventModifierFlags modifiers;
        unsigned short code = 0; BOOL function = NO;
        id repeat = params[@"repeat"];
        if (![key isKindOfClass:NSString.class] || !automationKey(key, &characters, &code, &function) ||
            !automationModifiers(params[@"modifiers"], &modifiers) ||
            (repeat && CFGetTypeID((__bridge CFTypeRef)repeat) != CFBooleanGetTypeID())) {
            reply(nil, -32602, @"Unsupported key or modifiers; use typeText for Unicode text"); return;
        }
        if (function) modifiers |= NSEventModifierFlagFunction | NSEventModifierFlagNumericPad;
        if (key.length == 1 && (![key isEqual:key.lowercaseString] || [@"~!@#$%^&*()_+{}|:\"<>?" containsString:key])) {
            modifiers |= NSEventModifierFlagShift;
        }
        if (modifiers & NSEventModifierFlagShift) {
            NSString *unshifted = @"`1234567890-=[]\\;',./";
            NSString *shifted = @"~!@#$%^&*()_+{}|:\"<>?";
            NSRange index = [unshifted rangeOfString:characters];
            characters = characters.length == 1 && index.location != NSNotFound
                ? [shifted substringWithRange:NSMakeRange(index.location, 1)] : characters.uppercaseString;
        }
        NSString *unmodified = characters;
        if ((modifiers & NSEventModifierFlagControl) && characters.length == 1) {
            unichar c = [characters.lowercaseString characterAtIndex:0];
            if (c >= 'a' && c <= 'z') { c -= 'a' - 1; characters = [NSString stringWithCharacters:&c length:1]; }
        }
        NSWindow *window = view.window;
        if (!self.background) {
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
        }
        NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
        for (NSNumber *kind in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
            NSEvent *event = [NSEvent keyEventWithType:kind.unsignedIntegerValue location:NSZeroPoint modifierFlags:modifiers
                timestamp:timestamp windowNumber:window.windowNumber context:nil characters:characters
                charactersIgnoringModifiers:unmodified isARepeat:kind.unsignedIntegerValue == NSEventTypeKeyDown && [repeat boolValue] keyCode:code];
            if (kind.unsignedIntegerValue == NSEventTypeKeyDown) {
                if (!automationMenuKey(NSApp.mainMenu, event, window.firstResponder) &&
                    ![window performKeyEquivalent:event]) [window.firstResponder keyDown:event];
            } else [window.firstResponder keyUp:event];
        }
        reply(@{ @"dispatched": @YES }, 0, nil);
    } else if ([method isEqual:@"typeText"]) {
        NSString *text = params[@"text"];
        if (![text isKindOfClass:NSString.class] || text.length > 16384) {
            reply(nil, -32602, @"text must be a string of at most 16384 UTF-16 code units"); return;
        }
        NSResponder *target = view.window.firstResponder;
        if (![target isKindOfClass:NSView.class] || ![(NSView *)target isDescendantOf:view] ||
            ![target respondsToSelector:@selector(insertText:replacementRange:)]) {
            reply(nil, -32004, @"Focus a text field in the webview first"); return;
        }
        [(id<NSTextInputClient>)target insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
        reply(@{ @"dispatched": @YES }, 0, nil);
    } else if ([method isEqual:@"close"]) {
        self.closeRequested = YES;
        reply(@{ @"closing": @YES }, 0, nil);
    } else reply(nil, -32601, @"Method not found");
}
@end

BOOL TurfAutomationIsBackground(void) { return automationServer.background; }

int TurfAutomationStart(WKWebView *view, const char *path, bool background) {
    if (![NSThread isMainThread] || !view || !view.window) return EINVAL;
    if (automationServer) return EALREADY;
    NSString *socketPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path length:strlen(path)];
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (!socketPath.isAbsolutePath || strlen(path) >= sizeof(address.sun_path)) return EINVAL;
    // A private parent directory protects the socket even before chmod runs.
    struct stat parent;
    if (lstat(socketPath.stringByDeletingLastPathComponent.fileSystemRepresentation, &parent) != 0) return errno;
    if (!S_ISDIR(parent.st_mode) || parent.st_uid != geteuid() || (parent.st_mode & 077) != 0) return EACCES;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return errno;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    address.sun_len = sizeof(address);
    // Never unlink an existing path, including stale sockets.
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { int err = errno; close(fd); return err; }
    struct stat st;
    if (lstat(path, &st) != 0) { int err = errno; close(fd); return err; }
    if (chmod(path, 0600) != 0 || listen(fd, 8) != 0) { int err = errno; close(fd); unlink(path); return err; }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    TurfAutomationServer *server = [TurfAutomationServer new];
    server.background = background;
    server.view = view; server.path = socketPath; server.listener = fd;
    server.socketInode = st.st_ino; server.socketDevice = st.st_dev;
    automationServer = server;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [server serve]; });
    return 0;
}

void TurfAutomationStop(void) {
    TurfAutomationServer *server = automationServer;
    if (!server) return;
    [server stopDiagnostics];
    [server.view evaluateJavaScript:@"window.turf?._clearRetained()" completionHandler:nil];
    [server.retainedTopics removeAllObjects];
    [server updateRetainedScript];
    server.stopped = YES;
    server.navigationReply = nil;
    server.navigation = nil;
    [server removeSocket];
    // The server loop retires on a worker; release its UI reference here on main.
    server.view = nil;
    automationServer = nil;
}

void TurfAutomationNavigationFinished(WKNavigation *navigation, NSError *error) {
    TurfAutomationServer *server = automationServer;
    if (!navigation || server.navigation != navigation || !server.navigationReply) return;
    AutomationReply reply = server.navigationReply;
    server.navigationReply = nil; server.navigation = nil;
    if (error) reply(nil, -32002, error.localizedDescription);
    else reply(@{ @"url": server.view.URL.absoluteString ?: @"" }, 0, nil);
}
