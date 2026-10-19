//! GtkMenus built from a menu's nodes (tray icons' menus on Linux), and
//! the GTK functions menus and status icons need, looked up when first
//! used so apps without them don't pay for them.
const std = @import("std");
const gtk = @import("gtk.zig");
const menu_mod = @import("../menu_accel.zig");

pub const Api = struct {
    gtk_menu_new: *const fn () callconv(.c) *gtk.Widget,
    gtk_menu_item_new_with_mnemonic: *const fn (label: [*:0]const u8) callconv(.c) *gtk.Widget,
    gtk_check_menu_item_new_with_mnemonic: *const fn (label: [*:0]const u8) callconv(.c) *gtk.Widget,
    gtk_check_menu_item_set_active: *const fn (item: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_check_menu_item_set_draw_as_radio: *const fn (item: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_separator_menu_item_new: *const fn () callconv(.c) *gtk.Widget,
    gtk_menu_shell_append: *const fn (shell: *gtk.Widget, child: *gtk.Widget) callconv(.c) void,
    gtk_menu_item_set_submenu: *const fn (item: *gtk.Widget, sub: *gtk.Widget) callconv(.c) void,
    gtk_widget_set_sensitive: *const fn (w: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_widget_show_all: *const fn (w: *gtk.Widget) callconv(.c) void,
    gtk_widget_destroy: *const fn (w: *gtk.Widget) callconv(.c) void,
    gtk_menu_popup_at_pointer: *const fn (menu: *gtk.Widget, event: ?*anyopaque) callconv(.c) void,
    g_object_ref_sink: *const fn (obj: *anyopaque) callconv(.c) *anyopaque,
    g_object_unref: *const fn (obj: *anyopaque) callconv(.c) void,
    gtk_status_icon_new_from_file: *const fn (path: [*:0]const u8) callconv(.c) *anyopaque,
    gtk_status_icon_new_from_icon_name: *const fn (name: [*:0]const u8) callconv(.c) *anyopaque,
    gtk_status_icon_set_from_file: *const fn (icon: *anyopaque, path: [*:0]const u8) callconv(.c) void,
    gtk_status_icon_set_tooltip_text: *const fn (icon: *anyopaque, text: [*:0]const u8) callconv(.c) void,
    gtk_status_icon_set_title: *const fn (icon: *anyopaque, text: [*:0]const u8) callconv(.c) void,
    gtk_status_icon_set_visible: *const fn (icon: *anyopaque, on: c_int) callconv(.c) void,
};

pub var api: Api = undefined;
var loaded = false;

/// Looks the functions up in GTK (loaded by `gtk.load`).
pub fn load() bool {
    if (loaded) return true;
    if (!gtk.load()) return false;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse return false;
        @field(api, name) = @ptrCast(@alignCast(sym));
    }
    loaded = true;
    return true;
}

/// "&File" as GTK writes mnemonics: "_File" ("&&" is "&", "_" is "__").
pub fn mnemonic(buf: []u8, label: []const u8) [:0]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < label.len and n + 2 < buf.len) : (i += 1) {
        const c = label[i];
        if (c == '&') {
            if (i + 1 < label.len and label[i + 1] == '&') {
                i += 1;
                buf[n] = '&';
            } else buf[n] = '_';
            n += 1;
        } else if (c == '_') {
            buf[n] = '_';
            buf[n + 1] = '_';
            n += 2;
        } else {
            buf[n] = c;
            n += 1;
        }
    }
    buf[n] = 0;
    return buf[0..n :0];
}

/// While myzig sets checks itself: their "activate" is not a click.
var syncing = false;

fn onActivate(_: *gtk.Widget, data: ?*anyopaque) callconv(.c) void {
    if (syncing) return;
    const it: *menu_mod.Item = @ptrCast(@alignCast(data));
    menu_mod.Menu.activate(it);
}

fn onChange(_: *menu_mod.Menu, it: *menu_mod.Item) void {
    const widget: *gtk.Widget = @ptrCast(it.native orelse return);
    syncing = true;
    defer syncing = false;
    if (it.kind != .normal) api.gtk_check_menu_item_set_active(widget, @intFromBool(it.checked));
    api.gtk_widget_set_sensitive(widget, @intFromBool(!it.disabled));
}

