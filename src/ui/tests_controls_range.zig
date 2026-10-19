//! Range sliders, steppers, number inputs, meters and spinners through
//! `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const range = @import("controls_range.zig");
const testing = std.testing;

const Prices = struct {
    low: f64 = 200,
    high: f64 = 800,
    step: f64 = 0,
    changes: u32 = 0,
    fn view(s: *Prices, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (range.rangeSlider(c, &s.low, &s.high, .{ .min = 0, .max = 1000, .step = s.step, .width = 218 })) s.changes += 1;
        ui.text(c, "Below", .{});
    }
};

// The slider spans x 20..238; its knobs are 18 wide, so a value v sits at
// x = 29 + v / 1000 * 200, at y 31.
fn xOf(v: f64) f32 {
    return 29 + @as(f32, @floatCast(v)) / 1000 * 200;
}

test "each knob drags, and the knobs do not cross" {
    var s: Prices = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Prices.view), .{});
    defer t.deinit();
    t.drag(xOf(200), 31, xOf(100), 31);
    try testing.expectApproxEqAbs(@as(f64, 100), s.low, 0.01);
    try testing.expectEqual(@as(f64, 800), s.high);
    t.drag(xOf(800), 31, xOf(900), 31);
    try testing.expectApproxEqAbs(@as(f64, 900), s.high, 0.01);
    // Dragged past the high knob, the low one stops at it.
    t.drag(xOf(100), 31, xOf(1000), 31);
    try testing.expectApproxEqAbs(@as(f64, 900), s.low, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 900), s.high, 0.01);
    try testing.expect(s.changes > 0);
}

test "a press on the track moves the nearest knob, which goes on dragging" {
    var s: Prices = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Prices.view), .{});
    defer t.deinit();
    t.click(xOf(700), 31);
    try testing.expectApproxEqAbs(@as(f64, 700), s.high, 0.01);
    try testing.expectEqual(@as(f64, 200), s.low);
    t.drag(xOf(350), 31, xOf(0), 31);
    try testing.expectApproxEqAbs(@as(f64, 0), s.low, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 700), s.high, 0.01);
}

test "a step snaps, and the keys move the knob with the focus" {
    var s: Prices = .{ .step = 50 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Prices.view), .{});
    defer t.deinit();
    t.click(xOf(212), 31);
    try testing.expectEqual(@as(f64, 200), s.low);
    t.key(.right);
    try testing.expectEqual(@as(f64, 250), s.low);
    t.key(.left);
    t.key(.down);
    try testing.expectEqual(@as(f64, 150), s.low);
    t.key(.home);
    try testing.expectEqual(@as(f64, 0), s.low);
    // End stops at the other knob.
    t.key(.end);
    try testing.expectEqual(@as(f64, 800), s.low);
    t.key(.right);
    try testing.expectEqual(@as(f64, 800), s.low);
    // The high knob's keys.
    t.click(xOf(800) + 6, 31);
    t.key(.end);
    try testing.expectEqual(@as(f64, 1000), s.high);
    t.key(.home);
    try testing.expectEqual(@as(f64, 800), s.high);
    // Values the app set out of order are put back in order.
    s.low = 900;
    s.high = 100;
    t.frame();
    try testing.expect(s.low <= s.high);
}

const Copies = struct {
    copies: f64 = 1,
    opacity: f64 = 0.5,
    text: ui.TextBuffer = .{},
    otext: ui.TextBuffer = .{},
    changes: u32 = 0,
    fn view(s: *Copies, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (range.stepper(c, &s.copies, .{ .min = 1, .max = 20, .step = 1 })) s.changes += 1;
        ui.textf(c, .{}, "{d} copies", .{s.copies});
        if (range.numberInput(c, &s.copies, &s.text, .{ .min = 1, .max = 20, .step = 1 })) s.changes += 1;
        _ = range.numberInput(c, &s.opacity, &s.otext, .{ .min = 0, .max = 1, .step = 0.05 });
        ui.text(c, "Elsewhere", .{});
    }
};

test "the stepper's arrows step, stop at the bounds, and take the keys" {
    var s: Copies = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Copies.view), .{});
    defer t.deinit();
    // Its arrows: x 20..40, the up one y 20..33, the down one 33..46.
    t.click(30, 26);
    t.click(30, 26);
    try testing.expectEqual(@as(f64, 3), s.copies);
    t.click(30, 39);
    try testing.expectEqual(@as(f64, 2), s.copies);
    t.key(.up);
    try testing.expectEqual(@as(f64, 3), s.copies);
    t.key(.end);
    try testing.expectEqual(@as(f64, 20), s.copies);
    t.click(30, 26);
    try testing.expectEqual(@as(f64, 20), s.copies);
    t.key(.home);
    t.key(.down);
    try testing.expectEqual(@as(f64, 1), s.copies);
    try testing.expect(t.hasText("1 copies"));
}

test "holding an arrow keeps stepping, faster after a while" {
    var s: Copies = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Copies.view), .{});
    defer t.deinit();
    t.moveTo(30, 26);
    t.ctx.pointerDown();
    t.frame();
    try testing.expectEqual(@as(f64, 2), s.copies);
    t.advance(0.3);
    try testing.expectEqual(@as(f64, 2), s.copies);
    // After 0.4 s, a step every 80 ms: by 0.8 s, five more.
    t.advance(0.5);
    try testing.expect(s.copies >= 6 and s.copies <= 8);
    t.ctx.pointerUp();
    t.frame();
    const after = s.copies;
    t.advance(0.5);
    try testing.expectEqual(after, s.copies);
}

