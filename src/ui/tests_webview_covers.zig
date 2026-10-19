//! What native UI paints over a web view, through the Tester: the box of
//! what overlaps the page (popovers, dialogs, boxes painted after it)
//! within its clip, none when nothing does, and the cover's pixels, which
//! are the window's where they are opaque and transparent where the page
//! shows. A Tester has no window: no page is made, the covers are what a
//! window's platform would show.
const std = @import("std");
const ui = @import("ui.zig");
const webview = @import("webview.zig");
const cover = @import("../page_embed_cover.zig");
const testing = std.testing;

const App = struct {
    menu: ui.OverlayState = .{},
    dialog: ui.OverlayState = .{},
    badge: bool = false,
    clicked: u32 = 0,
    v: webview.WebView = .{},

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.row(c, .{ .width = .fill, .padding = .all(8) });
        const more = ui.button(c, "Menu", .{});
        if (more.clicked) s.menu.toggle();
        if (ui.popover(c, &s.menu, more, .{})) |p| {
            defer p.end();
            if (ui.button(c, "Over the page", .{}).clicked) s.clicked += 1;
        }
        ui.end(c);
        _ = webview.webView(c, &s.v, .{ .grow = 1, .padding = .all(4) });
        if (s.badge) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 300, .y = 200 }, .width = .{ .px = 40 }, .height = .{ .px = 20 }, .background = .hex(0xc81e1e) }, .none, null);
        if (ui.dialog(c, &s.dialog, .{})) |d| {
            defer d.end();
            ui.text(c, "A dialog", .{});
        }
    }
};

fn setUp(t: *ui.Tester, s: *App, scale: f32) !void {
    try t.init(testing.allocator, .init(s, App.view), .{ .width = 400, .height = 300, .scale = scale });
}

test "nothing over a web view: no cover, nothing drawn" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try setUp(&t, &s, 2);
    defer t.deinit();
    try testing.expect(s.v.shown != null);
    try testing.expect(s.v.cover == null);
    try testing.expect(webview.coverImage(&t.ctx, &s.v) == null);
    try testing.expectEqual(@as(usize, 0), s.v.cover_px.items.len);
}

test "a popover over a web view covers it where they meet" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try setUp(&t, &s, 2);
    defer t.deinit();
    const menu = t.findText("Menu").?;
    t.click(menu.x + 2, menu.y + 2);
    t.settle(1);
    try testing.expect(s.menu.open);
    const clip = s.v.shown.?.clip;
    const r = s.v.cover.?;
    // Within the page's clip, from its top (the popover starts above it).
    try testing.expect(r.x >= clip.x and r.y >= clip.y - 0.01);
    try testing.expect(r.x + r.w <= clip.x + clip.w + 0.01 and r.y + r.h <= clip.y + clip.h + 0.01);
    try testing.expectApproxEqAbs(clip.y, r.y, 0.01);
    const item = t.findText("Over the page").?;
    try testing.expect(item.y + item.h <= r.y + r.h);
    // Far from it, the page alone.
    try testing.expect(r.x + r.w < clip.x + clip.w - 100);
    // Closed, nothing covers it.
    t.key(.escape);
    t.settle(1);
    try testing.expect(!s.menu.open);
    try testing.expect(s.v.cover == null);
}

test "a box painted after a web view covers it; a dialog's backdrop covers all of it" {
    var s: App = .{ .badge = true };
    var t: ui.Tester = undefined;
    try setUp(&t, &s, 2);
    defer t.deinit();
    const r = s.v.cover.?;
    try testing.expectApproxEqAbs(@as(f32, 300), r.x, 1.01);
    try testing.expectApproxEqAbs(@as(f32, 200), r.y, 1.01);
    try testing.expect(r.w <= 42 and r.h <= 22);
    s.badge = false;
    s.dialog.show();
    t.settle(1);
    const all = s.v.cover.?;
    const clip = s.v.shown.?.clip;
    try testing.expectApproxEqAbs(clip.x, all.x, 0.01);
    try testing.expectApproxEqAbs(clip.w, all.w, 0.01);
    try testing.expectApproxEqAbs(clip.h, all.h, 0.01);
}

