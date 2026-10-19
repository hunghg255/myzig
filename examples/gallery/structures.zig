//! The gallery's structures: tabs, disclosures, an accordion, a split of
//! panes, a toolbar and breadcrumbs, a sidebar, a tree, an outline of a
//! thousand folders, a sortable table and a grid.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const card = @import("basics.zig").card;

const File = struct { name: []const u8, kind: []const u8, size: u32 };

const files = [_]File{
    .{ .name = "main.zig", .kind = "Zig source", .size = 12_400 },
    .{ .name = "build.zig", .kind = "Zig source", .size = 3_100 },
    .{ .name = "README.md", .kind = "Markdown", .size = 5_800 },
    .{ .name = "logo.svg", .kind = "SVG image", .size = 2_200 },
    .{ .name = "notes.txt", .kind = "Plain text", .size = 640 },
    .{ .name = "photo.png", .kind = "PNG image", .size = 845_000 },
    .{ .name = "theme.json", .kind = "JSON", .size = 1_200 },
};

const columns: []const ui.TableColumn = &.{
    .{ .title = "Name", .sortable = true },
    .{ .title = "Kind", .width = 120, .sortable = true },
    .{ .title = "Size", .width = 90, .alignment = .end, .sortable = true },
};

pub const Structures = struct {
    tab: usize = 0,
    advanced: bool = false,
    sections: [3]bool = .{ true, false, false },
    pane: f32 = 200,
    chosen: []const u8 = "src/main.zig",
    src: bool = true,
    ui_dir: bool = false,
    bold: bool = true,
    italic: bool = false,
    crumb: usize = 3,
    mailbox: []const u8 = "inbox",
    mailboxes: bool = true,
    folders: ui.OutlineState(u32) = .{},
    roots: [1000]u32 = blk: {
        var r: [1000]u32 = undefined;
        for (&r, 0..) |*v, i| v.* = @intCast(i);
        break :blk r;
    },
    kids: [20]u32 = undefined,
    table: ui.TableState = .{},
    order: [files.len]usize = .{ 0, 1, 2, 3, 4, 5, 6 },
    grid: ui.GridState = .{},

    pub fn deinit(s: *Structures, gpa: std.mem.Allocator) void {
        s.folders.deinit(gpa);
    }

    /// The outline's children: folders hold twenty files.
    pub fn children(s: *Structures, item: u32) []const u32 {
        if (item >= 1_000_000) return &.{};
        for (&s.kids, 0..) |*v, f| v.* = 1_000_000 + item * 100 + @as(u32, @intCast(f));
        return &s.kids;
    }

    fn sortFiles(s: *Structures) void {
        const sort = s.table.sort orelse return;
        const Ctx = struct {
            col: usize,
            desc: bool,
            fn less(ctx: @This(), a: usize, b: usize) bool {
                const fa = files[a];
                const fb = files[b];
                const lt = switch (ctx.col) {
                    0 => std.mem.lessThan(u8, fa.name, fb.name),
                    1 => std.mem.lessThan(u8, fa.kind, fb.kind),
                    else => fa.size < fb.size,
                };
                const gt = switch (ctx.col) {
                    0 => std.mem.lessThan(u8, fb.name, fa.name),
                    1 => std.mem.lessThan(u8, fb.kind, fa.kind),
                    else => fb.size < fa.size,
                };
                return if (ctx.desc) gt else lt;
            }
        };
        std.mem.sort(usize, &s.order, Ctx{ .col = sort.column, .desc = sort.descending }, Ctx.less);
    }

    pub fn view(s: *Structures, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Structures");
        {
            card(c, "Tabs and disclosures");
            defer ui.end(c);
            _ = ui.tabs(c, &.{ "General", "Appearance", "Advanced" }, &s.tab, .{});
            ui.text(c, switch (s.tab) {
                0 => "General settings: the name, the language and where files go.",
                1 => "Appearance: light, dark, or the system's.",
                else => "Advanced: for those who know what they do.",
            }, .{ .color = th.muted });
            const d = ui.collapsible(c, "More options", &s.advanced);
            if (d.shown) {
                ui.text(c, "Verbose logging", .{});
                ui.text(c, "Experimental features", .{});
            }
            d.end();
            var acc = ui.accordion(c, .{});
            defer acc.end();
            const titles = [_][]const u8{ "Shipping", "Returns", "Warranty" };
            const bodies = [_][]const u8{ "Free over $50, in two to four days.", "Within 30 days, in the box it came in.", "Two years, parts and labor." };
            for (titles, bodies, 0..) |title, body, i| {
                const it = acc.item(title, &s.sections[i]);
                defer it.end();
                if (it.shown) ui.text(c, body, .{ .color = th.muted });
            }
        }
        {
            card(c, "Toolbar and breadcrumbs");
            defer ui.end(c);
            var tb = ui.toolbar(c, .{});
            _ = tb.button("", .{ .icon = "chevron.left.forwardslash.chevron.right" });
            _ = tb.toggle("Bold", &s.bold);
            _ = tb.toggle("Italic", &s.italic);
            tb.separator();
            _ = tb.button("Disabled", .{ .disabled = true });
            tb.spacer();
            _ = tb.button("Share", .{ .icon = "arrow.up" });
            tb.end();
            _ = ui.breadcrumbs(c, &.{ "Macintosh HD", "Users", "ada", "Documents" }, &s.crumb, .{});
        }
        {
            card(c, "Sidebar, tree and outline in split panes");
            defer ui.end(c);
            ui.row(c, .{ .width = .fill, .height = .{ .px = 280 }, .border = th.border, .radius = 8, .clip = true });
            defer ui.end(c);
            var sb = ui.sidebar(c, &s.mailbox, .{ .width = .{ .px = 170 } });
            if (sb.section("Mailboxes", &s.mailboxes)) {
                sb.item("inbox", "Inbox", .{ .icon = "doc.text", .badge = "3" });
                sb.item("sent", "Sent", .{ .icon = "arrow.up" });
                sb.item("trash", "Trash", .{ .icon = "trash" });
            }
            if (sb.section("Tags", null)) {
                sb.item("work", "Work", .{});
                sb.item("home", "Home", .{});
            }
            _ = sb.end();
            var sp = ui.split(c, &s.pane, .{ .min = 120 });
            var tr = ui.tree(c, &s.chosen, .{});
            if (tr.item("src", "src", &s.src)) {
                defer tr.endChildren();
                if (tr.item("src/ui", "ui", &s.ui_dir)) {
                    defer tr.endChildren();
                    _ = tr.item("src/ui/list.zig", "list.zig", null);
                    _ = tr.item("src/ui/tree.zig", "tree.zig", null);
                }
                _ = tr.item("src/main.zig", "main.zig", null);
            }
            _ = tr.item("build.zig", "build.zig", null);
            _ = tr.end();
            sp.second();
            var rows = ui.outline(u32, c, &s.folders, &s.roots, s, .{ .row_height = 24 });
            while (rows.next()) |r| {
                if (r.item >= 1_000_000) {
                    ui.icon(c, "doc", .{ .size = 12, .color = th.muted });
                    ui.text(c, c.print("file {d}.{d}", .{ (r.item - 1_000_000) / 100, r.item % 100 }), .{});
                } else {
                    ui.icon(c, "folder", .{ .size = 12, .color = th.accent });
                    ui.text(c, c.print("Folder {d}", .{r.item}), .{});
                }
            }
            _ = rows.end();
            _ = sp.end();
        }
        {
            card(c, "Table");
            defer ui.end(c);
            ui.column(c, .{ .width = .fill, .height = .{ .px = 250 } });
            defer ui.end(c);
            var tb = ui.table(c, &s.table, columns, files.len, .{});
            while (tb.next()) |row| {
                const f = files[s.order[row]];
                while (tb.cell()) |col| switch (col) {
                    0 => ui.text(c, f.name, .{ .color = tb.textColor() }),
                    1 => ui.text(c, f.kind, .{ .color = th.muted }),
                    else => ui.text(c, c.print("{d:.1} KB", .{@as(f64, @floatFromInt(f.size)) / 1000}), .{ .mono = true, .size = 12 }),
                };
            }
            if (tb.end().sorted) s.sortFiles();
        }
        {
            card(c, "Grid");
            defer ui.end(c);
            ui.column(c, .{ .width = .fill, .height = .{ .px = 230 } });
            defer ui.end(c);
            var g = ui.gridView(c, &s.grid, .{ .count = 60, .min_item_width = 96, .row_height = 80 });
            while (g.next()) |i| {
                const hue: f32 = @floatFromInt(i * 37 % 360);
                ui.column(c, .{ .width = .fill, .height = .fill, .radius = 8, .align_items = .center, .justify = .center, .background = hueColor(hue) });
                ui.text(c, c.print("Photo {d}", .{i + 1}), .{ .size = 12, .color = .white, .weight = .semibold });
                ui.end(c);
            }
            _ = g.end();
        }
    }
};

/// A saturated color of `hue` degrees.
fn hueColor(hue: f32) ui.Color {
    const h = hue / 60;
    const x = 1 - @abs(@mod(h, 2) - 1);
    const rgb: [3]f32 = switch (@as(u32, @intFromFloat(h))) {
        0 => .{ 1, x, 0 },
        1 => .{ x, 1, 0 },
        2 => .{ 0, 1, x },
        3 => .{ 0, x, 1 },
        4 => .{ x, 0, 1 },
        else => .{ 1, 0, x },
    };
    const l = 0.25;
    return .{ .r = 0.2 + rgb[0] * 0.6 - l * 0.2, .g = 0.2 + rgb[1] * 0.6 - l * 0.2, .b = 0.2 + rgb[2] * 0.6 - l * 0.2 };
}
