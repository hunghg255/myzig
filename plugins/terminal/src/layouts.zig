//! Checks the structs of `ghostty.zig` against the layouts the library
//! describes (`ghostty_type_json`): their sizes and the offsets of their
//! fields, the enum values hardcoded here, and the bit positions of
//! packed cells, which `cell` then reads by. A library of another version
//! fails to load rather than corrupt memory.
const std = @import("std");
const g = @import("ghostty.zig");

/// A field of the packed GhosttyCell.
pub const Bits = struct {
    lsb: u6 = 0,
    width: u6 = 0,

    pub fn of(b: Bits, v: u64) u64 {
        if (b.width == 0) return 0;
        return (v >> b.lsb) & ((@as(u64, 1) << b.width) - 1);
    }
};

/// Where the parts of a GhosttyCell are, as the library reports them.
pub const CellBits = struct {
    tag: Bits = .{},
    codepoint: Bits = .{},
    style_id: Bits = .{},
    wide: Bits = .{},
    hyperlink: Bits = .{},
    palette_index: Bits = .{},
    r: Bits = .{},
    g: Bits = .{},
    b: Bits = .{},
};

pub var cell: CellBits = .{};

const structs = .{
    .{ "GhosttyColorRgb", g.Rgb },
    .{ "GhosttyStyleColor", g.StyleColor },
    .{ "GhosttyStyle", g.Style },
    .{ "GhosttyRenderStateCursor", g.RenderCursor },
    .{ "GhosttyRenderStateColors", g.RenderColors },
    .{ "GhosttyRenderStateRowSelection", g.RowSelection },
    .{ "GhosttyCellsView", g.CellsView },
    .{ "GhosttyString", g.String },
    .{ "GhosttyTerminalScrollbar", g.Scrollbar },
    .{ "GhosttyTerminalScrollViewport", g.ScrollViewport },
    .{ "GhosttyTerminalModeConfig", g.ModeConfig },
    .{ "GhosttyGridRef", g.GridRef },
    .{ "GhosttyPoint", g.Point },
    .{ "GhosttyPointCoordinate", g.PointCoordinate },
    .{ "GhosttySelection", g.Selection },
    .{ "GhosttyTerminalSelectionFormatOptions", g.SelectionFormatOptions },
    .{ "GhosttyFormatterTerminalOptions", g.FormatterTerminalOptions },
    .{ "GhosttyFormatterTerminalExtra", g.FormatterTerminalExtra },
    .{ "GhosttyFormatterScreenExtra", g.FormatterScreenExtra },
    .{ "GhosttyMouseEncoderSize", g.MouseEncoderSize },
    .{ "GhosttyMousePosition", g.MousePosition },
    .{ "GhosttySizeReportSize", g.SizeReportSize },
    .{ "GhosttyDeviceAttributes", g.DeviceAttributes },
    .{ "GhosttyDeviceAttributesPrimary", g.DeviceAttributesPrimary },
    .{ "GhosttyDeviceAttributesSecondary", g.DeviceAttributesSecondary },
};

/// Values of enums this package hardcodes, which the library must agree with.
const enums = [_]struct { []const u8, []const u8, i64 }{
    .{ "GhosttyKey", "A", 20 },
    .{ "GhosttyKey", "ARROW_UP", 78 },
    .{ "GhosttyKey", "ESCAPE", 120 },
    .{ "GhosttyKey", "F1", 121 },
    .{ "GhosttyKeyAction", "PRESS", 1 },
    .{ "GhosttyMouseAction", "MOTION", 2 },
    .{ "GhosttyMouseButton", "FIVE", 5 },
    .{ "GhosttyRenderStateCursorVisualStyle", "BLOCK_HOLLOW", 3 },
    .{ "GhosttyCellWide", "SPACER_HEAD", 3 },
    .{ "GhosttyStyleColorTag", "RGB", 2 },
    .{ "GhosttyTerminalOption", "RESIZE_PULL_SCROLLBACK", 40 },
    .{ "GhosttyTerminalOption", "TERMINFO_NAME", 37 },
    .{ "GhosttyTerminalData", "VIEWPORT_ACTIVE", 32 },
    .{ "GhosttyRenderStateData", "COLORS", 19 },
    .{ "GhosttyRenderStateRowData", "CELLS_RAW", 5 },
    .{ "GhosttyRenderStateRowCellsData", "GRAPHEMES_BUF", 4 },
    .{ "GhosttyTerminalScrollViewportTag", "ROW", 3 },
    .{ "GhosttyPointTag", "SCREEN", 2 },
    .{ "GhosttyFocusEvent", "LOST", 1 },
    .{ "GhosttyKeyEncoderOption", "MACOS_OPTION_AS_ALT", 6 },
    .{ "GhosttyMouseEncoderOption", "TRACK_LAST_CELL", 4 },
};

