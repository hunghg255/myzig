//! The code editor through the Tester: syntax colors and line numbers,
//! indentation, brackets, the find bar (case, words, regular expressions,
//! replacing), going to a line, wrapping, and a file of 100,000 lines
//! that builds and highlights only what is in view.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui.zig");
const ed_mod = @import("editor/editor.zig");
const testing = std.testing;
const S = ui.Shortcut;

fn primary(k: u21, shift: bool) S {
    return if (builtin.os.tag == .macos) .{ .key = k, .cmd = true, .shift = shift } else .{ .key = k, .ctrl = true, .shift = shift };
}

const App = struct {
    ed: ed_mod.CodeEditor,
    result: ed_mod.Result = .{},

    fn view(s: *App, c: *ui.Context) void {
        s.result = ed_mod.codeEditor(c, &s.ed, .{});
    }
};

fn setup(t: *ui.Tester, s: *App, text: []const u8, name: []const u8) !void {
    s.* = .{ .ed = .init(testing.allocator, text, name) };
    try t.init(testing.allocator, .init(s, App.view), .{ .width = 640, .height = 400 });
    t.click(500, 380);
    s.ed.area.collapse(0);
    t.frame();
}

fn expectText(s: *App, want: []const u8) !void {
    const got = s.ed.area.text(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

/// The text leaf drawing `str` in the last frame.
fn leafOf(t: *ui.Tester, str: []const u8) ?@import("context.zig").Content.Text {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, str)) return tx,
        else => {},
    };
    return null;
}

test "line numbers, syntax colors and the caret's line" {
    var s: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "const x = 42; // answer\nfn main() void {}\n", "main.zig");
    defer t.deinit();
    defer s.ed.deinit();
    try testing.expect(s.result.focused);
    try testing.expect(t.hasText("1") and t.hasText("2") and t.hasText("3"));
    const first = leafOf(&t, "const x = 42; // answer").?;
    try testing.expect(first.spans.len >= 3);
    try testing.expectEqual(@as(u32, 0), first.spans[0].start);
    try testing.expectEqual(@as(u32, 5), first.spans[0].end);
    // The keyword's color is not the text's.
    try testing.expect(!std.meta.eql(first.spans[0].color.?, first.color));
    // Without a language, plain text.
    s.ed.setLanguage(null);
    t.frame();
    try testing.expectEqual(@as(usize, 0), leafOf(&t, "const x = 42; // answer").?.spans.len);
    const pixels = try t.render(testing.allocator);
    defer pixels.deinit(testing.allocator);
}

test "Tab and Shift+Tab indent lines; Enter keeps the indentation" {
    var s: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "fn f() {}", "a.zig");
    defer t.deinit();
    defer s.ed.deinit();
    // Between a pair, Enter opens an indented line.
    s.ed.area.collapse(8);
    t.frame();
    t.key(.enter);
    try expectText(&s, "fn f() {\n    \n}");
    try testing.expectEqual(@as(usize, 13), s.ed.area.sel.caret);
    t.typeText("x");
    t.key(.enter);
    try expectText(&s, "fn f() {\n    x\n    \n}");
    // Tab at the caret: spaces to the next stop.
    s.ed.area.reset("ab");
    s.ed.area.collapse(1);
    t.frame();
    try testing.expect(t.shortcut(.{ .key = S.tab }));
    try expectText(&s, "a   b");
    // On selected lines: a level each, and back.
    s.ed.area.reset("one\ntwo\nthree");
    s.ed.area.select(1, 9);
    t.frame();
    try testing.expect(t.shortcut(.{ .key = S.tab }));
    try expectText(&s, "    one\n    two\n    three");
    try testing.expectEqual(@as(usize, 5), s.ed.area.sel.anchor);
    try testing.expect(t.shortcut(.{ .key = S.tab, .shift = true }));
    try expectText(&s, "one\ntwo\nthree");
    try testing.expect(t.shortcut(primary(']', false)));
    try expectText(&s, "    one\n    two\n    three");
    try testing.expect(t.shortcut(primary('z', false)));
    try expectText(&s, "one\ntwo\nthree");
    // Tab stays in the editor: the focus doesn't move.
    try testing.expectEqual(s.ed.area.id, t.ctx.focus);
}

