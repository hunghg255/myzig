//! Clocks for the hill-climb on every platform: a monotonic clock for
//! frames, the process's CPU time, and the wall clock for the history.
const std = @import("std");
const builtin = @import("builtin");

const os = builtin.os.tag;

const win = struct {
    const FILETIME = extern struct { low: u32, high: u32 };
    extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) c_int;
    extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) c_int;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "kernel32" fn GetProcessTimes(p: *anyopaque, created: *FILETIME, exited: *FILETIME, kernel: *FILETIME, user: *FILETIME) callconv(.winapi) c_int;
    extern "kernel32" fn GetSystemTimeAsFileTime(t: *FILETIME) callconv(.winapi) void;

    /// 100-nanosecond intervals.
    fn ticks(t: FILETIME) u64 {
        return @as(u64, t.high) << 32 | t.low;
    }
};

extern "c" fn CACurrentMediaTime() f64;

fn timespecSeconds(ts: std.c.timespec) f64 {
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

/// Seconds on a monotonic clock.
pub fn now() f64 {
    switch (os) {
        .macos => return CACurrentMediaTime(),
        .windows => {
            var c: i64 = 0;
            var f: i64 = 1;
            _ = win.QueryPerformanceCounter(&c);
            _ = win.QueryPerformanceFrequency(&f);
            return @as(f64, @floatFromInt(c)) / @as(f64, @floatFromInt(f));
        },
        else => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
            return timespecSeconds(ts);
        },
    }
}

/// The process's CPU time (user + system) in seconds, every thread's.
pub fn cpuSeconds() f64 {
    if (os == .windows) {
        var created: win.FILETIME = undefined;
        var exited: win.FILETIME = undefined;
        var kernel: win.FILETIME = undefined;
        var user: win.FILETIME = undefined;
        _ = win.GetProcessTimes(win.GetCurrentProcess(), &created, &exited, &kernel, &user);
        return @as(f64, @floatFromInt(win.ticks(kernel) + win.ticks(user))) / 1e7;
    }
    var ru: std.c.rusage = undefined;
    _ = std.c.getrusage(0, &ru);
    const tv = struct {
        fn s(t: anytype) f64 {
            return @as(f64, @floatFromInt(t.sec)) + @as(f64, @floatFromInt(t.usec)) / 1e6;
        }
    }.s;
    return tv(ru.utime) + tv(ru.stime);
}

/// Seconds since the Unix epoch.
pub fn unixSeconds() u64 {
    if (os == .windows) {
        var t: win.FILETIME = undefined;
        win.GetSystemTimeAsFileTime(&t);
        // FILETIME counts from 1601.
        return (win.ticks(t) - 116444736000000000) / 10_000_000;
    }
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}
