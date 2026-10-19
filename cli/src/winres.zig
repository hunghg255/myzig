//! Windows resources of an app (after mygo's winres.go): its icon, a
//! manifest (per-monitor DPI awareness, common controls 6, Windows 10 and
//! 11, UTF-8) and version information, written as a compiled resource
//! file (.res), which Zig links into the executable like an object
//! (`exe.root_module.addObjectFile`, through the template's `-Dwin32-res`).
const std = @import("std");
const icon = @import("icon.zig");
const Config = @import("config.zig").Config;

const rt_icon = 3;
const rt_group_icon = 14;
const rt_version = 16;
const rt_manifest = 24;
/// en-US: resources are in the app's own language.
const lang_en_us = 0x0409;

const Res = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn int(r: *Res, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try r.out.appendSlice(r.gpa, &b);
    }

    fn pad(r: *Res) !void {
        while (r.out.items.len % 4 != 0) try r.out.append(r.gpa, 0);
    }

    /// One resource, typed and named by number.
    fn add(r: *Res, typ: u16, id: u16, flags: u16, lang: u16, data: []const u8) !void {
        try r.int(u32, @intCast(data.len));
        try r.int(u32, 32); // header size
        try r.int(u16, 0xFFFF);
        try r.int(u16, typ);
        try r.int(u16, 0xFFFF);
        try r.int(u16, id);
        try r.int(u32, 0); // data version
        try r.int(u16, flags);
        try r.int(u16, lang);
        try r.int(u32, 0); // version
        try r.int(u32, 0); // characteristics
        try r.out.appendSlice(r.gpa, data);
        try r.pad();
    }
};

/// The .res of the app, with `icon_png` (or null for no icon).
pub fn resources(gpa: std.mem.Allocator, c: Config, executable: []const u8, icon_png: ?[]const u8) ![]u8 {
    var r: Res = .{ .gpa = gpa };
    errdefer r.out.deinit(gpa);
    // A .res starts with an empty resource.
    try r.add(0, 0, 0, 0, "");
    if (icon_png) |src| {
        const images = try icon.windowsImages(gpa, src);
        defer for (images) |i| gpa.free(i);
        var group: std.ArrayList(u8) = .empty;
        defer group.deinit(gpa);
        var head: [6]u8 = undefined;
        std.mem.writeInt(u16, head[0..2], 0, .little);
        std.mem.writeInt(u16, head[2..4], 1, .little);
        std.mem.writeInt(u16, head[4..6], images.len, .little);
        try group.appendSlice(gpa, &head);
        for (images, icon.windows_sizes, 0..) |img, n, i| {
            const id: u16 = @intCast(i + 1);
            try r.add(rt_icon, id, 0x1010, lang_en_us, img);
            try icon.dirEntry(&group, gpa, n, img.len, .{ .id = id });
        }
        try r.add(rt_group_icon, 1, 0x1030, lang_en_us, group.items);
    }
    const ver = try versionInfo(gpa, c, executable);
    defer gpa.free(ver);
    try r.add(rt_version, 1, 0x0030, lang_en_us, ver);
    const man = try manifest(gpa, c);
    defer gpa.free(man);
    try r.add(rt_manifest, 1, 0x0030, lang_en_us, man);
    return r.out.toOwnedSlice(gpa);
}

/// A version such as "1.2.3-beta" as four numbers.
pub fn version4(v: []const u8) [4]u16 {
    var out: [4]u16 = .{ 0, 0, 0, 0 };
    const core = v[0 .. std.mem.indexOfAny(u8, v, "-+") orelse v.len];
    var it = std.mem.splitScalar(u8, core, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == 4) break;
        out[i] = std.fmt.parseInt(u16, part, 10) catch 0;
    }
    return out;
}

