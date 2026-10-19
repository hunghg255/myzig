//! Delayed rendering against a fake clipboard: what the window renders
//! when the system's messages ask, and when, the user's clipboard untouched.
const std = @import("std");
const w = @import("win32.zig");
const transfer = @import("../transfer.zig");
const native = @import("../transfer_native.zig");
const lazy = @import("clipboard_lazy.zig");

const Fake = struct {
    open: bool = false,
    owner: ?w.HWND = null,
    sets: std.ArrayList(struct { cf: u32, bytes: ?[]u8 }) = .empty,

    fn of(ctx: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn openImpl(ctx: ?*anyopaque, owner: w.HWND) bool {
        const f = of(ctx);
        if (f.open) return false;
        f.open = true;
        f.owner = owner;
        return true;
    }
    fn closeImpl(ctx: ?*anyopaque) void {
        of(ctx).open = false;
    }
    fn emptyImpl(_: ?*anyopaque) void {}
    fn ownerImpl(ctx: ?*anyopaque) ?w.HWND {
        return of(ctx).owner;
    }
    fn setImpl(ctx: ?*anyopaque, cf: u32, bytes: ?[]const u8) void {
        const f = of(ctx);
        const copy = if (bytes) |b| std.testing.allocator.dupe(u8, b) catch return else null;
        f.sets.append(std.testing.allocator, .{ .cf = cf, .bytes = copy }) catch {};
    }
    fn last(f: *Fake, cf: u32) ?struct { bytes: ?[]u8 } {
        var i = f.sets.items.len;
        while (i > 0) : (i -= 1) if (f.sets.items[i - 1].cf == cf) return .{ .bytes = f.sets.items[i - 1].bytes };
        return null;
    }
    fn deinit(f: *Fake) void {
        for (f.sets.items) |s| if (s.bytes) |b| std.testing.allocator.free(b);
        f.sets.deinit(std.testing.allocator);
    }
};

const Note = struct {
    made: usize = 0,
    fn json(n: *Note, gpa: std.mem.Allocator) anyerror![]u8 {
        n.made += 1;
        return gpa.dupe(u8, "{\"title\":\"Hi\"}");
    }
    fn html(n: *Note, gpa: std.mem.Allocator) anyerror![]u8 {
        n.made += 1;
        return gpa.dupe(u8, "<b>Hi</b>");
    }
};

fn registered(name: []const u8) u32 {
    var buf: [64]u16 = undefined;
    return RegisterClipboardFormatW(w.wide(&buf, name));
}
extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) u32;

test "lazy formats are rendered when an app asks for them, once, and all before the window goes" {
    var fake: Fake = .{};
    defer fake.deinit();
    lazy.board = .{ .ctx = &fake, .open = Fake.openImpl, .close = Fake.closeImpl, .empty = Fake.emptyImpl, .owner = Fake.ownerImpl, .set = Fake.setImpl };
    defer lazy.board = lazy.system;
    var note: Note = .{};
    var data = try transfer.Data.init(std.testing.allocator, &.{.{ .reps = &.{
        transfer.bytes(transfer.text, "Hi"),
        transfer.lazy("application/x-note", .of(&note, Note.json)),
        transfer.lazy(transfer.html, .of(&note, Note.html)),
    } }});
    defer data.deinit();
    try lazy.writeData(std.testing.allocator, &data);
    defer lazy.shutdown();
    const hwnd = lazy.ownerWindow().?;
    try std.testing.expect(!fake.open);
    // Text now (UTF-16, terminated); the lazy ones offered without bytes.
    const text = fake.last(native.CF_UNICODETEXT).?.bytes.?;
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("Hi\x00")), text);
    const cf_note = registered("application/x-note");
    const cf_html = registered("HTML Format");
    try std.testing.expect(fake.last(cf_note).?.bytes == null);
    try std.testing.expect(fake.last(cf_html).?.bytes == null);
    try std.testing.expectEqual(@as(usize, 0), note.made);

    // An app pastes the note: rendered then, once.
    _ = w.SendMessageW(hwnd, lazy.WM_RENDERFORMAT, cf_note, 0);
    _ = w.SendMessageW(hwnd, lazy.WM_RENDERFORMAT, cf_note, 0);
    try std.testing.expectEqualStrings("{\"title\":\"Hi\"}", fake.last(cf_note).?.bytes.?);
    try std.testing.expectEqual(@as(usize, 1), note.made);

    // The app ends: what is left is rendered, as "HTML Format".
    fake.owner = hwnd;
    _ = w.SendMessageW(hwnd, lazy.WM_RENDERALLFORMATS, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), note.made);
    const html = fake.last(cf_html).?.bytes.?;
    try std.testing.expect(std.mem.indexOf(u8, html, "<!--StartFragment--><b>Hi</b><!--EndFragment-->") != null);
    try std.testing.expect(!fake.open);

    // Another app copies: the data goes; later requests render nothing.
    _ = w.SendMessageW(hwnd, lazy.WM_DESTROYCLIPBOARD, 0, 0);
    const before = fake.sets.items.len;
    _ = w.SendMessageW(hwnd, lazy.WM_RENDERFORMAT, cf_note, 0);
    try std.testing.expectEqual(before, fake.sets.items.len);
}

test "files and URI lists: CF_HDROP made from the local files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var data = try transfer.Data.init(std.testing.allocator, &.{.{ .reps = &.{transfer.bytes(transfer.uri_list, "file:///C:/a.txt\r\nhttps://example.com/\r\n")} }});
    defer data.deinit();
    const o = try lazy.Offer.create(&data);
    defer o.destroy();
    try std.testing.expectEqual(@as(usize, 2), o.entries.len);
    try std.testing.expectEqual(@as(u32, native.CF_HDROP), o.entries[0].cf);
    try std.testing.expect(!o.entries[0].lazy);
    const drop = (try o.render(arena.allocator(), o.entries[0])).?;
    try std.testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, drop[0..4], .little));
    const list = (try o.render(arena.allocator(), o.entries[1])).?;
    try std.testing.expect(std.mem.startsWith(u8, list, "file:///C:/a.txt"));
}
