//! A terminal app: a window running the user's shell (PowerShell on
//! Windows), titled by the shell, closed when it exits. Under `zig build
//! run` it downloads libghostty-vt (and on Windows ConPTY) into the user's
//! cache once, as mygo's terminal does under `go run`.
//!
//!     zig build snapshot   # its first second, rendered offscreen to a PNG
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const terminal = @import("terminal");

const State = struct {
    term: *terminal.Terminal = undefined,
    win: ?*myzig.Window = null,
    gpa: std.mem.Allocator,

    fn view(s: *State, c: *ui.Context) void {
        terminal.view(c, s.term, .{ .autofocus = true });
    }

    fn onEvent(ctx: ?*anyopaque, t: *terminal.Terminal, ev: terminal.Event) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        const win = s.win orelse return;
        switch (ev) {
            .output => win.redraw(),
            .title => {
                const title = t.title(s.gpa) catch return;
                defer s.gpa.free(title);
                win.setTitle(if (title.len > 0) title else "Terminal");
            },
            .bell => {},
            .exit => win.close(),
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Terminal" });
    defer app.destroy();
    terminal.download.fetchAll(app.gpa, app.io) catch |err| std.log.warn("terminal: downloading its libraries: {s}", .{@errorName(err)});
    var state: State = .{ .gpa = app.gpa };
    state.term = try terminal.Terminal.create(app.gpa, app.io, .{
        .theme = terminal.Theme.light,
        .dark_theme = terminal.ghosttyTheme("Catppuccin Mocha"),
        .on_event = .{ .ctx = &state, .func = State.onEvent },
    });
    defer state.term.destroy();
    state.win = try app.newWindow(.{
        .title = "Terminal",
        .width = 760,
        .height = 460,
        .content = .{ .view = .init(&state, State.view) },
    });
    try app.run();
}
