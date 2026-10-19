//! Text where myzig lays it out (Linux, Windows): shaping through the
//! system's engine (Arabic joined, ligatures, right-to-left order), fallback
//! fonts for CJK and emoji, color emoji, the fast path against the engine,
//! and carets, hit testing, selections and wrapping agreeing with one
//! another in either direction. Tests of the engine are skipped where it is
//! missing; those of order and carets run on myzig's own reader too.
const std = @import("std");
const text = @import("text_tt.zig");
const types = @import("types.zig");
const caret = @import("text_caret.zig");

const t = std.testing;
const style: types.TextStyle = .{ .size = 16 };

const hebrew = "\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d"; // שלום
const arabic = "\xd8\xa8\xd8\xa8\xd8\xa8"; // ببب
const beh = "\xd8\xa8"; // ب
const lam_alef = "\xd9\x84\xd8\xa7"; // لا
const cjk = "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e"; // 日本語
const emoji = "\xf0\x9f\x98\x80"; // 😀

fn nativeSystem() ?text.TextSystem {
    var ts = text.TextSystem.init(t.allocator);
    if (!ts.native()) {
        ts.deinit();
        return null;
    }
    return ts;
}

/// Both text systems: the engine's (where there is one), and myzig's own.
fn systems(buf: *[2]text.TextSystem) []text.TextSystem {
    var n: usize = 0;
    if (nativeSystem()) |ts| {
        buf[n] = ts;
        n += 1;
    }
    buf[n] = text.TextSystem.initWith(t.allocator, .{ .native = false });
    n += 1;
    return buf[0..n];
}

test "Arabic letters join, and lam alef is one glyph" {
    var ts = nativeSystem() orelse return error.SkipZigTest;
    defer ts.deinit();
    const alone = ts.layout(beh, style);
    try t.expectEqual(@as(usize, 1), alone.glyphs.len);
    const joined = ts.layout(arabic, style);
    try t.expectEqual(@as(usize, 3), joined.glyphs.len);
    // Initial, medial and final forms: none is the isolated glyph.
    for (joined.glyphs) |g| {
        try t.expect(g.glyph != 0);
        try t.expect(g.glyph != alone.glyphs[0].glyph);
    }
    try t.expect(joined.glyphs[0].glyph != joined.glyphs[1].glyph);
    // Lam alef: one ligature, or both letters in forms of their own.
    const lig = ts.layout(lam_alef, style);
    if (lig.glyphs.len != 1) {
        try t.expectEqual(@as(usize, 2), lig.glyphs.len);
        const lam = ts.layout(lam_alef[0..2], style).glyphs[0].glyph;
        const alef = ts.layout(lam_alef[2..], style).glyphs[0].glyph;
        for (lig.glyphs) |g| try t.expect(g.glyph != lam and g.glyph != alef);
    }
}

test "ligatures, in a font that has them" {
    var ts = nativeSystem() orelse return error.SkipZigTest;
    defer ts.deinit();
    const family = for ([_][]const u8{ "Calibri", "Cambria", "DejaVu Serif", "Noto Serif", "Liberation Serif" }) |f| {
        if (ts.familyInstalled(f)) break f;
    } else return error.SkipZigTest;
    ts.setFamilies(family, null);
    // "fi" is one glyph, carets inside it split it in two.
    const l = ts.layout("fit", style);
    try t.expectEqual(@as(usize, 2), l.glyphs.len);
    const mid = ts.caretX("fit", style, 1);
    try t.expect(mid > 0 and mid < ts.caretX("fit", style, 2));
}

test "right-to-left text is shown in reverse, mixed text in runs" {
    var buf: [2]text.TextSystem = undefined;
    const all = systems(&buf);
    defer for (all) |*ts| ts.deinit();
    for (all) |*ts| {
        const l = ts.layout(hebrew, style);
        try t.expectEqual(@as(usize, 4), l.glyphs.len);
        // Left to right on the screen: the last letter first.
        try t.expectEqual(@as(u32, 6), l.glyphs[0].index);
        try t.expectEqual(@as(u32, 0), l.glyphs[3].index);
        try t.expect(l.rtl);
        try t.expect(l.glyphs[0].x < l.glyphs[3].x);
        // "ab שלום cd": the Hebrew word between, reversed.
        const s = "ab " ++ hebrew ++ " cd";
        const m = ts.layout(s, style);
        try t.expect(!m.rtl);
        const idx = try t.allocator.alloc(u32, m.glyphs.len);
        defer t.allocator.free(idx);
        for (m.glyphs, idx) |g, *o| o.* = g.index;
        try t.expectEqualSlices(u32, &.{ 0, 1, 2, 9, 7, 5, 3, 11, 12, 13 }, idx);
    }
}

