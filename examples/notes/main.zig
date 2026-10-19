//! Notes: a notes app in native UI. Notes in a sidebar, each edited as
//! rich text (`ui.richTextEditor`) with a toolbar of its formats, links
//! asked for in a bar under it, Markdown shortcuts as you type, and the
//! clipboard as plain text or Markdown. The notes are kept in memory.
//!
//!     zig build run-notes
//!     zig-out/bin/notes --myzig-snapshot=notes.png
//!     zig-out/bin/notes --myzig-snapshot=notes.png --myzig-script="click:Plans;type:Hi"
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const samples = [_][]const u8{
    \\# Groceries
    \\
    \\For the **weekend**, and *nothing* else.
    \\
    \\- [x] Oat milk
    \\- [ ] Bread, from the bakery on the corner
    \\- [ ] Apples
    \\    - the green ones
    \\
    \\> Remember the bags.
    ,
    \\# Plans
    \\
    \\1. Port the editor
    \\2. Write its tests
    \\    1. typing and blocks
    \\    2. marks and the clipboard
    \\3. Ship it
    \\
    \\See [the docs](https://ziglang.org/documentation/master/) for `std.ArrayList`.
    \\
    \\```
    \\var note = ui.RichText.initMarkdown(gpa, md);
    \\defer note.deinit();
    \\```
    ,
    \\# Ideas
    \\
    \\Type `# ` for a heading, `- ` for a list, `[ ] ` for a task, `> ` for a quotation, and three backticks then Enter for code. **Bold**, *italic*, `code` and ~~strikethrough~~ format as their closing mark is typed.
    ,
};

const Note = struct {
    id: [12]u8 = undefined,
    id_len: usize = 0,
    rt: ui.RichText,

    fn idStr(n: *const Note) []const u8 {
        return n.id[0..n.id_len];
    }

    /// The first line, or "New Note".
    fn title(n: *const Note) []const u8 {
        for (n.rt.doc.blocks.items) |*b| {
            const s = std.mem.trim(u8, b.str(), " \t");
            if (s.len > 0) return s[0..@min(s.len, 40)];
        }
        return "New Note";
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    notes: std.ArrayList(*Note) = .empty,
    selected: []const u8 = "",
    next_id: usize = 1,
    /// The bar asking for a link's URL.
    asking_link: bool = false,
    link: ui.TextBuffer = .{},
    /// Copy writes Markdown (else plain text), and text pastes as it.
    markdown_clipboard: bool = false,
    /// The last link clicked with ⌘ (Ctrl).
    clicked: []const u8 = "",
    /// A new note takes the keyboard once its editor is built.
    focus_editor: bool = false,

    fn add(a: *App, md: []const u8) *Note {
        const n = a.gpa.create(Note) catch @panic("OOM");
        n.* = .{ .rt = .initMarkdown(a.gpa, md) };
        n.id_len = if (std.fmt.bufPrint(&n.id, "n{d}", .{a.next_id})) |id| id.len else |_| 0;
        a.next_id += 1;
        a.notes.append(a.gpa, n) catch @panic("OOM");
        return n;
    }

    fn deinit(a: *App) void {
        for (a.notes.items) |n| {
            n.rt.deinit();
            a.gpa.destroy(n);
        }
        a.notes.deinit(a.gpa);
    }

    fn current(a: *App) ?*Note {
        for (a.notes.items) |n| if (std.mem.eql(u8, n.idStr(), a.selected)) return n;
        return null;
    }

    fn view(a: *App, c: *ui.Context) void {
        const t = c.theme;
        ui.row(c, .{ .width = .fill, .height = .fill, .align_items = .stretch });
        defer ui.end(c);

        ui.column(c, .{ .width = .{ .px = 220 }, .height = .fill, .background = t.surface });
        ui.row(c, .{ .width = .fill, .padding = .xy(12, 10), .align_items = .center });
        ui.text(c, "Notes", .{ .size = 15, .weight = .semibold });
        ui.spacer(c);
        if (ui.button(c, "New", .{ .variant = .ghost, .size = 13 }).clicked) {
            const n = a.add("");
            a.selected = n.idStr();
            a.focus_editor = true;
        }
        ui.end(c);
        var sb = ui.sidebar(c, &a.selected, .{ .width = .fill, .background = t.surface });
        for (a.notes.items) |n| sb.item(n.idStr(), n.title(), .{ .icon = "doc.text" });
        _ = sb.end();
        ui.end(c);
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = t.border }, .none, null);

        ui.column(c, .{ .grow = 1, .height = .fill });
        defer ui.end(c);
        const n = a.current() orelse {
            ui.column(c, .{ .width = .fill, .grow = 1, .align_items = .center, .justify = .center });
            ui.text(c, "No note chosen", .{ .color = t.muted });
            ui.end(c);
            return;
        };
        const tb = ui.richTextToolbar(c, &n.rt, .{});
        if (tb.link_requested) a.askLink(n);
        if (a.asking_link) a.linkBar(c, n);
        const r = ui.richTextEditor(c, &n.rt, .{
            .bare = true,
            .placeholder = "Write something. Markdown shortcuts format as you type.",
            .padding = .xy(28, 20),
            .clipboard = if (a.markdown_clipboard) .markdown else .plain,
        });
        if (r.link_requested) a.askLink(n);
        if (r.link_clicked) |u| a.clicked = u;
        if (a.focus_editor) {
            a.focus_editor = false;
            c.focus = n.rt.id;
            c.changed = true;
        }
        a.statusBar(c, n);
    }

    fn askLink(a: *App, n: *Note) void {
        a.asking_link = true;
        a.link.set(n.rt.formatting().link orelse "https://");
    }

    fn linkBar(a: *App, c: *ui.Context, n: *Note) void {
        ui.row(c, .{ .width = .fill, .padding = .xy(12, 6), .gap = 8, .align_items = .center });
        defer ui.end(c);
        ui.text(c, "Link", .{ .size = 13, .color = c.theme.muted });
        const f = ui.textField(c, &a.link, .{ .width = .fill, .placeholder = "https://" });
        if (ui.button(c, "Set", .{ .variant = .primary, .size = 13 }).clicked or f.submitted) {
            n.rt.setLink(a.link.text());
            a.asking_link = false;
            c.focus = n.rt.id;
        }
        if (ui.button(c, "Remove", .{ .variant = .ghost, .size = 13 }).clicked) {
            n.rt.setLink("");
            a.asking_link = false;
            c.focus = n.rt.id;
        }
        if (ui.button(c, "Cancel", .{ .variant = .ghost, .size = 13 }).clicked) a.asking_link = false;
    }

    fn statusBar(a: *App, c: *ui.Context, n: *Note) void {
        const t = c.theme;
        ui.divider(c);
        ui.row(c, .{ .width = .fill, .padding = .xy(12, 5), .gap = 16, .align_items = .center });
        defer ui.end(c);
        var words: usize = 0;
        for (n.rt.doc.blocks.items) |*b| {
            var it = std.mem.tokenizeAny(u8, b.str(), " \t");
            while (it.next()) |_| words += 1;
        }
        ui.text(c, c.print("{d} words, {d} blocks", .{ words, n.rt.doc.count() }), .{ .size = 12, .color = t.muted });
        if (a.clicked.len > 0) ui.text(c, c.print("Link: {s}", .{a.clicked}), .{ .size = 12, .color = t.accent });
        ui.spacer(c);
        _ = ui.toggle(c, "Copy as Markdown", &a.markdown_clipboard);
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Notes" });
    defer app.destroy();
    var state: App = .{ .gpa = init.gpa };
    defer state.deinit();
    for (samples) |md| _ = state.add(md);
    state.selected = state.notes.items[0].idStr();
    _ = try app.newWindow(.{
        .title = "Notes",
        .width = 940,
        .height = 640,
        .min_width = 560,
        .min_height = 360,
        .content = .{ .view = .init(&state, App.view) },
    });
    try app.run();
}
