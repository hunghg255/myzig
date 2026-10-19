//! What a timeline (`ui.motion.timeline`) is for: several tweens on one
//! playhead, arranged and controlled together.
//!
//! The card slides in from the left as it grows to its size, its title
//! follows it, the rows come one after another, and the card bounces a
//! little as it lands. One playhead drives all of it, so Play, Pause,
//! Reverse, Restart and the scrubber move the whole intro together. The
//! timeline reads the frame's clock and asks for frames only while it
//! moves, as the rest of myzig's motion does.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const motion = ui.motion;

/// Bounces as it lands, as a ball does (easeOutBounce).
fn bounceOut(t: f32) f32 {
    const n: f32 = 7.5625;
    const d: f32 = 2.75;
    if (t < 1 / d) return n * t * t;
    if (t < 2 / d) {
        const u = t - 1.5 / d;
        return n * u * u + 0.75;
    }
    if (t < 2.5 / d) {
        const u = t - 2.25 / d;
        return n * u * u + 0.9375;
    }
    const u = t - 2.625 / d;
    return n * u * u + 0.984375;
}

const App = struct {
    /// Plays the intro again when it changes.
    run: u64 = 0,
    paused: bool = false,
    reverse: bool = false,
    /// The scrubber, and whether the pointer holds it: then the playhead
    /// stays where it puts it, and goes on from there when let go.
    scrub: f32 = 0,
    held: bool = false,

    fn view(s: *App, c: *ui.Context) void {
        const th = c.theme;
        var o: motion.TimelineOptions = .{ .run = s.run, .paused = s.paused, .reverse = s.reverse };
        if (s.held) o.progress = s.scrub;
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 18, .padding = .all(24) });
        defer ui.end(c);

        // One playhead for the whole intro, kept by the card.
        var tl = motion.timeline(c, c.peekId("card"), "intro", o);
        const slide = tl.tween(.{ .from = -420, .to = 0, .duration = 0.45 }, .{});
        const grow = tl.tween(.{ .from = 0.9, .to = 1, .duration = 0.45 }, .with(0));
        const fade = tl.tween(.{ .from = 0, .to = 1, .duration = 0.3, .ease = .linear }, .at(0.15));
        tl.label("rows", .at(0.45)); // where the card lands
        const names = [3][]const u8{ "Plan", "Build", "Ship" };
        var rows: [3]f32 = undefined;
        for (&rows, 0..) |*r, i| r.* = tl.tween(.{ .from = 0, .to = 1, .duration = 0.24, .ease = .linear }, .atLabel("rows", @as(f32, @floatFromInt(i)) * 0.09));
        const bounce = tl.tween(.{ .from = 10, .to = 0, .duration = 0.36, .ease = .{ .custom = bounceOut } }, .at(0.45));

        _ = c.open(.{
            .width = .{ .px = 300 },
            .padding = .all(22),
            .gap = 10,
            .radius = 16,
            .background = th.surface,
            .shadow = .{},
            .transform = ui.Affine.scaling(grow, grow).then(.translation(slide, bounce)),
        }, "card");
        {
            defer c.end();
            _ = c.open(.{ .opacity = fade, .transform = .translation(0, (1 - fade) * 12) }, null);
            ui.text(c, "A timeline", .{ .size = 20, .weight = .bold });
            c.end();
            for (names, rows) |name, r| {
                ui.row(c, .{ .gap = 8, .opacity = r, .transform = .translation(0, (1 - r) * 14) });
                ui.text(c, name, .{ .color = th.muted });
                ui.end(c);
            }
        }
        {
            ui.row(c, .{ .gap = 8 });
            defer ui.end(c);
            if (ui.button(c, "Restart", .{ .variant = .primary }).clicked) s.run += 1;
            if (ui.button(c, "Pause", .{ .disabled = s.paused }).clicked) s.paused = true;
            if (ui.button(c, "Play", .{ .disabled = !s.paused }).clicked) s.paused = false;
            if (ui.button(c, "Reverse", .{}).clicked) s.reverse = !s.reverse;
        }
        ui.row(c, .{ .gap = 10, .align_items = .center, .width = .{ .px = 360 } });
        defer ui.end(c);
        // Held while it moves it, and until the button goes up.
        const moved = ui.slider(c, &s.scrub, .{ .width = .fill, .label = "Playhead" });
        s.held = moved or (s.held and c.input.down);
        if (!s.held) s.scrub = tl.progress();
        ui.text(c, c.print("{d:.0} / {d:.0} ms", .{ tl.time() * 1000, tl.duration() * 1000 }), .{ .size = 12, .color = th.muted });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Timeline" });
    defer app.destroy();
    var s: App = .{};
    _ = try app.newWindow(.{
        .title = "Timeline",
        .width = 520,
        .height = 480,
        .content = .{ .view = .init(&s, App.view) },
    });
    try app.run();
}
