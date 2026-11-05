//! A window's first frames are drawn on the CPU while a thread makes
//! Direct3D, through windows that are made but never shown: the messages
//! that draw them are sent to their window procedures.
const std = @import("std");
const w = @import("win32.zig");
const App = @import("app.zig").App;
const Surface = @import("surface.zig").Surface;
const present_mod = @import("surface_present.zig");
const ui = @import("../ui/ui.zig");

const t = std.testing;

const Page = struct {
    fn view(_: *Page, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(12), .gap = 8, .background = .hex(0xf0f0f0) });
        defer ui.end(c);
        ui.text(c, "Drawn on the CPU, then on the GPU", .{});
        _ = c.leaf(.{ .width = .{ .px = 120 }, .height = .{ .px = 40 }, .radius = 8, .background = .hex(0x0a84ff) }, .none, null);
    }
};

fn testApp(env: *std.process.Environ.Map) !*App {
    return App.createHidden(t.allocator, t.io, env, .{ .name = "myzig-surface-start-tests", .quit_on_signal = false });
}

fn paint(s: *Surface, h: w.HWND) void {
    _ = s.handle(h, w.WM_PAINT, 0, 0);
}

/// Waits for the thread as the message loop would: its message comes.
fn awaitRenderer(s: *Surface, h: w.HWND) !void {
    var msg: w.MSG = undefined;
    for (0..3000) |_| {
        if (w.PeekMessageW(&msg, h, present_mod.WM_GPU_READY, present_mod.WM_GPU_READY, 1) != 0) {
            _ = s.handle(h, msg.message, msg.wParam, msg.lParam);
            return;
        }
        std.Io.sleep(t.io, .fromMilliseconds(5), .awake) catch {};
    }
    return error.NoMessage;
}

test "the first frame is on the CPU; Direct3D then draws its pixels, and drops back to the CPU" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var page: Page = .{};
    const win = try app.newWindow(.{ .title = "Start", .content = .{ .view = ui.View.init(&page, Page.view) } });
    const h = win.hwnd.?;
    const s = win.surface.?;
    _ = s.handle(h, w.WM_SIZE, 0, 0);

    paint(s, h);
    try t.expect(s.direct3d == null);
    try t.expect(s.startup != null);
    try t.expect(s.pixels.len > 0);
    const cpu = try t.allocator.dupe(u8, s.pixels);
    defer t.allocator.free(cpu);
    const pw = s.pixel_w;
    const ph = s.pixel_h;

    try awaitRenderer(s, h);
    paint(s, h);
    try t.expect(s.startup == null);
    // No GPU here: the CPU goes on drawing, as it did.
    const r = s.direct3d orelse {
        try t.expect(s.pixels.len > 0);
        return;
    };
    try t.expectEqual(@as(usize, 0), s.pixels.len);
    try t.expectEqual(@as(usize, 0), s.cpu_damage.instances.items.len);

    // The buffer handed back after a present is the frame before: this one
    // is read before it shows, with the atlas the switch gave the GPU.
    try r.drawUnpresented(s.instances.items, s.scale, s.ctx.theme.background);
    const back = try r.readBackBuffer(t.allocator);
    defer t.allocator.free(back.bytes);
    try t.expectEqual(pw, back.width);
    try t.expectEqual(ph, back.height);
    var off: usize = 0;
    var inked: usize = 0;
    for (cpu, back.bytes) |a, b| {
        if (@abs(@as(i16, a) - @as(i16, b)) > 2) off += 1;
        if (b < 200) inked += 1;
    }
    // Blending rounds apart at a few edges (`d3d11_test.zig`), and the text
    // and box are there: not an empty frame.
    try t.expect(off * 20 <= cpu.len);
    try t.expect(inked > 100);

    // The device is lost, say: the CPU draws the frame whole again.
    s.dropDirect3D();
    s.stale = true;
    paint(s, h);
    try t.expectEqualSlices(u8, cpu, s.pixels);
}

test "a window closed while its renderer is being made waits for the thread and leaks nothing" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const app = try testApp(&env);
    defer app.destroy();
    var page: Page = .{};
    const win = try app.newWindow(.{ .title = "Gone", .content = .{ .view = ui.View.init(&page, Page.view) } });
    const h = win.hwnd.?;
    const s = win.surface.?;
    _ = s.handle(h, w.WM_SIZE, 0, 0);
    paint(s, h);
    try t.expect(s.startup != null);
    win.close();
    try t.expectEqual(@as(usize, 0), app.windows.items.len);
}
