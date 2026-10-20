//! Text on Linux, with the libraries GTK's own text stack is made of, loaded
//! with dlopen (`text_hb_api.zig`): fontconfig finds the faces for a style
//! and for characters they lack (CJK, emoji, symbols: `text_fc.zig`), the
//! bidirectional algorithm (`bidi.zig`) orders a line's runs, HarfBuzz
//! shapes each run in its face (Arabic joining, Indic reordering,
//! ligatures, kerning, marks), and FreeType rasterizes glyphs, color ones
//! (Noto Color Emoji's bitmaps, COLR layers) in BGRA (`text_ft.zig`). Where
//! a library is missing, `create` fails and myzig's own reader lays text out.
const std = @import("std");
const api = @import("text_hb_api.zig");
const fcm = @import("text_fc.zig");
const engine = @import("text_engine.zig");
const bidi = @import("bidi.zig");
const classes = @import("bidi_class.zig");
const ftr = @import("text_ft.zig");
const utf8 = @import("utf8.zig");

const Piece = engine.Piece;

pub const Face = struct {
    path: [:0]u8,
    index: u32,
    blob: *api.HbBlob,
    hface: *api.HbFace,
    font: *api.HbFont,
    upem: f32,
    bold: bool,
    slant: bool,
    /// FreeType's face, opened when a glyph is first drawn.
    ft: ?*api.FaceRec = null,
    ft_tried: bool = false,

    pub fn has(f: *const Face, cp: u21) bool {
        var g: u32 = 0;
        return api.hb.hb_font_get_nominal_glyph(f.font, cp, &g) != 0 and g != 0;
    }
};

const StyleKey = struct { family: u64, weight: u16, italic: bool };
const FallbackKey = struct { cp: u21, weight: u16, italic: bool, emoji: bool };
const FaceKey = struct { path: u64, index: u32, bold: bool, slant: bool };

/// An hb_feature_t: a tag, its value, over the whole buffer.
const HbFeature = extern struct { tag: u32, value: u32, start: c_uint = 0, end: c_uint = std.math.maxInt(c_uint) };

