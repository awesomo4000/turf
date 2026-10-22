// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
// Passive foreground observer. Creates no application or window and never activates.
#import <Cocoa/Cocoa.h>

static void record(NSRunningApplication *app, NSString *source) {
    NSDictionary *entry = @{ @"pid": @(app.processIdentifier),
        @"name": app.localizedName ?: @"", @"source": source,
        @"time": @(NSDate.date.timeIntervalSince1970) };
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

int main(void) {
    @autoreleasepool {
        NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
        __block pid_t previous = workspace.frontmostApplication.processIdentifier;
        [workspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
                previous = app.processIdentifier;
                record(app, @"activation");
            }];
        record(workspace.frontmostApplication, @"initial");
        // Sampling also catches changes if a workspace notification is delayed.
        [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) {
            NSRunningApplication *app = workspace.frontmostApplication;
            if (app.processIdentifier != previous) {
                previous = app.processIdentifier;
                record(app, @"sample");
            }
        }];
        [NSRunLoop.mainRunLoop run];
    }
}
