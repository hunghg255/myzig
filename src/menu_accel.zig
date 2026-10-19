//! Menus where myzig handles them itself (Linux, Windows), from the same
//! templates: their items with resolved labels, accelerators (which keys
//! reach before the view does; "CmdOrCtrl" is Ctrl there) and state, and
//! their shape as `nodes`, from which the native menus are built (HMENU
//! menu bars and tray menus on Windows, GtkMenus on Linux).
const std = @import("std");
const menu_types = @import("menu_types.zig");
const ui = @import("ui/ui.zig");

pub const Kind = menu_types.Kind;
pub const Role = menu_types.Role;
pub const Click = menu_types.Click(Item);
pub const MenuItem = menu_types.MenuItem(Item);
pub const parseAccelerator = menu_types.parseAccelerator;

pub const Item = struct {
    menu: *Menu,
    id: []const u8,
    /// What the menu shows, with "&" before the mnemonic.
    label: []const u8,
    /// As the accelerator was written ("CmdOrCtrl+S").
    accelerator: []const u8,
    kind: Kind,
    checked: bool,
    disabled: bool,
    click: ?Click,
    role: ?Role,
    accel: menu_types.Accelerator,
    /// The radio group: items `group_start..group_end` of the menu.
    group_start: u32 = 0,
    group_end: u32 = 0,
    /// The native menu item showing it, if one is (a GtkMenuItem).
    native: ?*anyopaque = null,

    pub fn setChecked(self: *Item, on: bool) void {
        if (on and self.kind == .radio) {
            for (self.menu.items.items[self.group_start..self.group_end]) |*other| if (other != self and other.checked) {
                other.checked = false;
                self.menu.changed(other);
            };
        }
        self.checked = on;
        self.menu.changed(self);
    }

    pub fn setEnabled(self: *Item, on: bool) void {
        self.disabled = !on;
        self.menu.changed(self);
    }

    pub fn index(self: *const Item) u32 {
        return @intCast((@intFromPtr(self) - @intFromPtr(self.menu.items.items.ptr)) / @sizeOf(Item));
    }
};

/// The shape of a menu, depth first: items (by index), separators, and
/// submenus opened with their title and closed.
pub const Node = union(enum) {
    item: u32,
    separator,
    open: []const u8,
    close,
};

