// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
#pragma once
#include <stdbool.h>
int turf_linux_automation_start(void *view, void *window, const char *path, bool background);
void turf_linux_automation_stop(void);
void turf_linux_show_window(void *window, bool no_focus);
