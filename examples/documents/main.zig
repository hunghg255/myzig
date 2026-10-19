//! A notes editor of Markdown and text files in native UI, built on
//! `myzig.Documents`: the File menu, a window per note, autosave, recovery
//! after a crash, and notes changed by other apps.
//!
//!     zig-out/bin/documents [file.md…]
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const Notes = myzig.Documents([]u8);
const Doc = Notes.Document;

/// A document's content: the file's text.
const Text = struct {
    fn read(gpa: std.mem.Allocator, bytes: []const u8) anyerror![]u8 {
        return gpa.dupe(u8, bytes);
    }
    fn write(_: std.mem.Allocator, content: *const []u8, w: *std.Io.Writer) anyerror!void {
        try w.writeAll(content.*);
    }
    fn free(gpa: std.mem.Allocator, content: []u8) void {
        gpa.free(content);
    }
    fn new(gpa: std.mem.Allocator) anyerror![]u8 {
        return gpa.alloc(u8, 0);
    }
    /// Undoing back to what the file has leaves the note unedited.
    fn equal(a: *const []u8, b: *const []u8) bool {
        return std.mem.eql(u8, a.*, b.*);
    }
};

/// The window of a document: the text its editor shows.
const Note = struct {
    gpa: std.mem.Allocator,
    doc: *Doc,
    win: *myzig.Window = undefined,
    editor: ui.TextArea,
    focused: bool = false,

    fn view(n: *Note, c: *ui.Context) void {
        const th = c.theme;
        const state = n.doc.state();
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        if (state.conflict) {
            ui.row(c, .{ .width = .fill, .padding = .all(10), .gap = 8, .align_items = .center, .background = ui.Color.hex(0xff9f0a).alpha(0.15) });
            defer ui.end(c);
            ui.column(c, .{ .grow = 1 });
            ui.text(c, "Another app changed this note. Save to keep yours, or revert to theirs.", .{ .wrap = true });
            ui.end(c);
            if (ui.button(c, "Revert", .{}).clicked) n.doc.revert() catch {};
            if (ui.button(c, "Save", .{ .variant = .primary }).clicked) _ = n.doc.saveAnyway();
        }
        // Focused from the start, once the editor has its id.
        if (!n.focused and n.editor.id != 0) {
            c.focus = n.editor.id;
            n.focused = true;
        }
        ui.column(c, .{ .width = .fill, .grow = 1, .padding = .xy(8, 6) });
        const r = ui.textArea(c, &n.editor, .{ .height = .fill, .mono = true, .bare = true, .placeholder = "Note" });
        ui.end(c);
        if (r.changed) n.doc.set(n.editor.text(n.gpa));
        ui.divider(c);
        ui.row(c, .{ .width = .fill, .padding = .xy(12, 6), .gap = 12 });
        defer ui.end(c);
        const text = n.doc.content;
        var words: usize = 0;
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |_| words += 1;
        ui.text(c, c.print("{d} words", .{words}), .{ .size = 12, .color = th.muted });
        ui.spacer(c);
        const status = if (state.path.len == 0) "Not saved" else if (state.read_only) "Read-only" else if (state.edited) "Edited" else "Saved";
        ui.text(c, status, .{ .size = 12, .color = th.muted });
    }

    /// Reverted, or changed by another app: show the file's text.
    fn reloaded(n: *Note, d: *Doc) void {
        n.editor.reset(d.content);
        n.win.redraw();
    }

    fn stateChanged(n: *Note, _: *Doc) void {
        n.win.redraw();
    }

    fn closed(n: *Note, _: *myzig.Window) void {
        n.editor.deinit();
        n.gpa.destroy(n);
    }
};

const Editor = struct {
    app: *myzig.App,
    host: *myzig.DocumentHost,
    notes: *Notes = undefined,

    /// Makes a document's window.
    fn window(e: *Editor, doc: *Doc) anyerror!*myzig.Window {
        const gpa = e.app.gpa;
        const n = try gpa.create(Note);
        n.* = .{ .gpa = gpa, .doc = doc, .editor = .init(gpa, doc.content) };
        n.win = try e.app.newWindow(.{
            .title = doc.name(),
            .width = 640,
            .height = 480,
            .state = myzig.windowState("note"),
            .on_close = .{ .ctx = n, .func = struct {
                fn f(ctx: *anyopaque, w: *myzig.Window) void {
                    Note.closed(@ptrCast(@alignCast(ctx)), w);
                }
            }.f },
            .content = .{ .view = .init(n, Note.view) },
        });
        doc.on_reload = .of(n, Note.reloaded);
        doc.on_state = .of(n, Note.stateChanged);
        // Closing the window closes its document.
        try e.host.attach(Notes, e.notes, n.win);
        return n.win;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const exts = [_][]const u8{ "md", "markdown", "txt" };
    const app = try myzig.App.create(init, .{ .name = "myzig Notes", .file_extensions = &exts });
    defer app.destroy();
    var host: myzig.DocumentHost = .{ .app = app };
    defer host.deinit();
    var editor: Editor = .{ .app = app, .host = &host };
    const data_dir = myzig.path(gpa, .data, app.options.name) catch null;
    defer if (data_dir) |d| gpa.free(d);
    const notes = try Notes.create(gpa, init.io, host.host(), .{
        .types = &.{
            .{ .name = "Markdown Document", .extensions = &.{ "md", "markdown" } },
            .{ .name = "Plain Text", .extensions = &.{"txt"} },
        },
        .read = Text.read,
        .write = Text.write,
        .free = Text.free,
        .new = Text.new,
        .equal = Text.equal,
        .window = .of(&editor, Editor.window),
        .app_name = app.options.name,
        .data_dir = data_dir,
    });
    defer notes.destroy();
    editor.notes = notes;
    app.options.on_open_file = .of(notes, Notes.openFile);
    try app.setMenu(&.{ .{ .role = .app_menu }, host.fileMenu(Notes, notes), .{ .role = .edit_menu }, .{ .role = .window_menu } });
    // The files the app was started with first, then what is left to open.
    host.start(Notes, notes);
    try app.run();
}
