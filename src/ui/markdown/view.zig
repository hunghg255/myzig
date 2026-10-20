//! Markdown in native UI: `ui.markdown(c, source, .{ .state = &app.md })`
//! shows CommonMark with GitHub's tables, task lists, strikethrough and
//! autolinks, in the window's fonts and colors. Its text is selectable,
//! links report their clicks, and code blocks show in the monospaced font,
//! highlighted, with a Copy button.
//!
//! Give it a `Markdown` kept in the app's state and the source each frame:
//! text appended since the last frame is parsed alone (only the last
//! block still open), the blocks before it keep their boxes, their ids
//! and what was made of them (inlines, rendered text, highlighted lines),
//! so a reply streaming in costs the same per token at its end as at its
//! start. With `streaming`, the end shows what its half-written syntax will
//! most likely become (`**bol` bold, an open fence as code). Without a
//! state, the source is parsed whole, every frame.
//!
//!     if (ui.markdown(c, msg.text, .{ .state = &msg.md, .streaming = !msg.done }).link) |url| open(url);
const std = @import("std");
const types = @import("../types.zig");
const ctx_mod = @import("../context.zig");
const text_mod = @import("../text.zig");
const doc = @import("document.zig");
const render = @import("render.zig");
const code = @import("view_code.zig");
const table = @import("view_table.zig");
const Context = ctx_mod.Context;
const Color = types.Color;
const TextStyle = types.TextStyle;
const Span = types.Span;

pub const Document = doc.Document;
pub const Extensions = doc.Extensions;

/// What a view keeps from frame to frame: the parsed document and what
/// was made of its blocks.
pub const Markdown = struct {
    doc: Document,

    pub fn init(gpa: std.mem.Allocator) Markdown {
        return .{ .doc = .init(gpa, .{}) };
    }

    pub fn deinit(m: *Markdown) void {
        m.doc.deinit();
    }
};

/// Highlights a line of a code block in a language: appends spans of
/// `code` (offsets from its start); returns false for a language it
/// doesn't know.
pub const Highlighter = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, language: []const u8, code: []const u8, dark: bool, out: *std.ArrayList(Span)) bool,
};

pub const Options = struct {
    /// Kept across frames (one per document shown): parses only what
    /// changed. Null parses the source whole each frame.
    state: ?*Markdown = null,
    /// The text is still being written (a model's reply): its end shows
    /// what its syntax will most likely become.
    streaming: bool = false,
    extensions: Extensions = .{},
    /// The size of body text; headings, code and spacing scale with it.
    size: f32 = 14,
    leading: f32 = 1.45,
    selectable: bool = true,
    /// Code blocks wrap their long lines, rather than clipping them.
    wrap_code: bool = true,
    /// Colors code blocks in the languages the highlighter knows.
    syntax: bool = true,
    /// Highlights code instead of the built-in highlighter (Zig, JS/TS,
    /// Go, Python, JSON, shell).
    highlighter: ?Highlighter = null,
    /// A table's columns are at most this wide; their text wraps.
    max_column_width: f32 = 320,
    /// The key of the view's box, as `ui.key` gives.
    key: ?[]const u8 = null,
    /// Reads an image's destination (a local file, as the app resolves
    /// it): it shows under its paragraph, which then leaves out its
    /// description. Null shows descriptions only.
    images: ?ImageReader = null,
};

pub const ImageReader = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, c: *Context, url: []const u8) ?Image,
};

/// An image's encoded bytes (PNG, or what the platform decodes; `svg`
/// for an SVG document), named by `key`; kept by the app while shown.
pub const Image = struct { key: []const u8, bytes: []const u8, svg: bool = false };

pub const Result = struct {
    /// A link clicked this frame: its destination.
    link: ?[]const u8 = null,
    /// The link under the pointer, as a status bar shows it.
    hovered_link: ?[]const u8 = null,
    /// The code a code block's Copy button put on the clipboard.
    copied: ?[]const u8 = null,
};

