//! A chart-like surface that handles pan and pinch before its scroll parent.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const State = struct {
    scale: f32 = 1,
    pan: f32 = 0,

    fn input(s: *State, e: ui.InputEvent) bool {
        switch (e.kind) {
            .zoom => s.scale = std.math.clamp(s.scale * e.scale, 0.1, 100),
            .scroll => s.pan += e.dx + e.dy,
        }
        return true;
    }

    fn view(s: *State, c: *ui.Context) void {
        const plot = ui.div(c).size(400, 240).p(20).bg(c.theme.surface).handleInput(s, input);
        defer plot.end();
        ui.text(c, "Pinch demo", .{ .weight = .bold });
        ui.textf(c, .{}, "Scale {d:.2}", .{s.scale});
        ui.textf(c, .{}, "Pan {d:.0}", .{s.pan});
        if (ui.button(c, "Zoom in", .{}).clicked) s.scale *= 2;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Gestures" });
    defer app.destroy();
    var state: State = .{};
    _ = try app.newWindow(.{ .title = "Gestures", .width = 480, .height = 320, .content = .{ .view = .init(&state, State.view) } });
    try app.run();
}