/// The GtkMenu of `m`, owned by the caller (`destroy`); items' state
/// changes update it.
pub fn build(m: *menu_mod.Menu) ?*gtk.Widget {
    if (!load()) return null;
    const root = api.gtk_menu_new();
    _ = api.g_object_ref_sink(root);
    var stack: [16]*gtk.Widget = undefined;
    var depth: usize = 0;
    var current = root;
    var buf: [512]u8 = undefined;
    for (m.nodes.items) |node| switch (node) {
        .item => |i| {
            const it = &m.items.items[i];
            const label = mnemonic(&buf, it.label);
            const widget = if (it.kind == .normal) api.gtk_menu_item_new_with_mnemonic(label) else api.gtk_check_menu_item_new_with_mnemonic(label);
            if (it.kind == .radio) api.gtk_check_menu_item_set_draw_as_radio(widget, 1);
            it.native = widget;
            onChange(m, it);
            gtk.connect(widget, "activate", @ptrCast(&onActivate), it);
            api.gtk_menu_shell_append(current, widget);
        },
        .separator => api.gtk_menu_shell_append(current, api.gtk_separator_menu_item_new()),
        .open => |title| {
            if (depth == stack.len) continue;
            const holder = api.gtk_menu_item_new_with_mnemonic(mnemonic(&buf, title));
            api.gtk_menu_shell_append(current, holder);
            const sub = api.gtk_menu_new();
            api.gtk_menu_item_set_submenu(holder, sub);
            stack[depth] = current;
            depth += 1;
            current = sub;
        },
        .close => {
            if (depth == 0) continue;
            depth -= 1;
            current = stack[depth];
        },
    };
    m.on_change = onChange;
    api.gtk_widget_show_all(root);
    return root;
}

pub fn destroy(m: *menu_mod.Menu, widget: *gtk.Widget) void {
    for (m.items.items) |*it| it.native = null;
    m.on_change = null;
    api.gtk_widget_destroy(widget);
    api.g_object_unref(widget);
}

test "a GtkMenu's items run their clicks and follow their state (on a display)" {
    if (!load() or gtk.api.gtk_init_check(null, null) == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const S = struct {
        clicks: usize = 0,
        fn click(s: *@This(), _: *menu_mod.Item) void {
            s.clicks += 1;
        }
    };
    var s: S = .{};
    const template = [_]menu_mod.MenuItem{
        .{ .label = "&Open", .id = "open", .click = .of(&s, S.click) },
        .{ .label = "More", .submenu = &.{.{ .label = "Grid", .kind = .checkbox, .id = "grid" }} },
    };
    const m = try menu_mod.Menu.create(gpa, &template);
    defer m.destroy();
    const g = build(m) orelse return error.NoMenu;
    defer destroy(m, g);
    const activate: *const fn (*gtk.Widget) callconv(.c) void = @ptrCast(@alignCast(std.c.dlsym(std.c.dlopen("libgtk-3.so.0", .{ .NOW = true }), "gtk_menu_item_activate").?));
    const get_active: *const fn (*gtk.Widget) callconv(.c) c_int = @ptrCast(@alignCast(std.c.dlsym(std.c.dlopen("libgtk-3.so.0", .{ .NOW = true }), "gtk_check_menu_item_get_active").?));
    activate(@ptrCast(m.item("open").?.native.?));
    try std.testing.expectEqual(@as(usize, 1), s.clicks);
    const grid = m.item("grid").?;
    grid.setChecked(true);
    try std.testing.expect(get_active(@ptrCast(grid.native.?)) != 0);
    // Setting it was not a click.
    try std.testing.expect(grid.checked);
    activate(@ptrCast(grid.native.?));
    try std.testing.expect(!grid.checked);
}

test "mnemonics as GTK writes them" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("_File", mnemonic(&buf, "&File"));
    try std.testing.expectEqualStrings("Save & Quit", mnemonic(&buf, "Save && Quit"));
    try std.testing.expectEqualStrings("snake__case", mnemonic(&buf, "snake_case"));
}
