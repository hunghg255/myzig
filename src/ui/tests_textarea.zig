//! Multi-line text through the Tester: typing, every movement, selection
//! with the keys and the pointer, the clipboard, undo and redo, input
//! methods, keeping the caret in view, wrapping, and building only the
//! rows in view of a long text.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui.zig");
const ta_mod = @import("textarea.zig");
const tv = @import("textarea_view.zig");
const testing = std.testing;
const S = ui.Shortcut;

/// Command on the Mac, Control elsewhere.
fn primary(k: u21, shift: bool) S {
    return if (builtin.os.tag == .macos) .{ .key = k, .cmd = true, .shift = shift } else .{ .key = k, .ctrl = true, .shift = shift };
}

const Notes = struct {
    ta: ta_mod.TextArea,
    opts: tv.Options = .{ .height = .{ .px = 200 } },
    result: tv.Result = .{},

    fn view(s: *Notes, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10), .width = .fill, .height = .fill });
        defer ui.end(c);
        s.result = tv.textArea(c, &s.ta, s.opts);
    }

    fn text(s: *Notes) []u8 {
        return s.ta.text(testing.allocator);
    }
};

fn expectText(s: *Notes, want: []const u8) !void {
    const got = s.text();
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn setup(t: *ui.Tester, s: *Notes, initial: []const u8) !void {
    s.* = .{ .ta = .init(testing.allocator, initial) };
    try t.init(testing.allocator, .init(s, Notes.view), .{ .width = 480, .height = 360 });
    // Focus it with a click past the text's end.
    t.click(400, 180);
}

fn keyShift(t: *ui.Tester, k: @import("context.zig").Key) void {
    t.ctx.input.shift = true;
    t.key(k);
    t.ctx.input.shift = false;
}

test "typing, Enter, Backspace and Delete" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "");
    defer t.deinit();
    defer s.ta.deinit();
    try testing.expect(s.result.focused);
    t.typeText("hello");
    t.key(.enter);
    t.typeText("wörld");
    try expectText(&s, "hello\nwörld");
    t.key(.backspace);
    try expectText(&s, "hello\nwörl");
    t.key(.home);
    t.key(.backspace);
    try expectText(&s, "hellowörl");
    t.key(.delete);
    try expectText(&s, "helloörl");
    t.key(.delete);
    try expectText(&s, "hellorl");
    try testing.expect(t.hasText("hellorl"));
}

test "the caret moves by characters, words, rows, pages and the whole text" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..60) |i| try buf.print(testing.allocator, "line {d} of text\n", .{i});
    try setup(&t, &s, buf.items);
    defer t.deinit();
    defer s.ta.deinit();
    s.ta.collapse(0);
    t.frame();
    t.key(.right);
    try testing.expectEqual(@as(usize, 1), s.ta.sel.caret);
    t.textOps(&.{.{ .command = .move_word_right }});
    try testing.expectEqual(@as(usize, 4), s.ta.sel.caret);
    t.textOps(&.{.{ .command = .move_word_right }});
    try testing.expectEqual(@as(usize, 6), s.ta.sel.caret);
    t.textOps(&.{.{ .command = .move_word_left }});
    try testing.expectEqual(@as(usize, 5), s.ta.sel.caret);
    t.key(.end);
    try testing.expectEqual(@as(usize, 14), s.ta.sel.caret);
    t.key(.down);
    try testing.expectEqual(@as(usize, 1), s.ta.caretLine());
    // Down keeps the column, past a shorter line and back.
    try testing.expectEqual(s.ta.doc.lineEnd(1), s.ta.sel.caret);
    _ = t.shortcut(.{ .key = S.up });
    try testing.expectEqual(@as(usize, 14), s.ta.sel.caret);
    t.key(.left);
    t.key(.home);
    try testing.expectEqual(@as(usize, 0), s.ta.sel.caret);
    t.key(.page_down);
    const paged = s.ta.caretLine();
    try testing.expect(paged >= 5);
    t.key(.page_up);
    try testing.expectEqual(@as(usize, 0), s.ta.caretLine());
    try testing.expect(t.shortcut(primary(S.down, false)));
    try testing.expectEqual(s.ta.len(), s.ta.sel.caret);
    // The caret stays in view: the last lines are built, the first are not.
    try testing.expect(t.hasText("line 59 of text"));
    try testing.expect(!t.hasText("line 0 of text"));
    try testing.expect((t.ctx.scroll.get(s.ta.scroll_id) orelse 0) > 0);
    try testing.expect(t.shortcut(primary(S.up, false)));
    try testing.expectEqual(@as(usize, 0), s.ta.sel.caret);
    try testing.expect(t.hasText("line 0 of text"));
    // Left at a line's start goes to the end of the line before.
    s.ta.collapse(s.ta.doc.lineStart(3));
    t.key(.left);
    try testing.expectEqual(s.ta.doc.lineEnd(2), s.ta.sel.caret);
    t.key(.right);
    try testing.expectEqual(s.ta.doc.lineStart(3), s.ta.sel.caret);
}

