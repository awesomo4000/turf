// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
#import <Cocoa/Cocoa.h>
#import "automation.h"
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
typedef void (^AutomationReply)(id result, NSInteger code, NSString *message);

@interface TurfAutomationServer : NSObject
@property (atomic) BOOL stopped;
@property (atomic) BOOL closeRequested;
@property (nonatomic, strong) WKWebView *view;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) int listener;
@property (nonatomic) ino_t socketInode;
@property (nonatomic) dev_t socketDevice;
@property (nonatomic, strong) WKNavigation *navigation;
@property (nonatomic, copy) AutomationReply navigationReply;
- (void)serve;
- (void)execute:(NSDictionary *)request reply:(AutomationReply)reply;
- (void)removeSocket;
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

static NSData *responseData(id requestID, id result, NSInteger code, NSString *message) {
    NSDictionary *response = code
        ? @{ @"jsonrpc": @"2.0", @"id": requestID ?: NSNull.null,
             @"error": @{ @"code": @(code), @"message": message ?: @"Request failed" } }
        : @{ @"jsonrpc": @"2.0", @"id": requestID ?: NSNull.null, @"result": result ?: NSNull.null };
    NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (!json || json.length > maxResponseBytes) {
        return responseData(requestID, nil, -32003, @"Result is not JSON-serializable or exceeds 32 MiB");
    }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    return line;
}

// Coordinates are webview points from the top-left, independent of screen scale.
static BOOL automationNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
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
- (void)removeSocket {
    struct stat st;
    if (lstat(self.path.fileSystemRepresentation, &st) == 0 && S_ISSOCK(st.st_mode)
        && st.st_ino == self.socketInode && st.st_dev == self.socketDevice) {
        unlink(self.path.fileSystemRepresentation);
    }
}

- (NSData *)handleLine:(NSData *)line {
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
        if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) == 0) break;
    }
    @synchronized(lock) {
        if (!completed) {
            completed = YES;
            response = responseData(requestID, nil, -32001, @"Request timed out; execution may still finish");
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
                if (![self writeResponse:[self handleLine:line] to:fd]) return;
                // Close only after the acknowledgement has been written.
                if (self.closeRequested) {
                    dispatch_async(dispatch_get_main_queue(), ^{ TurfAutomationStop(); [self.view.window close]; });
                    return;
                }
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

- (void)execute:(NSDictionary *)request reply:(AutomationReply)reply {
    NSString *method = request[@"method"];
    NSDictionary *params = request[@"params"] ?: @{};
    WKWebView *view = self.view;
    if ([method isEqual:@"info"]) {
        reply(@{ @"protocolVersion": @1, @"pid": @(getpid()), @"engine": @"WKWebView",
            @"title": view.title ?: @"", @"url": view.URL.absoluteString ?: @"", @"loading": @(view.loading),
            @"methods": @[@"info", @"evaluate", @"navigate", @"screenshot", @"resize", @"click", @"key", @"typeText", @"close"],
            @"capabilities": @{ @"nativeInput": @"appkit", @"awaitPromises": @YES, @"screenshot": @"viewport",
                @"maxRequestBytes": @(maxRequestBytes), @"maxResponseBytes": @(maxResponseBytes) },
            @"viewport": @{ @"width": @(view.bounds.size.width), @"height": @(view.bounds.size.height) } }, 0, nil);
    } else if ([method isEqual:@"evaluate"]) {
        if (![params[@"expression"] isKindOfClass:NSString.class]) { reply(nil, -32602, @"expression must be a string"); return; }
        if (@available(macOS 11.0, *)) {
            // Return JSON by value. JSON.stringify errors reject cycles and BigInts explicitly.
            NSString *body = @"const value = await (0, eval)(expression); return JSON.stringify({type: value === null ? 'null' : typeof value, value});";
            [view callAsyncJavaScript:body arguments:@{ @"expression": params[@"expression"] }
                inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
                if (error) { reply(nil, -32002, error.localizedDescription); return; }
                NSData *data = [result isKindOfClass:NSString.class] ? [result dataUsingEncoding:NSUTF8StringEncoding] : nil;
                id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (!value) reply(nil, -32003, @"JavaScript result cannot be serialized");
                else reply(value, 0, nil);
            }];
        } else reply(nil, -32000, @"Evaluation requires macOS 11 or newer");
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 29 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (self.navigation == navigation && self.navigationReply) {
                AutomationReply pending = self.navigationReply;
                self.navigationReply = nil; self.navigation = nil;
                [view stopLoading];
                pending(nil, -32001, @"Navigation timed out");
            }
        });
    } else if ([method isEqual:@"screenshot"]) {
        [view takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image, NSError *error) {
            if (error || !image) { reply(nil, -32002, error.localizedDescription ?: @"Snapshot failed"); return; }
            NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
            NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            if (!png) reply(nil, -32002, @"PNG encoding failed");
            else reply(@{ @"format": @"png", @"data": [png base64EncodedStringWithOptions:0],
                @"width": @(bitmap.pixelsWide), @"height": @(bitmap.pixelsHigh) }, 0, nil);
        }];
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
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        NSPoint point = NSMakePoint([x doubleValue], view.isFlipped ? [y doubleValue] : view.bounds.size.height - [y doubleValue]);
        point = [view convertPoint:point toView:nil];
        NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:modifiers
            timestamp:timestamp windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:modifiers
            timestamp:timestamp + 0.01 windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:0];
        // Queue mouse-up first so native controls with tracking loops can consume it.
        [NSApp postEvent:up atStart:NO];
        [NSApp sendEvent:down];
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
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
        for (NSNumber *kind in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
            NSEvent *event = [NSEvent keyEventWithType:kind.unsignedIntegerValue location:NSZeroPoint modifierFlags:modifiers
                timestamp:timestamp windowNumber:window.windowNumber context:nil characters:characters
                charactersIgnoringModifiers:unmodified isARepeat:kind.unsignedIntegerValue == NSEventTypeKeyDown && [repeat boolValue] keyCode:code];
            [NSApp sendEvent:event];
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

int TurfAutomationStart(WKWebView *view, const char *path) {
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
    server.view = view; server.path = socketPath; server.listener = fd;
    server.socketInode = st.st_ino; server.socketDevice = st.st_dev;
    automationServer = server;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [server serve]; });
    return 0;
}

void TurfAutomationStop(void) {
    TurfAutomationServer *server = automationServer;
    if (!server) return;
    server.stopped = YES;
    server.navigationReply = nil;
    server.navigation = nil;
    [server removeSocket];
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
