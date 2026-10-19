//! Dialogs in a browser: messages ask with `alert` and `confirm`; the
//! browser has no file dialogs that give paths, so `open` and `save`
//! report so.
const std = @import("std");
const js = @import("js.zig");
const dialog_types = @import("../dialog_types.zig");

pub const OpenOptions = dialog_types.OpenOptions;
pub const SaveOptions = dialog_types.SaveOptions;
pub const MessageKind = dialog_types.MessageKind;
pub const MessageOptions = dialog_types.MessageOptions;
pub const MessageResult = dialog_types.MessageResult;
pub const freePaths = dialog_types.freePaths;

pub fn open(_: std.mem.Allocator, _: OpenOptions) !?[][]u8 {
    return error.Unsupported;
}

pub fn save(_: std.mem.Allocator, _: SaveOptions) !?[]u8 {
    return error.Unsupported;
}

/// `alert` for one button, else `confirm`: OK is the first button,
/// Cancel the last.
pub fn message(opts: MessageOptions) MessageResult {
    var buf: [2048]u8 = undefined;
    const body = if (opts.detail.len > 0) std.fmt.bufPrint(&buf, "{s}\n\n{s}", .{ opts.title, opts.detail }) catch opts.title else opts.title;
    const n: u32 = @intCast(@max(1, opts.buttons.len));
    const pressed = js.message(body.ptr, body.len, n);
    return .{ .button = if (pressed == 0) 0 else n - 1 };
}
