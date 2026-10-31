// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
#import <WebKit/WebKit.h>
int TurfAutomationStart(WKWebView *view, const char *path, bool background);
void TurfAutomationStop(void);
void TurfAutomationNavigationFinished(WKNavigation *navigation, NSError *error);
BOOL TurfAutomationIsBackground(void);

void NSShowWindow(void);
