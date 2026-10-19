//! AT-SPI's method calls answered from the trees of the app's windows:
//! the application (the root), each window (a frame), and the nodes of
//! its last frame, with the interfaces of their roles. Pure: a call's
//! message in, a reply's body out, actions handed to the window's host.
const std = @import("std");
const dbus = @import("dbus.zig");
const proto = @import("atspi_proto.zig");
const text_iface = @import("atspi_text.zig");
const access = @import("../ui/access.zig");
const types = @import("../ui/types.zig");
const tree_mod = @import("../ui/access_tree.zig");
const Tree = tree_mod.Tree;
const Node = tree_mod.Node;
const none = tree_mod.none;
const I = proto.Interface;

/// A window's part, kept by its surface.
pub const Window = struct {
    tree: *const Tree,
    title: []const u8 = "",
    /// Its content's top left on the screen, in points.
    origin: types.Point = .{},
    ptr: *anyopaque,
    perform: *const fn (ptr: *anyopaque, id: u64, role: access.Role, action: access.Action) void,
};

pub const Model = struct {
    /// Our unique name on the accessibility bus.
    bus_name: []const u8,
    /// The registry's desktop, our application's parent.
    parent_bus: []const u8 = "",
    parent_path: []const u8 = proto.null_path,
    app_name: []const u8 = "myzig",
    app_id: i32 = 0,
    windows: []const ?*Window,
};

pub const Answer = struct {
    signature: []const u8 = "",
    /// An error reply, of this name, instead.
    error_name: ?[]const u8 = null,
};

const unknown_object: Answer = .{ .error_name = "org.freedesktop.DBus.Error.UnknownObject" };
const unknown_method: Answer = .{ .error_name = "org.freedesktop.DBus.Error.UnknownMethod" };

/// What a path stands for, now.
pub const Object = struct {
    target: proto.Target,
    window: ?*Window = null,
    node: ?*const Node = null,
    index: u32 = none,
};

pub fn resolve(m: *const Model, path: []const u8) ?Object {
    const t = proto.parsePath(path);
    switch (t) {
        .root => return .{ .target = t },
        .window => |k| {
            const win = if (k < m.windows.len) m.windows[k] orelse return null else return null;
            return .{ .target = t, .window = win };
        },
        .node => |n| {
            const win = if (n.surface < m.windows.len) m.windows[n.surface] orelse return null else return null;
            const i = win.tree.index.get(n.id) orelse return null;
            return .{ .target = t, .window = win, .node = &win.tree.nodes.items[i], .index = i };
        },
        .unknown => return null,
    }
}

/// Writes the reference of node index `i` of window `k` (its window for `none`).
pub fn refOf(m: *const Model, e: *dbus.Encoder, k: u32, win: *const Window, i: u32) !void {
    var buf: [96]u8 = undefined;
    const path = if (i == none) proto.windowPath(&buf, k) else proto.nodePath(&buf, k, win.tree.nodes.items[i].id);
    try proto.reference(e, m.bus_name, path);
}

fn surfaceOf(o: Object) u32 {
    return switch (o.target) {
        .window => |k| k,
        .node => |n| n.surface,
        else => 0,
    };
}

/// Answers a method call, its reply's body written to `e`.
pub fn handle(m: *const Model, msg: *dbus.Message, e: *dbus.Encoder) !Answer {
    const h = msg.header;
    const o = resolve(m, h.path) orelse return unknown_object;
    if (std.mem.eql(u8, h.interface, I.properties)) return properties(m, o, msg, e);
    if (try accessible(m, o, h.member, &msg.body, e)) |a| return a;
    if (o.node) |n| {
        if (try component(m, o, n, h.member, &msg.body, e)) |a| return a;
        if (try actions(o, n, h.member, &msg.body, e)) |a| return a;
        if (try text_iface.handle(o, n, h.member, &msg.body, e)) |a| return a;
    }
    return unknown_method;
}

fn childCount(m: *const Model, o: Object) u32 {
    return switch (o.target) {
        .root => blk: {
            var k: u32 = 0;
            for (m.windows) |w| k += @intFromBool(w != null);
            break :blk k;
        },
        .window => o.window.?.tree.childCount(none),
        .node => o.node.?.child_count,
        .unknown => 0,
    };
}

