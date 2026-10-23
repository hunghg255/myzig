//! A tour of the native UI toolkit: layout, text, and every widget, drawn
//! by myzig (Metal on macOS, its own renderer elsewhere). Each page is a
//! file of its own: basics.zig, inputs.zig, structures.zig, overlays.zig,
//! text.zig, drawing.zig, motion.zig and dnd.zig.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const Basics = @import("basics.zig").Basics;
const Inputs = @import("inputs.zig").Inputs;
const Structures = @import("structures.zig").Structures;
const Overlays = @import("overlays.zig").Overlays;
const TextPages = @import("text.zig").TextPages;
const Drawing = @import("drawing.zig").Drawing;
const MotionPage = @import("motion.zig").MotionPage;
const Board = @import("dnd.zig").Board;
const Composites = @import("composites.zig").Composites;
const Advanced = @import("advanced.zig").Advanced;
const DataTable = @import("data_table.zig").DataTable;
const Feedback = @import("feedback.zig").Feedback;

const Page = enum { controls, tasks, list, inputs, composites, feedback, advanced, data_table, structures, overlays, typography, editing, markdown, drawing, charts, styling, motion, dnd };

const sections = [_]struct { title: []const u8, pages: []const struct { Page, []const u8, []const u8 } }{
    .{ .title = "Widgets", .pages = &.{
        .{ .controls, "Controls", "slider.horizontal.3" },
        .{ .tasks, "Tasks", "checklist" },
        .{ .list, "List", "list.bullet" },
        .{ .inputs, "Inputs", "text.cursor" },
        .{ .composites, "Composition", "square.grid.2x2" },
        .{ .feedback, "Feedback", "info.circle" },
        .{ .advanced, "Actions & choices", "checklist" },
        .{ .data_table, "Data table", "tablecells" },
        .{ .structures, "Structures", "square.grid.2x2" },
        .{ .overlays, "Overlays", "rectangle.on.rectangle" },
    } },
    .{ .title = "Look", .pages = &.{
        .{ .typography, "Typography", "textformat" },
        .{ .editing, "Text editing", "square.and.pencil" },
        .{ .markdown, "Markdown", "doc.richtext" },
        .{ .drawing, "Drawing", "pencil" },
        .{ .charts, "Charts", "chart.bar.xaxis" },
        .{ .styling, "Styling", "circle.lefthalf.filled" },
        .{ .motion, "Motion", "sparkles" },
        .{ .dnd, "Drag and drop", "hand.raised" },
    } },
};

const Gallery = struct {
    gpa: std.mem.Allocator,
    page: Page = .controls,
    basics: Basics = .{},
    inputs: Inputs = .{},
    composites: Composites = .{},
    feedback: Feedback = .{},
    advanced: Advanced,
    data_table: DataTable = .{},
    structures: Structures = .{},
    overlays: Overlays = .{},
    text: TextPages,
    drawing: Drawing = .{},
    motion: MotionPage = .{},
    board: Board,

    fn init(g: *Gallery, gpa: std.mem.Allocator) !void {
        g.* = .{ .gpa = gpa, .text = try .init(gpa), .board = .init(gpa), .advanced = .init(gpa) };
        g.basics.init();
        g.inputs.init();
        g.composites.init();
        g.feedback.init();
        g.overlays.init();
    }

    fn deinit(g: *Gallery) void {
        g.text.deinit();
        g.structures.deinit(g.gpa);
        g.board.deinit();
        g.advanced.deinit();
    }

    fn view(g: *Gallery, c: *ui.Context) void {
        {
            ui.row(c, .{ .width = .fill, .height = .fill });
            defer ui.end(c);
            g.sidebar(c);
            if (g.page == .list) {
                g.basics.bigList(c);
            } else {
                ui.scroll(c, .{ .grow = 1, .height = .fill, .padding = .all(28), .gap = 20 });
                defer ui.end(c);
                switch (g.page) {
                    .controls => g.basics.controls(c),
                    .tasks => g.basics.tasks(c),
                    .list => {},
                    .inputs => g.inputs.view(c),
                    .composites => g.composites.view(c),
                    .feedback => g.feedback.view(c),
                    .advanced => g.advanced.view(c),
                    .data_table => g.data_table.view(c),
                    .structures => g.structures.view(c),
                    .overlays => g.overlays.view(c),
                    .typography => g.basics.typography(c),
                    .editing => g.text.editing(c),
                    .markdown => g.text.markdownPage(c),
                    .drawing => g.drawing.drawingPage(c),
                    .charts => g.drawing.chartsPage(c),
                    .styling => g.motion.look(c),
                    .motion => g.motion.moving(c),
                    .dnd => g.board.view(c),
                }
            }
        }
        // Over everything, last.
        g.overlays.toastLayer(c);
        g.board.preview(c);
        g.feedback.layers(c);
    }

    fn sidebar(g: *Gallery, c: *ui.Context) void {
        const th = c.theme;
        ui.column(c, .{
            .width = .{ .px = 210 },
            .height = .fill,
            .padding = .{ .top = 44, .left = 12, .right = 12, .bottom = 12 },
            .gap = 2,
            .background = th.surface.alpha(0.6),
            .scroll = true,
        });
        defer ui.end(c);
        ui.text(c, "myzig", .{ .size = 18, .weight = .bold });
        ui.label(c, "Zig 0.17 · native UI");
        for (sections) |sec| {
            _ = c.leaf(.{ .height = .{ .px = 10 } }, .none, null);
            ui.text(c, sec.title, .{ .size = 11, .weight = .semibold, .color = th.muted });
            for (sec.pages) |p| {
                const selected = g.page == p[0];
                // GPUI's way: a box styled by a chain of methods.
                var item = ui.div(c).row().wFull().px(10).py(6).gap(8).itemsCenter().rounded(7);
                item = if (selected) item.bg(th.accent) else item.hover(th.surface_hover);
                defer item.end();
                if (item.clicked()) g.page = p[0];
                const fg = if (selected) th.accent_text else th.text;
                ui.icon(c, p[2], .{ .size = 14, .frame = 18, .color = fg });
                ui.text(c, p[1], .{ .weight = .medium, .color = fg });
            }
        }
        ui.spacer(c);
        ui.label(c, c.print("{d} frames", .{c.frame}));
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Gallery" });
    defer app.destroy();
    const g = try init.gpa.create(Gallery);
    defer init.gpa.destroy(g);
    try g.init(init.gpa);
    defer g.deinit();
    _ = try app.newWindow(.{
        .title = "Gallery",
        .width = 980,
        .height = 700,
        .min_width = 640,
        .min_height = 420,
        .title_bar = .hidden,
        .content = .{ .view = .init(g, Gallery.view) },
    });
    try app.run();
}
