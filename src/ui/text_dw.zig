//! Text on Windows, as mygo has it: DirectWrite lays a line out with
//! IDWriteTextLayout, which itemizes it by script, orders it by the
//! bidirectional algorithm, finds fonts for what the asked font lacks (the
//! system's fallback: CJK, emoji, symbols) and shapes it with OpenType
//! (Arabic joining, ligatures, kerning, marks); it hands its glyph runs to
//! a renderer implemented here (`Renderer`), which copies them. Glyphs are
//! rasterized by IDWriteGlyphRunAnalysis (`text_dw_raster.zig`), layer by
//! layer for color fonts (Segoe UI Emoji).
const std = @import("std");
const api = @import("text_dw_api.zig");
const engine = @import("text_engine.zig");
const raster = @import("text_dw_raster.zig");

const Object = api.Object;
const Piece = engine.Piece;

const sans = [_][]const u8{ "Segoe UI", "Tahoma", "Arial" };
const monos = [_][]const u8{ "Cascadia Mono", "Consolas", "Courier New" };

const FormatKey = struct { family: u64, weight: u16, italic: bool, size_bits: u32 };
const FaceKey = struct { family: u64, weight: u16, italic: bool };

pub const Engine = struct {
    gpa: std.mem.Allocator,
    factory: Object,
    /// IDWriteFactory2 (Windows 8.1): grayscale analyses, color glyphs.
    factory2: ?Object,
    system: Object,
    locale_buf: [85]u16 = undefined,
    locale: [:0]const u16 = &.{},
    /// Families by the hash of the name asked (and mono): the name found.
    names: std.AutoHashMapUnmanaged(u64, ?[:0]u16) = .empty,
    formats: std.AutoHashMapUnmanaged(FormatKey, Object) = .empty,
    faces: std.AutoHashMapUnmanaged(FaceKey, ?Object) = .empty,
    /// IDWriteTypography objects by the hash of their features' list.
    typos: std.AutoHashMapUnmanaged(u64, ?Object) = .empty,
    /// Faces runs came in, referenced once each, as run fonts keep them.
    held: std.AutoHashMapUnmanaged(usize, void) = .empty,
    color: std.AutoHashMapUnmanaged(usize, bool) = .empty,
    text: engine.Utf16 = .{},
    firsts: std.ArrayList(u32) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    layers: std.ArrayList(u8) = .empty,

    pub fn create(gpa: std.mem.Allocator) ?*Engine {
        const f = api.createFactory() orelse return null;
        var system: ?Object = null;
        if (api.failed(api.call(f, api.factory.get_system_font_collection, .{ &system, @as(i32, 0) })) or system == null) {
            api.release(f);
            return null;
        }
        const e = gpa.create(Engine) catch {
            api.release(system);
            api.release(f);
            return null;
        };
        e.* = .{ .gpa = gpa, .factory = f, .factory2 = api.query(f, &api.iid_factory2), .system = system.? };
        e.locale = api.userLocale(&e.locale_buf);
        return e;
    }

    /// Lets go of the text formats, one a size: when the run fonts start
    /// over (`text_tt.zig`'s `max_run_fonts`).
    pub fn dropFormats(e: *Engine) void {
        var fi = e.formats.valueIterator();
        while (fi.next()) |v| api.release(v.*);
        e.formats.clearRetainingCapacity();
    }

    pub fn destroy(e: *Engine) void {
        const gpa = e.gpa;
        var ni = e.names.valueIterator();
        while (ni.next()) |v| if (v.*) |n| gpa.free(n);
        e.names.deinit(gpa);
        e.dropFormats();
        e.formats.deinit(gpa);
        var ci = e.faces.valueIterator();
        while (ci.next()) |v| api.release(v.*);
        e.faces.deinit(gpa);
        var ti = e.typos.valueIterator();
        while (ti.next()) |v| api.release(v.*);
        e.typos.deinit(gpa);
        var hi = e.held.keyIterator();
        while (hi.next()) |k| api.release(@ptrFromInt(k.*));
        e.held.deinit(gpa);
        e.color.deinit(gpa);
        e.text.deinit(gpa);
        e.firsts.deinit(gpa);
        e.scratch.deinit(gpa);
        e.layers.deinit(gpa);
        api.release(e.system);
        api.release(e.factory2);
        api.release(e.factory);
        gpa.destroy(e);
    }

    fn hasFamily(e: *Engine, name: [:0]const u16) bool {
        var index: u32 = 0;
        var exists: i32 = 0;
        return !api.failed(api.call(e.system, api.collection.find_family_name, .{ name.ptr, &index, &exists })) and exists != 0;
    }

    /// The family a style draws with: the theme's if installed, else the
    /// system's (Segoe UI, or Cascadia Mono for code).
    fn familyName(e: *Engine, family: ?[]const u8, mono: bool) ?[:0]const u16 {
        const key = std.hash.Wyhash.hash(@intFromBool(mono), family orelse "");
        if (e.names.get(key)) |n| return n;
        var found: ?[:0]u16 = null;
        if (family) |name| found = e.tryFamily(name);
        if (found == null) for (if (mono) &monos else &sans) |name| {
            found = e.tryFamily(name);
            if (found != null) break;
        };
        e.names.put(e.gpa, key, found) catch {};
        return found;
    }

    pub fn hasFamilyNamed(e: *Engine, name: []const u8) bool {
        const w = e.tryFamily(name) orelse return false;
        e.gpa.free(w);
        return true;
    }

    fn tryFamily(e: *Engine, name: []const u8) ?[:0]u16 {
        const w = std.unicode.utf8ToUtf16LeAllocZ(e.gpa, name) catch return null;
        if (e.hasFamily(w)) return w;
        e.gpa.free(w);
        return null;
    }

    /// The face a style's characters are drawn in when it has them.
    pub fn face(e: *Engine, family: ?[]const u8, mono: bool, weight: u16, italic: bool) ?usize {
        const name = e.familyName(family, mono) orelse return null;
        const key: FaceKey = .{ .family = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(name)), .weight = weight, .italic = italic };
        if (e.faces.get(key)) |f| return if (f) |o| @intFromPtr(o) else null;
        const f = e.matchFace(name, weight, italic);
        e.faces.put(e.gpa, key, f) catch {};
        return if (f) |o| @intFromPtr(o) else null;
    }

    fn matchFace(e: *Engine, name: [:0]const u16, weight: u16, italic: bool) ?Object {
        var index: u32 = 0;
        var exists: i32 = 0;
        if (api.failed(api.call(e.system, api.collection.find_family_name, .{ name.ptr, &index, &exists })) or exists == 0) return null;
        var fam: ?Object = null;
        if (api.failed(api.call(e.system, api.collection.get_font_family, .{ index, &fam }))) return null;
        defer api.release(fam);
        var fnt: ?Object = null;
        const style: u32 = if (italic) api.font_style_italic else api.font_style_normal;
        if (api.failed(api.call(fam.?, api.family.get_first_matching_font, .{ @as(u32, weight), @as(u32, api.font_stretch_normal), style, &fnt }))) return null;
        defer api.release(fnt);
        var out: ?Object = null;
        if (api.failed(api.call(fnt.?, api.font.create_font_face, .{&out}))) return null;
        return out;
    }

    pub fn metrics(e: *Engine, f: usize, size: f32) engine.Metrics {
        _ = e;
        var m: api.FontMetrics = std.mem.zeroes(api.FontMetrics);
        _ = api.callAs(void, @ptrFromInt(f), api.face.get_metrics, .{&m});
        const k = size / @as(f32, @floatFromInt(@max(m.units_per_em, 1)));
        return .{ .ascent = @as(f32, @floatFromInt(m.ascent)) * k, .descent = @as(f32, @floatFromInt(m.descent)) * k, .leading = @as(f32, @floatFromInt(@max(m.line_gap, 0))) * k };
    }

    fn format(e: *Engine, p: Piece) ?Object {
        const name = e.familyName(p.family, p.mono) orelse return null;
        const key: FormatKey = .{ .family = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(name)), .weight = p.weight, .italic = p.italic, .size_bits = @bitCast(p.size) };
        if (e.formats.get(key)) |f| return f;
        var out: ?Object = null;
        const style: u32 = if (p.italic) api.font_style_italic else api.font_style_normal;
        if (api.failed(api.call(e.factory, api.factory.create_text_format, .{ name.ptr, e.system, @as(u32, p.weight), style, @as(u32, api.font_stretch_normal), p.size, e.locale.ptr, &out }))) return null;
        e.formats.put(e.gpa, key, out.?) catch {
            api.release(out);
            return null;
        };
        return out;
    }

    /// Shapes `s` (one line) in its pieces' styles into `sink`, its runs in
    /// visual order; false when DirectWrite could not.
    pub fn shape(e: *Engine, s: []const u8, pieces: []const Piece, rtl: bool, sink: *engine.Sink) bool {
        if (s.len == 0 or pieces.len == 0) return true;
        const fmt = e.format(pieces[0]) orelse return false;
        e.text.set(e.gpa, s) catch return false;
        const units = e.text.units.items;
        var lay: ?Object = null;
        if (api.failed(api.call(e.factory, api.factory.create_text_layout, .{ units.ptr, @as(u32, @intCast(units.len)), fmt, @as(f32, 100000), @as(f32, 100000), &lay })) or lay == null) return false;
        defer api.release(lay);
        const l = lay.?;
        _ = api.call(l, api.layout.set_word_wrapping, .{@as(u32, api.word_wrapping_no_wrap)});
        if (rtl) _ = api.call(l, api.layout.set_reading_direction, .{@as(u32, api.reading_direction_rtl)});
        const base = pieces[0];
        for (pieces[1..]) |p| e.restyle(l, base, p);
        for (pieces) |p| if (p.features.len > 0) e.setFeatures(l, p);
        var ctx: Collect = .{ .e = e, .s = s, .sink = sink };
        if (api.failed(api.call(l, api.layout.draw, .{ @as(?*anyopaque, @ptrCast(&ctx)), @as(Object, @ptrCast(&renderer)), @as(f32, 0), @as(f32, 0) })) or ctx.failed) return false;
        sink.sortVisual();
        return true;
    }

    /// Gives piece `p`'s range the font it differs from `base` by.
    fn restyle(e: *Engine, l: Object, base: Piece, p: Piece) void {
        const u = e.text.unit_of.items;
        const a = u[@min(p.start, u.len - 1)];
        const b = u[@min(p.end, u.len - 1)];
        if (b <= a) return;
        const r = api.range(a, b - a);
        if (p.mono != base.mono or !sameFamily(p.family, base.family)) if (e.familyName(p.family, p.mono)) |name| {
            _ = api.call(l, api.layout.set_font_family_name, .{ name.ptr, r });
        };
        if (p.weight != base.weight) _ = api.call(l, api.layout.set_font_weight, .{ @as(u32, p.weight), r });
        if (p.italic != base.italic) _ = api.call(l, api.layout.set_font_style, .{ @as(u32, if (p.italic) api.font_style_italic else api.font_style_normal), r });
        if (p.size != base.size) _ = api.call(l, api.layout.set_font_size, .{ p.size, r });
    }

    /// Gives piece `p`'s range its OpenType features.
    fn setFeatures(e: *Engine, l: Object, p: Piece) void {
        const typo = e.typography(p.features) orelse return;
        const u = e.text.unit_of.items;
        if (u.len == 0) return;
        const a = u[@min(p.start, u.len - 1)];
        const b = u[@min(p.end, u.len - 1)];
        if (b <= a) return;
        _ = api.call(l, api.layout.set_typography, .{ typo, api.range(a, b - a) });
    }

    /// The IDWriteTypography of a features' list, made once.
    fn typography(e: *Engine, features: []const u8) ?Object {
        const key = std.hash.Wyhash.hash(0, features);
        if (e.typos.get(key)) |t| return t;
        var list: [16]engine.Feature = undefined;
        const n = engine.parseFeatures(features, &list);
        var out: ?Object = null;
        if (n > 0 and !api.failed(api.call(e.factory, api.factory.create_typography, .{&out})) and out != null) {
            for (list[0..n]) |f| _ = api.call(out.?, api.typography.add_font_feature, .{api.fontFeature(f.tag, f.value)});
        }
        e.typos.put(e.gpa, key, out) catch {};
        return out;
    }

    /// Keeps a face a run came in for as long as the engine lives.
    fn hold(e: *Engine, f: Object) void {
        const gop = e.held.getOrPut(e.gpa, @intFromPtr(f)) catch return;
        if (!gop.found_existing) api.addRef(f);
    }

    pub fn isColor(e: *Engine, f: usize) bool {
        if (e.color.get(f)) |c| return c;
        var c = false;
        if (api.query(@ptrFromInt(f), &api.iid_font_face2)) |f2| {
            c = api.callAs(i32, f2, api.face.is_color_font, .{}) != 0;
            api.release(f2);
        }
        e.color.put(e.gpa, f, c) catch {};
        return c;
    }

    pub const rasterize = raster.rasterize;

    /// The glyph of `cp` in face `f`, 0 when it has none.
    pub fn glyphIndex(e: *Engine, f: usize, cp: u21) u16 {
        _ = e;
        const c: u32 = cp;
        var g: u16 = 0;
        _ = api.call(@ptrFromInt(f), api.face.get_glyph_indices, .{ &c, @as(u32, 1), &g });
        return g;
    }
};

