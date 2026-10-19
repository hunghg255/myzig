//! HarfBuzz, FreeType and fontconfig, loaded with dlopen when text is first
//! laid out (as GTK is, `linux/gtk.zig`): no headers and no libraries at
//! build time. Each function is looked up by the name of its field; the
//! structures FreeType's faces and glyph slots are read through are those
//! of its public headers (`freetype.h`), whose layout has not changed in
//! FreeType 2's ABI.
const std = @import("std");

pub const FcPattern = anyopaque;
pub const FcCharSet = anyopaque;
pub const HbBlob = anyopaque;
pub const HbFace = anyopaque;
pub const HbFont = anyopaque;
pub const HbBuffer = anyopaque;

pub const Fc = struct {
    FcInitLoadConfigAndFonts: *const fn () callconv(.c) ?*anyopaque,
    FcConfigDestroy: *const fn (cfg: *anyopaque) callconv(.c) void,
    FcPatternCreate: *const fn () callconv(.c) ?*FcPattern,
    FcPatternDestroy: *const fn (p: *FcPattern) callconv(.c) void,
    FcPatternAddString: *const fn (p: *FcPattern, object: [*:0]const u8, s: [*:0]const u8) callconv(.c) c_int,
    FcPatternAddInteger: *const fn (p: *FcPattern, object: [*:0]const u8, i: c_int) callconv(.c) c_int,
    FcPatternAddBool: *const fn (p: *FcPattern, object: [*:0]const u8, b: c_int) callconv(.c) c_int,
    FcPatternAddCharSet: *const fn (p: *FcPattern, object: [*:0]const u8, cs: *const FcCharSet) callconv(.c) c_int,
    FcPatternGetString: *const fn (p: *const FcPattern, object: [*:0]const u8, n: c_int, s: *?[*:0]const u8) callconv(.c) c_int,
    FcPatternGetInteger: *const fn (p: *const FcPattern, object: [*:0]const u8, n: c_int, i: *c_int) callconv(.c) c_int,
    FcPatternGetCharSet: *const fn (p: *const FcPattern, object: [*:0]const u8, n: c_int, cs: *?*FcCharSet) callconv(.c) c_int,
    FcConfigSubstitute: *const fn (cfg: ?*anyopaque, p: *FcPattern, kind: c_int) callconv(.c) c_int,
    FcDefaultSubstitute: *const fn (p: *FcPattern) callconv(.c) void,
    FcFontMatch: *const fn (cfg: ?*anyopaque, p: *FcPattern, result: *c_int) callconv(.c) ?*FcPattern,
    FcCharSetCreate: *const fn () callconv(.c) ?*FcCharSet,
    FcCharSetDestroy: *const fn (cs: *FcCharSet) callconv(.c) void,
    FcCharSetAddChar: *const fn (cs: *FcCharSet, cp: u32) callconv(.c) c_int,
    FcCharSetHasChar: *const fn (cs: *const FcCharSet, cp: u32) callconv(.c) c_int,
};

pub const Ft = struct {
    FT_Init_FreeType: *const fn (lib: *?*anyopaque) callconv(.c) c_int,
    FT_Done_FreeType: *const fn (lib: *anyopaque) callconv(.c) c_int,
    FT_New_Face: *const fn (lib: *anyopaque, path: [*:0]const u8, index: c_long, face: *?*FaceRec) callconv(.c) c_int,
    FT_Done_Face: *const fn (face: *FaceRec) callconv(.c) c_int,
    FT_Set_Char_Size: *const fn (face: *FaceRec, w: c_long, h: c_long, hres: c_uint, vres: c_uint) callconv(.c) c_int,
    FT_Select_Size: *const fn (face: *FaceRec, index: c_int) callconv(.c) c_int,
    FT_Set_Transform: *const fn (face: *FaceRec, matrix: ?*const Matrix, delta: ?*const Vector) callconv(.c) void,
    FT_Load_Glyph: *const fn (face: *FaceRec, glyph: c_uint, flags: i32) callconv(.c) c_int,
    FT_Render_Glyph: *const fn (slot: *GlyphSlotRec, mode: c_int) callconv(.c) c_int,
    FT_GlyphSlot_Embolden: *const fn (slot: *GlyphSlotRec) callconv(.c) void,
    FT_GlyphSlot_Oblique: *const fn (slot: *GlyphSlotRec) callconv(.c) void,
};

pub const Hb = struct {
    hb_blob_create_from_file: *const fn (path: [*:0]const u8) callconv(.c) ?*HbBlob,
    hb_blob_destroy: *const fn (b: *HbBlob) callconv(.c) void,
    hb_face_create: *const fn (b: *HbBlob, index: c_uint) callconv(.c) ?*HbFace,
    hb_face_destroy: *const fn (f: *HbFace) callconv(.c) void,
    hb_face_get_upem: *const fn (f: *HbFace) callconv(.c) c_uint,
    hb_font_create: *const fn (f: *HbFace) callconv(.c) ?*HbFont,
    hb_font_destroy: *const fn (f: *HbFont) callconv(.c) void,
    hb_font_set_scale: *const fn (f: *HbFont, x: c_int, y: c_int) callconv(.c) void,
    hb_font_get_nominal_glyph: *const fn (f: *HbFont, cp: u32, glyph: *u32) callconv(.c) c_int,
    hb_font_get_h_extents: *const fn (f: *HbFont, extents: *FontExtents) callconv(.c) c_int,
    hb_buffer_create: *const fn () callconv(.c) ?*HbBuffer,
    hb_buffer_destroy: *const fn (b: *HbBuffer) callconv(.c) void,
    hb_buffer_clear_contents: *const fn (b: *HbBuffer) callconv(.c) void,
    hb_buffer_add_utf8: *const fn (b: *HbBuffer, text: [*]const u8, len: c_int, offset: c_uint, item_len: c_int) callconv(.c) void,
    hb_buffer_set_direction: *const fn (b: *HbBuffer, dir: c_uint) callconv(.c) void,
    hb_buffer_guess_segment_properties: *const fn (b: *HbBuffer) callconv(.c) void,
    hb_buffer_get_length: *const fn (b: *HbBuffer) callconv(.c) c_uint,
    hb_buffer_get_glyph_infos: *const fn (b: *HbBuffer, len: ?*c_uint) callconv(.c) [*]const GlyphInfo,
    hb_buffer_get_glyph_positions: *const fn (b: *HbBuffer, len: ?*c_uint) callconv(.c) [*]const GlyphPosition,
    hb_shape: *const fn (f: *HbFont, b: *HbBuffer, features: ?*const anyopaque, n: c_uint) callconv(.c) void,
};

