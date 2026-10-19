//! Code editor: myzig's code editor, its diff viewer and its text area.
//! Files of several languages to edit (syntax colors, indentation,
//! brackets, find and replace with Ctrl/⌘F and Ctrl+H/⌘⌥F, Ctrl+G to go to
//! a line, Alt+Z to wrap), the changes made to each against the file as it
//! was, unified or side by side, and notes in a plain text area.
//!
//!     zig build run-code-editor
//!     zig-out/bin/code-editor --myzig-snapshot=editor.png
//!     zig-out/bin/code-editor --myzig-snapshot=diff.png --myzig-script="click:Changes"
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const samples = @import("samples.zig");

const File = struct {
    name: []const u8,
    original: []const u8,
    editor: ui.CodeEditor,
    diff: ui.DiffView,
    /// The editor's version the diff was made of.
    diffed: ?u64 = null,
};

const App = struct {
    gpa: std.mem.Allocator,
    files: [samples.files.len]File = undefined,
    selected: usize = 0,
    page: usize = 0,
    split: usize = 0,
    notes: ui.TextArea,

    fn init(gpa: std.mem.Allocator) !App {
        var a: App = .{ .gpa = gpa, .notes = .init(gpa, "") };
        for (samples.files, 0..) |f, i| {
            a.files[i] = .{
                .name = f.name,
                .original = f.text,
                .editor = .init(gpa, f.text, f.name),
                .diff = try .init(gpa, f.text, f.text, f.name),
            };
        }
        // A few changes, as if made already: the changes page has some.
        for (samples.edits) |e| {
            const ta = &a.files[e.file].editor.area;
            const text = ta.text(gpa);
            defer gpa.free(text);
            const at = std.mem.indexOf(u8, text, e.find) orelse continue;
            ta.doc.replace(at, at + e.find.len, e.replace);
        }
        return a;
    }

    fn deinit(a: *App) void {
        for (&a.files) |*f| {
            f.editor.deinit();
            f.diff.deinit();
        }
        a.notes.deinit();
    }

    fn view(a: *App, c: *ui.Context) void {
        const t = c.theme;
        ui.row(c, .{ .width = .fill, .height = .fill, .align_items = .stretch });
        defer ui.end(c);

        // The files.
        ui.column(c, .{ .width = .{ .px = 180 }, .padding = .xy(8, 12), .gap = 2, .background = t.surface });
        ui.text(c, "Files", .{ .size = 11, .weight = .semibold, .color = t.muted });
        for (&a.files, 0..) |*f, i| {
            const modified = f.editor.area.doc.canUndo();
            const label = if (modified) c.print("{s} •", .{f.name}) else f.name;
            if (ui.button(c, label, .{ .variant = if (i == a.selected) .secondary else .ghost, .width = .fill, .size = 13 }).clicked) a.selected = i;
        }
        ui.end(c);
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = t.border }, .none, null);

        ui.column(c, .{ .grow = 1, .height = .fill });
        defer ui.end(c);
        const f = &a.files[a.selected];
        ui.row(c, .{ .width = .fill, .padding = .xy(12, 8), .gap = 12, .align_items = .center });
        _ = ui.segmented(c, &.{ "Editor", "Changes", "Notes" }, &a.page);
        ui.spacer(c);
        switch (a.page) {
            0 => {
                if (ui.button(c, "Find", .{ .variant = .ghost, .size = 13 }).clicked) f.editor.openFind(false);
                _ = ui.toggle(c, "Wrap", &f.editor.wrap);
            },
            1 => {
                const st = f.diff.stats();
                ui.text(c, c.print("+{d}  −{d}", .{ st.added, st.deleted }), .{ .size = 13, .color = t.muted });
                if (ui.segmented(c, &.{ "Unified", "Split" }, &a.split)) f.diff.setMode(if (a.split == 1) .split else .unified);
            },
            else => {},
        }
        ui.end(c);
        ui.divider(c);

        switch (a.page) {
            0 => {
                _ = ui.codeEditor(c, &f.editor, .{});
                a.statusBar(c, f);
            },
            1 => {
                // The diff of the editor's text against the file as it was.
                if (f.diffed != f.editor.area.doc.version) {
                    const now = f.editor.area.text(a.gpa);
                    defer a.gpa.free(now);
                    f.diff.set(f.original, now) catch {};
                    f.diffed = f.editor.area.doc.version;
                }
                ui.diffView(c, &f.diff, .{});
            },
            else => {
                ui.column(c, .{ .width = .fill, .grow = 1, .padding = .all(16), .gap = 8 });
                ui.text(c, "Notes", .{ .size = 15, .weight = .semibold });
                _ = ui.textArea(c, &a.notes, .{ .placeholder = "Notes about these files: they wrap, scroll and undo.", .height = .fill });
                ui.end(c);
            },
        }
    }

    fn statusBar(a: *App, c: *ui.Context, f: *File) void {
        _ = a;
        const t = c.theme;
        const ta = &f.editor.area;
        const line = ta.caretLine();
        const col = ta.sel.caret - ta.doc.lineStart(line);
        ui.divider(c);
        ui.row(c, .{ .width = .fill, .padding = .xy(12, 5), .gap = 16, .align_items = .center });
        defer ui.end(c);
        ui.text(c, c.print("Ln {d}, Col {d}", .{ line + 1, col + 1 }), .{ .size = 12, .color = t.muted });
        ui.text(c, c.print("{d} lines", .{ta.doc.lineCount()}), .{ .size = 12, .color = t.muted });
        ui.spacer(c);
        ui.text(c, if (f.editor.wrap) "Wrap" else "No wrap", .{ .size = 12, .color = t.muted });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Code editor" });
    defer app.destroy();
    var state = try App.init(init.gpa);
    defer state.deinit();
    _ = try app.newWindow(.{
        .title = "Code editor",
        .width = 980,
        .height = 680,
        .min_width = 560,
        .min_height = 360,
        .content = .{ .view = .init(&state, App.view) },
    });
    try app.run();
}
