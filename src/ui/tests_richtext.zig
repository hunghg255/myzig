//! The rich text editor through the Tester: typing, Enter and Backspace at
//! blocks' edges, every block's style by its keys and its Markdown
//! shortcut, lists continued, left and nested with Tab, and tasks checked.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui.zig");
const rich = @import("richtext/richtext.zig");
const testing = std.testing;
const S = ui.Shortcut;

/// Command on the Mac, Control elsewhere.
pub fn primary(k: u21, shift: bool, alt: bool) S {
    return if (builtin.os.tag == .macos) .{ .key = k, .cmd = true, .shift = shift, .alt = alt } else .{ .key = k, .ctrl = true, .shift = shift, .alt = alt };
}

pub const Note = struct {
    rt: rich.RichText,
    opts: rich.Options = .{ .height = .{ .px = 300 } },
    result: rich.Result = .{},
    toolbar: bool = false,
    toolbar_result: rich.ToolbarResult = .{},
    /// A text field after the editor, where Tab goes.
    other: ui.TextBuffer = .{},
    /// What the frames' results asked, kept: a frame built again (its
    /// state changed) answers only once.
    link_asked: bool = false,
    link_clicked: ?[]const u8 = null,

    pub fn view(s: *Note, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10), .width = .fill, .height = .fill, .gap = 6 });
        defer ui.end(c);
        if (s.toolbar) {
            s.toolbar_result = rich.toolbar(c, &s.rt, .{});
            if (s.toolbar_result.link_requested) s.link_asked = true;
        }
        s.result = rich.editor(c, &s.rt, s.opts);
        if (s.result.link_requested) s.link_asked = true;
        if (s.result.link_clicked) |u| s.link_clicked = u;
        _ = ui.textField(c, &s.other, .{ .placeholder = "Other" });
    }

    pub fn deinit(s: *Note) void {
        s.rt.deinit();
    }
};

/// A note of `md`, focused with a click past its text's end.
pub fn setup(t: *ui.Tester, s: *Note, md: []const u8) !void {
    s.* = .{ .rt = .initMarkdown(testing.allocator, md) };
    try t.init(testing.allocator, .init(s, Note.view), .{ .width = 480, .height = 400 });
    t.click(400, 290);
    try testing.expect(s.result.focused);
}

