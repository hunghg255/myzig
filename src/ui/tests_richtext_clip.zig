//! The rich text editor's clipboard, history, input methods and long
//! documents through the Tester: copies pasted whole and as plain text or
//! Markdown, undo and redo of typing, formats and blocks, compositions as
//! one step, and only the blocks in view built.
const std = @import("std");
const ui = @import("ui.zig");
const rich = @import("richtext/richtext.zig");
const h = @import("tests_richtext.zig");
const testing = std.testing;

fn paste(t: *ui.Tester, s: []const u8) void {
    t.textOps(&.{.{ .insert = s }});
}

test "a copy pastes whole: blocks' styles and marks come with it" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "# Title\n\nSome **bold** text\n\n- [x] done");
    defer t.deinit();
    defer s.deinit();
    t.textOps(&.{.{ .command = .select_all }});
    t.textOps(&.{.{ .command = .copy }});
    // The clipboard has plain text.
    try testing.expectEqualStrings("Title\nSome bold text\ndone", t.clipboard.items);
    // Pasted at the end: the same blocks again.
    t.textOps(&.{.{ .command = .move_doc_end }});
    t.key(.enter);
    t.key(.enter);
    try testing.expectEqual(rich.Kind.paragraph, h.kindOf(&s, 3));
    const clip = try testing.allocator.dupe(u8, t.clipboard.items);
    defer testing.allocator.free(clip);
    paste(&t, clip);
    try h.expectMarkdown(&s, "# Title\n\nSome **bold** text\n\n- [x] done\n\n# Title\n\nSome **bold** text\n\n- [x] done\n");
    // The caret after it; one step of undo takes it all back.
    try testing.expectEqual(@as(usize, 5), s.rt.sel.caret.block);
    _ = t.shortcut(h.primary('z', false, false));
    try testing.expectEqual(@as(usize, 4), s.rt.doc.count());
    // A part of a block, pasted inside another, takes its style.
    s.rt.select(.{ .block = 1, .off = 5 }, .{ .block = 1, .off = 9 });
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("bold", t.clipboard.items);
    s.rt.collapse(.{ .block = 0, .off = 5 });
    paste(&t, "bold");
    try h.expectMarkdown(&s, "# Title**bold**\n\nSome **bold** text\n\n- [x] done\n");
    // Cut: copied and deleted.
    s.rt.select(.{ .block = 2 }, .{ .block = 2, .off = 4 });
    t.textOps(&.{.{ .command = .cut }});
    try testing.expectEqualStrings("done", t.clipboard.items);
    try testing.expectEqual(@as(usize, 0), s.rt.doc.block(2).len());
    // Spanning two blocks, pasted in the middle of a paragraph: the
    // paragraph's start keeps its style, its end takes the copy's last.
    s.rt.setMarkdown("# Head\n\nbody\n\nmiddle");
    t.frame();
    s.rt.select(.{ .block = 0, .off = 2 }, .{ .block = 1, .off = 2 });
    t.textOps(&.{.{ .command = .copy }});
    s.rt.collapse(.{ .block = 2, .off = 3 });
    const two = try testing.allocator.dupe(u8, t.clipboard.items);
    defer testing.allocator.free(two);
    paste(&t, two);
    try h.expectText(&s, "Head\nbody\nmidad\nbodle");
    try testing.expectEqual(rich.Kind.paragraph, h.kindOf(&s, 2));
    try testing.expectEqual(rich.Kind.paragraph, h.kindOf(&s, 3));
}

test "text from elsewhere pastes plain, its lines blocks" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "- item");
    defer t.deinit();
    defer s.deinit();
    paste(&t, " one\ntwo **not bold**\nthree");
    try h.expectText(&s, "item one\ntwo **not bold**\nthree");
    // Lines pasted in a list are items.
    try testing.expectEqual(rich.Kind.bullet, h.kindOf(&s, 1));
    try testing.expectEqual(rich.Kind.bullet, h.kindOf(&s, 2));
    try testing.expectEqual(@as(usize, 2), s.rt.sel.caret.block);
    // A word pasted takes the marks typing would.
    s.rt.setMarkdown("**bold**");
    t.frame();
    s.rt.collapse(s.rt.doc.end());
    paste(&t, "er");
    try h.expectMarkdown(&s, "**bolder**\n");
}

test "Markdown in and out of the clipboard" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "# Plan\n\n1. **Write** it\n2. Ship *it*");
    defer t.deinit();
    defer s.deinit();
    s.opts.clipboard = .markdown;
    t.frame();
    t.textOps(&.{.{ .command = .select_all }});
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("# Plan\n\n1. **Write** it\n2. Ship *it*\n", t.clipboard.items);
    // Markdown from elsewhere pastes formatted.
    s.rt.setMarkdown("");
    t.frame();
    paste(&t, "## From a chat\n\n- [ ] read `docs`\n- [x] ~~done~~\n\n> quoted\n");
    try h.expectMarkdown(&s, "## From a chat\n\n- [ ] read `docs`\n- [x] ~~done~~\n\n> quoted\n");
    // Round trip: what was copied pastes back the same.
    t.textOps(&.{.{ .command = .select_all }});
    t.textOps(&.{.{ .command = .copy }});
    const md = try testing.allocator.dupe(u8, t.clipboard.items);
    defer testing.allocator.free(md);
    s.rt.setMarkdown("");
    t.frame();
    s.rt.clip.deinit(testing.allocator);
    paste(&t, md);
    const again = s.rt.markdown(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(md, again);
    // The API pastes Markdown at the caret too.
    s.rt.collapse(s.rt.doc.end());
    s.rt.pasteMarkdown(", **more**");
    try h.expectMarkdown(&s, "## From a chat\n\n- [ ] read `docs`\n- [x] ~~done~~\n\n> quoted, **more**\n");
}

