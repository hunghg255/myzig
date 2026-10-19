//! The block parser: lines into blocks, as cmark reads them. Each line
//! goes through the blocks still open (block quotes, list items, fences),
//! may open new ones, and its rest becomes the content of a leaf block (a
//! paragraph, a heading, code) or continues a paragraph lazily. Blocks are
//! appended in document order, so a block is closed (its `next` known)
//! before anything after it is added.
const std = @import("std");
const doc = @import("document.zig");
const bs = @import("block_scan.zig");
const scan = @import("scan.zig");
const leaf = @import("block_leaf.zig");
const Document = doc.Document;
const Block = doc.Block;
const Kind = doc.Kind;
const none = doc.none;

fn spaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

pub const Parser = struct {
    d: *Document,
    src: []const u8,
    line: []const u8 = "",
    line_start: u32 = 0,
    line_no: u32 = 0,
    /// The end of the line before, where blocks it closes end.
    prev_end: u32 = 0,
    offset: usize = 0,
    column: usize = 0,
    first_nonspace: usize = 0,
    first_nonspace_column: usize = 0,
    indent: usize = 0,
    blank: bool = false,
    partially_consumed_tab: bool = false,
    /// The deepest block open.
    current: u32 = 0,
    /// The blocks the line did not match are closed once, before the first
    /// block it opens.
    all_closed: bool = true,
    oldtip: u32 = 0,
    last_matched: u32 = 0,
    /// The line opened a fence: its rest is the info string, not code.
    skip_line: bool = false,

    pub fn b(p: *Parser, i: u32) *Block {
        return &p.d.blocks.items[i];
    }

    fn peek(p: *const Parser, i: usize) u8 {
        return if (i < p.line.len) p.line[i] else '\n';
    }

    fn findFirstNonspace(p: *Parser) void {
        var chars_to_tab = 4 - (p.column % 4);
        p.first_nonspace = p.offset;
        p.first_nonspace_column = p.column;
        while (p.first_nonspace < p.line.len) {
            const c = p.line[p.first_nonspace];
            if (c == ' ') {
                p.first_nonspace += 1;
                p.first_nonspace_column += 1;
                chars_to_tab -= 1;
                if (chars_to_tab == 0) chars_to_tab = 4;
            } else if (c == '\t') {
                p.first_nonspace += 1;
                p.first_nonspace_column += chars_to_tab;
                chars_to_tab = 4;
            } else break;
        }
        p.indent = p.first_nonspace_column - p.column;
        p.blank = p.first_nonspace >= p.line.len;
    }

    /// Advances by `count` bytes, or columns (a tab partly consumed).
    pub fn advance(p: *Parser, count_in: usize, columns: bool) void {
        var count = count_in;
        while (count > 0 and p.offset < p.line.len) {
            if (p.line[p.offset] == '\t') {
                const to_tab = 4 - (p.column % 4);
                if (columns) {
                    p.partially_consumed_tab = to_tab > count;
                    const n = @min(count, to_tab);
                    p.column += n;
                    if (!p.partially_consumed_tab) p.offset += 1;
                    count -= n;
                } else {
                    p.partially_consumed_tab = false;
                    p.column += to_tab;
                    p.offset += 1;
                    count -= 1;
                }
            } else {
                p.partially_consumed_tab = false;
                p.offset += 1;
                p.column += 1;
                count -= 1;
            }
        }
    }

    fn processLine(p: *Parser, start: u32, end: u32) void {
        p.line = p.src[start..end];
        p.line_start = start;
        p.line_no += 1;
        p.offset = 0;
        p.column = 0;
        p.blank = false;
        p.partially_consumed_tab = false;
        p.skip_line = false;

        // The blocks still open that the line continues.
        var container: u32 = 0;
        var all_matched = false;
        match: while (true) {
            const lc = p.b(container).p.last_child;
            if (lc == none or !p.b(lc).p.open) {
                all_matched = true;
                break;
            }
            container = lc;
            p.findFirstNonspace();
            switch (p.b(container).kind) {
                .quote => if (!p.quotePrefix()) break :match,
                .item => if (!p.itemPrefix(container)) break :match,
                .code_block => switch (p.codePrefix(container)) {
                    .no => break :match,
                    .yes => {},
                    .closed => {
                        p.current = p.finalize(container, end);
                        return;
                    },
                },
                .html_block => {
                    const t = p.b(container).p.html_type;
                    if ((t == 6 or t == 7) and p.blank) break :match;
                },
                .paragraph, .table => if (p.blank) break :match,
                .heading, .thematic_break => break :match,
                else => {},
            }
        }
        if (!all_matched) container = p.b(container).parent;
        p.last_matched = container;
        p.oldtip = p.current;
        p.all_closed = container == p.current;
        container = p.openNewBlocks(container, all_matched);
        p.addText(container, end);
    }

    fn quotePrefix(p: *Parser) bool {
        if (p.indent > 3 or p.peek(p.first_nonspace) != '>') return false;
        p.advance(p.indent, true);
        p.advance(1, false);
        if (spaceOrTab(p.peek(p.offset))) p.advance(1, true);
        return true;
    }

    fn itemPrefix(p: *Parser, item: u32) bool {
        const it = p.b(item);
        const need = @as(usize, it.p.marker_offset) + it.p.padding;
        if (p.indent >= need) {
            p.advance(need, true);
            return true;
        }
        if (p.blank and it.p.last_child != none) {
            p.advance(p.first_nonspace - p.offset, false);
            return true;
        }
        return false;
    }

    fn codePrefix(p: *Parser, code: u32) enum { no, yes, closed } {
        const cb = p.b(code);
        if (!cb.fenced) {
            if (p.indent >= 4) {
                p.advance(4, true);
                return .yes;
            }
            if (p.blank) {
                p.advance(p.first_nonspace - p.offset, false);
                return .yes;
            }
            return .no;
        }
        if (p.indent <= 3 and p.peek(p.first_nonspace) == cb.p.fence_char and bs.fenceClose(p.line, p.first_nonspace, cb.p.fence_char) >= cb.p.fence_len) return .closed;
        var i = cb.p.fence_offset;
        while (i > 0 and spaceOrTab(p.peek(p.offset))) : (i -= 1) p.advance(1, true);
        return .yes;
    }

    fn openNewBlocks(p: *Parser, container_in: u32, all_matched: bool) u32 {
        var container = container_in;
        var maybe_lazy = p.b(p.current).kind == .paragraph;
        while (true) {
            const ck = p.b(container).kind;
            if (ck == .code_block or ck == .html_block) break;
            p.findFirstNonspace();
            const indented = p.indent >= 4;
            const fns = p.first_nonspace;
            const c = p.peek(fns);
            if (!indented and c == '>') {
                p.advance(fns + 1 - p.offset, false);
                if (spaceOrTab(p.peek(p.offset))) p.advance(1, true);
                container = p.addChild(container, .quote, fns);
            } else if (!indented and bs.atxStart(p.line, fns) > 0) {
                const level = bs.atxStart(p.line, fns);
                p.advance(fns + level - p.offset, false);
                container = p.addChild(container, .heading, fns);
                p.b(container).level = level;
            } else if (!indented and bs.fenceStart(p.line, fns) > 0) {
                const n = bs.fenceStart(p.line, fns);
                const fence_offset = fns - p.offset;
                container = p.addChild(container, .code_block, fns);
                const cb = p.b(container);
                cb.fenced = true;
                cb.p.fence_char = c;
                cb.p.fence_len = @intCast(n);
                cb.p.fence_offset = @intCast(fence_offset);
                const from: u32 = @intCast(p.d.strings.items.len);
                scan.unescapeInto(p.d.gpa, &p.d.strings, std.mem.trim(u8, p.line[fns + n ..], " \t")) catch @panic("OOM");
                p.b(container).info = .{ from, @intCast(p.d.strings.items.len) };
                p.advance(p.line.len - p.offset, false);
                p.skip_line = true;
            } else if (!indented and bs.htmlStart(p.line, fns, ck == .paragraph) > 0) {
                const t = bs.htmlStart(p.line, fns, ck == .paragraph);
                container = p.addChild(container, .html_block, fns);
                p.b(container).p.html_type = t;
            } else if (!indented and ck == .paragraph and p.d.ext.tables and leaf.tableStart(p, &container)) {
                break;
            } else if (!indented and ck == .paragraph and bs.setextLevel(p.line, fns) > 0) {
                const level = bs.setextLevel(p.line, fns);
                if (leaf.resolveDefs(p, container)) {
                    const h = p.b(container);
                    h.kind = .heading;
                    h.level = level;
                    p.advance(p.line.len - p.offset, false);
                }
            } else if (!indented and !(ck == .paragraph and !all_matched) and bs.thematicBreak(p.line, fns)) {
                container = p.addChild(container, .thematic_break, fns);
                p.advance(p.line.len - p.offset, false);
            } else if ((!indented or ck == .list) and p.indent < 4 and bs.listMarker(p.line, fns, ck == .paragraph) != null) {
                const m = bs.listMarker(p.line, fns, ck == .paragraph).?;
                container = p.listItem(container, m);
            } else if (indented and !maybe_lazy and !p.blank and ck != .table) {
                p.advance(4, true);
                container = p.addChild(container, .code_block, p.offset);
            } else break;
            const k = p.b(container).kind;
            if (k == .paragraph or k == .heading or k == .code_block) break;
            maybe_lazy = false;
        }
        return container;
    }

    fn listItem(p: *Parser, container_in: u32, m: bs.ListMarker) u32 {
        var container = container_in;
        const indent = p.indent;
        const fns = p.first_nonspace;
        p.advance(fns + m.len - p.offset, false);
        const save_tab = p.partially_consumed_tab;
        const save_off = p.offset;
        const save_col = p.column;
        while (p.column - save_col <= 5 and spaceOrTab(p.peek(p.offset))) p.advance(1, true);
        const i = p.column - save_col;
        var padding: usize = m.len + i;
        if (i >= 5 or i < 1 or p.offset >= p.line.len) {
            padding = m.len + 1;
            p.partially_consumed_tab = save_tab;
            p.offset = save_off;
            p.column = save_col;
            if (i > 0) p.advance(1, true);
        }
        const list = p.b(container);
        if (list.kind != .list or list.ordered != m.ordered or list.marker != m.marker) {
            container = p.addChild(container, .list, fns);
            const l = p.b(container);
            l.ordered = m.ordered;
            l.marker = m.marker;
            l.number = m.number;
        }
        container = p.addChild(container, .item, fns);
        const it = p.b(container);
        it.p.marker_offset = @intCast(indent);
        it.p.padding = @intCast(padding);
        // A task list item: [ ] or [x] then a space.
        if (p.d.ext.task_lists) {
            const r = p.line[p.offset..];
            if (r.len >= 4 and r[0] == '[' and r[2] == ']' and spaceOrTab(r[3]) and std.mem.trim(u8, r[4..], " \t").len > 0) {
                const t = r[1];
                if (t == ' ' or t == 'x' or t == 'X') {
                    it.task = if (t == ' ') .unchecked else .checked;
                    p.advance(3, false);
                }
            }
        }
        return container;
    }

    /// Closes the blocks the line did not continue, once.
    fn closeUnmatched(p: *Parser) void {
        if (p.all_closed) return;
        while (p.oldtip != p.last_matched) p.oldtip = p.finalize(p.oldtip, p.prev_end);
        p.all_closed = true;
        p.current = p.last_matched;
    }

    fn canContain(parent: Kind, child: Kind) bool {
        return switch (parent) {
            .root, .quote, .item => child != .item,
            .list => child == .item,
            else => false,
        };
    }

    pub fn addChild(p: *Parser, parent_in: u32, kind: Kind, col: usize) u32 {
        p.closeUnmatched();
        var parent = parent_in;
        while (!canContain(p.b(parent).kind, kind)) parent = p.finalize(parent, p.prev_end);
        const d = p.d;
        const i: u32 = @intCast(d.blocks.items.len);
        const seg: u32 = @intCast(d.segs.items.len);
        d.blocks.append(d.gpa, .{
            .kind = kind,
            .parent = parent,
            .start = p.line_start + @as(u32, @intCast(@min(col, p.line.len))),
            .seg_a = seg,
            .seg_b = seg,
            .p = .{ .first_line = p.line_start, .start_line = p.line_no, .seg_mark = seg, .str_mark = @intCast(d.strings.items.len), .align_mark = @intCast(d.aligns.items.len) },
        }) catch @panic("OOM");
        p.b(parent).p.last_child = i;
        p.current = i;
        return i;
    }

    fn addLine(p: *Parser, i: u32) void {
        var pad: u8 = 0;
        if (p.partially_consumed_tab) {
            p.offset += 1;
            pad = @intCast(4 - (p.column % 4));
        }
        const d = p.d;
        d.segs.append(d.gpa, .{ .start = p.line_start + @as(u32, @intCast(@min(p.offset, p.line.len))), .end = p.line_start + @as(u32, @intCast(p.line.len)), .pad = pad }) catch @panic("OOM");
        p.b(i).seg_b = @intCast(d.segs.items.len);
    }

    fn addText(p: *Parser, container_in: u32, end: u32) void {
        var container = container_in;
        p.findFirstNonspace();
        // Blank lines, for lists' tightness.
        const lc = p.b(container).p.last_child;
        if (p.blank and lc != none) p.b(lc).p.last_line_blank = true;
        const cb = p.b(container);
        const last_blank = p.blank and !(cb.kind == .quote or cb.kind == .heading or cb.kind == .thematic_break or (cb.kind == .code_block and cb.fenced) or
            (cb.kind == .item and cb.p.last_child == none and cb.p.start_line == p.line_no));
        cb.p.last_line_blank = last_blank;
        var up = cb.parent;
        while (up != none) : (up = p.b(up).parent) p.b(up).p.last_line_blank = false;

        if (p.current != p.last_matched and container == p.last_matched and !p.blank and p.b(p.current).kind == .paragraph) {
            // A paragraph's lazy continuation.
            p.addLine(p.current);
            return;
        }
        p.closeUnmatched();
        switch (p.b(container).kind) {
            .code_block => if (!p.skip_line) p.addLine(container),
            .html_block => {
                p.addLine(container);
                const t = p.b(container).p.html_type;
                if (t >= 1 and t <= 5 and bs.htmlEnds(p.line[p.first_nonspace..], t)) container = p.finalize(container, end);
            },
            else => if (p.blank) {} else switch (p.b(container).kind) {
                .heading => {
                    const content = bs.atxContent(p.line[p.offset..]);
                    if (content.len > 0) {
                        const at: u32 = @intCast(@intFromPtr(content.ptr) - @intFromPtr(p.line.ptr));
                        p.d.segs.append(p.d.gpa, .{ .start = p.line_start + at, .end = p.line_start + at + @as(u32, @intCast(content.len)) }) catch @panic("OOM");
                        p.b(container).seg_b = @intCast(p.d.segs.items.len);
                    }
                },
                .paragraph => {
                    p.advance(p.first_nonspace - p.offset, false);
                    p.addLine(container);
                },
                .table => leaf.addRow(p, container, p.line_start, p.line, false),
                else => {
                    container = p.addChild(container, .paragraph, p.first_nonspace);
                    p.advance(p.first_nonspace - p.offset, false);
                    p.addLine(container);
                },
            },
        }
        p.current = container;
    }

    /// Closes block `i`, ending at `end`; returns its parent.
    pub fn finalize(p: *Parser, i: u32, end: u32) u32 {
        const d = p.d;
        const blk = p.b(i);
        blk.p.open = false;
        blk.end = @max(blk.start, end);
        blk.next = @intCast(d.blocks.items.len);
        const parent = blk.parent;
        switch (blk.kind) {
            .paragraph => if (!leaf.resolveDefs(p, i)) {
                // Nothing but definitions: no paragraph.
                std.debug.assert(i == d.blocks.items.len - 1);
                d.blocks.shrinkRetainingCapacity(i);
                // Its parent's last child is the one the block before it is in.
                p.b(parent).p.last_child = none;
                if (i > parent + 1) {
                    var j = i - 1;
                    while (p.b(j).parent != parent) j = p.b(j).parent;
                    p.b(parent).p.last_child = j;
                }
            },
            .code_block => if (!blk.fenced) {
                while (blk.seg_b > blk.seg_a) {
                    const sg = d.segs.items[blk.seg_b - 1];
                    if (std.mem.trim(u8, d.src.items[sg.start..sg.end], " \t").len > 0) break;
                    blk.seg_b -= 1;
                }
            },
            .list => leaf.tightness(p, i),
            else => {},
        }
        return parent;
    }

};

