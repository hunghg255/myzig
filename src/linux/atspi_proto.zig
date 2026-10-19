//! AT-SPI's vocabulary on D-Bus: its roles and states, object references
//! `(so)`, the paths of a window's elements, and the values myzig's D-Bus
//! encoder lacks (doubles, variants). Pure: tested anywhere.
const std = @import("std");
const dbus = @import("dbus.zig");
const access = @import("../ui/access.zig");
const Node = @import("../ui/access_tree.zig").Node;

pub const root_path = "/org/a11y/atspi/accessible/root";
pub const null_path = "/org/a11y/atspi/null";
pub const path_prefix = "/org/a11y/atspi/accessible/";

pub const Interface = struct {
    pub const accessible = "org.a11y.atspi.Accessible";
    pub const application = "org.a11y.atspi.Application";
    pub const component = "org.a11y.atspi.Component";
    pub const action = "org.a11y.atspi.Action";
    pub const value = "org.a11y.atspi.Value";
    pub const text = "org.a11y.atspi.Text";
    pub const editable_text = "org.a11y.atspi.EditableText";
    pub const properties = "org.freedesktop.DBus.Properties";
    pub const event_object = "org.a11y.atspi.Event.Object";
    pub const event_focus = "org.a11y.atspi.Event.Focus";
};

/// AtspiRole.
pub const AtRole = struct {
    pub const alert = 2;
    pub const check_box = 7;
    pub const check_menu_item = 8;
    pub const column_header = 10;
    pub const combo_box = 11;
    pub const dialog = 16;
    pub const frame = 23;
    pub const image = 27;
    pub const label = 29;
    pub const list = 31;
    pub const list_item = 32;
    pub const menu = 33;
    pub const menu_bar = 34;
    pub const menu_item = 35;
    pub const page_tab = 37;
    pub const page_tab_list = 38;
    pub const panel = 39;
    pub const password_text = 40;
    pub const popup_menu = 41;
    pub const progress_bar = 42;
    pub const push_button = 43;
    pub const radio_button = 44;
    pub const radio_menu_item = 45;
    pub const scroll_pane = 49;
    pub const separator = 50;
    pub const slider = 51;
    pub const spin_button = 52;
    pub const status_bar = 54;
    pub const table = 55;
    pub const table_cell = 56;
    pub const toggle_button = 62;
    pub const tool_bar = 63;
    pub const tool_tip = 64;
    pub const tree = 65;
    pub const application = 75;
    pub const entry = 79;
    pub const heading = 83;
    pub const link = 88;
    pub const table_row = 90;
    pub const tree_item = 91;
    pub const notification = 101;
    pub const level_bar = 103;
};

pub fn roleOf(n: *const Node) u32 {
    return switch (n.role) {
        .group, .radio_group, .tab_panel, .auto, .none => AtRole.panel,
        .text => AtRole.label,
        .button, .menu_button, .color_well => AtRole.push_button,
        .link => AtRole.link,
        .checkbox => AtRole.check_box,
        .radio => AtRole.radio_button,
        .switch_, .toggle_button, .disclosure => AtRole.toggle_button,
        .slider => AtRole.slider,
        .progress => AtRole.progress_bar,
        .meter => AtRole.level_bar,
        .stepper => AtRole.spin_button,
        .text_field => if (n.states.password) AtRole.password_text else AtRole.entry,
        .image => AtRole.image,
        .list => AtRole.list,
        .list_item => AtRole.list_item,
        .scroll_area => AtRole.scroll_pane,
        .dialog => AtRole.dialog,
        .alert_dialog => AtRole.alert,
        .popup => AtRole.panel,
        .tooltip => AtRole.tool_tip,
        .popup_button, .combo_box => AtRole.combo_box,
        .tab_list => AtRole.page_tab_list,
        .tab => AtRole.page_tab,
        .splitter => AtRole.separator,
        .status => AtRole.notification,
        .table => AtRole.table,
        .row => AtRole.table_row,
        .cell => AtRole.table_cell,
        .column_header => AtRole.column_header,
        .tree => AtRole.tree,
        .tree_item => AtRole.tree_item,
        .toolbar => AtRole.tool_bar,
        .menu => AtRole.menu,
        .menu_bar => AtRole.menu_bar,
        .menu_item => AtRole.menu_item,
        .menu_item_checkbox => AtRole.check_menu_item,
        .menu_item_radio => AtRole.radio_menu_item,
        .heading => AtRole.heading,
    };
}

