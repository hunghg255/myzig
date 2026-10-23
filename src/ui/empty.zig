//! Empty content with optional media and actions supplied by the app.
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const Context = @import("context.zig").Context;

pub const Options = struct {
    width: types.Length = .fill,
    icon: []const u8 = "",
    outline: bool = false,
};

pub const Empty = struct {
    c: *Context,

    /// Add action buttons or other widgets before closing the empty state.
    pub fn end(e: Empty) void {
        e.c.end();
    }
};

pub fn empty(c: *Context, title: []const u8, description: []const u8, opts: Options) Empty {
    const index = c.open(.{
        .width = opts.width,
        .padding = .all(24),
        .gap = 10,
        .align_items = .center,
        .radius = 10,
        .border = if (opts.outline) c.theme.border else null,
    }, null);
    c.describe(c.node(index).id, .{ .role = .group, .label = title, .description = description });
    if (opts.icon.len > 0) widgets.icon(c, opts.icon, .{ .size = 26, .frame = 40, .color = c.theme.muted });
    widgets.text(c, title, .{ .size = 16, .weight = .semibold, .wrap = true });
    if (description.len > 0) widgets.text(c, description, .{ .size = 13, .color = c.theme.muted, .wrap = true });
    return .{ .c = c };
}
