//! Dynamic values: SQLite's five storage classes, rows of them, and their
//! form on the wire to pages, where JSON has no 64-bit integers or bytes.
const std = @import("std");

pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

/// A query's result: column names (duplicates kept) and rows of cells in
/// their order.
pub const Rows = struct {
    columns: []const []const u8,
    rows: []const []const Value,
};

/// The cells JSON cannot carry as themselves, on the wire: integers
/// beyond 2^53, blobs, and infinities, sent as strings with their kind.
pub const Special = struct {
    row: u32,
    col: u32,
    kind: enum { bigint, blob, real },
};

/// Rows as pages receive them: plain cells, and the list of those that
/// are not what they seem (`Special`).
pub const WireRows = struct {
    columns: []const []const u8,
    rows: []const []const std.json.Value,
    special: []const Special,
};

const max_safe: i64 = (1 << 53) - 1;

/// The JSON of one cell, and its kind when it is a `Special`.
pub fn toJson(gpa: std.mem.Allocator, v: Value) !struct { std.json.Value, ?@FieldType(Special, "kind") } {
    return switch (v) {
        .null => .{ .null, null },
        .integer => |n| if (n >= -max_safe and n <= max_safe)
            .{ .{ .integer = n }, null }
        else
            .{ .{ .string = try std.fmt.allocPrint(gpa, "{d}", .{n}) }, .bigint },
        .real => |f| if (std.math.isFinite(f))
            .{ .{ .float = f }, null }
        else
            .{ .{ .string = if (std.math.isNan(f)) "NaN" else if (f > 0) "Infinity" else "-Infinity" }, .real },
        .text => |s| .{ .{ .string = s }, null },
        .blob => |b| blk: {
            const enc = std.base64.standard.Encoder;
            const out = try gpa.alloc(u8, enc.calcSize(b.len));
            break :blk .{ .{ .string = enc.encode(out, b) }, .blob };
        },
    };
}

pub fn rowsToWire(gpa: std.mem.Allocator, r: Rows) !WireRows {
    var special: std.ArrayList(Special) = .empty;
    const rows = try gpa.alloc([]const std.json.Value, r.rows.len);
    for (r.rows, rows, 0..) |row, *out, ri| {
        const cells = try gpa.alloc(std.json.Value, row.len);
        for (row, cells, 0..) |v, *c, ci| {
            const j, const kind = try toJson(gpa, v);
            c.* = j;
            if (kind) |k| try special.append(gpa, .{ .row = @intCast(ri), .col = @intCast(ci), .kind = k });
        }
        out.* = cells;
    }
    return .{ .columns = r.columns, .rows = rows, .special = try special.toOwnedSlice(gpa) };
}

pub const ParamError = error{ InvalidParameter, NonFiniteNumber, TooLarge, OutOfMemory };

/// A parameter from a page: null, booleans (0 or 1), numbers, strings, and
/// `{"$bigint": "123"}` and `{"$blob": "base64"}` for what JSON lacks.
pub fn fromJson(gpa: std.mem.Allocator, j: std.json.Value) ParamError!Value {
    return switch (j) {
        .null => .null,
        .bool => |b| .{ .integer = @intFromBool(b) },
        .integer => |n| .{ .integer = n },
        .float => |f| blk: {
            if (!std.math.isFinite(f)) break :blk error.NonFiniteNumber;
            // 3.0 from JavaScript is the integer 3.
            if (f == @trunc(f) and @abs(f) <= @as(f64, @floatFromInt(max_safe))) break :blk .{ .integer = @intFromFloat(f) };
            break :blk .{ .real = f };
        },
        .number_string => error.TooLarge,
        .string => |s| .{ .text = s },
        .object => |o| blk: {
            if (o.count() != 1) break :blk error.InvalidParameter;
            if (o.get("$bigint")) |b| {
                if (b != .string) break :blk error.InvalidParameter;
                break :blk .{ .integer = std.fmt.parseInt(i64, b.string, 10) catch |e| switch (e) {
                    error.Overflow => return error.TooLarge,
                    else => return error.InvalidParameter,
                } };
            }
            if (o.get("$blob")) |b| {
                if (b != .string) break :blk error.InvalidParameter;
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(b.string) catch return error.InvalidParameter;
                const out = try gpa.alloc(u8, n);
                dec.decode(out, b.string) catch return error.InvalidParameter;
                break :blk .{ .blob = out };
            }
            break :blk error.InvalidParameter;
        },
        .array => error.InvalidParameter,
    };
}

pub fn paramsFromJson(gpa: std.mem.Allocator, args: []const std.json.Value) ParamError![]Value {
    const out = try gpa.alloc(Value, args.len);
    for (args, out) |a, *v| v.* = try fromJson(gpa, a);
    return out;
}

test "cells JSON cannot carry travel as strings with their kind" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const row = [_]Value{ .null, .{ .integer = 7 }, .{ .integer = std.math.maxInt(i64) }, .{ .real = 1.5 }, .{ .real = -std.math.inf(f64) }, .{ .text = "hi" }, .{ .blob = "\x00\x01" } };
    const rows = [_][]const Value{&row};
    const w = try rowsToWire(a, .{ .columns = &.{ "a", "b", "c", "d", "e", "f", "g" }, .rows = &rows });
    var aw: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(w, .{}, &aw.writer);
    try std.testing.expectEqualStrings(
        \\{"columns":["a","b","c","d","e","f","g"],"rows":[[null,7,"9223372036854775807",1.5,"-Infinity","hi","AAE="]],"special":[{"row":0,"col":2,"kind":"bigint"},{"row":0,"col":4,"kind":"real"},{"row":0,"col":6,"kind":"blob"}]}
    , aw.written());
}

test "parameters from pages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky([]const std.json.Value, a,
        \\[null, true, 3, 3.0, 2.5, "x", {"$bigint":"-9223372036854775808"}, {"$blob":"AAE="}]
    , .{});
    const v = try paramsFromJson(a, parsed);
    try std.testing.expectEqual(Value.null, v[0]);
    try std.testing.expectEqual(@as(i64, 1), v[1].integer);
    try std.testing.expectEqual(@as(i64, 3), v[2].integer);
    try std.testing.expectEqual(@as(i64, 3), v[3].integer);
    try std.testing.expectEqual(@as(f64, 2.5), v[4].real);
    try std.testing.expectEqualStrings("x", v[5].text);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), v[6].integer);
    try std.testing.expectEqualSlices(u8, "\x00\x01", v[7].blob);
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"$bigint\":\"9223372036854775808\"}", .{});
    try std.testing.expectError(error.TooLarge, fromJson(a, bad));
    try std.testing.expectError(error.InvalidParameter, fromJson(a, try std.json.parseFromSliceLeaky(std.json.Value, a, "[1]", .{})));
}