test "brackets and quotes close, wrap the selection, are typed over and deleted in pairs" {
    var s: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "", "a.js");
    defer t.deinit();
    defer s.ed.deinit();
    t.typeText("f");
    t.typeText("(");
    try expectText(&s, "f()");
    t.typeText("\"");
    try expectText(&s, "f(\"\")");
    t.typeText("a");
    t.typeText("\"");
    t.typeText(")");
    try expectText(&s, "f(\"a\")");
    try testing.expectEqual(@as(usize, 6), s.ed.area.sel.caret);
    s.ed.area.select(2, 5);
    t.frame();
    t.typeText("[");
    try expectText(&s, "f([\"a\"])");
    s.ed.area.reset("x()");
    s.ed.area.collapse(2);
    t.frame();
    t.key(.backspace);
    try expectText(&s, "x");
    // The bracket at the caret and its partner.
    s.ed.area.reset("a(b[c]d)e");
    s.ed.area.collapse(1);
    t.frame();
    try testing.expectEqual([2]usize{ 1, 7 }, s.ed.bracket.?);
    s.ed.area.collapse(6);
    t.frame();
    try testing.expectEqual([2]usize{ 5, 3 }, s.ed.bracket.?);
    // Comments, out and in.
    s.ed.area.reset("a\n  b");
    s.ed.area.select(0, 4);
    t.frame();
    try testing.expect(t.shortcut(primary('/', false)));
    try expectText(&s, "// a\n//   b");
    try testing.expect(t.shortcut(primary('/', false)));
    try expectText(&s, "a\n  b");
}

test "the find bar finds, steps through matches and replaces" {
    var s: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&t, &s, "foo bar\nFoo foobar\nfoo1 foo22", "a.txt");
    defer t.deinit();
    defer s.ed.deinit();
    try testing.expect(t.shortcut(primary('f', false)));
    try testing.expect(s.ed.find.open);
    try testing.expectEqual(s.ed.query_id, t.ctx.focus);
    t.typeText("foo");
    try testing.expectEqual(@as(usize, 5), s.ed.find.matches.items.len);
    try testing.expect(t.hasText("1 of 5"));
    try testing.expectEqual(@as(usize, 0), s.ed.area.sel.lo());
    try testing.expectEqual(@as(usize, 3), s.ed.area.sel.hi());
    t.key(.enter);
    try testing.expect(t.hasText("2 of 5"));
    try testing.expectEqual(@as(usize, 8), s.ed.area.sel.lo());
    t.ctx.input.shift = true;
    t.key(.enter);
    t.ctx.input.shift = false;
    try testing.expect(t.hasText("1 of 5"));
    // Case, then whole words.
    s.ed.find.flags.case = true;
    t.frame();
    try testing.expectEqual(@as(usize, 4), s.ed.find.matches.items.len);
    s.ed.find.flags.word = true;
    t.frame();
    try testing.expectEqual(@as(usize, 1), s.ed.find.matches.items.len);
    s.ed.find.flags = .{};
    t.frame();
    // Matches are marked in the text.
    var marked: usize = 0;
    for (t.ctx.nodes.items) |n| if (n.style.background) |bg| if (bg.r > 0.9 and bg.g > 0.6 and bg.b < 0.4) {
        marked += 1;
    };
    try testing.expect(marked >= 5);
    // Replace: the replacement field, Enter replaces one, All the rest.
    try testing.expect(t.shortcut(primary('h', false)) or t.shortcut(.{ .key = 'f', .cmd = true, .alt = true }));
    try testing.expectEqual(s.ed.replacement_id, t.ctx.focus);
    t.typeText("qux");
    s.ed.area.collapse(0);
    s.ed.find.step(&s.ed.area, false);
    t.frame();
    t.key(.enter);
    try expectText(&s, "qux bar\nFoo foobar\nfoo1 foo22");
    try testing.expect(t.hasText("1 of 4"));
    try t.clickText("All");
    try expectText(&s, "qux bar\nqux quxbar\nqux1 qux22");
    try testing.expect(t.hasText("No results"));
    // Regular expressions, with groups.
    s.ed.area.reset("a1 b22 c333");
    s.ed.find.query.set("([a-z])(\\d+)");
    s.ed.find.replacement.set("$2$1");
    s.ed.find.flags.regex = true;
    t.frame();
    try testing.expectEqual(@as(usize, 3), s.ed.find.matches.items.len);
    _ = s.ed.find.replaceAll(testing.allocator, &s.ed.area);
    try expectText(&s, "1a 22b 333c");
    s.ed.find.query.set("(unclosed");
    t.frame();
    try testing.expect(t.hasText("Invalid pattern"));
    // Escape closes the bar and gives the keyboard back to the text.
    t.click(100, 12);
    t.key(.escape);
    try testing.expect(!s.ed.find.open);
    t.frame();
    try testing.expectEqual(s.ed.area.id, t.ctx.focus);
}