/// Parses `d`'s source from `off`, a line's start where nothing but the
/// root is open, to `end`, appending blocks.
pub fn parse(d: *Document, off: u32, end: u32) void {
    const src = d.src.items[0..end];
    d.stats.parsed_bytes += end - off;
    d.restart = off;
    d.restart_at = @intCast(d.blocks.items.len);
    var p: Parser = .{ .d = d, .src = src, .prev_end = off };
    var pos: usize = off;
    while (pos < src.len) {
        var line_end = pos;
        while (line_end < src.len and src[line_end] != '\n' and src[line_end] != '\r') line_end += 1;
        var next = line_end;
        if (next < src.len) {
            next += 1;
            if (src[line_end] == '\r' and next < src.len and src[next] == '\n') next += 1;
        }
        // A line ending in \r at the very end may yet be \r\n.
        const complete = next > line_end and !(next == d.src.items.len and src[next - 1] == '\r');
        p.processLine(@intCast(pos), @intCast(line_end));
        p.prev_end = @intCast(line_end);
        pos = next;
        if (complete) {
            const top = d.blocks.items[0].p.last_child;
            if (top != none and d.blocks.items[top].p.open) {
                d.restart_at = top;
                d.restart = d.blocks.items[top].p.first_line;
            } else {
                d.restart = @intCast(next);
                d.restart_at = @intCast(d.blocks.items.len);
            }
        }
    }
    // What is still open at the end is shown as it is.
    const last = p.current;
    d.tail = none;
    if (last != 0) switch (d.blocks.items[last].kind) {
        .paragraph, .heading => d.tail = last,
        .table => {
            const n: u32 = @intCast(d.blocks.items.len - 1);
            if (d.blocks.items[n].kind == .table_cell) d.tail = n;
        },
        else => {},
    };
    while (p.current != 0) {
        const cur = p.current;
        d.blocks.items[cur].open = true;
        const was = d.blocks.items.len;
        p.current = p.finalize(cur, @intCast(src.len));
        if (d.blocks.items.len < was and d.tail == cur) d.tail = none;
    }
    d.blocks.items[0].next = @intCast(d.blocks.items.len);
    d.blocks.items[0].end = @intCast(src.len);
}
