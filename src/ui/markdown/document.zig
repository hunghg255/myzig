//! Markdown parsed: CommonMark with GitHub's tables, task lists,
//! strikethrough and autolinks. Blocks are a flat array in document order,
//! each followed by its children up to its `next`; inlines are parsed per
//! block the first time they are asked for, and kept.
//!
//! Text appended parses again only the outermost block still open before
//! it, or nothing but the new lines when none is: a token costs the same at
//! the end of a long reply as at its start, and the blocks before it are
//! left as they were (their indices, offsets and inlines), so views keep
//! what they made of them. While `streaming`, the end shows what its
//! half-written syntax will most likely become (`heal.zig`) and lines that
//! could still turn into something else wait for what follows them.
const std = @import("std");
const blocks_mod = @import("blocks.zig");
const inlines_mod = @import("inlines.zig");

pub const none: u32 = std.math.maxInt(u32);

pub const Kind = enum(u8) {
    root,
    paragraph,
    heading,
    thematic_break,
    code_block,
    html_block,
    quote,
    list,
    item,
    table,
    table_row,
    table_cell,
};

pub const Task = enum(u8) { none, unchecked, checked };
pub const Align = enum(u8) { none, left, center, right };

/// A line of a leaf block's content: `pad` spaces (from a tab partly
/// taken by indentation), then the source's bytes [start, end), then a
/// newline unless it is the last or a table cell's.
pub const Seg = struct { start: u32, end: u32, pad: u8 = 0, cell: bool = false };

/// What the block parser keeps of a block while it is open.
pub const ParseState = struct {
    open: bool = true,
    last_child: u32 = none,
    last_line_blank: bool = false,
    /// A list item's: the column of its marker and the width to its content.
    marker_offset: u16 = 0,
    padding: u16 = 0,
    fence_char: u8 = 0,
    fence_len: u16 = 0,
    fence_offset: u16 = 0,
    html_type: u8 = 0,
    /// The offset of the line the block started on, and where its line
    /// count started (to tell an item that began with a blank line).
    first_line: u32 = 0,
    start_line: u32 = 0,
    /// `segs.len` and `strings.len` as the block began: what truncating
    /// at it keeps.
    seg_mark: u32 = 0,
    str_mark: u32 = 0,
    align_mark: u32 = 0,
};

pub const Block = struct {
    kind: Kind,
    parent: u32 = none,
    /// The index after the block and its descendants.
    next: u32 = none,
    /// Its bytes in the source: from its first character to the end of
    /// its last line.
    start: u32 = 0,
    end: u32 = 0,
    /// Still open at the end of the source: more text can continue it (a
    /// fence without its closing fence, the paragraph being written).
    open: bool = false,
    /// A heading's, from 1 to 6.
    level: u8 = 0,
    ordered: bool = false,
    /// An ordered list's first number; the bullet (`*`, `-`, `+`) or the
    /// delimiter after numbers (`.`, `)`).
    number: u32 = 0,
    marker: u8 = 0,
    tight: bool = true,
    task: Task = .none,
    fenced: bool = false,
    /// A table's header row.
    header: bool = false,
    /// A table's columns: their alignments in `Document.aligns`.
    align_at: u32 = 0,
    columns: u16 = 0,
    /// A fenced code block's info string, in `Document.strings`.
    info: [2]u32 = .{ 0, 0 },
    /// Its content lines in `Document.segs`.
    seg_a: u32 = 0,
    seg_b: u32 = 0,
    p: ParseState = .{},
    /// What was made of its content (inlines, rendered text), kept.
    cache: ?*Cache = null,
};

/// A link reference definition.
pub const Def = struct { key: []u8, dest: []u8, title: []u8, at: u32 };

/// A block's content and what was made of it: its inlines, and what a
/// view made of those (`render.zig`), until the block changes.
pub const Cache = struct {
    /// Where the content starts in the source, and the content: what a
    /// block parsed again must match to take it over.
    at: u32,
    content: []u8,
    healed: bool = false,
    inl: ?inlines_mod.Inlines = null,
    /// It looked labels up: a definition coming or going parses it again.
    uses_refs: bool = false,
    refs_rev: u32 = 0,
    /// A view's own (rendered text and spans), freed with it.
    view: ?*anyopaque = null,
    view_free: ?*const fn (gpa: std.mem.Allocator, p: *anyopaque) void = null,
    /// Changes whenever its inlines are parsed again.
    rev: u32 = 0,

    fn destroy(cache: *Cache, gpa: std.mem.Allocator) void {
        if (cache.inl) |*i| i.deinit(gpa);
        cache.dropView(gpa);
        gpa.free(cache.content);
        gpa.destroy(cache);
    }

    pub fn dropView(cache: *Cache, gpa: std.mem.Allocator) void {
        if (cache.view) |v| if (cache.view_free) |f| f(gpa, v);
        cache.view = null;
    }
};

