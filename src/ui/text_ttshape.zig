//! Shaping with myzig's own TrueType reader, where no text engine is (or
//! its libraries are missing): characters to glyphs through the character
//! map, kerning from the `kern` table, fallback faces for characters a face
//! lacks, and runs ordered by the bidirectional algorithm, with brackets
//! mirrored in right-to-left runs. There is no OpenType shaping here:
//! Arabic shows its letters unjoined.
const std = @import("std");
const types = @import("types.zig");
const bidi = @import("bidi.zig");
const runs = @import("text_runs.zig");
const engine = @import("text_engine.zig");
const utf8 = @import("utf8.zig");
const TextSystem = @import("text_tt.zig").TextSystem;

/// Shapes `s` in `style` from pen position `x0`, left to right, appending
/// its glyphs (byte offsets plus `offset`); returns the pen position after.
pub fn shapeInto(ts: *TextSystem, out: *std.ArrayList(runs.Glyph), s: []const u8, style: types.TextStyle, x0: f32, offset: usize) !f32 {
    const f = ts.font(style);
    const size = style.size * ts.zoom;
    var x = x0;
    if (f.id == 0xffff or !ts.isTT(f.id)) return x + @as(f32, @floatFromInt(s.len)) * size * 0.5;
    var prev: ?struct { id: u16, g: u16 } = null;
    var i: usize = 0;
    while (i < s.len) {
        const n = @min(utf8.seqLen(s[i]), s.len - i);
        const cp: u21 = utf8.decode(s[i .. i + n]) catch 0xfffd;
        const m = ts.ttGlyph(f, style, cp);
        const rf = ts.ttFont(m.id);
        const k = size / rf.font.units_per_em;
        if (prev) |p| if (p.id == m.id) {
            x += rf.font.kerning(p.g, m.g) * k;
        };
        if (cp >= 0x20 or cp == '\t') try out.append(ts.gpa, .{ .font = m.id, .glyph = m.g, .x = x, .y = 0, .index = @intCast(offset + i) });
        x += (rf.font.advance(m.g) * k + rf.embolden * size) * @as(f32, if (cp == '\t') 4 else 1);
        prev = .{ .id = m.id, .g = m.g };
        i += n;
    }
    return x;
}

/// The character shown for `cp` in a right-to-left run.
fn mirror(cp: u21) u21 {
    return switch (cp) {
        '(' => ')',
        ')' => '(',
        '<' => '>',
        '>' => '<',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        0xab => 0xbb,
        0xbb => 0xab,
        0x2039 => 0x203a,
        0x203a => 0x2039,
        else => cp,
    };
}

/// One style over bytes `start`..`end` of a paragraph.
pub const Styled = struct { start: u32, end: u32, style: types.TextStyle };

/// Shapes a paragraph of pieces in their styles, reordered for display,
/// into `sink` (faces there are run fonts, sizes 0).
pub fn shapeBidi(ts: *TextSystem, s: []const u8, pieces: []const Styled, sink: *engine.Sink) !bool {
    var levels: std.ArrayList(bidi.Run) = .empty;
    defer levels.deinit(ts.gpa);
    _ = try bidi.resolve(ts.gpa, s, null, &levels);
    // The bidi runs cut where the style changes.
    var cut: std.ArrayList(bidi.Run) = .empty;
    defer cut.deinit(ts.gpa);
    var styles: std.ArrayList(u32) = .empty;
    defer styles.deinit(ts.gpa);
    for (levels.items) |lv| for (pieces, 0..) |p, pi| {
        const a = @max(lv.start, p.start);
        const b = @min(lv.end, p.end);
        if (a >= b) continue;
        try cut.append(ts.gpa, .{ .start = a, .end = b, .level = lv.level });
        try styles.append(ts.gpa, @intCast(pi));
    };
    const order = try ts.gpa.alloc(u32, cut.items.len);
    defer ts.gpa.free(order);
    bidi.visual(cut.items, order);
    var shaped: std.ArrayList(struct { font: u16, g: runs.Shaped }) = .empty;
    defer shaped.deinit(ts.gpa);
    for (order) |ri| {
        const r = cut.items[ri];
        const style = pieces[styles.items[ri]].style;
        const f = ts.font(style);
        if (f.id == 0xffff or !ts.isTT(f.id)) return false;
        const size = style.size * ts.zoom;
        shaped.clearRetainingCapacity();
        var i: usize = r.start;
        while (i < r.end) {
            const n = @min(utf8.seqLen(s[i]), r.end - i);
            var cp: u21 = utf8.decode(s[i .. i + n]) catch 0xfffd;
            if (r.rtl()) cp = mirror(cp);
            const m = ts.ttGlyph(f, style, cp);
            const rf = ts.ttFont(m.id);
            const k = size / rf.font.units_per_em;
            const adv = if (cp < 0x20 and cp != '\t') 0 else (rf.font.advance(m.g) * k + rf.embolden * size) * @as(f32, if (cp == '\t') 4 else 1);
            try shaped.append(ts.gpa, .{ .font = m.id, .g = .{ .id = m.g, .advance = adv, .cluster = @intCast(i) } });
            i += n;
        }
        if (r.rtl()) std.mem.reverse(@TypeOf(shaped.items[0]), shaped.items);
        // Kerning between neighbors of a face, then runs of one face.
        var cur: ?u16 = null;
        for (shaped.items, 0..) |*e, k| {
            if (k > 0 and shaped.items[k - 1].font == e.font) {
                const rf = ts.ttFont(e.font);
                const kern = rf.font.kerning(shaped.items[k - 1].g.id, e.g.id) * size / rf.font.units_per_em;
                shaped.items[k - 1].g.advance += kern;
            }
        }
        var k: usize = 0;
        while (k < shaped.items.len) {
            cur = shaped.items[k].font;
            var j = k;
            var lo: u32 = std.math.maxInt(u32);
            var hi: u32 = 0;
            while (j < shaped.items.len and shaped.items[j].font == cur.?) : (j += 1) {
                lo = @min(lo, shaped.items[j].g.cluster);
                hi = @max(hi, shaped.items[j].g.cluster);
            }
            // Its bytes end where the run's next character in logical order starts.
            var end = r.end;
            for (shaped.items) |e| if (e.g.cluster > hi and e.g.cluster < end) {
                end = e.g.cluster;
            };
            try sink.begin(cur.?, 0, r.level, lo, end, 0);
            for (shaped.items[k..j]) |e| try sink.glyph(e.g);
            k = j;
        }
    }
    return true;
}
