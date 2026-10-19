//! The inline parser: a block's content into text, code spans, emphasis,
//! links and images, as commonmark.js reads it (a delimiter stack for
//! emphasis, a bracket stack for links), with GitHub's strikethrough and
//! autolinks. The result is flat, in document order, each inline followed
//! by its children up to its `next`.
const std = @import("std");
const scan = @import("scan.zig");
const links = @import("inline_links.zig");
const heal = @import("heal.zig");
const Document = @import("document.zig").Document;

pub const none = std.math.maxInt(u32);

pub const Kind = enum(u8) { text, softbreak, hardbreak, code, emph, strong, strike, link, image, html };

pub const Inline = struct {
    kind: Kind,
    /// The index after it and its children.
    next: u32,
    /// Text, code and HTML: its text in `buf`; links and images: the destination.
    a: u32 = 0,
    b: u32 = 0,
    /// Links and images: the title, in `buf`.
    ta: u32 = 0,
    tb: u32 = 0,
    /// A link whose destination is still being written (streaming).
    pending: bool = false,
    /// An autolink (`<…>` or GitHub's www., https:// and addresses).
    auto: bool = false,
};

pub const Inlines = struct {
    nodes: []Inline = &.{},
    buf: []u8 = &.{},

    pub fn deinit(x: *Inlines, gpa: std.mem.Allocator) void {
        gpa.free(x.nodes);
        gpa.free(x.buf);
        x.* = .{};
    }

    /// A text's, code span's or HTML's text; a link's destination.
    pub fn text(x: *const Inlines, i: u32) []const u8 {
        return x.buf[x.nodes[i].a..x.nodes[i].b];
    }

    pub fn title(x: *const Inlines, i: u32) []const u8 {
        return x.buf[x.nodes[i].ta..x.nodes[i].tb];
    }
};

/// What parsing gives: the inlines, and whether they looked labels up.
pub const Result = struct {
    inl: Inlines,
    uses_refs: bool,

    pub fn take(r: *Result) Inlines {
        return r.inl;
    }
};

pub const N = struct {
    kind: Kind,
    a: u32 = 0,
    b: u32 = 0,
    ta: u32 = 0,
    tb: u32 = 0,
    parent: u32 = none,
    first: u32 = none,
    last: u32 = none,
    prev: u32 = none,
    next: u32 = none,
    pending: bool = false,
    auto: bool = false,
};

pub const Delim = struct {
    node: u32,
    c: u8,
    n: u32,
    orig: u32,
    at: u32,
    can_open: bool,
    can_close: bool,
    prev: u32 = none,
    next: u32 = none,
};

