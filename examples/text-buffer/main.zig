//! A large editable document: 100 000 lines in a rope, edited by a text
//! area that lays out only the lines in view.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const Editor = struct {
    doc: ui.TextArea,

    fn view(e: *Editor, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 10 });
        defer ui.end(c);
        ui.text(c, "Indexed text input", .{ .size = 22, .weight = .bold });
        ui.text(c, c.print("{d} lines · {d} bytes · version {d}", .{ e.doc.doc.lineCount(), e.doc.len(), e.doc.doc.spliceSeq() }), .{ .color = c.theme.muted });
        _ = ui.textArea(c, &e.doc, .{ .height = .fill, .mono = true, .wrap = false });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Text Buffer" });
    defer app.destroy();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(init.gpa);
    for (0..100_000) |i| try source.print(init.gpa, "Line {d}: editable text, 😀, العربية, עברית\n", .{i + 1});
    var e: Editor = .{ .doc = .init(init.gpa, source.items) };
    defer e.doc.deinit();
    try app.setMenu(&.{ .{ .role = .app_menu }, .{ .role = .edit_menu } });
    _ = try app.newWindow(.{
        .title = "Indexed text buffer",
        .width = 900,
        .height = 650,
        .content = .{ .view = .init(&e, Editor.view) },
    });
    try app.run();
}
