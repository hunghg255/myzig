//! Views tested without a window: the same frames a window runs, input
//! simulated in process, time advanced by hand, and frames rendered
//! offscreen to PNG files (by Metal on macOS, by the CPU renderer where
//! text is myzig's own). Nothing reaches the screen, the mouse or the
//! keyboard.
//!
//!     var t: ui.Tester = undefined;
//!     try t.init(gpa, .init(&state, State.view), .{});
//!     defer t.deinit();
//!     try t.clickText("Increment");
//!     try std.testing.expect(t.hasText("1"));
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const text = @import("text.zig");
const raster = @import("raster.zig");
const portable = text.portable;
const metal = if (portable) struct {
    pub const Renderer = void;
} else @import("metal.zig");
const image = if (portable) void else @import("image.zig");
const frame_mod = @import("frame.zig");
const Theme = @import("theme.zig").Theme;
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const View = @import("ui.zig").View;

const runFor = @import("../platform.zig").runFor;

pub const Options = struct {
    width: f32 = 480,
    height: f32 = 360,
    scale: f32 = 2,
    dark: bool = false,
    /// Colors of its own, as a window's `theme` option gives.
    theme: ?Theme = null,
};

pub const Tester = struct {
    gpa: std.mem.Allocator,
    renderer: metal.Renderer,
    text: text.TextSystem,
    ctx: Context,
    view: View,
    size: types.Size,
    scale: f32,
    theme: Theme,
    instances: std.ArrayList(gpu.Instance) = .empty,
    /// Seconds each frame advances animations by.
    dt: f32 = 1.0 / 60.0,
    /// The app's menu bar, for a script's `shortcut:` steps: its
    /// accelerators run as a window's do (snapshots set it).
    accelerator: ?struct { ctx: *anyopaque, run: *const fn (ctx: *anyopaque, s: ctx_mod.Shortcut) bool } = null,
    /// What copy and cut wrote: tests never touch the system's clipboard.
    clipboard: std.ArrayList(u8) = .empty,
    /// The simulated clock, advanced by `dt` each frame.
    time: f64 = 0,

    /// Initializes in place (the context points into the tester) and runs
    /// the first frame.
    pub fn init(t: *Tester, gpa: std.mem.Allocator, view: View, opts: Options) !void {
        var renderer: metal.Renderer = if (portable) {} else try metal.Renderer.init();
        errdefer if (!portable) renderer.deinit();
        t.* = .{
            .gpa = gpa,
            .renderer = renderer,
            .text = if (portable) .init(gpa) else .init(gpa, renderer.device),
            .ctx = undefined,
            .view = view,
            .size = .{ .w = opts.width, .h = opts.height },
            .scale = opts.scale,
            .theme = opts.theme orelse if (opts.dark) Theme.dark_theme else Theme.light,
        };
        t.text.setScale(opts.scale);
        t.ctx = .init(gpa, &t.text);
        t.ctx.clipboard = .{ .ctx = t, .write = clipWrite };
        t.frame();
    }

    fn clipWrite(ctx: ?*anyopaque, text_: []const u8) void {
        const t: *Tester = @ptrCast(@alignCast(ctx));
        t.clipboard.clearRetainingCapacity();
        t.clipboard.appendSlice(t.gpa, text_) catch {};
    }

    pub fn deinit(t: *Tester) void {
        t.clipboard.deinit(t.gpa);
        t.instances.deinit(t.gpa);
        t.ctx.deinit();
        t.text.deinit();
        if (!portable) t.renderer.deinit();
    }

    pub fn frame(t: *Tester) void {
        _ = frame_mod.run(&t.ctx, t.view, &t.text, &t.instances, t.size, t.scale, t.theme, t.dt, t.time);
        t.time += t.dt;
    }

    /// Runs frames until animations settle (at most `max_seconds` of them).
    pub fn settle(t: *Tester, max_seconds: f32) void {
        var elapsed: f32 = 0;
        t.frame();
        while (t.ctx.animating and elapsed < max_seconds) : (elapsed += t.dt) t.frame();
    }

    /// Advances time by `seconds`, a frame at a time.
    pub fn advance(t: *Tester, seconds: f32) void {
        var elapsed: f32 = 0;
        while (elapsed < seconds) : (elapsed += t.dt) t.frame();
    }

    pub fn resize(t: *Tester, w: f32, h: f32) void {
        t.size = .{ .w = w, .h = h };
        t.frame();
    }

    pub fn moveTo(t: *Tester, x: f32, y: f32) void {
        t.ctx.input.mouse = .{ .x = x, .y = y };
        t.ctx.updateHot();
        t.frame();
    }

    /// Two clicks in quick succession: the second is a double click.
    pub fn doubleClick(t: *Tester, x: f32, y: f32) void {
        t.click(x, y);
        t.moveTo(x, y);
        t.ctx.input.click_count = 2;
        t.ctx.pointerDown();
        t.frame();
        t.ctx.pointerUp();
        t.frame();
        t.ctx.input.click_count = 1;
    }

    pub fn click(t: *Tester, x: f32, y: f32) void {
        t.moveTo(x, y);
        t.ctx.input.click_count = 1;
        t.ctx.pointerDown();
        t.frame();
        t.ctx.pointerUp();
        t.frame();
    }

    pub fn drag(t: *Tester, x1: f32, y1: f32, x2: f32, y2: f32) void {
        t.moveTo(x1, y1);
        t.ctx.pointerDown();
        t.frame();
        var i: f32 = 1;
        while (i <= 8) : (i += 1) {
            t.ctx.input.mouse = .{ .x = x1 + (x2 - x1) * i / 8, .y = y1 + (y2 - y1) * i / 8 };
            t.frame();
        }
        t.ctx.pointerUp();
        t.frame();
    }

    pub fn typeText(t: *Tester, s: []const u8) void {
        t.ctx.input.chars = s;
        t.frame();
    }

    /// Types `s` a character at a time, each its own event and frame, as a
    /// keyboard does: what reacts to what was just typed (Markdown's
    /// shortcuts, completions) sees each character.
    pub fn typeChars(t: *Tester, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(s.len, i + n);
            t.typeText(s[i..end]);
            i = end;
        }
    }

    /// Sends text input operations, as AppKit's input system would.
    pub fn textOps(t: *Tester, ops: []const ctx_mod.TextOp) void {
        t.ctx.input.ops = ops;
        t.frame();
        t.ctx.input.ops = &.{};
    }

    /// Offers a key combination, as a window does before text editing;
    /// true if the view took it.
    pub fn shortcut(t: *Tester, s: ctx_mod.Shortcut) bool {
        t.ctx.shortcut_taken = false;
        t.ctx.input.shortcut = s;
        t.frame();
        t.ctx.input.shortcut = null;
        return t.ctx.shortcut_taken;
    }

    /// A key going down (`down`) or up, as a view that follows keys
    /// (`Context.wants_keys`) sees it: `'w'`, `ui.Shortcut.up`.
    pub fn keyEdge(t: *Tester, code: u21, down: bool) void {
        if (down) t.ctx.input.key_down = code else t.ctx.input.key_up = code;
        t.frame();
    }

    /// `keyEdge` with where the key is (`Input.key_down_code`): `'z'` typed
    /// by the key at `.w` on an AZERTY keyboard.
    pub fn keyEdgeAt(t: *Tester, code: u21, physical: @import("keycode.zig").KeyCode, down: bool) void {
        if (down) {
            t.ctx.input.key_down = code;
            t.ctx.input.key_down_code = physical;
        } else {
            t.ctx.input.key_up = code;
            t.ctx.input.key_up_code = physical;
        }
        t.frame();
    }

    pub fn key(t: *Tester, k: ctx_mod.Key) void {
        t.ctx.input.key = k;
        t.frame();
    }

    /// Scrolls by `dy` points (up positive) with the pointer at (x, y), as
    /// a touchpad does: at once.
    pub fn scroll(t: *Tester, x: f32, y: f32, dy: f32) void {
        t.scrollWith(x, y, dy, false);
    }

    /// A notch of a mouse wheel of `dy` points: a scrolling box glides
    /// there as the clock advances (`advance`).
    pub fn wheel(t: *Tester, x: f32, y: f32, dy: f32) void {
        t.scrollWith(x, y, dy, true);
    }

    fn scrollWith(t: *Tester, x: f32, y: f32, dy: f32, notch: bool) void {
        t.ctx.input.mouse = .{ .x = x, .y = y };
        if (if (notch) t.ctx.applyWheel(dy) else t.ctx.applyScroll(dy)) {
            t.frame();
        } else if (t.ctx.wants_wheel) {
            t.ctx.input.scroll = .{ .y = dy };
            t.frame();
        }
        t.ctx.updateHot();
    }

    /// The rectangle of the text `s` in the last frame.
    pub fn findText(t: *Tester, s: []const u8) ?types.Rect {
        for (t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, s)) return n.rect,
            .icon, .image, .none => {},
        };
        return null;
    }

    pub fn hasText(t: *Tester, s: []const u8) bool {
        return t.findText(s) != null;
    }

    /// Whether a text drawn contains `s` (a terminal's row, a paragraph).
    pub fn containsText(t: *Tester, s: []const u8) bool {
        for (t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.indexOf(u8, tx.str, s) != null) return true,
            .icon, .image, .none => {},
        };
        return false;
    }

    /// Clicks the middle of the text `s`.
    /// A press of the secondary button (what opens a context menu).
    pub fn rightClick(t: *Tester, x: f32, y: f32) void {
        t.moveTo(x, y);
        t.ctx.input.right_pressed = true;
        t.frame();
    }

    /// A press of the middle button.
    pub fn middleClick(t: *Tester, x: f32, y: f32) void {
        t.moveTo(x, y);
        t.ctx.input.middle_pressed = true;
        t.frame();
    }

    pub fn clickText(t: *Tester, s: []const u8) !void {
        const r = t.findText(s) orelse return error.TextNotFound;
        t.click(r.x + r.w / 2, r.y + r.h / 2);
    }

    /// Renders the last frame offscreen and writes it to a PNG file.
    pub fn screenshot(t: *Tester, path: []const u8) !void {
        const pixels = try t.render(t.gpa);
        defer pixels.deinit(t.gpa);
        if (portable) {
            try @import("png.zig").writePng(t.gpa, std.Io.Threaded.global_single_threaded.io(), path, pixels);
        } else try image.writePng(path, pixels);
    }

    /// The last frame's pixels (BGRA, premultiplied); free with `deinit`.
    pub fn render(t: *Tester, gpa: std.mem.Allocator) !gpu.Pixels {
        if (!portable) t.renderer.syncImages(&t.text.images);
        if (!portable) return t.renderer.drawOffscreen(gpa, t.instances.items, t.text.texture(), t.size, t.scale, t.theme.background);
        const px = t.pixelSize();
        const bytes = try gpa.alloc(u8, px[0] * px[1] * 4);
        t.rasterize(bytes);
        return .{ .bytes = bytes, .width = px[0], .height = px[1] };
    }

    /// The frame's size in pixels.
    pub fn pixelSize(t: *const Tester) [2]usize {
        return .{
            @intFromFloat(@max(1, @round(t.size.w * t.scale))),
            @intFromFloat(@max(1, @round(t.size.h * t.scale))),
        };
    }

    /// Draws the last frame with the CPU renderer into `bytes` (BGRA,
    /// premultiplied, `pixelSize` large), where text is myzig's own: what
    /// benchmarks time where there is no Metal.
    pub fn rasterize(t: *Tester, bytes: []u8) void {
        if (!portable) @panic("rasterize: the CPU renderer draws myzig's own text only");
        const px = t.pixelSize();
        std.debug.assert(bytes.len == px[0] * px[1] * 4);
        const out: gpu.Pixels = .{ .bytes = bytes, .width = px[0], .height = px[1] };
        raster.draw(out, t.instances.items, t.text.atlas.mask(), t.text.images.pictures(), t.scale, t.theme.background);
    }

    /// Runs a script of steps separated by `;`: `click:TEXT`, `move:TEXT`,
    /// `type:TEXT` (a character an event), `key:enter|backspace|tab|escape|left|right`,
    /// `shortcut:ctrl+shift+p` (cmd, ctrl, alt, shift, then a character or
    /// up, down, left, right, enter, tab, escape, f1 to f12),
    /// `scroll:DY` (at the pointer), `drag:FROM>TO` (each a text or `X,Y`
    /// in points), `wait:SECONDS` (simulated time), `frames:N` (N frames,
    /// then no settling: a snapshot mid-animation), `live:SECONDS` (the
    /// real event loop: replies, processes, timers), `resize:WxH`. Each
    /// step but `frames` lets animations settle after it.
    pub fn runScript(t: *Tester, script: []const u8) !void {
        var steps = std.mem.splitScalar(u8, script, ';');
        while (steps.next()) |raw| {
            const step = std.mem.trim(u8, raw, " ");
            if (step.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, step, ':') orelse step.len;
            const op = step[0..colon];
            const arg = if (colon < step.len) step[colon + 1 ..] else "";
            if (std.mem.eql(u8, op, "click")) {
                try t.clickText(arg);
            } else if (std.mem.eql(u8, op, "move")) {
                const r = t.findText(arg) orelse return error.TextNotFound;
                t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
            } else if (std.mem.eql(u8, op, "type")) {
                t.typeChars(arg);
            } else if (std.mem.eql(u8, op, "drag")) {
                const gt = std.mem.indexOfScalar(u8, arg, '>') orelse return error.BadDrag;
                const a = try t.place(arg[0..gt]);
                const b = try t.place(arg[gt + 1 ..]);
                t.drag(a.x, a.y, b.x, b.y);
            } else if (std.mem.eql(u8, op, "frames")) {
                const n = try std.fmt.parseInt(u32, arg, 10);
                for (0..n) |_| t.frame();
                continue;
            } else if (std.mem.eql(u8, op, "key")) {
                t.key(std.meta.stringToEnum(ctx_mod.Key, arg) orelse return error.UnknownKey);
            } else if (std.mem.eql(u8, op, "shortcut")) {
                const sc = try parseShortcut(arg);
                // As a window: the menu's accelerators first, unless the
                // view asks for keys first.
                const accel = t.accelerator;
                const first = t.ctx.keys_first;
                if (!first and accel != null and accel.?.run(accel.?.ctx, sc)) {
                    t.frame();
                } else if (!t.shortcut(sc) and first and accel != null) {
                    if (accel.?.run(accel.?.ctx, sc)) t.frame();
                }
            } else if (std.mem.eql(u8, op, "scroll")) {
                t.scroll(t.ctx.input.mouse.x, t.ctx.input.mouse.y, try std.fmt.parseFloat(f32, arg));
            } else if (std.mem.eql(u8, op, "wait")) {
                t.advance(try std.fmt.parseFloat(f32, arg));
            } else if (std.mem.eql(u8, op, "live")) {
                const seconds = try std.fmt.parseFloat(f64, arg);
                var waited: f64 = 0;
                while (waited < seconds) : (waited += 0.05) {
                    runFor(0.05);
                    t.frame();
                }
            } else if (std.mem.eql(u8, op, "resize")) {
                const x = std.mem.indexOfScalar(u8, arg, 'x') orelse return error.BadSize;
                t.resize(try std.fmt.parseFloat(f32, arg[0..x]), try std.fmt.parseFloat(f32, arg[x + 1 ..]));
            } else return error.UnknownStep;
            t.settle(2);
        }
    }

    /// A script's place: `X,Y` in points, or the middle of a text.
    fn place(t: *Tester, s: []const u8) !types.Point {
        if (std.mem.indexOfScalar(u8, s, ',')) |comma| {
            const x = std.fmt.parseFloat(f32, std.mem.trim(u8, s[0..comma], " ")) catch null;
            const y = std.fmt.parseFloat(f32, std.mem.trim(u8, s[comma + 1 ..], " ")) catch null;
            if (x != null and y != null) return .{ .x = x.?, .y = y.? };
        }
        const r = t.findText(s) orelse return error.TextNotFound;
        return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
    }
};

