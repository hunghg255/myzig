//! Markdown shortcuts: what is typed formats itself. At a paragraph's
//! start, `# ` to `### ` make headings, `- `, `* ` and `+ ` bulleted lists,
//! `1. ` numbered ones, `[ ] ` and `[x] ` tasks and `> ` a quotation;
//! ```` ``` ```` then Enter a block of code. Around words, `**bold**`,
//! `*italic*`, `_italic_`, `` `code` `` and `~~struck~~` format what they
//! hold as the closing mark is typed; an underscore inside a word, as in
//! `snake_case`, stays one. Each is a step of undo of its own, which takes
//! it back to what was typed.
const std = @import("std");
const model = @import("model.zig");
const RichText = @import("editor.zig").RichText;
const Kind = model.Kind;
const BlockStyle = model.BlockStyle;

const Prefix = struct { text: []const u8, style: BlockStyle };

const prefixes = [_]Prefix{
    .{ .text = "#", .style = .{ .kind = .heading1 } },
    .{ .text = "##", .style = .{ .kind = .heading2 } },
    .{ .text = "###", .style = .{ .kind = .heading3 } },
    .{ .text = "-", .style = .{ .kind = .bullet } },
    .{ .text = "*", .style = .{ .kind = .bullet } },
    .{ .text = "+", .style = .{ .kind = .bullet } },
    .{ .text = "1.", .style = .{ .kind = .numbered } },
    .{ .text = "[]", .style = .{ .kind = .task } },
    .{ .text = "[ ]", .style = .{ .kind = .task } },
    .{ .text = "[x]", .style = .{ .kind = .task, .checked = true } },
    .{ .text = ">", .style = .{ .kind = .quote } },
};

/// After a character was typed at the caret: the shortcut it completes.
pub fn typed(rt: *RichText) void {
    const p = rt.sel.caret;
    const b = rt.doc.block(p.block);
    if (b.style.kind == .code or p.off == 0) return;
    const s = b.str()[0..p.off];
    const last = s[s.len - 1];
    if (last == ' ' and b.style.kind == .paragraph) {
        for (prefixes) |px| if (std.mem.eql(u8, s[0 .. s.len - 1], px.text)) {
            rt.begin(.other, p.block, p.block + 1);
            b.remove(rt.doc.gpa, 0, s.len);
            var st = px.style;
            st.indent = b.style.indent;
            b.setStyle(st);
            rt.sel = .at(.{ .block = p.block });
            rt.end(p.block + 1);
            rt.history.breakGroup();
            return;
        };
    }
    switch (last) {
        '`' => wrap(rt, "`", .code),
        '*' => if (s.len >= 2 and s[s.len - 2] == '*') wrap(rt, "**", .bold) else wrap(rt, "*", .italic),
        '_' => wrap(rt, "_", .italic),
        '~' => if (s.len >= 2 and s[s.len - 2] == '~') wrap(rt, "~~", .strike),
        else => {},
    }
}

/// Formats what `delim` holds before the caret, the delimiters taken away.
fn wrap(rt: *RichText, delim: []const u8, t: model.Toggle) void {
    const p = rt.sel.caret;
    const b = rt.doc.block(p.block);
    const s = b.str()[0..p.off];
    const close = s.len - delim.len;
    // The mark held must start and end with something other than a space.
    if (close == 0 or s[close - 1] == ' ') return;
    if (delim.len == 1 and delim[0] != '`' and s[close - 1] == delim[0]) return;
    // In code, only a backtick closes.
    if (b.marksAt(close - 1).code) return;
    const open = std.mem.lastIndexOf(u8, s[0..close], delim) orelse return;
    const inner = open + delim.len;
    if (inner >= close or s[inner] == ' ') return;
    if (delim.len == 1 and open > 0 and s[open - 1] == delim[0]) return;
    // `snake_case` stays: an underscore opens only at a word's start.
    if (delim[0] == '_' and open > 0 and isWord(s[open - 1])) return;
    const gpa = rt.doc.gpa;
    rt.begin(.other, p.block, p.block + 1);
    b.remove(gpa, close, p.off);
    b.remove(gpa, open, inner);
    const e = close - delim.len;
    b.format(gpa, open, e, model.toggleMark(t, true));
    rt.sel = .at(.{ .block = p.block, .off = e });
    rt.end(p.block + 1);
    rt.history.breakGroup();
    // What follows is typed outside it.
    var m = b.marksAt(e - 1);
    model.toggleMark(t, false).apply(&m);
    rt.typing = m.extending();
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Enter on a paragraph of ```` ``` ```` (and a language): a block of code.
pub fn fence(rt: *RichText) bool {
    if (!rt.sel.empty()) return false;
    const p = rt.sel.caret;
    const b = rt.doc.block(p.block);
    if (b.style.kind != .paragraph or p.off != b.len() or !std.mem.startsWith(u8, b.str(), "```")) return false;
    if (std.mem.indexOfScalar(u8, b.str()[3..], ' ') != null or std.mem.indexOfScalar(u8, b.str()[3..], '`') != null) return false;
    rt.begin(.other, p.block, p.block + 1);
    b.remove(rt.doc.gpa, 0, b.len());
    b.setStyle(.{ .kind = .code });
    rt.sel = .at(.{ .block = p.block });
    rt.end(p.block + 1);
    return true;
}
