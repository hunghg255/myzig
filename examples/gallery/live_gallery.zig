//! The documentation's demos that are the Gallery's own views, as its
//! pictures are (`snapshots.zig`): a page of it with only the card the
//! picture shows (`basics.only`), or the whole page. A page names one
//! with `<!-- demo: choices height=300 -->` above its picture.
const std = @import("std");
const ui = @import("myzig").ui;
const basics = @import("basics.zig");
const Demo = @import("live_demos.zig").Demo;
const Basics = basics.Basics;
const Inputs = @import("inputs.zig").Inputs;
const Structures = @import("structures.zig").Structures;
const Composites = @import("composites.zig").Composites;
const Advanced = @import("advanced.zig").Advanced;
const Feedback = @import("feedback.zig").Feedback;
const Overlays = @import("overlays.zig").Overlays;
const TextPages = @import("text.zig").TextPages;
const Drawing = @import("drawing.zig").Drawing;
const MotionPage = @import("motion.zig").MotionPage;
const Board = @import("dnd.zig").Board;
const Foundations = @import("snapshot_foundations.zig").Foundations;

pub const all = [_]Demo{
    gallery("controls", Basics, Basics.controls, null),
    gallery("text", Basics, Basics.typography, null),
    gallery("tasks", Basics, Basics.tasks, null),
    gallery("choices", Inputs, Inputs.view, "Choices"),
    gallery("ranges", Inputs, Inputs.view, "Ranges"),
    gallery("fields", Inputs, Inputs.view, "Fields"),
    gallery("dates-and-colors", Inputs, Inputs.view, "Dates, times and colors"),
    gallery("selects", Inputs, Inputs.view, "Menus of choices"),
    gallery("forms", Inputs, Inputs.view, "A form"),
    gallery("structures", Structures, Structures.view, "Tabs and disclosures"),
    gallery("toolbar", Structures, Structures.view, "Toolbar and breadcrumbs"),
    gallery("tree", Structures, Structures.view, "Sidebar, tree and outline in split panes"),
    gallery("table", Structures, Structures.view, "Table"),
    gallery("grid-view", Structures, Structures.view, "Grid"),
    gallery("items", Composites, Composites.view, "Items"),
    gallery("input-groups", Composites, Composites.view, "Input groups"),
    gallery("pagination", Composites, Composites.view, "Pagination"),
    gallery("button-groups", Advanced, Advanced.groups, null),
    gallery("multi-select", Advanced, Advanced.choices, null),
    gallery("date-range", Advanced, Advanced.dateRange, null),
    gallery("file-drop", Advanced, Advanced.drop, null),
    gallery("alerts", Feedback, Feedback.view, "Inline alerts"),
    gallery("empty-state", Feedback, Feedback.view, "Empty state"),
    gallery("skeleton", Feedback, Feedback.view, "Skeleton placeholders"),
    gallery("panels", Feedback, Feedback.panels, null),
    gallery("popover", Overlays, Overlays.view, "Popovers and tooltips"),
    gallery("menu", Overlays, Overlays.view, "Menus"),
    gallery("toasts", Overlays, Overlays.view, "Toasts"),
    gallery("text-area", TextPages, TextPages.editing, "Text area"),
    gallery("code-editor", TextPages, TextPages.editing, "Code editor"),
    gallery("diff", TextPages, TextPages.editing, "Diff"),
    gallery("rich-text", TextPages, TextPages.editing, "Rich text"),
    gallery("markdown", TextPages, TextPages.markdownPage, "Rendered"),
    gallery("drawing", Drawing, Drawing.drawingPage, null),
    gallery("bars", Drawing, Drawing.chartsPage, "Bars"),
    gallery("transforms", MotionPage, MotionPage.look, null),
    gallery("motion", MotionPage, MotionPage.moving, null),
    gallery("drag-and-drop", Board, Board.view, "A board"),
    gallery("layout", Foundations, Foundations.layout, null),
    gallery("grid", Foundations, Foundations.grid, null),
    gallery("right-to-left", Foundations, Foundations.direction, null),
    gallery("shaders", Foundations, Foundations.shaders, null),
};

/// A Gallery page as a demo: with only its card `title`, or whole.
fn gallery(comptime name: []const u8, comptime T: type, comptime page: fn (*T, *ui.Context) void, comptime title: ?[]const u8) Demo {
    return .{ .name = name, .view = struct {
        var state: T = undefined;
        var made = false;

        fn get() ui.View {
            if (!made) {
                state = make(T);
                made = true;
            }
            return .init(&state, view);
        }

        fn view(s: *T, c: *ui.Context) void {
            {
                basics.only = title;
                defer basics.only = null;
                ui.scroll(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 16 });
                defer ui.end(c);
                page(s, c);
            }
            // What the Gallery builds over its pages.
            if (T == Overlays) s.toastLayer(c);
            if (T == Feedback) s.layers(c);
            if (T == Board) s.preview(c);
        }
    }.get };
}

/// A page's state as the Gallery makes it.
fn make(comptime T: type) T {
    const gpa = std.heap.page_allocator;
    if (!@hasDecl(T, "init")) return .{};
    const Init = @TypeOf(T.init);
    const params = @typeInfo(Init).@"fn".param_types;
    if (params[0] == *T) {
        var s: T = .{};
        s.init();
        return s;
    }
    const made = T.init(gpa);
    return if (@typeInfo(@TypeOf(made)) == .error_union) made catch @panic("out of memory") else made;
}