/// A script's `shortcut:` step: "ctrl+shift+p", "alt+up", "cmd+f3".
fn parseShortcut(s: []const u8) !ctx_mod.Shortcut {
    const S = ctx_mod.Shortcut;
    var sc: S = .{ .key = 0 };
    var it = std.mem.splitScalar(u8, s, '+');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "cmd")) sc.cmd = true else if (std.mem.eql(u8, part, "ctrl")) sc.ctrl = true else if (std.mem.eql(u8, part, "alt")) sc.alt = true else if (std.mem.eql(u8, part, "shift")) sc.shift = true else if (part.len == 1) {
            sc.key = part[0];
        } else {
            const names = [_]struct { []const u8, u21 }{
                .{ "up", S.up },       .{ "down", S.down }, .{ "left", S.left },     .{ "right", S.right },
                .{ "enter", S.enter }, .{ "tab", S.tab },   .{ "escape", S.escape },
            };
            for (names) |n| if (std.mem.eql(u8, part, n[0])) {
                sc.key = n[1];
            };
            if (part.len >= 2 and part[0] == 'f') if (std.fmt.parseInt(u21, part[1..], 10)) |n| {
                if (n >= 1 and n <= 12) sc.key = S.f1 + n - 1;
            } else |_| {};
        }
    }
    if (sc.key == 0) return error.UnknownKey;
    return sc;
}

test parseShortcut {
    const sc = try parseShortcut("ctrl+shift+p");
    try std.testing.expect(sc.ctrl and sc.shift and sc.key == 'p');
    try std.testing.expectEqual(ctx_mod.Shortcut.f1 + 2, (try parseShortcut("f3")).key);
}
