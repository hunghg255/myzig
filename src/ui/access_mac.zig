//! Native UI for NSAccessibility (VoiceOver): the view's accessibility
//! children are elements of a runtime subclass of NSAccessibilityElement,
//! one per node of the last frame's tree (`access_tree.zig`), with the
//! roles, labels, values and actions AppKit's controls have. The view
//! starts describing frames the first time AppKit asks it; after each
//! frame, VoiceOver hears of the focus, values, titles and layout that
//! changed, and of announcements.
const std = @import("std");
const objc = @import("../objc.zig");
const access = @import("access.zig");
const text_methods = @import("access_mac_text.zig").methods;
const tree_mod = @import("access_tree.zig");
const Context = @import("context.zig").Context;
const Tree = tree_mod.Tree;
const Node = tree_mod.Node;
const none = tree_mod.none;
const Object = objc.Object;
const SEL = objc.SEL;

extern "c" fn NSAccessibilityPostNotification(element: Object, name: Object) void;
extern "c" fn NSAccessibilityPostNotificationWithUserInfo(element: Object, name: Object, info: ?Object) void;
extern "c" fn NSAccessibilityFrameInView(view: Object, frame: objc.CGRect) objc.CGRect;

pub const Host = struct {
    ptr: *anyopaque,
    ctx: *Context,
    view: Object,
    frame_now: *const fn (ptr: *anyopaque) void,
    request_frame: *const fn (ptr: *anyopaque) void,
};

/// One element: its object's Zig half.
pub const Elem = struct {
    owner: *Access,
    id: u64,
    obj: Object,
};

pub const Access = struct {
    gpa: std.mem.Allocator,
    host: Host,
    tree: Tree,
    prev: Tree,
    elems: std.AutoHashMapUnmanaged(u64, *Elem) = .empty,
    quiet: bool = false,

    pub fn create(gpa: std.mem.Allocator, host: Host) !*Access {
        const a = try gpa.create(Access);
        a.* = .{ .gpa = gpa, .host = host, .tree = .init(gpa), .prev = .init(gpa) };
        host.ctx.access.enabled = true;
        return a;
    }

    pub fn destroy(a: *Access) void {
        var it = a.elems.valueIterator();
        while (it.next()) |e| drop(e.*);
        a.elems.deinit(a.gpa);
        a.tree.deinit();
        a.prev.deinit();
        a.host.ctx.access.enabled = false;
        a.gpa.destroy(a);
    }

    fn drop(e: *Elem) void {
        objc.setZig(e.obj, null);
        NSAccessibilityPostNotification(e.obj, objc.nsString("AXUIElementDestroyed"));
        objc.release(e.obj);
        e.owner.gpa.destroy(e);
    }

    /// After a frame: the elements of its tree, and notifications.
    pub fn update(a: *Access) void {
        std.mem.swap(Tree, &a.tree, &a.prev);
        a.tree.build(a.host.ctx);
        var old = a.elems;
        a.elems = .empty;
        defer old.deinit(a.gpa);
        for (a.tree.nodes.items) |n| {
            const e = if (old.fetchRemove(n.id)) |kv| kv.value else blk: {
                const e = a.gpa.create(Elem) catch continue;
                const cls = objc.defineClass(.{ .name = "MyZigAXElement", .superclass = "NSAccessibilityElement", .methods = &element_methods });
                e.* = .{ .owner = a, .id = n.id, .obj = objc.msg(Object, objc.msg(Object, cls, "alloc", .{}), "init", .{}) };
                objc.setZig(e.obj, e);
                break :blk e;
            };
            a.elems.put(a.gpa, n.id, e) catch drop(e);
        }
        var gone = old.valueIterator();
        while (gone.next()) |e| drop(e.*);
        if (!a.quiet) a.notify();
    }

    fn notify(a: *Access) void {
        const t = &a.tree;
        const p = &a.prev;
        if (tree_mod.topChanged(p, t)) NSAccessibilityPostNotification(a.host.view, objc.nsString("AXLayoutChanged"));
        for (t.nodes.items) |*n| {
            const o = p.find(n.id) orelse continue;
            const e = a.elems.get(n.id) orelse continue;
            const ch = tree_mod.diff(p, o, t, n);
            if (ch.name) NSAccessibilityPostNotification(e.obj, objc.nsString("AXTitleChanged"));
            if (ch.value or ch.range or (ch.states and o.states.checked != n.states.checked)) NSAccessibilityPostNotification(e.obj, objc.nsString("AXValueChanged"));
            if (ch.selection) NSAccessibilityPostNotification(e.obj, objc.nsString("AXSelectedTextChanged"));
            if (ch.children) NSAccessibilityPostNotification(e.obj, objc.nsString("AXLayoutChanged"));
            if (ch.states and o.states.expanded != n.states.expanded) NSAccessibilityPostNotification(e.obj, objc.nsString(if (n.states.expanded) "AXExpanded" else "AXCollapsed"));
        }
        if (t.focus != p.focus and t.focus != 0) if (a.elems.get(t.focus)) |e| {
            NSAccessibilityPostNotification(e.obj, objc.nsString("AXFocusedUIElementChanged"));
        };
        for (t.announcements) |text| {
            const keys = [_]Object{ objc.nsString("AXAnnouncementKey"), objc.nsString("AXPriorityKey") };
            const vals = [_]Object{ objc.nsString(text), objc.msg(Object, objc.class("NSNumber"), "numberWithInteger:", .{@as(objc.NSInteger, 50)}) };
            const info = objc.msg(Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &vals, &keys, @as(objc.NSUInteger, 2) });
            const app = objc.msg(Object, objc.class("NSApplication"), "sharedApplication", .{});
            NSAccessibilityPostNotificationWithUserInfo(app, objc.nsString("AXAnnouncementRequested"), info);
        }
    }

    /// The children of node `i` (the view's for `none`), as an NSArray.
    fn children(a: *Access, i: u32) Object {
        const arr = objc.msg(Object, objc.class("NSMutableArray"), "array", .{});
        var ch = a.tree.firstChild(i);
        while (ch != none) : (ch = a.tree.nodes.items[ch].next_sibling) {
            if (a.elems.get(a.tree.nodes.items[ch].id)) |e| objc.msg(void, arr, "addObject:", .{e.obj});
        }
        return arr;
    }

    fn objOf(a: *Access, i: u32) Object {
        if (i == none) return a.host.view;
        return if (a.elems.get(a.tree.nodes.items[i].id)) |e| e.obj else a.host.view;
    }
};