fn sameFamily(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// What a layout's drawing collects into.
const Collect = struct {
    e: *Engine,
    s: []const u8,
    sink: *engine.Sink,
    failed: bool = false,

    fn run(c: *Collect, x: f32, gr: *const api.GlyphRun, desc: *const api.GlyphRunDescription) !void {
        const e = c.e;
        const n: usize = gr.count;
        const f = gr.face orelse return;
        if (n == 0) return;
        e.hold(f);
        const rtl = gr.bidi_level & 1 != 0;
        const pos: usize = desc.position;
        const len: usize = desc.length;
        const byte_of = e.text.byte_of.items;
        if (pos + len >= byte_of.len) return;
        // The first code unit of each glyph's cluster.
        try e.firsts.resize(e.gpa, n);
        const firsts = e.firsts.items;
        @memset(firsts, 0);
        if (desc.cluster_map) |map| {
            var k: usize = 0;
            while (k < len) {
                const g0: usize = map[k];
                var k1 = k + 1;
                while (k1 < len and map[k1] == g0) k1 += 1;
                const g1: usize = if (k1 < len) map[k1] else n;
                for (@min(g0, n)..@min(@max(g1, g0), n)) |g| firsts[g] = @intCast(k);
                k = k1;
            }
        }
        const advances = gr.advances orelse return;
        var width: f32 = 0;
        for (advances[0..n]) |a| width += a;
        try c.sink.begin(@intFromPtr(f), gr.em_size, @intCast(gr.bidi_level), byte_of[pos], byte_of[pos + len], if (rtl) x - width else x);
        for (0..n) |v| {
            const g = if (rtl) n - 1 - v else v;
            const at = byte_of[pos + firsts[g]];
            var adv = advances[g];
            if (at < c.s.len and c.s[at] == '\t') adv *= 4;
            const off: api.GlyphOffset = if (gr.offsets) |o| o[g] else .{ .advance = 0, .ascender = 0 };
            try c.sink.glyph(.{ .id = gr.indices.?[g], .advance = adv, .dx = if (rtl) -off.advance else off.advance, .dy = off.ascender, .cluster = at });
        }
    }
};

/// The IDWriteTextRenderer layouts draw to: one static object, whose
/// drawing context is the `Collect` of the layout drawn.
const Renderer = extern struct { vtbl: *const Vtbl };

const HRESULT = i32;
const Vtbl = extern struct {
    query: *const fn (*Renderer, *const api.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    add_ref: *const fn (*Renderer) callconv(.winapi) u32,
    release: *const fn (*Renderer) callconv(.winapi) u32,
    snapping_disabled: *const fn (*Renderer, ?*anyopaque, *i32) callconv(.winapi) HRESULT,
    transform: *const fn (*Renderer, ?*anyopaque, *[6]f32) callconv(.winapi) HRESULT,
    pixels_per_dip: *const fn (*Renderer, ?*anyopaque, *f32) callconv(.winapi) HRESULT,
    glyph_run: *const fn (*Renderer, ?*anyopaque, f32, f32, u32, *const api.GlyphRun, *const api.GlyphRunDescription, ?*anyopaque) callconv(.winapi) HRESULT,
    underline: *const fn (*Renderer, ?*anyopaque, f32, f32, ?*const anyopaque, ?*anyopaque) callconv(.winapi) HRESULT,
    strikethrough: *const fn (*Renderer, ?*anyopaque, f32, f32, ?*const anyopaque, ?*anyopaque) callconv(.winapi) HRESULT,
    inline_object: *const fn (*Renderer, ?*anyopaque, f32, f32, ?*anyopaque, i32, i32, ?*anyopaque) callconv(.winapi) HRESULT,
};

const methods = struct {
    fn query(self: *Renderer, iid: *const api.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (iid.eql(api.iid_unknown) or iid.eql(api.iid_pixel_snapping) or iid.eql(api.iid_text_renderer)) {
            out.* = self;
            return 0;
        }
        out.* = null;
        return @bitCast(@as(u32, 0x80004002));
    }
    fn refs(_: *Renderer) callconv(.winapi) u32 {
        return 1;
    }
    fn snapping(_: *Renderer, _: ?*anyopaque, out: *i32) callconv(.winapi) HRESULT {
        out.* = 1;
        return 0;
    }
    fn transform(_: *Renderer, _: ?*anyopaque, out: *[6]f32) callconv(.winapi) HRESULT {
        out.* = .{ 1, 0, 0, 1, 0, 0 };
        return 0;
    }
    fn dip(_: *Renderer, _: ?*anyopaque, out: *f32) callconv(.winapi) HRESULT {
        out.* = 1;
        return 0;
    }
    fn glyphRun(_: *Renderer, ctx: ?*anyopaque, x: f32, _: f32, _: u32, gr: *const api.GlyphRun, desc: *const api.GlyphRunDescription, _: ?*anyopaque) callconv(.winapi) HRESULT {
        const c: *Collect = @ptrCast(@alignCast(ctx orelse return 0));
        c.run(x, gr, desc) catch {
            c.failed = true;
        };
        return 0;
    }
    fn line(_: *Renderer, _: ?*anyopaque, _: f32, _: f32, _: ?*const anyopaque, _: ?*anyopaque) callconv(.winapi) HRESULT {
        return 0;
    }
    fn object(_: *Renderer, _: ?*anyopaque, _: f32, _: f32, _: ?*anyopaque, _: i32, _: i32, _: ?*anyopaque) callconv(.winapi) HRESULT {
        return 0;
    }
};

const vtbl: Vtbl = .{
    .query = methods.query,
    .add_ref = methods.refs,
    .release = methods.refs,
    .snapping_disabled = methods.snapping,
    .transform = methods.transform,
    .pixels_per_dip = methods.dip,
    .glyph_run = methods.glyphRun,
    .underline = methods.line,
    .strikethrough = methods.line,
    .inline_object = methods.object,
};

var renderer: Renderer = .{ .vtbl = &vtbl };
