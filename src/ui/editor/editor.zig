//! The code editor of native UI, after mygo's `ui/editor` and Zed's: a
//! gutter of line numbers, syntax colors (tokenized again only from the
//! lines an edit changed), the caret's line filled, indentation (Tab and
//! Shift+Tab on the selected lines, Enter keeping the indentation),
//! brackets and quotes closing as they are typed, the bracket at the caret
//! matched, a find bar that replaces too (case, whole words, regular
//! expressions), going to a line, soft wraps or long lines scrolled
//! sideways. Only the lines in view are built: a file of 100,000 lines
//! costs what a screenful does.
//!
//!     var code = ui.CodeEditor.init(gpa, source, "main.zig");
//!     defer code.deinit();
//!     // In the view:
//!     _ = ui.codeEditor(c, &code, .{});
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const ctx_mod = @import("../context.zig");
const Context = ctx_mod.Context;
const S = ctx_mod.Shortcut;
const TextBuffer = @import("../textfield.zig").TextBuffer;
const TextArea = @import("../textarea.zig").TextArea;
const tv = @import("../textarea_view.zig");
const keys = @import("../textarea_keys.zig");
const Geo = @import("../textlayout.zig").Geo;
const syntax = @import("syntax.zig");
const indent = @import("indent.zig");
const Find = @import("find.zig").Find;
const bars = @import("findbar.zig");

const mac = builtin.os.tag == .macos;

pub const CodeEditor = struct {
    area: TextArea,
    syntax: syntax.Syntax = .{},
    find: Find = .{},
    goto_open: bool = false,
    goto: TextBuffer = .{},
    /// Lines wrap at the editor's width (Alt+Z), rather than scrolling.
    wrap: bool = false,
    indent: indent.Indent = .{},
    read_only: bool = false,
    /// The bracket at the caret and its partner, this frame.
    bracket: ?[2]usize = null,
    /// A bar's field takes the focus in the next build.
    focus_next: enum { none, query, replacement, goto, editor } = .none,
    /// The bars' fields, from the last build.
    query_id: u64 = 0,
    replacement_id: u64 = 0,
    goto_id: u64 = 0,

    /// An editor of `text`, highlighted as the language of the file `name`.
    pub fn init(gpa: std.mem.Allocator, text: []const u8, name: ?[]const u8) CodeEditor {
        var ed: CodeEditor = .{ .area = .init(gpa, text) };
        if (name) |n| ed.syntax.setLanguage(syntax.languageFor(n));
        return ed;
    }

    pub fn deinit(ed: *CodeEditor) void {
        const gpa = ed.area.doc.gpa;
        ed.syntax.deinit(gpa);
        ed.find.deinit(gpa);
        ed.area.deinit();
    }

    /// Highlights as the language of a file named `name` (or a language's
    /// name: "zig", "go", "python"); none for null.
    pub fn setLanguage(ed: *CodeEditor, name: ?[]const u8) void {
        ed.syntax.setLanguage(if (name) |n| syntax.languageFor(n) else null);
    }

    /// Puts the caret at the start of line `line` (from 1) and shows it.
    pub fn goToLine(ed: *CodeEditor, line: usize) void {
        const n = std.math.clamp(line, 1, ed.area.doc.lineCount());
        ed.area.collapse(ed.area.doc.lineStart(n - 1));
        ed.focus_next = .editor;
    }

    /// Opens the find bar (replacing too), on the selection's text.
    pub fn openFind(ed: *CodeEditor, replacing: bool) void {
        ed.find.open = true;
        ed.find.replacing = ed.find.replacing or replacing;
        ed.goto_open = false;
        const ta = &ed.area;
        if (!ta.sel.empty() and ta.sel.hi() - ta.sel.lo() < 200) {
            const s = ta.selectedText(ta.doc.gpa);
            defer ta.doc.gpa.free(s);
            if (std.mem.indexOfScalar(u8, s, '\n') == null) ed.find.query.set(s);
        }
        ed.focus_next = if (replacing and ed.find.query.len > 0) .replacement else .query;
    }

    pub fn closeBars(ed: *CodeEditor) void {
        ed.find.open = false;
        ed.find.replacing = false;
        ed.goto_open = false;
        ed.focus_next = .editor;
    }

    /// The editor or one of its bars has the keyboard.
    fn active(ed: *const CodeEditor, c: *const Context) bool {
        if (c.focus == 0) return false;
        return c.focus == ed.area.id or c.focus == ed.query_id or c.focus == ed.replacement_id or c.focus == ed.goto_id;
    }
};

