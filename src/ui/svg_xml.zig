//! Just enough XML for SVG files: elements, their attributes (entities
//! decoded) and the text of `<style>`; comments, processing instructions,
//! doctypes and other text are skipped. Elements are kept in document
//! order as a tree of indices.
const std = @import("std");

pub const none = std.math.maxInt(u32);

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Element = struct {
    /// Without a namespace prefix (`svg:path` is `path`).
    name: []const u8,
    attrs: []const Attr,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next: u32 = none,
    /// The text inside it (CDATA included): a `<style>`'s CSS.
    text: []const u8 = "",

    pub fn attr(e: Element, name: []const u8) ?[]const u8 {
        for (e.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    /// `href`, or the older `xlink:href`.
    pub fn href(e: Element) ?[]const u8 {
        return e.attr("href") orelse e.attr("xlink:href");
    }
};

pub const Doc = struct {
    elements: []Element,

    /// The first element whose `id` is `id`.
    pub fn byId(d: Doc, id: []const u8) ?u32 {
        for (d.elements, 0..) |e, i| if (e.attr("id")) |v| if (std.mem.eql(u8, v, id)) return @intCast(i);
        return null;
    }

    pub fn children(d: Doc, i: u32) Children {
        return .{ .doc = d, .at = d.elements[i].first_child };
    }
};

pub const Children = struct {
    doc: Doc,
    at: u32,

    pub fn next(it: *Children) ?u32 {
        if (it.at == none) return null;
        const i = it.at;
        it.at = it.doc.elements[i].next;
        return i;
    }
};

/// Reads `bytes` into elements in `arena` (which keeps every string).
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Doc {
    var els: std.ArrayList(Element) = .empty;
    var stack: std.ArrayList(u32) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const lt = std.mem.indexOfScalarPos(u8, bytes, i, '<') orelse break;
        if (stack.items.len > 0 and lt > i) appendText(&els, stack.items, bytes[i..lt], arena) catch {};
        i = lt;
        if (std.mem.startsWith(u8, bytes[i..], "<!--")) {
            i = after(bytes, i + 4, "-->");
        } else if (std.mem.startsWith(u8, bytes[i..], "<![CDATA[")) {
            const end = std.mem.indexOfPos(u8, bytes, i + 9, "]]>") orelse bytes.len;
            if (stack.items.len > 0) try appendText(&els, stack.items, bytes[i + 9 .. end], arena);
            i = @min(bytes.len, end + 3);
        } else if (std.mem.startsWith(u8, bytes[i..], "<?")) {
            i = after(bytes, i + 2, "?>");
        } else if (std.mem.startsWith(u8, bytes[i..], "<!")) {
            i = skipDecl(bytes, i + 2);
        } else if (std.mem.startsWith(u8, bytes[i..], "</")) {
            i = after(bytes, i + 2, ">");
            _ = stack.pop();
        } else {
            i += 1;
            const name_start = i;
            while (i < bytes.len and !isSpace(bytes[i]) and bytes[i] != '>' and bytes[i] != '/') i += 1;
            var name = bytes[name_start..i];
            if (std.mem.indexOfScalar(u8, name, ':')) |c| name = name[c + 1 ..];
            var attrs: std.ArrayList(Attr) = .empty;
            var self_closing = false;
            while (i < bytes.len) {
                while (i < bytes.len and isSpace(bytes[i])) i += 1;
                if (i >= bytes.len) break;
                if (bytes[i] == '>') {
                    i += 1;
                    break;
                }
                if (bytes[i] == '/') {
                    self_closing = true;
                    i += 1;
                    continue;
                }
                const an = i;
                while (i < bytes.len and bytes[i] != '=' and !isSpace(bytes[i]) and bytes[i] != '>' and bytes[i] != '/') i += 1;
                const aname = bytes[an..i];
                while (i < bytes.len and isSpace(bytes[i])) i += 1;
                if (i >= bytes.len or bytes[i] != '=') {
                    if (aname.len == 0) i += 1;
                    continue;
                }
                i += 1;
                while (i < bytes.len and isSpace(bytes[i])) i += 1;
                if (i >= bytes.len) break;
                const q = bytes[i];
                var value: []const u8 = "";
                if (q == '"' or q == '\'') {
                    const end = std.mem.indexOfScalarPos(u8, bytes, i + 1, q) orelse bytes.len;
                    value = bytes[i + 1 .. end];
                    i = @min(bytes.len, end + 1);
                } else {
                    const vs = i;
                    while (i < bytes.len and !isSpace(bytes[i]) and bytes[i] != '>') i += 1;
                    value = bytes[vs..i];
                }
                try attrs.append(arena, .{ .name = aname, .value = try decode(arena, value) });
            }
            const index: u32 = @intCast(els.items.len);
            const parent = if (stack.items.len > 0) stack.items[stack.items.len - 1] else none;
            try els.append(arena, .{ .name = name, .attrs = attrs.items, .parent = parent });
            if (parent != none) {
                const p = &els.items[parent];
                if (p.last_child == none) p.first_child = index else els.items[p.last_child].next = index;
                p.last_child = index;
            }
            if (!self_closing) try stack.append(arena, index);
        }
    }
    return .{ .elements = els.items };
}

/// Keeps text only where it matters: inside `<style>`.
fn appendText(els: *std.ArrayList(Element), stack: []const u32, s: []const u8, arena: std.mem.Allocator) !void {
    const e = &els.items[stack[stack.len - 1]];
    if (!std.mem.eql(u8, e.name, "style")) return;
    e.text = if (e.text.len == 0) s else try std.mem.concat(arena, u8, &.{ e.text, s });
}

fn after(bytes: []const u8, from: usize, end: []const u8) usize {
    const at = std.mem.indexOfPos(u8, bytes, from, end) orelse return bytes.len;
    return at + end.len;
}

/// Past a `<!DOCTYPE …>`, with its internal subset in brackets.
fn skipDecl(bytes: []const u8, from: usize) usize {
    var depth: usize = 0;
    var i = from;
    while (i < bytes.len) : (i += 1) switch (bytes[i]) {
        '[' => depth += 1,
        ']' => depth -|= 1,
        '>' => if (depth == 0) return i + 1,
        else => {},
    };
    return bytes.len;
}

pub fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// The five named entities and numeric ones.
fn decode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') if (std.mem.indexOfScalarPos(u8, s, i, ';')) |semi| {
            const ent = s[i + 1 .. semi];
            const named = [_]struct { []const u8, u8 }{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' } };
            var done = false;
            for (named) |n| if (std.mem.eql(u8, ent, n[0])) {
                try out.append(arena, n[1]);
                done = true;
            };
            if (!done and ent.len > 1 and ent[0] == '#') {
                const cp = if (ent[1] == 'x') std.fmt.parseInt(u21, ent[2..], 16) catch null else std.fmt.parseInt(u21, ent[1..], 10) catch null;
                if (cp) |v| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(v, &buf) catch 0;
                    try out.appendSlice(arena, buf[0..n]);
                    done = true;
                }
            }
            if (done) {
                i = semi + 1;
                continue;
            }
        };
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

test "elements, attributes, entities, comments and style text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(),
        \\<?xml version="1.0"?>
        \\<!DOCTYPE svg [ <!ENTITY x "y"> ]>
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox='0 0 10 10'>
        \\  <!-- a comment <rect/> -->
        \\  <style><![CDATA[ .a { fill: red } ]]></style>
        \\  <g id="g1" title="a &amp; b &#65;"><rect width="5" height="5"/><svg:circle r="2"/></g>
        \\</svg>
    );
    try std.testing.expectEqual(@as(usize, 5), d.elements.len);
    try std.testing.expectEqualStrings("0 0 10 10", d.elements[0].attr("viewBox").?);
    try std.testing.expectEqualStrings(" .a { fill: red } ", d.elements[1].text);
    const g = d.byId("g1").?;
    try std.testing.expectEqualStrings("a & b A", d.elements[g].attr("title").?);
    var it = d.children(g);
    try std.testing.expectEqualStrings("rect", d.elements[it.next().?].name);
    try std.testing.expectEqualStrings("circle", d.elements[it.next().?].name);
    try std.testing.expect(it.next() == null);
}
