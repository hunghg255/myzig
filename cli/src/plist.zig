//! XML property lists (Info.plist), written from the configuration's
//! dynamic values: dictionaries with their keys sorted, as mygo writes
//! them.
const std = @import("std");
const Value = @import("zon.zig").Value;
const Field = @import("zon.zig").Field;

pub const header =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\
;

pub fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(c),
    };
}

fn lessThan(_: void, a: Field, b: Field) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn indent(w: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try w.writeByte('\t');
}

pub fn writeValue(gpa: std.mem.Allocator, w: *std.Io.Writer, v: Value, depth: usize) !void {
    try indent(w, depth);
    switch (v) {
        .object => |fields| {
            const sorted = try gpa.dupe(Field, fields);
            defer gpa.free(sorted);
            std.mem.sort(Field, sorted, {}, lessThan);
            try w.writeAll("<dict>\n");
            for (sorted) |f| {
                try indent(w, depth + 1);
                try w.writeAll("<key>");
                try escape(w, f.key);
                try w.writeAll("</key>\n");
                try writeValue(gpa, w, f.value, depth + 1);
            }
            try indent(w, depth);
            try w.writeAll("</dict>\n");
        },
        .list => |items| {
            try w.writeAll("<array>\n");
            for (items) |x| try writeValue(gpa, w, x, depth + 1);
            try indent(w, depth);
            try w.writeAll("</array>\n");
        },
        .bool => |b| try w.writeAll(if (b) "<true/>\n" else "<false/>\n"),
        .int => |i| try w.print("<integer>{d}</integer>\n", .{i}),
        .float => |f| try w.print("<real>{d}</real>\n", .{f}),
        .string => |s| {
            try w.writeAll("<string>");
            try escape(w, s);
            try w.writeAll("</string>\n");
        },
        .null => try w.writeAll("<string></string>\n"),
    }
}

/// A whole property list document holding `root`.
pub fn document(gpa: std.mem.Allocator, root: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(header);
    try writeValue(gpa, &out.writer, root, 0);
    try out.writer.writeAll("</plist>\n");
    return out.toOwnedSlice();
}

/// A dictionary being built: later keys replace earlier ones.
pub const Dict = struct {
    fields: std.ArrayList(Field) = .empty,

    pub fn put(d: *Dict, gpa: std.mem.Allocator, key: []const u8, v: Value) !void {
        for (d.fields.items) |*f| if (std.mem.eql(u8, f.key, key)) {
            f.value = v;
            return;
        };
        try d.fields.append(gpa, .{ .key = key, .value = v });
    }

    pub fn str(d: *Dict, gpa: std.mem.Allocator, key: []const u8, s: []const u8) !void {
        try d.put(gpa, key, .{ .string = s });
    }

    pub fn value(d: *Dict) Value {
        return .{ .object = d.fields.items };
    }
};

test document {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var d: Dict = .{};
    try d.str(gpa, "b", "x < y & \"z\"");
    try d.put(gpa, "a", .{ .bool = true });
    try d.put(gpa, "c", .{ .list = &.{ .{ .int = 3 }, .{ .string = "s" } } });
    try d.str(gpa, "b", "replaced");
    const doc = try document(gpa, d.value());
    try std.testing.expectEqualStrings(header ++ "<dict>\n" ++
        "\t<key>a</key>\n\t<true/>\n" ++
        "\t<key>b</key>\n\t<string>replaced</string>\n" ++
        "\t<key>c</key>\n\t<array>\n\t\t<integer>3</integer>\n\t\t<string>s</string>\n\t</array>\n" ++
        "</dict>\n</plist>\n", doc);
    var e: std.Io.Writer.Allocating = .init(gpa);
    try escape(&e.writer, "x < y & \"z\"");
    try std.testing.expectEqualStrings("x &lt; y &amp; &quot;z&quot;", e.written());
}