fn nameOf(m: *const Model, o: Object) []const u8 {
    return switch (o.target) {
        .root => m.app_name,
        .window => o.window.?.title,
        else => if (o.node) |n| n.name else "",
    };
}

fn roleCode(o: Object) u32 {
    return switch (o.target) {
        .root => proto.AtRole.application,
        .window => proto.AtRole.frame,
        else => if (o.node) |n| proto.roleOf(n) else proto.AtRole.panel,
    };
}

fn writeParent(m: *const Model, o: Object, e: *dbus.Encoder) !void {
    switch (o.target) {
        .root => try proto.reference(e, m.parent_bus, m.parent_path),
        .window => try proto.reference(e, m.bus_name, proto.root_path),
        else => try refOf(m, e, surfaceOf(o), o.window.?, o.node.?.parent),
    }
}

/// The child `k` of an object, written; false past the last.
fn writeChild(m: *const Model, o: Object, k: u32, e: *dbus.Encoder) !bool {
    switch (o.target) {
        .root => {
            var seen: u32 = 0;
            for (m.windows, 0..) |w, i| if (w != null) {
                if (seen == k) {
                    var buf: [96]u8 = undefined;
                    try proto.reference(e, m.bus_name, proto.windowPath(&buf, @intCast(i)));
                    return true;
                }
                seen += 1;
            };
            return false;
        },
        else => {
            const win = o.window.?;
            const at = win.tree.childAt(o.index, k);
            if (at == none) return false;
            try refOf(m, e, surfaceOf(o), win, at);
            return true;
        },
    }
}

fn accessible(m: *const Model, o: Object, member: []const u8, d: *dbus.Decoder, e: *dbus.Encoder) !?Answer {
    const eql = std.mem.eql;
    if (eql(u8, member, "GetChildAtIndex")) {
        const k = try proto.readInt(d);
        if (k < 0 or !try writeChild(m, o, @intCast(k), e)) try proto.reference(e, m.bus_name, proto.null_path);
        return .{ .signature = "(so)" };
    }
    if (eql(u8, member, "GetChildren")) {
        const arr = try e.beginArray(8);
        var k: u32 = 0;
        while (try writeChild(m, o, k, e)) k += 1;
        e.endArray(arr);
        return .{ .signature = "a(so)" };
    }
    if (eql(u8, member, "GetIndexInParent")) {
        try e.i32_(switch (o.target) {
            .root => -1,
            .window => |k| @intCast(k),
            else => @intCast(o.node.?.index_in_parent),
        });
        return .{ .signature = "i" };
    }
    if (eql(u8, member, "GetRelationSet")) {
        const arr = try e.beginArray(8);
        e.endArray(arr);
        return .{ .signature = "a(ua(so))" };
    }
    if (eql(u8, member, "GetRole")) {
        try e.u32_(roleCode(o));
        return .{ .signature = "u" };
    }
    if (eql(u8, member, "GetRoleName") or eql(u8, member, "GetLocalizedRoleName")) {
        try e.string(proto.roleName(roleCode(o)));
        return .{ .signature = "s" };
    }
    if (eql(u8, member, "GetState")) {
        var s: proto.StateSet = .{};
        switch (o.target) {
            .root => {},
            .window => for ([_]proto.State{ .active, .enabled, .sensitive, .showing, .visible }) |st| s.add(st),
            else => s = proto.statesOf(o.node.?),
        }
        const w = s.words();
        const arr = try e.beginArray(4);
        try e.u32_(w[0]);
        try e.u32_(w[1]);
        e.endArray(arr);
        return .{ .signature = "au" };
    }
    if (eql(u8, member, "GetAttributes")) {
        const arr = try e.beginArray(8);
        if (o.node) |n| {
            var buf: [16]u8 = undefined;
            if (n.role == .heading and n.level > 0) try attribute(e, "level", std.fmt.bufPrint(&buf, "{d}", .{n.level}) catch "1");
            if (n.placeholder.len > 0) try attribute(e, "placeholder-text", n.placeholder);
            try attribute(e, "toolkit", "myzig");
        }
        e.endArray(arr);
        return .{ .signature = "a{ss}" };
    }
    if (eql(u8, member, "GetApplication")) {
        try proto.reference(e, m.bus_name, proto.root_path);
        return .{ .signature = "(so)" };
    }
    if (eql(u8, member, "GetInterfaces")) {
        const arr = try e.beginArray(4);
        for (interfacesOf(o)) |name| if (name.len > 0) try e.string(name);
        e.endArray(arr);
        return .{ .signature = "as" };
    }
    if (eql(u8, member, "GetLocale")) {
        try e.string("C");
        return .{ .signature = "s" };
    }
    return null;
}