test "undo and redo: typing in bursts, formats, blocks and the caret" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "");
    defer t.deinit();
    defer s.deinit();
    t.typeText("a");
    t.typeText("b");
    t.typeText("c");
    t.advance(1.5);
    t.typeText("d");
    try h.expectText(&s, "abcd");
    _ = t.shortcut(h.primary('z', false, false));
    try h.expectText(&s, "abc");
    _ = t.shortcut(h.primary('z', false, false));
    try h.expectText(&s, "");
    try testing.expect(!s.rt.canUndo());
    _ = t.shortcut(h.primary('z', true, false));
    try h.expectText(&s, "abc");
    try testing.expectEqual(@as(usize, 3), s.rt.sel.caret.off);
    // A format, then Enter, each a step.
    t.textOps(&.{.{ .command = .select_all }});
    _ = t.shortcut(h.primary('b', false, false));
    t.key(.end);
    t.key(.enter);
    t.typeText("x");
    try h.expectMarkdown(&s, "**abc**\n\n**x**\n");
    _ = t.shortcut(h.primary('z', false, false));
    _ = t.shortcut(h.primary('z', false, false));
    try h.expectMarkdown(&s, "**abc**\n");
    _ = t.shortcut(h.primary('z', false, false));
    try h.expectMarkdown(&s, "abc\n");
    // The selection comes back with what undo brings back.
    try testing.expectEqual(@as(usize, 3), s.rt.sel.hi().off);
    _ = t.shortcut(h.primary('z', true, false));
    try h.expectMarkdown(&s, "**abc**\n");
    // Deleting across blocks, undone, brings back their styles.
    s.rt.setMarkdown("# A\n\n- b\n\n> c");
    t.frame();
    t.textOps(&.{.{ .command = .select_all }});
    t.key(.backspace);
    try h.expectText(&s, "");
    _ = t.shortcut(h.primary('z', false, false));
    try h.expectMarkdown(&s, "# A\n\n- b\n\n> c\n");
    // A new edit drops what could be redone.
    t.typeText("q");
    try testing.expect(!s.rt.canRedo());
}

test "an input method composes in the typing marks, one step of undo" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    try h.setup(&t, &s, "**x**");
    defer t.deinit();
    defer s.deinit();
    t.key(.end);
    t.textOps(&.{.{ .set_marked = .{ .text = "に", .sel_start = 3, .sel_len = 0 } }});
    try testing.expect(s.rt.marked != null);
    try testing.expectEqual([2]usize{ 1, 4 }, t.ctx.focused_text.?.marked.?);
    t.textOps(&.{.{ .set_marked = .{ .text = "日本", .sel_start = 6, .sel_len = 0 } }});
    try h.expectText(&s, "x日本");
    t.textOps(&.{.{ .insert = "日本語" }});
    try testing.expect(s.rt.marked == null);
    try h.expectMarkdown(&s, "**x日本語**\n");
    try testing.expectEqual(@as(usize, 10), s.rt.sel.caret.off);
    // The whole composition is one step.
    _ = t.shortcut(h.primary('z', false, false));
    try h.expectText(&s, "x");
    // An empty composition takes back what it showed.
    t.key(.end);
    t.textOps(&.{.{ .set_marked = .{ .text = "a", .sel_start = 1, .sel_len = 0 } }});
    t.textOps(&.{.{ .set_marked = .{ .text = "", .sel_start = 0, .sel_len = 0 } }});
    try h.expectText(&s, "x");
    try testing.expect(s.rt.marked == null);
}

test "a long document builds only the blocks in view" {
    var s: h.Note = undefined;
    var t: ui.Tester = undefined;
    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(testing.allocator);
    for (0..5000) |i| {
        if (i % 100 == 0) try md.print(testing.allocator, "## Section {d}\n\n", .{i / 100});
        try md.print(testing.allocator, "Paragraph {d} with **some** text to wrap and *mark* along the way.\n\n", .{i});
    }
    try h.setup(&t, &s, md.items);
    defer t.deinit();
    defer s.deinit();
    try testing.expectEqual(@as(usize, 5050), s.rt.doc.count());
    try testing.expect(s.result.last_block - s.result.first_block < 40);
    // The caret to the end: the view follows it.
    t.textOps(&.{.{ .command = .move_doc_end }});
    t.frame();
    try testing.expect(s.result.last_block == 5049);
    try testing.expect(s.result.last_block - s.result.first_block < 40);
    try testing.expect(t.containsText("Paragraph 4999 "));
    t.typeText("!");
    try testing.expect(std.mem.endsWith(u8, s.rt.doc.block(5049).str(), "way.!"));
    // Back to the start: the first blocks are built again.
    t.textOps(&.{.{ .command = .move_doc_start }});
    t.frame();
    try testing.expectEqual(@as(usize, 0), s.result.first_block);
    try testing.expect(t.hasText("Section 0"));
    try testing.expect(!t.containsText("Paragraph 4999"));
    // Paging moves through it a screen at a time.
    for (0..3) |_| t.key(.page_down);
    try testing.expect(s.rt.sel.caret.block > 10 and s.rt.sel.caret.block < 60);
    try testing.expect(s.result.first_block > 0);
}