/// AT-SPI's names of roles (GetRoleName), as atk_role_get_name.
pub fn roleName(r: u32) []const u8 {
    return switch (r) {
        AtRole.alert => "alert",
        AtRole.check_box => "check box",
        AtRole.check_menu_item => "check menu item",
        AtRole.column_header => "column header",
        AtRole.combo_box => "combo box",
        AtRole.dialog => "dialog",
        AtRole.frame => "frame",
        AtRole.image => "image",
        AtRole.label => "label",
        AtRole.list => "list",
        AtRole.list_item => "list item",
        AtRole.menu => "menu",
        AtRole.menu_bar => "menu bar",
        AtRole.menu_item => "menu item",
        AtRole.page_tab => "page tab",
        AtRole.page_tab_list => "page tab list",
        AtRole.password_text => "password text",
        AtRole.progress_bar => "progress bar",
        AtRole.push_button => "push button",
        AtRole.radio_button => "radio button",
        AtRole.radio_menu_item => "radio menu item",
        AtRole.scroll_pane => "scroll pane",
        AtRole.separator => "separator",
        AtRole.slider => "slider",
        AtRole.spin_button => "spin button",
        AtRole.table => "table",
        AtRole.table_cell => "table cell",
        AtRole.toggle_button => "toggle button",
        AtRole.tool_bar => "tool bar",
        AtRole.tool_tip => "tool tip",
        AtRole.tree => "tree",
        AtRole.application => "application",
        AtRole.entry => "entry",
        AtRole.heading => "heading",
        AtRole.link => "link",
        AtRole.table_row => "table row",
        AtRole.tree_item => "tree item",
        AtRole.notification => "notification",
        AtRole.level_bar => "level bar",
        else => "panel",
    };
}

/// AtspiStateType.
pub const State = enum(u6) {
    active = 1,
    checked = 4,
    collapsed = 5,
    defunct = 6,
    editable = 7,
    enabled = 8,
    expandable = 9,
    expanded = 10,
    focusable = 11,
    focused = 12,
    horizontal = 14,
    modal = 16,
    multi_line = 17,
    multiselectable = 18,
    pressed = 20,
    selectable = 22,
    selected = 23,
    sensitive = 24,
    showing = 25,
    single_line = 26,
    vertical = 29,
    visible = 30,
    indeterminate = 32,
    invalid_entry = 36,
    selectable_text = 38,
    checkable = 41,
    has_popup = 42,
    read_only = 43,
};

pub const StateSet = struct {
    bits: u64 = 0,

    pub fn add(s: *StateSet, st: State) void {
        s.bits |= @as(u64, 1) << @backingInt(st);
    }

    pub fn has(s: StateSet, st: State) bool {
        return s.bits & (@as(u64, 1) << @backingInt(st)) != 0;
    }

    /// As GetState's `au`: two words.
    pub fn words(s: StateSet) [2]u32 {
        return .{ @truncate(s.bits), @truncate(s.bits >> 32) };
    }
};

/// The states of a node, as GTK's widgets have them.
pub fn statesOf(n: *const Node) StateSet {
    var s: StateSet = .{};
    const st = n.states;
    s.add(.visible);
    if (!st.offscreen) s.add(.showing);
    if (!st.disabled) {
        s.add(.enabled);
        s.add(.sensitive);
    }
    if (st.focusable) s.add(.focusable);
    if (st.focused) s.add(.focused);
    switch (n.role) {
        .checkbox, .radio, .switch_, .menu_item_checkbox, .menu_item_radio, .toggle_button => s.add(.checkable),
        .slider => s.add(if (st.vertical) .vertical else .horizontal),
        .text_field, .combo_box => {
            s.add(.selectable_text);
            s.add(if (st.read_only) .read_only else .editable);
            s.add(if (st.multiline) .multi_line else .single_line);
        },
        else => {},
    }
    if (st.selectable) s.add(.selectable);
    if (st.selected) s.add(.selected);
    // Chosen tabs and rows are selected, not checked.
    if (st.checked and !(st.selectable and st.selected and n.role != .radio)) s.add(.checked);
    if (n.role == .disclosure and st.expanded) s.add(.checked);
    if (st.mixed) s.add(.indeterminate);
    if (n.role == .progress and n.range.now < n.range.min) s.add(.indeterminate);
    if (st.expandable) s.add(.expandable);
    if (st.expanded) s.add(.expanded) else if (st.expandable) s.add(.collapsed);
    if (st.multiselectable) s.add(.multiselectable);
    if (st.invalid) s.add(.invalid_entry);
    if (st.has_popup) s.add(.has_popup);
    if (st.modal) s.add(.modal);
    return s;
}

