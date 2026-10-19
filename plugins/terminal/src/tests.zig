//! The terminal's tests: the emulator fed sequences (its screen's cells),
//! key, pointer and paste encoding, a program in a pseudo-terminal read
//! into the screen, and the view through `ui.Tester`, offscreen. They
//! need libghostty-vt where `library.find` looks (they skip without it;
//! `zig build test -Ddownload` fetches it first).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const terminal = @import("terminal");
const ui = @import("myzig").ui;
const vt = terminal.vt;
const encode = terminal.encode;

fn load() !void {
    terminal.library.load(testing.allocator, testing.io) catch |err| switch (err) {
        error.GhosttyMissing => return error.SkipZigTest,
        else => return err,
    };
}

/// An emulator of 40×10 cells and what it answers the program.
const Fixture = struct {
    effects: vt.Effects = .{},
    replies: std.ArrayList(u8) = .empty,
    t: vt.Vt = undefined,
    r: vt.Render = undefined,

    fn init(f: *Fixture) !void {
        try load();
        f.effects = .{ .ctx = f, .write_pty = reply };
        f.t = try vt.Vt.init(40, 10, &f.effects);
        f.r = try vt.Render.init();
    }

    fn deinit(f: *Fixture) void {
        f.r.deinit();
        f.t.deinit();
        f.replies.deinit(testing.allocator);
    }

    fn reply(ctx: ?*anyopaque, bytes: []const u8) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        f.replies.appendSlice(testing.allocator, bytes) catch {};
    }

    /// Row `y` of the frame as text, its cells in `cells`.
    fn row(f: *Fixture, y: usize, out: []u8, cells: ?*[]const u64) []const u8 {
        f.r.update(f.t);
        f.r.beginRows();
        var i: usize = 0;
        while (f.r.nextRow()) : (i += 1) {
            const raw = f.r.rowCells();
            if (i != y) continue;
            if (cells) |c| c.* = raw;
            var n: usize = 0;
            for (raw) |rc| {
                const cell = vt.decodeCell(rc);
                if (cell.wide == .spacer_tail) continue;
                const cp: u21 = if (cell.codepoint == 0) ' ' else cell.codepoint;
                n += std.unicode.utf8Encode(cp, out[n..]) catch break;
            }
            return std.mem.trimEnd(u8, out[0..n], " ");
        }
        return "";
    }
};

test "the emulator prints text, moves the cursor and styles cells" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.t.write("hello \x1b[1;31mred\x1b[0m\r\nsecond\x1b[3;5HX");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("hello red", f.row(0, &buf, null));
    try testing.expectEqualStrings("second", f.row(1, &buf, null));
    try testing.expectEqualStrings("    X", f.row(2, &buf, null));
    try testing.expectEqual([2]u16{ 5, 2 }, f.t.cursor());
    // "red" is bold, of the palette's red.
    var cells: []const u64 = &.{};
    _ = f.row(0, &buf, &cells);
    const cell = vt.decodeCell(cells[6]);
    try testing.expectEqual(@as(u21, 'r'), cell.codepoint);
    try testing.expect(cell.style_id != 0);
    const s = f.r.style(6);
    try testing.expect(s.bold);
    try testing.expectEqual(@as(i32, vt.StyleColor.palette), s.fg_color.tag);
    try testing.expectEqual(@as(u8, 1), s.fg_color.value[0]);
    try testing.expect(!f.r.style(0).bold);
    // The cursor of the frame.
    const cur = f.r.cursor();
    try testing.expect(cur.viewport_has_value and cur.visible);
    try testing.expectEqual(@as(u16, 5), cur.viewport_x);
}

test "the emulator erases, scrolls into the scrollback and resizes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    for (0..30) |i| {
        var line: [16]u8 = undefined;
        f.t.write(try std.fmt.bufPrint(&line, "line {d}\r\n", .{i}));
    }
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("line 21", f.row(0, &buf, null));
    const sb = f.t.scrollbar();
    try testing.expect(sb.total > sb.len);
    try testing.expect(f.t.atBottom());
    f.t.scrollBy(-5);
    try testing.expect(!f.t.atBottom());
    try testing.expectEqualStrings("line 16", f.row(0, &buf, null));
    f.t.scrollToBottom();
    f.t.write("\x1b[2J\x1b[H\x1b[Kdone");
    try testing.expectEqualStrings("done", f.row(0, &buf, null));
    f.t.resize(20, 5, 8, 16);
    try testing.expectEqual([2]u16{ 20, 5 }, f.t.size());
    const text = f.t.text(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "line 3\n") != null);
}

