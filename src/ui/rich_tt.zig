//! Rich text where myzig lays it out: a paragraph cut where its spans
//! change the font (bold, italics, inline code) into pieces, shaped
//! together (one line of the engine's, ordered by direction as a whole),
//! cached as plain text is.
const std = @import("std");
const types = @import("types.zig");
const spans_mod = @import("spans.zig");
const text = @import("text_tt.zig");

pub const mono_scale = spans_mod.mono_scale;
pub const styled = spans_mod.styled;
pub const spanStyle = spans_mod.spanStyle;
pub const spansHash = spans_mod.spansHash;

/// The style of byte `at` of the paragraph.
fn styleAt(base: types.TextStyle, spans: []const types.Span, at: usize) types.TextStyle {
    var st = base;
    for (spans) |sp| if (sp.styled() and sp.start <= at and at < sp.end) {
        st = spanStyle(st, sp);
    };
    return st;
}

fn sameFont(a: types.TextStyle, b: types.TextStyle) bool {
    return a.size == b.size and a.weight == b.weight and a.mono == b.mono and a.italic == b.italic;
}

/// `s` shaped on one line, with the spans of the paragraph it starts at
/// byte `offset` of.
pub fn layout(ts: *text.TextSystem, s: []const u8, base: types.TextStyle, spans: []const types.Span, offset: usize) text.Layout {
    if (s.len == 0) return .{ .width = 0, .glyphs = &.{} };
    const k = text.TextSystem.key(s, base, 3 ^ spansHash(spans, offset, offset + s.len));
    if (ts.cached(k)) |l| return l;
    var pieces: std.ArrayList(text.Styled) = .empty;
    defer pieces.deinit(ts.gpa);
    var start: usize = 0;
    while (start < s.len) {
        const st = styleAt(base, spans, offset + start);
        var end = start + 1;
        while (end < s.len and sameFont(styleAt(base, spans, offset + end), st)) end += 1;
        pieces.append(ts.gpa, .{ .start = @intCast(start), .end = @intCast(end), .style = st }) catch return .{ .width = 0, .glyphs = &.{} };
        start = end;
    }
    return ts.keep(k, ts.shapeLine(s, pieces.items) catch .{ .width = 0, .glyphs = &.{} });
}