fn attribute(e: *dbus.Encoder, k: []const u8, v: []const u8) !void {
    try e.structStart();
    try e.string(k);
    try e.string(v);
}

/// The interfaces an object implements ("" for none), sorted as AT-SPI lists them.
pub fn interfacesOf(o: Object) [6][]const u8 {
    var out: [6][]const u8 = @splat("");
    out[0] = I.accessible;
    switch (o.target) {
        .root => out[1] = I.application,
        .window => out[1] = I.component,
        else => {
            const n = o.node.?;
            out[1] = I.component;
            if (hasActions(n)) out[2] = I.action;
            if (n.role.ranged()) out[3] = I.value;
            if (text_iface.hasText(n)) out[4] = I.text;
            if (n.actions.set_value) out[5] = I.editable_text;
        },
    }
    return out;
}

fn hasActions(n: *const Node) bool {
    return n.actions.press or n.actions.expand;
}

/// The node's extents for `coords`: 0 the screen, 1 the window, 2 its parent.
fn extents(o: Object, n: *const Node, coords: u32) types.Rect {
    var r = n.rect;
    switch (coords) {
        0 => {
            r.x += o.window.?.origin.x;
            r.y += o.window.?.origin.y;
        },
        2 => if (n.parent != none) {
            const p = o.window.?.tree.nodes.items[n.parent].rect;
            r.x -= p.x;
            r.y -= p.y;
        },
        else => {},
    }
    return r;
}

fn px(v: f32) i32 {
    return @intFromFloat(@round(v));
}

fn component(m: *const Model, o: Object, n: *const Node, member: []const u8, d: *dbus.Decoder, e: *dbus.Encoder) !?Answer {
    const eql = std.mem.eql;
    const win = o.window.?;
    if (eql(u8, member, "GetExtents")) {
        const r = extents(o, n, try d.u32_());
        try e.structStart();
        for ([_]f32{ r.x, r.y, r.w, r.h }) |v| try e.i32_(px(v));
        return .{ .signature = "(iiii)" };
    }
    if (eql(u8, member, "GetPosition")) {
        const r = extents(o, n, try d.u32_());
        try e.i32_(px(r.x));
        try e.i32_(px(r.y));
        return .{ .signature = "ii" };
    }
    if (eql(u8, member, "GetSize")) {
        try e.i32_(px(n.rect.w));
        try e.i32_(px(n.rect.h));
        return .{ .signature = "ii" };
    }
    if (eql(u8, member, "Contains") or eql(u8, member, "GetAccessibleAtPoint")) {
        const x = try proto.readInt(d);
        const y = try proto.readInt(d);
        const coords = try d.u32_();
        const base = extents(o, n, coords);
        const p: types.Point = .{ .x = @as(f32, @floatFromInt(x)) - (base.x - n.rect.x), .y = @as(f32, @floatFromInt(y)) - (base.y - n.rect.y) };
        if (eql(u8, member, "Contains")) {
            try e.boolean(n.rect.contains(p));
            return .{ .signature = "b" };
        }
        // The deepest node inside this one there.
        var found: u32 = none;
        var i = win.tree.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const c = &win.tree.nodes.items[i];
            if (c.states.offscreen or !c.rect.contains(p)) continue;
            var a: u32 = @intCast(i);
            while (a != none and a != o.index) a = win.tree.nodes.items[a].parent;
            if (a == o.index and i != o.index) {
                found = @intCast(i);
                break;
            }
        }
        if (found == none) try proto.reference(e, m.bus_name, proto.null_path) else try refOf(m, e, surfaceOf(o), win, found);
        return .{ .signature = "(so)" };
    }
    if (eql(u8, member, "GetLayer")) {
        try e.u32_(3); // ATSPI_LAYER_WIDGET
        return .{ .signature = "u" };
    }
    if (eql(u8, member, "GetMDIZOrder")) {
        try e.alignTo(2);
        try e.buf.appendSlice(e.gpa, &.{ 0, 0 });
        return .{ .signature = "n" };
    }
    if (eql(u8, member, "GetAlpha")) {
        try proto.double(e, 1);
        return .{ .signature = "d" };
    }
    if (eql(u8, member, "GrabFocus") or eql(u8, member, "ScrollTo")) {
        const focus = eql(u8, member, "GrabFocus");
        const can = if (focus) n.actions.focus else n.actions.scroll_into_view;
        if (can) win.perform(win.ptr, n.id, n.role, if (focus) .focus else .scroll_into_view);
        try e.boolean(can);
        return .{ .signature = "b" };
    }
    return null;
}

