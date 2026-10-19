//! The system's notifications that something changed under a directory:
//! only hints, after which a watch looks again. ReadDirectoryChangesW on
//! Windows, inotify on Linux, FSEvents on macOS. Each runs on a thread
//! of its own (FSEvents on a dispatch queue) and calls `Notify`.
const builtin = @import("builtin");

pub const Notify = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const Hints = switch (builtin.os.tag) {
    .windows => @import("hints_windows.zig").Hints,
    .linux => @import("hints_linux.zig").Hints,
    .macos => @import("hints_macos.zig").Hints,
    else => @compileError("watch: macOS, Linux and Windows only"),
};
