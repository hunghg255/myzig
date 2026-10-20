//! Text where myzig lays it out (Linux, Windows, and macOS built with
//! `-Dportable=true`): through the system's text engine where there is one
//! (DirectWrite on Windows, `text_dw.zig`; HarfBuzz, FreeType and
//! fontconfig on Linux, `text_hb.zig`), which shape every script, order
//! mixed directions, fall back to the system's fonts for CJK and emoji and
//! rasterize color glyphs; else with myzig's own TrueType reader
//! (`tt/fontdb.zig`, `text_ttshape.zig`). Simple text takes a fast path
//! learned from the engine (`text_simple.zig`). Lines are cached, wrapped
//! greedily at spaces, and give carets, hit testing and selections in
//! either direction (`text_caret.zig`). The same interface as `text_mac.zig`.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const fontdb = @import("tt/fontdb.zig");
const atlas_mod = @import("atlas_tt.zig");
const runs = @import("text_runs.zig");
const caret = @import("text_caret.zig");
const engine = @import("text_engine.zig");
const simple = @import("text_simple.zig");
const bidi = @import("bidi.zig");
const ttshape = @import("text_ttshape.zig");
const wrapping = @import("text_wrap.zig");
pub const rich = @import("rich_tt.zig");

pub const Atlas = atlas_mod.Atlas;
pub const Sprite = atlas_mod.Sprite;
pub const subpixel_bins = atlas_mod.subpixel_bins;
pub const Glyph = runs.Glyph;
pub const Layout = runs.Layout;
pub const Line = runs.Line;
pub const Cluster = runs.Cluster;
pub const Styled = ttshape.Styled;

/// The system's text engine, where myzig has one.
pub const Engine = switch (builtin.os.tag) {
    .windows => @import("text_dw.zig").Engine,
    .linux => @import("text_hb.zig").Engine,
    else => void,
};
const has_engine = Engine != void;

pub const Font = struct {
    ascent: f32,
    descent: f32,
    leading: f32,
    /// The run font of its face at its size.
    id: u16,
    weight: u16,

    pub fn lineHeight(f: Font) f32 {
        return @ceil(f.ascent + f.descent + f.leading);
    }
};

const FontKey = struct { size_bits: u32, weight: u16, mono: bool, italic: bool, family: u64 };

fn fontKey(style: types.TextStyle) FontKey {
    return .{
        .size_bits = @bitCast(style.size),
        .weight = styleWeight(style),
        .mono = style.mono,
        .italic = style.italic,
        .family = if (style.family) |f| std.hash.Wyhash.hash(1, f) else 0,
    };
}

/// A style's weight, 100 to 900.
pub fn styleWeight(style: types.TextStyle) u16 {
    return if (style.weight_value != 0) std.math.clamp(style.weight_value, 100, 900) else weightOf(style.weight);
}

pub fn weightOf(w: types.Weight) u16 {
    return switch (w) {
        .regular => 400,
        .medium => 500,
        .semibold => 600,
        .bold => 700,
    };
}

/// A face at a size, as glyphs refer to it: one myzig reads, or the engine's.
const RunFont = union(enum) {
    tt: struct { rf: atlas_mod.RunFont, face: u32 },
    native: Native,
};

const Native = struct { face: usize, size: f32, color: bool };

const ColorKey = struct { font: u16, glyph: u16, bin: u8 };

/// Run fonts kept at most: past it, a frame starts them over, as sizes
/// that change all the time (a zoom slider) would add one a frame.
pub const max_run_fonts = 256;

pub const Options = struct {
    /// Use the system's text engine where there is one.
    native: bool = true,
};

