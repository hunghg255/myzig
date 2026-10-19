//! The .DS_Store that lays out the Finder window of a disk image (window
//! bounds, icon size, icon positions), after mygo's dsstore.go: Finder
//! reads it when the image opens, so making the image needs no AppleScript
//! and works headless. The bytes are those the ds_store Python package
//! (used by dmgbuild, MIT licensed) writes for the same records.
const std = @import("std");

/// One record: a property (`code`) of a file in the folder, or of the
/// folder itself when the name is ".".
pub const Record = struct {
    name: []const u8,
    code: *const [4]u8,
    kind: enum { long, blob, type },
    /// Big-endian number, blob bytes or four-character type.
    value: []const u8,
};

fn put32(gpa: std.mem.Allocator, b: *std.ArrayList(u8), v: u32) !void {
    var x: [4]u8 = undefined;
    std.mem.writeInt(u32, &x, v, .big);
    try b.appendSlice(gpa, &x);
}

fn encodeRecord(gpa: std.mem.Allocator, b: *std.ArrayList(u8), r: Record) !void {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(gpa);
    var it = (try std.unicode.Utf8View.init(r.name)).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try units.append(gpa, @intCast(0xD800 + (v >> 10)));
            try units.append(gpa, @intCast(0xDC00 + (v & 0x3FF)));
        } else try units.append(gpa, @intCast(cp));
    }
    try put32(gpa, b, @intCast(units.items.len));
    for (units.items) |u| {
        var x: [2]u8 = undefined;
        std.mem.writeInt(u16, &x, u, .big);
        try b.appendSlice(gpa, &x);
    }
    try b.appendSlice(gpa, r.code);
    try b.appendSlice(gpa, @tagName(r.kind));
    if (r.kind == .blob) try put32(gpa, b, @intCast(r.value.len));
    try b.appendSlice(gpa, r.value);
}

