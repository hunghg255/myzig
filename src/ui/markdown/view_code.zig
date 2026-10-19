//! Code blocks: the language and a Copy button above the code, in the
//! monospaced font, highlighted. Each line is a box of its own, keyed by
//! its number, highlighted from the state the line before left: a block
//! growing as a reply streams in highlights and lays out only its last
//! line again, the lines before keeping what was made of them (taken over
//! from the block before it was parsed again).
const std = @import("std");
const types = @import("../types.zig");
const widgets = @import("../widgets.zig");
const hl = @import("highlight.zig");
const view = @import("view.zig");
const Span = types.Span;

const Line = struct {
    a: u32,
    b: u32,
    /// Its spans in `CodeView.spans`, offsets from `a`.
    sa: u32,
    sb: u32,
    /// The highlighter's state before it.
    state: hl.State,
};

const CodeView = struct {
    lines: std.ArrayList(Line) = .empty,
    spans: std.ArrayList(Span) = .empty,
    key: u64,

    fn deinit(cv: *CodeView, gpa: std.mem.Allocator) void {
        cv.lines.deinit(gpa);
        cv.spans.deinit(gpa);
    }
};

fn freeCode(gpa: std.mem.Allocator, p: *anyopaque) void {
    const cv: *CodeView = @ptrCast(@alignCast(p));
    cv.deinit(gpa);
    gpa.destroy(cv);
}

/// The lines of `content` from line `from` on, highlighted.
fn build(v: *view.V, cv: *CodeView, content: []const u8, lang: []const u8, from: usize) void {
    const gpa = v.gpa();
    var at: usize = 0;
    var state: hl.State = .none;
    if (from < cv.lines.items.len) {
        const ln = cv.lines.items[from];
        at = ln.a;
        state = ln.state;
        cv.spans.shrinkRetainingCapacity(ln.sa);
        cv.lines.shrinkRetainingCapacity(from);
    } else {
        cv.lines.clearRetainingCapacity();
        cv.spans.clearRetainingCapacity();
    }
    const builtin = if (v.opts.syntax and v.opts.highlighter == null) hl.language(lang) else null;
    const colors = hl.Colors.of(v.pal.dark);
    while (true) {
        const e = std.mem.indexOfScalarPos(u8, content, at, '\n') orelse content.len;
        const sa: u32 = @intCast(cv.spans.items.len);
        const s = content[at..e];
        var next = state;
        if (builtin) |l| {
            next = hl.line(gpa, l, s, state, 0, colors, &cv.spans);
        } else if (v.opts.syntax) if (v.opts.highlighter) |h| {
            _ = h.func(h.ctx, gpa, lang, s, v.pal.dark, &cv.spans);
        };
        cv.lines.append(gpa, .{ .a = @intCast(at), .b = @intCast(e), .sa = sa, .sb = @intCast(cv.spans.items.len), .state = state }) catch @panic("OOM");
        state = next;
        if (e >= content.len) break;
        at = e + 1;
    }
}

/// The view of code block `i`, made or brought up to date.
fn codeView(v: *view.V, i: u32, content: []const u8, lang: []const u8) *CodeView {
    const d = v.d;
    const cache = d.cacheOf(i);
    if (cache.view) |p| if (cache.view_free == freeCode) {
        const cv: *CodeView = @ptrCast(@alignCast(p));
        if (cv.key == v.key) return cv;
    };
    cache.dropView(v.gpa());
    var cv: *CodeView = undefined;
    var from: usize = 0;
    // The same block before more of it came: its complete lines stay.
    const old = d.oldCache(cache.at);
    if (old != null and old.?.view_free == freeCode and old.?.view != null and old.?.content.len <= content.len and
        std.mem.eql(u8, old.?.content, content[0..old.?.content.len]))
    {
        cv = @ptrCast(@alignCast(old.?.view.?));
        old.?.view = null;
        if (cv.key == v.key) from = cv.lines.items.len -| 1;
    } else {
        cv = v.gpa().create(CodeView) catch @panic("OOM");
        cv.* = .{ .key = v.key };
    }
    cv.key = v.key;
    cache.view = cv;
    cache.view_free = freeCode;
    build(v, cv, content, lang, from);
    return cv;
}

pub fn block(v: *view.V, i: u32) void {
    const c = v.c;
    const d = v.d;
    const b = d.block(i).*;
    const content = d.cacheOf(i).content;
    const lang = d.language(i);
    const cv = codeView(v, i, content, lang);
    const em = v.em;
    _ = c.open(.{ .width = .fill, .background = v.pal.block_bg, .border = v.pal.border, .radius = 8, .padding = .all(em * 0.75), .gap = em * 0.4, .clip = true }, null);
    defer c.end();
    // Its language, and Copy once it is complete.
    if (lang.len > 0 or !b.open) {
        _ = c.open(.{ .direction = .row, .width = .fill, .align_items = .center, .gap = 8 }, null);
        if (lang.len > 0) _ = c.leaf(.{}, .{ .text = .{ .str = lang, .style = .{ .size = em * 0.8, .weight = .medium }, .color = v.pal.muted } }, null);
        widgets.spacer(c);
        if (!b.open and widgets.button(c, "Copy", .{ .variant = .ghost, .size = em * 0.8 }).clicked) {
            c.clipboard.write(c.clipboard.ctx, content);
            v.result.copied = content;
        }
        c.end();
    }
    const style: types.TextStyle = .{ .size = em * 0.9, .mono = true, .wrap = v.opts.wrap_code, .leading = 1.35 };
    _ = c.open(.{ .width = .fill }, null);
    defer c.end();
    for (cv.lines.items, 0..) |ln, k| {
        c.next_key_int = k;
        const s = if (ln.b > ln.a) content[ln.a..ln.b] else " ";
        _ = v.textLeaf(s, cv.spans.items[ln.sa..ln.sb], style, v.fg);
    }
}

