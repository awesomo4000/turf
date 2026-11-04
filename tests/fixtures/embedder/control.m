// SPDX-License-Identifier: MPL-2.0
// Test-only host controls, independent of the automation socket being tested.
#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <libproc.h>
#include <stdlib.h>
static NSTimer *controlTimer;
extern void embedderTestCommand(const char *command);
void TestInstallControl(const char *path) {
    NSString *file = [NSString stringWithUTF8String:path];
    controlTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) {
        NSString *command = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
        if (!command) return;
        embedderTestCommand(command.UTF8String);
        [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
    }];
}
void TestRemoveControl(void) { [controlTimer invalidate]; controlTimer = nil; }
void TestClose(void) { [NSApp terminate:nil]; }
void TestResources(void) {
    @autoreleasepool {
    thread_act_array_t threads; mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) == KERN_SUCCESS) {
        for (unsigned i = 0; i < count; i++) mach_port_deallocate(mach_task_self(), threads[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    }
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    fprintf(stderr, "RESOURCES windows=%lu threads=%u fds=%d\n", (unsigned long)NSApp.windows.count,
            count, bytes / (int)sizeof(struct proc_fdinfo));
    }
}