/// A view being built: shared by the blocks' builders.
pub const V = struct {
    c: *Context,
    d: *Document,
    opts: Options,
    pal: render.Palette,
    key: u64,
    em: f32,
    /// The color of text here (muted in block quotes).
    fg: Color,
    /// How deep in lists, for bullets.
    depth: u32 = 0,
    result: Result = .{},

    pub fn gpa(v: *const V) std.mem.Allocator {
        return v.d.gpa;
    }

    pub fn body(v: *const V) TextStyle {
        return .{ .size = v.em, .leading = v.opts.leading, .wrap = true };
    }

    /// Block `i`'s inlines, rendered and kept.
    pub fn rendered(v: *V, i: u32) *const render.Rendered {
        const x = v.d.inlines(i);
        const cache = v.d.block(i).cache.?;
        if (cache.view) |p| if (cache.view_free == freePara) {
            const r: *render.Rendered = @ptrCast(@alignCast(p));
            if (r.key == v.key) return r;
        };
        cache.dropView(v.gpa());
        const r = v.gpa().create(render.Rendered) catch @panic("OOM");
        r.* = render.render(v.gpa(), x, v.pal);
        cache.view = r;
        cache.view_free = freePara;
        return r;
    }

    fn freePara(g: std.mem.Allocator, p: *anyopaque) void {
        const r: *render.Rendered = @ptrCast(@alignCast(p));
        r.deinit(g);
        g.destroy(r);
    }

    /// A box of text with spans; its index.
    pub fn textLeaf(v: *V, str: []const u8, spans: []const Span, style: TextStyle, color: Color) u32 {
        const width: types.Length = if (style.wrap) .fill else .auto;
        return v.c.leaf(.{ .width = width }, .{ .text = .{ .str = str, .style = style, .color = color, .spans = spans } }, null);
    }

    /// The rendered inlines of block `i` as a paragraph whose links click.
    pub fn paragraph(v: *V, i: u32, style: TextStyle, color: Color) void {
        const r = v.rendered(i);
        var shown: [8]?Image = @splat(null);
        var any = false;
        if (v.opts.images) |ir| for (r.images[0..@min(r.images.len, shown.len)], 0..) |im, k| if (!im.pending) {
            shown[k] = ir.read(ir.ctx, v.c, im.url);
            any = any or shown[k] != null;
        };
        // A paragraph of images alone shows them, not their descriptions.
        if (!any or !imagesOnly(r)) {
            const idx = v.textLeaf(r.text, r.spans, style, color);
            if (r.links.len > 0) v.links(idx, r, style);
        }
        for (shown) |s| if (s) |im| {
            const w = @max(v.c.size.w - 80, 120);
            if (im.svg) _ = @import("../svg.zig").svg(v.c, im.bytes, .{ .width = @min(w, 640), .key = im.key }) else _ = @import("../widgets.zig").image(v.c, .{ .key = im.key, .bytes = im.bytes, .max_width = w, .max_height = 2000, .radius = 4 });
        };
    }

    /// Whether `r` is images and blanks.
    fn imagesOnly(r: *const render.Rendered) bool {
        for (r.text, 0..) |ch, at| {
            if (ch == ' ' or ch == '\n' or ch == '\t') continue;
            var inside = false;
            for (r.images) |im| if (at >= im.start and at < im.end) {
                inside = true;
            };
            if (!inside) return false;
        }
        return true;
    }

    /// Reports the links of text box `idx` under the pointer and clicked.
    pub fn links(v: *V, idx: u32, r: *const render.Rendered, style: TextStyle) void {
        const c = v.c;
        const it = c.interact(idx, .{});
        const over = if (it.hovered) v.linkUnder(idx, r, style) else null;
        if (c.hot == it.id and over == null) c.cursor_hand = false;
        if (over) |l| {
            v.result.hovered_link = l.url;
            if (it.clicked and !l.pending) v.result.link = l.url;
        }
    }

    /// The link under the pointer in text box `idx`, as last laid out.
    fn linkUnder(v: *V, idx: u32, r: *const render.Rendered, style: TextStyle) ?render.Link {
        const c = v.c;
        const rect = c.rects.get(c.node(idx).id) orelse return null;
        const m = c.input.mouse;
        if (!rect.contains(m)) return null;
        const f = c.text.font(style);
        const lh = if (style.leading == 1) f.lineHeight() else @ceil(f.lineHeight() * style.leading);
        const lines = if (style.wrap) c.text.wrapAttributed(r.text, style, r.spans, rect.w) else &[_]text_mod.Line{.{ .start = 0, .end = r.text.len, .width = rect.w }};
        const li: usize = @intFromFloat(@max(0, @floor((m.y - rect.y) / @max(1, lh))));
        if (li >= lines.len) return null;
        const l = lines[li];
        const s = r.text[l.start..l.end];
        const lay = if (text_mod.rich.styled(r.spans)) text_mod.rich.layout(c.text, s, style, r.spans, l.start) else c.text.layout(s, style);
        const x = m.x - rect.x;
        if (x > lay.width) return null;
        var at: ?usize = null;
        for (lay.glyphs) |g| {
            if (g.x <= x) at = l.start + g.index;
        }
        return render.linkAt(r.links, at orelse return null);
    }

    pub fn children(v: *V, i: u32) void {
        var it = v.d.children(i);
        while (it.next()) |j| v.block(j);
    }

    fn block(v: *V, i: u32) void {
        const c = v.c;
        const b = v.d.block(i).*;
        // Keyed by where they start: blocks before the end keep their ids
        // as text is appended.
        c.next_key_int = b.start;
        switch (b.kind) {
            .paragraph => v.paragraph(i, v.body(), v.fg),
            .heading => v.heading(i, b.level),
            .thematic_break => _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = v.pal.border }, .none, null),
            .code_block => code.block(v, i),
            .html_block => {
                const content = v.d.cacheOf(i).content;
                _ = v.textLeaf(content, &.{}, .{ .size = v.em * 0.9, .mono = true, .wrap = true, .leading = 1.3 }, v.pal.muted);
            },
            .quote => {
                _ = c.open(.{ .direction = .row, .width = .fill, .gap = v.em * 0.75, .align_items = .stretch }, null);
                _ = c.leaf(.{ .width = .{ .px = 3 }, .radius = 1.5, .background = v.pal.border }, .none, null);
                _ = c.open(.{ .grow = 1, .gap = v.em * 0.6 }, null);
                const saved = v.fg;
                v.fg = v.pal.muted;
                v.children(i);
                v.fg = saved;
                c.end();
                c.end();
            },
            .list => v.list(i),
            .table => table.block(v, i),
            .root, .item, .table_row, .table_cell => {},
        }
    }

    fn heading(v: *V, i: u32, level: u8) void {
        const scales = [_]f32{ 1.75, 1.45, 1.2, 1.05, 1, 0.9 };
        const l = @min(6, @max(1, level)) - 1;
        const style: TextStyle = .{ .size = v.em * scales[l], .weight = if (level <= 3) .bold else .semibold, .wrap = true, .leading = 1.25 };
        _ = v.c.open(.{ .width = .fill, .gap = v.em * 0.3, .padding = .{ .top = if (level <= 2) v.em * 0.4 else v.em * 0.15 } }, null);
        v.paragraph(i, style, if (level == 6) v.pal.muted else v.fg);
        if (level <= 2) _ = v.c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = v.pal.border }, .none, null);
        v.c.end();
    }

    fn list(v: *V, i: u32) void {
        const c = v.c;
        const b = v.d.block(i).*;
        const gap = if (b.tight) v.em * 0.25 else v.em * 0.6;
        _ = c.open(.{ .width = .fill, .gap = gap }, null);
        v.depth += 1;
        var n = b.number;
        var it = v.d.children(i);
        while (it.next()) |item| : (n += 1) {
            c.next_key_int = v.d.block(item).start;
            _ = c.open(.{ .direction = .row, .width = .fill, .gap = v.em * 0.35 }, null);
            v.marker(b, v.d.block(item).task, n);
            _ = c.open(.{ .grow = 1, .gap = gap }, null);
            v.children(item);
            c.end();
            c.end();
        }
        v.depth -= 1;
        c.end();
    }

    fn marker(v: *V, list_b: doc.Block, task: doc.Task, n: u32) void {
        const c = v.c;
        const lh = @ceil(c.text.font(v.body()).lineHeight() * v.opts.leading);
        const w = if (list_b.ordered) v.em * 1.7 else v.em * 1.1;
        _ = c.open(.{ .direction = .row, .width = .{ .px = w }, .height = .{ .px = lh }, .align_items = .center, .justify = .end }, null);
        defer c.end();
        if (task != .none) {
            const on = task == .checked;
            const s = @round(v.em * 0.95);
            _ = c.open(.{ .width = .{ .px = s }, .height = .{ .px = s }, .radius = 3, .border = if (on) v.pal.accent else v.pal.border, .background = if (on) v.pal.accent else null, .align_items = .center, .justify = .center }, null);
            if (on) _ = c.leaf(.{}, .{ .text = .{ .str = "✓", .style = .{ .size = s * 0.75, .weight = .bold }, .color = Color.white } }, null);
            c.end();
            return;
        }
        if (list_b.ordered) {
            _ = c.leaf(.{}, .{ .text = .{ .str = c.print("{d}{c}", .{ n, list_b.marker }), .style = .{ .size = v.em }, .color = v.pal.muted } }, null);
            return;
        }
        const bullets = [_][]const u8{ "•", "◦", "▪" };
        _ = c.leaf(.{}, .{ .text = .{ .str = bullets[(v.depth - 1) % 3], .style = .{ .size = v.em }, .color = v.pal.muted } }, null);
    }
};

/// Shows `source` as Markdown; see the file's comment.
pub fn markdown(c: *Context, source: []const u8, opts: Options) Result {
    var tmp: Document = undefined;
    var d: *Document = undefined;
    if (opts.state) |st| {
        d = &st.doc;
        if (!std.meta.eql(d.ext, opts.extensions)) d.setExtensions(opts.extensions);
    } else {
        tmp = .init(c.alloc(), opts.extensions);
        d = &tmp;
    }
    d.setStreaming(opts.streaming);
    d.set(source);
    const pal = render.Palette.of(c.theme);
    var v: V = .{ .c = c, .d = d, .opts = opts, .pal = pal, .key = pal.key() ^ @as(u64, @intFromFloat(opts.size * 64)), .em = opts.size, .fg = c.theme.text };
    _ = c.open(.{ .width = .fill, .gap = opts.size * 0.8, .selectable = opts.selectable }, opts.key);
    v.children(0);
    c.end();
    return v.result;
}
