//! The terminal's view through `ui.Tester`, offscreen: its grid from the
//! box's size, the text and colors it draws (rendered by the CPU renderer
//! where text is myzig's own), the keys and text it sends the program,
//! the wheel through the scrollback, and selecting and copying.
const std = @import("std");
const testing = std.testing;
const terminal = @import("terminal");
const ui = @import("myzig").ui;

const Fixture = struct {
    t: *terminal.Terminal = undefined,
    tester: ui.Tester = undefined,

    fn view(f: *Fixture, c: *ui.Context) void {
        terminal.view(c, f.t, .{ .autofocus = true });
    }

    /// A terminal with no program, whose input stays in its queue.
    fn init(f: *Fixture) !void {
        terminal.library.load(testing.allocator, testing.io) catch |err| switch (err) {
            error.GhosttyMissing => return error.SkipZigTest,
            else => return err,
        };
        f.t = try terminal.Terminal.create(testing.allocator, testing.io, .{ .no_program = true, .theme = terminal.Theme.dark });
        try f.tester.init(testing.allocator, .init(f, Fixture.view), .{ .width = 400, .height = 240 });
        f.tester.frame();
        f.tester.frame();
    }

    fn deinit(f: *Fixture) void {
        f.tester.deinit();
        f.t.destroy();
    }

    /// What the view sent the program so far, which it then forgets.
    fn sent(f: *Fixture, buf: []u8) []const u8 {
        const n = @min(buf.len, f.t.queue.items.len);
        @memcpy(buf[0..n], f.t.queue.items[0..n]);
        f.t.queue.clearRetainingCapacity();
        return buf[0..n];
    }
};

test "the view sizes the terminal in cells of its font" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const g = f.t.view_state.grid;
    try testing.expect(g.cell_w > 4 and g.cell_h > 8);
    const size = f.t.vt.size();
    try testing.expectEqual(g.cols, size[0]);
    try testing.expectEqual(@as(u16, @intFromFloat(@floor((400 - 8) / g.cell_w))), size[0]);
    try testing.expectEqual(@as(u16, @intFromFloat(@floor((240 - 8) / g.cell_h))), size[1]);
    f.tester.resize(200, 120);
    f.tester.frame();
    try testing.expect(f.t.vt.size()[0] < size[0]);
}

test "the view draws text, colors and the cursor" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.t.feed("hello \x1b[1;32mgreen\x1b[0m \x1b[41m  \x1b[0m");
    f.tester.frame();
    try testing.expect(f.tester.hasText("hello"));
    try testing.expect(f.tester.hasText("green"));
    const px = try f.tester.render(testing.allocator);
    defer px.deinit(testing.allocator);
    const g = f.t.view_state.grid;
    // The red background of cells 12 and 13, in the CPU renderer's pixels.
    const sx: usize = @intFromFloat((g.pad + 12.5 * g.cell_w) * 2);
    const sy: usize = @intFromFloat((g.pad + 0.5 * g.cell_h) * 2);
    const i = (sy * px.width + sx) * 4;
    // BGRA: red, VS Code's palette's 0xcd3131.
    try testing.expect(px.bytes[i + 2] > 150 and px.bytes[i + 1] < 90 and px.bytes[i] < 90);
    // The background is the theme's.
    const bg = (sy * px.width + @as(usize, @intFromFloat((g.pad + 30 * g.cell_w) * 2))) * 4;
    try testing.expect(px.bytes[bg + 2] < 0x30 and px.bytes[bg + 1] < 0x30);
}

test "keys and text the view sends the program" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    f.tester.typeText("ls");
    f.tester.key(.enter);
    try testing.expectEqualStrings("ls\r", f.sent(&buf));
    try testing.expect(f.tester.shortcut(.{ .key = 'c', .ctrl = true }));
    try testing.expectEqualStrings("\x03", f.sent(&buf));
    f.tester.key(.up);
    f.tester.key(.backspace);
    try testing.expectEqualStrings("\x1b[A\x7f", f.sent(&buf));
    try testing.expect(f.tester.shortcut(.{ .key = 'b', .alt = true }));
    try testing.expectEqualStrings("\x1bb", f.sent(&buf));
    // Bracketed paste, as the program asks.
    f.t.feed("\x1b[?2004h");
    f.t.paste("a\nb");
    try testing.expectEqualStrings("\x1b[200~a\nb\x1b[201~", f.sent(&buf));
}

test "the pointer is reported to programs that ask, and the wheel scrolls back" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..60) |i| {
        var line: [16]u8 = undefined;
        f.t.feed(try std.fmt.bufPrint(&line, "row {d}\r\n", .{i}));
    }
    f.tester.frame();
    try testing.expect(f.t.vt.atBottom());
    f.tester.moveTo(100, 100);
    f.tester.scroll(100, 100, 3 * f.t.view_state.grid.cell_h);
    try testing.expect(!f.t.vt.atBottom());
    // Typing scrolls back to the bottom.
    f.tester.typeText("x");
    try testing.expect(f.t.vt.atBottom());
    _ = f.sent(&buf);
    // A program taking the mouse gets presses, in SGR's format.
    f.t.feed("\x1b[?1000h\x1b[?1006h");
    const g = f.t.view_state.grid;
    f.tester.click(g.pad + 2.5 * g.cell_w, g.pad + 3.5 * g.cell_h);
    try testing.expectEqualStrings("\x1b[<0;3;4M\x1b[<0;3;4m", f.sent(&buf));
}

test "a drag selects text, which copies" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.t.feed("first line\r\nsecond words here");
    f.tester.frame();
    const g = f.t.view_state.grid;
    f.tester.drag(g.pad + 0.5 * g.cell_w, g.pad + 1.5 * g.cell_h, g.pad + 5.5 * g.cell_w, g.pad + 1.5 * g.cell_h);
    try testing.expect(f.tester.shortcut(.{ .key = 'c', .ctrl = true, .shift = true }));
    try testing.expectEqualStrings("second", f.tester.clipboard.items);
    // A double click selects a word.
    f.tester.doubleClick(g.pad + 8.5 * g.cell_w, g.pad + 1.5 * g.cell_h);
    try testing.expect(f.tester.shortcut(.{ .key = 'c', .ctrl = true, .shift = true }));
    try testing.expectEqualStrings("words", f.tester.clipboard.items);
}


test "with the link key held, the link under the pointer is underlined" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.t.feed("see src/app.zig:12 now\r\ngo https://ghostty.org ok");
    f.tester.frame();
    const g = f.t.view_state.grid;
    const at = struct {
        fn point(gr: anytype, x: f32, y: f32) [2]f32 {
            return .{ gr.pad + (x + 0.5) * gr.cell_w, gr.pad + (y + 0.5) * gr.cell_h };
        }
    }.point;
    const key_field = if (@import("builtin").os.tag == .macos) "cmd" else "ctrl";
    // Without the key: nothing.
    var p = at(g, 6, 0);
    f.tester.moveTo(p[0], p[1]);
    try testing.expect(f.t.view_state.link == null);
    // With it: the path's columns, then the URL's.
    @field(f.tester.ctx.input, key_field) = true;
    f.tester.moveTo(p[0], p[1]);
    try testing.expectEqual([3]u16{ 0, 4, 17 }, f.t.view_state.link.?);
    p = at(g, 10, 1);
    f.tester.moveTo(p[0], p[1]);
    try testing.expectEqual([3]u16{ 1, 3, 21 }, f.t.view_state.link.?);
    // Over plain words: none.
    p = at(g, 0, 0);
    f.tester.moveTo(p[0], p[1]);
    try testing.expect(f.t.view_state.link == null);
}
