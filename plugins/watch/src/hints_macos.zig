//! Hints on macOS: one FSEvents stream covering everything beneath the
//! directory (no descriptor per file), with file-level events, on a serial
//! dispatch queue of its own.
const std = @import("std");
const Notify = @import("hints.zig").Notify;

const CFAllocator = opaque {};
const CFString = opaque {};
const CFArray = opaque {};
const Stream = opaque {};
const Queue = opaque {};
const Callback = *const fn (stream: *Stream, info: ?*anyopaque, n: usize, paths: *anyopaque, flags: [*]const u32, ids: [*]const u64) callconv(.c) void;
const Context = extern struct {
    version: isize = 0,
    info: ?*anyopaque,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copy_description: ?*const anyopaque = null,
};

extern "c" fn CFStringCreateWithBytes(alloc: ?*CFAllocator, bytes: [*]const u8, len: isize, encoding: u32, external: u8) ?*CFString;
extern "c" fn CFArrayCreate(alloc: ?*CFAllocator, values: [*]const ?*const anyopaque, n: isize, callbacks: ?*const anyopaque) ?*CFArray;
extern "c" fn CFRelease(obj: *const anyopaque) void;
extern "c" const kCFTypeArrayCallBacks: opaque {};
extern "c" fn FSEventStreamCreate(alloc: ?*CFAllocator, cb: Callback, ctx: *Context, paths: *CFArray, since: u64, latency: f64, flags: u32) ?*Stream;
extern "c" fn FSEventStreamSetDispatchQueue(stream: *Stream, queue: ?*Queue) void;
extern "c" fn FSEventStreamStart(stream: *Stream) u8;
extern "c" fn FSEventStreamStop(stream: *Stream) void;
extern "c" fn FSEventStreamInvalidate(stream: *Stream) void;
extern "c" fn FSEventStreamRelease(stream: *Stream) void;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*Queue;
extern "c" fn dispatch_release(obj: *anyopaque) void;

const utf8: u32 = 0x08000100;
const since_now: u64 = 0xFFFFFFFFFFFFFFFF;
// kFSEventStreamCreateFlagNoDefer | WatchRoot | FileEvents
const flags: u32 = 0x2 | 0x4 | 0x10;

pub const Hints = struct {
    gpa: std.mem.Allocator,
    stream: *Stream,
    queue: *Queue,
    notify: Notify,
    ctx: Context = .{ .info = null },

    pub fn start(gpa: std.mem.Allocator, io: std.Io, path: []const u8, recursive: bool, notify: Notify) !*Hints {
        _ = io;
        _ = recursive; // the stream covers the tree; the scan decides what counts
        const h = try gpa.create(Hints);
        errdefer gpa.destroy(h);
        const str = CFStringCreateWithBytes(null, path.ptr, @intCast(path.len), utf8, 0) orelse return error.Unexpected;
        defer CFRelease(str);
        const values = [_]?*const anyopaque{str};
        const arr = CFArrayCreate(null, &values, 1, &kCFTypeArrayCallBacks) orelse return error.Unexpected;
        defer CFRelease(arr);
        const queue = dispatch_queue_create("myzig.watch", null) orelse return error.Unexpected;
        h.* = .{ .gpa = gpa, .stream = undefined, .queue = queue, .notify = notify };
        h.ctx.info = h;
        h.stream = FSEventStreamCreate(null, callback, &h.ctx, arr, since_now, 0.0, flags) orelse {
            dispatch_release(queue);
            return error.Unexpected;
        };
        FSEventStreamSetDispatchQueue(h.stream, queue);
        if (FSEventStreamStart(h.stream) == 0) {
            FSEventStreamInvalidate(h.stream);
            FSEventStreamRelease(h.stream);
            dispatch_release(queue);
            return error.Unexpected;
        }
        return h;
    }

    pub fn refresh(_: *Hints, _: []const []const u8) void {}

    pub fn stop(h: *Hints) void {
        // After Invalidate, no callback runs any more.
        FSEventStreamStop(h.stream);
        FSEventStreamInvalidate(h.stream);
        FSEventStreamRelease(h.stream);
        dispatch_release(h.queue);
        h.gpa.destroy(h);
    }

    fn callback(_: *Stream, info: ?*anyopaque, _: usize, _: *anyopaque, _: [*]const u32, _: [*]const u64) callconv(.c) void {
        const h: *Hints = @ptrCast(@alignCast(info));
        h.notify.func(h.notify.ctx);
    }
};
