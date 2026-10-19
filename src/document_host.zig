//! What documents need from the app, and the questions they ask.
//!
//! `Host` is the app as documents see it: its dialogs, timers, windows,
//! file watches and recent documents. `document_app.zig` makes one from a
//! `myzig.App`; tests make their own, which answer questions as a script
//! says and run timers when the test says, so no dialog shows and no test
//! waits on the clock.
const std = @import("std");
const builtin = @import("builtin");
const dialog_types = @import("dialog_types.zig");

pub const MessageOptions = dialog_types.MessageOptions;
pub const SaveOptions = dialog_types.SaveOptions;
pub const OpenOptions = dialog_types.OpenOptions;

/// A timer's callback: documents keep their own timers' generations, so a
/// timer that fires late does nothing.
pub const TimerFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;

/// A file watch, canceled with `Host.unwatch`.
pub const WatchId = u32;

pub fn Host(comptime Window: type) type {
    return struct {
        const Self = @This();
        ctx: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            /// Asks a question (of `parent`'s window: a sheet on macOS);
            /// returns the index of the button chosen.
            message: *const fn (ctx: *anyopaque, parent: ?*Window, opts: MessageOptions) usize,
            /// Asks where to save; a path owned by `gpa`, or null if canceled.
            save_path: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, parent: ?*Window, opts: SaveOptions) ?[]u8,
            /// Asks which files to open; paths owned by `gpa`, or null.
            open_paths: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, opts: OpenOptions) ?[][]u8,
            /// Calls `func(arg)` on the main thread after `ms` milliseconds.
            after: *const fn (ctx: *anyopaque, ms: u64, arg: ?*anyopaque, func: TimerFn) void,
            set_title: *const fn (ctx: *anyopaque, w: *Window, title: []const u8) void,
            /// Closes the window without asking (documents asked already).
            close_window: *const fn (ctx: *anyopaque, w: *Window) void,
            focus_window: *const fn (ctx: *anyopaque, w: *Window) void,
            /// The focused window, for the File menu's items.
            focused_window: *const fn (ctx: *anyopaque) ?*Window,
            /// Calls `func(arg)` on the main thread when `path` (or its
            /// folder) may have changed; null when it can't be watched.
            watch: *const fn (ctx: *anyopaque, path: []const u8, arg: ?*anyopaque, func: TimerFn) ?WatchId,
            unwatch: *const fn (ctx: *anyopaque, id: WatchId) void,
            /// Records a file in Open Recent (and the system's list).
            add_recent: *const fn (ctx: *anyopaque, path: []const u8) void,
            /// Quits the app, once documents are taken care of.
            quit: *const fn (ctx: *anyopaque) void,
        };

        pub fn message(h: Self, parent: ?*Window, opts: MessageOptions) usize {
            return h.vtable.message(h.ctx, parent, opts);
        }
        pub fn savePath(h: Self, gpa: std.mem.Allocator, parent: ?*Window, opts: SaveOptions) ?[]u8 {
            return h.vtable.save_path(h.ctx, gpa, parent, opts);
        }
        pub fn openPaths(h: Self, gpa: std.mem.Allocator, opts: OpenOptions) ?[][]u8 {
            return h.vtable.open_paths(h.ctx, gpa, opts);
        }
        pub fn after(h: Self, ms: u64, arg: ?*anyopaque, func: TimerFn) void {
            h.vtable.after(h.ctx, ms, arg, func);
        }
        pub fn setTitle(h: Self, w: *Window, title: []const u8) void {
            h.vtable.set_title(h.ctx, w, title);
        }
        pub fn closeWindow(h: Self, w: *Window) void {
            h.vtable.close_window(h.ctx, w);
        }
        pub fn focusWindow(h: Self, w: *Window) void {
            h.vtable.focus_window(h.ctx, w);
        }
        pub fn focusedWindow(h: Self) ?*Window {
            return h.vtable.focused_window(h.ctx);
        }
        pub fn watch(h: Self, path: []const u8, arg: ?*anyopaque, func: TimerFn) ?WatchId {
            return h.vtable.watch(h.ctx, path, arg, func);
        }
        pub fn unwatch(h: Self, id: WatchId) void {
            h.vtable.unwatch(h.ctx, id);
        }
        pub fn addRecent(h: Self, path: []const u8) void {
            h.vtable.add_recent(h.ctx, path);
        }
        pub fn quit(h: Self) void {
            h.vtable.quit(h.ctx);
        }
    };
}

