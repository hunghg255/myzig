//! Baselines, for rows and grids that line up their children's first lines
//! of text (`Align.baseline`) and for the rows of a form's fields
//! (`Style.baselines`), from the sizes measured: a text's is its first
//! line's; a box's that of its first child as it starts the box (in a row
//! lining up its children, of their line), which a child without text
//! takes from its bottom, as in CSS. A form lines a label up with its
//! control's text, or, where a control without text comes first (a
//! switch, swatches), with a line of text centered on it, and in a row
//! text comes before what is drawn beside it (a status dot, an icon).
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;

/// How far below its top the first baseline of text style `style` is,
/// in a line of its height.
pub fn ofText(c: *Context, style: types.TextStyle) f32 {
    const f = c.text.font(style);
    const lh = c.text.lineHeight(style);
    return (lh - f.lineHeight()) / 2 + f.leading / 2 + f.ascent;
}

/// Whether box `index` lines up its children by their baselines.
pub fn lines(st: types.Style) bool {
    return st.direction == .row and (st.align_items == .baseline or st.baselines);
}

/// How far below the top of box `index` (as measured) its first baseline
/// is; null without one. `form`: as a form finds it (`Style.baselines`).
pub fn of(c: *Context, index: u32, form: bool) ?f32 {
    return find(c, index, form, 0).at;
}

const Found = struct { at: ?f32 = null, text: bool = false };

fn find(c: *Context, index: u32, form: bool, depth: u32) Found {
    const n = c.node(index);
    const st = n.style;
    const h = n.measured.h;
    switch (n.content) {
        .text => |t| return .{ .at = st.padding.top + ofText(c, t.style), .text = true },
        .icon, .image => return if (form and h > 0) .{ .at = centered(c, h) } else .{},
        .none => {},
    }
    if (depth > 64) return .{};
    // A form's control: its text's, else a line centered on it.
    if (form and (n.interactive or st.control or n.first_child == none)) {
        if (n.first_child != none) {
            const b = find(c, index, false, depth + 1);
            if (b.text) return b;
        }
        return if (h > 0) .{ .at = centered(c, h) } else .{};
    }
    if (n.first_child == none) return .{};
    if (!form and lines(st)) {
        // Its line: the lowest of its children's baselines.
        var line: ?f32 = null;
        var text = false;
        var child = n.first_child;
        while (child != none) : (child = c.node(child).next) {
            const ch = c.node(child);
            if (ch.style.absolute) continue;
            const b = find(c, child, false, depth + 1);
            text = text or b.text;
            const v = b.at orelse ch.measured.h;
            line = if (line) |l| @max(l, v) else v;
        }
        return if (line) |l| .{ .at = st.padding.top + l, .text = text } else .{};
    }
    // Its first child's; a form's first that has one, in a row its text's.
    var fallback: Found = .{};
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) continue;
        const b = find(c, child, form, depth + 1);
        const y = st.padding.top + crossOffset(n, ch);
        if (!form) return .{ .at = y + (b.at orelse ch.measured.h), .text = b.text };
        const at = b.at orelse continue;
        if (b.text or st.direction != .row) return .{ .at = y + at, .text = b.text };
        if (fallback.at == null) fallback = .{ .at = y + at };
    }
    return fallback;
}

/// Where a row places child `ch` across, as its alignment says.
fn crossOffset(n: *const ctx_mod.Node, ch: *const ctx_mod.Node) f32 {
    if (n.style.direction != .row) return 0;
    const inner = n.measured.h - n.style.padding.vertical();
    return switch (n.style.align_items) {
        .start, .stretch, .baseline => 0,
        .center => (inner - ch.measured.h) / 2,
        .end => inner - ch.measured.h,
    };
}

/// The baseline of a line of the theme's text centered on a box `h` high.
fn centered(c: *Context, h: f32) f32 {
    const f = c.text.font(.{ .size = 13 });
    return h / 2 + (f.ascent - f.descent) / 2;
}
