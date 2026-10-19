//! Colors: a picker (a square of saturation and brightness, sliders of
//! hue and opacity, the color in hex, swatches) and the well opening it.
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const textfield = @import("textfield.zig");
const state = @import("controls_state.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Color = types.Color;

pub const Hsva = struct {
    /// Degrees, 0 to 360.
    h: f32 = 0,
    s: f32 = 0,
    v: f32 = 0,
    a: f32 = 1,

    pub fn of(c: Color) Hsva {
        const hi = @max(c.r, @max(c.g, c.b));
        const lo = @min(c.r, @min(c.g, c.b));
        const d = hi - lo;
        var h: f32 = 0;
        if (d > 0) {
            if (hi == c.r) h = 60 * @mod((c.g - c.b) / d, 6) //
            else if (hi == c.g) h = 60 * ((c.b - c.r) / d + 2) //
            else h = 60 * ((c.r - c.g) / d + 4);
        }
        if (h < 0) h += 360;
        return .{ .h = h, .s = if (hi > 0) d / hi else 0, .v = hi, .a = c.a };
    }

    pub fn color(x: Hsva) Color {
        const k = x.v * x.s;
        const h = @mod(x.h, 360) / 60;
        const y = k * (1 - @abs(@mod(h, 2) - 1));
        const rgb: [3]f32 = if (h < 1) .{ k, y, 0 } else if (h < 2) .{ y, k, 0 } else if (h < 3) .{ 0, k, y } else if (h < 4) .{ 0, y, k } else if (h < 5) .{ y, 0, k } else .{ k, 0, y };
        const m = x.v - k;
        return quantize(.{ .r = rgb[0] + m, .g = rgb[1] + m, .b = rgb[2] + m, .a = x.a });
    }
};

fn byte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// The color with each channel on a step of 1/255, as hex keeps it.
pub fn quantize(c: Color) Color {
    const f = struct {
        fn q(v: f32) f32 {
            return @as(f32, @floatFromInt(byte(v))) / 255;
        }
    }.q;
    return .{ .r = f(c.r), .g = f(c.g), .b = f(c.b), .a = f(c.a) };
}

/// `#rrggbb`, or `#rrggbbaa` when not opaque, in the frame's memory.
pub fn hexOf(c: *Context, col: Color) []const u8 {
    if (byte(col.a) == 255) return c.print("#{x:0>2}{x:0>2}{x:0>2}", .{ byte(col.r), byte(col.g), byte(col.b) });
    return c.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ byte(col.r), byte(col.g), byte(col.b), byte(col.a) });
}

/// `#rgb`, `#rrggbb` or `#rrggbbaa` (the `#` optional).
pub fn parseHex(raw: []const u8) ?Color {
    var s = std.mem.trim(u8, raw, " ");
    if (s.len > 0 and s[0] == '#') s = s[1..];
    var v: [4]u8 = .{ 0, 0, 0, 255 };
    switch (s.len) {
        3 => for (0..3) |i| {
            const d = std.fmt.charToDigit(s[i], 16) catch return null;
            v[i] = d * 17;
        },
        6, 8 => for (0..s.len / 2) |i| {
            v[i] = std.fmt.parseInt(u8, s[2 * i .. 2 * i + 2], 16) catch return null;
        },
        else => return null,
    }
    return .{ .r = @as(f32, @floatFromInt(v[0])) / 255, .g = @as(f32, @floatFromInt(v[1])) / 255, .b = @as(f32, @floatFromInt(v[2])) / 255, .a = @as(f32, @floatFromInt(v[3])) / 255 };
}

/// What a picker keeps across frames, by the app: the hue a gray keeps,
/// the hex being typed, and whether a well's picker is open.
pub const ColorPicker = struct {
    hsva: Hsva = .{},
    last: ?Color = null,
    hex: textfield.TextBuffer = .{},
    open: bool = false,
};

pub const swatches = [_]u24{ 0xef4444, 0xf97316, 0xeab308, 0x22c55e, 0x14b8a6, 0x3b82f6, 0x6366f1, 0xa855f7, 0xec4899, 0x92400e, 0x71717a, 0x000000 };

const width: f32 = 228;
const square_h: f32 = 150;

// The square's and the hue slider's colors, as gradients: smooth, as
// AppKit's panel draws them (the renderers dither them).
const whiten = [_]types.Stop{ .{ .color = Color.white, .at = 0 }, .{ .color = Color.white.alpha(0), .at = 1 } };
const darken = [_]types.Stop{ .{ .color = Color.black.alpha(0), .at = 0 }, .{ .color = Color.black, .at = 1 } };
const across: types.Gradient = .{ .stops = &whiten, .angle = 90 };
const down: types.Gradient = .{ .stops = &darken };
const hues = blk: {
    var st: [7]types.Stop = undefined;
    for (&st, 0..) |*x, k| {
        const f = @as(f32, @floatFromInt(k)) / 6;
        x.* = .{ .color = (Hsva{ .h = f * 360, .s = 1, .v = 1 }).color(), .at = f };
    }
    break :blk st;
};
const hue_gradient: types.Gradient = .{ .stops = &hues, .angle = 90 };

