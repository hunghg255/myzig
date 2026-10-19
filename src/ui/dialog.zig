//! Dialogs over the dimmed window, and alert dialogs.
//!
//!     if (ui.button(c, "Rename…", .{}).clicked) s.renaming.show();
//!     if (ui.dialog(c, &s.renaming, .{})) |d| {
//!         defer d.end();
//!         ui.text(c, "Rename", .{ .weight = .bold });
//!         if (ui.textField(c, &s.name, .{}).submitted) s.renaming.close();
//!     }
//!
//! A dialog keeps the window: its backdrop takes the pointer, a press on
//! it closes the dialog (`dismissible`), Escape closes it unless something
//! in it took Escape first (a select's open popup), and the focus behind
//! it is dropped as it opens and given back as it closes.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const base = @import("overlay_base.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;
const OverlayState = base.OverlayState;

pub const DialogOptions = struct {
    width: types.Length = .{ .px = 360 },
    padding: types.Edges = .all(20),
    gap: f32 = 12,
    /// A press on the backdrop closes it (alerts are not).
    dismissible: bool = true,
    /// Escape closes it.
    escape: bool = true,
    /// No look of its own (`DialogBase`): style the backdrop and the panel
    /// with `Dialog.backdropStyle` and `Dialog.panelStyle`.
    bare: bool = false,
};

/// An open dialog's panel: its children follow, then `end`.
pub const Dialog = struct {
    c: *Context,
    state: *OverlayState,
    lo: u32,
    backdrop: u32,
    panel: u32,
    opts: DialogOptions,

    pub fn backdropStyle(d: Dialog) *types.Style {
        return &d.c.node(d.backdrop).style;
    }

    pub fn panelStyle(d: Dialog) *types.Style {
        return &d.c.node(d.panel).style;
    }

    /// Closes the dialog: Escape (unless what is in it took it) closes it.
    pub fn end(d: Dialog) void {
        _ = d.finish();
    }

    fn finish(d: Dialog) bool {
        const c = d.c;
        std.debug.assert(c.stack.items[c.stack.items.len - 1] == d.panel);
        c.end();
        var dismissed = false;
        if (d.opts.escape and d.state.open and base.takeKey(c, .escape)) {
            d.state.dismiss(c);
            dismissed = true;
        }
        c.end();
        d.state.record(c, d.lo);
        return dismissed;
    }
};

/// A dialog over the dimmed window while `state.open`; null while closed.
pub fn dialog(c: *Context, state: *OverlayState, opts: DialogOptions) ?Dialog {
    if (!state.sync(c)) return null;
    const th = c.theme;
    const opened = state.justOpened(c);
    // What is behind it is inert: its focus goes until the dialog closes.
    if (opened) c.focus = 0;
    const lo: u32 = @intCast(c.nodes.items.len);
    const backdrop = base.overlay(c, .{ .absolute = true, .width = .fill, .height = .fill, .align_items = .center, .justify = .center }, base.seedOf(state));
    const bid = c.node(backdrop).id;
    const t = base.fadeIn(c, bid, opened);
    if (!opts.bare) c.node(backdrop).style.background = types.Color.black.alpha((if (th.dark) @as(f32, 0.5) else 0.3) * t);
    _ = c.interact(backdrop, .{});
    if (opts.dismissible and c.input.pressed and c.hot == bid and !opened) state.dismiss(c);
    const panel = c.open(.{}, null);
    if (!opts.bare) {
        c.node(panel).style = .{
            .width = opts.width,
            .padding = opts.padding,
            .gap = opts.gap,
            .radius = 14,
            .background = th.surface,
            .border = th.border,
            .shadow = .{ .color = th.shadow.alpha(2), .blur = 32, .y = 12 },
            .opacity = t,
            .offset = .{ .y = (1 - t) * 8 },
        };
    }
    // Presses on the panel are the panel's, not the backdrop's.
    _ = c.interact(panel, .{});
    c.describe(c.node(panel).id, .{ .role = .dialog, .modal = true });
    return .{ .c = c, .state = state, .lo = lo, .backdrop = backdrop, .panel = panel, .opts = opts };
}

/// What an alert dialog answered in this frame.
pub const AlertResult = union(enum) {
    none,
    /// The index of the button clicked (or the last one, for Enter).
    chosen: usize,
    /// Escape closed it, choosing no button, as canceling does.
    dismissed,
};

/// Asks about something important over the window while `state.open`, as
/// AppKit's alerts: a title, a message and buttons, the last of which is
/// the default, in the accent color, which Enter clicks. Escape closes it
/// choosing none; a press outside it does nothing. Choosing closes it.
pub fn alertDialog(c: *Context, state: *OverlayState, title: []const u8, message: []const u8, buttons: []const []const u8) AlertResult {
    const d = dialog(c, state, .{ .width = .{ .px = 320 }, .dismissible = false, .gap = 8 }) orelse return .none;
    c.describe(c.node(d.panel).id, .{ .role = .alert_dialog, .label = title, .description = message });
    const th = c.theme;
    var result: AlertResult = .none;
    widgets.text(c, title, .{ .size = 15, .weight = .bold, .wrap = true });
    if (message.len > 0) widgets.text(c, message, .{ .size = 13, .color = th.muted, .wrap = true });
    widgets.row(c, .{ .width = .fill, .justify = .end, .gap = 8, .padding = .{ .top = 12 } });
    for (buttons, 0..) |b, i| {
        const last = i + 1 == buttons.len;
        if (widgets.button(c, b, .{ .variant = if (last) .primary else .secondary, .size = 13 }).clicked) result = .{ .chosen = i };
    }
    widgets.end(c);
    if (result == .none and buttons.len > 0 and (base.takeKey(c, .enter))) result = .{ .chosen = buttons.len - 1 };
    if (result == .chosen) {
        state.open = false;
        c.changed = true;
    }
    if (d.finish()) result = .dismissed;
    return result;
}
