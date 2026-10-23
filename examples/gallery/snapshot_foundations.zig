//! Small executable examples for the layout guides' documentation images.
const ui = @import("myzig").ui;
const waves = ui.shader.compile("docs-waves",
    \\uniform time: f32;
    \\pub fn fragment(pos: vec2) vec4 {
    \\    const v = 0.5 + 0.5 * sin(pos.x / 20 + time);
    \\    return vec4(v * 0.2, v * 0.4, v, 1);
    \\}
);

pub const Foundations = struct {
    name: ui.TextBuffer = .{},
    email: ui.TextBuffer = .{},

    pub fn init(s: *Foundations) void {
        s.name.set("Ada Lovelace");
        s.email.set("ada@example.com");
    }

    pub fn shaders(_: *Foundations, c: *ui.Context) void {
        ui.heading(c, "A shader box");
        ui.label(c, "The waves shader from the guide, rendered by its CPU twin.");
        _ = ui.shaderBox(c, &waves, .{ .time = @as(f32, 0) }, .{ .width = .fill, .height = .{ .px = 120 }, .radius = 12 });
        c.end();
    }

    pub fn layout(_: *Foundations, c: *ui.Context) void {
        ui.heading(c, "Rows and columns");
        ui.row(c, .{ .width = .fill, .gap = 16 });
        defer ui.end(c);
        ui.column(c, .{ .width = .{ .px = 160 }, .padding = .all(16), .gap = 12, .background = c.theme.surface, .radius = 12 });
        ui.text(c, "160 px", .{ .weight = .semibold });
        _ = ui.button(c, "Overview", .{ .variant = .primary });
        _ = ui.button(c, "Settings", .{});
        ui.end(c);
        ui.column(c, .{ .grow = 1, .gap = 16 });
        defer ui.end(c);
        ui.card(c, .{ .width = .fill, .gap = 10 });
        ui.text(c, "Fill the remaining width", .{ .weight = .semibold });
        ui.text(c, "A column of cards inside a row. Gap: 16, padding: 16.", .{ .wrap = true });
        ui.end(c);
        ui.row(c, .{ .width = .fill, .gap = 16 });
        defer ui.end(c);
        for ([_][]const u8{ "grow = 1", "grow = 2" }, 0..) |label, i| {
            ui.card(c, .{ .width = .fill, .grow = @floatFromInt(i + 1), .height = .{ .px = 80 }, .justify = .center, .align_items = .center });
            ui.text(c, label, .{});
            ui.end(c);
        }
    }

    pub fn grid(s: *Foundations, c: *ui.Context) void {
        ui.heading(c, "Grid: fit + 1fr");
        var g = ui.grid(c, .{
            .columns = &.{ .fit, .{ .fr = 1 } },
            .gap_x = 16,
            .gap_y = 14,
            .style = .{ .width = .fill, .padding = .all(20), .background = c.theme.surface, .radius = 12 },
        });
        defer g.end();
        g.cell(.{ .col_span = -1 });
        ui.text(c, "Profile · spans both columns", .{ .weight = .semibold });
        ui.end(c);
        ui.text(c, "Name", .{});
        _ = ui.textField(c, &s.name, .{ .width = .fill });
        ui.text(c, "Email address", .{});
        _ = ui.textField(c, &s.email, .{ .width = .fill });
    }

    pub fn direction(_: *Foundations, c: *ui.Context) void {
        ui.heading(c, "Layout direction");
        for ([_]ui.Direction{ .ltr, .rtl }) |dir| {
            ui.label(c, if (dir == .ltr) "Left to right (LTR)" else "Right to left (RTL)");
            const row = c.open(.{
                .direction = .row,
                .width = .fill,
                .padding = .all(16),
                .gap = 12,
                .background = c.theme.surface,
                .radius = 12,
            }, null);
            ui.direction.scope(c, row, dir);
            _ = ui.button(c, "Back", .{ .icon = if (dir == .ltr) "chevron.left" else "chevron.right" });
            _ = ui.button(c, "Overview", .{ .variant = .primary });
            _ = ui.button(c, "Settings", .{});
            c.end();
        }
    }
};
