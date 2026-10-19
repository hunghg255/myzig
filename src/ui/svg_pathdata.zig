//! SVG path data (`d`) into a `Path`: every command, absolute and
//! relative, with implicit repeats, smooth curves reflecting the last
//! control point, and arcs. An error stops it where it is, as browsers
//! draw what came before.
const std = @import("std");
const path = @import("path.zig");
const style = @import("svg_style.zig");
const xml = @import("svg_xml.zig");

pub fn parse(d: []const u8, out: *path.Path) void {
    var n: style.Numbers = .{ .s = d };
    var cmd: u8 = 0;
    var cur: path.Point = .{ 0, 0 };
    var start: path.Point = .{ 0, 0 };
    // The last curve's second control point, to reflect for S and T.
    var last_ctrl: ?path.Point = null;
    var last_kind: u8 = 0;
    while (true) {
        n.skip();
        if (n.i >= d.len) break;
        const ch = d[n.i];
        if (std.ascii.isAlphabetic(ch)) {
            cmd = ch;
            n.i += 1;
            if (ch == 'z' or ch == 'Z') {
                out.close();
                cur = start;
                last_ctrl = null;
                last_kind = 'Z';
                continue;
            }
        } else if (cmd == 0) return;
        const rel = std.ascii.isLower(cmd);
        const ox: f32 = if (rel) cur[0] else 0;
        const oy: f32 = if (rel) cur[1] else 0;
        const upper = std.ascii.toUpper(cmd);
        var kind = upper;
        switch (upper) {
            'M' => {
                const x = (n.next() orelse return) + ox;
                const y = (n.next() orelse return) + oy;
                out.moveTo(x, y);
                cur = .{ x, y };
                start = cur;
                // Pairs after a move are lines.
                cmd = if (rel) 'l' else 'L';
                last_ctrl = null;
            },
            'L' => {
                const x = (n.next() orelse return) + ox;
                const y = (n.next() orelse return) + oy;
                out.lineTo(x, y);
                cur = .{ x, y };
            },
            'H' => {
                const x = (n.next() orelse return) + ox;
                out.lineTo(x, cur[1]);
                cur[0] = x;
            },
            'V' => {
                const y = (n.next() orelse return) + oy;
                out.lineTo(cur[0], y);
                cur[1] = y;
            },
            'C', 'S' => {
                var c1: path.Point = undefined;
                if (upper == 'C') {
                    c1 = .{ (n.next() orelse return) + ox, (n.next() orelse return) + oy };
                } else {
                    c1 = if (last_ctrl != null and (last_kind == 'C' or last_kind == 'S')) reflect(last_ctrl.?, cur) else cur;
                }
                const c2: path.Point = .{ (n.next() orelse return) + ox, (n.next() orelse return) + oy };
                const e: path.Point = .{ (n.next() orelse return) + ox, (n.next() orelse return) + oy };
                out.cubicTo(c1[0], c1[1], c2[0], c2[1], e[0], e[1]);
                last_ctrl = c2;
                cur = e;
            },
            'Q', 'T' => {
                var c1: path.Point = undefined;
                if (upper == 'Q') {
                    c1 = .{ (n.next() orelse return) + ox, (n.next() orelse return) + oy };
                } else {
                    c1 = if (last_ctrl != null and (last_kind == 'Q' or last_kind == 'T')) reflect(last_ctrl.?, cur) else cur;
                }
                const e: path.Point = .{ (n.next() orelse return) + ox, (n.next() orelse return) + oy };
                out.quadTo(c1[0], c1[1], e[0], e[1]);
                last_ctrl = c1;
                cur = e;
            },
            'A' => {
                const rx = n.next() orelse return;
                const ry = n.next() orelse return;
                const rot = n.next() orelse return;
                const large = n.flag() orelse return;
                const sweep = n.flag() orelse return;
                const x = (n.next() orelse return) + ox;
                const y = (n.next() orelse return) + oy;
                out.svgArc(rx, ry, rot, large, sweep, x, y);
                cur = .{ x, y };
            },
            else => return,
        }
        if (upper == 'M') kind = 'M';
        last_kind = kind;
    }
}

fn reflect(ctrl: path.Point, about: path.Point) path.Point {
    return .{ 2 * about[0] - ctrl[0], 2 * about[1] - ctrl[1] };
}

test "path data: commands, relative ones, repeats, smooth curves and arcs" {
    const gpa = std.testing.allocator;
    var p: path.Path = .init(gpa);
    defer p.deinit();
    parse("M10 10 20 10l0 10h-10Z m5,5 v2 H1", &p);
    try std.testing.expectEqualSlices(path.Verb, &.{ .move, .line, .line, .line, .close, .move, .line, .line }, p.verbs.items);
    try std.testing.expectEqual(path.Point{ 20, 20 }, p.pts.items[2]);
    // After Z, a relative move starts from the subpath's start.
    try std.testing.expectEqual(path.Point{ 15, 15 }, p.pts.items[4]);
    try std.testing.expectEqual(path.Point{ 1, 17 }, p.pts.items[6]);
    p.reset();
    parse("M0 0C0 10 10 10 10 0S20-10 20 0Q25 5 30 0T40 0", &p);
    try std.testing.expectEqualSlices(path.Verb, &.{ .move, .cubic, .cubic, .quad, .quad }, p.verbs.items);
    // S reflects (10, 10) about (10, 0); T reflects (25, 5) about (30, 0).
    try std.testing.expectEqual(path.Point{ 10, -10 }, p.pts.items[4]);
    try std.testing.expectEqual(path.Point{ 35, -5 }, p.pts.items[9]);
    p.reset();
    parse("M0 0a5 5 0 1010 0", &p);
    try std.testing.expectEqual(path.Point{ 10, 0 }, p.pts.items[p.pts.items.len - 1]);
    p.reset();
    // An error keeps what came before.
    parse("M0 0 L10 10 L oops", &p);
    try std.testing.expectEqual(@as(usize, 2), p.verbs.items.len);
}