fn roleOf(n: *const Node) [:0]const u8 {
    return switch (n.role) {
        .button, .disclosure, .color_well => "AXButton",
        .menu_button => "AXMenuButton",
        .link => "AXLink",
        .checkbox, .switch_, .toggle_button, .menu_item_checkbox => "AXCheckBox",
        .radio, .tab => "AXRadioButton",
        .slider => "AXSlider",
        .progress => "AXProgressIndicator",
        .meter => "AXLevelIndicator",
        .stepper => "AXIncrementor",
        .text_field => "AXTextField",
        .combo_box => "AXComboBox",
        .popup_button => "AXPopUpButton",
        .text => "AXStaticText",
        .heading => "AXHeading",
        .image => "AXImage",
        .list => "AXList",
        .table => "AXTable",
        .tree => "AXOutline",
        .row, .tree_item, .list_item => "AXRow",
        .cell => "AXCell",
        .column_header => "AXButton",
        .scroll_area => "AXScrollArea",
        .tab_list => "AXTabGroup",
        .radio_group => "AXRadioGroup",
        .toolbar => "AXToolbar",
        .splitter => "AXSplitter",
        .menu, .popup => "AXMenu",
        .menu_bar => "AXMenuBar",
        .menu_item, .menu_item_radio => "AXMenuItem",
        else => "AXGroup",
    };
}

fn subroleOf(n: *const Node) ?[:0]const u8 {
    return switch (n.role) {
        .switch_ => "AXSwitch",
        .toggle_button => "AXToggle",
        .tab => "AXTabButton",
        .tree_item => "AXOutlineRow",
        .dialog, .alert_dialog => "AXApplicationDialog",
        .status => "AXApplicationStatus",
        else => if (n.states.password) "AXSecureTextField" else null,
    };
}

pub fn elemOf(obj: Object) ?*Elem {
    return objc.getZig(Elem, obj);
}

pub fn nodeOf(obj: Object) ?*const Node {
    const e = elemOf(obj) orelse return null;
    return e.owner.tree.find(e.id);
}

fn str(s: []const u8) ?Object {
    return if (s.len == 0) null else objc.nsString(s);
}

fn role(obj: Object, _: SEL) callconv(.c) ?Object {
    const n = nodeOf(obj) orelse return objc.nsString("AXUnknown");
    return objc.nsString(roleOf(n));
}

fn subrole(obj: Object, _: SEL) callconv(.c) ?Object {
    const n = nodeOf(obj) orelse return null;
    return if (subroleOf(n)) |s| objc.nsString(s) else null;
}

fn label(obj: Object, _: SEL) callconv(.c) ?Object {
    const n = nodeOf(obj) orelse return null;
    return str(n.name);
}

fn help(obj: Object, _: SEL) callconv(.c) ?Object {
    const n = nodeOf(obj) orelse return null;
    return str(n.description);
}

fn placeholder(obj: Object, _: SEL) callconv(.c) ?Object {
    const n = nodeOf(obj) orelse return null;
    return str(n.placeholder);
}

