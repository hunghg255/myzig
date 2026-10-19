//! The rich text editor's marks and selections through the Tester: marks
//! toggled on a selection and at the caret, by keys, by the toolbar and by
//! Markdown typed around words; selections across blocks with the keys
//! and the pointer; links asked for, set and clicked.
const std = @import("std");
const ui = @import("ui.zig");
const rich = @import("richtext/richtext.zig");
const h = @import("tests_richtext.zig");
const testing = std.testing;

test "marks toggle on a selection, and at the caret for what is typed" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "make this bold");
    defer t.deinit();
    defer s.deinit();
    // A double click selects a word.
    const r = t.findText("make this bold").?;
    const w = r.w / 14;
    t.doubleClick(r.x + w * 6.5, r.y + r.h / 2);
    try testing.expectEqualStrings("this", s.rt.selectedText(t.ctx.arena.allocator()));
    try testing.expect(t.shortcut(h.primary('b', false, false)));
    try h.expectMarkdown(&s, "make **this** bold\n");
    try testing.expectEqual(rich.FormatState.on, s.rt.formatting().bold);
    // Again: off, as all of it has it.
    _ = t.shortcut(h.primary('b', false, false));
    try h.expectMarkdown(&s, "make this bold\n");
    _ = t.shortcut(h.primary('i', false, false));
    _ = t.shortcut(h.primary('u', false, false));
    _ = t.shortcut(h.primary('x', true, false));
    try h.expectMarkdown(&s, "make *~~<u>this</u>~~* bold\n");
    // A selection partly italic: mixed, and the toggle makes it all italic.
    t.textOps(&.{.{ .command = .select_all }});
    try testing.expectEqual(rich.FormatState.mixed, s.rt.formatting().italic);
    _ = t.shortcut(h.primary('i', false, false));
    try testing.expectEqual(rich.FormatState.on, s.rt.formatting().italic);
    _ = t.shortcut(h.primary('i', false, false));
    _ = t.shortcut(h.primary('u', false, false));
    _ = t.shortcut(h.primary('u', false, false));
    _ = t.shortcut(h.primary('x', true, false));
    _ = t.shortcut(h.primary('x', true, false));
    try h.expectMarkdown(&s, "make this bold\n");
    // At the caret: the next text typed is bold, until the caret moves.
    t.key(.end);
    _ = t.shortcut(h.primary('b', false, false));
    try testing.expectEqual(rich.FormatState.on, s.rt.formatting().bold);
    t.typeText(" now");
    try h.expectMarkdown(&s, "make this bold **now**\n");
    t.typeText("!");
    try h.expectMarkdown(&s, "make this bold **now!**\n");
    // Code at the caret holds what is typed, and stops at its end.
    _ = t.shortcut(.{ .key = 'e', .ctrl = @import("builtin").os.tag != .macos, .cmd = @import("builtin").os.tag == .macos, .shift = @import("builtin").os.tag != .macos });
    _ = t.shortcut(h.primary('b', false, false));
    t.typeText("x");
    t.typeText("y");
    try h.expectMarkdown(&s, "make this bold **now!**`xy`\n");
    t.key(.left);
    t.key(.right);
    t.typeText("z");
    try h.expectMarkdown(&s, "make this bold **now!**`xy`z\n");
}

test "Markdown typed around words formats them" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "");
    defer t.deinit();
    defer s.deinit();
    const typed = "a **b** *c* _d_ `e` ~~f~~ snake_case_name 2 * 3 * 4";
    for (typed) |ch| t.typeText(&.{ch});
    try h.expectText(&s, "a b c d e f snake_case_name 2 * 3 * 4");
    try h.expectMarkdown(&s, "a **b** *c* *d* `e` ~~f~~ snake\\_case\\_name 2 \\* 3 \\* 4\n");
    // Undo takes the last one back to what was typed.
    s.rt.setMarkdown("");
    t.frame();
    for ("**x**") |ch| t.typeText(&.{ch});
    try h.expectText(&s, "x");
    _ = t.shortcut(h.primary('z', false, false));
    try h.expectText(&s, "**x**");
}

