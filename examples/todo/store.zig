//! The list, kept as JSON in the app's data directory. Its public methods
//! are callable from the frontend; every change is broadcast to every
//! window (`Changed`).
const std = @import("std");
const myzig = @import("myzig");

pub const Todo = struct {
    id: i64,
    title: []const u8,
    done: bool = false,
    /// Milliseconds since 1970.
    createdAt: i64,
};

/// Which todos are listed.
pub const Filter = enum { all, active, done };

/// Counters for the footer.
pub const Stats = struct { total: usize, active: usize };

/// Sent to every window whenever the list changes.
pub const Changed = myzig.Event("changed", Stats);

pub const Todos = struct {
    app: *myzig.App,
    gpa: std.mem.Allocator,
    path: []const u8,
    items: std.ArrayList(Todo) = .empty,
    /// The titles' memory.
    titles: std.heap.ArenaAllocator,
    next: i64 = 0,

    pub const myzig_params = .{ .list = .{"filter"}, .add = .{"title"}, .toggle = .{"id"}, .remove = .{"id"} };

    /// Loads the saved todos from `path`, if any.
    pub fn open(app: *myzig.App, path: []const u8) !Todos {
        var t: Todos = .{ .app = app, .gpa = app.gpa, .path = path, .titles = .init(app.gpa) };
        errdefer t.deinit();
        const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => return t,
            else => return err,
        };
        defer app.gpa.free(data);
        const items = try std.json.parseFromSliceLeaky([]Todo, t.titles.allocator(), data, .{ .ignore_unknown_fields = true });
        try t.items.appendSlice(t.gpa, items);
        for (items) |it| t.next = @max(t.next, it.id);
        return t;
    }

    fn deinit(t: *Todos) void {
        t.items.deinit(t.gpa);
        t.titles.deinit();
    }

    /// The todos matching `filter`, newest first.
    pub fn list(t: *Todos, call: *myzig.Call, filter: Filter) ![]const Todo {
        var out: std.ArrayList(Todo) = .empty;
        var i = t.items.items.len;
        while (i > 0) {
            i -= 1;
            const it = t.items.items[i];
            if (filter == .all or (filter == .done) == it.done) try out.append(call.arena, it);
        }
        return out.items;
    }

    /// Creates a todo.
    pub fn add(t: *Todos, title: []const u8) !Todo {
        const trimmed = std.mem.trim(u8, title, " \t");
        if (trimmed.len == 0) return error.TitleRequired;
        t.next += 1;
        const now = std.Io.Timestamp.now(t.app.io, .real);
        const todo: Todo = .{ .id = t.next, .title = try t.titles.allocator().dupe(u8, trimmed), .createdAt = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)) };
        try t.items.append(t.gpa, todo);
        try t.save();
        return todo;
    }

    /// Marks a todo done or not done.
    pub fn toggle(t: *Todos, id: i64) !void {
        const i = t.index(id) orelse return error.TodoNotFound;
        t.items.items[i].done = !t.items.items[i].done;
        try t.save();
    }

    pub fn remove(t: *Todos, id: i64) !void {
        const i = t.index(id) orelse return error.TodoNotFound;
        _ = t.items.orderedRemove(i);
        try t.save();
    }

    /// Removes completed todos; returns how many went.
    pub fn clearDone(t: *Todos) !usize {
        const before = t.items.items.len;
        var kept: usize = 0;
        for (t.items.items) |it| if (!it.done) {
            t.items.items[kept] = it;
            kept += 1;
        };
        t.items.shrinkRetainingCapacity(kept);
        try t.save();
        return before - kept;
    }

    pub fn stats(t: *Todos) Stats {
        var s: Stats = .{ .total = t.items.items.len, .active = 0 };
        for (t.items.items) |it| s.active += @intFromBool(!it.done);
        return s;
    }

    /// Asks where to save the list and writes it as JSON; returns the path
    /// chosen, or "" when the dialog was canceled.
    pub fn @"export"(t: *Todos, call: *myzig.Call) ![]const u8 {
        const path = try myzig.dialog.save(call.arena, .{ .title = "Export Todos", .name = "todos.json", .extensions = &.{"json"} }) orelse return "";
        try t.writeTo(path);
        return path;
    }

    fn index(t: *Todos, id: i64) ?usize {
        for (t.items.items, 0..) |it, i| if (it.id == id) return i;
        return null;
    }

    fn writeTo(t: *Todos, path: []const u8) !void {
        const data = try std.json.Stringify.valueAlloc(t.gpa, t.items.items, .{ .whitespace = .indent_2 });
        defer t.gpa.free(data);
        try std.Io.Dir.cwd().writeFile(t.app.io, .{ .sub_path = path, .data = data });
    }

    /// Writes the list and tells every window about the change.
    fn save(t: *Todos) !void {
        try t.writeTo(t.path);
        Changed.broadcast(t.app, t.stats());
    }
};

// What the app does with the list besides the frontend: functions of the
// file, not methods, so the frontend doesn't get them.

pub fn close(t: *Todos) void {
    t.deinit();
}

/// Writes the list as JSON to `path`.
pub fn exportTo(t: *Todos, path: []const u8) !void {
    try t.writeTo(path);
}