test "Control with Home, End, Backspace and the arrows goes by words and to the ends (Linux, Windows)" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "one two\nthree four");
    defer t.deinit();
    defer s.ta.deinit();
    t.ctx.input.ctrl = true;
    defer t.ctx.input.ctrl = false;
    t.key(.home);
    try testing.expectEqual(@as(usize, 0), s.ta.sel.caret);
    t.key(.right);
    try testing.expectEqual(@as(usize, 3), s.ta.sel.caret);
    t.key(.end);
    try testing.expectEqual(s.ta.len(), s.ta.sel.caret);
    t.key(.backspace);
    try expectText(&s, "one two\nthree ");
    t.key(.left);
    try testing.expectEqual(@as(usize, 8), s.ta.sel.caret);
    t.key(.delete);
    try expectText(&s, "one two\n ");
}

test "Shift extends the selection; typing replaces it; select all" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "one two\nthree");
    defer t.deinit();
    defer s.ta.deinit();
    s.ta.collapse(4);
    keyShift(&t, .right);
    keyShift(&t, .right);
    keyShift(&t, .right);
    try testing.expectEqual(@as(usize, 4), s.ta.sel.anchor);
    try testing.expectEqual(@as(usize, 7), s.ta.sel.caret);
    keyShift(&t, .down);
    try testing.expectEqual(@as(usize, 1), s.ta.caretLine());
    keyShift(&t, .up);
    t.typeText("2");
    try expectText(&s, "one 2\nthree");
    // Left collapses a selection to its start.
    t.textOps(&.{.{ .command = .select_word_left }});
    t.key(.left);
    try testing.expect(s.ta.sel.empty());
    t.textOps(&.{.{ .command = .select_all }});
    try testing.expectEqual(@as(usize, 0), s.ta.sel.lo());
    try testing.expectEqual(s.ta.len(), s.ta.sel.hi());
    t.key(.backspace);
    try expectText(&s, "");
}

test "the pointer places the caret, double clicks select words and triple clicks lines" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "alpha beta\ngamma delta");
    defer t.deinit();
    defer s.ta.deinit();
    // A click past a line's end puts the caret at it.
    const second = t.findText("gamma delta").?;
    t.click(second.x + second.w + 30, second.y + second.h / 2);
    try testing.expectEqual(s.ta.len(), s.ta.sel.caret);
    t.click(second.x + 1, second.y + second.h / 2);
    try testing.expectEqual(s.ta.doc.lineStart(1), s.ta.sel.caret);
    // A word.
    const first = t.findText("alpha beta").?;
    const bx = first.x + first.w - 4;
    t.doubleClick(bx, first.y + first.h / 2);
    const sel = s.ta.selectedText(testing.allocator);
    defer testing.allocator.free(sel);
    try testing.expectEqualStrings("beta", sel);
    // A line, with its newline.
    t.moveTo(bx, first.y + first.h / 2);
    t.ctx.input.click_count = 3;
    t.ctx.pointerDown();
    t.frame();
    t.ctx.pointerUp();
    t.frame();
    t.ctx.input.click_count = 1;
    const line = s.ta.selectedText(testing.allocator);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("alpha beta\n", line);
    // Dragging selects from the press.
    t.drag(first.x + 1, first.y + first.h / 2, second.x + 1, second.y + second.h / 2);
    try testing.expectEqual(@as(usize, 0), s.ta.sel.anchor);
    try testing.expectEqual(s.ta.doc.lineStart(1), s.ta.sel.caret);
    // Shift+click extends it.
    t.ctx.input.shift = true;
    t.click(second.x + second.w + 30, second.y + second.h / 2);
    t.ctx.input.shift = false;
    try testing.expectEqual(@as(usize, 0), s.ta.sel.anchor);
    try testing.expectEqual(s.ta.len(), s.ta.sel.caret);
}

