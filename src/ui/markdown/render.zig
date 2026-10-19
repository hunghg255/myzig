//! A block's inlines as one paragraph of rich text: its text, the spans
//! that draw parts of it their own way (bold, italics, code, links,
//! strikethrough), and where its links are. Spans don't overlap: each run
//! of text carries every style around it.
const std = @import("std");
const types = @import("../types.zig");
const inl = @import("inlines.zig");
const Theme = @import("../theme.zig").Theme;
const Color = types.Color;
const Span = types.Span;

/// The colors and sizes of a view, from the window's theme.
pub const Palette = struct {
    text: Color,
    muted: Color,
    link: Color,
    code: Color,
    code_bg: Color,
    block_bg: Color,
    border: Color,
    header_bg: Color,
    stripe_bg: Color,
    accent: Color,
    dark: bool,

    pub fn of(t: Theme) Palette {
        return .{
            .text = t.text,
            .muted = t.muted,
            .link = t.accent,
            .code = if (t.dark) Color.hex(0xe6a8a8) else Color.hex(0xb3304c),
            .code_bg = t.text.alpha(0.07),
            .block_bg = if (t.dark) Color.hex(0x232326) else Color.hex(0xf0f0f3),
            .border = t.border,
            .header_bg = t.text.alpha(0.05),
            .stripe_bg = t.text.alpha(0.025),
            .accent = t.accent,
            .dark = t.dark,
        };
    }

    /// Changes when anything rendered with it would.
    pub fn key(p: Palette) u64 {
        return std.hash.Wyhash.hash(7, std.mem.asBytes(&p));
    }
};

pub const Link = struct {
    start: u32,
    end: u32,
    url: []const u8,
    /// Its destination is still being written: not to follow yet.
    pending: bool,
};

pub const Rendered = struct {
    text: []u8 = &.{},
    spans: []Span = &.{},
    links: []Link = &.{},
    key: u64 = 0,

    pub fn deinit(r: *Rendered, gpa: std.mem.Allocator) void {
        gpa.free(r.text);
        gpa.free(r.spans);
        gpa.free(r.links);
        r.* = .{};
    }
};

const Style = struct {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strike: bool = false,
    link: bool = false,
    image: bool = false,

    fn plain(s: Style) bool {
        return !(s.bold or s.italic or s.code or s.strike or s.link or s.image);
    }
};

const R = struct {
    gpa: std.mem.Allocator,
    x: *const inl.Inlines,
    pal: Palette,
    text: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    links: std.ArrayList(Link) = .empty,

    fn put(r: *R, s: []const u8, st: Style) void {
        if (s.len == 0) return;
        const a: u32 = @intCast(r.text.items.len);
        r.text.appendSlice(r.gpa, s) catch @panic("OOM");
        if (st.plain()) return;
        const sp: Span = .{
            .start = a,
            .end = @intCast(r.text.items.len),
            .color = if (st.link) r.pal.link else if (st.code) r.pal.code else if (st.image) r.pal.muted else null,
            .weight = if (st.bold) .bold else null,
            .italic = st.italic or st.image,
            .mono = st.code,
            .background = if (st.code) r.pal.code_bg else null,
            .underline = st.link,
            .strike = st.strike,
        };
        // One span for runs styled alike.
        if (r.spans.items.len > 0) {
            const last = &r.spans.items[r.spans.items.len - 1];
            var same = last.*;
            same.start = sp.start;
            same.end = sp.end;
            if (last.end == a and std.meta.eql(same, sp)) {
                last.end = sp.end;
                return;
            }
        }
        r.spans.append(r.gpa, sp) catch @panic("OOM");
    }

    fn walk(r: *R, from: u32, to: u32, st: Style) void {
        var j = from;
        while (j < to) {
            const n = r.x.nodes[j];
            switch (n.kind) {
                .text => r.put(r.x.text(j), st),
                // Raw HTML shows as text, so that nothing hides in it.
                .html => r.put(r.x.text(j), st),
                .softbreak => r.put(" ", st),
                .hardbreak => r.put("\n", .{}),
                .code => {
                    var s = st;
                    s.code = true;
                    r.put(r.x.text(j), s);
                },
                .emph, .strong, .strike => {
                    var s = st;
                    switch (n.kind) {
                        .emph => s.italic = true,
                        .strong => s.bold = true,
                        else => s.strike = true,
                    }
                    r.walk(j + 1, n.next, s);
                },
                .link => {
                    var s = st;
                    s.link = true;
                    const a: u32 = @intCast(r.text.items.len);
                    r.walk(j + 1, n.next, s);
                    r.links.append(r.gpa, .{ .start = a, .end = @intCast(r.text.items.len), .url = r.x.text(j), .pending = n.pending }) catch @panic("OOM");
                },
                .image => {
                    // Its description, until something shows images.
                    var s = st;
                    s.image = true;
                    const a = r.text.items.len;
                    r.walk(j + 1, n.next, s);
                    if (r.text.items.len == a) r.put("image", s);
                },
            }
            j = n.next;
        }
    }
};

/// `x` rendered with `pal`; free with `Rendered.deinit`.
pub fn render(gpa: std.mem.Allocator, x: *const inl.Inlines, pal: Palette) Rendered {
    var r: R = .{ .gpa = gpa, .x = x, .pal = pal };
    r.walk(0, @intCast(x.nodes.len), .{});
    return .{
        .text = r.text.toOwnedSlice(gpa) catch @panic("OOM"),
        .spans = r.spans.toOwnedSlice(gpa) catch @panic("OOM"),
        .links = r.links.toOwnedSlice(gpa) catch @panic("OOM"),
        .key = pal.key(),
    };
}

/// The link at byte `at` of the text, if any.
pub fn linkAt(links: []const Link, at: usize) ?Link {
    for (links) |l| if (at >= l.start and at < l.end) return l;
    return null;
}
