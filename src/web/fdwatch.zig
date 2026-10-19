//! Watching file descriptors: a browser has no processes or descriptors
//! to wait on.
pub const Handler = *const fn (ctx: ?*anyopaque) callconv(.c) void;

pub const Watch = struct {
    pub fn cancel(_: Watch) void {}
};

pub fn readable(fd: anytype, ctx: ?*anyopaque, handler: Handler) !Watch {
    _ = fd;
    _ = ctx;
    _ = handler;
    return error.Unsupported;
}

pub fn exited(pid: anytype, ctx: ?*anyopaque, handler: Handler) !Watch {
    _ = pid;
    _ = ctx;
    _ = handler;
    return error.Unsupported;
}
