//! The gallery's look and motion: transforms, gradients, blur and frosted
//! glass; springs and curves, keyframes, a timeline, and boxes that move
//! as the layout changes, come and go.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const motion = ui.motion;
const card = @import("basics.zig").card;

const frost: ui.Effect = .{ .blur = 10 };

const sunset: ui.Gradient = .{ .stops = &.{ .{ .color = .hex(0xff5e62), .at = 0 }, .{ .color = .hex(0xff9966), .at = 1 } }, .angle = 135 };
const ocean: ui.Gradient = .{ .kind = .radial, .stops = &.{ .{ .color = .hex(0x5ac8fa), .at = 0 }, .{ .color = .hex(0x0040dd), .at = 1 } } };
const wheel: ui.Gradient = .{ .kind = .conic, .stops = &.{
    .{ .color = .hex(0xff3b30), .at = 0 },   .{ .color = .hex(0xffcc00), .at = 0.17 },
    .{ .color = .hex(0x34c759), .at = 0.33 }, .{ .color = .hex(0x5ac8fa), .at = 0.5 },
    .{ .color = .hex(0x0a84ff), .at = 0.67 }, .{ .color = .hex(0xaf52de), .at = 0.83 },
    .{ .color = .hex(0xff3b30), .at = 1 },
} };
const oklab: ui.Gradient = .{ .stops = &.{ .{ .color = .hex(0x0000ff), .at = 0 }, .{ .color = .hex(0xffff00), .at = 1 } }, .angle = 90, .oklab = true };
const srgb: ui.Gradient = .{ .stops = &.{ .{ .color = .hex(0x0000ff), .at = 0 }, .{ .color = .hex(0xffff00), .at = 1 } }, .angle = 90 };

const easings = [_]struct { []const u8, motion.Animation }{
    .{ "Linear", .curve(0.6, .linear) },
    .{ "Ease in", .curve(0.6, .ease_in) },
    .{ "Ease out", .curve(0.6, .ease_out) },
    .{ "Ease in out", .curve(0.6, .ease_in_out) },
    .{ "Smooth spring", .smooth },
    .{ "Bouncy spring", .bouncy },
};

