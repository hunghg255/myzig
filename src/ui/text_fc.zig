//! Fonts on Linux as fontconfig finds them, as Pango does: the face of a
//! family (or of the system's "sans-serif" and "monospace") nearest a
//! weight and slant, and the face that has a character the others lack,
//! with the system's preferences for each script and for emoji (a color
//! font first).
const std = @import("std");
const api = @import("text_hb_api.zig");

pub const Match = struct {
    /// The file, NUL-terminated, the caller's.
    path: [:0]u8,
    index: u32,
    weight: c_int,
    slant: c_int,
    family: [64]u8 = undefined,
    family_len: usize = 0,

    pub fn familyName(m: *const Match) []const u8 {
        return m.family[0..m.family_len];
    }
};

pub const Query = struct {
    family: []const u8,
    weight: u16,
    italic: bool,
    /// A character the face must have.
    char: ?u21 = null,
    /// Prefer a color font (emoji).
    color: bool = false,
};

fn fcWeight(w: u16) c_int {
    if (w >= 700) return api.fc_weight_bold;
    if (w >= 600) return api.fc_weight_demibold;
    if (w >= 500) return api.fc_weight_medium;
    return api.fc_weight_regular;
}

/// The face fontconfig picks for `q`, null if none.
pub fn match(gpa: std.mem.Allocator, cfg: ?*anyopaque, q: Query) ?Match {
    const fc = &api.fc;
    const p = fc.FcPatternCreate() orelse return null;
    defer fc.FcPatternDestroy(p);
    var name: [128]u8 = undefined;
    if (q.family.len >= name.len) return null;
    @memcpy(name[0..q.family.len], q.family);
    name[q.family.len] = 0;
    _ = fc.FcPatternAddString(p, "family", name[0..q.family.len :0]);
    _ = fc.FcPatternAddInteger(p, "weight", fcWeight(q.weight));
    _ = fc.FcPatternAddInteger(p, "slant", if (q.italic) api.fc_slant_italic else api.fc_slant_roman);
    if (q.color) _ = fc.FcPatternAddBool(p, "color", 1);
    var cs: ?*api.FcCharSet = null;
    defer if (cs) |c| fc.FcCharSetDestroy(c);
    if (q.char) |cp| {
        cs = fc.FcCharSetCreate();
        if (cs) |c| {
            _ = fc.FcCharSetAddChar(c, cp);
            _ = fc.FcPatternAddCharSet(p, "charset", c);
        }
    }
    _ = fc.FcConfigSubstitute(cfg, p, api.fc_match_pattern);
    fc.FcDefaultSubstitute(p);
    var result: c_int = 0;
    const m = fc.FcFontMatch(cfg, p, &result) orelse return null;
    defer fc.FcPatternDestroy(m);
    if (result != api.fc_result_match) return null;
    if (q.char) |cp| {
        var got: ?*api.FcCharSet = null;
        if (fc.FcPatternGetCharSet(m, "charset", 0, &got) != api.fc_result_match or got == null or fc.FcCharSetHasChar(got.?, cp) == 0) return null;
    }
    var file: ?[*:0]const u8 = null;
    if (fc.FcPatternGetString(m, "file", 0, &file) != api.fc_result_match or file == null) return null;
    var out: Match = .{ .path = undefined, .index = 0, .weight = api.fc_weight_regular, .slant = api.fc_slant_roman };
    var index: c_int = 0;
    if (fc.FcPatternGetInteger(m, "index", 0, &index) == api.fc_result_match) out.index = @intCast(@max(0, index) & 0xffff);
    _ = fc.FcPatternGetInteger(m, "weight", 0, &out.weight);
    _ = fc.FcPatternGetInteger(m, "slant", 0, &out.slant);
    var fam: ?[*:0]const u8 = null;
    if (fc.FcPatternGetString(m, "family", 0, &fam) == api.fc_result_match) if (fam) |f| {
        const s = std.mem.span(f);
        out.family_len = @min(s.len, out.family.len);
        @memcpy(out.family[0..out.family_len], s[0..out.family_len]);
    };
    const path = std.mem.span(file.?);
    const owned = gpa.allocSentinel(u8, path.len, 0) catch return null;
    @memcpy(owned, path);
    out.path = owned;
    return out;
}

/// Whether the matched face is a weight bolder than asked lacks
/// (fontconfig's own rule for synthesized bold).
pub fn needsBold(m: Match, weight: u16) bool {
    return weight >= 600 and m.weight < api.fc_weight_demibold;
}

pub fn needsSlant(m: Match, italic: bool) bool {
    return italic and m.slant == api.fc_slant_roman;
}