/// The cover's pixels against the window's frame, drawn whole.
fn checkPixels(t: *ui.Tester, s: *App) !cover.Image {
    const img = webview.coverImage(&t.ctx, &s.v).?;
    const frame = try t.render(testing.allocator);
    defer frame.deinit(testing.allocator);
    try testing.expect(cover.matches(img, frame.bytes, frame.width));
    // Where it is, in the window's pixels: the cover's box, rounded out
    // (to the platform's points, the nearest pixels at 1.25), within the
    // page's.
    const sc = s.v.shown.?.scale;
    const r = s.v.cover.?;
    const clip = s.v.shown.?.clip;
    try testing.expect(@as(f32, @floatFromInt(img.x)) <= @max(r.x * sc, @round(clip.x * sc)) + 0.5);
    try testing.expect(@as(f32, @floatFromInt(img.y)) <= @max(r.y * sc, @round(clip.y * sc)) + 0.5);
    try testing.expect(@as(f32, @floatFromInt(img.x + @as(i32, @intCast(img.w)))) >= @min((r.x + r.w) * sc, @round((clip.x + clip.w) * sc)) - 0.5);
    try testing.expect(@as(f32, @floatFromInt(img.y + @as(i32, @intCast(img.h)))) >= @min((r.y + r.h) * sc, @round((clip.y + clip.h) * sc)) - 0.5);
    return img;
}

test "a cover's pixels are the window's where opaque, transparent where the page shows" {
    for ([_]f32{ 2, 1, 1.25 }) |scale| {
        var s: App = .{};
        var t: ui.Tester = undefined;
        try setUp(&t, &s, scale);
        defer t.deinit();
        const menu = t.findText("Menu").?;
        t.click(menu.x + 2, menu.y + 2);
        t.settle(1);
        const img = try checkPixels(&t, &s);
        const n = cover.census(img);
        // The popover's panel is opaque; past its shadow, the page shows.
        try testing.expect(n[0] > img.px.len / 4);
        try testing.expect(n[1] > 0);
        // At the item, native UI's; drawn again only when it changes.
        const item = t.findText("Over the page").?;
        const at = img.at(@intFromFloat(@round((item.x + 2) * scale)), @intFromFloat(@round((item.y + item.h / 2) * scale)));
        try testing.expectEqual(@as(u32, 255), at >> 24);
        const hash = s.v.cover_hash;
        const px = s.v.cover_px.items.ptr;
        t.frame();
        _ = webview.coverImage(&t.ctx, &s.v).?;
        try testing.expectEqual(hash, s.v.cover_hash);
        try testing.expectEqual(px, s.v.cover_px.items.ptr);
    }
}

test "a dialog's dimmed backdrop: a cover over all the page, translucent" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try setUp(&t, &s, 2);
    defer t.deinit();
    s.dialog.show();
    t.settle(1);
    const img = try checkPixels(&t, &s);
    // The backdrop takes the pointer everywhere: no pixel lets it through.
    try testing.expectEqual(@as(usize, 0), cover.census(img)[1]);
    const corner = img.px[0];
    try testing.expect(corner >> 24 > 0 and corner >> 24 < 255);
}

test "the overlap of a frame's instances: shadows grow, clips cut, invisible quads count not" {
    const gpu = @import("gpu.zig");
    const clip: ui.Rect = .{ .x = 100, .y = 100, .w = 100, .h = 100 };
    const none_drawn = [_]gpu.Instance{
        .{ .rect = .{ 120, 120, 20, 20 }, .color = .{ 0, 0, 0, 0 } },
        .{ .rect = .{ 0, 0, 40, 40 }, .color = .{ 1, 0, 0, 1 } },
    };
    try testing.expect(cover.overlap(&none_drawn, 0, clip) == null);
    const shadow = [_]gpu.Instance{.{ .rect = .{ 60, 60, 30, 30 }, .color = .{ 0, 0, 0, 0.3 }, .border_width = 4, .kind = gpu.Kind.shadow }};
    const r = cover.overlap(&shadow, 0, clip).?;
    try testing.expectEqual(@as(f32, 100), r.x);
    try testing.expectEqual(@as(f32, 103), r.x + r.w); // 60 + 30 + 4 * 3 + 1
    const cut = [_]gpu.Instance{.{ .rect = .{ 150, 150, 100, 100 }, .color = .{ 1, 1, 1, 1 }, .clip = .{ 0, 0, 160, 170 } }};
    const k = cover.overlap(&cut, 0, clip).?;
    try testing.expectEqual(@as(f32, 160), k.x + k.w);
    try testing.expectEqual(@as(f32, 170), k.y + k.h);
    // From the second on: the first is under the page.
    const two = [_]gpu.Instance{ cut[0], none_drawn[0] };
    try testing.expect(cover.overlap(&two, 1, clip) == null);
    try testing.expect(cover.pixelArea(k, clip, 2, 1).?[0] == 298);
    try testing.expectEqual([4]i32{ 298, 298, 320, 340 }, cover.pixelArea(k, clip, 2, 1).?);
    try testing.expectEqual([4]i32{ 298, 298, 320, 340 }, cover.pixelArea(k, clip, 2, 2).?);
    try testing.expectEqual([4]i32{ 149, 149, 160, 170 }, cover.pixelArea(k, clip, 1, 1).?);
}
