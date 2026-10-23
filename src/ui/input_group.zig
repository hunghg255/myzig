//! A shared frame for one text field, icons, affixes and action buttons.
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const textfield = @import("textfield.zig");
const Context = @import("context.zig").Context;

pub const Options = struct {
    width: types.Length = .{ .px = 320 },
    disabled: bool = false,
    invalid: bool = false,
};

pub const InputGroup = struct {
    c: *Context,
    index: u32,
    opts: Options,
    focus_input: bool,
    input_id: ?u64 = null,

    pub fn text(g: InputGroup, value: []const u8) void {
        widgets.text(g.c, value, .{ .size = 13, .color = g.c.theme.muted.alpha(if (g.opts.disabled) 0.45 else 1) });
    }

    pub fn icon(g: InputGroup, name: []const u8) void {
        widgets.icon(g.c, name, .{ .size = 16, .frame = 18, .color = g.c.theme.muted.alpha(if (g.opts.disabled) 0.45 else 1) });
    }

    /// Exactly one input per group. Its width and bare frame are owned by
    /// the group; all editing options and the result are textField's.
    pub fn input(g: *InputGroup, buffer: *textfield.TextBuffer, opts: textfield.Options) textfield.Result {
        std.debug.assert(g.input_id == null);
        const c = g.c;
        c.next_key = "input";
        const id = c.peekId(null);
        g.input_id = id;
        if (g.focus_input and !g.opts.disabled and !opts.disabled) {
            c.focus = id;
            c.changed = true;
        }
        var o = opts;
        o.bare = true;
        o.width = .fill;
        o.disabled = o.disabled or g.opts.disabled;
        const result = textfield.textField(c, buffer, o);
        c.describe(id, .{ .invalid = g.opts.invalid });
        return result;
    }

    /// Action buttons keep their own focus; pressing one never submits
    /// the input. Set a label even when displaying only an icon.
    pub fn button(g: InputGroup, title: []const u8, opts: widgets.ButtonOptions) bool {
        var o = opts;
        o.disabled = o.disabled or g.opts.disabled;
        return widgets.button(g.c, title, o).clicked;
    }

    pub fn end(g: InputGroup) void {
        std.debug.assert(g.input_id != null);
        const c = g.c;
        var focused = false;
        for (c.nodes.items[g.index + 1 ..]) |n| {
            if (n.id == c.focus) focused = true;
        }
        if (focused and g.opts.disabled) {
            c.focus = 0;
            c.changed = true;
            focused = false;
        }
        const n = c.node(g.index);
        n.style.border = if (g.opts.invalid) c.theme.danger else if (focused) c.theme.accent else c.theme.border;
        n.style.border_width = if (focused) 2 else 1;
        c.end();
    }
};

pub fn inputGroup(c: *Context, opts: Options) InputGroup {
    const index = c.open(.{
        .direction = .row,
        .width = opts.width,
        .align_items = .center,
        .gap = 8,
        .padding = .xy(10, 6),
        .radius = 8,
        .background = c.theme.surface,
        .border = c.theme.border,
    }, null);
    const it = c.interact(index, .{});
    c.describe(it.id, .{ .role = .group, .disabled = opts.disabled });
    if (c.hot == it.id) c.cursor_hand = false;
    return .{ .c = c, .index = index, .opts = opts, .focus_input = it.pressed and c.input.pressed };
}
