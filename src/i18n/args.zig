//! The arguments of messages: their types, as catalogs declare or imply
//! them, checked against the values a call gives, at compile time.
const std = @import("std");
const msg = @import("message.zig");
const render = @import("render.zig");
const DateTime = @import("date.zig").DateTime;

/// The type of an argument, from its placeholder's `type` in the source
/// catalog (String, int, double, num, DateTime, Object), or implied by its
/// use: counted by plural, selectordinal or number, an int; by date or
/// time, a DateTime; else a String.
pub const Type = enum {
    string,
    int,
    number,
    date_time,
    object,

    pub fn ofArb(name: []const u8) ?Type {
        const table = .{ .{ "String", Type.string }, .{ "int", Type.int }, .{ "double", Type.number }, .{ "num", Type.number }, .{ "DateTime", Type.date_time }, .{ "Object", Type.object } };
        inline for (table) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
        return null;
    }

    pub fn implied(use: msg.Use) Type {
        return switch (use) {
            .plural, .number => .int,
            .date => .date_time,
            .plain, .select => .string,
        };
    }

    /// The TypeScript type of the argument in pages.
    pub fn ts(t: Type) []const u8 {
        return switch (t) {
            .string => "string",
            .int, .number => "number",
            .date_time => "Date",
            .object => "unknown",
        };
    }
};

/// A decimal number written as it is, which keeps its fraction digits:
/// `i18n.exact("1.50")` says "1.50", and its plural category is that of
/// two fraction digits.
pub const Exact = struct { text: []const u8 };

pub fn exact(text: []const u8) Exact {
    return .{ .text = text };
}

/// Why `use` of an argument of type `t` is wrong, or null.
pub fn misuse(t: Type, use: msg.Use) ?[]const u8 {
    return switch (use) {
        .plural, .number => if (t == .string or t == .date_time) "is counted as a number but is not one" else null,
        .date => if (t != .date_time and t != .object) "is a date but is not a DateTime" else null,
        .select => if (t == .date_time) "is selected on but is a DateTime" else null,
        .plain => null,
    };
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
            else => false,
        },
        else => false,
    };
}

fn isNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => true,
        else => T == Exact,
    };
}

/// Why a value of type `T` cannot be an argument of type `t`, or null.
pub fn mismatch(comptime t: Type, comptime T: type) ?[]const u8 {
    const string_like = isString(T) or @typeInfo(T) == .@"enum" or @typeInfo(T) == .enum_literal or T == bool;
    return switch (t) {
        .string => if (string_like) null else "takes a string (or an enum, or a bool), not " ++ @typeName(T),
        .int => switch (@typeInfo(T)) {
            .int, .comptime_int => null,
            else => if (T == Exact) null else "takes an integer, not " ++ @typeName(T),
        },
        .number => if (isNumber(T)) null else "takes a number, not " ++ @typeName(T),
        .date_time => if (T == DateTime) null else "takes an i18n.DateTime, not " ++ @typeName(T),
        .object => if (string_like or isNumber(T) or T == DateTime) null else "takes a string, a number or a DateTime, not " ++ @typeName(T),
    };
}

/// The value of an argument.
pub fn value(v: anytype) render.Value {
    const T = @TypeOf(v);
    if (T == Exact) return .{ .exact = v.text };
    if (T == DateTime) return .{ .time = v };
    if (T == bool) return .{ .string = if (v) "true" else "false" };
    if (comptime isString(T)) return .{ .string = v };
    return switch (@typeInfo(T)) {
        .@"enum" => .{ .string = @tagName(v) },
        .enum_literal => .{ .string = @tagName(v) },
        .comptime_int => .{ .int = v },
        .int => |i| if (i.bits < 64 or (i.bits == 64 and i.signedness == .signed))
            .{ .int = v }
        else if (v >= 0 and v <= std.math.maxInt(u64))
            .{ .uint = @intCast(v) }
        else
            .{ .float = @floatFromInt(v) },
        .float, .comptime_float => .{ .float = v },
        else => @compileError("i18n: an argument cannot be a " ++ @typeName(T)),
    };
}
