//! Color pickers and wells through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const color = @import("controls_color.zig");
const testing = std.testing;
const Color = ui.Color;

fn hexEq(want: []const u8, got: Color) !void {
    var buf: [16]u8 = undefined;
    const b = struct {
        fn f(v: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }.f;
    const s = if (b(got.a) == 255)
        try std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ b(got.r), b(got.g), b(got.b) })
    else
        try std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ b(got.r), b(got.g), b(got.b), b(got.a) });
    try testing.expectEqualStrings(want, s);
}

test "hex and HSV round trips" {
    try hexEq("#ff0000", color.parseHex("#f00").?);
    try hexEq("#3b82f6", color.parseHex("3b82f6").?);
    try hexEq("#11223344", color.parseHex("#11223344").?);
    try testing.expect(color.parseHex("#12345") == null);
    try testing.expect(color.parseHex("#gg0000") == null);
    try testing.expect(color.parseHex("") == null);
    for ([_]u24{ 0xff0000, 0x00ff00, 0x0000ff, 0x3b82f6, 0x92400e, 0x777777, 0x000000, 0xffffff }) |v| {
        const c = color.quantize(Color.hex(v));
        try testing.expectEqual(c, color.Hsva.of(c).color());
    }
    const h = color.Hsva.of(Color.hex(0x00ff00));
    try testing.expectApproxEqAbs(@as(f32, 120), h.h, 0.01);
    try testing.expectEqual(@as(f32, 1), h.s);
}

const Paint = struct {
    tint: Color = Color.hex(0xff0000),
    picker: color.ColorPicker = .{},
    changes: u32 = 0,
    fn view(s: *Paint, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (color.colorPicker(c, &s.tint, &s.picker)) s.changes += 1;
        ui.text(c, "Elsewhere", .{});
    }
};

// The square spans x 20..248 and y 20..170; the hue slider y 180..196,
// the opacity slider 206..222 (knobs 14 wide).
test "the square sets saturation across and brightness up" {
    var s: Paint = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Paint.view), .{ .height = 420 });
    defer t.deinit();
    try testing.expect(t.hasText("#ff0000"));
    // The bottom left is black, the top left white, the top right the hue.
    t.click(20, 169.9);
    try hexEq("#000000", s.tint);
    t.click(20, 20);
    try hexEq("#ffffff", s.tint);
    t.click(247.9, 20);
    try hexEq("#ff0000", s.tint);
    // Half across and half up.
    t.click(134, 95);
    try hexEq("#804040", s.tint);
    try testing.expect(t.hasText("#804040"));
    // A drag ends where it is released, past the edge clamped.
    t.drag(134, 95, 400, 0);
    try hexEq("#ff0000", s.tint);
    try testing.expect(s.changes >= 4);
}

test "a gray keeps its hue, and the keys move across the square" {
    var s: Paint = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Paint.view), .{ .height = 420 });
    defer t.deinit();
    // Set the hue to blue's (240 of 360) on the slider.
    t.click(20 + 7 + 214.0 * 240.0 / 360.0, 188);
    try hexEq("#0000ff", s.tint);
    t.click(20, 20);
    try hexEq("#ffffff", s.tint);
    // Back right: blue again, not red.
    t.click(247.9, 20);
    try hexEq("#0000ff", s.tint);
    t.key(.down);
    t.key(.left);
    // 99% bright, 99% saturated: blue a little dimmer and paler.
    try hexEq("#0303fc", s.tint);
}

test "the opacity slider, typing hex, and swatches" {
    var s: Paint = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Paint.view), .{ .height = 420 });
    defer t.deinit();
    t.click(20 + 7 + 107, 214);
    try hexEq("#ff000080", s.tint);
    t.key(.end);
    try hexEq("#ff0000", s.tint);
    // Typed hex applies as soon as it is a color, kept as typed.
    try t.clickText("#ff0000");
    t.textOps(&.{.{ .command = .select_all }});
    t.typeText("#3b82f");
    try hexEq("#ff0000", s.tint);
    t.typeText("6");
    try hexEq("#3b82f6", s.tint);
    t.typeText("8");
    try hexEq("#3b82f6", s.tint);
    try testing.expectEqualStrings("#3b82f68", s.picker.hex.text());
    try t.clickText("Elsewhere");
    try testing.expectEqualStrings("#3b82f6", s.picker.hex.text());
    // The first swatch is red; the last black.
    var first: ?ui.Rect = null;
    var last: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| if (n.style.background) |b| {
        if (n.style.height == .px and n.style.height.px == 22) {
            if (first == null and std.meta.eql(b, Color.hex(0xef4444))) first = n.rect;
            if (std.meta.eql(b, Color.hex(0x000000))) last = n.rect;
        }
    };
    t.click(first.?.x + 5, first.?.y + 5);
    try hexEq("#ef4444", s.tint);
    t.click(last.?.x + 5, last.?.y + 5);
    try hexEq("#000000", s.tint);
    // The app sets the color: the picker follows.
    s.tint = Color.hex(0x22c55e);
    t.frame();
    try testing.expect(t.hasText("#22c55e"));
}

const Well = struct {
    tint: Color = Color.hex(0x3b82f6),
    picker: color.ColorPicker = .{},
    fn view(s: *Well, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        _ = color.colorWell(c, &s.tint, &s.picker);
        ui.text(c, "Elsewhere", .{});
    }
};

test "a color well opens its picker below it, and closes" {
    var s: Well = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Well.view), .{ .height = 480 });
    defer t.deinit();
    try testing.expect(!t.hasText("#3b82f6"));
    t.click(30, 30);
    try testing.expect(s.picker.open);
    try testing.expect(t.hasText("#3b82f6"));
    // A click inside works and keeps it open.
    const hex = t.findText("#3b82f6").?;
    const sq_x = hex.x - 30;
    t.click(sq_x + 1, hex.y - 100);
    try testing.expect(s.picker.open);
    try testing.expect(!std.meta.eql(s.tint, Color.hex(0x3b82f6)));
    // Escape closes it; Enter opens it again; a click outside closes it.
    t.key(.escape);
    try testing.expect(!s.picker.open);
    t.key(.enter);
    try testing.expect(s.picker.open);
    t.click(460, 470);
    try testing.expect(!s.picker.open);
    // The well toggles it.
    t.click(30, 30);
    t.click(30, 30);
    try testing.expect(!s.picker.open);
}