/// A color picker over `color`, as AppKit's color panel: a square choosing
/// the saturation, across, and the brightness, up, of the hue the slider
/// below it chooses; a slider of opacity; the color in hex, which the user
/// edits; and swatches. The arrows move across the square while it has the
/// keyboard focus. Returns true when the color changes.
pub fn colorPicker(c: *Context, color: *Color, p: *ColorPicker) bool {
    const th = c.theme;
    if (p.last == null or !std.meta.eql(p.last.?, color.*)) {
        // The app set it: start from it (a gray keeps the hue it had).
        const x = Hsva.of(color.*);
        p.hsva = .{ .h = if (x.s == 0 or x.v == 0) p.hsva.h else x.h, .s = x.s, .v = x.v, .a = x.a };
        p.last = color.*;
    }
    var x = p.hsva;
    var moved = false;
    _ = c.open(.{ .width = .{ .px = width }, .gap = 10 }, null);
    defer c.end();

    // The square: the hue, whitened to the left and darkened downward.
    const sq = c.open(.{ .width = .{ .px = width }, .height = .{ .px = square_h }, .radius = 6, .clip = true, .background = (Hsva{ .h = x.h, .s = 1, .v = 1 }).color(), .control = true }, null);
    const si = c.interact(sq, .{ .focusable = true });
    _ = c.leaf(.{ .absolute = true, .width = .fill, .height = .fill, .gradient = &across }, .none, null);
    _ = c.leaf(.{ .absolute = true, .width = .fill, .height = .fill, .gradient = &down }, .none, null);
    const marker = c.leaf(.{ .absolute = true, .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .border = .white, .border_width = 2, .shadow = .{ .color = .{ .a = 0.4 }, .blur = 2, .y = 0 } }, .none, null);
    c.end();
    if (si.pressed) if (si.rect) |r| {
        x.s = std.math.clamp((c.input.mouse.x - r.x) / r.w, 0, 1);
        x.v = 1 - std.math.clamp((c.input.mouse.y - r.y) / r.h, 0, 1);
        moved = true;
    };
    if (si.focused and c.focus == si.id) if (c.input.key) |key| {
        switch (key) {
            .right => x.s = @min(1, x.s + 0.01),
            .left => x.s = @max(0, x.s - 0.01),
            .up => x.v = @min(1, x.v + 0.01),
            .down => x.v = @max(0, x.v - 0.01),
            else => {},
        }
        if (key == .left or key == .right or key == .up or key == .down) {
            c.input.key = null;
            moved = true;
        }
    };
    state.focusRing(c, sq, si.focused and c.focus == si.id);

    // Hue, then opacity.
    if (channel(c, x.h / 360, .hue, x)) |f| {
        x.h = f * 360;
        moved = true;
    }
    if (channel(c, x.a, .alpha, x)) |f| {
        x.a = f;
        moved = true;
    }
    if (moved) p.hsva = x;
    c.node(marker).style.offset = .{ .x = x.s * width - 7, .y = (1 - x.v) * square_h - 7 };
    c.node(sq).style.background = (Hsva{ .h = x.h, .s = 1, .v = 1 }).color();

    var next = if (moved) x.color() else color.*;
    // The color now, and its hex.
    _ = c.open(.{ .direction = .row, .gap = 8, .align_items = .center }, null);
    _ = c.leaf(.{ .width = .{ .px = 30 }, .height = .{ .px = 30 }, .radius = 6, .border = th.border, .background = next }, .none, null);
    const field_id = c.peekId(null);
    if (c.focus != field_id and !std.mem.eql(u8, p.hex.text(), hexOf(c, next))) p.hex.set(hexOf(c, next));
    const r = textfield.textField(c, &p.hex, .{ .width = .fill, .size = 13 });
    c.end();
    if (r.changed) if (parseHex(p.hex.text())) |v| {
        next = v;
        const hv = Hsva.of(v);
        p.hsva = .{ .h = if (hv.s == 0 or hv.v == 0) p.hsva.h else hv.h, .s = hv.s, .v = hv.v, .a = hv.a };
    };

    // Swatches, six to a row.
    for (0..2) |row| {
        _ = c.open(.{ .direction = .row, .gap = 6 }, null);
        defer c.end();
        for (swatches[row * 6 .. row * 6 + 6]) |sw| {
            const sc = Color.hex(sw);
            const chosen = std.meta.eql(quantize(color.*), quantize(sc));
            const b = c.open(.{ .width = .{ .px = (width - 30) / 6 }, .height = .{ .px = 22 }, .radius = 5, .background = sc, .border = if (chosen) th.text else null, .border_width = 2, .control = true }, null);
            const bi = c.interact(b, .{});
            c.end();
            if (bi.clicked) {
                next = sc;
                const hv = Hsva.of(sc);
                p.hsva = .{ .h = if (hv.s == 0) p.hsva.h else hv.h, .s = hv.s, .v = hv.v, .a = 1 };
                c.focus = 0;
            }
        }
    }
    if (std.meta.eql(next, color.*)) return false;
    color.* = next;
    p.last = next;
    c.changed = true;
    return true;
}