fn number(v: f64) Object {
    return objc.msg(Object, objc.class("NSNumber"), "numberWithDouble:", .{v});
}

fn value(obj: Object, _: SEL) callconv(.c) ?Object {
    const n = nodeOf(obj) orelse return null;
    if (n.role.ranged()) return number(@max(n.range.now, n.range.min));
    switch (n.role) {
        .checkbox, .switch_, .toggle_button, .radio, .menu_item_checkbox, .tab => return number(if (n.states.mixed) 2 else if (n.states.checked or n.states.selected) 1 else 0),
        .disclosure => return number(if (n.states.expanded) 1 else 0),
        else => return str(n.value),
    }
}

fn minValue(obj: Object, _: SEL) callconv(.c) ?Object {
    const n = nodeOf(obj) orelse return null;
    return if (n.role.ranged()) number(n.range.min) else null;
}

fn maxValue(obj: Object, _: SEL) callconv(.c) ?Object {
    const n = nodeOf(obj) orelse return null;
    return if (n.role.ranged()) number(n.range.max) else null;
}

fn frame(obj: Object, _: SEL) callconv(.c) objc.CGRect {
    const e = elemOf(obj) orelse return .{};
    const n = e.owner.tree.find(e.id) orelse return .{};
    const r: objc.CGRect = .{ .origin = .{ .x = n.rect.x, .y = n.rect.y }, .size = .{ .width = n.rect.w, .height = n.rect.h } };
    return NSAccessibilityFrameInView(e.owner.host.view, r);
}

fn parent(obj: Object, _: SEL) callconv(.c) ?Object {
    const e = elemOf(obj) orelse return null;
    const n = e.owner.tree.find(e.id) orelse return e.owner.host.view;
    return e.owner.objOf(n.parent);
}

fn elementChildren(obj: Object, _: SEL) callconv(.c) ?Object {
    const e = elemOf(obj) orelse return null;
    const i = e.owner.tree.index.get(e.id) orelse return null;
    return e.owner.children(i);
}

fn isElement(_: Object, _: SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn enabled(obj: Object, _: SEL) callconv(.c) objc.BOOL {
    const n = nodeOf(obj) orelse return objc.NO;
    return !n.states.disabled;
}

fn focused(obj: Object, _: SEL) callconv(.c) objc.BOOL {
    const n = nodeOf(obj) orelse return objc.NO;
    return n.states.focused;
}

fn expanded(obj: Object, _: SEL) callconv(.c) objc.BOOL {
    const n = nodeOf(obj) orelse return objc.NO;
    return n.states.expanded;
}

fn selected(obj: Object, _: SEL) callconv(.c) objc.BOOL {
    const n = nodeOf(obj) orelse return objc.NO;
    return n.states.selected;
}

pub fn act(obj: Object, action: access.Action) objc.BOOL {
    const e = elemOf(obj) orelse return objc.NO;
    const n = e.owner.tree.find(e.id) orelse return objc.NO;
    if (n.states.disabled) return objc.NO;
    access.perform(e.owner.host.ctx, n.id, n.role, action);
    e.owner.host.request_frame(e.owner.host.ptr);
    return objc.YES;
}

fn press(obj: Object, _: SEL) callconv(.c) objc.BOOL {
    const n = nodeOf(obj) orelse return objc.NO;
    if (!n.actions.press and n.actions.expand) return act(obj, if (n.states.expanded) .collapse else .expand);
    return act(obj, .press);
}

fn increment(obj: Object, _: SEL) callconv(.c) objc.BOOL {
    return act(obj, .increment);
}

fn decrement(obj: Object, _: SEL) callconv(.c) objc.BOOL {
    return act(obj, .decrement);
}

fn setFocused(obj: Object, _: SEL, on: objc.BOOL) callconv(.c) void {
    if (on) _ = act(obj, .focus);
}

fn setValue(obj: Object, _: SEL, v: ?Object) callconv(.c) void {
    const n = nodeOf(obj) orelse return;
    const o = v orelse return;
    if (n.actions.set_value and objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class("NSString")})) {
        _ = act(obj, .{ .set_value = objc.fromNSString(o) });
    } else if (n.actions.increment and objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class("NSNumber")})) {
        const want = objc.msg(f64, o, "doubleValue", .{});
        if (want > n.range.now) _ = act(obj, .increment) else if (want < n.range.now) _ = act(obj, .decrement);
    }
}

const rect_types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:";

