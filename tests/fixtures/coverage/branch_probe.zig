// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 awesomo4000
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
var result: u32 = 0;
noinline fn visited() void {
    @as(*volatile u32, &result).* = 11; // HIT
}
noinline fn skipped() void {
    @as(*volatile u32, &result).* = 22; // MISS
}
pub fn main() void {
    if (getenv("TURF_COVERAGE_TAKE_OTHER") != null) {
        skipped();
    } else {
        visited();
    }
}