/// The words documents show, in English; an app that shows another
/// language gives its own (`DocumentsOptions.strings`). `{s}` is a
/// document's name, `{d}` a count.
pub const Strings = struct {
    untitled: []const u8 = "Untitled",
    copy_suffix: []const u8 = "copy",
    save: []const u8 = "Save",
    save_ellipsis: []const u8 = "Save…",
    dont_save: []const u8 = "Don't Save",
    delete: []const u8 = "Delete",
    cancel: []const u8 = "Cancel",
    save_all: []const u8 = "Save All",
    save_anyway: []const u8 = "Save Anyway",
    revert: []const u8 = "Revert",
    save_changes: []const u8 = "Do you want to save the changes made to the document “{s}”?",
    changes_lost: []const u8 = "Your changes will be lost if you don't save them.",
    keep_new: []const u8 = "Do you want to keep this new document “{s}”?",
    keep_new_detail: []const u8 = "You can choose to save your changes, or delete this document immediately. You can't undo this action.",
    save_many: []const u8 = "Do you want to save the changes made to {d} documents?",
    changed_on_disk: []const u8 = "The file “{s}” was changed by another application.",
    changed_on_disk_detail: []const u8 = "Do you want to save this version anyway, or revert to the one on the disk?",
    read_only: []const u8 = "The file “{s}” can't be written: save it as another file.",
    save_as: []const u8 = "Save As",
    open: []const u8 = "Open",
    cant_save: []const u8 = "The document “{s}” could not be saved.",
};

/// The buttons of a question about saving, in the order each platform
/// lays them out: macOS puts the first rightmost, the second left of it
/// and the third apart on the left (Save, Cancel, Don't Save).
pub const SaveButtons = struct {
    labels: [3][]const u8,
    save: usize,
    discard: usize,
    cancel: usize,

    pub fn of(save: []const u8, discard: []const u8, cancel: []const u8) SaveButtons {
        if (builtin.os.tag == .macos) return .{ .labels = .{ save, cancel, discard }, .save = 0, .discard = 2, .cancel = 1 };
        return .{ .labels = .{ save, discard, cancel }, .save = 0, .discard = 1, .cancel = 2 };
    }
};

/// What the user answered a question about saving.
pub const Answer = enum { save, discard, cancel };

pub fn answerOf(b: SaveButtons, index: usize) Answer {
    if (index == b.save) return .save;
    if (index == b.discard) return .discard;
    return .cancel;
}

/// Replaces the first `{s}` (or `{d}`) of `template` with `arg`.
pub fn fill(gpa: std.mem.Allocator, template: []const u8, arg: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, template, "{s}") orelse std.mem.indexOf(u8, template, "{d}") orelse return template;
    return std.mem.concat(gpa, u8, &.{ template[0..at], arg, template[at + 3 ..] }) catch template;
}

test "questions' buttons and words" {
    const b = SaveButtons.of("Save", "Don't Save", "Cancel");
    try std.testing.expectEqual(Answer.save, answerOf(b, b.save));
    try std.testing.expectEqual(Answer.discard, answerOf(b, b.discard));
    try std.testing.expectEqual(Answer.cancel, answerOf(b, b.cancel));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s: Strings = .{};
    try std.testing.expectEqualStrings("Do you want to save the changes made to the document “a.md”?", fill(arena.allocator(), s.save_changes, "a.md"));
    try std.testing.expectEqualStrings("Do you want to save the changes made to 3 documents?", fill(arena.allocator(), s.save_many, "3"));
}