const element_methods = text_methods ++ [_]objc.Method{
    .{ .name = "accessibilityRole", .imp = &role, .types = "@@:" },
    .{ .name = "accessibilitySubrole", .imp = &subrole, .types = "@@:" },
    .{ .name = "accessibilityLabel", .imp = &label, .types = "@@:" },
    .{ .name = "accessibilityHelp", .imp = &help, .types = "@@:" },
    .{ .name = "accessibilityPlaceholderValue", .imp = &placeholder, .types = "@@:" },
    .{ .name = "accessibilityValue", .imp = &value, .types = "@@:" },
    .{ .name = "accessibilityMinValue", .imp = &minValue, .types = "@@:" },
    .{ .name = "accessibilityMaxValue", .imp = &maxValue, .types = "@@:" },
    .{ .name = "accessibilityFrame", .imp = &frame, .types = rect_types },
    .{ .name = "accessibilityParent", .imp = &parent, .types = "@@:" },
    .{ .name = "accessibilityChildren", .imp = &elementChildren, .types = "@@:" },
    .{ .name = "isAccessibilityElement", .imp = &isElement, .types = "B@:" },
    .{ .name = "isAccessibilityEnabled", .imp = &enabled, .types = "B@:" },
    .{ .name = "isAccessibilityFocused", .imp = &focused, .types = "B@:" },
    .{ .name = "isAccessibilityExpanded", .imp = &expanded, .types = "B@:" },
    .{ .name = "isAccessibilitySelected", .imp = &selected, .types = "B@:" },
    .{ .name = "accessibilityPerformPress", .imp = &press, .types = "B@:" },
    .{ .name = "accessibilityPerformIncrement", .imp = &increment, .types = "B@:" },
    .{ .name = "accessibilityPerformDecrement", .imp = &decrement, .types = "B@:" },
    .{ .name = "setAccessibilityFocused:", .imp = &setFocused, .types = "v@:B" },
    .{ .name = "setAccessibilityValue:", .imp = &setValue, .types = "v@:@" },
};

/// The view's methods: its elements, made the first time AppKit asks.
/// `S` is the surface: `access: ?*Access`, `ctx`, `gpa`, `nsview`,
/// `frame()` and `requestFrame()`.
pub fn viewMethods(comptime S: type) [4]objc.Method {
    const V = struct {
        fn accessOf(obj: Object) ?*Access {
            const s = objc.getZig(S, obj) orelse return null;
            if (s.access == null) {
                const Glue = struct {
                    fn frameNow(p: *anyopaque) void {
                        const self: *S = @ptrCast(@alignCast(p));
                        self.frame();
                    }
                    fn request(p: *anyopaque) void {
                        const self: *S = @ptrCast(@alignCast(p));
                        self.requestFrame();
                    }
                };
                const a = Access.create(s.gpa, .{ .ptr = s, .ctx = &s.ctx, .view = s.nsview, .frame_now = Glue.frameNow, .request_frame = Glue.request }) catch return null;
                s.access = a;
                // A tree at once, described quietly.
                a.quiet = true;
                a.host.frame_now(a.host.ptr);
                a.quiet = false;
            }
            return s.access;
        }
        fn viewChildren(obj: Object, _: SEL) callconv(.c) ?Object {
            const a = accessOf(obj) orelse return null;
            return a.children(none);
        }
        fn focusedElement(obj: Object, _: SEL) callconv(.c) ?Object {
            const a = accessOf(obj) orelse return obj;
            if (a.tree.focus == 0) return obj;
            return if (a.elems.get(a.tree.focus)) |e| e.obj else obj;
        }
        fn hitTest(obj: Object, _: SEL, p: objc.CGPoint) callconv(.c) ?Object {
            const a = accessOf(obj) orelse return obj;
            // Screen to window to view.
            const win = objc.msg(Object, obj, "window", .{});
            const r = objc.msg(objc.CGRect, win, "convertRectFromScreen:", .{objc.CGRect{ .origin = p }});
            const local = objc.msg(objc.CGPoint, obj, "convertPoint:fromView:", .{ r.origin, @as(?Object, null) });
            const n = a.tree.at(.{ .x = @floatCast(local.x), .y = @floatCast(local.y) }) orelse return obj;
            return if (a.elems.get(n.id)) |e| e.obj else obj;
        }
        fn group(_: Object, _: SEL) callconv(.c) ?Object {
            return objc.nsString("AXGroup");
        }
    };
    return .{
        .{ .name = "accessibilityChildren", .imp = &V.viewChildren, .types = "@@:" },
        .{ .name = "accessibilityFocusedUIElement", .imp = &V.focusedElement, .types = "@@:" },
        .{ .name = "accessibilityHitTest:", .imp = &V.hitTest, .types = "@@:{CGPoint=dd}" },
        .{ .name = "accessibilityRole", .imp = &V.group, .types = "@@:" },
    };
}

/// After a frame: VoiceOver sees it.
pub fn afterFrame(s: anytype) void {
    if (s.access) |a| a.update();
}

pub fn destroy(s: anytype) void {
    if (s.access) |a| a.destroy();
    s.access = null;
}