pub const Engine = struct {
    gpa: std.mem.Allocator,
    config: ?*anyopaque,
    ft_lib: ?*anyopaque = null,
    buffer: *api.HbBuffer,
    faces: std.ArrayList(*Face) = .empty,
    by_file: std.AutoHashMapUnmanaged(FaceKey, usize) = .empty,
    styles: std.AutoHashMapUnmanaged(StyleKey, ?usize) = .empty,
    fallbacks: std.AutoHashMapUnmanaged(FallbackKey, ?usize) = .empty,
    names: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    levels: std.ArrayList(bidi.Run) = .empty,
    segs: std.ArrayList(Seg) = .empty,
    order: std.ArrayList(u32) = .empty,
    text: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    const Seg = struct { start: u32, end: u32, level: u8, face: usize, size: f32 };

    pub fn create(gpa: std.mem.Allocator) ?*Engine {
        if (!api.load()) return null;
        const cfg = api.fc.FcInitLoadConfigAndFonts() orelse return null;
        const buf = api.hb.hb_buffer_create() orelse {
            api.fc.FcConfigDestroy(cfg);
            return null;
        };
        const e = gpa.create(Engine) catch {
            api.hb.hb_buffer_destroy(buf);
            api.fc.FcConfigDestroy(cfg);
            return null;
        };
        e.* = .{ .gpa = gpa, .config = cfg, .buffer = buf };
        if (api.ft.FT_Init_FreeType(&e.ft_lib) != 0) e.ft_lib = null;
        return e;
    }

    pub fn destroy(e: *Engine) void {
        const gpa = e.gpa;
        for (e.faces.items) |f| {
            if (f.ft) |ft| _ = api.ft.FT_Done_Face(ft);
            api.hb.hb_font_destroy(f.font);
            api.hb.hb_face_destroy(f.hface);
            api.hb.hb_blob_destroy(f.blob);
            gpa.free(f.path);
            gpa.destroy(f);
        }
        e.faces.deinit(gpa);
        e.by_file.deinit(gpa);
        e.styles.deinit(gpa);
        e.fallbacks.deinit(gpa);
        e.names.deinit(gpa);
        e.levels.deinit(gpa);
        e.segs.deinit(gpa);
        e.order.deinit(gpa);
        e.text.deinit(gpa);
        e.scratch.deinit(gpa);
        if (e.ft_lib) |l| _ = api.ft.FT_Done_FreeType(l);
        api.hb.hb_buffer_destroy(e.buffer);
        if (e.config) |c| api.fc.FcConfigDestroy(c);
        gpa.destroy(e);
    }

    pub fn faceAt(e: *Engine, handle: usize) *Face {
        return e.faces.items[handle];
    }

    /// The face of a match (opened once per file, face and synthesis).
    fn open(e: *Engine, m: fcm.Match, weight: u16, italic: bool) ?usize {
        const key: FaceKey = .{ .path = std.hash.Wyhash.hash(0, m.path), .index = m.index, .bold = fcm.needsBold(m, weight), .slant = fcm.needsSlant(m, italic) };
        if (e.by_file.get(key)) |h| {
            e.gpa.free(m.path);
            return h;
        }
        const hb = &api.hb;
        const blob = hb.hb_blob_create_from_file(m.path.ptr) orelse return e.dropPath(m.path);
        const hface = hb.hb_face_create(blob, m.index) orelse {
            hb.hb_blob_destroy(blob);
            return e.dropPath(m.path);
        };
        const upem = hb.hb_face_get_upem(hface);
        const hfont = hb.hb_font_create(hface) orelse {
            hb.hb_face_destroy(hface);
            hb.hb_blob_destroy(blob);
            return e.dropPath(m.path);
        };
        // Positions in font units, scaled to sizes by the engine.
        hb.hb_font_set_scale(hfont, @intCast(upem), @intCast(upem));
        const f = e.gpa.create(Face) catch return e.dropPath(m.path);
        f.* = .{ .path = m.path, .index = m.index, .blob = blob, .hface = hface, .font = hfont, .upem = @floatFromInt(@max(upem, 1)), .bold = key.bold, .slant = key.slant };
        e.faces.append(e.gpa, f) catch {
            e.gpa.destroy(f);
            return e.dropPath(m.path);
        };
        const h = e.faces.items.len - 1;
        e.by_file.put(e.gpa, key, h) catch {};
        return h;
    }

    fn dropPath(e: *Engine, path: [:0]u8) ?usize {
        e.gpa.free(path);
        return null;
    }

    fn generic(family: ?[]const u8, mono: bool) []const u8 {
        return family orelse if (mono) "monospace" else "sans-serif";
    }

    /// The face a style's characters are drawn in when it has them.
    pub fn face(e: *Engine, family: ?[]const u8, mono: bool, weight: u16, italic: bool) ?usize {
        var fam = generic(family, mono);
        if (family != null and !e.hasFamilyNamed(fam)) fam = generic(null, mono);
        const key: StyleKey = .{ .family = std.hash.Wyhash.hash(@intFromBool(mono), fam), .weight = weight, .italic = italic };
        if (e.styles.get(key)) |h| return h;
        const m = fcm.match(e.gpa, e.config, .{ .family = fam, .weight = weight, .italic = italic });
        const h = if (m) |mm| e.open(mm, weight, italic) else null;
        e.styles.put(e.gpa, key, h) catch {};
        return h;
    }

    pub fn hasFamilyNamed(e: *Engine, name: []const u8) bool {
        const key = std.hash.Wyhash.hash(7, name);
        if (e.names.get(key)) |v| return v;
        var ok = false;
        if (fcm.match(e.gpa, e.config, .{ .family = name, .weight = 400, .italic = false })) |m| {
            ok = std.ascii.eqlIgnoreCase(m.familyName(), name);
            e.gpa.free(m.path);
        }
        e.names.put(e.gpa, key, ok) catch {};
        return ok;
    }

    /// A face that has `cp`, for text its style's face lacks.
    fn fallback(e: *Engine, cp: u21, weight: u16, italic: bool, emoji: bool) ?usize {
        const key: FallbackKey = .{ .cp = cp, .weight = weight, .italic = italic, .emoji = emoji };
        if (e.fallbacks.get(key)) |h| return h;
        var h: ?usize = null;
        if (emoji) if (fcm.match(e.gpa, e.config, .{ .family = "emoji", .weight = 400, .italic = false, .char = cp, .color = true })) |m| {
            h = e.open(m, 400, false);
        };
        if (h == null) if (fcm.match(e.gpa, e.config, .{ .family = "sans-serif", .weight = weight, .italic = italic, .char = cp })) |m| {
            h = e.open(m, weight, italic);
        };
        if (h) |x| if (!e.faces.items[x].has(cp)) {
            h = null;
        };
        e.fallbacks.put(e.gpa, key, h) catch {};
        return h;
    }

    pub fn metrics(e: *Engine, f: usize, size: f32) engine.Metrics {
        const fc = e.faces.items[f];
        var x: api.FontExtents = std.mem.zeroes(api.FontExtents);
        _ = api.hb.hb_font_get_h_extents(fc.font, &x);
        const k = size / fc.upem;
        return .{ .ascent = @as(f32, @floatFromInt(x.ascender)) * k, .descent = @as(f32, @floatFromInt(-x.descender)) * k, .leading = @as(f32, @floatFromInt(@max(0, x.line_gap))) * k };
    }

    pub fn isColor(e: *Engine, f: usize) bool {
        const ft = ftr.ftFace(e, f) orelse return false;
        return ft.face_flags & api.face_flag_color != 0;
    }

    pub const rasterize = ftr.rasterize;

    pub fn glyphIndex(e: *Engine, f: usize, cp: u21) u16 {
        var g: u32 = 0;
        _ = api.hb.hb_font_get_nominal_glyph(e.faces.items[f].font, cp, &g);
        return @truncate(g);
    }

    /// The face for each character of `s` in its piece: the piece's when it
    /// has it, else a fallback; marks, joiners, selectors and modifiers stay
    /// with what they follow, and emoji go to a color font.
    fn itemize(e: *Engine, s: []const u8, pieces: []const Piece) !void {
        e.segs.clearRetainingCapacity();
        var li: usize = 0;
        for (pieces) |p| {
            const primary = e.face(p.family, p.mono, p.weight, p.italic) orelse return error.NoFace;
            var prev: ?usize = null;
            var i: usize = p.start;
            while (i < p.end) {
                const n = @min(utf8.seqLen(s[i]), p.end - i);
                const cp: u21 = std.unicode.utf8Decode(s[i .. i + n]) catch 0xfffd;
                const next: u21 = if (i + n < p.end) blk: {
                    const m = @min(utf8.seqLen(s[i + n]), p.end - i - n);
                    break :blk std.unicode.utf8Decode(s[i + n .. i + n + m]) catch 0;
                } else 0;
                const pf = e.faces.items;
                const f: usize = blk: {
                    if (prev) |pv| if (continues(cp) or (neutral(cp) and pf[pv].has(cp))) break :blk pv;
                    const emoji = isEmoji(cp, next);
                    if (!emoji and pf[primary].has(cp)) break :blk primary;
                    if (cp < 0x20 or cp == 0x7f) break :blk prev orelse primary;
                    if (e.fallback(cp, p.weight, p.italic, emoji)) |fb| break :blk fb;
                    break :blk if (pf[primary].has(cp)) primary else (prev orelse primary);
                };
                prev = f;
                while (li + 1 < e.levels.items.len and e.levels.items[li].end <= i) li += 1;
                const level = e.levels.items[li].level;
                const last = if (e.segs.items.len > 0) &e.segs.items[e.segs.items.len - 1] else null;
                if (last != null and last.?.end == i and last.?.face == f and last.?.level == level and last.?.size == p.size and i != p.start) {
                    last.?.end = @intCast(i + n);
                } else try e.segs.append(e.gpa, .{ .start = @intCast(i), .end = @intCast(i + n), .level = level, .face = f, .size = p.size });
                i += n;
            }
        }
    }

    /// Shapes `s` (one line) in its pieces' styles into `sink`, its runs in
    /// visual order; false when it could not.
    pub fn shape(e: *Engine, s: []const u8, pieces: []const Piece, rtl: bool, sink: *engine.Sink) bool {
        if (s.len == 0 or pieces.len == 0) return true;
        e.levels.clearRetainingCapacity();
        if (rtl or bidi.mayHaveRtl(s)) {
            _ = bidi.resolve(e.gpa, s, if (rtl) 1 else 0, &e.levels) catch return false;
        } else e.levels.append(e.gpa, .{ .start = 0, .end = @intCast(s.len), .level = 0 }) catch return false;
        if (e.levels.items.len == 0) return true;
        e.itemize(s, pieces) catch return false;
        // Tabs shaped as spaces, other controls as spaces of no width.
        e.text.resize(e.gpa, s.len) catch return false;
        for (s, e.text.items) |c, *o| o.* = if (c < 0x20 or c == 0x7f) ' ' else c;
        const segs = e.segs.items;
        e.order.resize(e.gpa, segs.len) catch return false;
        var lv: [64]bidi.Run = undefined;
        const as_runs: []bidi.Run = if (segs.len <= lv.len) lv[0..segs.len] else (e.gpa.alloc(bidi.Run, segs.len) catch return false);
        defer if (segs.len > lv.len) e.gpa.free(as_runs);
        for (segs, as_runs) |sg, *r| r.* = .{ .start = sg.start, .end = sg.end, .level = sg.level };
        bidi.visual(as_runs, e.order.items);
        const hb = &api.hb;
        for (e.order.items, 0..) |si, vi| {
            const sg = segs[si];
            const f = e.faces.items[sg.face];
            hb.hb_buffer_clear_contents(e.buffer);
            hb.hb_buffer_add_utf8(e.buffer, e.text.items.ptr, @intCast(s.len), sg.start, @intCast(sg.end - sg.start));
            hb.hb_buffer_set_direction(e.buffer, if (sg.level & 1 != 0) api.hb_direction_rtl else api.hb_direction_ltr);
            hb.hb_buffer_guess_segment_properties(e.buffer);
            // The OpenType features of the piece the segment is in.
            var feats: [16]HbFeature = undefined;
            var nf: usize = 0;
            for (pieces) |p| if (sg.start >= p.start and sg.start < p.end) {
                var list: [16]engine.Feature = undefined;
                for (list[0..engine.parseFeatures(p.features, &list)]) |ft| {
                    feats[nf] = .{ .tag = std.mem.readInt(u32, &ft.tag, .big), .value = ft.value };
                    nf += 1;
                }
                break;
            };
            hb.hb_shape(f.font, e.buffer, if (nf > 0) @ptrCast(&feats) else null, @intCast(nf));
            var n: c_uint = 0;
            const infos = hb.hb_buffer_get_glyph_infos(e.buffer, &n);
            const pos = hb.hb_buffer_get_glyph_positions(e.buffer, null);
            const k = sg.size / f.upem;
            sink.begin(sg.face, sg.size, sg.level, sg.start, sg.end, @floatFromInt(vi)) catch return false;
            for (infos[0..n], pos[0..n]) |gi, gp| {
                const c = s[@min(gi.cluster, s.len - 1)];
                const mult: f32 = if (c == '\t') 4 else if (c < 0x20 or c == 0x7f) 0 else 1;
                sink.glyph(.{
                    .id = @truncate(gi.codepoint),
                    .advance = @as(f32, @floatFromInt(gp.x_advance)) * k * mult,
                    .dx = @as(f32, @floatFromInt(gp.x_offset)) * k,
                    .dy = @as(f32, @floatFromInt(gp.y_offset)) * k,
                    .cluster = gi.cluster,
                }) catch return false;
            }
        }
        sink.sortVisual();
        return true;
    }
};

/// Characters that belong with the one before them: marks, joiners,
/// variation selectors, emoji modifiers and tags, keycaps.
fn continues(cp: u21) bool {
    return classes.of(cp) == .NSM or cp == 0x200d or cp == 0x200c or (cp >= 0xfe00 and cp <= 0xfe0f) or
        (cp >= 0x1f3fb and cp <= 0x1f3ff) or (cp >= 0xe0020 and cp <= 0xe007f) or cp == 0x20e3;
}

/// Spaces and punctuation, which stay in the face before them when it has them.
fn neutral(cp: u21) bool {
    return switch (classes.of(cp)) {
        .WS, .CS, .ON, .ES, .ET => cp < 0x2190 or (cp >= 0x3000 and cp <= 0x303f),
        else => false,
    };
}

/// Characters shown as emoji: pictographs, and symbols asked to be (U+FE0F).
fn isEmoji(cp: u21, next: u21) bool {
    if (next == 0xfe0f) return true;
    return (cp >= 0x1f000 and cp <= 0x1faff and !(cp >= 0x1f100 and cp <= 0x1f1e5)) or (cp >= 0x1f1e6 and cp <= 0x1f1ff);
}