pub fn expectText(s: *Note, want: []const u8) !void {
    const got = s.rt.text(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

pub fn expectMarkdown(s: *Note, want: []const u8) !void {
    const got = s.rt.markdown(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

pub fn kindOf(s: *Note, i: usize) rich.Kind {
    return s.rt.doc.block(i).style.kind;
}

pub fn keyShift(t: *ui.Tester, k: @import("context.zig").Key) void {
    t.ctx.input.shift = true;
    t.key(k);
    t.ctx.input.shift = false;
}

test "typing, Enter, Backspace and Delete across blocks" {
    var s: Note = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "");
    defer t.deinit();
    defer s.deinit();
    t.typeText("Hello");
    t.key(.enter);
    t.typeText("wörld");
    try expectText(&s, "Hello\nwörld");
    try testing.expectEqual(@as(usize, 2), s.rt.doc.count());
    try testing.expect(t.hasText("wörld"));
    t.key(.backspace);
    try expectText(&s, "Hello\nwörl");
    t.key(.home);
    // At a paragraph's start Backspace joins it to the one before.
    t.key(.backspace);
    try expectText(&s, "Hellowörl");
    try testing.expectEqual(@as(usize, 1), s.rt.doc.count());
    try testing.expectEqual(@as(usize, 5), s.rt.sel.caret.off);
    t.key(.enter);
    t.key(.left);
    // At a block's end Delete joins the next one into it.
    t.key(.delete);
    try expectText(&s, "Hellowörl");
    t.key(.end);
    t.key(.enter);
    t.key(.enter);
    t.typeText("x");
    try expectText(&s, "Hellowörl\n\nx");
    try testing.expect(s.rt.takeChanged());
    try testing.expect(!s.rt.takeChanged());
}

test "every block style by its keys, toggled back" {
    var s: Note = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "Text");
    defer t.deinit();
    defer s.deinit();
    const cases = [_]struct { s: S, kind: rich.Kind }{
        .{ .s = primary('1', false, true), .kind = .heading1 },
        .{ .s = primary('2', false, true), .kind = .heading2 },
        .{ .s = primary('3', false, true), .kind = .heading3 },
        .{ .s = primary('7', true, false), .kind = .numbered },
        .{ .s = primary('8', true, false), .kind = .bullet },
        .{ .s = primary('l', true, false), .kind = .task },
        .{ .s = primary('9', true, false), .kind = .quote },
        .{ .s = primary('c', false, true), .kind = .code },
    };
    for (cases) |cs| {
        try testing.expect(t.shortcut(cs.s));
        try testing.expectEqual(cs.kind, kindOf(&s, 0));
        try testing.expect(t.hasText("Text"));
        try testing.expect(t.shortcut(cs.s));
        try testing.expectEqual(rich.Kind.paragraph, kindOf(&s, 0));
    }
    _ = t.shortcut(primary('2', false, true));
    try expectMarkdown(&s, "## Text\n");
    try testing.expect(t.shortcut(primary('0', false, true)));
    try expectMarkdown(&s, "Text\n");
    // Several blocks at once.
    t.key(.end);
    t.key(.enter);
    t.typeText("More");
    t.textOps(&.{.{ .command = .select_all }});
    _ = t.shortcut(primary('8', true, false));
    try expectMarkdown(&s, "- Text\n- More\n");
}

test "Markdown shortcuts at a block's start, and undo takes them back" {
    var s: Note = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "");
    defer t.deinit();
    defer s.deinit();
    const cases = [_]struct { typed: []const u8, kind: rich.Kind }{
        .{ .typed = "# ", .kind = .heading1 },
        .{ .typed = "## ", .kind = .heading2 },
        .{ .typed = "### ", .kind = .heading3 },
        .{ .typed = "- ", .kind = .bullet },
        .{ .typed = "* ", .kind = .bullet },
        .{ .typed = "1. ", .kind = .numbered },
        .{ .typed = "[ ] ", .kind = .task },
        .{ .typed = "> ", .kind = .quote },
    };
    for (cases) |cs| {
        for (cs.typed) |ch| t.typeText(&.{ch});
        try testing.expectEqual(cs.kind, kindOf(&s, 0));
        try testing.expectEqual(@as(usize, 0), s.rt.doc.block(0).len());
        // Undo: back to what was typed, a paragraph.
        _ = t.shortcut(primary('z', false, false));
        try testing.expectEqual(rich.Kind.paragraph, kindOf(&s, 0));
        try expectText(&s, cs.typed);
        t.textOps(&.{.{ .command = .select_all }});
        t.key(.backspace);
        try expectText(&s, "");
    }
    // ``` then Enter: a block of code.
    for ("```") |ch| t.typeText(&.{ch});
    t.key(.enter);
    try testing.expectEqual(rich.Kind.code, kindOf(&s, 0));
    t.typeText("const x = 1;");
    try expectMarkdown(&s, "```\nconst x = 1;\n```\n");
    // Not in code.
    t.key(.enter);
    t.typeText("# ");
    try testing.expectEqual(rich.Kind.code, kindOf(&s, 1));
    try expectText(&s, "const x = 1;\n# ");
}

test "Enter continues a list and leaves it on an empty item; Tab nests" {
    var s: Note = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "- one");
    defer t.deinit();
    defer s.deinit();
    t.key(.enter);
    t.typeText("two");
    try expectMarkdown(&s, "- one\n- two\n");
    // Tab is the list's: the item goes a level in, the focus stays.
    const focus = t.ctx.focus;
    try testing.expect(t.shortcut(.{ .key = S.tab }));
    try testing.expectEqual(focus, t.ctx.focus);
    try testing.expectEqual(@as(u8, 1), s.rt.doc.block(1).style.indent);
    try expectMarkdown(&s, "- one\n    - two\n");
    t.key(.enter);
    t.typeText("three");
    try testing.expectEqual(@as(u8, 1), s.rt.doc.block(2).style.indent);
    try testing.expect(t.shortcut(.{ .key = S.tab, .shift = true }));
    try expectMarkdown(&s, "- one\n    - two\n- three\n");
    try testing.expect(t.shortcut(.{ .key = S.tab }));
    // Enter on an empty nested item: a level out, then out of the list.
    t.key(.enter);
    try testing.expectEqual(@as(u8, 1), s.rt.doc.block(3).style.indent);
    t.key(.enter);
    try testing.expectEqual(@as(u8, 0), s.rt.doc.block(3).style.indent);
    try testing.expectEqual(rich.Kind.bullet, kindOf(&s, 3));
    t.key(.enter);
    try testing.expectEqual(rich.Kind.paragraph, kindOf(&s, 3));
    try testing.expectEqual(@as(usize, 4), s.rt.doc.count());
    t.typeText("after");
    try expectMarkdown(&s, "- one\n    - two\n    - three\n\nafter\n");
    // Out of a list, Tab moves the focus.
    _ = t.shortcut(.{ .key = S.tab });
    try testing.expect(t.ctx.focus != focus);
}

