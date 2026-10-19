//! The popup list of selects, comboboxes and autocompletes: options below
//! an anchor, one highlighted by the arrows or the pointer, chosen by a
//! click (or Enter, which the widget reads with `navigate`).
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const base = @import("overlay_base.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;

/// A popup list's state, inside its widget's.
pub const ListState = struct {
    state: base.OverlayState = .{},
    /// The option the arrows or the pointer are on, -1 for none.
    highlight: i32 = -1,
    /// The pointer as last seen: it highlights only when it moves.
    mouse: types.Point = .{ .x = -1e6, .y = -1e6 },
    /// The keyboard moved the highlight: scroll it into view.
    reveal: bool = false,
    /// The popup's box id, for its scroll offset.
    popup_id: u64 = 0,
    /// The highlighted option's box id: assistive technology follows it as
    /// the focus while the field or button keeps the keyboard.
    highlight_id: u64 = 0,

    pub fn openWith(l: *ListState, highlight: i32) void {
        l.state.open = true;
        l.highlight = highlight;
        l.mouse = .{ .x = -1e6, .y = -1e6 };
        l.reveal = true;
    }
};

/// The keys of an open list of `n` options: Up and Down (wrapping), Home
/// and End move the highlight; Enter (and Space, when `space`) chooses it,
/// returned; Escape closes the list. Keys it takes go no further.
pub fn navigate(c: *Context, l: *ListState, n: usize, space: bool) ?usize {
    if (!l.state.open) return null;
    const count: i32 = @intCast(n);
    if (base.takeKey(c, .down)) {
        if (count > 0) l.highlight = if (l.highlight < 0) 0 else @mod(l.highlight + 1, count);
        l.reveal = true;
    } else if (base.takeKey(c, .up)) {
        if (count > 0) l.highlight = if (l.highlight < 0) count - 1 else @mod(l.highlight - 1 + count, count);
        l.reveal = true;
    } else if (c.input.key == .home or c.input.key == .end) {
        if (count > 0) l.highlight = if (c.input.key == .home) 0 else count - 1;
        c.input.key = null;
        c.changed = true;
        l.reveal = true;
    } else if (base.takeKey(c, .escape)) {
        l.state.dismiss(c);
    } else if (l.highlight >= 0 and l.highlight < count and (base.takeKey(c, .enter) or (space and base.takeSpace(c)))) {
        return @intCast(l.highlight);
    }
    return null;
}

pub const PopupOptions = struct {
    /// The option chosen now, shown with a check mark.
    selected: ?usize = null,
    max_height: f32 = 260,
    /// Takes presses outside it, which only close it (a select's popup, as
    /// the system's pop-up menus). Without, they go on to what is under
    /// the pointer, and `except` is not outside.
    catcher: bool = false,
    except: u64 = 0,
};

/// Builds the open list's popup of `labels` below `anchor`, at least as wide;
/// returns the option clicked in this frame.
pub fn popup(c: *Context, l: *ListState, anchor: types.Rect, labels: []const []const u8, opts: PopupOptions) ?usize {
    if (!opts.catcher and l.state.open and l.state.shown and l.state.pressedOutside(c, opts.except)) l.state.dismiss(c);
    if (!l.state.sync(c)) return null;
    const th = c.theme;
    const lo: u32 = @intCast(c.nodes.items.len);
    if (opts.catcher) {
        const catcher = base.overlay(c, .{ .absolute = true, .width = .fill, .height = .fill }, base.seedOf(l) +% 1);
        const cid = c.node(catcher).id;
        _ = c.interact(catcher, .{});
        c.end();
        if ((c.input.pressed or base.rightPressed(c)) and c.hot == cid and !l.state.justOpened(c)) l.state.dismiss(c);
    }
    const index = base.overlay(c, .{
        .absolute = true,
        .padding = .all(4),
        .min_width = anchor.w,
        .max_height = opts.max_height,
        .scroll = true,
        .radius = 8,
        .background = th.surface,
        .border = th.border,
        .shadow = .{ .color = th.shadow.alpha(1.5), .blur = 20, .y = 6 },
    }, base.seedOf(l) +% 2);
    const pid = c.node(index).id;
    l.popup_id = pid;
    c.node(index).style.opacity = base.fadeIn(c, pid, l.state.justOpened(c));
    _ = c.interact(index, .{});
    c.describe(pid, .{ .role = .list });
    l.highlight_id = 0;
    const moved = c.input.mouse.x != l.mouse.x or c.input.mouse.y != l.mouse.y;
    var clicked: ?usize = null;
    var hl_rect: ?types.Rect = null;
    for (labels, 0..) |lab, i| {
        c.next_key_int = i;
        const pos: i32 = @intCast(i);
        const row = c.open(.{ .direction = .row, .width = .fill, .padding = .xy(8, 5), .radius = 5, .gap = 6, .align_items = .center, .control = true }, null);
        const it = c.interact(row, .{});
        if (it.hovered and moved and l.highlight != pos) {
            l.highlight = pos;
            c.changed = true;
        }
        if (it.clicked) clicked = i;
        const on = l.highlight == pos;
        c.describe(it.id, .{ .role = .list_item, .label = lab, .selected = if (opts.selected) |sel| sel == i else on, .pos_in_set = @intCast(i + 1), .set_size = @intCast(labels.len) });
        if (on) l.highlight_id = it.id;
        if (on) {
            c.node(row).style.background = th.accent;
            hl_rect = it.rect;
        }
        const fg = if (on) th.accent_text else th.text;
        if (opts.selected != null) {
            _ = c.open(.{ .width = .{ .px = 14 }, .align_items = .center }, null);
            if (opts.selected == i) widgets.icon(c, "checkmark", .{ .size = 12, .weight = .semibold, .color = fg });
            c.end();
        }
        widgets.text(c, lab, .{ .size = 13, .color = fg });
        c.end();
    }
    if (labels.len == 0) widgets.text(c, "No results", .{ .size = 13, .color = th.muted });
    l.mouse = c.input.mouse;
    // Keep the highlighted option in view as the keyboard moves it.
    if (l.reveal) if (hl_rect) |r| if (c.rects.get(pid)) |pr| {
        const off = c.scroll.get(pid) orelse 0;
        const view_top = pr.y + 4;
        const view_bottom = pr.y + pr.h - 4;
        var next = off;
        if (r.y < view_top) next = off - (view_top - r.y);
        if (r.y + r.h > view_bottom) next = off + (r.y + r.h - view_bottom);
        if (next != off) {
            c.scroll.put(c.gpa, pid, @max(0, next)) catch {};
            c.changed = true;
        }
        l.reveal = false;
    };
    _ = base.place(c, index, anchor, .below, .start, 4);
    c.end();
    l.state.record(c, lo);
    if (clicked != null) {
        l.state.open = false;
        c.changed = true;
    }
    return clicked;
}

/// Lowercase ASCII comparison, enough for filtering options.
fn lower(b: u8) u8 {
    return std.ascii.toLower(b);
}

fn startsWithFold(s: []const u8, prefix: []const u8) bool {
    if (prefix.len > s.len) return false;
    for (s[0..prefix.len], prefix) |a, b| if (lower(a) != lower(b)) return false;
    return true;
}

fn containsFold(s: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > s.len) return false;
    var i: usize = 0;
    while (i + needle.len <= s.len) : (i += 1) if (startsWithFold(s[i..], needle)) return true;
    return false;
}

/// The indices of `options` containing `query` (ignoring case), those
/// starting with it first; all of them for an empty query. In frame memory.
pub fn filter(c: *Context, options: []const []const u8, query: []const u8) []const usize {
    const out = c.alloc().alloc(usize, options.len) catch return &.{};
    var n: usize = 0;
    for (options, 0..) |o, i| if (startsWithFold(o, query)) {
        out[n] = i;
        n += 1;
    };
    if (query.len > 0) for (options, 0..) |o, i| if (!startsWithFold(o, query) and containsFold(o, query)) {
        out[n] = i;
        n += 1;
    };
    return out[0..n];
}

/// The labels of `indices` in `options`, in frame memory.
pub fn labelsOf(c: *Context, options: []const []const u8, indices: []const usize) []const []const u8 {
    const out = c.alloc().alloc([]const u8, indices.len) catch return &.{};
    for (indices, 0..) |i, k| out[k] = options[i];
    return out;
}

test "matching ignores case" {
    try std.testing.expect(startsWithFold("Helvetica", "hel"));
    try std.testing.expect(containsFold("Comic Sans", "SANS"));
    try std.testing.expect(!containsFold("Menlo", "arial"));
}