pub const Bracket = struct {
    node: u32,
    /// The top of the delimiter stack when it was pushed.
    prev_delim: u32,
    /// Where its text starts, after `[` or `![`.
    index: u32,
    image: bool,
    active: bool = true,
    bracket_after: bool = false,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    d: ?*const Document,
    s: []const u8 = "",
    pos: usize = 0,
    nodes: std.ArrayList(N) = .empty,
    buf: std.ArrayList(u8) = .empty,
    delims: std.ArrayList(Delim) = .empty,
    top: u32 = none,
    brackets: std.ArrayList(Bracket) = .empty,
    uses_refs: bool = false,
    /// While healing: where the text added to the source starts, and the
    /// openers left unclosed.
    heal_from: usize = std.math.maxInt(usize),
    leftover: std.ArrayList(Delim) = .empty,
    /// The text healing completes, and the flat inlines being made.
    tmp: std.ArrayList(u8) = .empty,
    out: std.ArrayList(Inline) = .empty,

    pub fn deinit(p: *Parser) void {
        p.tmp.deinit(p.gpa);
        p.out.deinit(p.gpa);
        p.nodes.deinit(p.gpa);
        p.buf.deinit(p.gpa);
        p.delims.deinit(p.gpa);
        p.brackets.deinit(p.gpa);
        p.leftover.deinit(p.gpa);
    }

    fn reset(p: *Parser, s: []const u8) void {
        p.s = s;
        p.pos = 0;
        p.nodes.clearRetainingCapacity();
        p.buf.clearRetainingCapacity();
        p.delims.clearRetainingCapacity();
        p.brackets.clearRetainingCapacity();
        p.leftover.clearRetainingCapacity();
        p.top = none;
        p.nodes.append(p.gpa, .{ .kind = .text }) catch @panic("OOM");
    }

    pub fn n(p: *Parser, i: u32) *N {
        return &p.nodes.items[i];
    }

    pub fn newNode(p: *Parser, node: N) u32 {
        p.nodes.append(p.gpa, node) catch @panic("OOM");
        return @intCast(p.nodes.items.len - 1);
    }

    pub fn appendChild(p: *Parser, parent: u32, c: u32) void {
        const pn = p.n(parent);
        const cn = p.n(c);
        cn.parent = parent;
        cn.prev = pn.last;
        cn.next = none;
        if (pn.last != none) p.n(pn.last).next = c else pn.first = c;
        p.n(parent).last = c;
    }

    pub fn insertAfter(p: *Parser, ref: u32, c: u32) void {
        const r = p.n(ref).*;
        const cn = p.n(c);
        cn.parent = r.parent;
        cn.prev = ref;
        cn.next = r.next;
        if (r.next != none) p.n(r.next).prev = c else p.n(r.parent).last = c;
        p.n(ref).next = c;
    }

    pub fn unlink(p: *Parser, c: u32) void {
        const cn = p.n(c).*;
        if (cn.parent == none) return;
        if (cn.prev != none) p.n(cn.prev).next = cn.next else p.n(cn.parent).first = cn.next;
        if (cn.next != none) p.n(cn.next).prev = cn.prev else p.n(cn.parent).last = cn.prev;
        const x = p.n(c);
        x.parent = none;
        x.prev = none;
        x.next = none;
    }

    pub fn str(p: *Parser, s: []const u8) [2]u32 {
        const a: u32 = @intCast(p.buf.items.len);
        p.buf.appendSlice(p.gpa, s) catch @panic("OOM");
        return .{ a, @intCast(p.buf.items.len) };
    }

    pub fn addText(p: *Parser, s: []const u8) u32 {
        const r = p.str(s);
        const i = p.newNode(.{ .kind = .text, .a = r[0], .b = r[1] });
        p.appendChild(0, i);
        return i;
    }

    pub fn add(p: *Parser, kind: Kind) u32 {
        const i = p.newNode(.{ .kind = kind });
        p.appendChild(0, i);
        return i;
    }

    /// Parses `s` into the tree rooted at node 0.
    pub fn run(p: *Parser, s: []const u8) void {
        p.reset(s);
        while (p.pos < s.len) p.inline1();
        p.processEmphasis(none);
    }

    fn special(p: *Parser, c: u8, at: usize) bool {
        return switch (c) {
            '\n', '\\', '`', '*', '_', '[', ']', '!', '<', '&' => true,
            '~' => p.ext().strikethrough,
            '@' => p.ext().autolinks,
            'w', 'h', 'f' => p.ext().autolinks and @import("autolink.zig").boundary(p.s, at),
            else => false,
        };
    }

    fn ext(p: *const Parser) @import("document.zig").Extensions {
        return if (p.d) |d| d.ext else .{};
    }

    fn inline1(p: *Parser) void {
        const s = p.s;
        const c = s[p.pos];
        switch (c) {
            '\n' => p.newline(),
            '\\' => {
                p.pos += 1;
                if (p.pos < s.len and s[p.pos] == '\n') {
                    _ = p.add(.hardbreak);
                    p.pos += 1;
                    p.skipSpaces();
                } else if (p.pos < s.len and scan.isPunct(s[p.pos])) {
                    _ = p.addText(s[p.pos .. p.pos + 1]);
                    p.pos += 1;
                } else _ = p.addText("\\");
            },
            '`' => p.codeSpan(),
            '*', '_' => p.delimRun(c),
            '~' => if (p.ext().strikethrough) p.delimRun(c) else p.textRun(),
            '[' => {
                p.pos += 1;
                links.pushBracket(p, p.addText("["), false);
            },
            '!' => if (p.pos + 1 < s.len and s[p.pos + 1] == '[') {
                p.pos += 2;
                links.pushBracket(p, p.addText("!["), true);
            } else {
                p.pos += 1;
                _ = p.addText("!");
            },
            ']' => links.closeBracket(p),
            '<' => links.angle(p),
            '&' => {
                var ebuf: [8]u8 = undefined;
                if (scan.entity(s, p.pos, &ebuf)) |e| {
                    _ = p.addText(e.text);
                    p.pos += e.len;
                } else {
                    _ = p.addText("&");
                    p.pos += 1;
                }
            },
            else => if (p.ext().autolinks and links.extAutolink(p)) {} else p.textRun(),
        }
    }

    fn textRun(p: *Parser) void {
        const start = p.pos;
        p.pos += 1;
        while (p.pos < p.s.len and !p.special(p.s[p.pos], p.pos)) p.pos += 1;
        _ = p.addText(p.s[start..p.pos]);
    }

    fn skipSpaces(p: *Parser) void {
        while (p.pos < p.s.len and p.s[p.pos] == ' ') p.pos += 1;
    }

    fn newline(p: *Parser) void {
        p.pos += 1;
        const last = p.n(0).last;
        var hard = false;
        if (last != none and p.n(last).kind == .text) {
            const x = p.n(last);
            var spaces: u32 = 0;
            while (x.b > x.a + spaces and p.buf.items[x.b - 1 - spaces] == ' ') spaces += 1;
            hard = spaces >= 2;
            x.b -= spaces;
        }
        _ = p.add(if (hard) .hardbreak else .softbreak);
        p.skipSpaces();
    }

    fn codeSpan(p: *Parser) void {
        const s = p.s;
        const start = p.pos;
        while (p.pos < s.len and s[p.pos] == '`') p.pos += 1;
        const ticks = p.pos - start;
        var k = p.pos;
        while (std.mem.indexOfScalarPos(u8, s, k, '`')) |at| {
            var e = at;
            while (e < s.len and s[e] == '`') e += 1;
            if (e - at == ticks) {
                const r: u32 = @intCast(p.buf.items.len);
                for (s[p.pos..at]) |ch| p.buf.append(p.gpa, if (ch == '\n') ' ' else ch) catch @panic("OOM");
                var a = r;
                var b: u32 = @intCast(p.buf.items.len);
                const body = p.buf.items[a..b];
                if (body.len >= 2 and body[0] == ' ' and body[body.len - 1] == ' ' and std.mem.trim(u8, body, " ").len > 0) {
                    a += 1;
                    b -= 1;
                }
                const i = p.newNode(.{ .kind = .code, .a = a, .b = b });
                p.appendChild(0, i);
                p.pos = e;
                return;
            }
            k = e;
        }
        _ = p.addText(s[start..p.pos]);
    }

    fn delimRun(p: *Parser, c: u8) void {
        const s = p.s;
        const start = p.pos;
        while (p.pos < s.len and s[p.pos] == c) p.pos += 1;
        const count = p.pos - start;
        const node = p.addText(s[start..p.pos]);
        if (c == '~' and count > 2) return;
        const before = scan.cpBefore(s, start);
        const after = scan.cpAt(s, p.pos);
        const after_ws = scan.isUnicodeSpace(after);
        const after_p = scan.isUnicodePunct(after);
        const before_ws = scan.isUnicodeSpace(before);
        const before_p = scan.isUnicodePunct(before);
        const left = !after_ws and (!after_p or before_ws or before_p);
        const right = !before_ws and (!before_p or after_ws or after_p);
        const can_open = if (c == '_') left and (!right or before_p) else left;
        const can_close = if (c == '_') right and (!left or after_p) else right;
        if (!can_open and !can_close) return;
        const i: u32 = @intCast(p.delims.items.len);
        p.delims.append(p.gpa, .{ .node = node, .c = c, .n = @intCast(count), .orig = @intCast(count), .at = @intCast(start), .can_open = can_open, .can_close = can_close, .prev = p.top }) catch @panic("OOM");
        if (p.top != none) p.delims.items[p.top].next = i;
        p.top = i;
    }

    pub fn removeDelim(p: *Parser, i: u32) void {
        const dl = p.delims.items[i];
        if (dl.prev != none) p.delims.items[dl.prev].next = dl.next;
        if (dl.next != none) p.delims.items[dl.next].prev = dl.prev else p.top = dl.prev;
    }

    pub fn processEmphasis(p: *Parser, bottom: u32) void {
        // The lowest opener to look at, by closer kind: *, _ and ~, whether
        // it can open, and its length modulo 3.
        var openers_bottom: [3][6]u32 = undefined;
        for (&openers_bottom) |*row| @memset(row, bottom);
        // The first delimiter above bottom.
        var closer = p.top;
        if (closer == bottom) closer = none;
        while (closer != none and p.delims.items[closer].prev != bottom) closer = p.delims.items[closer].prev;
        while (closer != none) {
            const cl = p.delims.items[closer];
            if (!cl.can_close) {
                closer = cl.next;
                continue;
            }
            const ci: usize = switch (cl.c) {
                '*' => 0,
                '_' => 1,
                else => 2,
            };
            const oi: usize = (if (cl.can_open) @as(usize, 3) else 0) + cl.orig % 3;
            var opener = cl.prev;
            var found = false;
            while (opener != none and opener != bottom and opener != openers_bottom[ci][oi]) : (opener = p.delims.items[opener].prev) {
                const op = p.delims.items[opener];
                const odd = (cl.can_open or op.can_close) and cl.orig % 3 != 0 and (op.orig + cl.orig) % 3 == 0;
                if (op.c == cl.c and op.can_open and (if (cl.c == '~') op.n == cl.n else !odd)) {
                    found = true;
                    break;
                }
            }
            const old_closer = closer;
            if (found) {
                closer = p.emphasis(opener, closer);
            } else {
                closer = cl.next;
                openers_bottom[ci][oi] = cl.prev;
                if (!cl.can_open) p.removeDelim(old_closer);
            }
        }
        // Those left are text; healing completes them.
        var x = p.top;
        while (x != none and x != bottom) {
            const dl = p.delims.items[x];
            if (bottom == none and dl.can_open and dl.n > 0) p.leftover.append(p.gpa, dl) catch {};
            p.removeDelim(x);
            x = dl.prev;
        }
    }

    /// Wraps what is between opener and closer in emphasis; returns the
    /// next closer to look at.
    fn emphasis(p: *Parser, opener: u32, closer: u32) u32 {
        const op = &p.delims.items[opener];
        const cl = &p.delims.items[closer];
        const use: u32 = if (cl.c == '~') cl.n else if (cl.n >= 2 and op.n >= 2) 2 else 1;
        op.n -= use;
        cl.n -= use;
        const on = op.node;
        const cn = cl.node;
        p.n(on).b -= use;
        p.n(cn).a += use;
        const kind: Kind = if (cl.c == '~') .strike else if (use == 1) .emph else .strong;
        const e = p.newNode(.{ .kind = kind });
        var tmp = p.n(on).next;
        while (tmp != none and tmp != cn) {
            const nx = p.n(tmp).next;
            p.unlink(tmp);
            p.appendChild(e, tmp);
            tmp = nx;
        }
        p.insertAfter(on, e);
        // The delimiters between them are gone.
        var between = p.delims.items[closer].prev;
        while (between != none and between != opener) {
            const pv = p.delims.items[between].prev;
            p.removeDelim(between);
            between = pv;
        }
        if (p.delims.items[opener].n == 0) {
            p.unlink(on);
            p.removeDelim(opener);
        }
        if (p.delims.items[closer].n == 0) {
            p.unlink(cn);
            const nx = p.delims.items[closer].next;
            p.removeDelim(closer);
            return nx;
        }
        return closer;
    }

    /// The tree, flat in document order, without empty text.
    pub fn flatten(p: *Parser) Inlines {
        p.out.clearRetainingCapacity();
        p.flattenChildren(0, &p.out);
        return .{
            .nodes = p.gpa.dupe(Inline, p.out.items) catch @panic("OOM"),
            .buf = p.gpa.dupe(u8, p.buf.items) catch @panic("OOM"),
        };
    }

    fn flattenChildren(p: *Parser, parent: u32, out: *std.ArrayList(Inline)) void {
        var c = p.n(parent).first;
        while (c != none) : (c = p.n(c).next) {
            const x = p.n(c).*;
            if (x.kind == .text and x.b <= x.a) continue;
            const at = out.items.len;
            out.append(p.gpa, .{ .kind = x.kind, .next = 0, .a = x.a, .b = x.b, .ta = x.ta, .tb = x.tb, .pending = x.pending, .auto = x.auto }) catch @panic("OOM");
            p.flattenChildren(c, out);
            out.items[at].next = @intCast(out.items.len);
        }
    }
};

/// Parses a block's content, trimmed. `healed` completes what its end
/// leaves open, as the end of a document still being written.
pub fn parse(d: ?*const Document, content: []const u8, healed: bool) Result {
    var p: Parser = .{ .gpa = if (d) |x| x.gpa else std.heap.page_allocator, .d = d };
    defer p.deinit();
    return parseWith(&p, content, healed);
}

/// As `parse`, with a parser kept from block to block, its memory reused.
pub fn parseWith(p: *Parser, content: []const u8, healed: bool) Result {
    p.uses_refs = false;
    p.heal_from = std.math.maxInt(usize);
    const s = std.mem.trim(u8, content, " \t\n");
    if (healed) heal.complete(p, s, &p.tmp) else p.run(s);
    return .{ .inl = p.flatten(), .uses_refs = p.uses_refs };
}
