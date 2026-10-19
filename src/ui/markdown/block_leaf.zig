//! What the block parser does at the ends of blocks: tables made of a
//! paragraph's last line and their rows, link reference definitions taken
//! out of paragraphs, and lists' tightness.
const std = @import("std");
const doc = @import("document.zig");
const bs = @import("block_scan.zig");
const scan = @import("scan.zig");
const Parser = @import("blocks.zig").Parser;
const Block = doc.Block;
const none = doc.none;

/// A delimiter row under a paragraph whose last line has as many
/// cells: that line becomes the header of a table.
pub fn tableStart(p: *Parser, container: *u32) bool {
    var al_buf: [64]doc.Align = undefined;
    const aligns = bs.delimiterRow(p.line[p.first_nonspace..], &al_buf) orelse return false;
    const para = container.*;
    const pb = p.b(para).*;
    if (pb.seg_b == pb.seg_a) return false;
    const hs = p.d.segs.items[pb.seg_b - 1];
    const header = p.src[hs.start..hs.end];
    var cells_buf: [64][2]usize = undefined;
    if (bs.rowCells(header, &cells_buf).len != aligns.len) return false;
    var table: u32 = undefined;
    if (pb.seg_b - pb.seg_a == 1) {
        // The paragraph was the header alone: it becomes the table.
        table = para;
        const t = p.b(table);
        t.kind = .table;
        t.seg_b = t.seg_a;
    } else {
        p.b(para).seg_b -= 1;
        const parent = p.finalize(para, p.prev_end);
        table = p.addChild(parent, .table, 0);
        const t = p.b(table);
        t.start = hs.start;
        t.p.first_line = @intCast(doc.lineStart(p.src, hs.start));
    }
    const t = p.b(table);
    t.align_at = @intCast(p.d.aligns.items.len);
    t.columns = @intCast(aligns.len);
    p.d.aligns.appendSlice(p.d.gpa, aligns) catch @panic("OOM");
    addRow(p, table, hs.start, header, true);
    p.advance(p.line.len - p.offset, false);
    p.current = table;
    container.* = table;
    return true;
}

pub fn addRow(p: *Parser, table: u32, at: u32, line: []const u8, header: bool) void {
    const d = p.d;
    const row: u32 = @intCast(d.blocks.items.len);
    d.blocks.append(d.gpa, .{ .kind = .table_row, .parent = table, .start = at, .end = at + @as(u32, @intCast(line.len)), .header = header, .p = .{ .open = false, .seg_mark = @intCast(d.segs.items.len), .str_mark = @intCast(d.strings.items.len), .align_mark = @intCast(d.aligns.items.len) } }) catch @panic("OOM");
    var cells_buf: [64][2]usize = undefined;
    const cells = bs.rowCells(line, &cells_buf);
    const columns = p.b(table).columns;
    for (0..columns) |k| {
        const idx: u32 = @intCast(d.blocks.items.len);
        const seg_a: u32 = @intCast(d.segs.items.len);
        var cb: Block = .{ .kind = .table_cell, .parent = row, .next = idx + 1, .start = at, .end = at, .seg_a = seg_a, .seg_b = seg_a, .p = .{ .open = false, .seg_mark = seg_a, .str_mark = @intCast(d.strings.items.len), .align_mark = @intCast(d.aligns.items.len) } };
        if (k < cells.len) {
            const cl = cells[k];
            cb.start = at + @as(u32, @intCast(cl[0]));
            cb.end = at + @as(u32, @intCast(cl[1]));
            if (cl[1] > cl[0]) {
                d.segs.append(d.gpa, .{ .start = cb.start, .end = cb.end, .cell = true }) catch @panic("OOM");
                cb.seg_b = seg_a + 1;
            }
        }
        d.blocks.append(d.gpa, cb) catch @panic("OOM");
    }
    p.b(row).next = @intCast(d.blocks.items.len);
    p.b(table).p.last_child = row;
    p.b(table).end = at + @as(u32, @intCast(line.len));
}

pub fn endsWithBlankLine(p: *Parser, i_in: u32) bool {
    var i = i_in;
    while (i != none) {
        const x = p.b(i);
        if (x.p.last_line_blank) return true;
        if (x.kind != .list and x.kind != .item) return false;
        i = x.p.last_child;
    }
    return false;
}

pub fn tightness(p: *Parser, list: u32) void {
    const end = p.b(list).next;
    var item = list + 1;
    while (item < end) : (item = p.b(item).next) {
        const it_next = p.b(item).next;
        const more = it_next < end;
        if (p.b(item).p.last_line_blank and more) {
            p.b(list).tight = false;
            return;
        }
        var sub = item + 1;
        while (sub < it_next) : (sub = p.b(sub).next) {
            if (endsWithBlankLine(p, sub) and (more or p.b(sub).next < it_next)) {
                p.b(list).tight = false;
                return;
            }
        }
    }
}

/// Takes the link reference definitions at the start of paragraph `i`
/// out of it; returns whether content is left.
pub fn resolveDefs(p: *Parser, i: u32) bool {
    const d = p.d;
    const blk = p.b(i).*;
    if (blk.seg_b == blk.seg_a) return false;
    const first = d.src.items[d.segs.items[blk.seg_a].start..d.segs.items[blk.seg_a].end];
    if (first.len == 0 or first[0] != '[') return true;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(d.gpa);
    d.contentInto(i, &content, d.gpa) catch @panic("OOM");
    const s = content.items;
    var pos: usize = 0;
    var lines: u32 = 0;
    var dest: std.ArrayList(u8) = .empty;
    defer dest.deinit(d.gpa);
    var title: std.ArrayList(u8) = .empty;
    defer title.deinit(d.gpa);
    while (pos < s.len and s[pos] == '[') {
        const df = scan.definition(s, pos) orelse break;
        const at = d.segs.items[blk.seg_a + lines].start;
        dest.clearRetainingCapacity();
        title.clearRetainingCapacity();
        scan.unescapeInto(d.gpa, &dest, df.dest) catch @panic("OOM");
        if (df.title) |t| scan.unescapeInto(d.gpa, &title, t) catch @panic("OOM");
        d.define(df.label, dest.items, title.items, at);
        lines += @intCast(std.mem.count(u8, s[pos..df.end], "\n"));
        if (df.end == s.len and (df.end == pos or s[df.end - 1] != '\n')) lines += 1;
        pos = df.end;
    }
    const x = p.b(i);
    x.seg_a = @min(x.seg_b, x.seg_a + lines);
    if (x.seg_a < x.seg_b) x.start = d.segs.items[x.seg_a].start;
    return x.seg_a < x.seg_b;
}
