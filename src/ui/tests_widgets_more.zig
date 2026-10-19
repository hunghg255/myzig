//! Small widget behaviors through `Tester`: a slider reporting that it is
//! held, the theme's warning color, the bounce and elastic easings.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Volume = struct {
    value: f32 = 0.5,
    held: bool = false,
    fn view(s: *Volume, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20) });
        defer ui.end(c);
        _ = ui.slider(c, &s.value, .{ .width = .{ .px = 200 }, .held = &s.held });
    }
};

test "a slider says it is held while the pointer drags it, and not once let go" {
    var s: Volume = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Volume.view), .{});
    defer t.deinit();
    try testing.expect(!s.held);
    // The slider spans x 20..220 and y 20..42.
    t.moveTo(120, 31);
    t.ctx.pointerDown();
    t.frame();
    try testing.expect(s.held);
    t.ctx.input.mouse = .{ .x = 180, .y = 31 };
    t.frame();
    try testing.expect(s.held);
    try testing.expect(s.value > 0.7);
    t.ctx.pointerUp();
    t.frame();
    try testing.expect(!s.held);
}

test "themes have a warning color, amber, of their own in the dark" {
    const light = ui.Theme.light.warning;
    const dark = ui.Theme.dark_theme.warning;
    try testing.expect(light.r > light.b and dark.r > dark.b);
    try testing.expect(!std.meta.eql(light, dark));
    // A theme mixed between them mixes it too.
    const half = @import("themes.zig").mix(ui.Theme.light, ui.Theme.dark_theme, 0.5).warning;
    try testing.expect(half.g > @min(light.g, dark.g) and half.g < @max(light.g, dark.g));
}

test "a value animated with the bounce easing lands on its target" {
    const curve = @import("motion_curve.zig");
    var ch = curve.Channel.init(0, 0);
    ch.retarget(10, curve.Animation.curve(0.5, .bounce));
    ch.advance(0.5 / 2.75);
    try testing.expectApproxEqAbs(@as(f64, 10), ch.value, 1e-2);
    ch.advance(1);
    try testing.expectApproxEqAbs(@as(f64, 10), ch.value, 1e-6);
}

const Typing = struct {
    events: u32 = 0,
    text: [32]u8 = undefined,
    len: usize = 0,
    on: bool = false,
    shown: f32 = 0,
    fn view(s: *Typing, c: *ui.Context) void {
        if (c.input.chars.len > 0) {
            s.events += 1;
            @memcpy(s.text[s.len..][0..c.input.chars.len], c.input.chars);
            s.len += c.input.chars.len;
        }
        s.shown = c.animate(7, 0, if (s.on) 1 else 0, 4);
        ui.column(c, .{ .padding = .all(20) });
        defer ui.end(c);
        ui.text(c, "Hello", .{});
    }
};

test "scripts type a character an event, and capture frames mid-animation" {
    var s: Typing = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Typing.view), .{});
    defer t.deinit();
    try t.runScript("type:# é*");
    try testing.expectEqual(@as(u32, 4), s.events);
    try testing.expectEqualStrings("# é*", s.text[0..s.len]);
    s.on = true;
    try t.runScript("frames:3");
    try testing.expect(s.shown > 0.05 and s.shown < 0.9);
    try t.runScript("wait:0");
    try testing.expectEqual(@as(f32, 1), s.shown);
}

test "a script drags between points and texts" {
    var s: Volume = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Volume.view), .{});
    defer t.deinit();
    try t.runScript("drag:120,31>200,31");
    try testing.expect(s.value > 0.85);
    try testing.expect(!s.held);
    try testing.expectError(error.TextNotFound, t.runScript("drag:Nowhere>10,10"));
}

const Game = struct {
    up: bool = false,
    typed: u21 = 0,
    fn view(s: *Game, c: *ui.Context) void {
        c.wants_keys = true;
        if (c.input.key_down_code) |k| if (k == .w) {
            s.up = true;
        };
        if (c.input.key_up_code) |k| if (k == .w) {
            s.up = false;
        };
        if (c.input.key_down) |ch| s.typed = ch;
        ui.text(c, "Game", .{});
    }
};

test "a view following keys gets where the key is with what it types" {
    var s: Game = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Game.view), .{});
    defer t.deinit();
    // AZERTY: the key where W is types z.
    t.keyEdgeAt('z', .w, true);
    try testing.expect(s.up);
    try testing.expectEqual(@as(u21, 'z'), s.typed);
    t.frame();
    try testing.expect(s.up);
    t.keyEdgeAt('z', .w, false);
    try testing.expect(!s.up);
    // Edges without a position leave it null, as before.
    t.keyEdge('a', true);
    try testing.expectEqual(@as(u21, 'a'), s.typed);
}
