//! DirectWrite without headers: the entry point, loaded from the system
//! directory when text is first shaped, the interfaces' ids, the vtable
//! indices of the methods myzig calls and the structures they take, all
//! from the Windows SDK's headers (dwrite.h, dwrite_1.h, dwrite_2.h).
const std = @import("std");
const com = @import("../windows/com.zig");

pub const GUID = com.GUID;
pub const Object = com.Object;
pub const call = com.call;
pub const callAs = com.callAs;
pub const release = com.release;
pub const addRef = com.addRef;
pub const query = com.query;
pub const failed = com.failed;

pub const iid_unknown = GUID.parse("00000000-0000-0000-c000-000000000046");
pub const iid_factory = GUID.parse("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");
pub const iid_factory2 = GUID.parse("0439fc60-ca44-4994-8dee-3a9af7b732ec");
pub const iid_font_face2 = GUID.parse("d8b768ff-64bc-4e66-982b-ec8e87f693f7");
pub const iid_text_renderer = GUID.parse("ef8a8135-5cc6-45fe-8825-c5a0724eb819");
pub const iid_pixel_snapping = GUID.parse("eaf3a2da-ecf4-4d24-b644-b34f6842024b");

/// IDWriteFactory, and IDWriteFactory2 which extends it.
pub const factory = struct {
    pub const get_system_font_collection = 3;
    pub const create_text_format = 15;
    pub const create_text_layout = 18;
    pub const translate_color_glyph_run = 28;
    pub const create_glyph_run_analysis2 = 30;
};

pub const collection = struct {
    pub const get_font_family = 4;
    pub const find_family_name = 5;
};

pub const family = struct {
    pub const get_first_matching_font = 7;
};

pub const font = struct {
    pub const create_font_face = 13;
};

pub const face = struct {
    pub const get_metrics = 8;
    pub const get_glyph_indices = 11;
    /// IDWriteFontFace2.
    pub const is_color_font = 30;
};

/// IDWriteTextFormat, and IDWriteTextLayout which extends it.
pub const layout = struct {
    pub const set_word_wrapping = 5;
    pub const set_reading_direction = 6;
    pub const set_font_family_name = 31;
    pub const set_font_weight = 32;
    pub const set_font_style = 33;
    pub const set_font_size = 35;
    pub const draw = 58;
};

pub const analysis = struct {
    pub const get_alpha_texture_bounds = 3;
    pub const create_alpha_texture = 4;
};

pub const color_runs = struct {
    pub const move_next = 3;
    pub const get_current_run = 4;
};

pub const factory_type_shared = 0;
pub const font_style_normal = 0;
pub const font_style_italic = 2;
pub const font_stretch_normal = 5;
pub const word_wrapping_no_wrap = 1;
pub const reading_direction_rtl = 1;
pub const rendering_mode_natural_symmetric = 5;
pub const measuring_mode_natural = 0;
pub const grid_fit_default = 0;
pub const antialias_grayscale = 1;
pub const texture_aliased_1x1 = 0;
pub const palette_foreground: u16 = 0xffff;

pub const GlyphOffset = extern struct { advance: f32, ascender: f32 };

pub const GlyphRun = extern struct {
    face: ?Object,
    em_size: f32,
    count: u32,
    indices: ?[*]const u16,
    advances: ?[*]const f32,
    offsets: ?[*]const GlyphOffset,
    sideways: i32 = 0,
    bidi_level: u32 = 0,
};

pub const GlyphRunDescription = extern struct {
    locale: ?[*:0]const u16,
    text: ?[*]const u16,
    length: u32,
    cluster_map: ?[*]const u16,
    position: u32,
};

pub const ColorGlyphRun = extern struct {
    run: GlyphRun,
    description: ?*const GlyphRunDescription,
    x: f32,
    y: f32,
    color: [4]f32,
    palette_index: u16,
};

pub const FontMetrics = extern struct {
    units_per_em: u16,
    ascent: u16,
    descent: u16,
    line_gap: i16,
    cap_height: u16,
    x_height: u16,
    underline_position: i16,
    underline_thickness: u16,
    strikethrough_position: i16,
    strikethrough_thickness: u16,
};

pub const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

/// A DWRITE_TEXT_RANGE, passed in a register as the SDK's ABI does.
pub fn range(start: u32, length: u32) u64 {
    return @as(u64, start) | (@as(u64, length) << 32);
}

const CreateFactory = fn (kind: u32, iid: *const GUID, out: *?Object) callconv(.winapi) com.HRESULT;

extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetUserDefaultLocaleName(out: [*]u16, len: i32) callconv(.winapi) i32;
const load_from_system32 = 0x800;

/// The shared DirectWrite factory, null where DirectWrite is missing.
pub fn createFactory() ?Object {
    const module = LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("dwrite.dll"), null, load_from_system32) orelse return null;
    const f: *const CreateFactory = @ptrCast(@alignCast(GetProcAddress(module, "DWriteCreateFactory") orelse return null));
    var out: ?Object = null;
    if (failed(f(factory_type_shared, &iid_factory, &out))) return null;
    return out;
}

/// The user's locale name ("en-US"), NUL-terminated, in `buf`.
pub fn userLocale(buf: *[85]u16) [:0]const u16 {
    const n = GetUserDefaultLocaleName(buf, buf.len);
    if (n <= 1) {
        const en = std.unicode.utf8ToUtf16LeStringLiteral("en-US");
        @memcpy(buf[0..en.len], en);
        buf[en.len] = 0;
        return buf[0..en.len :0];
    }
    const len: usize = @intCast(n - 1);
    buf[len] = 0;
    return buf[0..len :0];
}