pub fn manifest(gpa: std.mem.Allocator, c: Config) ![]u8 {
    const v = version4(c.version);
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(gpa);
    for (c.identifier) |ch| if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-') try name.append(gpa, ch);
    return std.fmt.allocPrint(gpa,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
        \\  <assemblyIdentity type="win32" name="{s}" version="{d}.{d}.{d}.{d}" processorArchitecture="*"/>
        \\  <dependency>
        \\    <dependentAssembly>
        \\      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
        \\    </dependentAssembly>
        \\  </dependency>
        \\  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
        \\    <application>
        \\      <supportedOS Id="{{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}}"/>
        \\    </application>
        \\  </compatibility>
        \\  <application xmlns="urn:schemas-microsoft-com:asm.v3">
        \\    <windowsSettings>
        \\      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
        \\      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
        \\      <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
        \\    </windowsSettings>
        \\  </application>
        \\</assembly>
        \\
    , .{ name.items, v[0], v[1], v[2], v[3] });
}

/// A node of a version resource: its length, its value's length, its
/// type, a UTF-16 key, the value and children, each aligned on 32 bits.
const Node = struct {
    key: []const u8,
    text: bool = false,
    value: []const u8 = "",
    /// In bytes for binary values, in UTF-16 units for text.
    value_len: usize = 0,
    children: []const Node = &.{},

    fn encode(n: Node, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        const start = out.items.len;
        try out.appendNTimes(gpa, 0, 6);
        try utf16z(gpa, out, n.key);
        while ((out.items.len - start) % 4 != 0) try out.append(gpa, 0);
        try out.appendSlice(gpa, n.value);
        for (n.children) |child| {
            while ((out.items.len - start) % 4 != 0) try out.append(gpa, 0);
            try child.encode(gpa, out);
        }
        const b = out.items[start..];
        std.mem.writeInt(u16, b[0..2], @intCast(b.len), .little);
        std.mem.writeInt(u16, b[2..4], @intCast(n.value_len), .little);
        std.mem.writeInt(u16, b[4..6], @intFromBool(n.text), .little);
    }
};

fn utf16z(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(gpa, s);
    defer gpa.free(units);
    for (units) |u| {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, u, .little);
        try out.appendSlice(gpa, &b);
    }
    try out.appendSlice(gpa, &.{ 0, 0 });
}

/// VS_VERSIONINFO: the app's strings in English and the Unicode code page
/// (040904b0), and its version as numbers.
pub fn versionInfo(gpa: std.mem.Allocator, c: Config, executable: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = version4(c.version);
    var fixed: [52]u8 = @splat(0);
    std.mem.writeInt(u32, fixed[0..4], 0xFEEF04BD, .little); // signature
    std.mem.writeInt(u32, fixed[4..8], 0x00010000, .little); // struct version
    std.mem.writeInt(u32, fixed[8..12], @as(u32, v[0]) << 16 | v[1], .little); // file version
    std.mem.writeInt(u32, fixed[12..16], @as(u32, v[2]) << 16 | v[3], .little);
    @memcpy(fixed[16..24], fixed[8..16]); // product version
    std.mem.writeInt(u32, fixed[24..28], 0x3F, .little); // flags mask
    std.mem.writeInt(u32, fixed[32..36], 0x00040004, .little); // VOS_NT_WINDOWS32
    std.mem.writeInt(u32, fixed[36..40], 1, .little); // VFT_APP

    const exe = try std.fmt.allocPrint(a, "{s}.exe", .{executable});
    const pairs = [_][2][]const u8{
        .{ "FileDescription", c.name },  .{ "FileVersion", c.version },
        .{ "InternalName", exe },        .{ "LegalCopyright", c.copyright },
        .{ "OriginalFilename", exe },    .{ "ProductName", c.name },
        .{ "ProductVersion", c.version }, .{ "MyzigIdentifier", c.identifier },
    };
    var strings: std.ArrayList(Node) = .empty;
    for (pairs) |p| {
        if (p[1].len == 0) continue;
        var val: std.ArrayList(u8) = .empty;
        try utf16z(a, &val, p[1]);
        try strings.append(a, .{ .key = p[0], .text = true, .value = val.items, .value_len = val.items.len / 2 });
    }
    const translation = [_]u8{ 0x09, 0x04, 0xB0, 0x04 };
    const root: Node = .{ .key = "VS_VERSION_INFO", .value = &fixed, .value_len = fixed.len, .children = &.{
        .{ .key = "StringFileInfo", .text = true, .children = &.{.{ .key = "040904b0", .text = true, .children = strings.items }} },
        .{ .key = "VarFileInfo", .text = true, .children = &.{.{ .key = "Translation", .value = &translation, .value_len = translation.len }} },
    } };
    var out: std.ArrayList(u8) = .empty;
    try root.encode(gpa, &out);
    return out.toOwnedSlice(gpa);
}