pub const Options = struct {
    width: types.Length = .fill,
    height: types.Length = .fill,
    size: f32 = 13,
    line_numbers: bool = true,
    /// Fills the caret's line.
    current_line: bool = true,
    placeholder: []const u8 = "",
};

pub const Result = tv.Result;

fn primary(k: u21, shift: bool) S {
    return if (mac) .{ .key = k, .cmd = true, .shift = shift } else .{ .key = k, .ctrl = true, .shift = shift };
}

/// The editor's own keys, before the text's.
fn shortcuts(c: *Context, ed: *CodeEditor) void {
    if (!ed.active(c)) return;
    const ta = &ed.area;
    if (c.shortcut(primary('f', false))) return ed.openFind(false);
    if (c.shortcut(if (mac) S{ .key = 'f', .cmd = true, .alt = true } else primary('h', false))) return ed.openFind(true);
    if (c.shortcut(.{ .key = 'g', .ctrl = true })) {
        ed.goto_open = true;
        ed.find.open = false;
        ed.goto.clear();
        ed.focus_next = .goto;
        return;
    }
    const next = if (mac) c.shortcut(primary('g', false)) else false;
    const prev = if (mac) c.shortcut(primary('g', true)) else false;
    const f3 = c.input.key == .f3;
    if (next or prev or f3) {
        if (f3) c.input.key = null;
        if (ed.find.query.len == 0) return ed.openFind(false);
        ed.find.update(ta.doc.gpa, &ta.doc);
        ed.find.step(ta, prev or (f3 and c.input.shift));
        c.changed = true;
        return;
    }
    if (c.shortcut(.{ .key = S.escape })) {
        if (ed.find.open or ed.goto_open) ed.closeBars() else if (!ta.sel.empty()) ta.collapse(ta.sel.caret) else c.shortcut_taken = false;
        return;
    }
    if (c.focus != ta.id or ed.read_only) {
        if (c.shortcut(.{ .key = 'z', .alt = true })) ed.wrap = !ed.wrap;
        return;
    }
    ta.time = c.time;
    if (c.shortcut(primary(']', false))) return indent.indentLines(ta, ed.indent, false);
    if (c.shortcut(primary('[', false))) return indent.indentLines(ta, ed.indent, true);
    if (c.shortcut(primary('/', false))) {
        const lang = ed.syntax.language orelse return;
        return indent.toggleComment(ta, if (lang.line_comment.len > 0) lang.line_comment else "//");
    }
    if (c.shortcut(.{ .key = 'z', .alt = true })) ed.wrap = !ed.wrap;
}

/// What the editor does with a command before the text area does.
fn hook(ctx: *anyopaque, c: *Context, ta: *TextArea, _: Geo, cmd: keys.Cmd) bool {
    const ed: *CodeEditor = @ptrCast(@alignCast(ctx));
    ta.time = c.time;
    switch (cmd) {
        .escape => {
            if (ed.find.open or ed.goto_open) ed.closeBars() else if (!ta.sel.empty()) ta.collapse(ta.sel.caret);
            return true;
        },
        .copy, .cut => if (ta.sel.empty()) {
            // Without a selection, the caret's line.
            const r = ta.lineRange(ta.caretLine());
            const s = ta.doc.slice(c.alloc(), r[0], r[1]);
            c.clipboard.write(c.clipboard.ctx, s);
            c.copy_done = true;
            if (cmd == .cut and !ed.read_only) ta.replaceRange(r[0], r[1], "", .other);
            return true;
        } else return false,
        else => {},
    }
    if (ed.read_only) return false;
    switch (cmd) {
        .newline => indent.newline(ta, ed.indent, c.alloc()),
        .tab => |back| indent.tab(ta, ed.indent, back),
        .insert => |s| return indent.typed(ta, s),
        .delete => |d| return d == .back and indent.backspace(ta, ed.indent),
        else => return false,
    }
    return true;
}

