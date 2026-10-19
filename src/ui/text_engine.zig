//! What the system's text engines share (DirectWrite on Windows,
//! HarfBuzz, FreeType and fontconfig on Linux), as `text_tt.zig` drives
//! them: the styles of a paragraph's pieces, the runs they shape into, and
//! the bitmaps they rasterize glyphs to.
const std = @import("std");
const runs = @import("text_runs.zig");

/// Bytes `start`..`end` of a paragraph in one style.
pub const Piece = struct {
    start: u32,
    end: u32,
    /// The family the theme names, null for the system's.
    family: ?[]const u8,
    mono: bool,
    weight: u16,
    italic: bool,
    size: f32,
};

pub const Metrics = struct { ascent: f32, descent: f32, leading: f32 };

/// A rasterized glyph: `w` × `h` pixels whose top left is `left`, `top`
/// pixels from the pen on the baseline (y down); coverage, or premultiplied
/// BGRA for a color glyph.
pub const Bitmap = struct {
    w: u32 = 0,
    h: u32 = 0,
    left: i32 = 0,
    top: i32 = 0,
    color: bool = false,
    pixels: []const u8 = &.{},
};

/// A run as an engine shapes it: its face (the engine's handle) and size
/// rather than the text system's run font, and where it starts on the line
/// (visual order follows from it).
pub const NativeRun = struct {
    face: usize,
    size: f32,
    level: u8,
    start: u32,
    end: u32,
    x: f32,
    first: u32,
    count: u32,
};

/// Where an engine puts what it shapes.
pub const Sink = struct {
    gpa: std.mem.Allocator,
    glyphs: std.ArrayList(runs.Shaped) = .empty,
    runs: std.ArrayList(NativeRun) = .empty,

    pub fn deinit(s: *Sink) void {
        s.glyphs.deinit(s.gpa);
        s.runs.deinit(s.gpa);
    }

    pub fn reset(s: *Sink) void {
        s.glyphs.clearRetainingCapacity();
        s.runs.clearRetainingCapacity();
    }

    /// Starts a run; its glyphs follow (`glyph`), left to right.
    pub fn begin(s: *Sink, face: usize, size: f32, level: u8, start: u32, end: u32, x: f32) !void {
        try s.runs.append(s.gpa, .{ .face = face, .size = size, .level = level, .start = start, .end = end, .x = x, .first = @intCast(s.glyphs.items.len), .count = 0 });
    }

    pub fn glyph(s: *Sink, g: runs.Shaped) !void {
        try s.glyphs.append(s.gpa, g);
        s.runs.items[s.runs.items.len - 1].count += 1;
    }

    /// The runs sorted by where they start on the line.
    pub fn sortVisual(s: *Sink) void {
        std.mem.sort(NativeRun, s.runs.items, {}, struct {
            fn lt(_: void, a: NativeRun, b: NativeRun) bool {
                return a.x < b.x;
            }
        }.lt);
    }

    pub fn glyphsOf(s: *const Sink, r: NativeRun) []const runs.Shaped {
        return s.glyphs.items[r.first..][0..r.count];
    }
};

/// UTF-8 to UTF-16 with each code unit's byte and each byte's code unit,
/// as engines that take UTF-16 (DirectWrite) map their clusters back.
/// Tabs become spaces and other controls zero-width spaces: a line has no
/// breaks, and a tab is drawn as four spaces' room.
pub const Utf16 = struct {
    units: std.ArrayList(u16) = .empty,
    /// The byte of each unit, and one more for the end.
    byte_of: std.ArrayList(u32) = .empty,
    /// The unit of each byte, and one more for the end.
    unit_of: std.ArrayList(u32) = .empty,

    pub fn deinit(u: *Utf16, gpa: std.mem.Allocator) void {
        u.units.deinit(gpa);
        u.byte_of.deinit(gpa);
        u.unit_of.deinit(gpa);
    }

    pub fn set(u: *Utf16, gpa: std.mem.Allocator, s: []const u8) !void {
        u.units.clearRetainingCapacity();
        u.byte_of.clearRetainingCapacity();
        u.unit_of.clearRetainingCapacity();
        var i: usize = 0;
        while (i < s.len) {
            const n = @min(@import("utf8.zig").seqLen(s[i]), s.len - i);
            var cp: u21 = std.unicode.utf8Decode(s[i .. i + n]) catch 0xfffd;
            if (cp == '\t') cp = ' ' else if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) cp = 0x200b;
            const at: u32 = @intCast(u.units.items.len);
            for (0..n) |_| try u.unit_of.append(gpa, at);
            if (cp >= 0x10000) {
                const v = cp - 0x10000;
                try u.units.appendSlice(gpa, &.{ @intCast(0xd800 + (v >> 10)), @intCast(0xdc00 + (v & 0x3ff)) });
                try u.byte_of.appendSlice(gpa, &.{ @intCast(i), @intCast(i) });
            } else {
                try u.units.append(gpa, @intCast(cp));
                try u.byte_of.append(gpa, @intCast(i));
            }
            i += n;
        }
        try u.byte_of.append(gpa, @intCast(s.len));
        try u.unit_of.append(gpa, @intCast(u.units.items.len));
    }
};
