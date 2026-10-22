//! Native UI on Windows: the window's client area shows frames Direct3D 11
//! draws (`ui/d3d11.zig`, into a flip model swap chain), or, where it is
//! unavailable, the very same pixels the CPU renderer draws (GDI copies
//! them), at the monitor's DPI, fed the mouse,
//! the wheel, keys and typed characters from the window procedure. Frames
//! run on input and while something animates (a 60 Hz timer); idle,
//! nothing runs.
const std = @import("std");
const w = @import("win32.zig");
const ui = @import("../ui/ui.zig");
const types = @import("../ui/types.zig");
const gpu = @import("../ui/gpu.zig");
const d3d11 = @import("../ui/d3d11.zig");
const text = @import("../ui/text.zig");
const frame_mod = @import("../ui/frame.zig");
const ctx_mod = @import("../ui/context.zig");
const clock = @import("../ui/clock.zig");
const Theme = @import("../ui/theme.zig").Theme;
const Context = ctx_mod.Context;
const Window = @import("window.zig").Window;
const surface_access = @import("surface_access.zig");
const damage = @import("../ui/damage.zig");
const present_mod = @import("surface_present.zig");

extern "user32" fn IsIconic(hwnd: w.HWND) callconv(.winapi) w.BOOL;

/// Posted for a frame requested from outside the view.
pub const WM_FRAME = w.WM_APP + 1;
const tick_timer = 1;
/// A frame asked for later (`frameIn`).
const later_timer: usize = 2;