test "carets and hits agree in either direction" {
    var buf: [2]text.TextSystem = undefined;
    const all = systems(&buf);
    defer for (all) |*ts| ts.deinit();
    const samples = [_][]const u8{ "Hello, World", hebrew, "ab " ++ hebrew ++ " cd", hebrew ++ " 123 " ++ hebrew, "x" ++ arabic ++ "y" };
    for (all) |*ts| for (samples) |s| {
        const l = ts.layout(s, style);
        var at: usize = 0;
        while (at <= s.len) {
            const x = ts.caretX(s, style, at);
            try t.expect(x >= -0.01 and x <= l.width + 0.01);
            // A caret's own x hits it back, except where a run's edge
            // meets another's (two bytes share the x).
            const back = ts.indexAt(s, style, x);
            if (back != at) try t.expectApproxEqAbs(x, ts.caretX(s, style, back), 0.01);
            if (at == s.len) break;
            at += @import("utf8.zig").seqLen(s[at]);
        }
    };
    // In Hebrew, the first caret is at the right, the last at the left.
    for (all) |*ts| {
        const w = ts.width(hebrew, style);
        try t.expectApproxEqAbs(w, ts.caretX(hebrew, style, 0), 0.01);
        try t.expectApproxEqAbs(@as(f32, 0), ts.caretX(hebrew, style, hebrew.len), 0.01);
        try t.expectEqual(@as(usize, 0), ts.indexAt(hebrew, style, w + 5));
        try t.expectEqual(hebrew.len, ts.indexAt(hebrew, style, -5));
    }
}

test "a selection across directions shows as ranges" {
    var buf: [2]text.TextSystem = undefined;
    const all = systems(&buf);
    defer for (all) |*ts| ts.deinit();
    for (all) |*ts| {
        const s = "ab " ++ hebrew ++ " cd";
        var out: [8][2]f32 = undefined;
        // "b ש": the "b " at the left, the shin at the right of the word.
        const n = ts.selectionRanges(s, style, 1, 5, &out);
        try t.expectEqual(@as(usize, 2), n);
        try t.expect(out[0][1] < out[1][0]);
        const word_end = ts.caretX(s, style, 3);
        try t.expectApproxEqAbs(word_end, out[1][1], 0.01);
        // All of it: one range, the whole line.
        try t.expectEqual(@as(usize, 1), ts.selectionRanges(s, style, 0, s.len, &out));
        try t.expectApproxEqAbs(ts.width(s, style), out[0][1] - out[0][0], 0.01);
    }
}

test "CJK and emoji are drawn by fallback fonts, not missing glyphs" {
    var ts = nativeSystem() orelse return error.SkipZigTest;
    defer ts.deinit();
    const primary = ts.font(style).id;
    for ([_][]const u8{ cjk, emoji, "a" ++ cjk ++ "b" ++ emoji }) |s| {
        const l = ts.layout(s, style);
        try t.expect(l.glyphs.len > 0);
        for (l.glyphs) |g| try t.expect(g.glyph != 0);
    }
    const l = ts.layout(cjk, style);
    try t.expect(l.glyphs[0].font != primary);
    for (l.glyphs) |g| try t.expect(ts.glyph(g, 0) != null);
}