test "copy, cut and paste go through the Tester's clipboard" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "first\nsecond");
    defer t.deinit();
    defer s.ta.deinit();
    s.ta.select(2, 9);
    t.frame();
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("rst\nsec", t.clipboard.items);
    try expectText(&s, "first\nsecond");
    try testing.expect(t.shortcut(primary('x', false)));
    try testing.expectEqualStrings("rst\nsec", t.clipboard.items);
    try expectText(&s, "fiond");
    // Pasted text keeps its newlines.
    t.textOps(&.{.{ .insert = "RST\nSEC" }});
    try expectText(&s, "fiRST\nSECond");
    try testing.expectEqual(@as(usize, 1), s.ta.caretLine());
}

test "undo takes back typing a burst at a time, redo does it again" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "");
    defer t.deinit();
    defer s.ta.deinit();
    for ("hello") |ch| t.typeText(&.{ch});
    t.advance(2);
    t.typeText(" ");
    for ("world") |ch| t.typeText(&.{ch});
    try expectText(&s, "hello world");
    try testing.expect(t.shortcut(primary('z', false)));
    try expectText(&s, "hello");
    try testing.expectEqual(@as(usize, 5), s.ta.sel.caret);
    try testing.expect(t.shortcut(primary('z', false)));
    try expectText(&s, "");
    try testing.expect(t.shortcut(primary('z', true)));
    try expectText(&s, "hello");
    try testing.expect(t.shortcut(primary('z', true)));
    try expectText(&s, "hello world");
    // A move ends the burst: what is typed after is a step of its own.
    t.key(.left);
    t.typeText("!");
    try testing.expect(t.shortcut(primary('z', false)));
    try expectText(&s, "hello world");
    // Deleting in a row is one step too.
    t.key(.end);
    for (0..5) |_| t.key(.backspace);
    try expectText(&s, "hello ");
    try testing.expect(t.shortcut(primary('z', false)));
    try expectText(&s, "hello world");
}

test "an input method composes in the text and commits" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "ab\ncd");
    defer t.deinit();
    defer s.ta.deinit();
    s.ta.collapse(4);
    t.frame();
    t.textOps(&.{.{ .set_marked = .{ .text = "に", .sel_start = 3, .sel_len = 0 } }});
    try testing.expect(s.ta.marked != null);
    try expectText(&s, "ab\ncにd");
    // The input method sees the caret's line.
    const ft = t.ctx.focused_text.?;
    try testing.expectEqualStrings("cにd", ft.text);
    try testing.expectEqual(@as(usize, 4), ft.caret);
    try testing.expectEqual([2]usize{ 1, 4 }, ft.marked.?);
    t.textOps(&.{.{ .set_marked = .{ .text = "日本", .sel_start = 6, .sel_len = 0 } }});
    t.textOps(&.{.{ .insert = "日本" }});
    try expectText(&s, "ab\nc日本d");
    try testing.expect(s.ta.marked == null);
    try testing.expectEqual(@as(usize, 10), s.ta.sel.caret);
}

