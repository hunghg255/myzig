//! Actions: the commands of an app, named once with their title, key
//! combination, icon and state, and offered wherever they show: as key
//! combinations, menu items (with their shortcut shown and grayed out
//! while disabled) and buttons. What chose an action does not matter to
//! the app, which answers one `switch`:
//!
//!     const Cmd = enum { new, save, wrap };
//!     var acts: ui.Actions(Cmd) = .init(.{
//!         .new = .{ .title = "New", .shortcut = .{ .key = 'n', .cmd = true } },
//!         .save = .{ .title = "Save", .shortcut = .{ .key = 's', .cmd = true } },
//!         .wrap = .{ .title = "Wrap Lines", .checked = false },
//!     });
//!
//!     acts.setEnabled(.save, s.dirty);
//!     if (acts.button(c, .save, .{})) s.save();
//!     if (ui.menuButton(c, "File", &s.file_menu, .{})) |m| {
//!         defer m.end();
//!         if (acts.menuItem(m, .new)) s.new();
//!     }
//!     if (acts.shortcuts(c)) |cmd| switch (cmd) { .new => s.new(), .save => s.save(), .wrap => s.toggleWrap() };
const std = @import("std");
const ctx_mod = @import("context.zig");
const widgets = @import("widgets.zig");
const menu = @import("menu.zig");
const Context = ctx_mod.Context;
const Shortcut = ctx_mod.Shortcut;

pub const Action = struct {
    title: []const u8,
    shortcut: ?Shortcut = null,
    /// An SF Symbol (or line icon) for its menu item and button.
    icon: []const u8 = "",
    enabled: bool = true,
    /// A check mark in menus while true (and room for one while false).
    checked: ?bool = null,
};

/// The actions of an app, one for each tag of the enum `E`.
pub fn Actions(comptime E: type) type {
    return struct {
        const Self = @This();
        list: std.EnumArray(E, Action),
        /// The action chosen last (by any way), for the frame after.
        last: ?E = null,

        pub fn init(defs: std.enums.EnumFieldStruct(E, Action, null)) Self {
            return .{ .list = .init(defs) };
        }

        pub fn get(a: *Self, e: E) *Action {
            return a.list.getPtr(e);
        }

        pub fn setEnabled(a: *Self, e: E, on: bool) void {
            a.list.getPtr(e).enabled = on;
        }

        pub fn setChecked(a: *Self, e: E, on: bool) void {
            a.list.getPtr(e).checked = on;
        }

        fn chose(a: *Self, c: *Context, e: E) E {
            a.last = e;
            c.changed = true;
            return e;
        }

        /// The enabled action whose key combination this event is, taken.
        /// Call it after the widgets that take keys (a focused field's
        /// own ⌘A comes first) and before nothing else claims it.
        pub fn shortcuts(a: *Self, c: *Context) ?E {
            if (c.input.shortcut == null) return null;
            for (std.enums.values(E)) |e| {
                const act = a.list.get(e);
                if (!act.enabled) continue;
                const s = act.shortcut orelse continue;
                if (c.shortcut(s)) return a.chose(c, e);
            }
            return null;
        }

        /// The action's item in an open menu, with its key combination
        /// shown: true in the frame it is chosen.
        pub fn menuItem(a: *Self, p: *menu.MenuPanel, e: E) bool {
            const act = a.list.get(e);
            const shown = if (act.shortcut) |s| label(p.c, s) else "";
            if (!p.item(act.title, .{ .shortcut = shown, .checked = act.checked, .disabled = !act.enabled, .icon = act.icon })) return false;
            _ = a.chose(p.c, e);
            return true;
        }

        /// A button for the action, disabled with it.
        pub fn button(a: *Self, c: *Context, e: E, opts: widgets.ButtonOptions) bool {
            const act = a.list.get(e);
            var o = opts;
            o.disabled = opts.disabled or !act.enabled;
            if (o.icon.len == 0) o.icon = act.icon;
            if (!widgets.button(c, act.title, o).clicked) return false;
            _ = a.chose(c, e);
            return true;
        }
    };
}

const mac = @import("keys.zig").mac;

/// A key combination as this platform writes it (⇧⌘S on the Mac,
/// Ctrl+Shift+S elsewhere), in the frame's memory.
pub fn label(c: *Context, s: Shortcut) []const u8 {
    var buf: [64]u8 = undefined;
    const out = write(&buf, s.native());
    return c.alloc().dupe(u8, out) catch "";
}

/// Writes `s` (already as the platform has it) into `buf`.
pub fn write(buf: []u8, s: Shortcut) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (mac) {
        if (s.ctrl) w.writeAll("⌃") catch {};
        if (s.alt) w.writeAll("⌥") catch {};
        if (s.shift) w.writeAll("⇧") catch {};
        if (s.cmd) w.writeAll("⌘") catch {};
    } else {
        if (s.ctrl) w.writeAll("Ctrl+") catch {};
        if (s.alt) w.writeAll("Alt+") catch {};
        if (s.shift) w.writeAll("Shift+") catch {};
        if (s.cmd) w.writeAll("Win+") catch {};
    }
    switch (s.key) {
        Shortcut.up => w.writeAll("↑") catch {},
        Shortcut.down => w.writeAll("↓") catch {},
        Shortcut.left => w.writeAll("←") catch {},
        Shortcut.right => w.writeAll("→") catch {},
        Shortcut.escape => w.writeAll(if (mac) "⎋" else "Esc") catch {},
        Shortcut.tab => w.writeAll(if (mac) "⇥" else "Tab") catch {},
        Shortcut.enter => w.writeAll(if (mac) "↩" else "Enter") catch {},
        ' ' => w.writeAll("Space") catch {},
        else => |k| {
            var b: [4]u8 = undefined;
            const up: u21 = if (k < 128) std.ascii.toUpper(@intCast(k)) else k;
            const n = std.unicode.utf8Encode(up, &b) catch 0;
            w.writeAll(b[0..n]) catch {};
        },
    }
    return w.buffered();
}

test "labels of key combinations" {
    var buf: [64]u8 = undefined;
    if (mac) {
        try std.testing.expectEqualStrings("⇧⌘S", write(&buf, .{ .key = 's', .cmd = true, .shift = true }));
        try std.testing.expectEqualStrings("⌥←", write(&buf, .{ .key = Shortcut.left, .alt = true }));
    } else {
        try std.testing.expectEqualStrings("Ctrl+Shift+S", write(&buf, (Shortcut{ .key = 's', .cmd = true, .shift = true }).native()));
        try std.testing.expectEqualStrings("Alt+←", write(&buf, .{ .key = Shortcut.left, .alt = true }));
        try std.testing.expectEqualStrings("Ctrl+Enter", write(&buf, .{ .key = Shortcut.enter, .ctrl = true }));
    }
}