/// The node's actions, by index: pressing, then opening or closing.
fn actionAt(n: *const Node, i: i32) ?access.Action {
    var k: i32 = 0;
    if (n.actions.press) {
        if (k == i) return .press;
        k += 1;
    }
    if (n.actions.expand) {
        if (k == i) return if (n.states.expanded) .collapse else .expand;
    }
    return null;
}

fn actionName(a: access.Action) []const u8 {
    return switch (a) {
        .press => "click",
        .expand, .collapse => "expand or contract",
        else => "",
    };
}

fn actionCount(n: *const Node) i32 {
    return @as(i32, @intFromBool(n.actions.press)) + @intFromBool(n.actions.expand);
}

fn actions(o: Object, n: *const Node, member: []const u8, d: *dbus.Decoder, e: *dbus.Encoder) !?Answer {
    const eql = std.mem.eql;
    if (!hasActions(n)) return null;
    if (eql(u8, member, "GetName") or eql(u8, member, "GetLocalizedName") or eql(u8, member, "GetDescription") or eql(u8, member, "GetKeyBinding")) {
        const a = actionAt(n, try proto.readInt(d));
        const named = eql(u8, member, "GetName") or eql(u8, member, "GetLocalizedName");
        try e.string(if (a != null and named) actionName(a.?) else "");
        return .{ .signature = "s" };
    }
    if (eql(u8, member, "GetActions")) {
        const arr = try e.beginArray(8);
        var i: i32 = 0;
        while (actionAt(n, i)) |a| : (i += 1) {
            try e.structStart();
            try e.string(actionName(a));
            try e.string("");
            try e.string("");
        }
        e.endArray(arr);
        return .{ .signature = "a(sss)" };
    }
    if (eql(u8, member, "DoAction")) {
        const a = actionAt(n, try proto.readInt(d));
        if (a) |act| o.window.?.perform(o.window.?.ptr, n.id, n.role, act);
        try e.boolean(a != null);
        return .{ .signature = "b" };
    }
    return null;
}