fn recordLess(_: void, a: Record, b: Record) bool {
    // By name ignoring case, then by code.
    const n = @min(a.name.len, b.name.len);
    for (a.name[0..n], b.name[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    if (a.name.len != b.name.len) return a.name.len < b.name.len;
    return std.mem.order(u8, a.code, b.code) == .lt;
}

/// Encodes a .DS_Store holding `records`. The file is a buddy-allocated
/// address space (after a 4-byte prefix): a header at 0, the B-tree header
/// ("DSDB") at 0x20, the allocator's root block at 0x800 and a single
/// B-tree leaf at 0x2000, which holds the few records of a disk image.
pub fn encode(gpa: std.mem.Allocator, records_in: []const Record) ![]u8 {
    const records = try gpa.dupe(Record, records_in);
    defer gpa.free(records);
    std.sort.insertion(Record, records, {}, recordLess);
    var node: std.ArrayList(u8) = .empty;
    defer node.deinit(gpa);
    try put32(gpa, &node, 0); // a leaf: no child pointer
    try put32(gpa, &node, @intCast(records.len));
    for (records) |r| try encodeRecord(gpa, &node, r);
    const page = 0x1000;
    if (node.items.len > page) return error.DSStoreTooLarge;

    const dsdb = 0x20; // block 1, 2^5 bytes
    const root_at = 0x800; // block 0, 2^11 bytes
    const node_at = 0x2000; // block 2, 2^13 bytes
    const file = try gpa.alloc(u8, 4 + 0x4000);
    @memset(file, 0);
    file[3] = 1;
    const mem = file[4..];
    const W = struct {
        fn w(m: []u8, at: usize, v: u32) void {
            std.mem.writeInt(u32, m[at..][0..4], v, .big);
        }
    };
    @memcpy(mem[0..4], "Bud1");
    W.w(mem, 4, root_at);
    W.w(mem, 8, 0x800); // the root block's size
    W.w(mem, 12, root_at);
    @memcpy(mem[16..32], &[_]u8{ 0, 0, 0x10, 0x0c, 0, 0, 0, 0x87, 0, 0, 0x20, 0x0b, 0, 0, 0, 0 });

    W.w(mem, dsdb, 2); // the root node: block 2
    W.w(mem, dsdb + 4, 0);
    W.w(mem, dsdb + 8, @intCast(records.len));
    W.w(mem, dsdb + 12, 1); // nodes
    W.w(mem, dsdb + 16, page);

    const root = mem[root_at..];
    W.w(root, 0, 3); // blocks
    for ([_]u32{ root_at | 11, dsdb | 5, node_at | 13 }, 0..) |addr, i| W.w(root, 8 + 4 * i, addr);
    var p: usize = 8 + 256 * 4; // the block list is padded to 256 entries
    W.w(root, p, 1);
    root[p + 4] = 4;
    @memcpy(root[p + 5 ..][0..4], "DSDB");
    W.w(root, p + 9, 1); // the B-tree header is block 1
    p += 13;
    // Free lists by log2 size: carving the blocks above out of the initial
    // 2 GiB leaves one free block of each other size, at its size.
    for (0..32) |width| {
        if (width < 6 or width == 11 or width == 13 or width == 31) {
            p += 4;
            continue;
        }
        W.w(root, p, 1);
        W.w(root, p + 4, @as(u32, 1) << @intCast(width));
        p += 8;
    }
    @memcpy(mem[node_at..][0..node.items.len], node.items);
    return file;
}

/// A value of a flat binary property list.
pub const Scalar = union(enum) {
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,

    fn eql(a: Scalar, b: Scalar) bool {
        return switch (a) {
            .bool => |x| b == .bool and b.bool == x,
            .int => |x| b == .int and b.int == x,
            .float => |x| b == .float and b.float == x,
            .string => |x| b == .string and std.mem.eql(u8, b.string, x),
        };
    }
};

pub const Entry = struct { []const u8, Scalar };

fn sizeOf(n: u64) u8 {
    return if (n < 1 << 8) 1 else if (n < 1 << 16) 2 else if (n < 1 << 32) 4 else 8;
}

fn putUint(gpa: std.mem.Allocator, b: *std.ArrayList(u8), v: u64, size: u8) !void {
    var i: u8 = size;
    while (i > 0) {
        i -= 1;
        try b.append(gpa, @truncate(v >> @intCast(8 * @as(u32, i))));
    }
}

fn putInt(gpa: std.mem.Allocator, b: *std.ArrayList(u8), v: i64) !void {
    if (v < 0) {
        try b.append(gpa, 0x13);
        return putUint(gpa, b, @bitCast(v), 8);
    }
    const u: u64 = @intCast(v);
    const s = sizeOf(u);
    try b.append(gpa, 0x10 | @as(u8, switch (s) {
        1 => 0,
        2 => 1,
        4 => 2,
        else => 3,
    }));
    try putUint(gpa, b, u, s);
}

fn putSize(gpa: std.mem.Allocator, b: *std.ArrayList(u8), marker: u8, n: usize) !void {
    if (n < 15) return b.append(gpa, marker | @as(u8, @intCast(n)));
    try b.append(gpa, marker | 0xf);
    try putInt(gpa, b, @intCast(n));
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a[0], b[0]) == .lt;
}

/// Encodes a flat dictionary as a binary property list, laid out as
/// Python's plistlib does: the dictionary, its keys, its values, equal
/// scalars shared.
pub fn binaryPlist(gpa: std.mem.Allocator, entries_in: []const Entry) ![]u8 {
    const entries = try gpa.dupe(Entry, entries_in);
    defer gpa.free(entries);
    std.sort.insertion(Entry, entries, {}, entryLess);
    var objs: std.ArrayList(Scalar) = .empty; // objs[i] is object i + 1
    defer objs.deinit(gpa);
    const refs = try gpa.alloc(usize, entries.len * 2);
    defer gpa.free(refs);
    for (0..2) |half| for (entries, 0..) |e, i| {
        const s: Scalar = if (half == 0) .{ .string = e[0] } else e[1];
        const r = for (objs.items, 0..) |o, k| {
            if (o.eql(s)) break k + 1;
        } else blk: {
            try objs.append(gpa, s);
            break :blk objs.items.len;
        };
        refs[half * entries.len + i] = r;
    };
    const ref_size = sizeOf(objs.items.len + 1);
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa, "bplist00");
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(gpa);
    try offsets.append(gpa, b.items.len);
    try putSize(gpa, &b, 0xd0, entries.len);
    for (refs) |r| try putUint(gpa, &b, r, ref_size);
    for (objs.items) |o| {
        try offsets.append(gpa, b.items.len);
        switch (o) {
            .bool => |v| try b.append(gpa, if (v) 0x09 else 0x08),
            .int => |v| try putInt(gpa, &b, v),
            .float => |v| {
                try b.append(gpa, 0x23);
                try putUint(gpa, &b, @bitCast(v), 8);
            },
            .string => |s| {
                const ascii = for (s) |c| {
                    if (c >= 0x80) break false;
                } else true;
                if (ascii) {
                    try putSize(gpa, &b, 0x50, s.len);
                    try b.appendSlice(gpa, s);
                } else {
                    var units: std.ArrayList(u16) = .empty;
                    defer units.deinit(gpa);
                    var it = (try std.unicode.Utf8View.init(s)).iterator();
                    while (it.nextCodepoint()) |cp| try units.append(gpa, if (cp < 0x10000) @intCast(cp) else 0xFFFD);
                    try putSize(gpa, &b, 0x60, units.items.len);
                    for (units.items) |u| try putUint(gpa, &b, u, 2);
                }
            },
        }
    }
    const table = b.items.len;
    const off_size = sizeOf(table);
    for (offsets.items) |o| try putUint(gpa, &b, o, off_size);
    try b.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0, 0, 0, off_size, ref_size });
    try putUint(gpa, &b, offsets.items.len, 8);
    try putUint(gpa, &b, 0, 8); // the top object
    try putUint(gpa, &b, table, 8);
    return b.toOwnedSlice(gpa);
}