pub const hb_direction_ltr = 4;
pub const hb_direction_rtl = 5;

pub const GlyphInfo = extern struct { codepoint: u32, mask: u32, cluster: u32, var1: u32, var2: u32 };
pub const GlyphPosition = extern struct { x_advance: i32, y_advance: i32, x_offset: i32, y_offset: i32, v: u32 };
pub const FontExtents = extern struct { ascender: i32, descender: i32, line_gap: i32, reserved: [9]i32 };

// fontconfig.
pub const fc_match_pattern = 0;
pub const fc_result_match = 0;
pub const fc_weight_regular = 80;
pub const fc_weight_medium = 100;
pub const fc_weight_demibold = 180;
pub const fc_weight_bold = 200;
pub const fc_slant_roman = 0;
pub const fc_slant_italic = 100;

// FreeType.
pub const Vector = extern struct { x: c_long, y: c_long };
pub const Matrix = extern struct { xx: c_long, xy: c_long, yx: c_long, yy: c_long };
const Generic = extern struct { data: ?*anyopaque, finalizer: ?*anyopaque };
const BBox = extern struct { x0: c_long, y0: c_long, x1: c_long, y1: c_long };
pub const BitmapSize = extern struct { height: i16, width: i16, size: c_long, x_ppem: c_long, y_ppem: c_long };

pub const FaceRec = extern struct {
    num_faces: c_long,
    face_index: c_long,
    face_flags: c_long,
    style_flags: c_long,
    num_glyphs: c_long,
    family_name: ?[*:0]const u8,
    style_name: ?[*:0]const u8,
    num_fixed_sizes: c_int,
    available_sizes: ?[*]const BitmapSize,
    num_charmaps: c_int,
    charmaps: ?*anyopaque,
    generic: Generic,
    bbox: BBox,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    height: i16,
    max_advance_width: i16,
    max_advance_height: i16,
    underline_position: i16,
    underline_thickness: i16,
    glyph: *GlyphSlotRec,
    size: ?*anyopaque,
    charmap: ?*anyopaque,
};

pub const Bitmap = extern struct {
    rows: c_uint,
    width: c_uint,
    pitch: c_int,
    buffer: ?[*]u8,
    num_grays: u16,
    pixel_mode: u8,
    palette_mode: u8,
    palette: ?*anyopaque,
};

const GlyphMetrics = extern struct { width: c_long, height: c_long, hbx: c_long, hby: c_long, hadv: c_long, vbx: c_long, vby: c_long, vadv: c_long };

pub const GlyphSlotRec = extern struct {
    library: ?*anyopaque,
    face: ?*FaceRec,
    next: ?*anyopaque,
    glyph_index: c_uint,
    generic: Generic,
    metrics: GlyphMetrics,
    linear_hori_advance: c_long,
    linear_vert_advance: c_long,
    advance: Vector,
    format: c_uint,
    bitmap: Bitmap,
    bitmap_left: c_int,
    bitmap_top: c_int,
};

pub const face_flag_scalable = 1 << 0;
pub const face_flag_fixed_sizes = 1 << 1;
pub const face_flag_color = 1 << 14;
pub const load_no_hinting = 1 << 1;
pub const load_color = 1 << 20;
pub const render_mode_normal = 0;
pub const pixel_mode_mono = 1;
pub const pixel_mode_gray = 2;
pub const pixel_mode_bgra = 7;

pub var fc: Fc = undefined;
pub var ft: Ft = undefined;
pub var hb: Hb = undefined;
var tried = false;
var loaded = false;

fn bind(comptime T: type, out: *T, names: []const [*:0]const u8) bool {
    var lib: ?*anyopaque = null;
    for (names) |n| {
        lib = std.c.dlopen(n, .{ .NOW = true });
        if (lib != null) break;
    }
    const l = lib orelse return false;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const sym = std.c.dlsym(l, name) orelse return false;
        @field(out.*, name) = @ptrCast(@alignCast(sym));
    }
    return true;
}

/// Loads the three libraries once; false if one is missing.
pub fn load() bool {
    if (tried) return loaded;
    tried = true;
    loaded = bind(Fc, &fc, &.{ "libfontconfig.so.1", "libfontconfig.so" }) and
        bind(Ft, &ft, &.{ "libfreetype.so.6", "libfreetype.so" }) and
        bind(Hb, &hb, &.{ "libharfbuzz.so.0", "libharfbuzz.so" });
    return loaded;
}