pub const TextSystem = struct {
    gpa: std.mem.Allocator,
    db: fontdb.Db,
    atlas: Atlas,
    /// The pictures shown (`ui.image`), and color glyphs.
    images: @import("images.zig").Images,
    scale: f32 = 2,
    fonts: std.AutoHashMapUnmanaged(FontKey, Font) = .empty,
    run_fonts: std.ArrayList(RunFont) = .empty,
    /// Bumped when the run fonts start over: glyphs laid out before name
    /// fonts by ids that are others' now (`textlayout_long.zig` checks).
    epoch: u32 = 0,
    layouts: std.AutoHashMapUnmanaged(u64, Layout) = .empty,
    previous: std.AutoHashMapUnmanaged(u64, Layout) = .empty,
    wraps: std.AutoHashMapUnmanaged(u64, []Line) = .empty,
    family: ?[]const u8 = null,
    mono_family: ?[]const u8 = null,
    /// Every size times this (`Context.setZoom`).
    zoom: f32 = 1,
    engine: if (has_engine) ?*Engine else void = if (has_engine) null else {},
    sink: engine.Sink,
    short_sink: engine.Sink,
    /// The fast path's tables, by run font.
    tables: std.AutoHashMapUnmanaged(u16, *simple.Table) = .empty,
    colors: std.AutoHashMapUnmanaged(ColorKey, void) = .empty,
    shaped: std.ArrayList(runs.Run) = .empty,
    /// Lines the engine has shaped, as tests count them.
    engine_lines: usize = 0,

    pub fn init(gpa: std.mem.Allocator) TextSystem {
        return initWith(gpa, .{});
    }

    pub fn initWith(gpa: std.mem.Allocator, opts: Options) TextSystem {
        var ts: TextSystem = .{
            .gpa = gpa,
            .db = .init(gpa, std.Io.Threaded.global_single_threaded.io()),
            .atlas = .init(gpa),
            .images = .{ .gpa = gpa },
            .sink = .{ .gpa = gpa },
            .short_sink = .{ .gpa = gpa },
        };
        if (has_engine and opts.native) ts.engine = Engine.create(gpa);
        return ts;
    }

    pub fn deinit(self: *TextSystem) void {
        self.images.deinit();
        self.fonts.deinit(self.gpa);
        self.run_fonts.deinit(self.gpa);
        freeLayouts(self.gpa, &self.layouts);
        freeLayouts(self.gpa, &self.previous);
        self.layouts.deinit(self.gpa);
        self.previous.deinit(self.gpa);
        self.clearWraps();
        self.wraps.deinit(self.gpa);
        self.freeTables();
        self.tables.deinit(self.gpa);
        self.colors.deinit(self.gpa);
        self.shaped.deinit(self.gpa);
        self.sink.deinit();
        self.short_sink.deinit();
        if (has_engine) if (self.engine) |e| e.destroy();
        self.atlas.deinit();
        self.db.deinit();
    }

    /// Whether the system's engine lays text out (not myzig's own reader).
    pub fn native(self: *const TextSystem) bool {
        return has_engine and self.engine != null;
    }

    pub fn setScale(self: *TextSystem, scale: f32) void {
        self.scale = scale;
        self.atlas.setScale(scale);
    }

    pub fn setFamilies(self: *TextSystem, family: ?[]const u8, mono_family: ?[]const u8) void {
        const same = struct {
            fn f(a: ?[]const u8, b: ?[]const u8) bool {
                if (a == null or b == null) return a == null and b == null;
                return std.mem.eql(u8, a.?, b.?);
            }
        }.f;
        if (same(self.family, family) and same(self.mono_family, mono_family)) return;
        self.family = family;
        self.mono_family = mono_family;
        self.dropCaches();
    }

    fn dropCaches(self: *TextSystem) void {
        self.fonts.clearRetainingCapacity();
        freeLayouts(self.gpa, &self.layouts);
        freeLayouts(self.gpa, &self.previous);
        self.clearWraps();
    }

    /// Scales every text by `z`: a change drops every cached font, shaping and wrap.
    pub fn setZoom(self: *TextSystem, z: f32) void {
        if (z == self.zoom) return;
        self.zoom = z;
        self.dropCaches();
    }

    pub fn lineHeight(self: *TextSystem, style: types.TextStyle) f32 {
        const lh = self.font(style).lineHeight();
        return if (style.leading == 1) lh else @ceil(lh * style.leading);
    }

    pub fn beginFrame(self: *TextSystem) void {
        self.atlas.reset_during_frame = false;
        if (self.run_fonts.items.len > max_run_fonts) self.dropFonts();
        freeLayouts(self.gpa, &self.previous);
        std.mem.swap(std.AutoHashMapUnmanaged(u64, Layout), &self.layouts, &self.previous);
    }

    /// Lets go of every run font and what is kept by their ids: fonts,
    /// shapes, the fast path's tables, color glyphs and the glyph atlas.
    fn dropFonts(self: *TextSystem) void {
        self.dropCaches();
        self.freeTables();
        var it = self.colors.keyIterator();
        while (it.next()) |k| self.images.remove(pictureKey(.{ .font = k.font, .glyph = k.glyph, .x = 0, .y = 0 }, k.bin));
        self.colors.clearRetainingCapacity();
        self.run_fonts.clearRetainingCapacity();
        self.atlas.reset();
        if (has_engine) if (self.engine) |e| if (@hasDecl(Engine, "dropFormats")) e.dropFormats();
        self.epoch +%= 1;
    }

    fn freeTables(self: *TextSystem) void {
        var it = self.tables.valueIterator();
        while (it.next()) |t| {
            t.*.deinit(self.gpa);
            self.gpa.destroy(t.*);
        }
        self.tables.clearRetainingCapacity();
    }

    fn freeLayouts(gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u64, Layout)) void {
        var it = map.valueIterator();
        while (it.next()) |l| l.free(gpa);
        map.clearRetainingCapacity();
    }

    /// The run font of tt face `face` at `size`, slanted when italics were
    /// asked of an upright face, thickened for a weight it lacks.
    fn ttRunFont(self: *TextSystem, face: u32, size: f32, slant: bool, weight: u16) u16 {
        const f = self.db.load(face) orelse return 0xffff;
        const skew: f32 = if (slant and !f.style.italic) 0.2 else 0;
        const embolden: f32 = if (weight >= 600 and f.style.weight < 550) (if (weight >= 700) 0.045 else 0.03) else 0;
        for (self.run_fonts.items, 0..) |rf, i| switch (rf) {
            .tt => |t| if (t.face == face and t.rf.size == size and t.rf.skew == skew and t.rf.embolden == embolden) return @intCast(i),
            .native => {},
        };
        return self.addRunFont(.{ .tt = .{ .rf = .{ .font = f, .size = size, .skew = skew, .embolden = embolden }, .face = face } });
    }

    /// The run font of an engine's face at `size`.
    pub fn nativeRunFont(self: *TextSystem, face: usize, size: f32) u16 {
        for (self.run_fonts.items, 0..) |rf, i| switch (rf) {
            .native => |n| if (n.face == face and n.size == size) return @intCast(i),
            .tt => {},
        };
        const color = if (has_engine) (if (self.engine) |e| e.isColor(face) else false) else false;
        return self.addRunFont(.{ .native = .{ .face = face, .size = size, .color = color } });
    }

    fn addRunFont(self: *TextSystem, rf: RunFont) u16 {
        if (self.run_fonts.items.len >= 0xfffe) return 0xffff;
        self.run_fonts.append(self.gpa, rf) catch return 0xffff;
        return @intCast(self.run_fonts.items.len - 1);
    }

    pub fn isTT(self: *const TextSystem, id: u16) bool {
        return id < self.run_fonts.items.len and self.run_fonts.items[id] == .tt;
    }

    pub fn ttFont(self: *const TextSystem, id: u16) atlas_mod.RunFont {
        return self.run_fonts.items[id].tt.rf;
    }

    /// The tt glyph of `cp` in font `f`, or in a fallback face that has it.
    pub fn ttGlyph(self: *TextSystem, f: Font, style: types.TextStyle, cp: u21) struct { id: u16, g: u16 } {
        const rf = self.ttFont(f.id);
        const g = rf.font.glyphIndex(if (cp == '\t') ' ' else cp);
        if (g == 0 and cp >= 0x20) if (self.db.fallback(cp, f.weight)) |face| {
            const fid = self.ttRunFont(face, style.size * self.zoom, style.italic, f.weight);
            if (fid != 0xffff) return .{ .id = fid, .g = self.ttFont(fid).font.glyphIndex(cp) };
        };
        return .{ .id = f.id, .g = g };
    }

    fn familyOf(self: *const TextSystem, style: types.TextStyle) ?[]const u8 {
        if (style.family) |f| return f;
        return if (style.mono) self.mono_family else self.family;
    }

    pub fn font(self: *TextSystem, style: types.TextStyle) Font {
        const fk = fontKey(style);
        if (self.fonts.get(fk)) |f| return f;
        const weight = styleWeight(style);
        const size = style.size * self.zoom;
        var f: Font = .{ .ascent = size * 0.8, .descent = size * 0.2, .leading = 0, .id = 0xffff, .weight = weight };
        if (has_engine) if (self.engine) |e| {
            if (e.face(self.familyOf(style), style.mono, weight, style.italic)) |face| {
                const m = e.metrics(face, size);
                f = .{ .ascent = m.ascent, .descent = m.descent, .leading = m.leading, .id = self.nativeRunFont(face, size), .weight = weight };
                self.fonts.put(self.gpa, fk, f) catch {};
                return f;
            }
        };
        const face = self.db.match(self.familyOf(style), weight, style.italic, style.mono);
        if (face) |fc| if (self.db.load(fc)) |tf| {
            const k = size / tf.units_per_em;
            f = .{ .ascent = tf.ascent * k, .descent = tf.descent * k, .leading = tf.line_gap * k, .id = self.ttRunFont(fc, size, style.italic, weight), .weight = weight };
        };
        self.fonts.put(self.gpa, fk, f) catch {};
        return f;
    }

    pub fn key(s: []const u8, style: types.TextStyle, extra: u64) u64 {
        var h = std.hash.Wyhash.init(extra);
        h.update(s);
        h.update(std.mem.asBytes(&style.size));
        h.update(&.{ @intFromEnum(style.weight), @intFromBool(style.mono), @intFromBool(style.italic) });
        h.update(std.mem.asBytes(&style.weight_value));
        h.update(style.family orelse "\x00");
        h.update(style.features);
        return h.final();
    }

    pub fn layout(self: *TextSystem, s: []const u8, style: types.TextStyle) Layout {
        if (s.len == 0) return .{ .width = 0, .glyphs = &.{} };
        const k = key(s, style, 1);
        if (self.cached(k)) |l| return l;
        const pieces = [_]Styled{.{ .start = 0, .end = @intCast(s.len), .style = style }};
        return self.keep(k, self.shapeLine(s, &pieces) catch .{ .width = 0, .glyphs = &.{} });
    }

    pub fn cached(self: *TextSystem, k: u64) ?Layout {
        if (self.layouts.get(k)) |l| return l;
        if (self.previous.fetchRemove(k)) |kv| {
            self.layouts.put(self.gpa, k, kv.value) catch {};
            return kv.value;
        }
        return null;
    }

    pub fn keep(self: *TextSystem, k: u64, l: Layout) Layout {
        self.layouts.put(self.gpa, k, l) catch {
            l.free(self.gpa);
            return .{ .width = l.width, .glyphs = &.{} };
        };
        return l;
    }

    /// `s` laid out on one line in its pieces' styles (which cover it, in
    /// order); owned by the caller.
    pub fn shapeLine(self: *TextSystem, s: []const u8, pieces: []const Styled) !Layout {
        const rtl = bidi.mayHaveRtl(s);
        if (has_engine) if (self.engine) |e| {
            if (pieces.len == 1 and !rtl and pieces[0].style.features.len == 0) if (self.table(pieces[0].style)) |t| {
                if (t.layout(self.gpa, Short{ .ts = self, .style = pieces[0].style }, s)) |l| return l;
            };
            if (try self.engineLine(e, &self.sink, s, pieces, rtl)) |l| return l;
        };
        if (!rtl) {
            var glyphs: std.ArrayList(Glyph) = .empty;
            errdefer glyphs.deinit(self.gpa);
            var x: f32 = 0;
            for (pieces) |p| x = try ttshape.shapeInto(self, &glyphs, s[p.start..p.end], p.style, x, p.start);
            return .{ .width = x, .glyphs = try glyphs.toOwnedSlice(self.gpa) };
        }
        self.sink.reset();
        if (!try ttshape.shapeBidi(self, s, pieces, &self.sink)) return .{ .width = 0, .glyphs = &.{} };
        return self.fromSink(&self.sink, bidi.firstStrong(s) orelse false, false);
    }

    fn engineLine(self: *TextSystem, e: anytype, sink: *engine.Sink, s: []const u8, pieces: []const Styled, rtl: bool) !?Layout {
        var buf: [16]engine.Piece = undefined;
        var list: std.ArrayList(engine.Piece) = .initBuffer(&buf);
        var heap: std.ArrayList(engine.Piece) = .empty;
        defer heap.deinit(self.gpa);
        for (pieces) |p| {
            const ep: engine.Piece = .{ .start = p.start, .end = p.end, .family = self.familyOf(p.style), .mono = p.style.mono, .weight = styleWeight(p.style), .italic = p.style.italic, .size = p.style.size * self.zoom, .features = p.style.features };
            if (list.items.len < buf.len) list.appendAssumeCapacity(ep) else try heap.append(self.gpa, ep);
        }
        if (heap.items.len > 0) try heap.insertSlice(self.gpa, 0, list.items);
        sink.reset();
        self.engine_lines += 1;
        const para_rtl = rtl and (bidi.firstStrong(s) orelse false);
        if (!e.shape(s, if (heap.items.len > 0) heap.items else list.items, para_rtl, sink)) return null;
        for (sink.runs.items) |*r| {
            r.face = self.nativeRunFont(r.face, r.size);
            r.size = 0;
        }
        // Clusters always: a ligature's carets are inside it.
        return try self.fromSink(sink, para_rtl, true);
    }

    /// `s` laid out by the engine `e` itself, never by the fast path, as
    /// tests compare them; owned by the caller.
    pub fn engineLineForTest(self: *TextSystem, s: []const u8, pieces: []const Styled) !?Layout {
        if (has_engine) {
            return self.engineLine(self.engine orelse return null, &self.short_sink, s, pieces, bidi.mayHaveRtl(s));
        } else return null;
    }

    /// The layout of a sink's runs (faces are run fonts by then).
    fn fromSink(self: *TextSystem, sink: *engine.Sink, para_rtl: bool, clusters: bool) !Layout {
        self.shaped.clearRetainingCapacity();
        for (sink.runs.items) |r| try self.shaped.append(self.gpa, .{ .font = @intCast(r.face), .level = r.level, .start = r.start, .end = r.end, .glyphs = sink.glyphsOf(r) });
        return runs.build(self.gpa, self.shaped.items, 0, para_rtl, clusters);
    }

    fn table(self: *TextSystem, style: types.TextStyle) ?*simple.Table {
        const f = self.font(style);
        if (f.id == 0xffff or self.isTT(f.id)) return null;
        if (self.tables.get(f.id)) |t| return t;
        const t = self.gpa.create(simple.Table) catch return null;
        t.* = .{ .font = f.id };
        self.tables.put(self.gpa, f.id, t) catch {
            self.gpa.destroy(t);
            return null;
        };
        return t;
    }

    /// What the fast path asks the engine: one or two characters shaped.
    const Short = struct {
        ts: *TextSystem,
        style: types.TextStyle,

        pub fn short(sh: Short, s: []const u8) simple.Short {
            const ts = sh.ts;
            if (!has_engine) return .{} else return sh.shortNative(ts.engine orelse return .{}, s);
        }

        fn shortNative(sh: Short, e: anytype, s: []const u8) simple.Short {
            const ts = sh.ts;
            const pieces = [_]Styled{.{ .start = 0, .end = @intCast(s.len), .style = sh.style }};
            const l = (ts.engineLine(e, &ts.short_sink, s, &pieces, false) catch return .{}) orelse return .{};
            defer l.free(ts.gpa);
            var out: simple.Short = .{ .n = l.glyphs.len, .width = l.width };
            if (l.glyphs.len == 0 or l.glyphs.len > 2) return out;
            out.font = l.glyphs[0].font;
            for (l.glyphs, 0..) |g, i| {
                out.glyphs[i] = g.glyph;
                out.x[i] = g.x;
                if (g.font != out.font or g.y != 0) out.one_font = false;
            }
            return out;
        }
    };

    pub fn glyph(self: *TextSystem, g: Glyph, bin: u8) ?Sprite {
        if (g.font >= self.run_fonts.items.len) return null;
        switch (self.run_fonts.items[g.font]) {
            .tt => |t| return self.atlas.glyph(g.font, t.rf, g.glyph, bin),
            .native => |n| {
                if (self.atlas.cached(g.font, g.glyph, bin)) |sp| {
                    if (sp == null or !n.color) return sp;
                    return self.withPicture(g, bin, n, sp.?);
                }
                var bmp: engine.Bitmap = .{};
                const ok = self.rasterize(n, g.glyph, bin, &bmp);
                const sp = self.atlas.put(g.font, g.glyph, bin, if (ok) bmp else null) orelse return null;
                if (ok and bmp.color) {
                    self.keepPicture(g, bin, bmp);
                    return self.withPicture(g, bin, n, sp);
                }
                return sp;
            },
        }
    }

    fn rasterize(self: *TextSystem, n: Native, g: u16, bin: u8, out: *engine.Bitmap) bool {
        if (has_engine) {
            const e = self.engine orelse return false;
            return e.rasterize(n.face, n.size * self.scale, g, @as(f32, @floatFromInt(bin)) / subpixel_bins, out);
        } else return false;
    }

    fn pictureKey(g: Glyph, bin: u8) u64 {
        const v: u64 = (@as(u64, g.font) << 24) | (@as(u64, g.glyph) << 8) | bin;
        return std.hash.Wyhash.hash(0x636f6c6f72, std.mem.asBytes(&v));
    }

    /// Keeps a color glyph's pixels among the pictures, padded as the
    /// atlas pads its silhouette.
    fn keepPicture(self: *TextSystem, g: Glyph, bin: u8, bmp: engine.Bitmap) void {
        const w = bmp.w + 2;
        const h = bmp.h + 2;
        const px = self.gpa.alloc(u8, w * h * 4) catch return;
        @memset(px, 0);
        for (0..bmp.h) |y| @memcpy(px[((y + 1) * w + 1) * 4 ..][0 .. bmp.w * 4], bmp.pixels[y * bmp.w * 4 ..][0 .. bmp.w * 4]);
        self.images.put(pictureKey(g, bin), .{ .width = w, .height = h, .w = w, .h = h, .bgra = px });
        self.colors.put(self.gpa, .{ .font = g.font, .glyph = g.glyph, .bin = bin }, {}) catch {};
    }

    /// `sp` with where its color pixels are among the pictures.
    fn withPicture(self: *TextSystem, g: Glyph, bin: u8, n: Native, sp: Sprite) Sprite {
        var out = sp;
        if (!self.colors.contains(.{ .font = g.font, .glyph = g.glyph, .bin = bin })) return out;
        const k = pictureKey(g, bin);
        if (self.images.get(k, &.{})) |entry| {
            out.picture = entry.uv;
            return out;
        }
        // Let go of to make room among the pictures: rasterized again.
        var bmp: engine.Bitmap = .{};
        if (self.rasterize(n, g.glyph, bin, &bmp) and bmp.color) {
            self.keepPicture(g, bin, bmp);
            if (self.images.get(k, &.{})) |entry| out.picture = entry.uv;
        }
        return out;
    }

    pub fn width(self: *TextSystem, s: []const u8, style: types.TextStyle) f32 {
        return self.layout(s, style).width;
    }

    pub fn wrap(self: *TextSystem, s: []const u8, style: types.TextStyle, max_width: f32) []const Line {
        return self.wrapAttributed(s, style, &.{}, max_width);
    }

    /// `s` broken at spaces (or, for a word wider than the line, between
    /// characters) and at newlines into lines no wider than `max_width`.
    pub fn wrapAttributed(self: *TextSystem, s: []const u8, style: types.TextStyle, spans: []const types.Span, max_width: f32) []const Line {
        const styled = rich.styled(spans);
        const k = key(s, style, (@as(u64, @intFromFloat(@max(0, @min(max_width, 1e6)))) + 2) ^ (if (styled) rich.spansHash(spans, 0, s.len) else 0));
        if (self.wraps.get(k)) |lines| return lines;
        const lay = if (styled) rich.layout(self, s, style, spans, 0) else self.layout(s, style);
        var lines: std.ArrayList(Line) = .empty;
        defer lines.deinit(self.gpa);
        wrapping.breakLines(self.gpa, &lines, s, lay, @max(1, max_width)) catch {};
        if (lines.items.len == 0) lines.append(self.gpa, .{ .start = 0, .end = 0, .width = 0 }) catch {};
        if (self.wraps.count() > 2048) self.clearWraps();
        const owned = lines.toOwnedSlice(self.gpa) catch return &.{};
        self.wraps.put(self.gpa, k, owned) catch {
            self.gpa.free(owned);
            return &.{};
        };
        return owned;
    }

    fn clearWraps(self: *TextSystem) void {
        var it = self.wraps.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.wraps.clearRetainingCapacity();
    }

    /// The x of the caret before byte `index` of `s`, in either direction.
    pub fn caretX(self: *TextSystem, s: []const u8, style: types.TextStyle, index: usize) f32 {
        if (s.len == 0) return 0;
        return caret.caretX(self.layout(s, style), s, index);
    }

    /// The byte of `s` whose caret is nearest `x`.
    pub fn indexAt(self: *TextSystem, s: []const u8, style: types.TextStyle, x: f32) usize {
        if (s.len == 0) return 0;
        return caret.indexAt(self.layout(s, style), s, x);
    }

    /// The ranges of x bytes `a`..`b` of `s` cover, left to right (several
    /// in mixed directions), written to `out`; returns how many.
    pub fn selectionRanges(self: *TextSystem, s: []const u8, style: types.TextStyle, a: usize, b: usize, out: [][2]f32) usize {
        if (s.len == 0) return 0;
        return caret.selection(self.layout(s, style), s, a, b, out);
    }

    /// Whether the system has font family `name` (the engine's fonts, or
    /// those myzig reads).
    pub fn familyInstalled(self: *TextSystem, name: []const u8) bool {
        if (has_engine) if (self.engine) |e| return e.hasFamilyNamed(name);
        return self.db.family(name, 400, false) != null;
    }

    /// Whether `s` reads right to left (its first strong character's way).
    pub fn readsRtl(_: *TextSystem, s: []const u8) bool {
        return bidi.firstStrong(s) orelse false;
    }
};
