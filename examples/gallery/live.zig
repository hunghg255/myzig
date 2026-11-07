//! The demos of the documentation site as one app for browsers: every page
//! shares this one WebAssembly and names its demo, `--demo=buttons`. Built
//! by `zig build docs-live`; `cd docs && npm run live` puts it in the site.
const std = @import("std");
const myzig = @import("myzig");
const demos = @import("live_demos.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var name: []const u8 = demos.all[0].name;
    for (args) |a| if (std.mem.startsWith(u8, a, "--demo=")) {
        name = a["--demo=".len..];
    };
    const demo = demos.find(name) orelse return error.UnknownDemo;
    const app = try myzig.App.create(init, .{ .name = "myzig" });
    defer app.destroy();
    _ = try app.newWindow(.{ .title = demo.name, .content = .{ .view = demo.view() } });
    try app.run();
}