pub const Surface = struct {
    gpa: std.mem.Allocator,
    window: *Window,
    text: text.TextSystem,
    ctx: Context,
    view: ui.View,
    instances: std.ArrayList(gpu.Instance) = .empty,
    /// Direct3D, once the window is there to draw into; null where it is
    /// unavailable (or failed), and frames are drawn on the CPU.
    direct3d: ?*d3d11.Renderer = null,
    direct3d_tried: bool = false,
    pixels: []u8 = &.{},
    pixel_w: usize = 0,
    pixel_h: usize = 0,
    stale: bool = true,
    /// What changed since the pixels were drawn on the CPU (`damage.zig`).
    cpu_damage: damage.Differ,
    /// Presents wait for room ahead of the screen (`surface_present.zig`):
    /// a frame drawn waits to present, and the timer's frames wait for it.
    latency: present_mod.Latency,
    pending: bool = false,
    frame_wanted: bool = false,
    size: types.Size = .{},
    scale: f32 = 1,
    last_frame_time: f64 = 0,
    start_time: f64,
    ticking: bool = false,
    frame_posted: bool = false,
    /// A frame is being built: a modal loop the view started (a file
    /// dialog, a message box) must not build another inside it.
    in_frame: bool = false,
    /// A frame was asked for while one was built: it runs after.
    frame_again: bool = false,
    tracking: bool = false,
    theme_override: ?Theme = null,
    cursor: ctx_mod.Cursor = .arrow,
    /// A UTF-16 high surrogate waiting for its other half.
    high: u16 = 0,
    chars: [8]u8 = undefined,
    /// UI Automation's view of the frames, once a client asked.
    access: ?*@import("uia.zig").Access = null,

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        self.* = .{ .gpa = gpa, .window = window, .text = .init(gpa), .ctx = undefined, .view = view, .theme_override = theme_override, .start_time = clock.now(), .cpu_damage = .init(gpa), .latency = .{ .gpa = gpa } };
        self.ctx = .init(gpa, &self.text);
        self.ctx.host = window;
        return self;
    }

    pub fn destroy(self: *Surface) void {
        surface_access.destroy(self);
        // Going: the pictures need no copy in memory.
        self.text.images.sink = null;
        self.dropDirect3D();
        self.cpu_damage.deinit();
        self.instances.deinit(self.gpa);
        self.gpa.free(self.pixels);
        self.ctx.deinit();
        self.text.deinit();
        self.gpa.destroy(self);
    }

    fn hwnd(self: *Surface) ?w.HWND {
        return self.window.hwnd;
    }

    fn theme(self: *Surface) Theme {
        if (self.theme_override) |t| return t;
        return if (@import("desktop.zig").isDark()) Theme.dark_theme else Theme.light;
    }

    pub fn frame(self: *Surface) void {
        if (self.size.w <= 0 or self.size.h <= 0) return;
        if (self.in_frame) {
            self.frame_again = true;
            return;
        }
        self.in_frame = true;
        defer {
            self.in_frame = false;
            if (self.frame_again) {
                self.frame_again = false;
                self.requestFrame();
            }
        }
        const c = &self.ctx;
        const now = clock.now();
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        self.window.afterFrame(self);
        self.stale = true;
        if (self.hwnd()) |h| _ = w.InvalidateRect(h, null, 0);
        self.updateCursor();
        const more = c.animating or r.hot_changed;
        if (more and !self.ticking) if (self.hwnd()) |h| {
            _ = w.SetTimer(h, tick_timer, 16, null);
            self.ticking = true;
        };
        // Something changes now and then: one frame, that much later.
        if (!more) if (c.frame_in) |s| if (self.hwnd()) |h| {
            _ = w.SetTimer(h, later_timer, @intFromFloat(@max(1, s * 1000)), null);
        };
        if (!c.animating) self.last_frame_time = 0;
    }

    /// A frame no input asked for (the animation's timer, a request from
    /// outside the view, one asked for later): held while the window is
    /// minimized, as browsers draw nothing for windows out of sight; it
    /// runs as the window is restored (`WM_SIZE`). Input still builds one.
    /// A hidden window still draws: runs with `--myzig-hidden` check it.
    fn pacedFrame(self: *Surface) void {
        if (self.hwnd()) |h| if (IsIconic(h) != 0) {
            if (self.ticking) {
                _ = w.KillTimer(h, tick_timer);
                self.ticking = false;
            }
            return;
        };
        self.frame();
    }

    pub fn requestFrame(self: *Surface) void {
        if (self.frame_posted) return;
        const h = self.hwnd() orelse return;
        self.frame_posted = true;
        _ = w.PostMessageW(h, WM_FRAME, 0, 0);
    }

    fn dropDirect3D(self: *Surface) void {
        self.latency.stop();
        self.pending = false;
        const r = self.direct3d orelse return;
        // The pictures the GPU held, in memory again where they were.
        self.text.images.useCpu();
        r.deinit();
        self.gpa.destroy(r);
        self.direct3d = null;
    }

    /// The renderer on the GPU, made with the first frame shown.
    fn gpuRenderer(self: *Surface, h: w.HWND, pw: usize, ph: usize) ?*d3d11.Renderer {
        if (self.direct3d_tried) return self.direct3d;
        self.direct3d_tried = true;
        const r = present_mod.renderer(self.gpa, h, pw, ph) orelse return null;
        self.direct3d = r;
        self.latency.handle = r.latency;
        // Pictures go straight to the GPU: no copy of their atlas in memory.
        self.text.images.useSink(.{ .ctx = r, .upload = d3d11.Renderer.uploadImage });
        return r;
    }

    /// What the frame drawn last is, `pw` × `ph` pixels.
    fn frameOf(self: *Surface, pw: usize, ph: usize) damage.Frame {
        return .{
            .instances = self.instances.items,
            .width = @intCast(pw),
            .height = @intCast(ph),
            .scale = self.scale,
            .clear = self.ctx.theme.background,
            .atlas = damage.atlasKey(&self.text.atlas),
            .images = self.text.images.generation,
        };
    }

    /// Presents the frame drawn, taking its token (waiting for one unless
    /// `wait` is false); false if Direct3D failed.
    fn presentNow(self: *Surface, r: *d3d11.Renderer, sync: u32, wait: bool) bool {
        self.pending = false;
        self.latency.take(wait);
        r.present(sync) catch |e| {
            std.log.warn("myzig: Direct3D failed ({s}): frames are drawn on the CPU", .{@errorName(e)});
            self.dropDirect3D();
            self.stale = true;
            if (self.hwnd()) |h| _ = w.InvalidateRect(h, null, 0);
            return false;
        };
        return true;
    }

    /// The thread waiting for room ahead of the screen is done: the frame
    /// waiting presents, and the timer's frame waiting draws.
    fn presented(self: *Surface, signaled: bool) void {
        if (!self.latency.done(signaled)) return;
        if (self.pending) if (self.direct3d) |r| {
            if (!self.presentNow(r, 1, false)) return;
        };
        if (self.frame_wanted) {
            self.frame_wanted = false;
            self.frame();
        }
    }

    /// Draws the frame with Direct3D, only what changed, and presents it,
    /// or leaves it to present once the screen has room for it; false if
    /// it can't (the device was lost, say), and it is drawn on the CPU from
    /// then on.
    fn present(self: *Surface, h: w.HWND, pw: usize, ph: usize) bool {
        const r = self.gpuRenderer(h, pw, ph) orelse return false;
        r.syncAtlas(self.text.atlas.mask(), self.text.atlas.generation, self.text.atlas.takeDirty());
        r.syncImages(&self.text.images);
        const before: [2]u32 = .{ r.width, r.height };
        r.resize(@intCast(pw), @intCast(ph)) catch {};
        const resized = before[0] != r.width or before[1] != r.height;
        _ = r.render(self.frameOf(pw, ph)) catch |e| {
            std.log.warn("myzig: Direct3D failed ({s}): frames are drawn on the CPU", .{@errorName(e)});
            self.dropDirect3D();
            return false;
        };
        self.stale = false;
        if (!r.unpresented()) return true;
        // A resize's frame shows at once, at its size.
        if (resized) return self.presentNow(r, 0, true);
        if (!self.latency.ready()) {
            self.pending = true;
            self.latency.arm(h);
            return true;
        }
        _ = self.presentNow(r, 1, true);
        return true;
    }

    fn render(self: *Surface) void {
        const pw: usize = @intFromFloat(@max(1, @round(self.size.w * self.scale)));
        const ph: usize = @intFromFloat(@max(1, @round(self.size.h * self.scale)));
        if (pw != self.pixel_w or ph != self.pixel_h) {
            const px = self.gpa.alloc(u8, pw * ph * 4) catch return;
            self.gpa.free(self.pixels);
            self.pixels = px;
            self.pixel_w = pw;
            self.pixel_h = ph;
            self.cpu_damage.invalidate();
        }
        const out: gpu.Pixels = .{ .bytes = self.pixels, .width = pw, .height = ph };
        _ = damage.drawCpu(&self.cpu_damage, out, self.frameOf(pw, ph), self.text.atlas.mask(), self.text.images.pictures(), false);
        self.stale = false;
    }

    fn paint(self: *Surface, h: w.HWND) void {
        var ps: w.PAINTSTRUCT = undefined;
        const dc = w.BeginPaint(h, &ps) orelse return;
        defer _ = w.EndPaint(h, &ps);
        if (self.size.w > 0 and self.size.h > 0) {
            const pw: usize = @intFromFloat(@max(1, @round(self.size.w * self.scale)));
            const ph: usize = @intFromFloat(@max(1, @round(self.size.h * self.scale)));
            if (self.present(h, pw, ph)) return;
        }
        if (self.stale or self.pixels.len == 0) self.render();
        if (self.pixels.len == 0) return;
        // A negative height: rows from the top, as the renderer writes them.
        const info: w.BITMAPINFOHEADER = .{ .biWidth = @intCast(self.pixel_w), .biHeight = -@as(i32, @intCast(self.pixel_h)) };
        _ = w.SetDIBitsToDevice(dc, 0, 0, @intCast(self.pixel_w), @intCast(self.pixel_h), 0, 0, 0, @intCast(self.pixel_h), self.pixels.ptr, &info, 0);
    }

    fn updateCursor(self: *Surface) void {
        self.cursor = self.ctx.cursor orelse if (self.ctx.cursor_text) .text else if (self.ctx.cursor_hand) .hand else .arrow;
    }

    fn setCursor(self: *Surface) void {
        // IDC_ARROW, IDC_HAND, IDC_IBEAM, IDC_SIZEWE, IDC_SIZENS.
        const id: usize = switch (self.cursor) {
            .arrow => 32512,
            .hand => 32649,
            .text => 32513,
            .resize_left_right => 32644,
            .resize_up_down => 32645,
        };
        _ = w.SetCursor(w.LoadCursorW(null, id));
    }

    fn updateSize(self: *Surface, h: w.HWND) void {
        var r: w.RECT = .{};
        _ = w.GetClientRect(h, &r);
        const dpi = w.GetDpiForWindow(h);
        self.scale = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
        self.size = .{ .w = @as(f32, @floatFromInt(r.right - r.left)) / self.scale, .h = @as(f32, @floatFromInt(r.bottom - r.top)) / self.scale };
        self.text.setScale(self.scale);
    }

    fn setMouse(self: *Surface, lp: w.LPARAM) void {
        const x: i16 = @truncate(lp);
        const y: i16 = @truncate(lp >> 16);
        self.ctx.input.mouse = .{ .x = @as(f32, @floatFromInt(x)) / self.scale, .y = @as(f32, @floatFromInt(y)) / self.scale };
        self.ctx.input.shift = w.GetKeyState(0x10) < 0;
        self.ctx.input.cmd = false;
        self.ctx.input.ctrl = w.GetKeyState(0x11) < 0;
    }

    /// The window procedure's part for native UI; null for messages it
    /// leaves to the default.
    pub fn handle(self: *Surface, h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
        switch (msg) {
            surface_access.WM_GETOBJECT => return surface_access.getObject(self, h, wp, lp),
            w.WM_PAINT => self.paint(h),
            w.WM_ERASEBKGND => return 1,
            w.WM_SIZE, w.WM_DPICHANGED => {
                self.updateSize(h);
                self.frame();
            },
            w.WM_TIMER => if (wp == later_timer) {
                _ = w.KillTimer(h, later_timer);
                self.pacedFrame();
            } else if (wp == tick_timer) {
                // A frame waits for room ahead of the screen: this one
                // draws once it presented.
                if (self.pending) self.frame_wanted = true else self.pacedFrame();
                if (!self.ctx.animating) {
                    _ = w.KillTimer(h, tick_timer);
                    self.ticking = false;
                }
            },
            WM_FRAME => {
                self.frame_posted = false;
                self.pacedFrame();
            },
            present_mod.WM_PRESENT => self.presented(wp != 0),
            w.WM_SETCURSOR => {
                // Over the client area only: the frame keeps its own.
                if (lp & 0xffff != 1) return null;
                self.setCursor();
                return 1;
            },
            w.WM_MOUSEMOVE => {
                if (!self.tracking) {
                    var t: w.TRACKMOUSEEVENT = .{ .dwFlags = 2, .hwndTrack = h };
                    _ = w.TrackMouseEvent(&t);
                    self.tracking = true;
                }
                self.setMouse(lp);
                const before = self.ctx.hot;
                self.ctx.updateHot();
                if (self.ctx.input.down or self.ctx.hot != before or self.ctx.wants_moves) {
                    self.frame();
                } else if (self.ctx.pointerOverText() != self.ctx.cursor_text) {
                    // Onto or off text that selects: the cursor only.
                    self.ctx.cursor_text = !self.ctx.cursor_text;
                    self.updateCursor();
                }
            },
            w.WM_MOUSELEAVE => {
                self.tracking = false;
                self.ctx.input.mouse = .{ .x = -1e6, .y = -1e6 };
                if (self.ctx.hot != 0) {
                    self.ctx.updateHot();
                    self.frame();
                }
            },
            w.WM_LBUTTONDOWN, w.WM_LBUTTONDBLCLK => {
                // The keyboard comes back from a web view's page.
                if (self.window.web_views.items.len > 0) _ = w.SetFocus(h);
                _ = w.SetCapture(h);
                self.setMouse(lp);
                self.ctx.input.click_count = if (msg == w.WM_LBUTTONDBLCLK) 2 else 1;
                self.ctx.updateHot();
                self.ctx.pointerDown();
                self.frame();
            },
            w.WM_RBUTTONDOWN => {
                self.setMouse(lp);
                self.ctx.updateHot();
                self.ctx.input.right_pressed = true;
                self.frame();
            },
            w.WM_MBUTTONDOWN => {
                self.setMouse(lp);
                self.ctx.updateHot();
                self.ctx.input.middle_pressed = true;
                self.frame();
            },
            w.WM_LBUTTONUP => {
                _ = w.ReleaseCapture();
                self.setMouse(lp);
                self.ctx.updateHot();
                self.ctx.pointerUp();
                self.frame();
            },
            w.WM_MOUSEWHEEL, w.WM_MOUSEHWHEEL => @import("surface_gesture.zig").wheel(self, h, wp, lp, msg == w.WM_MOUSEHWHEEL),
            w.WM_KEYDOWN, w.WM_SYSKEYDOWN => {
                // Its edge, for views that follow keys (not the repeats).
                const repeat = (@as(usize, @bitCast(lp)) >> 30) & 1 != 0;
                if (self.ctx.wants_keys and !repeat) {
                    self.ctx.input.key_down = codeOf(@intCast(wp));
                    self.ctx.input.key_down_code = @import("../ui/keycode.zig").fromLparam(lp);
                }
                const taken = self.keyDown(@intCast(wp));
                if (self.ctx.input.key_down != null) self.frame();
                if (taken) return 0 else return null;
            },
            w.WM_KEYUP, w.WM_SYSKEYUP => {
                if (!self.ctx.wants_keys) return null;
                self.ctx.input.key_up = codeOf(@intCast(wp));
                self.ctx.input.key_up_code = @import("../ui/keycode.zig").fromLparam(lp);
                self.frame();
                return null;
            },
            w.WM_CHAR => self.char(@truncate(wp)),
            else => return null,
        }
        return 0;
    }

    /// A virtual key as views see it: characters lowercase, other keys
    /// as `Shortcut.up` and the like; 0 for the rest.
    fn codeOf(vk: u32) u21 {
        const S = ui.Shortcut;
        return switch (vk) {
            0x26 => S.up,
            0x28 => S.down,
            0x25 => S.left,
            0x27 => S.right,
            0x09 => S.tab,
            0x1B => S.escape,
            0x0D => S.enter,
            0x10 => 0xF710, // shift
            0x11 => 0xF711, // control
            0x12 => 0xF712, // alt
            'A'...'Z', '0'...'9' => std.ascii.toLower(@intCast(vk)),
            0x20 => ' ',
            else => 0,
        };
    }

    /// Keys that are not text, and key combinations; true if taken.
    fn keyDown(self: *Surface, vk: u32) bool {
        const in = &self.ctx.input;
        const ctrl = w.GetKeyState(0x11) < 0;
        const alt = w.GetKeyState(0x12) < 0;
        in.shift = w.GetKeyState(0x10) < 0;
        in.cmd = false;
        in.ctrl = ctrl;
        const key: ?ctx_mod.Key = switch (vk) {
            0x08 => .backspace,
            0x2E => .delete,
            0x25 => .left,
            0x26 => .up,
            0x27 => .right,
            0x28 => .down,
            0x24 => .home,
            0x23 => .end,
            0x0D => .enter,
            0x09 => .tab,
            0x1B => .escape,
            0x21 => .page_up,
            0x22 => .page_down,
            0x70...0x7B => @fromBackingInt(@intCast(@backingInt(ctx_mod.Key.f1) + (vk - 0x70))),
            else => null,
        };
        const S = ui.Shortcut;
        const special: ?u21 = if (key) |k| switch (k) {
            .up => S.up,
            .down => S.down,
            .left => S.left,
            .right => S.right,
            .tab => S.tab,
            .escape => S.escape,
            .enter => S.enter,
            .home => S.home,
            .end => S.end,
            .page_up => S.page_up,
            .page_down => S.page_down,
            .backspace => S.backspace,
            .delete => S.delete,
            else => if (vk >= 0x70 and vk <= 0x7B) S.f1 + @as(u21, @intCast(vk - 0x70)) else null,
        } else null;
        // Letters and digits by their virtual key; other characters come as WM_CHAR.
        const letter: u21 = if ((vk >= 'A' and vk <= 'Z') or (vk >= '0' and vk <= '9')) std.ascii.toLower(@intCast(vk)) else switch (vk) {
            0xBC => ',',
            0xBE => '.',
            0xBF => '/',
            0xDB => '[',
            0xDD => ']',
            0xDC => '\\',
            0xBD => '-',
            0xBB => '=',
            0x20 => ' ',
            0xC0 => '`',
            0xBA => ';',
            0xDE => '\'',
            else => 0,
        };
        const base: u21 = special orelse letter;
        const fkey = base >= S.f1 and base < S.f1 + 12;
        const offer = base != 0 and (ctrl or alt or fkey or base == S.up or base == S.down or base == S.tab or base == S.escape);
        if (offer) {
            const sc: S = .{ .key = base, .ctrl = ctrl, .alt = alt, .shift = in.shift };
            const first = self.ctx.keys_first;
            if (!first and self.window.app.accelerator(sc)) return true;
            if (ctrl and self.ctx.focused_text != null and self.editShortcut(base)) return true;
            self.ctx.shortcut_taken = false;
            in.shortcut = sc;
            self.frame();
            in.shortcut = null;
            if (self.ctx.shortcut_taken) return true;
            if (first and self.window.app.accelerator(sc)) return true;
        }
        if (key) |k| {
            in.key = k;
            self.frame();
            return true;
        }
        return false;
    }

    fn char(self: *Surface, unit: u16) void {
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            self.high = unit;
            return;
        }
        var cp: u21 = unit;
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            if (self.high == 0) return;
            cp = 0x10000 + ((@as(u21, self.high) - 0xD800) << 10) + (unit - 0xDC00);
            self.high = 0;
        }
        // Controls (Ctrl+letters, Enter, Tab, Backspace) came as keys.
        if (cp < 0x20 or cp == 0x7f) return;
        const n = std.unicode.utf8Encode(cp, &self.chars) catch return;
        self.ctx.input.chars = self.chars[0..n];
        self.frame();
    }

    /// Ctrl+C, X, V and A in a text field: copy, cut, paste, select all.
    fn editShortcut(self: *Surface, key: u21) bool {
        var ops: [1]ctx_mod.TextOp = undefined;
        var pasted: ?[]u8 = null;
        defer if (pasted) |p| self.gpa.free(p);
        ops[0] = switch (key) {
            'c' => .{ .command = .copy },
            'x' => .{ .command = .cut },
            'a' => .{ .command = .select_all },
            'v' => blk: {
                pasted = @import("desktop.zig").clipboard.readText(self.gpa) catch null;
                // No text: the view may take Ctrl+V for something else (an image).
                const t = pasted orelse return false;
                break :blk .{ .insert = ctx_mod.pasteText(t, self.ctx.focused_text.?.multiline) };
            },
            else => return false,
        };
        self.ctx.input.ops = &ops;
        self.frame();
        self.ctx.input.ops = &.{};
        return true;
    }
};