test "go to a line; wrap long lines or scroll to them" {
    var s: App = undefined;
    var t: ui.Tester = undefined;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..200) |i| try buf.print(testing.allocator, "line {d}\n", .{i});
    try buf.appendNTimes(testing.allocator, 'x', 400);
    try setup(&t, &s, buf.items, "a.txt");
    defer t.deinit();
    defer s.ed.deinit();
    try testing.expect(t.shortcut(.{ .key = 'g', .ctrl = true }));
    try testing.expect(s.ed.goto_open);
    try testing.expectEqual(s.ed.goto_id, t.ctx.focus);
    t.typeText("150");
    t.key(.enter);
    t.frame();
    try testing.expect(!s.ed.goto_open);
    try testing.expectEqual(@as(usize, 149), s.ed.area.caretLine());
    try testing.expectEqual(s.ed.area.id, t.ctx.focus);
    try testing.expect(t.hasText("line 149"));
    try testing.expect(!t.hasText("line 0"));
    // The long last line: scrolled to its end, then wrapped.
    try testing.expect(t.shortcut(primary(S.down, false)));
    try testing.expect(s.ed.area.scroll_x > 0);
    try testing.expect(t.shortcut(.{ .key = 'z', .alt = true }));
    try testing.expect(s.ed.wrap);
    t.frame();
    try testing.expectEqual(@as(f32, 0), s.ed.area.scroll_x);
    try testing.expect(s.ed.area.wrap.rowsOf(&s.ed.area.doc, 200) > 2);
}

test "a file of 100,000 lines builds and highlights only what is in view" {
    var s: App = undefined;
    var t: ui.Tester = undefined;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..100_000) |i| try buf.print(testing.allocator, "const v{d} = \"{d}\"; // n\n", .{ i, i });
    try setup(&t, &s, buf.items, "big.zig");
    defer t.deinit();
    defer s.ed.deinit();
    try testing.expect(t.ctx.stats.nodes < 250);
    try testing.expect(s.ed.syntax.tokenized < 100);
    s.ed.goToLine(50_000);
    t.frame();
    try testing.expect(t.hasText("const v49999 = \"49999\"; // n"));
    try testing.expect(t.ctx.stats.nodes < 250);
    // Typing there tokenizes a few lines, not the file again.
    const before = s.ed.syntax.tokenized;
    t.typeText("x");
    try testing.expect(s.ed.syntax.tokenized - before < 10);
    try testing.expect(t.hasText("xconst v49999 = \"49999\"; // n"));
    t.key(.backspace);
    try testing.expect(t.ctx.stats.nodes < 250);
}

test "lines wrap at a column, or at the edge where that is nearer" {
    var s: App = undefined;
    var t: ui.Tester = undefined;
    // 120 characters: past 40 columns, within the 640-point editor's edge.
    const line = "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij";
    try setup(&t, &s, line, "a.txt");
    defer t.deinit();
    defer s.ed.deinit();
    s.ed.wrap = true;
    t.frame();
    const at_edge = s.ed.area.wrap.rowsOf(&s.ed.area.doc, 0);
    s.ed.wrap_column = 40;
    t.frame();
    t.frame();
    try testing.expectEqual(@as(usize, 3), s.ed.area.wrap.rowsOf(&s.ed.area.doc, 0));
    try testing.expect(at_edge < 3);
    // A column past the edge: the edge.
    s.ed.wrap_column = 1000;
    t.frame();
    t.frame();
    try testing.expectEqual(at_edge, s.ed.area.wrap.rowsOf(&s.ed.area.doc, 0));
}