/// A property's value, null where the object has none.
pub fn property(m: *const Model, o: Object, iface: []const u8, name: []const u8) ?proto.Variant {
    const eql = std.mem.eql;
    if (eql(u8, iface, I.accessible)) {
        if (eql(u8, name, "Name")) return .{ .s = nameOf(m, o) };
        if (eql(u8, name, "Description")) return .{ .s = if (o.node) |n| n.description else "" };
        if (eql(u8, name, "HelpText")) return .{ .s = if (o.node) |n| n.placeholder else "" };
        if (eql(u8, name, "ChildCount")) return .{ .i = @intCast(childCount(m, o)) };
        if (eql(u8, name, "Locale")) return .{ .s = "C" };
        if (eql(u8, name, "AccessibleId")) return .{ .s = "" };
        if (eql(u8, name, "Parent")) return switch (o.target) {
            .root => .{ .ref = .{ .bus = m.parent_bus, .path = m.parent_path } },
            else => null, // written by `properties` (its path is built)
        };
        return null;
    }
    if (eql(u8, iface, I.application) and o.target == .root) {
        if (eql(u8, name, "ToolkitName")) return .{ .s = "myzig" };
        if (eql(u8, name, "Version")) return .{ .s = "0.1" };
        if (eql(u8, name, "AtspiVersion")) return .{ .s = "2.1" };
        if (eql(u8, name, "Id")) return .{ .i = m.app_id };
        return null;
    }
    const n = o.node orelse return null;
    if (eql(u8, iface, I.value) and n.role.ranged()) {
        if (eql(u8, name, "MinimumValue")) return .{ .d = n.range.min };
        if (eql(u8, name, "MaximumValue")) return .{ .d = n.range.max };
        if (eql(u8, name, "MinimumIncrement")) return .{ .d = if (n.range.step > 0) n.range.step else (n.range.max - n.range.min) / 100 };
        if (eql(u8, name, "CurrentValue")) return .{ .d = @max(n.range.now, n.range.min) };
        if (eql(u8, name, "Text")) return .{ .s = n.value };
        return null;
    }
    if (eql(u8, iface, I.action) and hasActions(n) and eql(u8, name, "NActions")) return .{ .i = actionCount(n) };
    if (eql(u8, iface, I.text)) return text_iface.property(n, name);
    return null;
}

const listed = [_]struct { []const u8, []const []const u8 }{
    .{ I.accessible, &.{ "Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId", "HelpText" } },
    .{ I.application, &.{ "ToolkitName", "Version", "AtspiVersion", "Id" } },
    .{ I.value, &.{ "MinimumValue", "MaximumValue", "MinimumIncrement", "CurrentValue", "Text" } },
    .{ I.action, &.{"NActions"} },
    .{ I.text, &.{ "CharacterCount", "CaretOffset" } },
};

fn writeProperty(m: *const Model, o: Object, iface: []const u8, name: []const u8, e: *dbus.Encoder) !bool {
    if (std.mem.eql(u8, iface, I.accessible) and std.mem.eql(u8, name, "Parent") and o.target != .root) {
        try e.signature("(so)");
        try writeParent(m, o, e);
        return true;
    }
    const v = property(m, o, iface, name) orelse return false;
    try proto.variant(e, v);
    return true;
}

fn properties(m: *const Model, o: Object, msg: *dbus.Message, e: *dbus.Encoder) !Answer {
    const d = &msg.body;
    const member = msg.header.member;
    const iface = try d.string();
    if (std.mem.eql(u8, member, "Get")) {
        const name = try d.string();
        if (!try writeProperty(m, o, iface, name, e)) return .{ .error_name = "org.freedesktop.DBus.Error.UnknownProperty" };
        return .{ .signature = "v" };
    }
    if (std.mem.eql(u8, member, "GetAll")) {
        const arr = try e.beginArray(8);
        for (listed) |l| if (std.mem.eql(u8, l[0], iface)) for (l[1]) |name| {
            const mark = e.buf.items.len;
            try e.structStart();
            try e.string(name);
            if (!try writeProperty(m, o, iface, name, e)) e.buf.shrinkRetainingCapacity(mark);
        };
        e.endArray(arr);
        return .{ .signature = "a{sv}" };
    }
    if (std.mem.eql(u8, member, "Set")) {
        const name = try d.string();
        const sig = try d.signature();
        const n = o.node orelse return .{};
        if (std.mem.eql(u8, iface, I.value) and std.mem.eql(u8, name, "CurrentValue") and std.mem.eql(u8, sig, "d") and n.actions.increment) {
            const v = try proto.readDouble(d);
            const win = o.window.?;
            // Toward the value, as the arrow keys move it.
            if (v > n.range.now) win.perform(win.ptr, n.id, n.role, .increment) else if (v < n.range.now) win.perform(win.ptr, n.id, n.role, .decrement);
        }
        return .{};
    }
    return unknown_method;
}
