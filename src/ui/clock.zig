//! A monotonic clock in seconds, for frame timing and animations.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn CACurrentMediaTime() f64;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;

pub fn now() f64 {
    switch (builtin.os.tag) {
        .macos => return CACurrentMediaTime(),
        .windows => {
            var c: i64 = 0;
            var f: i64 = 1;
            _ = QueryPerformanceCounter(&c);
            _ = QueryPerformanceFrequency(&f);
            return @as(f64, @floatFromInt(c)) / @as(f64, @floatFromInt(f));
        },
        .wasi => {
            var t: std.os.wasi.timestamp_t = 0;
            _ = std.os.wasi.clock_time_get(.MONOTONIC, 1, &t);
            return @as(f64, @floatFromInt(t)) / 1e9;
        },
        else => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
        },
    }
}
