//! SVG's values: numbers as path data and lists write them, lengths with
//! units, colors (hex, rgb(), hsl(), names, currentColor, url(#id)),
//! transforms, `style` declarations, and simple CSS rules from `<style>`
//! (selectors by element, class and id).
const std = @import("std");
const types = @import("types.zig");
const path = @import("path.zig");
const colors = @import("svg_colors.zig");
const xml = @import("svg_xml.zig");
const Color = types.Color;
const Transform = path.Transform;

/// Numbers one after another, as path data and lists write them: spaces
/// and commas between, or nothing ("1.5.5" is 1.5 then .5, "1-2" 1 then -2).
pub const Numbers = struct {
    s: []const u8,
    i: usize = 0,

    pub fn skip(n: *Numbers) void {
        while (n.i < n.s.len and (xml.isSpace(n.s[n.i]) or n.s[n.i] == ',')) n.i += 1;
    }

    pub fn next(n: *Numbers) ?f32 {
        n.skip();
        const len = scan(n.s[n.i..]);
        if (len == 0) return null;
        const v = std.fmt.parseFloat(f32, n.s[n.i..][0..len]) catch return null;
        n.i += len;
        return v;
    }

    /// An arc's flag: a lone 0 or 1, which may be followed by anything.
    pub fn flag(n: *Numbers) ?bool {
        n.skip();
        if (n.i >= n.s.len) return null;
        const ch = n.s[n.i];
        if (ch != '0' and ch != '1') return null;
        n.i += 1;
        return ch == '1';
    }

    pub fn done(n: *Numbers) bool {
        n.skip();
        return n.i >= n.s.len;
    }
};

/// The length of the number at the start of `s`.
fn scan(s: []const u8) usize {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    var digits = false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits = true;
    }
    if (!digits) return 0;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and std.ascii.isDigit(s[j])) {
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            i = j;
        }
    }
    return i;
}

pub fn number(s: []const u8) ?f32 {
    var n: Numbers = .{ .s = std.mem.trim(u8, s, " \t\r\n") };
    return n.next();
}

/// A length in user units (CSS pixels); `percent_of` is what 100% is.
pub fn length(s_in: []const u8, percent_of: f32) ?f32 {
    const s = std.mem.trim(u8, s_in, " \t\r\n");
    const len = scan(s);
    if (len == 0) return null;
    const v = std.fmt.parseFloat(f32, s[0..len]) catch return null;
    const unit = s[len..];
    const k: f32 = if (unit.len == 0 or std.mem.eql(u8, unit, "px")) 1 else if (std.mem.eql(u8, unit, "%")) percent_of / 100 else if (std.mem.eql(u8, unit, "pt")) 4.0 / 3.0 else if (std.mem.eql(u8, unit, "pc")) 16 else if (std.mem.eql(u8, unit, "mm")) 96.0 / 25.4 else if (std.mem.eql(u8, unit, "cm")) 96.0 / 2.54 else if (std.mem.eql(u8, unit, "in")) 96 else if (std.mem.eql(u8, unit, "em")) 16 else if (std.mem.eql(u8, unit, "ex")) 8 else 1;
    return v * k;
}

/// How a shape is painted: not, in a color, in the text's color, or by a
/// gradient (`url(#id)`, with a color for when there is none).
pub const PaintValue = union(enum) {
    none,
    color: Color,
    current,
    url: struct { id: []const u8, fallback: ?Color },
};

pub fn paint(s_in: []const u8) ?PaintValue {
    const s = std.mem.trim(u8, s_in, " \t\r\n");
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(s, "currentColor")) return .current;
    if (std.mem.startsWith(u8, s, "url(")) {
        const close = std.mem.indexOfScalar(u8, s, ')') orelse return null;
        var id = std.mem.trim(u8, s[4..close], " '\"");
        if (id.len > 0 and id[0] == '#') id = id[1..];
        const rest = std.mem.trim(u8, s[close + 1 ..], " ");
        return .{ .url = .{ .id = id, .fallback = if (rest.len > 0) color(rest) else null } };
    }
    return .{ .color = color(s) orelse return null };
}

/// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, `hsl()`,
/// `hsla()`, a name, or `transparent`.
pub fn color(s_in: []const u8) ?Color {
    const s = std.mem.trim(u8, s_in, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '#') {
        const h = s[1..];
        const v = std.fmt.parseInt(u32, h, 16) catch return null;
        return switch (h.len) {
            3 => rgb8(((v >> 8) & 0xf) * 17, ((v >> 4) & 0xf) * 17, (v & 0xf) * 17, 255),
            4 => rgb8(((v >> 12) & 0xf) * 17, ((v >> 8) & 0xf) * 17, ((v >> 4) & 0xf) * 17, (v & 0xf) * 17),
            6 => rgb8((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff, 255),
            8 => rgb8((v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff),
            else => null,
        };
    }
    if (std.ascii.eqlIgnoreCase(s, "transparent")) return Color.transparent;
    const open = std.mem.indexOfScalar(u8, s, '(');
    if (open) |o| {
        const close = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len;
        const fname = s[0..o];
        var parts: [4]f32 = .{ 0, 0, 0, 1 };
        var pct: [4]bool = .{ false, false, false, false };
        var it = std.mem.tokenizeAny(u8, s[o + 1 .. close], " ,/\t");
        var n: usize = 0;
        while (it.next()) |tok| : (n += 1) {
            if (n == 4) break;
            const is_pct = std.mem.endsWith(u8, tok, "%");
            parts[n] = number(if (is_pct) tok[0 .. tok.len - 1] else tok) orelse return null;
            pct[n] = is_pct;
        }
        if (n < 3) return null;
        const a = if (n == 4) (if (pct[3]) parts[3] / 100 else parts[3]) else 1;
        if (std.mem.startsWith(u8, fname, "rgb")) {
            var ch: [3]f32 = undefined;
            for (0..3) |k| ch[k] = std.math.clamp(if (pct[k]) parts[k] / 100 else parts[k] / 255, 0, 1);
            return .{ .r = ch[0], .g = ch[1], .b = ch[2], .a = std.math.clamp(a, 0, 1) };
        }
        if (std.mem.startsWith(u8, fname, "hsl")) return hsl(parts[0], parts[1] / 100, parts[2] / 100, std.math.clamp(a, 0, 1));
        return null;
    }
    const v = colors.named(s) orelse return null;
    return Color.hex(v);
}

fn rgb8(r: u32, g: u32, b: u32, a: u32) Color {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255,
        .g = @as(f32, @floatFromInt(g)) / 255,
        .b = @as(f32, @floatFromInt(b)) / 255,
        .a = @as(f32, @floatFromInt(a)) / 255,
    };
}

fn hsl(h_deg: f32, s: f32, l: f32, a: f32) Color {
    const h = @mod(h_deg, 360) / 360;
    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;
    const f = struct {
        fn hue(pp: f32, qq: f32, t_in: f32) f32 {
            var t = t_in;
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            if (t < 1.0 / 6.0) return pp + (qq - pp) * 6 * t;
            if (t < 0.5) return qq;
            if (t < 2.0 / 3.0) return pp + (qq - pp) * (2.0 / 3.0 - t) * 6;
            return pp;
        }
    }.hue;
    return .{ .r = f(p, q, h + 1.0 / 3.0), .g = f(p, q, h), .b = f(p, q, h - 1.0 / 3.0), .a = a };
}

/// A `transform` attribute: its functions, applied right to left.
pub fn transform(s: []const u8) Transform {
    var t: Transform = .identity;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (xml.isSpace(s[i]) or s[i] == ',')) i += 1;
        const name_start = i;
        while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
        const name = s[name_start..i];
        const open = std.mem.indexOfScalarPos(u8, s, i, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, s, open, ')') orelse break;
        var nums: Numbers = .{ .s = s[open + 1 .. close] };
        var v: [6]f32 = .{ 0, 0, 0, 0, 0, 0 };
        var n: usize = 0;
        while (n < 6) : (n += 1) v[n] = nums.next() orelse break;
        i = close + 1;
        const deg = std.math.pi / 180.0;
        const m: Transform = if (std.mem.eql(u8, name, "matrix") and n == 6)
            .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3], .e = v[4], .f = v[5] }
        else if (std.mem.eql(u8, name, "translate"))
            .translation(v[0], if (n > 1) v[1] else 0)
        else if (std.mem.eql(u8, name, "scale"))
            .scaling(v[0], if (n > 1) v[1] else v[0])
        else if (std.mem.eql(u8, name, "rotate"))
            (if (n >= 3) Transform.translation(-v[1], -v[2]).then(.rotation(v[0] * deg)).then(.translation(v[1], v[2])) else Transform.rotation(v[0] * deg))
        else if (std.mem.eql(u8, name, "skewX"))
            .skewX(v[0] * deg)
        else if (std.mem.eql(u8, name, "skewY"))
            .skewY(v[0] * deg)
        else
            .identity;
        // `a b` is a(b(p)): each new one applies first.
        t = m.then(t);
    }
    return t;
}

