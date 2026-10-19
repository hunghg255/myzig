//! Documents in a real app: what `myzig.DocumentHost` is made of compiles
//! on every platform (nothing here shows a window or a dialog).
const std = @import("std");
const myzig = @import("myzig.zig");

const Text = struct {
    fn read(a: std.mem.Allocator, bytes: []const u8) anyerror![]u8 {
        return a.dupe(u8, bytes);
    }
    fn write(_: std.mem.Allocator, content: *const []u8, w: *std.Io.Writer) anyerror!void {
        try w.writeAll(content.*);
    }
};

test "a document host of the platform's app" {
    const Ds = myzig.Documents([]u8);
    const H = myzig.DocumentHost;
    // Analyzed, never run: it would need an app and windows.
    var run = false;
    _ = &run;
    if (run) {
        var h: H = .{ .app = undefined };
        const ds = try Ds.create(std.testing.allocator, std.testing.io, h.host(), .{
            .types = &.{.{ .name = "Text", .extensions = &.{"txt"} }},
            .read = Text.read,
            .write = Text.write,
            .window = undefined,
        });
        try h.attach(Ds, ds, undefined);
        h.start(Ds, ds);
        _ = h.fileMenu(Ds, ds);
        ds.quit();
        h.deinit();
    }
    std.testing.refAllDecls(myzig.file_watch);
}