test "the emulator takes titles, modes, the alternate screen and answers queries" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.t.write("\x1b]0;My Title\x07");
    try testing.expectEqualStrings("My Title", f.t.title());
    f.t.write("\x1b[?2004h\x1b[?1049h");
    try testing.expect(f.t.mode(.bracketed_paste));
    try testing.expect(f.t.altScreen());
    f.t.write("\x1b[?1049l\x1b[?1000h");
    try testing.expect(!f.t.altScreen());
    try testing.expect(f.t.mouseTracking());
    // A query of the cursor's position is answered to the program.
    f.t.write("\x1b[2;4H\x1b[6n");
    try testing.expectEqualStrings("\x1b[2;4R", f.replies.items);
    // A hyperlink (OSC 8).
    f.t.write("\x1b]8;;https://ghostty.org\x1b\\link\x1b]8;;\x1b\\");
    const ref = f.t.cellAt(4, 1).?;
    try testing.expect(vt.decodeCell(f.t.rawCell(ref)).hyperlink);
    var ubuf: [128]u8 = undefined;
    try testing.expectEqualStrings("https://ghostty.org", f.t.hyperlink(ref, &ubuf).?);
}

test "keys encode as the program's modes ask" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var e = try encode.KeyEncoder.init();
    defer e.deinit();
    e.sync(f.t, false);
    try testing.expectEqualStrings("\r", e.encode(terminal.keys.fromKey(.enter, .{})));
    try testing.expectEqualStrings("\x1b[A", e.encode(terminal.keys.fromKey(.up, .{})));
    try testing.expectEqualStrings("\x7f", e.encode(terminal.keys.fromKey(.backspace, .{})));
    try testing.expectEqualStrings("\x1bOP", e.encode(terminal.keys.fromKey(.f1, .{})));
    try testing.expectEqualStrings("\x1b[1;5C", e.encode(terminal.keys.fromKey(.right, .{ .ctrl = true })));
    var text: [4]u8 = undefined;
    try testing.expectEqualStrings("\x03", e.encode(terminal.keys.fromShortcut(.{ .key = 'c', .ctrl = true }, &text).?));
    try testing.expectEqualStrings("\x1bx", e.encode(terminal.keys.fromShortcut(.{ .key = 'x', .alt = true }, &text).?));
    try testing.expectEqualStrings("A", e.encode(terminal.keys.fromChar('A', "A")));
    try testing.expectEqualStrings("é", e.encode(terminal.keys.fromChar(0xe9, "é")));
    // Cursor keys in application mode (DECCKM), as editors set.
    f.t.write("\x1b[?1h");
    e.sync(f.t, false);
    try testing.expectEqualStrings("\x1bOA", e.encode(terminal.keys.fromKey(.up, .{})));
}

test "the pointer, focus and pastes encode for the program" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var m = try encode.MouseEncoder.init();
    defer m.deinit();
    const size: encode.MouseSize = .{ .screen_width = 400, .screen_height = 200, .cell_width = 10, .cell_height = 20 };
    m.sync(f.t, size, false);
    try testing.expectEqualStrings("", m.encode(.press, .left, .{}, 25, 65));
    // Normal tracking in SGR's format: column 3, row 4.
    f.t.write("\x1b[?1000h\x1b[?1006h");
    m.sync(f.t, size, false);
    try testing.expectEqualStrings("\x1b[<0;3;4M", m.encode(.press, .left, .{}, 25, 65));
    m.sync(f.t, size, true);
    try testing.expectEqualStrings("\x1b[<0;3;4m", m.encode(.release, .left, .{}, 25, 65));
    try testing.expectEqualStrings("\x1b[<64;1;1M", m.encode(.press, .wheel_up, .{}, 1, 1));
    var fb: [8]u8 = undefined;
    try testing.expectEqualStrings("\x1b[I", encode.focus(true, &fb));
    try testing.expectEqualStrings("\x1b[O", encode.focus(false, &fb));
    const plain = try encode.paste(testing.allocator, "echo a\nb", false);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("echo a\rb", plain);
    const bracketed = try encode.paste(testing.allocator, "x\ny", true);
    defer testing.allocator.free(bracketed);
    try testing.expect(std.mem.startsWith(u8, bracketed, "\x1b[200~") and std.mem.endsWith(u8, bracketed, "\x1b[201~"));
    try testing.expect(!encode.pasteIsSafe("rm -rf x\n"));
    try testing.expect(encode.pasteIsSafe("ls"));
}

test {
    _ = @import("tests_pty.zig");
    _ = @import("tests_view.zig");
}