/// The path of the node `id` in surface `k`.
pub fn nodePath(buf: []u8, k: u32, id: u64) []const u8 {
    return std.fmt.bufPrint(buf, path_prefix ++ "{d}_{x}", .{ k, id }) catch null_path;
}

/// The path of surface `k`'s window.
pub fn windowPath(buf: []u8, k: u32) []const u8 {
    return std.fmt.bufPrint(buf, path_prefix ++ "{d}", .{k}) catch null_path;
}

pub const Target = union(enum) {
    root,
    window: u32,
    node: struct { surface: u32, id: u64 },
    unknown,
};

pub fn parsePath(path: []const u8) Target {
    if (std.mem.eql(u8, path, root_path)) return .root;
    if (!std.mem.startsWith(u8, path, path_prefix)) return .unknown;
    const rest = path[path_prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '_')) |u| {
        const k = std.fmt.parseInt(u32, rest[0..u], 10) catch return .unknown;
        const id = std.fmt.parseInt(u64, rest[u + 1 ..], 16) catch return .unknown;
        return .{ .node = .{ .surface = k, .id = id } };
    }
    return .{ .window = std.fmt.parseInt(u32, rest, 10) catch return .unknown };
}

/// Writes `(so)`: a bus name and an object path.
pub fn reference(e: *dbus.Encoder, bus_name: []const u8, path: []const u8) !void {
    try e.structStart();
    try e.string(bus_name);
    try e.string(path);
}

pub fn double(e: *dbus.Encoder, v: f64) !void {
    try e.alignTo(8);
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, @bitCast(v), .little);
    try e.buf.appendSlice(e.gpa, &b);
}

pub fn readDouble(d: *dbus.Decoder) !f64 {
    try d.alignTo(8);
    if (d.pos + 8 > d.bytes.len) return error.Truncated;
    defer d.pos += 8;
    return @bitCast(std.mem.readInt(u64, d.bytes[d.pos..][0..8], .little));
}

pub fn readInt(d: *dbus.Decoder) !i32 {
    return @bitCast(try d.u32_());
}

/// A variant of a string, an int, a bool, a double or a reference.
pub const Variant = union(enum) {
    s: []const u8,
    i: i32,
    u: u32,
    b: bool,
    d: f64,
    ref: struct { bus: []const u8, path: []const u8 },
};

pub fn variant(e: *dbus.Encoder, v: Variant) !void {
    switch (v) {
        .s => |s| {
            try e.signature("s");
            try e.string(s);
        },
        .i => |i| {
            try e.signature("i");
            try e.i32_(i);
        },
        .u => |u| {
            try e.signature("u");
            try e.u32_(u);
        },
        .b => |b| {
            try e.signature("b");
            try e.boolean(b);
        },
        .d => |d| {
            try e.signature("d");
            try double(e, d);
        },
        .ref => |r| {
            try e.signature("(so)");
            try reference(e, r.bus, r.path);
        },
    }
}

/// An event's body, `siiva{sv}`: its detail, two numbers, a value, and
/// no properties.
pub fn eventBody(e: *dbus.Encoder, detail: []const u8, d1: i32, d2: i32, v: Variant) !void {
    try e.string(detail);
    try e.i32_(d1);
    try e.i32_(d2);
    try variant(e, v);
    const props = try e.beginArray(8);
    e.endArray(props);
}

test "paths, roles and states" {
    var buf: [96]u8 = undefined;
    const p = nodePath(&buf, 2, 0xabc);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/2_abc", p);
    try std.testing.expectEqual(@as(u64, 0xabc), parsePath(p).node.id);
    try std.testing.expectEqual(@as(u32, 3), parsePath(windowPath(&buf, 3)).window);
    try std.testing.expect(parsePath(root_path) == .root);
    const n: Node = .{ .id = 1, .role = .checkbox, .states = .{ .checked = true, .focusable = true } };
    const s = statesOf(&n);
    try std.testing.expect(s.has(.checked) and s.has(.checkable) and s.has(.focusable) and s.has(.enabled) and !s.has(.focused));
    try std.testing.expectEqual(@as(u32, AtRole.check_box), roleOf(&n));
    try std.testing.expectEqualStrings("check box", roleName(roleOf(&n)));
}
