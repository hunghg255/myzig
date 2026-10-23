//! Documentation snapshots of the Gallery's actual views, without a window.
//! `cd docs && npm run images:ui` renders and losslessly compresses the PNGs.
const std = @import("std");
const ui = @import("myzig").ui;
const Basics = @import("basics.zig").Basics;
const Inputs = @import("inputs.zig").Inputs;
const Structures = @import("structures.zig").Structures;
const Overlays = @import("overlays.zig").Overlays;
const TextPages = @import("text.zig").TextPages;
const Drawing = @import("drawing.zig").Drawing;
const MotionPage = @import("motion.zig").MotionPage;
const Board = @import("dnd.zig").Board;
const Foundations = @import("snapshot_foundations.zig").Foundations;
const Composites = @import("composites.zig").Composites;
const Advanced = @import("advanced.zig").Advanced;
const DataTable = @import("data_table.zig").DataTable;
const Feedback = @import("feedback.zig").Feedback;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedOutputDirectory;
    try std.Io.Dir.cwd().createDirPath(init.io, args[1]);
    const out: Output = .{ .gpa = init.gpa, .dir = args[1] };

    var basics: Basics = .{};
    basics.init();
    try out.capture(&basics, Basics.controls, "controls", .{ .full = true });
    try out.capture(&basics, Basics.controls, "controls-dark", .{ .full = true, .dark = true });
    try out.capture(&basics, Basics.controls, "buttons", .{ .card = "Buttons" });
    try out.capture(&basics, Basics.controls, "toggles", .{ .card = "Toggles" });
    try out.capture(&basics, Basics.controls, "sliders", .{ .card = "Sliders and progress" });
    basics.name.set("Ada");
    try out.capture(&basics, Basics.controls, "text-field", .{ .card = "Text field" });
    try out.capture(&basics, Basics.typography, "text", .{ .full = true });
    try out.capture(&basics, Basics.tasks, "tasks", .{ .full = true });
    try out.capture(&basics, Basics.bigList, "virtual-list", .{ .height = 460, .bare = true });

    var inputs: Inputs = .{};
    inputs.init();
    try out.capture(&inputs, Inputs.view, "choices", .{ .card = "Choices" });
    try out.capture(&inputs, Inputs.view, "ranges", .{ .card = "Ranges" });
    try out.capture(&inputs, Inputs.view, "fields", .{ .card = "Fields" });
    try out.capture(&inputs, Inputs.view, "dates-and-colors", .{ .card = "Dates, times and colors" });
    try out.capture(&inputs, Inputs.view, "selects", .{ .card = "Menus of choices" });
    inputs.submitted = true;
    inputs.password.set("short");
    try out.capture(&inputs, Inputs.view, "forms", .{ .card = "A form" });

    var structures: Structures = .{};
    defer structures.deinit(init.gpa);
    try out.capture(&structures, Structures.view, "structures", .{ .card = "Tabs and disclosures" });
    try out.capture(&structures, Structures.view, "toolbar", .{ .card = "Toolbar and breadcrumbs" });
    try out.capture(&structures, Structures.view, "tree", .{ .card = "Sidebar, tree and outline in split panes" });
    try out.capture(&structures, Structures.view, "table", .{ .card = "Table" });
    try out.capture(&structures, Structures.view, "grid-view", .{ .card = "Grid" });

    var composites: Composites = .{};
    composites.init();
    try out.capture(&composites, Composites.view, "items", .{ .card = "Items", .script = "click:Open report;visible:Opened report" });
    try out.capture(&composites, Composites.view, "input-groups", .{ .card = "Input groups", .script = "click:Use URL;visible:URL selected" });
    try out.capture(&composites, Composites.view, "pagination", .{ .card = "Pagination", .script = "click:Next;visible:Page 7 of 20;visible:Document 13" });

    var advanced: Advanced = .init(init.gpa);
    defer advanced.deinit();
    try out.capture(&advanced, Advanced.groups, "button-groups", .{ .card = "Button and toggle groups" });
    try out.capture(&advanced, Advanced.choices, "multi-select", .{ .height = 500, .script = "click:Languages (2);visible:Python" });
    try out.capture(&advanced, Advanced.dateRange, "date-range", .{ .height = 500, .script = "click:Choose date range;visible:Choose start date" });
    try out.capture(&advanced, Advanced.drop, "file-drop", .{ .card = "File drop zone", .script = "click:Browse files;visible:design-notes.md" });
    var data_table: DataTable = .{};
    try out.capture(&data_table, DataTable.view, "data-table", .{ .full = true });

    var feedback: Feedback = .{};
    feedback.init();
    try out.capture(&feedback, Feedback.view, "alerts", .{ .card = "Inline alerts" });
    try out.capture(&feedback, Feedback.view, "empty-state", .{ .card = "Empty state" });
    try out.capture(&feedback, Feedback.view, "skeleton", .{ .card = "Skeleton placeholders" });
    for ([_]struct { []const u8, []const u8 }{
        .{ "command-palette", "click:Open commands;visible:Workspace settings" },
        .{ "sheet", "click:Open details;wait:0.5;visible:Save details" },
    }) |entry| {
        var panels: Feedback = .{};
        panels.init();
        try out.capture(&panels, Feedback.panels, entry[0], .{ .height = 640, .script = entry[1] });
    }

    // Fresh state for each overlay so an earlier dialog cannot obscure a menu.
    for ([_]struct { []const u8, []const u8 }{
        .{ "popover", "click:Edit name…;visible:Done" },
        .{ "dialog", "click:Rename…;visible:Rename the note" },
        .{ "menu", "click:Sort by;visible:Date modified" },
        .{ "toast", "click:With an action;visible:Undo" },
    }) |entry| {
        var overlays: Overlays = .{};
        overlays.init();
        try out.capture(&overlays, Overlays.view, entry[0], .{ .height = 640, .script = entry[1] });
    }

    var text: TextPages = try .init(init.gpa);
    defer text.deinit();
    try out.capture(&text, TextPages.editing, "text-area", .{ .card = "Text area" });
    try out.capture(&text, TextPages.editing, "code-editor", .{ .card = "Code editor" });
    try out.capture(&text, TextPages.editing, "diff", .{ .card = "Diff" });
    try out.capture(&text, TextPages.editing, "rich-text", .{
        .card = "Rich text",
        .script = "visible:Checked tasks;visible:Quotes, too.",
    });
    try out.capture(&text, TextPages.markdownPage, "markdown", .{ .card = "Rendered" });

    var drawing: Drawing = .{};
    try out.capture(&drawing, Drawing.drawingPage, "drawing", .{ .full = true });
    try out.capture(&drawing, Drawing.chartsPage, "chart", .{ .card = "Lines and areas" });
    try out.capture(&drawing, Drawing.chartsPage, "bars", .{ .card = "Bars" });
    var motion: MotionPage = .{};
    try out.capture(&motion, MotionPage.look, "transforms", .{ .full = true });
    try out.capture(&motion, MotionPage.moving, "motion", .{ .full = true });

    var board: Board = .init(init.gpa);
    defer board.deinit();
    try out.capture(&board, Board.view, "drag-and-drop", .{ .card = "A board", .width = 940 });
    var foundations: Foundations = .{};
    foundations.init();
    try out.capture(&foundations, Foundations.layout, "layout", .{ .height = 350 });
    try out.capture(&foundations, Foundations.grid, "grid", .{ .height = 280 });
    try out.capture(&foundations, Foundations.direction, "right-to-left", .{ .height = 320 });
    try out.capture(&foundations, Foundations.shaders, "shaders", .{ .full = true });
}