pub const Menu = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    /// Told when an item's state changes, to update the native menu.
    on_change: ?*const fn (menu: *Menu, item: *Item) void = null,
    /// Whoever builds the native menu (its owner's pointer).
    owner: ?*anyopaque = null,

    pub fn create(gpa: std.mem.Allocator, template: []const MenuItem) !*Menu {
        const m = try gpa.create(Menu);
        m.* = .{ .gpa = gpa };
        errdefer m.destroy();
        try m.add(template);
        return m;
    }

    fn add(m: *Menu, template: []const MenuItem) !void {
        var group: ?u32 = null;
        for (template) |t| {
            if (t.hidden) continue;
            if (t.role) |r| if (menu_types.portableExpand(Item, r)) |items| {
                try m.nodes.append(m.gpa, .{ .open = if (t.label.len > 0) t.label else menu_types.portableMenuTitle(r) });
                try m.add(t.submenu orelse items);
                try m.nodes.append(m.gpa, .close);
                group = null;
                continue;
            };
            if (t.role) |r| if (menu_types.macOnly(r)) continue;
            if (t.is_separator) {
                // No separator first, last, or twice.
                const last = if (m.nodes.items.len > 0) m.nodes.items[m.nodes.items.len - 1] else Node{ .open = "" };
                if (last != .open and last != .separator) try m.nodes.append(m.gpa, .separator);
                group = null;
                continue;
            }
            if (t.submenu) |sub| {
                try m.nodes.append(m.gpa, .{ .open = t.label });
                try m.add(sub);
                try m.nodes.append(m.gpa, .close);
                group = null;
                continue;
            }
            var label = t.label;
            var accel = t.accelerator;
            if (t.role) |r| {
                const info = menu_types.portableRole(r);
                if (label.len == 0) label = info.label;
                if (accel.len == 0) accel = info.accel;
            }
            const i: u32 = @intCast(m.items.items.len);
            if (t.kind == .radio) {
                if (group == null) group = i;
            } else group = null;
            try m.items.append(m.gpa, .{
                .menu = m,
                .id = t.id,
                .label = label,
                .accelerator = accel,
                .kind = t.kind,
                .checked = t.checked,
                .disabled = t.disabled,
                .click = t.click,
                .role = t.role,
                .accel = parseAccelerator(accel),
            });
            if (group) |g| for (m.items.items[g .. i + 1]) |*member| {
                member.group_start = g;
                member.group_end = i + 1;
            };
            try m.nodes.append(m.gpa, .{ .item = i });
        }
        // Nor a separator last.
        if (m.nodes.items.len > 0 and m.nodes.items[m.nodes.items.len - 1] == .separator) _ = m.nodes.pop();
    }

    pub fn destroy(m: *Menu) void {
        m.items.deinit(m.gpa);
        m.nodes.deinit(m.gpa);
        m.gpa.destroy(m);
    }

    fn changed(m: *Menu, it: *Item) void {
        if (m.on_change) |f| f(m, it);
    }

    pub fn item(m: *Menu, id: []const u8) ?*Item {
        for (m.items.items) |*it| if (it.id.len > 0 and std.mem.eql(u8, it.id, id)) return it;
        return null;
    }

    /// The item whose accelerator is this key combination, if one is.
    pub fn match(m: *Menu, sc: ui.Shortcut) ?*Item {
        for (m.items.items) |*it| {
            const a = it.accel;
            if (a.key == 0 or it.disabled) continue;
            // Cmd (CmdOrCtrl) and Ctrl are both Ctrl on Linux.
            const ctrl = a.mods & (menu_types.mod_cmd | menu_types.mod_ctrl) != 0;
            const shift = a.mods & menu_types.mod_shift != 0;
            const alt = a.mods & menu_types.mod_alt != 0;
            if (a.key == sc.key and ctrl == sc.ctrl and shift == sc.shift and alt == sc.alt) return it;
        }
        return null;
    }

    /// Runs an item as a click would.
    pub fn activate(it: *Item) void {
        switch (it.kind) {
            .checkbox => it.setChecked(!it.checked),
            .radio => it.setChecked(true),
            .normal => {},
        }
        if (it.click) |c| c.func(c.ctx, it);
    }
};

/// `label` without its mnemonic marks ("&File" is "File", "&&" is "&").
pub fn plainLabel(buf: []u8, label: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < label.len and n < buf.len) : (i += 1) {
        if (label[i] == '&') {
            if (i + 1 < label.len and label[i + 1] == '&') i += 1 else continue;
        }
        buf[n] = label[i];
        n += 1;
    }
    return buf[0..n];
}

test "menus' shape, roles and radio groups" {
    const gpa = std.testing.allocator;
    const template = [_]MenuItem{
        .{ .role = .app_menu },
        .{ .label = "&View", .submenu = &.{
            .{ .label = "Small", .kind = .radio, .checked = true, .id = "s" },
            .{ .label = "Large", .kind = .radio, .id = "l" },
            MenuItem.separator,
            .{ .label = "Grid", .kind = .checkbox, .id = "g", .accelerator = "CmdOrCtrl+G" },
            MenuItem.separator,
        } },
        .{ .role = .about },
    };
    const m = try Menu.create(gpa, &template);
    defer m.destroy();
    // File (Exit), View (Small, Large, Grid); About is macOS's.
    try std.testing.expectEqual(@as(usize, 4), m.items.items.len);
    try std.testing.expectEqualStrings("E&xit", m.items.items[0].label);
    try std.testing.expectEqualStrings("&File", m.nodes.items[0].open);
    try std.testing.expectEqual(Node.close, m.nodes.items[m.nodes.items.len - 1]);
    var seps: usize = 0;
    for (m.nodes.items) |n| if (n == .separator) {
        seps += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), seps);
    m.item("l").?.setChecked(true);
    try std.testing.expect(!m.item("s").?.checked);
    try std.testing.expect(m.item("l").?.checked);
    try std.testing.expectEqual(@as(u32, 3), m.item("g").?.index());
    try std.testing.expect(m.match(.{ .key = 'g', .ctrl = true }) == m.item("g"));
    Menu.activate(m.item("g").?);
    try std.testing.expect(m.item("g").?.checked);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Save & Quit", plainLabel(&buf, "&Save && Quit"));
}
