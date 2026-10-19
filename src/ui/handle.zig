//! Handles, after mygo's `ui.Handle`: a control known to the app across
//! frames, to move the keyboard's focus to it from code (a search field
//! focused by ⌘F, the first field of a form that opens). Bind it to the
//! control's interaction every frame; a request made before the control
//! shows waits for it.
//!
//!     // In the app's state:
//!     search: ui.Handle = .{},
//!
//!     const it = ui.button(c, "Find", .{});
//!     s.search.bind(c, it);
//!     if (c.shortcut(.{ .key = 'f', .cmd = true })) s.search.focus();
const std = @import("std");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Interaction = ctx_mod.Interaction;

pub const Handle = struct {
    /// The control's id as last bound, 0 before.
    id: u64 = 0,
    /// The frame it was last bound in: a control not built goes hidden.
    frame: u64 = std.math.maxInt(u64),
    requested: bool = false,
    /// The ring shows, as when Tab moves the focus.
    visible: bool = true,

    /// Gives the handle the control of `it` in this frame, and the focus
    /// asked for it.
    pub fn bind(h: *Handle, c: *Context, it: Interaction) void {
        h.bindId(c, it.id);
    }

    pub fn bindId(h: *Handle, c: *Context, id: u64) void {
        h.id = id;
        h.frame = c.frame;
        if (!h.requested) return;
        h.requested = false;
        if (c.focus != id) {
            c.focus = id;
            c.focus_visible = h.visible;
            // The control was built before it had the focus: again.
            c.changed = true;
        }
    }

    /// Moves the focus to the control in the next frame it is built.
    pub fn focus(h: *Handle) void {
        h.requested = true;
    }

    pub fn cancelFocus(h: *Handle) void {
        h.requested = false;
    }

    /// Whether the control has the focus.
    pub fn focused(h: *const Handle, c: *const Context) bool {
        return h.id != 0 and c.focus == h.id;
    }

    /// Whether the control was built in the last frame.
    pub fn shown(h: *const Handle, c: *const Context) bool {
        return h.frame != std.math.maxInt(u64) and h.frame + 1 >= c.frame;
    }
};

test "a request waits for the control, then focuses it" {
    const ui = @import("ui.zig");
    const App = struct {
        h: Handle = .{},
        show: bool = false,
        fn view(s: *@This(), c: *Context) void {
            ui.column(c, .{});
            defer ui.end(c);
            _ = ui.button(c, "Other", .{});
            if (s.show) s.h.bind(c, ui.button(c, "Target", .{}));
        }
    };
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, App.view), .{});
    defer t.deinit();
    s.h.focus();
    t.frame();
    try std.testing.expectEqual(@as(u64, 0), t.ctx.focus);
    try std.testing.expect(!s.h.shown(&t.ctx));
    s.show = true;
    t.frame();
    try std.testing.expect(s.h.focused(&t.ctx));
    try std.testing.expect(t.ctx.focus_visible);
    try std.testing.expect(s.h.shown(&t.ctx));
    // Enter clicks it, as the focused control.
    t.key(.enter);
    try std.testing.expect(s.h.focused(&t.ctx));
}