test "color emoji are drawn in color" {
    var ts = nativeSystem() orelse return error.SkipZigTest;
    defer ts.deinit();
    const l = ts.layout(emoji, .{ .size = 24 });
    try t.expectEqual(@as(usize, 1), l.glyphs.len);
    const sp = ts.glyph(l.glyphs[0], 0) orelse return error.TestUnexpectedResult;
    const uv = sp.picture orelse return error.TestUnexpectedResult;
    // Its pixels among the pictures: some opaque, and not gray.
    const pics = ts.images.pictures();
    const s: f32 = @floatFromInt(pics.size);
    const x0: usize = @intFromFloat(uv[0] * s);
    const y0: usize = @intFromFloat(uv[1] * s);
    const x1: usize = @intFromFloat(uv[2] * s);
    const y1: usize = @intFromFloat(uv[3] * s);
    var colored: usize = 0;
    for (y0..y1) |y| for (x0..x1) |x| {
        const p = pics.pixels[(y * pics.size + x) * 4 ..][0..4];
        if (p[3] > 200 and (@abs(@as(i32, p[0]) - p[1]) > 40 or @abs(@as(i32, p[1]) - p[2]) > 40)) colored += 1;
    };
    try t.expect(colored > 20);
    // Text in a monochrome font has no picture.
    const a = ts.layout("a", .{ .size = 24 });
    try t.expect((ts.glyph(a.glyphs[0], 0) orelse return error.TestUnexpectedResult).picture == null);
}

test "the fast path lays simple text out as the engine does" {
    var ts = nativeSystem() orelse return error.SkipZigTest;
    defer ts.deinit();
    const samples = [_][]const u8{ "1234", "Hello, World!", "AVATAR To Ty", "Row 42 \xe2\x80\x94 a line", "(x) = [y]", "WAVE", "Typography", "caf\xc3\xa9 na\xc3\xafve" };
    for ([_]types.TextStyle{ style, .{ .size = 13, .weight = .bold }, .{ .size = 12, .mono = true } }) |st| for (samples) |s| {
        const fast = ts.layout(s, st);
        const pieces = [_]text.Styled{.{ .start = 0, .end = @intCast(s.len), .style = st }};
        // The engine's own layout, bypassing the fast path.
        const slow = (try ts.engineLineForTest(s, &pieces)) orelse return error.TestUnexpectedResult;
        defer slow.free(t.allocator);
        try t.expectApproxEqAbs(slow.width, fast.width, 0.01);
        try t.expectEqual(slow.glyphs.len, fast.glyphs.len);
        for (slow.glyphs, fast.glyphs) |a, b| {
            try t.expectEqual(a.glyph, b.glyph);
            try t.expectEqual(a.index, b.index);
            try t.expectApproxEqAbs(a.x, b.x, 0.01);
        }
    };
}

test "simple text takes the fast path once its characters are learned" {
    var ts = nativeSystem() orelse return error.SkipZigTest;
    defer ts.deinit();
    var buf: [48]u8 = undefined;
    // Learned: every digit after a space and before one, every pair of digits.
    for (0..10) |i| for (0..10) |j| {
        _ = ts.layout(std.fmt.bufPrint(&buf, "Row {d}{d} — a line", .{ i, j }) catch unreachable, style);
    };
    const before = ts.engine_lines;
    for (0..50) |i| {
        const l = ts.layout(std.fmt.bufPrint(&buf, "Row {d} — a line", .{100 + i * 7919}) catch unreachable, style);
        try t.expect(l.glyphs.len > 10);
    }
    try t.expectEqual(before, ts.engine_lines);
}

test "measuring, wrapping and hit testing agree" {
    var buf: [2]text.TextSystem = undefined;
    const all = systems(&buf);
    defer for (all) |*ts| ts.deinit();
    const para = "The quick brown fox " ++ hebrew ++ " jumps over " ++ cjk ++ " the lazy dog";
    for (all) |*ts| {
        const full = ts.width(para, style);
        try t.expect(full > 100);
        const lines = ts.wrap(para, style, full / 2.5);
        try t.expect(lines.len >= 3);
        var covered: usize = 0;
        for (lines) |ln| {
            // A line is no wider than asked, and as wide as laid out alone.
            try t.expect(ln.width <= full / 2.5 + 0.5);
            const alone = ts.width(para[ln.start..ln.end], style);
            try t.expectApproxEqAbs(alone, ln.width, 1);
            try t.expect(ln.start >= covered);
            covered = ln.end;
        }
        try t.expectEqual(para.len, lines[lines.len - 1].end);
    }
}

test "the bidi class table and engine agree on direction" {
    var buf: [2]text.TextSystem = undefined;
    const all = systems(&buf);
    defer for (all) |*ts| ts.deinit();
    for (all) |*ts| {
        try t.expect(ts.readsRtl(hebrew ++ " abc"));
        try t.expect(!ts.readsRtl("123 abc " ++ hebrew));
        _ = caret;
    }
}
