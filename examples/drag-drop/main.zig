//! Drag and drop of notes, text, URLs and files in two windows of native
//! UI: within a window, out to other apps (where myzig has the system's
//! drag: Windows), and files dropped on the windows from file managers.
//! Hold Shift to move rather than copy.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const transfer = myzig.transfer;

const note_format = "application/vnd.myzig.example-note+json";
const wanted = [_][]const u8{ note_format, transfer.file_list, transfer.uri_list, transfer.text };

const Note = struct {
    id: u32,
    title: []const u8,

    fn json(n: *Note, gpa: std.mem.Allocator) anyerror![]u8 {
        return std.json.Stringify.valueAlloc(gpa, n.*, .{});
    }
};

const Demo = struct {
    gpa: std.mem.Allocator,
    next_id: u32 = 2,
    file: []const u8,
};

const Pane = struct {
    demo: *Demo,
    name: []const u8,
    notes: std.ArrayList(Note) = .empty,
    /// Titles of the notes, owned.
    arena: std.heap.ArenaAllocator,
    status: std.ArrayList(u8) = .empty,
    /// The note a drag carries, as it was when the drag started.
    frozen: Note = .{ .id = 0, .title = "" },
    dnd: ui.DragDrop = .{},

    fn deinit(p: *Pane) void {
        const gpa = p.demo.gpa;
        p.notes.deinit(gpa);
        p.arena.deinit();
        p.status.deinit(gpa);
        p.dnd.deinit();
    }

    fn setStatus(p: *Pane, comptime fmt: []const u8, args: anytype) void {
        p.status.clearRetainingCapacity();
        p.status.print(p.demo.gpa, fmt, args) catch {};
        std.log.info("{s}: {s}", .{ p.name, p.status.items });
    }

    fn completed(p: *Pane, f: ui.DragFinished) void {
        if (f.canceled) p.setStatus("Drag canceled", .{}) else if (f.effect == .move) p.setStatus("Move completed", .{}) else p.setStatus("Copy completed", .{});
    }

    fn noteData(p: *Pane, n: Note) !transfer.Data {
        p.frozen = n;
        return transfer.Data.init(p.demo.gpa, &.{.{ .reps = &.{
            transfer.bytes(transfer.text, n.title),
            transfer.lazy(note_format, .of(&p.frozen, Note.json)),
        } }});
    }

    fn receive(p: *Pane, data: *transfer.Data) void {
        const gpa = p.demo.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const f = data.preferred(&wanted) orelse return;
        if (std.mem.eql(u8, f, note_format)) {
            const b = data.read(a, f) catch |err| return p.setStatus("{t}", .{err});
            const parsed = std.json.parseFromSliceLeaky(Note, a, b, .{}) catch |err| return p.setStatus("{t}", .{err});
            p.demo.next_id += 1;
            const title = p.arena.allocator().dupe(u8, parsed.title) catch return;
            p.notes.append(gpa, .{ .id = p.demo.next_id, .title = title }) catch return;
            p.setStatus("Received note: {s}", .{title});
        } else if (std.mem.eql(u8, f, transfer.text)) {
            p.setStatus("Received text: {s}", .{data.read(a, f) catch ""});
        } else {
            const files = data.files(a) catch &.{};
            if (files.len > 0) {
                p.setStatus("Received files: {s}", .{std.mem.join(a, ", ", @ptrCast(files)) catch ""});
            } else p.setStatus("Received URLs: {s}", .{data.read(a, transfer.uri_list) catch ""});
        }
    }

    fn view(p: *Pane, c: *ui.Context) void {
        const th = c.theme;
        const gpa = p.demo.gpa;
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        ui.text(c, p.name, .{ .size = 24, .weight = .bold });
        ui.text(c, "Drag a card to the drop zone, a text editor, or Explorer. Drop files here from a file manager.", .{ .wrap = true, .color = th.muted });
        var remove: ?u32 = null;
        for (p.notes.items) |n| {
            ui.key(c, c.print("note-{d}", .{n.id}));
            var d = p.dnd.draggable(c, .{ .width = .fill, .padding = .all(14), .radius = 8, .border = th.border, .background = th.surface }, .{ .effects = .copy_move });
            if (d.starting) if (p.noteData(n)) |data| d.offer(data) else |_| {};
            ui.text(c, n.title, .{});
            if (d.end().finished) |f| {
                p.completed(f);
                if (f.effect == .move) remove = n.id;
            }
        }
        if (remove) |id| for (p.notes.items, 0..) |n, i| if (n.id == id) {
            _ = p.notes.orderedRemove(i);
            break;
        };
        const sources = [_]struct { label: []const u8, kind: enum { url, file } }{
            .{ .label = "Drag the myzig website URL", .kind = .url },
            .{ .label = "Drag a sample .txt file", .kind = .file },
        };
        for (sources) |s| {
            var d = p.dnd.draggable(c, .{ .width = .fill, .padding = .all(12), .radius = 8, .border = th.border }, .{});
            if (d.starting) {
                const data = switch (s.kind) {
                    .url => transfer.Data.init(gpa, &.{.{ .reps = &.{
                        transfer.bytes(transfer.uri_list, "https://github.com/egoist/mygo"),
                        transfer.bytes(transfer.text, "https://github.com/egoist/mygo"),
                    } }}),
                    .file => transfer.fileData(gpa, &.{p.demo.file}),
                };
                if (data) |x| d.offer(x) else |_| {}
            }
            ui.text(c, s.label, .{});
            if (d.end().finished) |f| p.completed(f);
        }

        const zone = c.open(.{ .width = .fill, .grow = 1, .min_height = 100, .padding = .all(16), .radius = 8, .border = th.border, .border_width = 2 }, "zone");
        const t = p.dnd.target(c, zone, .{ .formats = &wanted, .effects = .copy_move });
        if (t.over) {
            c.node(zone).style.border = th.accent;
            c.node(zone).style.background = th.surface;
        }
        ui.text(c, "Drop here", .{ .weight = .bold });
        c.end();
        if (t.dropped) |drop| p.receive(drop.data);
        ui.text(c, p.status.items, .{ .wrap = true, .size = 12, .color = th.muted });
        p.dnd.preview(c);
    }

    /// Files dropped on the window from a file manager.
    fn droppedFiles(p: *Pane, _: *myzig.Window, paths: []const []const u8) void {
        var data = transfer.fileData(p.demo.gpa, paths) catch return;
        defer data.deinit();
        p.receive(&data);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const app = try myzig.App.create(init, .{ .name = "Drag" });
    defer app.destroy();

    // A sample file to drag out, in a temporary directory.
    const tmp = try myzig.path(gpa, .temp, "myzig-drag-demo");
    defer gpa.free(tmp);
    try std.Io.Dir.cwd().createDirPath(io, tmp);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    const file = try std.fs.path.join(gpa, &.{ tmp, "myzig drag sample.txt" });
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "A file dragged from myzig native UI.\n" });

    var demo: Demo = .{ .gpa = gpa, .file = file };
    var panes: [2]Pane = undefined;
    for (&panes, [_][]const u8{ "Left", "Right" }, 0..) |*p, name, i| {
        p.* = .{ .demo = &demo, .name = name, .arena = .init(gpa) };
        const title = try std.fmt.allocPrint(p.arena.allocator(), "A note from {s}", .{name});
        try p.notes.append(gpa, .{ .id = @intCast(i + 1), .title = title });
        try p.status.appendSlice(gpa, "Escape cancels a drag.");
    }
    defer for (&panes) |*p| p.deinit();
    for (&panes, 0..) |*p, i| {
        const win = try app.newWindow(.{
            .title = if (i == 0) "myzig Drag — Left" else "myzig Drag — Right",
            .width = 440,
            .height = 580,
            .x = 60 + @as(f64, @floatFromInt(i)) * 480,
            .y = 80,
            .on_drop = .of(p, Pane.droppedFiles),
            .content = .{ .view = .init(p, Pane.view) },
        });
        // Drags leaving the window go on in the system's, where it has one.
        p.dnd.external = myzig.systemDrag(win);
    }
    try app.run();
}
