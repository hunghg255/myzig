//! A toolbar of the rich text editor's formats: bold, italics, underline,
//! strikethrough and code, headings, lists, quotations and code blocks, a
//! link, undo and redo. Its buttons show the selection's formats, and a
//! click formats the editor and gives it back the keyboard.
//!
//!     const tb = ui.richTextToolbar(c, &note, .{});
//!     if (tb.link_requested) s.asking_link = true;
//!     _ = ui.richTextEditor(c, &note, .{});
const std = @import("std");
const ctx_mod = @import("../context.zig");
const toolbar_mod = @import("../toolbar.zig");
const model = @import("model.zig");
const RichText = @import("editor.zig").RichText;
const Context = ctx_mod.Context;

pub const Options = struct {
    border: bool = true,
    /// Undo and redo at the end.
    history: bool = true,
};

pub const Result = struct {
    /// A format was applied in this frame.
    changed: bool = false,
    /// The link button: show a field, then `RichText.setLink`.
    link_requested: bool = false,
};

pub fn richTextToolbar(c: *Context, rt: *RichText, opts: Options) Result {
    var res: Result = .{};
    var tb = toolbar_mod.toolbar(c, .{ .border = opts.border });
    const f = rt.formatting();
    const marks = [_]struct { title: []const u8, t: model.Toggle }{
        .{ .title = "B", .t = .bold },
        .{ .title = "I", .t = .italic },
        .{ .title = "U", .t = .underline },
        .{ .title = "S", .t = .strike },
    };
    for (marks) |m| {
        var on = f.of(m.t) == .on;
        if (tb.toggle(m.title, &on)) {
            rt.toggle(m.t);
            res.changed = true;
        }
    }
    var code = f.code == .on;
    if (tb.toggleIcon("", "chevron.left.forwardslash.chevron.right", &code)) {
        rt.toggle(.code);
        res.changed = true;
    }
    tb.separator();
    const kinds = [_]struct { title: []const u8, icon: []const u8, k: model.Kind }{
        .{ .title = "H1", .icon = "", .k = .heading1 },
        .{ .title = "H2", .icon = "", .k = .heading2 },
        .{ .title = "H3", .icon = "", .k = .heading3 },
        .{ .title = "", .icon = "list.bullet", .k = .bullet },
        .{ .title = "1.", .icon = "", .k = .numbered },
        .{ .title = "", .icon = "checklist", .k = .task },
        .{ .title = "Quote", .icon = "", .k = .quote },
        .{ .title = "Code", .icon = "", .k = .code },
    };
    for (kinds) |k| {
        var on = f.style.kind == k.k;
        if (tb.toggleIcon(k.title, k.icon, &on)) {
            rt.setKind(k.k);
            res.changed = true;
        }
    }
    tb.separator();
    var linked = f.link != null;
    if (tb.toggle("Link", &linked)) {
        res.link_requested = true;
        // The toggle shows the link; it stays as it is until a URL comes.
        linked = !linked;
    }
    if (opts.history) {
        tb.spacer();
        if (tb.button("Undo", .{ .disabled = !rt.canUndo() })) {
            rt.undo();
            res.changed = true;
        }
        if (tb.button("Redo", .{ .disabled = !rt.canRedo() })) {
            rt.redo();
            res.changed = true;
        }
    }
    tb.end();
    // The keyboard goes back to the text.
    if (res.changed and rt.id != 0) c.focus = rt.id;
    if (res.changed) c.changed = true;
    return res;
}
