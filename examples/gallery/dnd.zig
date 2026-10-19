//! The gallery's drag and drop: cards moved between the columns of a
//! board (or copied, with Control), and dropped on the trash.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const transfer = myzig.transfer;
const card = @import("basics.zig").card;

const Task = struct { id: u32, title: []const u8, column: u8 };

const titles = [_][]const u8{ "Sketch the board", "Write the parser", "Draw the icons", "Test on Linux", "Ship 0.2", "Fix the scrollbar" };
const columns = [_][]const u8{ "To do", "Doing", "Done" };

pub const Board = struct {
    tasks: [32]Task = undefined,
    count: usize = 0,
    next: u32 = 0,
    dnd: ui.DragDrop = .{},
    gpa: std.mem.Allocator,
    status: []const u8 = "Drag a card to another column, or onto the trash.",

    pub fn init(gpa: std.mem.Allocator) Board {
        var b: Board = .{ .gpa = gpa };
        for (titles, 0..) |t, i| b.add(t, @intCast(i % 3));
        return b;
    }

    pub fn deinit(b: *Board) void {
        b.dnd.deinit();
    }

    fn add(b: *Board, title: []const u8, column: u8) void {
        if (b.count == b.tasks.len) return;
        b.tasks[b.count] = .{ .id = b.next, .title = title, .column = column };
        b.count += 1;
        b.next += 1;
    }

    fn find(b: *Board, id: u32) ?usize {
        for (b.tasks[0..b.count], 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    pub fn view(b: *Board, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Drag and drop");
        card(c, "A board");
        defer ui.end(c);
        ui.text(c, b.status, .{ .color = th.muted, .wrap = true });
        ui.row(c, .{ .width = .fill, .gap = 12, .align_items = .stretch });
        defer ui.end(c);
        const fmt = transfer.value_format(Task);
        for (columns, 0..) |name, col| {
            const zone = c.open(.{ .grow = 1, .width = .fill, .min_height = 220, .padding = .all(10), .gap = 8, .radius = 10, .background = th.background, .border = th.border }, name);
            const t = b.dnd.target(c, zone, .{ .formats = &.{fmt}, .effects = .copy_move });
            if (t.over) {
                c.node(zone).style.border = th.accent;
                c.node(zone).style.border_width = 2;
            }
            ui.text(c, name, .{ .weight = .semibold, .size = 13 });
            for (b.tasks[0..b.count]) |*task| {
                if (task.column != col) continue;
                ui.key(c, c.print("task-{d}", .{task.id}));
                var d = b.dnd.draggable(c, .{ .width = .fill, .padding = .all(10), .radius = 8, .background = th.surface, .border = th.border, .shadow = .{ .blur = 4, .y = 1 } }, .{ .effects = .copy_move });
                if (d.starting) if (transfer.valueData(b.gpa, Task, task)) |data| d.offer(data) else |_| {};
                ui.text(c, task.title, .{});
                if (d.end().finished) |f| {
                    if (f.canceled) b.status = "Drag canceled.";
                }
            }
            c.end();
            if (t.dropped) |drop| if (drop.data.value(Task)) |task| {
                // Within the board a drag moves; Control copies. (Negotiation
                // prefers copy when both ends allow it, so the board decides.)
                if (drop.effect == .copy and c.input.ctrl) {
                    b.add(task.title, @intCast(col));
                    b.status = "Copied.";
                } else {
                    task.column = @intCast(col);
                    b.status = "Moved.";
                }
            };
        }
        const trash = c.open(.{ .width = .{ .px = 110 }, .padding = .all(10), .radius = 10, .align_items = .center, .justify = .center, .gap = 6, .border = th.border }, "trash");
        const t = b.dnd.target(c, trash, .{ .formats = &.{fmt}, .effects = .{ .move = true } });
        if (t.over) c.node(trash).style.background = th.danger.alpha(0.15);
        ui.icon(c, "trash", .{ .size = 22, .color = if (t.over) th.danger else th.muted });
        ui.text(c, "Trash", .{ .size = 12, .color = th.muted });
        c.end();
        if (t.dropped) |drop| if (drop.data.value(Task)) |task| if (b.find(task.id)) |i| {
            std.mem.copyForwards(Task, b.tasks[i .. b.count - 1], b.tasks[i + 1 .. b.count]);
            b.count -= 1;
            b.status = "Deleted.";
        };
    }

    /// The card that follows the pointer: built last, over everything.
    pub fn preview(b: *Board, c: *ui.Context) void {
        b.dnd.preview(c);
    }
};
