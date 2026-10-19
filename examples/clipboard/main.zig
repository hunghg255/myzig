//! One data model for copying and dragging a note: the same note as text,
//! HTML, and JSON made only when a receiver asks for it.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const transfer = myzig.transfer;

const note_format = "application/vnd.myzig.clipboard-note+json";
const wanted = [_][]const u8{ note_format, transfer.text, transfer.file_list, transfer.uri_list };

const Note = struct {
    title: []const u8,
    body: []const u8,

    /// The lazy representation: made once per drag, when a target reads it.
    fn json(n: *Note, gpa: std.mem.Allocator) anyerror![]u8 {
        demo_ptr.providers += 1;
        return std.json.Stringify.valueAlloc(gpa, n.*, .{});
    }
};

var demo_ptr: *Demo = undefined;

const Demo = struct {
    gpa: std.mem.Allocator,
    title: ui.TextBuffer = .{},
    body: ui.TextArea,
    path: ui.TextBuffer = .{},
    /// What the alternatives of the last copy or drag describe, frozen.
    frozen: Note = .{ .title = "", .body = "" },
    frozen_mem: std.heap.ArenaAllocator,
    status: std.ArrayList(u8) = .empty,
    providers: u32 = 0,
    dnd: ui.DragDrop = .{},

    fn setStatus(d: *Demo, comptime fmt: []const u8, args: anytype) void {
        d.status.clearRetainingCapacity();
        d.status.print(d.gpa, fmt, args) catch {};
    }

    fn freeze(d: *Demo) void {
        _ = d.frozen_mem.reset(.retain_capacity);
        const a = d.frozen_mem.allocator();
        d.frozen = .{ .title = a.dupe(u8, d.title.text()) catch "", .body = d.body.text(a) };
    }

    /// Text, HTML and lazy JSON of the note as it is now.
    fn noteData(d: *Demo) !transfer.Data {
        d.freeze();
        const a = d.frozen_mem.allocator();
        const plain = try std.fmt.allocPrint(a, "{s}\n{s}", .{ d.frozen.title, d.frozen.body });
        const html = try std.fmt.allocPrint(a, "<h1>{f}</h1><p>{f}</p>", .{ escape(d.frozen.title), escape(d.frozen.body) });
        return transfer.Data.init(d.gpa, &.{.{ .reps = &.{
            transfer.bytes(transfer.text, plain),
            transfer.bytes(transfer.html, html),
            transfer.lazy(note_format, .of(&d.frozen, Note.json)),
        } }});
    }

    /// Takes a note, text or files, in that order of preference.
    fn receive(d: *Demo, data: *transfer.Data) void {
        var arena: std.heap.ArenaAllocator = .init(d.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const f = data.preferred(&wanted) orelse return d.setStatus("No supported format", .{});
        if (std.mem.eql(u8, f, note_format) or std.mem.eql(u8, f, transfer.text)) {
            const b = data.read(a, f) catch |err| return d.setStatus("{t}", .{err});
            if (f.ptr == note_format.ptr) {
                d.takeJson(b) catch |err| return d.setStatus("{t}", .{err});
            } else d.body.setText(b);
            d.setStatus("Received {s}", .{f});
        } else {
            const files = data.files(a) catch return;
            var list: std.ArrayList(u8) = .empty;
            for (files, 0..) |p, i| list.print(a, "{s}{s}", .{ if (i > 0) ", " else "", p }) catch {};
            d.setStatus("Files: {s}", .{list.items});
        }
    }

    fn takeJson(d: *Demo, b: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Note, d.gpa, b, .{});
        defer parsed.deinit();
        d.title.set(parsed.value.title);
        d.body.setText(parsed.value.body);
    }

    fn copy(d: *Demo) void {
        d.freeze();
        const a = d.frozen_mem.allocator();
        const plain = std.fmt.allocPrint(a, "{s}\n{s}", .{ d.frozen.title, d.frozen.body }) catch return;
        const html = std.fmt.allocPrint(a, "<h1>{f}</h1><p>{f}</p>", .{ escape(d.frozen.title), escape(d.frozen.body) }) catch return;
        // The system clipboard takes text and HTML; lazy formats only drag.
        myzig.clipboard.writeHtml(d.gpa, html, plain) catch |err| return d.setStatus("{t}", .{err});
        d.setStatus("Copied as text and HTML", .{});
    }

    fn paste(d: *Demo) void {
        if (myzig.clipboard.readFiles(d.gpa) catch null) |files| {
            defer {
                for (files) |p| d.gpa.free(p);
                d.gpa.free(files);
            }
            if (files.len > 0) {
                var data = transfer.fileData(d.gpa, @ptrCast(files)) catch return;
                defer data.deinit();
                return d.receive(&data);
            }
        }
        const s = (myzig.clipboard.readText(d.gpa) catch null) orelse return d.setStatus("No supported clipboard format", .{});
        defer d.gpa.free(s);
        // A note copied as JSON by another app comes as its text.
        if (d.takeJson(s)) |_| return d.setStatus("Received {s}", .{note_format}) else |_| {}
        d.body.setText(s);
        d.setStatus("Received {s}", .{transfer.text});
    }

    fn view(d: *Demo, c: *ui.Context) void {
        const th = c.theme;
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        ui.text(c, "Clipboard and drag data", .{ .size = 24, .weight = .bold });
        ui.text(c, "Copy or drag the same note as text, HTML, or lazy JSON. Paste in another app to use its preferred representation.", .{ .wrap = true, .color = th.muted });
        _ = ui.textField(c, &d.title, .{ .placeholder = "Title", .width = .fill });
        _ = ui.textArea(c, &d.body, .{ .height = .{ .px = 90 } });
        {
            ui.row(c, .{ .gap = 8 });
            defer ui.end(c);
            if (ui.button(c, "Copy note", .{}).clicked) d.copy();
            if (ui.button(c, "Paste", .{}).clicked) d.paste();
        }
        var drag = d.dnd.draggable(c, .{ .width = .fill, .padding = .all(16), .border = th.border, .radius = 8 }, .{});
        if (drag.starting) if (d.noteData()) |data| drag.offer(data) else |_| {};
        ui.text(c, "Drag this note", .{ .weight = .bold });
        _ = drag.end();

        const zone = c.open(.{ .width = .fill, .padding = .all(16), .border = th.border, .radius = 8 }, "zone");
        const t = d.dnd.target(c, zone, .{ .formats = &wanted });
        if (t.over) {
            c.node(zone).style.border = th.accent;
            c.node(zone).style.border_width = 2;
        }
        ui.text(c, "Drop notes, text, or files here", .{});
        c.end();
        if (t.dropped) |drop| d.receive(drop.data);

        {
            ui.row(c, .{ .width = .fill, .gap = 8 });
            defer ui.end(c);
            _ = ui.textField(c, &d.path, .{ .placeholder = "Absolute file path", .width = .fill });
            if (ui.button(c, "Copy file", .{}).clicked) {
                if (myzig.clipboard.writeFiles(d.gpa, &.{d.path.text()})) |_| d.setStatus("Copied native file list", .{}) else |err| d.setStatus("{t}", .{err});
            }
        }
        ui.text(c, c.print("JSON requests: {d}", .{d.providers}), .{ .color = th.muted });
        ui.text(c, d.status.items, .{ .wrap = true });
        d.dnd.preview(c);
    }

    /// Files dropped on the window from the file manager.
    fn dropped(d: *Demo, _: *myzig.Window, paths: []const []const u8) void {
        var data = transfer.fileData(d.gpa, paths) catch return;
        defer data.deinit();
        d.receive(&data);
    }
};

/// Text escaped for HTML, as a `{f}` argument.
fn escape(s: []const u8) Escaped {
    return .{ .s = s };
}

const Escaped = struct {
    s: []const u8,

    pub fn format(e: Escaped, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (e.s) |ch| switch (ch) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(ch),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Clipboard" });
    defer app.destroy();
    var d: Demo = .{ .gpa = init.gpa, .body = .init(init.gpa, "Shared clipboard and drag representations."), .frozen_mem = .init(init.gpa) };
    defer {
        d.body.deinit();
        d.frozen_mem.deinit();
        d.status.deinit(init.gpa);
        d.dnd.deinit();
    }
    demo_ptr = &d;
    d.title.set("A portable note");
    const win = try app.newWindow(.{
        .title = "myzig Clipboard",
        .width = 640,
        .height = 580,
        .on_drop = .of(&d, Demo.dropped),
        .content = .{ .view = .init(&d, Demo.view) },
    });
    // Drags leaving the window go on in the system's, where it has one.
    d.dnd.external = myzig.systemDrag(win);
    try app.run();
}
