//! A fast path for shaping simple text where a text engine shapes it
//! (DirectWrite, HarfBuzz), as `shaper.zig` is for CoreText: each
//! character's glyph and advance, and each pair's kerning, are learned once
//! from the engine and cached, so laying out "Row 1234" again with other
//! digits costs lookups, not an engine's layout. Simple characters are those
//! of scripts that need no shaping beyond pairs (Latin, Greek, Cyrillic,
//! punctuation, currency): a pair the engine turns into one glyph (a
//! ligature), a character its font lacks (drawn by a fallback font) or
//! anything else falls back to the engine; tests check the fast path
//! places glyphs exactly as the engine does.
const std = @import("std");
const runs = @import("text_runs.zig");
const utf8 = @import("utf8.zig");

/// What the engine makes of one or two characters.
pub const Short = struct {
    n: usize = 0,
    /// The run font of the first glyph, as text systems number them.
    font: u16 = 0xffff,
    /// Every glyph is in that font.
    one_font: bool = true,
    glyphs: [2]u16 = .{ 0, 0 },
    x: [2]f32 = .{ 0, 0 },
    width: f32 = 0,
};

/// Characters shaped one at a time as they are shaped together.
pub fn simple(cp: u21) bool {
    return (cp >= 0x20 and cp < 0x7f) or
        (cp >= 0xa0 and cp < 0x300 and cp != 0xad) or
        (cp >= 0x370 and cp < 0x530 and !(cp >= 0x483 and cp <= 0x489)) or
        (cp >= 0x1e00 and cp < 0x1f00) or
        (cp >= 0x2010 and cp <= 0x2027) or
        (cp >= 0x2030 and cp <= 0x205e) or
        (cp >= 0x20a0 and cp <= 0x20c0) or
        (cp >= 0x2100 and cp < 0x2150);
}

const Char = struct { glyph: u16 = 0, advance: f32 = 0, ok: bool = false };
const Pair = struct { kern: f32, complex: bool };

const max_chars = 512;

/// The cached shaping of one font's simple characters.
pub const Table = struct {
    /// The run font the engine draws these characters in.
    font: u16,
    ascii: [95]?Char = @splat(null),
    others: std.AutoHashMapUnmanaged(u21, Char) = .empty,
    pairs: std.AutoHashMapUnmanaged(u64, Pair) = .empty,

    pub fn deinit(t: *Table, gpa: std.mem.Allocator) void {
        t.others.deinit(gpa);
        t.pairs.deinit(gpa);
    }

    fn learn(t: *Table, shaper: anytype, cp: u21) Char {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return .{};
        const s = shaper.short(buf[0..n]);
        if (s.n != 1 or s.font != t.font or !s.one_font) return .{};
        return .{ .glyph = s.glyphs[0], .advance = s.width, .ok = true };
    }

    fn char(t: *Table, gpa: std.mem.Allocator, shaper: anytype, cp: u21) ?Char {
        if (cp >= 0x20 and cp < 0x7f) {
            const slot = &t.ascii[cp - 0x20];
            if (slot.* == null) slot.* = t.learn(shaper, cp);
            return if (slot.*.?.ok) slot.*.? else null;
        }
        if (t.others.get(cp)) |c| return if (c.ok) c else null;
        const c = t.learn(shaper, cp);
        t.others.put(gpa, cp, c) catch {};
        return if (c.ok) c else null;
    }

    fn pair(t: *Table, gpa: std.mem.Allocator, shaper: anytype, a: u21, ca: Char, b: u21, cb: Char) Pair {
        const key = (@as(u64, a) << 21) | b;
        if (t.pairs.get(key)) |p| return p;
        var buf: [8]u8 = undefined;
        const na = std.unicode.utf8Encode(a, &buf) catch 0;
        const nb = std.unicode.utf8Encode(b, buf[na..]) catch 0;
        const s = shaper.short(buf[0 .. na + nb]);
        const p: Pair = if (s.n == 2 and s.one_font and s.font == t.font and s.glyphs[0] == ca.glyph and s.glyphs[1] == cb.glyph)
            .{ .kern = s.x[1] - ca.advance, .complex = false }
        else
            .{ .kern = 0, .complex = true };
        t.pairs.put(gpa, key, p) catch {};
        return p;
    }

    /// `s` laid out as the engine would, its glyphs in `gpa`; null when it
    /// needs the engine itself.
    pub fn layout(t: *Table, gpa: std.mem.Allocator, shaper: anytype, s: []const u8) ?runs.Layout {
        var cps: [max_chars]u21 = undefined;
        var at: [max_chars]u32 = undefined;
        var info: [max_chars]Char = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (n += 1) {
            if (n == max_chars) return null;
            const len = @min(utf8.seqLen(s[i]), s.len - i);
            const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return null;
            if (!simple(cp)) return null;
            cps[n] = cp;
            at[n] = @intCast(i);
            info[n] = t.char(gpa, shaper, cp) orelse return null;
            i += len;
        }
        var x: f32 = 0;
        var xs: [max_chars]f32 = undefined;
        for (0..n) |k| {
            if (k > 0) {
                const p = t.pair(gpa, shaper, cps[k - 1], info[k - 1], cps[k], info[k]);
                if (p.complex) return null;
                x += p.kern;
            }
            xs[k] = x;
            x += info[k].advance;
        }
        const glyphs = gpa.alloc(runs.Glyph, n) catch return null;
        for (glyphs, 0..) |*g, k| g.* = .{ .font = t.font, .glyph = info[k].glyph, .x = xs[k], .y = 0, .index = at[k] };
        return .{ .width = x, .glyphs = glyphs };
    }
};

test "the fast path from a fake engine: kerning, ligatures, fallbacks" {
    const gpa = std.testing.allocator;
    // Glyphs are characters, 10 wide; "AV" kerns by -2, "fi" is a ligature,
    // and "é" is in another font.
    const Fake = struct {
        calls: usize = 0,
        fn short(f: *@This(), s: []const u8) Short {
            f.calls += 1;
            if (std.mem.eql(u8, s, "fi")) return .{ .n = 1, .font = 0, .glyphs = .{ 99, 0 }, .width = 10 };
            if (std.mem.indexOf(u8, s, "\xc3\xa9") != null) return .{ .n = 1, .font = 1, .glyphs = .{ 1, 0 }, .width = 10 };
            var out: Short = .{ .n = s.len, .font = 0 };
            for (s, 0..) |c, k| {
                out.glyphs[k] = c;
                out.x[k] = @floatFromInt(10 * k);
            }
            if (std.mem.eql(u8, s, "AV")) out.x[1] = 8;
            out.width = if (std.mem.eql(u8, s, "AV")) 18 else @floatFromInt(10 * s.len);
            return out;
        }
    };
    var fake: Fake = .{};
    var t: Table = .{ .font = 0 };
    defer t.deinit(gpa);
    const l = t.layout(gpa, &fake, "AVA").?;
    defer gpa.free(l.glyphs);
    try std.testing.expectEqual(@as(f32, 28), l.width);
    try std.testing.expectEqual(@as(f32, 8), l.glyphs[1].x);
    try std.testing.expect(t.layout(gpa, &fake, "fit") == null);
    try std.testing.expect(t.layout(gpa, &fake, "caf\xc3\xa9") == null);
    // Learned once: laying out again asks nothing.
    const calls = fake.calls;
    const again = t.layout(gpa, &fake, "VAV").?;
    gpa.free(again.glyphs);
    try std.testing.expectEqual(calls, fake.calls);
}
