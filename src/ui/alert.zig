//! Inline notices with optional trailing actions, without moving focus.
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const Context = @import("context.zig").Context;

pub const Kind = enum { info, success, warning, danger };

pub const Options = struct {
    width: types.Length = .fill,
    kind: Kind = .info,
};

pub const Alert = struct {
    c: *Context,

    /// Add dismiss, retry or other actions, then close the notice.
    pub fn end(a: Alert) void {
        a.c.end();
    }
};

pub fn alert(c: *Context, title: []const u8, description: []const u8, opts: Options) Alert {
    const color = switch (opts.kind) {
        .info => c.theme.accent,
        .success => c.theme.success,
        .warning => c.theme.warning,
        .danger => c.theme.danger,
    };
    const index = c.open(.{
        .direction = .row,
        .width = opts.width,
        .padding = .all(14),
        .gap = 10,
        .radius = 8,
        .border = color.alpha(0.4),
        .background = color.alpha(if (c.theme.dark) 0.12 else 0.05),
    }, null);
    c.describe(c.node(index).id, .{ .role = .status, .label = title, .description = description });
    widgets.icon(c, switch (opts.kind) {
        .info => "info.circle",
        .success => "checkmark.circle.fill",
        .warning, .danger => "exclamationmark.triangle",
    }, .{ .size = 18, .frame = 20, .color = color });
    widgets.column(c, .{ .width = .fill, .min_width = 0, .gap = 4 });
    widgets.text(c, title, .{ .weight = .semibold, .color = color, .wrap = true });
    if (description.len > 0) widgets.text(c, description, .{ .size = 13, .wrap = true });
    c.end();
    return .{ .c = c };
}
