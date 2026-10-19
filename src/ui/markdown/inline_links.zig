//! Links and images of the inline parser: brackets, inline links and
//! references, autolinks in angle brackets and GitHub's without, and raw
//! HTML tags.
const std = @import("std");
const scan = @import("scan.zig");
const autolink = @import("autolink.zig");
const inl = @import("inlines.zig");
const Parser = inl.Parser;
const none = inl.none;

pub fn pushBracket(p: *Parser, node: u32, image: bool) void {
    if (p.brackets.items.len > 0) p.brackets.items[p.brackets.items.len - 1].bracket_after = true;
    p.brackets.append(p.gpa, .{ .node = node, .prev_delim = p.top, .index = @intCast(p.pos), .image = image }) catch @panic("OOM");
}

pub fn closeBracket(p: *Parser) void {
    const s = p.s;
    p.pos += 1;
    const start_pos = p.pos;
    if (p.brackets.items.len == 0) {
        _ = p.addText("]");
        return;
    }
    const opener = p.brackets.items[p.brackets.items.len - 1];
    if (!opener.active) {
        _ = p.brackets.pop();
        _ = p.addText("]");
        return;
    }
    var dest: ?[]const u8 = null;
    var title: []const u8 = "";
    var from_ref = false;
    // An inline link: (destination "title").
    if (p.pos < s.len and s[p.pos] == '(') {
        var j = scan.spnl(s, p.pos + 1);
        if (scan.linkDestination(s, j)) |dd| {
            j = dd.end;
            const before_title = j;
            j = scan.spnl(s, j);
            var t: ?[]const u8 = null;
            if (j > before_title) if (scan.linkTitle(s, j)) |tt| {
                t = tt.raw;
                j = scan.spnl(s, tt.end);
            };
            if (j < s.len and s[j] == ')') {
                dest = dd.raw;
                title = t orelse "";
                p.pos = j + 1;
            }
        }
    }
    var def: ?@import("document.zig").Def = null;
    if (dest == null) {
        // A reference: [text][label], [text][] or [text].
        var label: ?[]const u8 = null;
        const before_label = p.pos;
        const le = scan.linkLabel(s, p.pos);
        if (le) |e| {
            if (e - before_label > 2) {
                label = s[before_label + 1 .. e - 1];
            } else if (!opener.bracket_after) label = s[opener.index .. start_pos - 1];
            p.pos = e;
        } else if (!opener.bracket_after) label = s[opener.index .. start_pos - 1];
        if (label) |l| if (p.d) |d| {
            p.uses_refs = true;
            var buf: [1024]u8 = undefined;
            def = d.lookup(l, &buf);
        };
        if (def == null) p.pos = start_pos else from_ref = true;
    }
    if (dest == null and def == null) {
        _ = p.brackets.pop();
        _ = p.addText("]");
        return;
    }
    const link = p.newNode(.{ .kind = if (opener.image) .image else .link });
    if (def) |df| {
        const r = p.str(df.dest);
        const t = p.str(df.title);
        p.n(link).a = r[0];
        p.n(link).b = r[1];
        p.n(link).ta = t[0];
        p.n(link).tb = t[1];
    } else {
        const r0: u32 = @intCast(p.buf.items.len);
        scan.unescapeInto(p.gpa, &p.buf, dest.?) catch @panic("OOM");
        const r1: u32 = @intCast(p.buf.items.len);
        scan.unescapeInto(p.gpa, &p.buf, title) catch @panic("OOM");
        const lk = p.n(link);
        lk.a = r0;
        lk.b = r1;
        lk.ta = r1;
        lk.tb = @intCast(p.buf.items.len);
    }
    p.n(link).pending = !from_ref and p.pos > p.heal_from;
    var tmp = p.n(opener.node).next;
    while (tmp != none) {
        const nx = p.n(tmp).next;
        p.unlink(tmp);
        p.appendChild(link, tmp);
        tmp = nx;
    }
    p.appendChild(0, link);
    p.processEmphasis(opener.prev_delim);
    p.unlink(opener.node);
    _ = p.brackets.pop();
    // No links in links.
    if (!opener.image) for (p.brackets.items) |*br| {
        if (!br.image) br.active = false;
    };
}

pub fn angle(p: *Parser) void {
    const s = p.s;
    if (scan.autolink(s, p.pos)) |al| {
        const raw = s[p.pos + 1 .. al.end - 1];
        const link = p.newNode(.{ .kind = .link, .auto = true });
        const r0: u32 = @intCast(p.buf.items.len);
        if (al.email) p.buf.appendSlice(p.gpa, "mailto:") catch @panic("OOM");
        p.buf.appendSlice(p.gpa, raw) catch @panic("OOM");
        p.n(link).a = r0;
        p.n(link).b = @intCast(p.buf.items.len);
        p.appendChild(0, link);
        const t = p.str(raw);
        const tn = p.newNode(.{ .kind = .text, .a = t[0], .b = t[1] });
        p.appendChild(link, tn);
        p.pos = al.end;
        return;
    }
    if (scan.htmlTag(s, p.pos)) |e| {
        const r = p.str(s[p.pos..e]);
        const i = p.newNode(.{ .kind = .html, .a = r[0], .b = r[1] });
        p.appendChild(0, i);
        p.pos = e;
        return;
    }
    p.pos += 1;
    _ = p.addText("<");
}

/// GitHub's autolinks without brackets: www.…, http(s)://… and addresses.
pub fn extAutolink(p: *Parser) bool {
    const s = p.s;
    const c = s[p.pos];
    if (c == '@') {
        // An address: its local part ends the text before, across the
        // runs of _ and - it was cut at.
        var local: usize = 0;
        var k = p.n(0).last;
        while (k != none and p.n(k).kind == .text) : (k = p.n(k).prev) {
            const t = p.buf.items[p.n(k).a..p.n(k).b];
            const run = autolink.localRun(t);
            if (run == 0 or run > p.pos - local or !std.mem.eql(u8, t[t.len - run ..], s[p.pos - local - run .. p.pos - local])) break;
            local += run;
            if (run < t.len) break;
        }
        const end = autolink.email(s, p.pos, local) orelse return false;
        var left = local;
        k = p.n(0).last;
        while (left > 0) : (k = p.n(k).prev) {
            const x = p.n(k);
            const take: u32 = @intCast(@min(left, x.b - x.a));
            x.b -= take;
            left -= take;
        }
        // The delimiters whose runs it took are gone.
        while (p.top != none and p.n(p.delims.items[p.top].node).b <= p.n(p.delims.items[p.top].node).a) p.removeDelim(p.top);
        linkNode(p, s[p.pos - local .. end], "mailto:");
        p.pos = end;
        return true;
    }
    const e = autolink.url(s, p.pos) orelse return false;
    const raw = s[p.pos..e];
    linkNode(p, raw, if (c == 'w') "http://" else "");
    p.pos = e;
    return true;
}

pub fn linkNode(p: *Parser, raw: []const u8, prefix: []const u8) void {
    const link = p.newNode(.{ .kind = .link, .auto = true });
    const r0: u32 = @intCast(p.buf.items.len);
    p.buf.appendSlice(p.gpa, prefix) catch @panic("OOM");
    p.buf.appendSlice(p.gpa, raw) catch @panic("OOM");
    p.n(link).a = r0;
    p.n(link).b = @intCast(p.buf.items.len);
    p.appendChild(0, link);
    const t = p.str(raw);
    p.appendChild(link, p.newNode(.{ .kind = .text, .a = t[0], .b = t[1] }));
}
