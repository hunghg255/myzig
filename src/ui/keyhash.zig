//! Keys of boxes by what Zig compares (`Context.keyed`), after mygo's: a
//! value keys a box as `std.meta.eql` would tell two apart, with values of
//! different types apart. A pointer keys the object it points to,
//! whatever the object holds, so an item's pointer serves as its key as
//! well as an id does; a string by its bytes; an integer, an enum or a
//! bool by its value; a float by its value too, a NaN and -0 alike with
//! their kin, so a key not equal to itself still keys one box; a struct,
//! an array, an optional or a tagged union by what it holds.
const std = @import("std");

/// The hash of key `k` among the keys of a box's children.
pub fn of(k: anytype) u64 {
    var h = std.hash.Wyhash.init(0x6b6579);
    const T = @TypeOf(k);
    // Strings are strings whatever their type: a literal, a slice, an array.
    if (comptime isString(T)) {
        h.update("s");
        h.update(asString(k));
        return h.final();
    }
    h.update(@typeName(T));
    add(&h, k);
    return h.final();
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |a| a.child == u8,
        else => false,
    };
}

fn asString(k: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(k))) {
        .array => &k,
        else => k,
    };
}

fn add(h: *std.hash.Wyhash, k: anytype) void {
    const T = @TypeOf(k);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            const v: i128 = k;
            h.update(std.mem.asBytes(&v));
        },
        .bool => h.update(if (k) "1" else "0"),
        .@"enum" => add(h, @intFromEnum(k)),
        .float, .comptime_float => {
            // As == compares them: -0 is 0, and every NaN one key.
            const v: f64 = k;
            const bits: u64 = if (std.math.isNan(v)) 0x7ff8000000000000 else if (v == 0) 0 else @bitCast(v);
            h.update(std.mem.asBytes(&bits));
        },
        .pointer => |p| switch (p.size) {
            // The object it points to, not what the object holds.
            .one, .many, .c => {
                const a = @intFromPtr(k);
                h.update(std.mem.asBytes(&a));
            },
            .slice => {
                h.update(std.mem.asBytes(&k.len));
                for (k) |e| add(h, e);
            },
        },
        .array => for (k) |e| add(h, e),
        .optional => if (k) |v| {
            h.update("?");
            add(h, v);
        } else h.update("null"),
        .@"struct" => |s| inline for (s.field_names) |name| add(h, @field(k, name)),
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("myzig: a key of an untagged union cannot be compared: " ++ @typeName(T));
            add(h, std.meta.activeTag(k));
            switch (k) {
                inline else => |v| add(h, v),
            }
        },
        .void, .null => {},
        else => @compileError("myzig: cannot key a box by a " ++ @typeName(T)),
    }
}

test "keys: by value, a pointer by its object, types apart" {
    const Item = struct { name: []const u8, done: bool };
    var a: Item = .{ .name = "a", .done = false };
    var b: Item = .{ .name = "a", .done = false };
    const pa = &a;
    // A pointer keys its object, whatever it holds.
    const before = of(pa);
    a.done = true;
    try std.testing.expectEqual(before, of(pa));
    try std.testing.expect(of(&a) != of(&b));
    // A struct keys by what it holds.
    try std.testing.expectEqual(of(Item{ .name = "x", .done = true }), of(Item{ .name = "x", .done = true }));
    try std.testing.expect(of(Item{ .name = "x", .done = true }) != of(Item{ .name = "x", .done = false }));
    // Strings by their bytes, whatever their type.
    const s: []const u8 = "notes";
    try std.testing.expectEqual(of("notes"), of(s));
    // Integers of different types are different keys.
    try std.testing.expect(of(@as(u32, 5)) != of(@as(u64, 5)));
    try std.testing.expectEqual(of(@as(u32, 5)), of(@as(u32, 5)));
    // A NaN keys one box from frame to frame, and -0 is 0.
    try std.testing.expectEqual(of(std.math.nan(f64)), of(std.math.nan(f64)));
    try std.testing.expectEqual(of(@as(f64, -0.0)), of(@as(f64, 0.0)));
    b.done = true;
}
