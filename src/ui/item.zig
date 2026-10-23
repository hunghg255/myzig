//! A content row with optional media and trailing controls. The row is a
//! group; its buttons keep their own focus and actions.
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const fields = @import("controls_fields.zig");
const Context = @import("context.zig").Context;

pub const Options = struct {
    width: types.Length = .fill,
    variant: enum { plain, outline, muted } = .outline,
    size: enum { normal, small } = .normal,
    /// Names the group for assistive technology.
    label: []const u8 = "",
};

pub const Item = struct {
    c: *Context,
    small: bool,

    pub fn icon(it: Item, name: []const u8) void {
        widgets.icon(it.c, name, .{ .size = if (it.small) 18 else 22, .frame = if (it.small) 24 else 32 });
    }

    pub fn avatar(it: Item, name: []const u8, opts: fields.AvatarOptions) void {
        fields.avatar(it.c, name, opts);
    }

    /// Takes the remaining width; the description wraps before actions.
    pub fn content(it: Item, title: []const u8, description: []const u8) void {
        const c = it.c;
        widgets.column(c, .{ .width = .fill, .min_width = 0, .gap = 3 });
        defer c.end();
        widgets.text(c, title, .{ .size = if (it.small) 13 else 14, .weight = .medium, .wrap = true });
        if (description.len > 0) widgets.text(c, description, .{ .size = 12, .color = c.theme.muted, .wrap = true });
    }

    /// Add trailing buttons or other widgets before ending the row.
    pub fn end(it: Item) void {
        it.c.end();
    }
};

pub fn item(c: *Context, opts: Options) Item {
    const small = opts.size == .small;
    const index = c.open(.{
        .direction = .row,
        .width = opts.width,
        .align_items = .center,
        .gap = if (small) 8 else 12,
        .padding = .all(if (small) 10 else 16),
        .radius = 8,
        .border = if (opts.variant == .outline) c.theme.border else null,
        .background = if (opts.variant == .muted) c.theme.surface_hover else null,
    }, null);
    c.describe(c.node(index).id, .{ .role = .group, .label = opts.label });
    return .{ .c = c, .small = small };
}
