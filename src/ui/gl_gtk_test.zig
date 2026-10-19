//! The OpenGL renderer in a GtkGLArea's context, as a window draws with it:
//! the area realized in a window that is never shown (GLX on X11, EGL on
//! Wayland, through libepoxy), its framebuffer drawn into and read back
//! against the CPU renderer. Skipped without GTK, a display or OpenGL
//! (run under Xvfb in the Linux container).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const linux = builtin.os.tag == .linux;
const gl = if (linux) @import("gl.zig") else struct {};
const gl_gtk = if (linux) @import("gl_gtk.zig") else struct {};

const Gtk = struct {
    gtk_init_check: *const fn (argc: ?*c_int, argv: ?*anyopaque) callconv(.c) c_int,
    gtk_window_new: *const fn (kind: c_int) callconv(.c) *anyopaque,
    gtk_container_add: *const fn (container: *anyopaque, child: *anyopaque) callconv(.c) void,
    gtk_widget_realize: *const fn (w: *anyopaque) callconv(.c) void,
    gtk_widget_size_allocate: *const fn (w: *anyopaque, a: *const [4]c_int) callconv(.c) void,
    gtk_widget_destroy: *const fn (w: *anyopaque) callconv(.c) void,
    gtk_widget_show: *const fn (w: *anyopaque) callconv(.c) void,
    gtk_gl_area_new: *const fn () callconv(.c) *anyopaque,
    gtk_gl_area_set_required_version: *const fn (area: *anyopaque, major: c_int, minor: c_int) callconv(.c) void,
    gtk_gl_area_get_error: *const fn (area: *anyopaque) callconv(.c) ?*anyopaque,
    gtk_gl_area_make_current: *const fn (area: *anyopaque) callconv(.c) void,
    gtk_gl_area_attach_buffers: *const fn (area: *anyopaque) callconv(.c) void,
};

test "a GtkGLArea's context draws what the CPU renderer draws, rows from the top" {
    if (!linux) return error.SkipZigTest;
    if (std.c.getenv("DISPLAY") == null and std.c.getenv("WAYLAND_DISPLAY") == null) return error.SkipZigTest;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return error.SkipZigTest;
    var g: Gtk = undefined;
    inline for (@typeInfo(Gtk).@"struct".field_names) |name| {
        @field(g, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return error.SkipZigTest));
    }
    if (g.gtk_init_check(null, null) == 0) return error.SkipZigTest;
    const gpa = testing.allocator;
    const win = g.gtk_window_new(0);
    defer g.gtk_widget_destroy(win);
    const area = g.gtk_gl_area_new();
    g.gtk_gl_area_set_required_version(area, 3, 3);
    g.gtk_container_add(win, area);
    // Shown in a window that is not: allocated a size, never on a screen.
    g.gtk_widget_show(area);
    const alloc: [4]c_int = .{ 0, 0, 40, 30 };
    g.gtk_widget_size_allocate(win, &alloc);
    g.gtk_widget_realize(area);
    if (g.gtk_gl_area_get_error(area) != null) return error.SkipZigTest;
    g.gtk_widget_size_allocate(area, &alloc);
    g.gtk_gl_area_make_current(area);
    // The first call makes the buffers, the second sizes them.
    g.gtk_gl_area_attach_buffers(area);
    g.gtk_gl_area_attach_buffers(area);

    // What a surface keeps, drawing as its render signal does.
    var text = @import("text.zig").TextSystem.init(gpa);
    defer text.deinit();
    var surface_gpu: gl_gtk.Gpu = .{};
    defer surface_gpu.release(gpa, area);
    const list = [_]gpu.Instance{
        .{ .rect = .{ 2, 2, 20, 12 }, .color = .{ 0.2, 0.5, 0.9, 1 }, .radius = 4, .border_width = 1.5, .border_color = .{ 0, 0, 0, 1 } },
        .{ .rect = .{ 10, 10, 24, 16 }, .color = .{ 0, 0, 0, 0.5 }, .radius = 3, .border_width = 4, .kind = gpu.Kind.shadow },
        .{ .rect = .{ 0, 0, 8, 3 }, .color = .{ 1, 0, 0, 1 } },
    };
    const clear: @import("types.zig").Color = .{ .r = 1, .g = 1, .b = 1 };
    try testing.expect(surface_gpu.render(gpa, &text, &list, 1, 40, 30, clear));
    try testing.expect(surface_gpu.renderer != null);
    const back = try gl.readFramebuffer(gpa, 40, 30);
    defer back.deinit(gpa);
    const cpu = try gpa.alloc(u8, back.bytes.len);
    defer gpa.free(cpu);
    raster.draw(.{ .bytes = cpu, .width = 40, .height = 30 }, &list, .{ .pixels = &.{}, .size = 0 }, .{}, 1, clear);
    for (back.bytes, cpu) |x, y| try testing.expect(@max(x, y) - @min(x, y) <= 3);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, back.bytes[(1 * 40 + 1) * 4 ..][0..4]);
    // Frames drawn on the CPU, as when the renderer fails, show as drawn.
    surface_gpu.present(gpa, cpu, 40, 30);
    const shown = try gl.readFramebuffer(gpa, 40, 30);
    defer shown.deinit(gpa);
    try testing.expectEqualSlices(u8, cpu, shown.bytes);
}