test "numbered lists count by level; tasks check with a click" {
    var s: Note = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "1. a\n2. b\n    1. c\n    2. d\n3. e\n\n- [ ] milk\n- [x] bread");
    defer t.deinit();
    defer s.deinit();
    try testing.expect(t.hasText("1."));
    try testing.expect(t.hasText("3."));
    try testing.expect(t.hasText("b."));
    try testing.expect(!s.rt.doc.block(5).style.checked);
    // The check box sits left of the item's text.
    const milk = t.findText("milk").?;
    t.click(milk.x - 15, milk.y + milk.h / 2);
    try testing.expect(s.rt.doc.block(5).style.checked);
    try testing.expect(s.result.focused);
    try testing.expect(t.hasText("bread"));
    try expectMarkdown(&s, "1. a\n2. b\n    1. c\n    2. d\n3. e\n- [x] milk\n- [x] bread\n");
    // Enter after a task: an unchecked one.
    t.click(400, 290);
    t.key(.enter);
    try testing.expectEqual(rich.Kind.task, kindOf(&s, 7));
    try testing.expect(!s.rt.doc.block(7).style.checked);
    _ = t.shortcut(primary('z', false, false));
    _ = t.shortcut(primary('z', false, false));
    try testing.expect(!s.rt.doc.block(5).style.checked);
}

test "Enter and Backspace at the edges of headings, items, quotations and code" {
    var s: Note = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "# Title");
    defer t.deinit();
    defer s.deinit();
    // Enter at a heading's end: a body paragraph.
    t.key(.enter);
    try testing.expectEqual(rich.Kind.paragraph, kindOf(&s, 1));
    t.typeText("body");
    t.key(.home);
    t.key(.backspace);
    try expectMarkdown(&s, "# Titlebody\n");
    // Enter at a heading's start pushes it down, leaving a paragraph.
    t.textOps(&.{.{ .command = .move_doc_start }});
    t.key(.enter);
    try testing.expectEqual(rich.Kind.paragraph, kindOf(&s, 0));
    try testing.expectEqual(rich.Kind.heading1, kindOf(&s, 1));
    // Backspace at a heading's start takes the heading away first.
    t.key(.backspace);
    try testing.expectEqual(rich.Kind.paragraph, kindOf(&s, 1));
    t.key(.backspace);
    try testing.expectEqual(@as(usize, 1), s.rt.doc.count());
    try expectText(&s, "Titlebody");
    // An item: its style goes, then it joins.
    s.rt.setMarkdown("para\n\n- item");
    t.frame();
    s.rt.collapse(.{ .block = 1 });
    t.key(.backspace);
    try testing.expectEqual(rich.Kind.paragraph, kindOf(&s, 1));
    t.key(.backspace);
    try expectText(&s, "paraitem");
    // A quotation continues with Enter and ends on an empty line.
    s.rt.setMarkdown("> wise");
    t.frame();
    s.rt.collapse(s.rt.doc.end());
    t.key(.enter);
    try testing.expectEqual(rich.Kind.quote, kindOf(&s, 1));
    t.key(.enter);
    try testing.expectEqual(rich.Kind.paragraph, kindOf(&s, 1));
    // Code: Enter makes lines; on an empty last line it ends the code.
    s.rt.setMarkdown("```\nfn main() void {}\n```");
    t.frame();
    s.rt.collapse(s.rt.doc.end());
    t.key(.enter);
    try testing.expectEqual(rich.Kind.code, kindOf(&s, 1));
    t.key(.enter);
    try testing.expectEqual(rich.Kind.paragraph, kindOf(&s, 1));
    try testing.expectEqual(@as(usize, 2), s.rt.doc.count());
}
