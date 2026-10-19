//! Choosing: radio buttons and their groups, star ratings, links, and the
//! back and forward buttons of a history.
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const state = @import("controls_state.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Interaction = ctx_mod.Interaction;

/// The dot and its label; `on` fills it.
fn radioLook(c: *Context, title: []const u8, on: bool) Interaction {
    const th = c.theme;
    const it = widgets.pressable(c, .{ .direction = .row, .gap = 8, .align_items = .center, .control = true }, null);
    c.describe(it.id, .{ .role = .radio, .label = title, .checked = if (on) .on else .off, .selected = on });
    const t = c.animate(it.id, 0, if (on) 1 else 0, 22);
    const hover = c.animate(it.id, 1, if (it.hovered) 1 else 0, 20);
    _ = c.open(.{
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .radius = 9,
        .background = th.surface.mix(th.surface_hover, hover * (1 - t)).mix(th.accent, t),
        .border = th.border.mix(th.accent, t),
        .align_items = .center,
        .justify = .center,
    }, null);
    if (t > 0.01) _ = c.leaf(.{ .width = .{ .px = 7 * t }, .height = .{ .px = 7 * t }, .radius = 3.5 * t, .background = th.accent_text }, .none, null);
    c.end();
    if (title.len > 0) widgets.text(c, title, .{});
    c.end();
    return it;
}

/// A radio button selecting `value` into `selected` (any type
/// `std.meta.eql` compares); returns true when a click selects it.
pub fn radio(c: *Context, selected: anytype, value: @TypeOf(selected.*), title: []const u8) bool {
    const on = std.meta.eql(selected.*, value);
    const it = radioLook(c, title, on);
    if (it.clicked and !on) {
        selected.* = value;
        c.changed = true;
        return true;
    }
    return false;
}

pub fn Choice(comptime T: type) type {
    return struct { label: []const u8, value: T };
}

pub const RadioGroupOptions = struct {
    /// A row of radio buttons, not a column.
    row: bool = false,
    gap: f32 = 8,
};

/// Radio buttons, one per choice, as one control taking the keyboard focus:
/// the arrows choose among them, Home and End the first and the last.
/// Returns true when the choice changes.
///
///     _ = ui.radioGroup(c, &s.size, &.{ .{ .label = "Small", .value = .small }, .{ .label = "Large", .value = .large } }, .{});
pub fn radioGroup(c: *Context, selected: anytype, choices: []const Choice(@TypeOf(selected.*)), opts: RadioGroupOptions) bool {
    const i = c.open(.{ .direction = if (opts.row) .row else .column, .gap = opts.gap, .padding = .all(2), .radius = 6 }, null);
    defer c.end();
    const it = c.interact(i, .{ .focusable = true });
    c.describe(it.id, .{ .role = .radio_group });
    var current: ?usize = null;
    for (choices, 0..) |ch, k| if (std.meta.eql(selected.*, ch.value)) {
        current = k;
    };
    var changed = false;
    for (choices, 0..) |ch, k| {
        const on = current == k;
        const r = radioLook(c, ch.label, on);
        if (on) c.describe(it.id, .{ .active_descendant = r.id });
        if (r.clicked) {
            // The group keeps the focus its button took.
            c.focus = it.id;
            if (!on) {
                selected.* = ch.value;
                current = k;
                changed = true;
            }
        }
    }
    if (it.focused and choices.len > 0) if (c.input.key) |key| {
        const last = choices.len - 1;
        const at = current orelse 0;
        const to: ?usize = switch (key) {
            .down, .right => if (current == null) 0 else @min(last, at + 1),
            .up, .left => if (at == 0) 0 else at - 1,
            .home => 0,
            .end => last,
            else => null,
        };
        if (to) |k| {
            c.input.key = null;
            if (current != k) {
                selected.* = choices[k].value;
                changed = true;
            }
        }
    };
    state.focusRing(c, i, it.focused and c.focus == it.id);
    if (changed) c.changed = true;
    return changed;
}

pub const RatingOptions = struct {
    max: u8 = 5,
    size: f32 = 18,
};

/// A row of stars, `value` of them filled: a click on a star sets the
/// rating, a click on the star set clears it, the arrows, Home and End
/// change it with the keyboard focus, and the stars the pointer rests on
/// show what a click would set. Returns true when it changes.
pub fn rating(c: *Context, value: *u8, opts: RatingOptions) bool {
    const th = c.theme;
    const i = c.open(.{ .direction = .row, .gap = 2, .padding = .all(2), .radius = 6, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{ .focusable = true });
    c.describe(it.id, .{ .role = .slider, .label = "Rating", .range = .{ .min = 0, .max = @floatFromInt(opts.max), .now = @floatFromInt(value.*), .step = 1 } });
    var next: ?u8 = null;
    var hover: ?u8 = null;
    const first_icon: u32 = @intCast(c.nodes.items.len + 1);
    var k: u8 = 0;
    while (k < opts.max) : (k += 1) {
        const s = c.open(.{ .width = .{ .px = opts.size }, .height = .{ .px = opts.size }, .align_items = .center, .justify = .center }, null);
        const si = c.interact(s, .{});
        if (si.hovered) hover = k;
        if (si.clicked) {
            next = if (value.* == k + 1) 0 else k + 1;
            c.focus = it.id;
        }
        widgets.icon(c, "star.fill", .{ .size = opts.size * 0.9 });
        c.end();
    }
    // The stars a click would set, as the pointer rests on them.
    k = 0;
    while (k < opts.max) : (k += 1) {
        const filled = if (hover) |h| k <= h else k < value.*;
        const color = if (!filled) th.track else if (hover != null) state.warning(c).alpha(0.6) else state.warning(c);
        c.node(first_icon + 2 * @as(u32, k)).content.icon.color = color;
    }
    if (it.focused) if (c.input.key) |key| {
        const v = value.*;
        const to: ?u8 = switch (key) {
            .right, .up => @min(opts.max, v + 1),
            .left, .down => if (v == 0) 0 else v - 1,
            .home => 0,
            .end => opts.max,
            else => null,
        };
        if (to != null) {
            c.input.key = null;
            next = to;
        }
    };
    state.focusRing(c, i, it.focused and c.focus == it.id);
    if (next) |v| if (v != value.*) {
        value.* = @min(v, opts.max);
        c.changed = true;
        return true;
    };
    return false;
}

pub const LinkOptions = struct {
    size: f32 = 14,
};

/// A text in the accent color, underlined while the pointer is over it,
/// clicked as a button is (or with Enter while it has the keyboard focus):
///
///     if (ui.link(c, "Privacy policy", .{})) myzig.desktop.openUrl("https://example.com/privacy");
pub fn link(c: *Context, title: []const u8, opts: LinkOptions) bool {
    const i = c.open(.{ .control = true, .radius = 3 }, null);
    defer c.end();
    const it = c.interact(i, .{ .focusable = true });
    c.describe(it.id, .{ .role = .link, .label = title });
    const spans: []const types.Span = if (it.hovered)
        c.alloc().dupe(types.Span, &.{.{ .start = 0, .end = @intCast(title.len), .underline = true }}) catch &.{}
    else
        &.{};
    widgets.richText(c, title, spans, .{ .size = opts.size, .color = if (it.pressed) c.theme.accent_hover else c.theme.accent });
    const focused = it.focused and c.focus == it.id;
    state.focusRing(c, i, focused);
    var clicked = it.clicked;
    if (focused and c.input.key == .enter) {
        c.input.key = null;
        clicked = true;
    }
    if (clicked) c.changed = true;
    return clicked;
}

pub const HistoryAction = enum { none, back, forward };

pub const HistoryOptions = struct {
    can_back: bool,
    can_forward: bool,
    /// Also take the keys that go back and forward: Command-[ and
    /// Command-] on macOS, Alt-Left and Alt-Right elsewhere.
    shortcuts: bool = true,
};

/// A history's back and forward buttons, as in Finder's toolbar or a
/// browser's: disabled at its ends. Returns where to go.
///
///     switch (ui.historyButtons(c, .{ .can_back = s.at > 0, .can_forward = s.at + 1 < s.pages.len })) { ... }
pub fn historyButtons(c: *Context, opts: HistoryOptions) HistoryAction {
    _ = c.open(.{ .direction = .row, .gap = 2 }, null);
    defer c.end();
    var action: HistoryAction = .none;
    if (historyButton(c, "chevron.left", "‹", opts.can_back)) action = .back;
    if (historyButton(c, "chevron.right", "›", opts.can_forward)) action = .forward;
    if (opts.shortcuts and action == .none) {
        const mac = @import("builtin").os.tag == .macos;
        if (opts.can_back and (if (mac) c.shortcut(.{ .key = '[', .cmd = true }) else c.shortcut(.{ .key = ctx_mod.Shortcut.left, .alt = true }))) action = .back //
        else if (opts.can_forward and (if (mac) c.shortcut(.{ .key = ']', .cmd = true }) else c.shortcut(.{ .key = ctx_mod.Shortcut.right, .alt = true }))) action = .forward;
    }
    if (action != .none) c.changed = true;
    return action;
}

fn historyButton(c: *Context, symbol: []const u8, glyph: []const u8, enabled: bool) bool {
    const th = c.theme;
    const i = c.open(.{ .width = .{ .px = 28 }, .height = .{ .px = 26 }, .radius = 6, .align_items = .center, .justify = .center, .control = true, .opacity = if (enabled) 1 else 0.35 }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const hover = c.animate(it.id, 0, if (it.hovered and enabled) 1 else 0, 20);
    c.node(i).style.background = th.surface_hover.alpha(hover).mix(th.border, if (it.pressed and enabled) 0.5 else 0);
    // A symbol where the platform has it, else the chevron as text.
    if (!@import("text.zig").portable or @import("icons.zig").find(symbol) != null)
        widgets.icon(c, symbol, .{ .size = 15, .weight = .semibold, .color = th.text })
    else
        widgets.text(c, glyph, .{ .size = 20, .weight = .medium, .color = th.text });
    return it.clicked and enabled;
}
