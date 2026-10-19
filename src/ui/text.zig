//! Text, whichever system shapes it: CoreText on macOS (`text_mac.zig`);
//! elsewhere myzig lays it out (`text_tt.zig`) with the system's engine
//! (DirectWrite on Windows; HarfBuzz, FreeType and fontconfig on Linux) or
//! its own TrueType reader, also on a Mac built with `-Dportable=true` (to
//! test that path). Both give the same interface: fonts, shaped and
//! wrapped layouts, carets, and the glyph atlas.
const builtin = @import("builtin");
const options = @import("build_options");

/// myzig's own text and CPU renderer, not CoreText and Metal.
pub const portable = options.portable or builtin.os.tag != .macos;
const impl = if (portable) @import("text_tt.zig") else @import("text_mac.zig");

pub const TextSystem = impl.TextSystem;
pub const Font = impl.Font;
pub const Glyph = impl.Glyph;
pub const Layout = impl.Layout;
pub const Line = impl.Line;
pub const Atlas = impl.Atlas;
pub const Sprite = impl.Sprite;
pub const subpixel_bins = impl.subpixel_bins;
pub const rich = impl.rich;

/// Carets, hits, selections and logical widths over any layout, in either
/// direction where the layout knows its clusters (`text_caret.zig`).
pub const caret = @import("text_caret.zig");

/// The ranges of x (left to right) bytes `a`..`b` of `s` cover on one line:
/// several in text of mixed directions where myzig lays text out, one
/// between the carets with CoreText. Returns how many were written to `out`.
pub fn selectionRanges(ts: *TextSystem, s: []const u8, style: @import("types.zig").TextStyle, a: usize, b: usize, out: [][2]f32) usize {
    if (portable) return ts.selectionRanges(s, style, a, b, out);
    if (a >= b or out.len == 0) return 0;
    const x0 = ts.caretX(s, style, a);
    const x1 = ts.caretX(s, style, b);
    out[0] = .{ @min(x0, x1), @max(x0, x1) };
    return 1;
}

/// Whether a paragraph reads right to left: its first strongly directional
/// character's way (UAX #9's P2, P3), left to right without one.
pub fn readsRtl(s: []const u8) bool {
    return @import("bidi.zig").firstStrong(s) orelse false;
}
