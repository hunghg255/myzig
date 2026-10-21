//! Pages and windows in memory: no native handles or WebView2 profile.
const std = @import("std");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const Page = @import("page.zig").Page;
const t = std.testing;

pub const Fixture = struct {
    env: std.process.Environ.Map,
    app: App,

    pub fn init(f: *Fixture) void {
        f.env = .init(t.allocator);
        f.app = .{ .gpa = t.allocator, .io = t.io, .environ = &f.env, .options = .{ .name = "page-regression" } };
    }

    pub fn deinit(f: *Fixture) void {
        while (f.app.windows.items.len > 0) f.app.windows.items[0].close();
        f.app.windows.deinit(t.allocator);
        f.app.bindings.deinit(t.allocator);
        f.env.deinit();
    }

    pub fn open(f: *Fixture, options: @import("../window_types.zig").PageOptions) !*Page {
        const win = try t.allocator.create(Window);
        errdefer t.allocator.destroy(win);
        win.* = .{ .app = &f.app };
        const page = try t.allocator.create(Page);
        errdefer t.allocator.destroy(page);
        page.* = .{
            .window = win,
            .gpa = t.allocator,
            .options = options,
            .core = .{ .gpa = t.allocator, .window = win, .options = options, .token = "0123456789abcdef".* },
        };
        try f.app.windows.append(t.allocator, win);
        win.page = page;
        return page;
    }
};
