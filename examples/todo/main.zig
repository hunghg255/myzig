//! A small but complete myzig app: typed services and events shared with
//! a web frontend, persistence, dialogs, menus and several windows kept in
//! sync. The frontend's client is generated from the Zig services:
//!
//!     zig-out/bin/todo --myzig-generate=examples/todo/frontend
const std = @import("std");
const myzig = @import("myzig");
const store = @import("store.zig");

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
    .{ .path = "/main.js", .data = @embedFile("frontend/main.js") },
    .{ .path = "/style.css", .data = @embedFile("frontend/style.css") },
};

var app: *myzig.App = undefined;
var todos: store.Todos = undefined;

fn openWindow() void {
    _ = app.newWindow(.{
        .title = "Todo",
        .width = 460,
        .height = 640,
        .min_width = 360,
        .min_height = 420,
        .title_bar = .hidden,
        .content = .{ .page = .{ .url = "/", .assets = &assets } },
    }) catch |err| std.log.err("window: {t}", .{err});
}

const Menu = struct {
    fn newWindow(_: *Menu, _: *myzig.menu.Item) void {
        openWindow();
    }
    fn exportList(_: *Menu, _: *myzig.menu.Item) void {
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const path = myzig.dialog.save(arena.allocator(), .{ .title = "Export Todos", .name = "todos.json", .extensions = &.{"json"} }) catch return orelse return;
        store.exportTo(&todos, path) catch |err| std.log.err("export: {t}", .{err});
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // The name first: it names the data directory.
    app = try myzig.App.create(init, .{ .name = "Todo" });
    defer app.destroy();

    // Headless runs (--myzig-eval) keep their list in a temporary directory.
    const dir = try myzig.path(gpa, if (app.flags.hidden) .temp else .data, "Todo");
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    const path = try std.fs.path.join(gpa, &.{ dir, if (app.flags.hidden) "myzig-todo-test.json" else "todos.json" });
    defer gpa.free(path);
    if (app.flags.hidden) std.Io.Dir.cwd().deleteFile(init.io, path) catch {};
    todos = try store.Todos.open(app, path);
    defer store.close(&todos);
    try app.bind(&todos);
    try app.registerEvent(store.Changed);

    var menu: Menu = .{};
    try app.setMenu(&.{
        .{ .role = .app_menu },
        .{ .label = "File", .submenu = &.{
            .{ .label = "New Window", .accelerator = "CmdOrCtrl+N", .click = .of(&menu, Menu.newWindow) },
            .{ .label = "Export…", .accelerator = "CmdOrCtrl+E", .click = .of(&menu, Menu.exportList) },
            .separator,
            .{ .role = .close },
        } },
        .{ .role = .edit_menu },
        .{ .role = .view_menu },
        .{ .role = .window_menu },
    });
    openWindow();
    try app.run();
}