pub const Extensions = packed struct {
    tables: bool = true,
    task_lists: bool = true,
    strikethrough: bool = true,
    autolinks: bool = true,

    pub const commonmark: Extensions = .{ .tables = false, .task_lists = false, .strikethrough = false, .autolinks = false };
    pub const gfm: Extensions = .{};
};

/// The work parsing did, for tests and benchmarks.
pub const Stats = struct {
    /// Bytes of source the block parser read, over every parse.
    parsed_bytes: usize = 0,
    /// Inlines parsed, and taken over from a block parsed again.
    inline_parses: usize = 0,
    inline_reused: usize = 0,
};

pub const Document = struct {
    gpa: std.mem.Allocator,
    ext: Extensions = .{},
    src: std.ArrayList(u8) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    segs: std.ArrayList(Seg) = .empty,
    strings: std.ArrayList(u8) = .empty,
    aligns: std.ArrayList(Align) = .empty,
    defs: std.ArrayList(Def) = .empty,
    /// Normalized label → the first definition of it in `defs`.
    refs: std.StringHashMapUnmanaged(u32) = .empty,
    refs_rev: u32 = 0,
    /// Where parsing restarts as text is appended: the offset of the first
    /// line of the outermost block open after the last complete line (or
    /// that line's end), and the index of the first block parsed from there.
    restart: u32 = 0,
    restart_at: u32 = 1,
    streaming: bool = false,
    /// The block holding the end (a paragraph, heading or table cell), or none.
    tail: u32 = none,
    /// Where the source shown ends: text held back while streaming is past it.
    cut: u32 = 0,
    /// Caches of blocks parsed again, to hand to the same blocks.
    old: std.ArrayList(*Cache) = .empty,
    /// The inline parser, its memory kept from block to block.
    inp: ?inlines_mod.Parser = null,
    stats: Stats = .{},

    pub fn init(gpa: std.mem.Allocator, ext: Extensions) Document {
        var d: Document = .{ .gpa = gpa, .ext = ext };
        d.reset();
        return d;
    }

    pub fn deinit(d: *Document) void {
        d.dropBlocks(0);
        d.freeOld();
        for (d.defs.items) |df| d.freeDef(df);
        d.defs.deinit(d.gpa);
        d.refs.deinit(d.gpa);
        d.src.deinit(d.gpa);
        d.blocks.deinit(d.gpa);
        d.segs.deinit(d.gpa);
        d.strings.deinit(d.gpa);
        d.aligns.deinit(d.gpa);
        d.old.deinit(d.gpa);
        if (d.inp) |*p| p.deinit();
    }

    fn reset(d: *Document) void {
        d.dropBlocks(0);
        d.blocks.clearRetainingCapacity();
        d.blocks.append(d.gpa, .{ .kind = .root, .next = 1 }) catch @panic("OOM");
        d.segs.clearRetainingCapacity();
        d.strings.clearRetainingCapacity();
        d.aligns.clearRetainingCapacity();
        for (d.defs.items) |df| d.freeDef(df);
        if (d.defs.items.len > 0) d.refs_rev +%= 1;
        d.defs.clearRetainingCapacity();
        d.refs.clearRetainingCapacity();
        d.restart = 0;
        d.restart_at = 1;
        d.tail = none;
    }

    fn freeDef(d: *Document, df: Def) void {
        d.gpa.free(df.key);
        d.gpa.free(df.dest);
        d.gpa.free(df.title);
    }

    /// Parses `s` with these extensions, whole.
    pub fn parse(gpa: std.mem.Allocator, s: []const u8, ext: Extensions) Document {
        var d = init(gpa, ext);
        d.set(s);
        return d;
    }

    pub fn source(d: *const Document) []const u8 {
        return d.src.items;
    }

    pub fn len(d: *const Document) u32 {
        return @intCast(d.blocks.items.len);
    }

    pub fn block(d: *const Document, i: u32) *Block {
        return &d.blocks.items[i];
    }

    /// The children of block `i`: `var it = d.children(0); while (it.next()) |j| …`.
    pub fn children(d: *const Document, i: u32) Children {
        return .{ .d = d, .at = i + 1, .end = d.blocks.items[i].next };
    }

    pub const Children = struct {
        d: *const Document,
        at: u32,
        end: u32,

        pub fn next(it: *Children) ?u32 {
            if (it.at >= it.end) return null;
            const i = it.at;
            it.at = it.d.blocks.items[i].next;
            return i;
        }
    };

    /// A fenced code block's info string, and its language (its first word).
    pub fn info(d: *const Document, i: u32) []const u8 {
        const b = d.blocks.items[i];
        return d.strings.items[b.info[0]..b.info[1]];
    }

    pub fn language(d: *const Document, i: u32) []const u8 {
        const s = d.info(i);
        const e = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
        return s[0..e];
    }

    /// A table's column alignments.
    pub fn alignments(d: *const Document, table: u32) []const Align {
        const b = d.blocks.items[table];
        return d.aligns.items[b.align_at .. b.align_at + b.columns];
    }

    /// Makes `s` the source, parsing only what changed: text appended to
    /// the last source parses from the restart point; any other change
    /// parses it all again.
    pub fn set(d: *Document, s: []const u8) void {
        const old = d.src.items;
        if (s.len == old.len and std.mem.eql(u8, s, old)) return;
        if (s.len > old.len and std.mem.eql(u8, s[0..old.len], old)) {
            d.append(s[old.len..]);
            return;
        }
        d.src.clearRetainingCapacity();
        d.src.appendSlice(d.gpa, s) catch @panic("OOM");
        d.reset();
        d.parseTail();
    }

    /// Reads other syntax: parses the source again.
    pub fn setExtensions(d: *Document, ext: Extensions) void {
        d.ext = ext;
        d.reset();
        d.parseTail();
    }

    /// Adds text to the end of the source.
    pub fn append(d: *Document, s: []const u8) void {
        if (s.len == 0) return;
        d.src.appendSlice(d.gpa, s) catch @panic("OOM");
        d.parseTail();
    }

    /// Whether the source is text still being written, as a language
    /// model's reply: its end then shows what it will most likely become.
    /// Turn it off once the text is complete, to read its end exactly as
    /// CommonMark does.
    pub fn setStreaming(d: *Document, on: bool) void {
        if (d.streaming == on) return;
        d.streaming = on;
        d.parseTail();
    }

    /// Parses again from the restart point to what is shown.
    fn parseTail(d: *Document) void {
        // The caches of the blocks parsed again last time, not taken.
        d.freeOld();
        d.truncate(d.restart_at, d.restart);
        var cut = d.displayCut();
        blocks_mod.parse(d, d.restart, cut);
        if (d.streaming and d.ext.tables) {
            // A table's header waits for its delimiter row.
            const c = d.heldTableRow(cut);
            if (c < cut) {
                d.truncate(d.restart_at, d.restart);
                blocks_mod.parse(d, d.restart, c);
                cut = c;
            }
        }
        d.cut = cut;
    }

    /// Drops blocks from index `at` (whose first line starts at `off`),
    /// keeping their caches to hand back, and the definitions from there.
    fn truncate(d: *Document, at: u32, off: u32) void {
        if (at < d.blocks.items.len) {
            const b = d.blocks.items[at];
            d.segs.shrinkRetainingCapacity(b.p.seg_mark);
            d.strings.shrinkRetainingCapacity(b.p.str_mark);
            d.aligns.shrinkRetainingCapacity(b.p.align_mark);
            for (d.blocks.items[at..]) |*x| if (x.cache) |cache| {
                d.old.append(d.gpa, cache) catch cache.destroy(d.gpa);
                x.cache = null;
            };
            d.blocks.shrinkRetainingCapacity(at);
        }
        var removed = false;
        while (d.defs.items.len > 0 and d.defs.items[d.defs.items.len - 1].at >= off) {
            const df = d.defs.pop().?;
            const i: u32 = @intCast(d.defs.items.len);
            if (d.refs.get(df.key)) |first| if (first == i) {
                _ = d.refs.remove(df.key);
            };
            d.freeDef(df);
            removed = true;
        }
        if (removed) d.refs_rev +%= 1;
        // The root is open again, after the last top-level block kept.
        const root = &d.blocks.items[0];
        root.p.open = true;
        root.p.last_child = none;
        // The block before the cut is in the last top-level block kept.
        if (d.blocks.items.len > 1) {
            var i: u32 = @intCast(d.blocks.items.len - 1);
            while (d.blocks.items[i].parent != 0) i = d.blocks.items[i].parent;
            root.p.last_child = i;
        }
        root.next = @intCast(d.blocks.items.len);
        d.tail = none;
    }

    fn dropBlocks(d: *Document, at: usize) void {
        if (at >= d.blocks.items.len) return;
        for (d.blocks.items[at..]) |*b| if (b.cache) |cache| {
            cache.destroy(d.gpa);
            b.cache = null;
        };
    }

    fn freeOld(d: *Document) void {
        for (d.old.items) |cache| cache.destroy(d.gpa);
        d.old.clearRetainingCapacity();
    }

    /// Where the source shown ends while streaming: a character half
    /// received, and a last line of only a few markers (as `-` or `==`,
    /// which would make the paragraph above a heading), wait.
    fn displayCut(d: *const Document) u32 {
        const s = d.src.items;
        var n = s.len;
        if (!d.streaming) return @intCast(n);
        var i: usize = 1;
        while (i <= 3 and i <= n) : (i += 1) {
            const c = s[n - i];
            if (c < 0x80) break;
            if (c & 0xC0 != 0x80) {
                const want = std.unicode.utf8ByteSequenceLength(c) catch 1;
                if (want > i) n -= i;
                break;
            }
        }
        const ls = lineStart(s, n);
        const line = std.mem.trim(u8, s[ls..n], " \t");
        if (line.len > 0 and line.len <= 3 and std.mem.trim(u8, line, "-=*+#>|_~`:.)0123456789").len == 0) return @intCast(ls);
        return @intCast(n);
    }

    /// While streaming, a paragraph ending in lines that start with a pipe
    /// may be a table's header whose delimiter row is coming: they wait.
    fn heldTableRow(d: *const Document, cut: u32) u32 {
        const t = d.tail;
        if (t == none or t >= d.blocks.items.len or d.blocks.items[t].kind != .paragraph) return cut;
        const b = d.blocks.items[t];
        var c = cut;
        var i = b.seg_b;
        while (i > b.seg_a) {
            i -= 1;
            const sg = d.segs.items[i];
            const line = std.mem.trimStart(u8, d.src.items[sg.start..sg.end], " \t");
            if (line.len == 0 or line[0] != '|') break;
            c = @intCast(lineStart(d.src.items, sg.start));
        }
        return c;
    }

    /// The content of leaf block `i`: its lines joined by newlines.
    pub fn contentInto(d: *const Document, i: u32, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        const b = d.blocks.items[i];
        for (d.segs.items[b.seg_a..b.seg_b], 0..) |sg, k| {
            if (k > 0 and !sg.cell) try out.append(gpa, '\n');
            try out.appendNTimes(gpa, ' ', sg.pad);
            const s = d.src.items[sg.start..sg.end];
            if (sg.cell) {
                // A cell's \| is a pipe, even in a code span.
                var j: usize = 0;
                while (j < s.len) : (j += 1) {
                    if (s[j] == '\\' and j + 1 < s.len and s[j + 1] == '|') j += 1;
                    try out.append(gpa, s[j]);
                }
            } else try out.appendSlice(gpa, s);
        }
    }

    /// Block `i`'s cache, made (or taken over from the block it was
    /// before being parsed again) the first time it is asked for.
    pub fn cacheOf(d: *Document, i: u32) *Cache {
        const b = &d.blocks.items[i];
        const healed = d.streaming and i == d.tail;
        if (b.cache) |cache| {
            if (cache.healed == healed and !(cache.uses_refs and cache.refs_rev != d.refs_rev)) return cache;
            if (cache.inl) |*inl| inl.deinit(d.gpa);
            cache.inl = null;
            cache.dropView(d.gpa);
            cache.healed = healed;
            cache.rev +%= 1;
            return cache;
        }
        var content: std.ArrayList(u8) = .empty;
        d.contentInto(i, &content, d.gpa) catch @panic("OOM");
        const at: u32 = if (b.seg_b > b.seg_a) d.segs.items[b.seg_a].start else b.start;
        for (d.old.items, 0..) |cache, k| {
            if (cache.at == at and cache.healed == healed and std.mem.eql(u8, cache.content, content.items) and
                !(cache.uses_refs and cache.refs_rev != d.refs_rev))
            {
                _ = d.old.swapRemove(k);
                content.deinit(d.gpa);
                b.cache = cache;
                d.stats.inline_reused += 1;
                return cache;
            }
        }
        const cache = d.gpa.create(Cache) catch @panic("OOM");
        cache.* = .{ .at = at, .content = content.toOwnedSlice(d.gpa) catch @panic("OOM"), .healed = healed };
        b.cache = cache;
        return cache;
    }

    /// The inlines of block `i` (a paragraph, heading or table cell),
    /// parsed the first time they are asked for.
    pub fn inlines(d: *Document, i: u32) *const inlines_mod.Inlines {
        const cache = d.cacheOf(i);
        if (cache.inl == null) {
            d.stats.inline_parses += 1;
            if (d.inp == null) d.inp = .{ .gpa = d.gpa, .d = d };
            d.inp.?.d = d;
            var r = inlines_mod.parseWith(&d.inp.?, cache.content, cache.healed);
            cache.uses_refs = r.uses_refs;
            cache.refs_rev = d.refs_rev;
            cache.inl = r.take();
        }
        return &cache.inl.?;
    }

    /// The cache a block parsed again had, if its content started at `at`
    /// and it was not taken: a view takes over what it made of it (a code
    /// block's lines, as it grows).
    pub fn oldCache(d: *Document, at: u32) ?*Cache {
        for (d.old.items) |cache| if (cache.at == at) return cache;
        return null;
    }

    /// The link a label was defined to, if it was.
    pub fn lookup(d: *const Document, label: []const u8, buf: []u8) ?Def {
        const key = normalizeLabel(label, buf) orelse return null;
        const i = d.refs.get(key) orelse return null;
        return d.defs.items[i];
    }

    pub fn define(d: *Document, label: []const u8, dest: []const u8, title: []const u8, at: u32) void {
        var buf: [1024]u8 = undefined;
        const key = normalizeLabel(label, &buf) orelse return;
        const df: Def = .{
            .key = d.gpa.dupe(u8, key) catch @panic("OOM"),
            .dest = d.gpa.dupe(u8, dest) catch @panic("OOM"),
            .title = d.gpa.dupe(u8, title) catch @panic("OOM"),
            .at = at,
        };
        d.defs.append(d.gpa, df) catch @panic("OOM");
        const gop = d.refs.getOrPut(d.gpa, df.key) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = @intCast(d.defs.items.len - 1);
        d.refs_rev +%= 1;
    }

};

