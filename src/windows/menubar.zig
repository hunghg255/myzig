//! Native menus on Windows: HMENUs built from a menu's nodes, as a
//! window's menu bar or a tray icon's popup. An item's command id is its
//! index in the menu plus one; checks and grayed items are refreshed
//! from the items' state each time a submenu opens.
const std = @import("std");
const w = @import("win32.zig");
const menu_mod = @import("../menu_accel.zig");
const menu_types = @import("../menu_types.zig");

pub const HMENU = *opaque {};

extern "user32" fn CreateMenu() callconv(.winapi) ?HMENU;
extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn DestroyMenu(m: HMENU) callconv(.winapi) w.BOOL;
extern "user32" fn AppendMenuW(m: HMENU, flags: u32, id: usize, item: ?[*:0]const u16) callconv(.winapi) w.BOOL;
extern "user32" fn CheckMenuItem(m: HMENU, id: u32, check: u32) callconv(.winapi) u32;
extern "user32" fn EnableMenuItem(m: HMENU, id: u32, enable: u32) callconv(.winapi) w.BOOL;
extern "user32" fn GetMenuState(m: HMENU, id: u32, flags: u32) callconv(.winapi) u32;
extern "user32" fn GetMenuItemCount(m: HMENU) callconv(.winapi) i32;
pub extern "user32" fn GetMenu(hwnd: w.HWND) callconv(.winapi) ?HMENU;
pub extern "user32" fn SetMenu(hwnd: w.HWND, m: ?HMENU) callconv(.winapi) w.BOOL;
pub extern "user32" fn DrawMenuBar(hwnd: w.HWND) callconv(.winapi) w.BOOL;
extern "user32" fn TrackPopupMenu(m: HMENU, flags: u32, x: i32, y: i32, reserved: i32, hwnd: w.HWND, rect: ?*const w.RECT) callconv(.winapi) i32;
extern "user32" fn GetCursorPos(p: *w.POINT) callconv(.winapi) w.BOOL;

const MF_STRING = 0x0;
const MF_GRAYED = 0x1;
const MF_CHECKED = 0x8;
const MF_POPUP = 0x10;
const MF_SEPARATOR = 0x800;
const MF_BYCOMMAND = 0x0;
const MF_ENABLED = 0x0;
const MF_UNCHECKED = 0x0;

/// The HMENU of `m`: a menu bar (`bar`) or a popup. Null if it is empty.
pub fn build(m: *menu_mod.Menu, bar: bool) ?HMENU {
    const root = (if (bar) CreateMenu() else CreatePopupMenu()) orelse return null;
    var stack: [16]HMENU = undefined;
    var titles: [16][]const u8 = undefined;
    var depth: usize = 0;
    var current = root;
    var buf: [512]u16 = undefined;
    for (m.nodes.items) |node| switch (node) {
        .item => |i| {
            const it = &m.items.items[i];
            var text: [320]u8 = undefined;
            var accel: [64]u8 = undefined;
            const shortcut = menu_types.acceleratorText(&accel, it.accelerator);
            const label = if (shortcut.len > 0)
                std.fmt.bufPrint(&text, "{s}\t{s}", .{ it.label, shortcut }) catch it.label
            else
                it.label;
            _ = AppendMenuW(current, MF_STRING | flags(it), i + 1, w.wide(&buf, label));
        },
        .separator => _ = AppendMenuW(current, MF_SEPARATOR, 0, null),
        .open => |title| {
            if (depth == stack.len) continue;
            stack[depth] = current;
            titles[depth] = title;
            depth += 1;
            current = CreatePopupMenu() orelse root;
        },
        .close => {
            if (depth == 0) continue;
            depth -= 1;
            const sub = current;
            current = stack[depth];
            _ = AppendMenuW(current, MF_POPUP, @intFromPtr(sub), w.wide(&buf, titles[depth]));
        },
    };
    if (GetMenuItemCount(root) <= 0) {
        _ = DestroyMenu(root);
        return null;
    }
    return root;
}

fn flags(it: *const menu_mod.Item) u32 {
    var f: u32 = 0;
    if (it.checked) f |= MF_CHECKED;
    if (it.disabled) f |= MF_GRAYED;
    return f;
}

/// Updates the checks and grayed items under `h` from `m`'s items.
pub fn refresh(m: *menu_mod.Menu, h: HMENU) void {
    for (m.items.items, 0..) |*it, i| {
        const id: u32 = @intCast(i + 1);
        // 0xFFFFFFFF: not in this menu.
        if (GetMenuState(h, id, MF_BYCOMMAND) == 0xFFFFFFFF) continue;
        _ = CheckMenuItem(h, id, MF_BYCOMMAND | (if (it.checked) @as(u32, MF_CHECKED) else MF_UNCHECKED));
        _ = EnableMenuItem(h, id, MF_BYCOMMAND | (if (it.disabled) @as(u32, MF_GRAYED) else MF_ENABLED));
    }
}

/// The item of command `id`, if it is one of `m`'s.
pub fn command(m: *menu_mod.Menu, id: usize) ?*menu_mod.Item {
    if (id == 0 or id > m.items.items.len) return null;
    return &m.items.items[id - 1];
}

/// Shows `m` as a popup at the mouse, owned by `hwnd`, and returns the
/// item chosen, if one was.
pub fn popup(m: *menu_mod.Menu, hwnd: w.HWND) ?*menu_mod.Item {
    const h = build(m, false) orelse return null;
    defer _ = DestroyMenu(h);
    var pt: w.POINT = .{};
    _ = GetCursorPos(&pt);
    // The popup closes when the user clicks elsewhere only if its owner
    // is in the foreground.
    _ = w.SetForegroundWindow(hwnd);
    // TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON
    const cmd = TrackPopupMenu(h, 0x0100 | 0x0080 | 0x0002, pt.x, pt.y, 0, hwnd, null);
    _ = w.PostMessageW(hwnd, 0, 0, 0); // WM_NULL
    return command(m, @intCast(@max(cmd, 0)));
}

test "menu bars from templates: items, submenus, checks" {
    const gpa = std.testing.allocator;
    const template = [_]menu_mod.MenuItem{
        .{ .role = .app_menu },
        .{ .label = "&View", .submenu = &.{
            .{ .label = "Grid", .kind = .checkbox, .id = "g", .accelerator = "CmdOrCtrl+G" },
            menu_mod.MenuItem.separator,
            .{ .label = "Ruler", .id = "r", .disabled = true },
        } },
    };
    const m = try menu_mod.Menu.create(gpa, &template);
    defer m.destroy();
    const bar = build(m, true) orelse return error.NoMenu;
    defer _ = DestroyMenu(bar);
    try std.testing.expectEqual(@as(i32, 2), GetMenuItemCount(bar));
    const grid = m.item("g").?;
    const id = grid.index() + 1;
    try std.testing.expectEqual(@as(u32, 0), GetMenuState(bar, id, MF_BYCOMMAND) & MF_CHECKED);
    try std.testing.expect(GetMenuState(bar, m.item("r").?.index() + 1, MF_BYCOMMAND) & MF_GRAYED != 0);
    menu_mod.Menu.activate(command(m, id).?);
    refresh(m, bar);
    try std.testing.expect(GetMenuState(bar, id, MF_BYCOMMAND) & MF_CHECKED != 0);
    try std.testing.expect(command(m, 0) == null);
    try std.testing.expect(command(m, 99) == null);
}