test "long lines wrap; Home and End go to the row's ends, Up and Down by rows" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    const long = "the quick brown fox jumps over the lazy dog and keeps on running through the fields until the end of the row";
    try setup(&t, &s, long ++ "\nend");
    defer t.deinit();
    defer s.ta.deinit();
    s.ta.collapse(0);
    t.frame();
    try testing.expect(!t.hasText(long));
    try testing.expect(s.ta.wrap.rowsOf(&s.ta.doc, 0) >= 2);
    t.key(.end);
    const row_end = s.ta.sel.caret;
    try testing.expect(row_end > 0 and row_end < long.len);
    try testing.expectEqual(@as(u8, ' '), long[row_end]);
    t.key(.down);
    try testing.expectEqual(@as(usize, 0), s.ta.caretLine());
    t.key(.home);
    try testing.expectEqual(row_end + 1, s.ta.sel.caret);
    // Without wrapping, one row scrolled sideways to the caret.
    s.opts.wrap = false;
    t.frame();
    s.ta.collapse(long.len);
    t.frame();
    try testing.expect(t.hasText(long));
    try testing.expect(s.ta.scroll_x > 0);
}

test "a placeholder shows while empty; read-only text selects and copies but doesn't change" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "");
    defer t.deinit();
    defer s.ta.deinit();
    s.opts.placeholder = "Write something";
    t.frame();
    try testing.expect(t.hasText("Write something"));
    t.typeText("x");
    try testing.expect(!t.hasText("Write something"));
    s.opts.read_only = true;
    t.typeText("y");
    t.key(.backspace);
    try expectText(&s, "x");
    t.textOps(&.{.{ .command = .select_all }});
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("x", t.clipboard.items);
    t.textOps(&.{.{ .command = .cut }});
    try expectText(&s, "x");
}

test "Tab moves the focus, unless the area takes it" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "");
    defer t.deinit();
    defer s.ta.deinit();
    try testing.expect(t.shortcut(.{ .key = S.tab }));
    try expectText(&s, "");
    s.opts.tab = true;
    t.click(400, 180);
    try testing.expect(t.shortcut(.{ .key = S.tab }));
    try expectText(&s, "\t");
    try testing.expectEqual(s.ta.id, t.ctx.focus);
}

test "a text of 100,000 lines builds only the rows in view, and edits cheaply" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..100_000) |i| try buf.print(testing.allocator, "row {d}\n", .{i});
    try setup(&t, &s, buf.items);
    defer t.deinit();
    defer s.ta.deinit();
    s.opts.height = .fill;
    t.frame();
    try testing.expect(t.ctx.stats.nodes < 200);
    s.ta.collapse(s.ta.doc.lineStart(50_000));
    t.frame();
    try testing.expect(t.hasText("row 50000"));
    try testing.expect(!t.hasText("row 0"));
    try testing.expect(t.ctx.stats.nodes < 200);
    t.typeText("x");
    try testing.expect(t.hasText("xrow 50000"));
    try testing.expectEqual(@as(usize, 100_001), s.ta.doc.lineCount());
    // The wheel scrolls; what comes into view is built.
    t.scroll(200, 200, -2000);
    try testing.expect(!t.hasText("xrow 50000"));
    try testing.expect(t.ctx.stats.nodes < 200);
}

test "the selection and the caret are drawn" {
    var s: Notes = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "select me");
    defer t.deinit();
    defer s.ta.deinit();
    s.ta.select(0, 6);
    t.frame();
    const r = t.findText("select me").?;
    const pixels = try t.render(testing.allocator);
    defer pixels.deinit(testing.allocator);
    // Under "select", the accent's tint; past it, the surface.
    const sx: usize = @intFromFloat((r.x + 2) * t.scale);
    const sy: usize = @intFromFloat((r.y + 1) * t.scale);
    const px = pixels.bytes[(sy * pixels.width + sx) * 4 ..][0..4];
    const ex: usize = @intFromFloat((r.x + r.w + 20) * t.scale);
    const pe = pixels.bytes[(sy * pixels.width + ex) * 4 ..][0..4];
    // BGRA: the selection is bluer than the background beyond the text.
    try testing.expect(px[0] > px[2]);
    try testing.expect(@as(i32, px[0]) - px[2] > @as(i32, pe[0]) - pe[2]);
}