/// `name: value` pairs of a `style` attribute or a CSS rule.
pub const Declarations = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn init(s: []const u8) Declarations {
        return .{ .it = std.mem.splitScalar(u8, s, ';') };
    }

    pub fn next(d: *Declarations) ?xml.Attr {
        while (d.it.next()) |decl| {
            const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
            const name = std.mem.trim(u8, decl[0..colon], " \t\r\n");
            var value = std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
            if (std.mem.endsWith(u8, value, "!important")) value = std.mem.trimEnd(u8, value[0 .. value.len - 10], " ");
            if (name.len > 0) return .{ .name = name, .value = value };
        }
        return null;
    }
};

/// A CSS rule of `<style>`: one simple selector (`tag`, `.class`, `#id`,
/// `tag.class`, `*`) and its declarations.
pub const Rule = struct {
    tag: []const u8 = "",
    class: []const u8 = "",
    id: []const u8 = "",
    decls: []const u8,

    pub fn specificity(r: Rule) u32 {
        return @as(u32, if (r.id.len > 0) 100 else 0) + @as(u32, if (r.class.len > 0) 10 else 0) + @as(u32, if (r.tag.len > 0) 1 else 0);
    }

    pub fn matches(r: Rule, e: xml.Element) bool {
        if (r.tag.len > 0 and !std.mem.eql(u8, r.tag, e.name)) return false;
        if (r.id.len > 0 and !std.mem.eql(u8, r.id, e.attr("id") orelse "")) return false;
        if (r.class.len > 0) {
            var classes = std.mem.tokenizeAny(u8, e.attr("class") orelse "", " \t\n");
            while (classes.next()) |cl| {
                if (std.mem.eql(u8, cl, r.class)) return true;
            }
            return false;
        }
        return true;
    }
};

/// The rules of a style sheet; selectors it can't match (descendants,
/// pseudo-classes, attributes) are left out.
pub fn css(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Rule)) !void {
    var i: usize = 0;
    while (i < text.len) {
        // Comments go.
        if (std.mem.startsWith(u8, text[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 2 else text.len;
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, text, i, '{') orelse break;
        const close = std.mem.indexOfScalarPos(u8, text, open, '}') orelse break;
        const selectors = text[i..open];
        const decls = text[open + 1 .. close];
        i = close + 1;
        if (std.mem.indexOf(u8, selectors, "@") != null) continue;
        var sels = std.mem.splitScalar(u8, selectors, ',');
        while (sels.next()) |raw| {
            const sel = std.mem.trim(u8, raw, " \t\r\n");
            if (sel.len == 0 or std.mem.indexOfAny(u8, sel, " >+~:[") != null) continue;
            var r: Rule = .{ .decls = decls };
            if (std.mem.eql(u8, sel, "*")) {} else if (sel[0] == '#') {
                r.id = sel[1..];
            } else if (std.mem.indexOfScalar(u8, sel, '.')) |dot| {
                r.tag = sel[0..dot];
                r.class = sel[dot + 1 ..];
            } else r.tag = sel;
            try out.append(arena, r);
        }
    }
}

test "numbers as path data writes them" {
    var n: Numbers = .{ .s = "1.5.5-2e1,3 -.25e-1 1em" };
    try std.testing.expectEqual(@as(f32, 1.5), n.next().?);
    try std.testing.expectEqual(@as(f32, 0.5), n.next().?);
    try std.testing.expectEqual(@as(f32, -20), n.next().?);
    try std.testing.expectEqual(@as(f32, 3), n.next().?);
    try std.testing.expectApproxEqAbs(@as(f32, -0.025), n.next().?, 1e-6);
    try std.testing.expectEqual(@as(f32, 1), n.next().?);
    try std.testing.expectEqual(@as(?f32, 16), length("1em", 0));
    try std.testing.expectEqual(@as(?f32, 50), length("25%", 200));
}

test "colors and transforms" {
    try std.testing.expectEqual(Color.hex(0xff0000), color("#f00").?);
    try std.testing.expectEqual(Color.hex(0x336699), color("#336699").?);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), color("rgba(0, 0, 255, 0.5)").?.a, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), color("hsl(120, 100%, 50%)").?.g, 1e-5);
    try std.testing.expectEqual(Color.hex(0x008000), color("green").?);
    try std.testing.expectEqualStrings("g1", paint("url(#g1) red").?.url.id);
    const t = transform("translate(10 20) scale(2)");
    const p = t.apply(.{ 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 12), p[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 22), p[1], 1e-5);
    const r = transform("rotate(90, 10, 10)").apply(.{ 20, 10 });
    try std.testing.expectApproxEqAbs(@as(f32, 10), r[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 20), r[1], 1e-4);
}