/// A slider of hue or opacity: the fraction a press or the keys set.
fn channel(c: *Context, f: f32, comptime kind: enum { hue, alpha }, x: Hsva) ?f32 {
    const knob: f32 = 14;
    const i = c.open(.{ .width = .{ .px = width }, .height = .{ .px = 16 }, .control = true }, null);
    const it = c.interact(i, .{ .focusable = true });
    _ = c.leaf(.{ .absolute = true, .width = .fill, .height = .{ .px = 12 }, .radius = 6, .background = if (kind == .alpha) Color.hex(0xcccccc) else null, .offset = .{ .y = 2 } }, .none, null);
    const g: *const types.Gradient = if (kind == .hue) &hue_gradient else blk: {
        // The color from clear to opaque, kept until the frame is drawn.
        const a = c.alloc();
        const st = a.alloc(types.Stop, 2) catch break :blk &hue_gradient;
        const solid = (Hsva{ .h = x.h, .s = x.s, .v = x.v, .a = 1 }).color();
        st[0] = .{ .color = solid.alpha(0), .at = 0 };
        st[1] = .{ .color = solid, .at = 1 };
        const gr = a.create(types.Gradient) catch break :blk &hue_gradient;
        gr.* = .{ .stops = st, .angle = 90 };
        break :blk gr;
    };
    _ = c.leaf(.{ .absolute = true, .width = .fill, .height = .{ .px = 12 }, .radius = 6, .gradient = g, .offset = .{ .y = 2 } }, .none, null);
    const k = c.leaf(.{ .absolute = true, .width = .{ .px = knob }, .height = .{ .px = knob }, .radius = knob / 2, .background = .white, .shadow = .{ .color = .{ .a = 0.35 }, .blur = 3, .y = 1 }, .offset = .{ .y = 1 } }, .none, null);
    c.end();
    var next: ?f32 = null;
    if (it.pressed) if (it.rect) |r| {
        next = std.math.clamp((c.input.mouse.x - r.x - knob / 2) / (r.w - knob), 0, 1);
    };
    if (it.focused and c.focus == it.id) if (c.input.key) |key| {
        const step: f32 = if (kind == .hue) 1.0 / 360.0 else 0.01;
        next = switch (key) {
            .right, .up => @min(1, f + step),
            .left, .down => @max(0, f - step),
            .home => 0,
            .end => 1,
            else => next,
        };
        if (next != null) c.input.key = null;
    };
    c.node(k).style.offset.x = (next orelse f) * (width - knob);
    state.focusRing(c, k, it.focused and c.focus == it.id);
    return next;
}

/// A swatch of `color` opening a picker below it, as AppKit's color well:
/// a click, Enter or Space opens it, and Escape or a click outside closes
/// it. Returns true when the color changes.
pub fn colorWell(c: *Context, color: *Color, p: *ColorPicker) bool {
    const th = c.theme;
    const i = c.open(.{ .padding = .all(4), .radius = 8, .background = th.surface, .border = th.border, .control = true }, null);
    const it = c.interact(i, .{ .focusable = true });
    _ = c.leaf(.{ .width = .{ .px = 36 }, .height = .{ .px = 20 }, .radius = 4, .background = color.* }, .none, null);
    c.end();
    const focused = c.focus == it.id;
    var changed = false;
    if (it.clicked or (focused and !p.open and (c.input.key == .enter or state.takeSpace(c)))) {
        c.input.key = null;
        p.open = !p.open;
        c.changed = true;
    }
    if (p.open) {
        if (c.input.key == .escape) {
            c.input.key = null;
            p.open = false;
            c.focus = it.id;
            c.changed = true;
        }
        const r = c.rects.get(it.id) orelse types.Rect{};
        const o = c.openOverlay(.{ .absolute = true, .offset = .{ .x = r.x, .y = r.y + r.h + 4 }, .padding = .all(12), .radius = 10, .background = th.surface, .border = th.border, .shadow = .{ .color = th.shadow, .blur = 16, .y = 6 } }, "picker");
        const oi = c.interact(o, .{});
        if (p.open) changed = colorPicker(c, color, p);
        c.end();
        if (c.pressedOutside(oi.id) and c.hot != it.id) {
            p.open = false;
            c.changed = true;
        }
    }
    state.focusRing(c, i, focused);
    return changed;
}
