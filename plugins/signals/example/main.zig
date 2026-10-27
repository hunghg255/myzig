//! Native UI on global state: signals hold it, computeds derive from it,
//! effects do what follows from it. The view reads the store like any
//! state (it runs on every event); "Auto" changes it from a timer, outside
//! any event, and an effect draws the window again only then, and keeps
//! its title in step.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const signals = @import("signals");

const store = struct {
    var count = signals.Signal(i64).init(0);
    var step = signals.Signal(i64).init(1);
    var auto = signals.Signal(bool).init(false);

    var doubled = signals.Computed(i64).init(struct {
        fn get(_: ?i64) i64 {
            return count.get() * 2;
        }
    }.get);
    var parity = signals.Computed([]const u8).init(struct {
        fn get(_: ?[]const u8) []const u8 {
            return if (@rem(count.get(), 2) == 0) "even" else "odd";
        }
    }.get);

    fn add() void {
        count.set(count.peek() + step.peek());
    }
};

fn view(_: *void, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 12 });
    defer ui.end(c);
    ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{store.count.get()});
    ui.textf(c, .{ .size = 15 }, "doubled {d}, {s}", .{ store.doubled.get(), store.parity.get() });
    ui.row(c, .{ .gap = 8 });
    defer ui.end(c);
    if (ui.button(c, "Add", .{ .variant = .primary, .size = 16 }).clicked) store.add();
    const step = store.step.get();
    if (ui.button(c, if (step == 1) "Step 1" else "Step 10", .{ .size = 16 }).clicked) store.step.set(if (step == 1) 10 else 1);
    const auto = store.auto.get();
    if (ui.button(c, if (auto) "Stop" else "Auto", .{ .variant = .ghost, .size = 16 }).clicked) {
        store.auto.set(!auto);
        if (!auto) tick(null);
    }
    if (ui.button(c, "Reset", .{ .variant = .ghost, .size = 16, .disabled = store.count.get() == 0 }).clicked) {
        // One run of the effects for both writes.
        signals.startBatch();
        defer signals.endBatch();
        store.count.set(0);
        store.step.set(1);
    }
}

/// Adds a step every half second while "Auto" is on.
fn tick(_: ?*anyopaque) callconv(.c) void {
    if (!store.auto.peek()) return;
    store.add();
    myzig.App.after(500, null, tick);
}

/// Draws the window again when what it shows changes, and titles it.
fn follow(win: *myzig.Window) void {
    var buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Signals: {d} ({s})", .{ store.count.get(), store.parity.get() }) catch "Signals";
    _ = store.step.get();
    _ = store.auto.get();
    win.setTitle(title);
    win.redraw();
}

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Signals" });
    defer app.destroy();
    var nothing: void = {};
    const win = try app.newWindow(.{
        .title = "Signals",
        .width = 480,
        .height = 300,
        .content = .{ .view = .init(&nothing, view) },
    });
    const effect = signals.effectWith(win, follow);
    defer effect.dispose();
    try app.run();
}
