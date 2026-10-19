//! A custom text field built from myzig's text-input and layout
//! primitives: the app owns the text, the selection and the composition;
//! the context brings the platform's text operations (typing, input
//! methods, key bindings) and asks where the caret is for the input method.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const style: ui.TextStyle = .{ .size = 18 };
const pad: f32 = 12;
/// What text input does to the focused text (not exported by `ui` yet).
const TextOp = @typeInfo(@FieldType(@FieldType(ui.Context, "input"), "ops")).pointer.child;

/// Application-owned state: a larger editor can keep its own buffer,
/// selections, attributes and history the same way.
const Field = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    caret: usize = 0,
    anchor: usize = 0,
    marked: ?[2]usize = null,
    selecting: bool = false,
    focused_once: bool = false,

    fn lo(f: *const Field) usize {
        return @min(f.caret, f.anchor);
    }

    fn hi(f: *const Field) usize {
        return @max(f.caret, f.anchor);
    }

    /// Replaces the composition, else the selection, with `s`.
    fn replace(f: *Field, s: []const u8) void {
        const r = f.marked orelse .{ f.lo(), f.hi() };
        f.text.replaceRange(f.gpa, r[0], r[1] - r[0], s) catch return;
        f.caret = r[0] + s.len;
        f.anchor = f.caret;
        f.marked = null;
    }

    fn move(f: *Field, to: usize, extend: bool) void {
        f.caret = to;
        if (!extend) f.anchor = to;
    }

    fn prev(f: *const Field, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        while (j > 0 and (f.text.items[j] & 0xc0) == 0x80) j -= 1;
        return j;
    }

    fn next(f: *const Field, i: usize) usize {
        if (i >= f.text.items.len) return f.text.items.len;
        var j = i + 1;
        while (j < f.text.items.len and (f.text.items[j] & 0xc0) == 0x80) j += 1;
        return j;
    }

    fn apply(f: *Field, c: *ui.Context, op: TextOp) void {
        const n = f.text.items.len;
        switch (op) {
            .insert => |s| f.replace(s),
            .set_marked => |m| {
                const at = (f.marked orelse [2]usize{ f.lo(), f.hi() })[0];
                f.replace(m.text);
                f.marked = .{ at, at + m.text.len };
                f.anchor = at + @min(m.sel_start, m.text.len);
                f.caret = at + @min(m.sel_start + m.sel_len, m.text.len);
            },
            .unmark => f.marked = null,
            .command => |cmd| switch (cmd) {
                .delete_backward, .delete_forward => {
                    if (f.caret == f.anchor) f.caret = if (cmd == .delete_backward) f.prev(f.caret) else f.next(f.caret);
                    f.replace("");
                },
                .move_left => f.move(if (f.caret != f.anchor) f.lo() else f.prev(f.caret), false),
                .move_right => f.move(if (f.caret != f.anchor) f.hi() else f.next(f.caret), false),
                .select_left => f.move(f.prev(f.caret), true),
                .select_right => f.move(f.next(f.caret), true),
                .move_line_start, .move_doc_start, .move_up => f.move(0, false),
                .move_line_end, .move_doc_end, .move_down => f.move(n, false),
                .select_line_start, .select_doc_start, .select_up => f.move(0, true),
                .select_line_end, .select_doc_end, .select_down => f.move(n, true),
                .select_all => {
                    f.anchor = 0;
                    f.caret = n;
                },
                .copy, .cut => if (f.caret != f.anchor) {
                    c.clipboard.write(c.clipboard.ctx, f.text.items[f.lo()..f.hi()]);
                    c.copy_done = true;
                    if (cmd == .cut) f.replace("");
                },
                .cancel => c.focus = 0,
                else => {},
            },
        }
    }

    /// The field: a focusable box that draws the text, the selection, the
    /// composition's underline and the caret itself.
    fn field(f: *Field, c: *ui.Context) void {
        const th = c.theme;
        const box = c.open(.{ .width = .fill, .height = .{ .px = 60 }, .padding = .all(pad), .background = th.surface, .border = th.border, .radius = 8, .clip = true }, "custom-field");
        defer c.end();
        const it = c.interact(box, .{ .focusable = true });
        if (!f.focused_once) {
            // Focused from the start, as AutoFocus.
            c.focus = it.id;
            f.focused_once = true;
        }
        if (it.hovered) {
            c.cursor_hand = false;
            c.cursor_text = true;
        }
        const focused = c.focus == it.id;
        if (focused) {
            if (it.rect) |r| {
                const x = c.input.mouse.x - r.x - pad;
                if (c.input.pressed and it.hovered) {
                    f.move(c.text.indexAt(f.text.items, style, x), c.input.shift);
                    f.marked = null;
                    f.selecting = true;
                } else if (f.selecting and c.input.down) f.move(c.text.indexAt(f.text.items, style, x), true);
                if (!c.input.down) f.selecting = false;
            }
            for (c.input.ops) |op| f.apply(c, op);
            // Without an input method (tests, scripts): characters and keys.
            if (c.input.chars.len > 0) f.apply(c, .{ .insert = c.input.chars });
            if (c.input.key) |k| switch (k) {
                .backspace => f.apply(c, .{ .command = .delete_backward }),
                .delete => f.apply(c, .{ .command = .delete_forward }),
                .left => f.apply(c, .{ .command = if (c.input.shift) .select_left else .move_left }),
                .right => f.apply(c, .{ .command = if (c.input.shift) .select_right else .move_right }),
                .home => f.apply(c, .{ .command = if (c.input.shift) .select_line_start else .move_line_start }),
                .end => f.apply(c, .{ .command = if (c.input.shift) .select_line_end else .move_line_end }),
                .escape => c.focus = 0,
                else => {},
            };
            if (c.input.ops.len > 0 or c.input.chars.len > 0 or c.input.key != null) c.changed = true;
        }
        const s = f.text.items;
        const lh = c.text.lineHeight(style);
        if (focused and f.caret != f.anchor) {
            const x0 = c.text.caretX(s, style, f.lo());
            const x1 = c.text.caretX(s, style, f.hi());
            _ = c.leaf(.{ .absolute = true, .width = .{ .px = x1 - x0 }, .height = .{ .px = lh }, .background = th.accent.alpha(0.3), .offset = .{ .x = x0 } }, .none, null);
        }
        _ = c.leaf(.{}, .{ .text = .{ .str = s, .style = style, .color = th.text } }, null);
        if (f.marked) |m| {
            const x0 = c.text.caretX(s, style, m[0]);
            const x1 = c.text.caretX(s, style, m[1]);
            _ = c.leaf(.{ .absolute = true, .width = .{ .px = x1 - x0 }, .height = .{ .px = 1.5 }, .background = th.text, .offset = .{ .x = x0, .y = lh - 1 } }, .none, null);
        }
        const caret_x = c.text.caretX(s, style, f.caret);
        if (focused) {
            if (f.caret == f.anchor) _ = c.leaf(.{ .absolute = true, .width = .{ .px = 2 }, .height = .{ .px = lh }, .background = th.accent, .offset = .{ .x = caret_x } }, .none, null);
            // What the input method asks between frames: the text, the
            // selection, and where to put its candidates.
            const r = it.rect orelse ui.Rect{};
            c.focused_text = .{ .id = it.id, .text = s, .caret = f.caret, .anchor = f.anchor, .marked = f.marked, .caret_rect = .{ .x = r.x + pad + caret_x, .y = r.y + pad, .w = 2, .h = lh } };
        }
    }

    fn view(f: *Field, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(24), .gap = 12 });
        defer ui.end(c);
        ui.text(c, "Application-owned text input", .{ .size = 22, .weight = .bold });
        ui.text(c, "Click, type, compose with your input method, select with Shift, and use the Edit menu.", .{ .color = c.theme.muted, .wrap = true });
        f.field(c);
        ui.text(c, "Storage, navigation, clipboard policy and rendering belong to this example; the primitive supplies native text services.", .{ .color = c.theme.muted, .wrap = true });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Text Input" });
    defer app.destroy();
    var f: Field = .{ .gpa = init.gpa };
    defer f.text.deinit(init.gpa);
    try f.text.appendSlice(init.gpa, "Type here: é, 😀, العربية, עברית");
    f.caret = f.text.items.len;
    f.anchor = f.caret;
    try app.setMenu(&.{ .{ .role = .app_menu }, .{ .role = .edit_menu } });
    _ = try app.newWindow(.{
        .title = "Text input primitive",
        .width = 760,
        .height = 240,
        .content = .{ .view = .init(&f, Field.view) },
    });
    try app.run();
}