/// A label as definitions match it: case folded (ASCII, Latin, Greek and
/// Cyrillic), runs of whitespace one space, trimmed. Null if it is too
/// long for `buf`.
pub fn normalizeLabel(label: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var space = false;
    const t = std.mem.trim(u8, label, &std.ascii.whitespace);
    var i: usize = 0;
    while (i < t.len) {
        const c = t[i];
        if (std.ascii.isWhitespace(c)) {
            space = true;
            i += 1;
            continue;
        }
        if (n + 8 >= buf.len) return null;
        if (space) {
            buf[n] = ' ';
            n += 1;
            space = false;
        }
        if (c < 0x80) {
            buf[n] = std.ascii.toLower(c);
            n += 1;
            i += 1;
            continue;
        }
        const len = @min(t.len - i, std.unicode.utf8ByteSequenceLength(c) catch 1);
        const cp = std.unicode.utf8Decode(t[i .. i + len]) catch {
            buf[n] = c;
            n += 1;
            i += 1;
            continue;
        };
        i += len;
        if (cp == 0xdf or cp == 0x1e9e) {
            @memcpy(buf[n .. n + 2], "ss");
            n += 2;
            continue;
        }
        const f: u21 = switch (cp) {
            0xc0...0xd6, 0xd8...0xde, 0x391...0x3a1, 0x3a3...0x3a9, 0x410...0x42f => cp + 0x20,
            0x400...0x40f => cp + 0x50,
            0x100...0x17f => if (cp % 2 == 0) cp + 1 else cp,
            else => cp,
        };
        n += std.unicode.utf8Encode(f, buf[n .. n + 4]) catch 0;
    }
    return buf[0..n];
}

pub fn lineStart(s: []const u8, off: usize) usize {
    var i = off;
    while (i > 0 and s[i - 1] != '\n' and s[i - 1] != '\r') i -= 1;
    return i;
}