/// The window: the app on the left, a link to /Applications on the right.
pub const window = .{ .x = 200, .y = 400, .width = 660, .height = 400, .icon_size = 128, .app = .{ 180, 190 }, .applications = .{ 480, 185 } };

fn be32(gpa: std.mem.Allocator, v: u32) ![]u8 {
    const b = try gpa.alloc(u8, 4);
    std.mem.writeInt(u32, b[0..4], v, .big);
    return b;
}

fn iconLocation(gpa: std.mem.Allocator, name: []const u8, x: u32, y: u32) !Record {
    const b = try gpa.alloc(u8, 16);
    std.mem.writeInt(u32, b[0..4], x, .big);
    std.mem.writeInt(u32, b[4..8], y, .big);
    b[8..16].* = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0 };
    return .{ .name = name, .code = "Iloc", .kind = .blob, .value = b };
}

/// The .DS_Store of a disk image holding `app` (the bundle's file name)
/// and an Applications link. Allocates from `gpa` (an arena).
pub fn forDiskImage(gpa: std.mem.Allocator, app: []const u8) ![]u8 {
    const bounds = try std.fmt.allocPrint(gpa, "{{{{{d}, {d}}}, {{{d}, {d}}}}}", .{ window.x, window.y, window.width, window.height });
    const bwsp = try binaryPlist(gpa, &.{
        .{ "ShowStatusBar", .{ .bool = false } },      .{ "WindowBounds", .{ .string = bounds } },
        .{ "ContainerShowSidebar", .{ .bool = false } }, .{ "PreviewPaneVisibility", .{ .bool = false } },
        .{ "SidebarWidth", .{ .int = 180 } },           .{ "ShowTabView", .{ .bool = false } },
        .{ "ShowToolbar", .{ .bool = false } },         .{ "ShowPathbar", .{ .bool = false } },
        .{ "ShowSidebar", .{ .bool = false } },
    });
    const icvp = try binaryPlist(gpa, &.{
        .{ "viewOptionsVersion", .{ .int = 1 } },      .{ "backgroundType", .{ .int = 0 } },
        .{ "backgroundColorRed", .{ .float = 1 } },    .{ "backgroundColorGreen", .{ .float = 1 } },
        .{ "backgroundColorBlue", .{ .float = 1 } },   .{ "gridOffsetX", .{ .float = 0 } },
        .{ "gridOffsetY", .{ .float = 0 } },           .{ "gridSpacing", .{ .float = 100 } },
        .{ "arrangeBy", .{ .string = "none" } },       .{ "showIconPreview", .{ .bool = false } },
        .{ "showItemInfo", .{ .bool = false } },       .{ "labelOnBottom", .{ .bool = true } },
        .{ "textSize", .{ .float = 16 } },             .{ "iconSize", .{ .float = window.icon_size } },
        .{ "scrollPositionX", .{ .float = 0 } },       .{ "scrollPositionY", .{ .float = 0 } },
    });
    return encode(gpa, &.{
        .{ .name = ".", .code = "vSrn", .kind = .long, .value = try be32(gpa, 1) },
        .{ .name = ".", .code = "bwsp", .kind = .blob, .value = bwsp },
        .{ .name = ".", .code = "icvp", .kind = .blob, .value = icvp },
        .{ .name = ".", .code = "icvl", .kind = .type, .value = "icnv" }, // icon view
        try iconLocation(gpa, app, window.app[0], window.app[1]),
        try iconLocation(gpa, "Applications", window.applications[0], window.applications[1]),
    });
}

test "the bytes of the ds_store package" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try forDiskImage(arena.allocator(), "Hello MyGo.app");
    try std.testing.expectEqualSlices(u8, @embedFile("testdata/dmg.DS_Store"), got);
}

test binaryPlist {
    const gpa = std.testing.allocator;
    const data = try binaryPlist(gpa, &.{ .{ "a", .{ .bool = true } }, .{ "b", .{ .string = "a" } }, .{ "u", .{ .string = "h\u{e9}" } } });
    defer gpa.free(data);
    try std.testing.expect(std.mem.startsWith(u8, data, "bplist00"));
    // Objects: the dict, keys a, b, u ("a" shared with b's value), true, "hé".
    try std.testing.expectEqual(@as(u64, 6), std.mem.readInt(u64, data[data.len - 24 ..][0..8], .big));
}