/// The resources of a .res, for tests: (type, id, data).
pub fn parse(gpa: std.mem.Allocator, res: []const u8) ![]const struct { u16, u16, []const u8 } {
    var list: std.ArrayList(struct { u16, u16, []const u8 }) = .empty;
    var at: usize = 0;
    while (at + 32 <= res.len) {
        const size = std.mem.readInt(u32, res[at..][0..4], .little);
        const header = std.mem.readInt(u32, res[at + 4 ..][0..4], .little);
        if (header != 32 or std.mem.readInt(u16, res[at + 8 ..][0..2], .little) != 0xFFFF) return error.BadRes;
        const typ = std.mem.readInt(u16, res[at + 10 ..][0..2], .little);
        const id = std.mem.readInt(u16, res[at + 14 ..][0..2], .little);
        try list.append(gpa, .{ typ, id, res[at + 32 ..][0..size] });
        at = std.mem.alignForward(usize, at + 32 + size, 4);
    }
    if (at != res.len) return error.BadRes;
    return list.toOwnedSlice(gpa);
}

test resources {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const png = try @import("png.zig").testIcon(gpa, 48, .{ 255, 128, 0 });
    const c: Config = .{ .root = "/a", .name = "My App", .identifier = "com.example.my app", .version = "1.2.3-beta", .copyright = "(c) Me" };
    const res = try resources(gpa, c, "my_app", png);
    const list = try parse(gpa, res);
    // The empty resource, 7 icons, the group, version and manifest.
    try std.testing.expectEqual(@as(usize, 1 + icon.windows_sizes.len + 3), list.len);
    try std.testing.expectEqual(@as(u16, 0), list[0][0]);
    for (list[1 .. 1 + icon.windows_sizes.len], 1..) |r, id| {
        try std.testing.expectEqual(@as(u16, rt_icon), r[0]);
        try std.testing.expectEqual(@as(u16, @intCast(id)), r[1]);
        try std.testing.expect(std.mem.startsWith(u8, r[2], "\x89PNG"));
    }
    const group = list[1 + icon.windows_sizes.len];
    try std.testing.expectEqual(@as(u16, rt_group_icon), group[0]);
    try std.testing.expectEqual(@as(usize, 6 + 14 * icon.windows_sizes.len), group[2].len);
    const ver = list[list.len - 2][2];
    try std.testing.expectEqual(@as(u16, @intCast(ver.len)), std.mem.readInt(u16, ver[0..2], .little));
    try std.testing.expectEqual(@as(u16, 52), std.mem.readInt(u16, ver[2..4], .little));
    // The fixed info follows the key "VS_VERSION_INFO" (6 + 32 bytes, aligned to 40).
    try std.testing.expectEqual(@as(u32, 0xFEEF04BD), std.mem.readInt(u32, ver[40..44], .little));
    try std.testing.expectEqual(@as(u32, 1 << 16 | 2), std.mem.readInt(u32, ver[48..52], .little));
    try std.testing.expectEqual(@as(u32, 3 << 16), std.mem.readInt(u32, ver[52..56], .little));
    const units = try std.unicode.utf8ToUtf16LeAlloc(gpa, "My App");
    try std.testing.expect(std.mem.indexOf(u8, ver, std.mem.sliceAsBytes(units)) != null);
    const man = list[list.len - 1];
    try std.testing.expectEqual(@as(u16, rt_manifest), man[0]);
    try std.testing.expect(std.mem.indexOf(u8, man[2], "name=\"com.example.myapp\" version=\"1.2.3.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, man[2], "PerMonitorV2") != null);
}

test version4 {
    try std.testing.expectEqual([4]u16{ 1, 2, 3, 0 }, version4("1.2.3"));
    try std.testing.expectEqual([4]u16{ 0, 10, 0, 0 }, version4("0.10-rc.1"));
    try std.testing.expectEqual([4]u16{ 1, 2, 3, 4 }, version4("1.2.3.4.5"));
}
