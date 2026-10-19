//! Disclosures: a header that opens and closes what is built below it, the
//! content growing into view and shrinking away (`Context.animate`), and
//! accordions, sections of them one above the other in a bordered box.
//!
//!     const d = ui.collapsible(c, "Advanced", &s.advanced);
//!     defer d.end();
//!     if (d.shown) {
//!         _ = ui.checkbox(c, "Verbose logging", &s.verbose);
//!     }
//!
//! A click on the header opens and closes it, as do Enter and Space while
//! it has the keyboard focus. In an accordion, Up and Down move the focus
//! between the headers, Home and End to the first and the last:
//!
//!     var acc = ui.accordion(c, .{});
//!     defer acc.end();
//!     {
//!         const d = acc.item("General", &s.general);
//!         defer d.end();
//!         if (d.shown) general(s, c);
//!     }
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;

pub const Disclosure = struct {
    c: *Context,
    /// The header's id: what has the focus while it does.
    id: u64,
    /// The header was clicked (or pressed with a key) in this frame.
    changed: bool,
    /// From 0 closed to 1 open, easing toward the state.
    progress: f32,
    /// Build the content: open, or still closing.
    shown: bool,
    focused: bool,

    /// Closes the content (when shown) and the disclosure.
    pub fn end(d: Disclosure) void {
        if (d.shown) {
            d.c.end(); // the content
            d.c.end(); // the clip that grows
        }
        d.c.end();
    }
};

const Look = enum { plain, section };

/// A disclosure: `title` beside an arrow, and below it, while `open.*` is
/// true or closing, what the view builds until `end`.
pub fn collapsible(c: *Context, title: []const u8, open: *bool) Disclosure {
    return disclose(c, title, open, .plain, null);
}

fn disclose(c: *Context, title: []const u8, open: *bool, look: Look, acc: ?*Accordion) Disclosure {
    const th = c.theme;
    _ = c.open(.{ .direction = .column, .width = .fill }, title);
    const head = c.open(.{
        .direction = .row,
        .width = .fill,
        .align_items = .center,
        .gap = 6,
        .padding = if (look == .section) .xy(12, 10) else .xy(4, 4),
        .radius = if (look == .section) 0 else 6,
        .control = true,
    }, "header");
    const it = c.interact(head, .{ .focusable = true });
    c.describe(it.id, .{ .role = .disclosure, .label = title, .expanded = open.* });
    if (acc) |a| a.add(it.id);
    var focused = it.focused;
    var changed = it.clicked;
    if (focused) {
        if (c.input.key) |k| if (k == .enter) {
            _ = structure.takeKey(c);
            changed = true;
        };
        if (structure.typedSpace(c)) {
            c.input.chars = "";
            changed = true;
        }
        if (acc) |a| a.keys();
        focused = c.focus == it.id;
    }
    if (changed) {
        open.* = !open.*;
        c.changed = true;
    }
    const p = c.animate(it.id, 0, if (open.*) 1 else 0, 16);
    const hover = c.animate(it.id, 1, if (it.hovered) 1 else 0, 20);
    const head_n = c.node(head);
    head_n.style.background = th.text.alpha(0.05 * hover);
    if (focused) head_n.style.border = th.accent.alpha(0.6);
    widgets.icon(c, if (p > 0.5) "chevron.down" else "chevron.right", .{ .size = 12, .frame = 14, .weight = .semibold, .color = th.muted });
    widgets.text(c, title, .{ .size = 13, .weight = if (look == .section) .semibold else .medium });
    c.end();

    const shown = open.* or p > 0;
    if (shown) {
        // The clip is as tall as the content, times the progress: the
        // content's height from the last frame, which lays it out whole.
        const inner_id = blk: {
            const clip_id = c.peekId("panel");
            var h = std.hash.Wyhash.init(clip_id);
            h.update("content");
            break :blk h.final();
        };
        const full = if (c.rects.get(inner_id)) |r| r.h else 0;
        const height: types.Length = if (p >= 1) .auto else .{ .px = @round(full * p) };
        _ = c.open(.{ .direction = .column, .width = .fill, .height = height, .clip = true, .opacity = @min(1, p * 1.5) }, "panel");
        _ = c.open(.{
            .direction = .column,
            .width = .fill,
            .gap = 8,
            .padding = if (look == .section) .{ .left = 12, .right = 12, .bottom = 12, .top = 2 } else .{ .left = 24, .top = 4, .bottom = 4 },
        }, "content");
    }
    return .{ .c = c, .id = it.id, .changed = changed, .progress = p, .shown = shown, .focused = focused };
}

pub const AccordionOptions = struct {
    width: types.Length = .fill,
};

pub const Accordion = struct {
    c: *Context,
    /// The headers built so far, in order, for Up and Down.
    headers: std.ArrayList(u64) = .empty,
    /// The focus moves to the next header built (Down).
    focus_next: bool = false,
    /// The focus moves to the last header at `end` (End).
    focus_last: bool = false,

    /// A section: its header shows `title`; what the view builds until the
    /// disclosure's `end` shows below it while `open.*` is true.
    pub fn item(a: *Accordion, title: []const u8, open: *bool) Disclosure {
        if (a.headers.items.len > 0) widgets.divider(a.c);
        return disclose(a.c, title, open, .section, a);
    }

    fn add(a: *Accordion, id: u64) void {
        if (a.focus_next) {
            a.focus_next = false;
            a.c.focus = id;
            a.c.changed = true;
        }
        a.headers.append(a.c.alloc(), id) catch {};
    }

    /// Keys of the focused header, the last added.
    fn keys(a: *Accordion) void {
        const c = a.c;
        const k = c.input.key orelse return;
        const at = a.headers.items.len - 1;
        switch (k) {
            .up => if (at > 0) {
                c.focus = a.headers.items[at - 1];
            },
            .down => a.focus_next = true,
            .home => c.focus = a.headers.items[0],
            .end => a.focus_last = true,
            else => return,
        }
        _ = structure.takeKey(c);
        c.changed = true;
    }

    pub fn end(a: *Accordion) void {
        // Down on the last header keeps the focus there.
        if (a.focus_last and a.headers.items.len > 0) a.c.focus = a.headers.items[a.headers.items.len - 1];
        a.c.end();
    }
};

/// A bordered box of sections (`Accordion.item`), each opening on its own.
pub fn accordion(c: *Context, opts: AccordionOptions) Accordion {
    const th = c.theme;
    _ = c.open(.{ .direction = .column, .width = opts.width, .radius = 10, .border = th.border, .background = th.surface, .clip = true }, null);
    return .{ .c = c };
}