fn spans(ctx: *anyopaque, c: *Context, line: usize, str: []const u8) []const types.Span {
    const ed: *CodeEditor = @ptrCast(@alignCast(ctx));
    ed.syntax.sync(ed.area.doc.gpa, &ed.area.doc);
    return ed.syntax.spans(c.alloc(), &ed.area.doc, line, str, c.theme.dark);
}

const match_color: types.Color = .hex(0xf2b84b);

fn marks(ctx: *anyopaque, c: *Context, _: usize, start: usize, str: []const u8) []const tv.Mark {
    const ed: *CodeEditor = @ptrCast(@alignCast(ctx));
    var out: std.ArrayList(tv.Mark) = .empty;
    const gpa = c.alloc();
    const end = start + str.len;
    if (ed.find.open) {
        ed.find.update(ed.area.doc.gpa, &ed.area.doc);
        const all = ed.find.within(start, end + 1);
        const first_index = (@intFromPtr(all.ptr) - @intFromPtr(ed.find.matches.items.ptr)) / @sizeOf([2]usize);
        for (all, 0..) |m, k| {
            const current = ed.find.current == first_index + k;
            out.append(gpa, .{
                .start = @intCast(@max(m[0], start) - start),
                .end = @intCast(@min(m[1], end) - start),
                .color = match_color.alpha(if (current) 0.75 else 0.3),
            }) catch break;
        }
    }
    if (ed.bracket) |b| for (b) |at| if (at >= start and at < end) {
        out.append(gpa, .{ .start = @intCast(at - start), .end = @intCast(at - start + 1), .color = c.theme.muted.alpha(0.3) }) catch {};
    };
    return out.items;
}

/// A code editor of `ed`: give it a size, or let it fill its parent.
pub fn codeEditor(c: *Context, ed: *CodeEditor, opts: Options) Result {
    const th = c.theme;
    const bg = if (th.dark) types.Color.hex(0x1e1f22) else types.Color.hex(0xffffff);
    _ = c.open(.{ .direction = .column, .width = opts.width, .height = opts.height, .background = bg, .clip = true }, null);
    defer c.end();
    // The keyboard back to the text, in the build after the bar's key (its
    // Enter, its Escape) was read: the text doesn't get the key too.
    if (ed.focus_next == .editor and ed.area.id != 0) {
        c.focus = ed.area.id;
        ed.focus_next = .none;
        c.changed = true;
    }
    shortcuts(c, ed);
    if (ed.find.open) {
        ed.find.update(ed.area.doc.gpa, &ed.area.doc);
        ed.find.track(&ed.area);
        bars.findBar(c, ed);
    }
    if (ed.goto_open) bars.gotoBar(c, ed);
    if (ed.focus_next == .editor) c.changed = true;
    const ta = &ed.area;
    ed.bracket = if (c.focus == ta.id) indent.matchBracket(ta, c.alloc(), 2000) else null;
    if (ed.find.open) {
        ed.find.update(ta.doc.gpa, &ta.doc);
        ed.find.track(ta);
    }
    const style: types.TextStyle = .{ .size = opts.size, .mono = true, .leading = 1.45 };
    var digits: usize = 1;
    var n = ta.doc.lineCount();
    while (n >= 10) : (n /= 10) digits += 1;
    const ns: types.TextStyle = .{ .size = opts.size * 0.92, .mono = true };
    const gutter_w = @as(f32, @floatFromInt(@max(digits, 2))) * c.text.width("0", ns) + 26;
    // Keyed: the text keeps its id (its focus, its scroll) as bars come and go.
    c.next_key = "code-editor-text";
    return tv.view(c, ta, .{ .width = .fill, .grow = 1 }, .{
        .style = style,
        .wrap = ed.wrap,
        .read_only = ed.read_only,
        .placeholder = opts.placeholder,
        .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
        .gutter = if (opts.line_numbers) .{ .width = gutter_w, .color = th.muted.alpha(0.75), .active = th.text, .background = bg } else null,
        .current_line = if (opts.current_line) th.text.alpha(if (th.dark) 0.06 else 0.045) else null,
        .decor = .{ .ctx = ed, .spans = spans, .marks = marks },
        .hook = .{ .ctx = ed, .run = hook },
        .tab = true,
        .apply = .{ .smart_home = true },
    });
}
