//! The functions the host (`host.js`) calls: the browser's events for a
//! window (known by its id), timers, and the appearance. Text comes in
//! the shared buffer (`myzig_web_buffer`), which each call reads before
//! it returns.
const std = @import("std");
const app_mod = @import("app.zig");
const input = @import("input.zig");
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;

var buffer: []u8 = &.{};

/// The buffer the host writes text into, at least `len` bytes.
export fn myzig_web_buffer(len: usize) ?[*]u8 {
    if (buffer.len < len) {
        const gpa = std.heap.wasm_allocator;
        const grown = gpa.alloc(u8, @max(len, 256)) catch return null;
        gpa.free(buffer);
        buffer = grown;
    }
    return buffer.ptr;
}

fn text(len: usize) []u8 {
    return buffer[0..@min(len, buffer.len)];
}

fn surface(id: u32) ?*Surface {
    const app = app_mod.current orelse return null;
    for (app.windows.items) |w| if (w.id() == id) return w.surface;
    return null;
}

/// The canvas is `w` × `h` CSS pixels at `dpr` device pixels each.
export fn myzig_web_resize(id: u32, w: f32, h: f32, dpr: f32) void {
    const s = surface(id) orelse return;
    s.resize(w, h, if (dpr > 0) dpr else 1);
}

/// The animation frame asked for: true when another is wanted.
export fn myzig_web_animation_frame(id: u32) bool {
    const s = surface(id) orelse return false;
    return s.animationFrame();
}

export fn myzig_web_pointer(id: u32, kind: u32, x: f32, y: f32, button: u32, clicks: u32, mods: u32) bool {
    const s = surface(id) orelse return false;
    if (kind > 3) return false;
    return input.pointer(s, @fromBackingInt(@intCast(kind)), x, y, button, clicks, mods);
}

export fn myzig_web_wheel(id: u32, x: f32, y: f32, dy: f32, mods: u32) bool {
    const s = surface(id) orelse return false;
    return input.wheel(s, x, y, dy, mods);
}

export fn myzig_web_pinch(id: u32, x: f32, y: f32, scale: f32, mods: u32) bool {
    const s = surface(id) orelse return false;
    return input.pinch(s, x, y, scale, mods);
}

export fn myzig_web_scroll(id: u32, x: f32, y: f32, dx: f32, dy: f32, precise: bool, mods: u32) bool {
    const s = surface(id) orelse return false;
    return input.scroll(s, x, y, dx, dy, precise, mods);
}

/// A key down (`up` false) or up, its `KeyboardEvent.key` in the buffer.
export fn myzig_web_key(id: u32, up: bool, len: usize, mods: u32, repeat: bool) bool {
    const s = surface(id) orelse return false;
    if (up) return input.keyUp(s, text(len), mods);
    return input.keyDown(s, text(len), mods, repeat);
}

/// Text from the text area: 0 typed, 1 composing, 2 committed, 3 pasted.
export fn myzig_web_text(id: u32, kind: u32, len: usize) void {
    const s = surface(id) orelse return;
    const t = text(len);
    switch (kind) {
        0 => input.typed(s, t),
        1 => input.composing(s, t),
        2 => input.committed(s, t),
        3 => input.pasted(s, t),
        else => {},
    }
}

export fn myzig_web_focus(id: u32, on: bool) void {
    const s = surface(id) orelse return;
    s.focused = on;
}

/// The window's close button (a page framing the app may have one).
export fn myzig_web_close(id: u32) void {
    const app = app_mod.current orelse return;
    for (app.windows.items) |w| if (w.id() == id) return w.close();
}

export fn myzig_web_context_restored(id: u32) void {
    const s = surface(id) orelse return;
    s.contextRestored();
}

export fn myzig_web_timer(token: u32) void {
    app_mod.fire(token);
}

export fn myzig_web_appearance(dark: bool) void {
    const app = app_mod.current orelse return;
    app.setDark(dark);
}

/// For tests: the window's frame drawn on the CPU (BGRA, premultiplied),
/// to compare with what WebGL drew; its size in `myzig_web_pixels_size`.
export fn myzig_web_cpu_pixels(id: u32) ?[*]u8 {
    const s = surface(id) orelse return null;
    const px = s.cpuPixels() orelse return null;
    return px.ptr;
}

export fn myzig_web_pixels_size(id: u32) u32 {
    const s = surface(id) orelse return 0;
    return @intCast(s.pixel_w << 16 | s.pixel_h);
}

/// For tests: whether WebGL 2 draws the window (else the CPU does).
export fn myzig_web_uses_webgl(id: u32) bool {
    const s = surface(id) orelse return false;
    return s.gl != null;
}

var found: [4]f32 = .{ 0, 0, 0, 0 };

/// For tests: where the text in the buffer is drawn (CSS pixels), in
/// `myzig_web_found`; false when no box shows exactly that text.
export fn myzig_web_find_text(id: u32, len: usize) bool {
    const s = surface(id) orelse return false;
    const want = text(len);
    for (s.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, want)) {
            found = .{ n.rect.x, n.rect.y, n.rect.w, n.rect.h };
            return true;
        },
        else => {},
    };
    return false;
}

export fn myzig_web_found() [*]f32 {
    return &found;
}