const Options = struct {
    card: ?[]const u8 = null,
    width: f32 = 800,
    height: f32 = 600,
    dark: bool = false,
    bare: bool = false,
    full: bool = false,
    script: []const u8 = "",
};

const Output = struct {
    gpa: std.mem.Allocator,
    dir: []const u8,

    fn capture(out: Output, state: anytype, comptime build: anytype, name: []const u8, opts: Options) !void {
        const Wrapped = struct {
            state: @TypeOf(state),
            bare: bool,
            fn view(w: *@This(), c: *ui.Context) void {
                if (w.bare) {
                    build(w.state, c);
                    return;
                }
                {
                    ui.scroll(c, .{ .width = .fill, .height = .fill, .padding = .all(24), .gap = 24 });
                    defer ui.end(c);
                    build(w.state, c);
                    // Allow the last card to scroll all the way to the top too.
                    _ = c.leaf(.{ .height = .{ .px = 2000 } }, .none, null);
                }
                if (@TypeOf(w.state) == *Overlays) w.state.toastLayer(c);
                if (@TypeOf(w.state) == *Board) w.state.preview(c);
                if (@TypeOf(w.state) == *Feedback) w.state.layers(c);
            }
        };
        var wrapped: Wrapped = .{ .state = state, .bare = opts.bare };
        var t: ui.Tester = undefined;
        try t.init(out.gpa, .init(&wrapped, Wrapped.view), .{
            .width = opts.width,
            .height = opts.height,
            .scale = 2,
            .dark = opts.dark,
        });
        defer t.deinit();
        t.settle(0.5);
        if (opts.full) t.resize(opts.width, @ceil(t.ctx.nodes.items[t.ctx.nodes.items.len - 1].rect.y));
        if (opts.card) |title| {
            const rect = try cardRect(&t, title);
            t.resize(opts.width, @ceil(rect.h) + 48);
            t.scroll(8, 8, 24 - (try cardRect(&t, title)).y);
            const framed = try cardRect(&t, title);
            if (@abs(framed.y - 24) > 1 or framed.y + framed.h > t.size.h - 23)
                return error.CardNotFullyVisible;
        }
        try t.runScript(opts.script);
        t.moveTo(0, 0);
        const path = try std.fs.path.join(out.gpa, &.{ out.dir, name });
        defer out.gpa.free(path);
        const png = try out.gpa.print("{s}.png", .{path});
        defer out.gpa.free(png);
        try t.screenshot(png);
        std.debug.print("{s}\n", .{name});
    }
};

/// Gallery card headings are direct children of their card. Framing from
/// layout keeps screenshots complete when text metrics or widget sizes change.
fn cardRect(t: *ui.Tester, title: []const u8) !ui.Rect {
    for (t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, title)) {
            return t.ctx.nodes.items[node.parent].rect;
        },
        else => {},
    };
    std.log.err("Gallery card not found: {s}", .{title});
    return error.CardNotFound;
}