pub fn check(manifest: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), manifest, .{}) catch return error.GhosttyIncompatible;
    const root = object(parsed) orelse return error.GhosttyIncompatible;
    if (int(field(root, &.{ "abi", "pointer_size" })) != @sizeOf(usize)) return error.GhosttyIncompatible;
    const types = object(root.get("types") orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    inline for (structs) |s| try checkStruct(types, s[0], s[1]);
    for (enums) |e| {
        if (int(field(types, &.{ e[0], "values", e[1] })) != e[2]) return error.GhosttyIncompatible;
    }
    try readCell(types);
}

fn checkStruct(types: std.json.ObjectMap, comptime name: []const u8, comptime T: type) !void {
    const t = object(types.get(name) orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    if (int(t.get("size")) != @sizeOf(T)) return error.GhosttyIncompatible;
    const fields = object(t.get("fields") orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    inline for (@typeInfo(T).@"struct".field_names) |f| {
        if (f[0] == '_') continue;
        if (int(field(fields, &.{ f, "offset" })) != @offsetOf(T, f)) return error.GhosttyIncompatible;
    }
}

fn readCell(types: std.json.ObjectMap) !void {
    const c = object(types.get("GhosttyCell") orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    if (int(c.get("size")) != 8) return error.GhosttyIncompatible;
    const bits = object(c.get("bits") orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    cell.tag = try bitsOf(bits, "content_tag", 0);
    cell.style_id = try bitsOf(bits, "style_id", 0);
    cell.wide = try bitsOf(bits, "wide", 0);
    cell.hyperlink = try bitsOf(bits, "hyperlink", 0);
    const content = object(bits.get("content") orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    const base: u6 = @intCast(int(content.get("lsb")));
    const arms = object(content.get("arms") orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    cell.codepoint = try armBits(arms, "CODEPOINT", "codepoint", base);
    cell.palette_index = try armBits(arms, "BG_COLOR_PALETTE", "index", base);
    cell.r = try armBits(arms, "BG_COLOR_RGB", "r", base);
    cell.g = try armBits(arms, "BG_COLOR_RGB", "g", base);
    cell.b = try armBits(arms, "BG_COLOR_RGB", "b", base);
}

fn armBits(arms: std.json.ObjectMap, arm: []const u8, name: []const u8, base: u6) !Bits {
    const a = object(arms.get(arm) orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    const bits = object(a.get("bits") orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    return bitsOf(bits, name, base);
}

fn bitsOf(bits: std.json.ObjectMap, name: []const u8, base: u6) !Bits {
    const b = object(bits.get(name) orelse return error.GhosttyIncompatible) orelse return error.GhosttyIncompatible;
    const lsb = int(b.get("lsb"));
    const width = int(b.get("width"));
    if (lsb < 0 or width <= 0 or lsb + base + width > 64) return error.GhosttyIncompatible;
    return .{ .lsb = @intCast(lsb + base), .width = @intCast(width) };
}

fn object(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn int(v: ?std.json.Value) i64 {
    return switch (v orelse return -1) {
        .integer => |i| i,
        else => -1,
    };
}

/// The value at `path` in nested objects.
fn field(o: std.json.ObjectMap, path: []const []const u8) ?std.json.Value {
    var cur: std.json.Value = .{ .object = o };
    for (path) |p| {
        const obj = object(cur) orelse return null;
        cur = obj.get(p) orelse return null;
    }
    return cur;
}

test "bits read a field of a packed value" {
    const b: Bits = .{ .lsb = 4, .width = 3 };
    try std.testing.expectEqual(@as(u64, 5), b.of((5 << 4) | 0x80 | 0xf));
}