test "a number input applies what is typed in range, steps, and rounds on blur" {
    var s: Copies = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Copies.view), .{});
    defer t.deinit();
    try testing.expectEqualStrings("1", s.text.text());
    try testing.expectEqualStrings("0.50", s.otext.text());
    try t.clickText("1");
    t.key(.end);
    t.key(.backspace);
    t.typeText("12");
    try testing.expectEqual(@as(f64, 12), s.copies);
    // Out of range: kept as typed, the value unchanged.
    t.typeText("5");
    try testing.expectEqualStrings("125", s.text.text());
    try testing.expectEqual(@as(f64, 12), s.copies);
    t.key(.backspace);
    t.key(.up);
    try testing.expectEqual(@as(f64, 13), s.copies);
    try testing.expectEqualStrings("13", s.text.text());
    t.key(.down);
    t.key(.down);
    try testing.expectEqual(@as(f64, 11), s.copies);
    // Not a number: nothing applies, and blur shows the value again.
    t.typeText("x");
    try testing.expectEqual(@as(f64, 11), s.copies);
    try t.clickText("Elsewhere");
    try testing.expectEqualStrings("11", s.text.text());
    // The stepper changed it: the input shows it.
    t.click(30, 26);
    try testing.expectEqualStrings("12", s.text.text());
}

test "a number input's buttons step by the step, disabled at the bounds" {
    var s: Copies = .{ .opacity = 0.9 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Copies.view), .{});
    defer t.deinit();
    const r = t.findText("0.90").?;
    // The second number input's "+" is the last "+" drawn.
    var plus: ?ui.Rect = null;
    var minus: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (n.rect.y > r.y - 10 and n.rect.y < r.y + 10) {
            if (std.mem.eql(u8, tx.str, "+")) plus = n.rect;
            if (std.mem.eql(u8, tx.str, "−")) minus = n.rect;
        },
        else => {},
    };
    t.click(plus.?.x + 2, plus.?.y + 4);
    t.click(plus.?.x + 2, plus.?.y + 4);
    t.click(plus.?.x + 2, plus.?.y + 4);
    try testing.expectEqual(@as(f64, 1), s.opacity);
    try testing.expectEqualStrings("1.00", s.otext.text());
    t.click(minus.?.x + 2, minus.?.y + 4);
    try testing.expectEqual(@as(f64, 0.95), s.opacity);
}

const Levels = struct {
    fn view(_: *Levels, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        range.meter(c, 0.5, .{ .width = .{ .px = 100 } });
        range.spinner(c, .{});
    }
};

test "a meter's color follows its levels, high or low" {
    var s: Levels = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Levels.view), .{});
    defer t.deinit();
    const c = &t.ctx;
    const disk: range.MeterOptions = .{ .max = 100, .warning = 80, .critical = 95 };
    try testing.expectEqual(c.theme.success, range.meterColor(c, 50, disk));
    try testing.expect(!std.meta.eql(c.theme.success, range.meterColor(c, 85, disk)));
    try testing.expectEqual(c.theme.danger, range.meterColor(c, 96, disk));
    const battery: range.MeterOptions = .{ .max = 100, .warning = 20, .critical = 10 };
    try testing.expectEqual(c.theme.success, range.meterColor(c, 50, battery));
    try testing.expectEqual(c.theme.danger, range.meterColor(c, 5, battery));
    try testing.expect(!std.meta.eql(c.theme.danger, range.meterColor(c, 15, battery)));
    try testing.expectEqual(c.theme.success, range.meterColor(c, 99, .{}));
    // Filled to half its width.
    var fill: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| if (n.style.background) |b| {
        if (std.meta.eql(b, c.theme.success)) fill = n.rect;
    };
    try testing.expectApproxEqAbs(@as(f32, 50), fill.?.w, 0.5);
}

test "a spinner steps a twelfth of a turn on the clock, asking only for its next step" {
    var s: Levels = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Levels.view), .{});
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), range.spinnerStep(0));
    try testing.expectEqual(@as(u8, 1), range.spinnerStep(0.08));
    try testing.expectEqual(@as(u8, 11), range.spinnerStep(0.89));
    try testing.expectEqual(@as(u8, 0), range.spinnerStep(0.9));
    try testing.expect(t.ctx.frame_in != null and t.ctx.frame_in.? <= 0.075 + 1e-4);
    try testing.expect(!t.ctx.animating);
    const brightest = struct {
        fn f(tt: *ui.Tester) usize {
            var best: f32 = 0;
            var at: usize = 0;
            var k: usize = 0;
            for (tt.ctx.nodes.items) |n| if (n.style.absolute) {
                if (n.style.background.?.a > best) {
                    best = n.style.background.?.a;
                    at = k;
                }
                k += 1;
            };
            return at;
        }
    }.f;
    const before = brightest(&t);
    t.advance(0.075 * 3);
    try testing.expect(brightest(&t) != before);
}