pub const MotionPage = struct {
    rotate: f32 = 12,
    scale: f32 = 1,
    skew: f32 = 0,
    blur: f32 = 0,
    right: bool = false,
    shakes: u64 = 0,
    intro: u64 = 0,
    items: [8]u32 = .{ 1, 2, 3, 0, 0, 0, 0, 0 },
    count: usize = 3,
    next: u32 = 4,
    wide: bool = false,

    pub fn look(s: *MotionPage, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Styling");
        {
            card(c, "Transforms");
            defer ui.end(c);
            ui.row(c, .{ .gap = 40, .align_items = .center, .padding = .xy(30, 20) });
            _ = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 80 }, .radius = 12, .gradient = &sunset, .transform = ui.Affine.rotation(s.rotate).then(.scaling(s.scale, s.scale)).then(.skewing(s.skew, 0)) }, .none, null);
            ui.column(c, .{ .gap = 8 });
            inline for (.{ .{ "Rotate", "rotate", -180, 180 }, .{ "Scale", "scale", 0.5, 1.5 }, .{ "Skew", "skew", -30, 30 } }) |sl| {
                ui.row(c, .{ .gap = 8, .align_items = .center });
                _ = c.leaf(.{ .width = .{ .px = 50 } }, .{ .text = .{ .str = sl[0], .style = .{ .size = 12 }, .color = th.muted } }, null);
                _ = ui.slider(c, &@field(s, sl[1]), .{ .min = sl[2], .max = sl[3], .width = .{ .px = 200 }, .label = sl[0] });
                ui.end(c);
            }
            ui.end(c);
            ui.end(c);
        }
        {
            card(c, "Gradients");
            defer ui.end(c);
            ui.row(c, .{ .gap = 12 });
            defer ui.end(c);
            for ([_]struct { []const u8, *const ui.Gradient }{ .{ "Linear", &sunset }, .{ "Radial", &ocean }, .{ "Conic", &wheel }, .{ "sRGB", &srgb }, .{ "Oklab", &oklab } }) |g| {
                ui.column(c, .{ .gap = 6, .align_items = .center });
                _ = c.leaf(.{ .width = .{ .px = 90 }, .height = .{ .px = 90 }, .radius = if (g[1] == &wheel) 45 else 12, .gradient = g[1] }, .none, null);
                ui.text(c, g[0], .{ .size = 12, .color = th.muted });
                ui.end(c);
            }
        }
        {
            card(c, "Blur and frosted glass");
            defer ui.end(c);
            ui.row(c, .{ .gap = 12, .align_items = .center });
            ui.text(c, "Blur", .{ .color = th.muted });
            _ = ui.slider(c, &s.blur, .{ .min = 0, .max = 8, .width = .{ .px = 200 } });
            ui.end(c);
            ui.row(c, .{ .gap = 16 });
            defer ui.end(c);
            _ = c.open(.{ .width = .{ .px = 160 }, .height = .{ .px = 110 }, .radius = 12, .gradient = &wheel, .blur = s.blur, .align_items = .center, .justify = .center }, null);
            ui.text(c, "Blurred", .{ .weight = .bold, .color = .white });
            c.end();
            // Glass over stripes: the box draws from what is under it.
            _ = c.open(.{ .width = .{ .px = 260 }, .height = .{ .px = 110 }, .radius = 12, .clip = true }, null);
            for (0..8) |i| _ = c.leaf(.{ .absolute = true, .offset = .{ .x = @as(f32, @floatFromInt(i)) * 34, .y = -10 }, .width = .{ .px = 16 }, .height = .{ .px = 140 }, .background = if (i % 2 == 0) ui.Color.hex(0xff9500) else ui.Color.hex(0x0a84ff), .transform = .rotation(20) }, .none, null);
            _ = c.open(.{ .absolute = true, .offset = .{ .x = 40, .y = 25 }, .width = .{ .px = 180 }, .height = .{ .px = 60 }, .radius = 14, .effect = &frost, .background = ui.Color.white.alpha(0.25), .border = ui.Color.white.alpha(0.5), .align_items = .center, .justify = .center }, null);
            ui.text(c, "Frosted glass", .{ .weight = .semibold, .color = .white });
            c.end();
            c.end();
        }
    }

    pub fn moving(s: *MotionPage, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Motion");
        {
            card(c, "Springs and curves");
            defer ui.end(c);
            if (ui.button(c, if (s.right) "Back" else "Go", .{ .variant = .primary }).clicked) s.right = !s.right;
            for (easings) |e| {
                ui.row(c, .{ .gap = 12, .align_items = .center, .width = .fill });
                defer ui.end(c);
                _ = c.leaf(.{ .width = .{ .px = 100 } }, .{ .text = .{ .str = e[0], .style = .{ .size = 12 }, .color = th.muted } }, null);
                const track = c.open(.{ .width = .{ .px = 320 }, .height = .{ .px = 24 }, .radius = 12, .background = th.track }, e[0]);
                const x = motion.animateTo(c, c.node(track).id, "x", if (s.right) 296 else 0, e[1]);
                _ = c.leaf(.{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .radius = 12, .background = th.accent, .transform = .translation(x, 0) }, .none, null);
                c.end();
            }
        }
        {
            card(c, "Keyframes and a timeline");
            defer ui.end(c);
            ui.row(c, .{ .gap = 12, .align_items = .center });
            if (ui.button(c, "Shake", .{}).clicked) s.shakes += 1;
            if (ui.button(c, "Play the intro", .{}).clicked) s.intro += 1;
            ui.end(c);
            ui.row(c, .{ .gap = 24, .align_items = .center, .padding = .xy(10, 10) });
            defer ui.end(c);
            const id = c.peekId("shake");
            const dx = motion.keyframes(c, id, "dx", &.{
                .{ .value = 0 },
                .{ .at = 0.08, .value = -12 },
                .{ .at = 0.16, .value = 12 },
                .{ .at = 0.24, .value = -8 },
                .{ .at = 0.32, .value = 8 },
                .{ .at = 0.4, .value = 0, .ease = .ease_out },
            }, .{ .run = s.shakes });
            _ = c.open(.{ .padding = .xy(14, 10), .radius = 8, .background = th.danger.alpha(0.15), .transform = .translation(dx, 0) }, "shake");
            ui.text(c, "Wrong password", .{ .color = th.danger });
            c.end();
            var tl = motion.timeline(c, c.peekId("intro"), "intro", .{ .run = s.intro });
            const slide = tl.tween(.{ .from = -60, .to = 0, .duration = 0.4 }, .{});
            const fade = tl.tween(.{ .from = 0, .to = 1, .duration = 0.3, .ease = .linear }, .with(0.1));
            const grow = tl.tween(.{ .from = 0.8, .to = 1, .duration = 0.3 }, .after(-0.1));
            _ = c.open(.{ .padding = .xy(14, 10), .radius = 8, .background = th.accent, .opacity = fade, .transform = ui.Affine.scaling(grow, grow).then(.translation(slide, 0)) }, "intro");
            ui.text(c, c.print("Intro · {d:.0} ms", .{tl.time() * 1000}), .{ .color = th.accent_text });
            c.end();
        }
        {
            card(c, "Transitions");
            defer ui.end(c);
            ui.row(c, .{ .gap = 8 });
            if (ui.button(c, "Add", .{ .disabled = s.count == s.items.len }).clicked) {
                s.items[s.count] = s.next;
                s.next += 1;
                s.count += 1;
            }
            if (ui.button(c, "Remove the first", .{ .disabled = s.count == 0 }).clicked) {
                std.mem.copyForwards(u32, s.items[0 .. s.count - 1], s.items[1..s.count]);
                s.count -= 1;
            }
            if (ui.button(c, "Shuffle", .{}).clicked) std.mem.reverse(u32, s.items[0..s.count]);
            _ = ui.toggle(c, "Wide", &s.wide);
            ui.end(c);
            ui.row(c, .{ .gap = 8, .width = .fill });
            defer ui.end(c);
            for (s.items[0..s.count]) |n| {
                const box = c.open(.{ .width = .{ .px = if (s.wide) 110 else 70 }, .height = .{ .px = 50 }, .radius = 10, .background = th.surface_hover, .align_items = .center, .justify = .center }, c.print("item-{d}", .{n}));
                ui.text(c, c.print("{d}", .{n}), .{ .weight = .bold });
                motion.transition(c, box, .{ .animation = .snappy, .enter = .{ .opacity = 0, .scale = 0.6, .y = 12 }, .exit = .{ .opacity = 0, .scale = 0.6, .collapse = true } });
                c.end();
            }
        }
    }
};