test "selections across blocks: keys, the pointer, deleting and typing over" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "# First\n\nsecond line\n\n- third");
    defer t.deinit();
    defer s.deinit();
    t.textOps(&.{.{ .command = .move_doc_start }});
    t.key(.right);
    h.keyShift(&t, .down);
    h.keyShift(&t, .down);
    try testing.expectEqual(@as(usize, 2), s.rt.sel.caret.block);
    const sel = s.rt.selectedText(t.ctx.arena.allocator());
    try testing.expect(std.mem.startsWith(u8, sel, "irst\nsecond line\n"));
    // Typing over it: the first block keeps its style.
    t.typeText("X");
    try testing.expectEqual(rich.Kind.heading1, h.kindOf(&s, 0));
    try testing.expect(std.mem.startsWith(u8, s.rt.doc.block(0).str(), "FX"));
    // A drag from the heading into the list selects across, and Backspace
    // deletes it all.
    s.rt.setMarkdown("# First\n\nsecond line\n\n- third");
    t.frame();
    const a = t.findText("First").?;
    const b = t.findText("third").?;
    t.drag(a.x + a.w * 0.4, a.y + a.h / 2, b.x + b.w + 5, b.y + b.h / 2);
    try testing.expectEqual(@as(usize, 0), s.rt.sel.lo().block);
    try testing.expectEqual(@as(usize, 2), s.rt.sel.hi().block);
    t.key(.backspace);
    try testing.expectEqual(@as(usize, 1), s.rt.doc.count());
    try testing.expectEqual(rich.Kind.heading1, h.kindOf(&s, 0));
    try testing.expectEqual(@as(usize, 2), s.rt.doc.block(0).len());
    // Select all, then type: one empty paragraph's worth of text.
    s.rt.setMarkdown("one\n\ntwo");
    t.frame();
    t.textOps(&.{.{ .command = .select_all }});
    t.typeText("z");
    try h.expectText(&s, "z");
    // A triple click selects a block.
    s.rt.setMarkdown("alpha beta\n\ngamma");
    t.frame();
    const g = t.findText("alpha beta").?;
    t.click(g.x + 2, g.y + 2);
    t.ctx.input.click_count = 3;
    t.ctx.pointerDown();
    t.frame();
    t.ctx.pointerUp();
    t.frame();
    t.ctx.input.click_count = 1;
    try testing.expectEqualStrings("alpha beta", s.rt.selectedText(t.ctx.arena.allocator()));
}

test "the toolbar formats the selection and gives the editor the keys back" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "tool bar");
    defer t.deinit();
    defer s.deinit();
    s.toolbar = true;
    t.frame();
    t.click(400, 290);
    const editor_id = s.rt.id;
    t.textOps(&.{.{ .command = .select_all }});
    try t.clickText("B");
    try h.expectMarkdown(&s, "**tool bar**\n");
    try testing.expectEqual(editor_id, t.ctx.focus);
    try t.clickText("H2");
    try h.expectMarkdown(&s, "## **tool bar**\n");
    try t.clickText("Quote");
    try testing.expectEqual(rich.Kind.quote, h.kindOf(&s, 0));
    try t.clickText("Undo");
    try testing.expectEqual(rich.Kind.heading2, h.kindOf(&s, 0));
    try t.clickText("Redo");
    try testing.expectEqual(rich.Kind.quote, h.kindOf(&s, 0));
    try t.clickText("Link");
    try testing.expect(s.link_asked);
}

test "links: asked for with the keys, set, typed past, and clicked" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "see the docs");
    defer t.deinit();
    defer s.deinit();
    t.key(.end);
    t.textOps(&.{.{ .command = .select_word_left }});
    try testing.expect(t.shortcut(h.primary('k', false, false)));
    try testing.expect(s.link_asked);
    s.rt.setLink("https://ziglang.org/documentation");
    try h.expectMarkdown(&s, "see the [docs](https://ziglang.org/documentation)\n");
    try testing.expectEqualStrings("https://ziglang.org/documentation", s.rt.formatting().link.?);
    // Typed at its end: outside it.
    t.key(.end);
    t.typeText(".");
    try h.expectMarkdown(&s, "see the [docs](https://ziglang.org/documentation).\n");
    // A click with ⌘ (Ctrl) on it reports it.
    const r = t.findText("see the docs.").?;
    t.ctx.input.cmd = true;
    t.ctx.input.ctrl = true;
    t.moveTo(r.x + r.w * 0.75, r.y + r.h / 2);
    t.ctx.pointerDown();
    t.frame();
    try testing.expectEqualStrings("https://ziglang.org/documentation", s.link_clicked.?);
    t.ctx.pointerUp();
    t.ctx.input.cmd = false;
    t.ctx.input.ctrl = false;
    t.frame();
    // At a caret in it, the link changes whole; empty takes it away.
    s.rt.collapse(.{ .off = 10 });
    s.rt.setLink("https://ziglang.org");
    try h.expectMarkdown(&s, "see the [docs](https://ziglang.org).\n");
    s.rt.setLink("");
    try h.expectMarkdown(&s, "see the docs.\n");
    // At a caret outside links, the URL is inserted, linked.
    s.rt.collapse(.{ .off = 0 });
    s.rt.setLink("https://a.b");
    try h.expectMarkdown(&s, "[https://a.b](https://a.b)see the docs.\n");
}

test "colors and highlights are marks too" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "red text");
    defer t.deinit();
    defer s.deinit();
    s.rt.select(.{}, .{ .off = 3 });
    s.rt.setMark(.{ .color = ui.Color.hex(0xff0000) });
    s.rt.select(.{ .off = 4 }, .{ .off = 8 });
    s.rt.setMark(.{ .highlight = ui.Color.hex(0xffff00) });
    t.frame();
    const b = s.rt.doc.block(0);
    try testing.expect(b.marksAt(0).color != null);
    try testing.expect(b.marksAt(5).highlight != null);
    try testing.expectEqual(@as(usize, 3), b.runs.items.len);
    // Markdown has none: they are left out.
    try h.expectMarkdown(&s, "red text\n");
    _ = t.shortcut(h.primary('z', false, false));
    try testing.expect(s.rt.doc.block(0).marksAt(5).highlight == null);
}
