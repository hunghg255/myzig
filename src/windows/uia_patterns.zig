//! The properties and control patterns of UI Automation's elements:
//! Invoke presses buttons and links, Toggle checkboxes and switches,
//! SelectionItem chooses radio buttons, tabs and rows (in the Selection
//! of their list), RangeValue moves sliders as the arrow keys do, Value
//! sets text fields' text, ExpandCollapse opens popups, disclosures and
//! tree items, ScrollItem scrolls what scrolls into view, and Text reads
//! texts by ranges (`uia_text.zig`).
const std = @import("std");
const api_mod = @import("uia_api.zig");
const uia = @import("uia.zig");
const tree_mod = @import("../ui/access_tree.zig");
const Node = tree_mod.Node;
const Iface = api_mod.Iface;
const HRESULT = api_mod.HRESULT;
const S_OK = api_mod.S_OK;
const VARIANT = api_mod.VARIANT;
const Element = uia.Element;
const Prop = api_mod.Prop;
const text = @import("uia_text.zig");

/// Whether the element implements an interface.
pub fn supports(e: *Element, i: Iface) bool {
    switch (i) {
        .simple, .fragment => return true,
        .root => return e.is_root,
        else => {},
    }
    const n = e.node() orelse return false;
    return switch (i) {
        .invoke => switch (n.role) {
            .checkbox, .switch_, .radio, .popup_button, .tab, .menu_button, .toggle_button, .disclosure, .combo_box, .tree_item => false,
            else => n.actions.press,
        },
        // Items of menus showing a choice toggle it, and are invoked too.
        .toggle => n.role == .checkbox or n.role == .switch_ or n.role == .toggle_button or n.role == .menu_item_checkbox or n.role == .menu_item_radio,
        .selection_item => switch (n.role) {
            .radio, .tab, .tree_item => true,
            .list_item, .row => n.states.selectable,
            else => false,
        },
        .selection => (n.role == .list or n.role == .table or n.role == .tree or n.role == .tab_list or n.role == .radio_group),
        .scroll_item => n.actions.scroll_into_view,
        .text, .text2 => text.supports(n),
        .range_value => n.role.ranged(),
        .value => n.role == .text_field or n.role == .popup_button or n.role == .combo_box or n.role == .color_well,
        .expand_collapse => n.role == .popup_button or n.role == .menu_button or n.role == .combo_box or n.role == .disclosure or
            (n.role == .tree_item and n.states.expandable) or (n.states.has_popup and n.role == .menu_item),
        else => false,
    };
}

fn toggleState(n: *const Node) i32 {
    if (n.states.mixed) return 2; // ToggleState_Indeterminate
    return @intFromBool(n.states.checked);
}

fn expandState(n: *const Node) i32 {
    if (n.states.expanded) return 1; // ExpandCollapseState_Expanded
    if (n.role == .tree_item and !n.states.expandable) return 3; // LeafNode
    return 0;
}

fn chosen(n: *const Node) bool {
    return n.states.selected or (n.role == .radio and n.states.checked);
}

/// The value of a range, its minimum for progress of unknown length.
fn rangeNow(n: *const Node) f64 {
    return @max(n.range.now, n.range.min);
}

fn smallChange(n: *const Node) f64 {
    return if (n.range.step > 0) n.range.step else (n.range.max - n.range.min) / 100;
}

/// Fills in a property, leaving those it has not empty for UI Automation's defaults.
pub fn property(e: *Element, prop: i32, v: *VARIANT) void {
    if (e.is_root) return; // the window's
    const n = e.node() orelse return;
    const str = struct {
        fn f(out: *VARIANT, s: []const u8) void {
            if (s.len > 0) out.* = .string(s);
        }
    }.f;
    switch (prop) {
        Prop.control_type => v.* = .int(api_mod.controlType(n.role)),
        Prop.localized_control_type => str(v, switch (n.role) {
            .switch_ => "toggle switch",
            .menu_button => "menu button",
            .radio_group => "radio group",
            .dialog => "dialog",
            .alert_dialog => "alert dialog",
            .popup => "popup",
            .heading => "heading",
            .status => "status",
            else => "",
        }),
        Prop.name => str(v, n.name),
        Prop.automation_id => if (n.id != uia.announcer_id) {
            var buf: [20]u8 = undefined;
            str(v, std.fmt.bufPrint(&buf, "{x}", .{n.id}) catch "");
        },
        Prop.has_keyboard_focus => v.* = .boolean(n.states.focused),
        Prop.is_keyboard_focusable => v.* = .boolean(n.states.focusable),
        Prop.is_enabled => v.* = .boolean(!n.states.disabled),
        // A text field's placeholder, else the description, as Chromium's.
        Prop.help_text => str(v, if (n.placeholder.len > 0) n.placeholder else n.description),
        Prop.full_description => str(v, n.description),
        Prop.is_data_valid => v.* = .boolean(!n.states.invalid),
        Prop.is_password => v.* = .boolean(n.states.password),
        Prop.framework_id => str(v, "myzig"),
        Prop.is_dialog => v.* = .boolean(n.role == .dialog or n.role == .alert_dialog),
        Prop.is_offscreen => v.* = .boolean(n.states.offscreen),
        Prop.orientation => if (n.role == .slider or n.role == .splitter) {
            v.* = .int(if (n.states.vertical) 2 else 1); // OrientationType
        },
        // HeadingLevel1 to 9, as Chromium's headings.
        Prop.heading_level => if (n.role == .heading and n.level > 0) {
            v.* = .int(80050 + @as(i32, @intCast(@min(n.level, 9))));
        },
        Prop.level => if (n.level > 0 and n.role != .heading) {
            v.* = .int(@intCast(n.level));
        },
        Prop.position_in_set => if (n.pos_in_set > 0) {
            v.* = .int(@intCast(n.pos_in_set));
        },
        Prop.size_of_set => if (n.set_size > 0) {
            v.* = .int(@intCast(n.set_size));
        },
        Prop.item_status => str(v, if (n.role == .column_header) n.description else ""),
        // Statuses and announcements are polite live regions.
        Prop.live_setting => if (n.role == .status or n.id == uia.announcer_id) {
            v.* = .int(1);
        },
        Prop.value => if (supports(e, .value)) str(v, n.value),
        Prop.toggle_state => if (supports(e, .toggle)) {
            v.* = .int(toggleState(n));
        },
        Prop.expand_state => if (supports(e, .expand_collapse)) {
            v.* = .int(expandState(n));
        },
        Prop.is_selected => if (supports(e, .selection_item)) {
            v.* = .boolean(chosen(n));
        },
        Prop.range_value => if (n.role.ranged()) {
            v.* = .double(rangeNow(n));
        },
        else => {},
    }
}

/// Tells clients how an element changed.
pub fn changed(e: *Element, a: *const api_mod.Api, o: *const Node, n: *const Node, ch: tree_mod.Change) void {
    const p = e.ptr(.simple);
    text.changed(e, a, o, n, ch);
    const raise = struct {
        fn f(api: *const api_mod.Api, el: *anyopaque, prop: i32, before: VARIANT, after: VARIANT) void {
            var b = before;
            var x = after;
            _ = api.UiaRaiseAutomationPropertyChangedEvent(el, prop, b, x);
            _ = api.VariantClear(&b);
            _ = api.VariantClear(&x);
        }
    }.f;
    if (ch.name) raise(a, p, Prop.name, .string(o.name), .string(n.name));
    if (ch.value and supports(e, .value)) raise(a, p, Prop.value, .string(o.value), .string(n.value));
    if (ch.range and n.role.ranged() and rangeNow(o) != rangeNow(n)) raise(a, p, Prop.range_value, .double(rangeNow(o)), .double(rangeNow(n)));
    if (!ch.states) return;
    if (o.states.disabled != n.states.disabled) raise(a, p, Prop.is_enabled, .boolean(!o.states.disabled), .boolean(!n.states.disabled));
    if (supports(e, .toggle) and toggleState(o) != toggleState(n)) raise(a, p, Prop.toggle_state, .int(toggleState(o)), .int(toggleState(n)));
    if (supports(e, .expand_collapse) and expandState(o) != expandState(n)) raise(a, p, Prop.expand_state, .int(expandState(o)), .int(expandState(n)));
    if (supports(e, .selection_item) and chosen(o) != chosen(n)) {
        raise(a, p, Prop.is_selected, .boolean(chosen(o)), .boolean(chosen(n)));
        if (chosen(n)) _ = a.UiaRaiseAutomationEvent(p, api_mod.Event.element_selected);
    }
}

fn press(this: *anyopaque) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    return uia.act(e, .press);
}

fn toggleStateGet(this: *anyopaque, p: *i32) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    p.* = if (e.node()) |n| toggleState(n) else 0;
    return S_OK;
}

fn select(this: *anyopaque) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    const n = e.node() orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    if (chosen(n)) return S_OK;
    return uia.act(e, .press);
}

fn removeFromSelection(_: *anyopaque) callconv(.winapi) HRESULT {
    return api_mod.UIA_E_INVALIDOPERATION;
}

fn isSelected(this: *anyopaque, p: *i32) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    p.* = if (e.node()) |n| @intFromBool(chosen(n)) else 0;
    return S_OK;
}

/// The list, table or tree around an item whose Selection holds it.
fn container(e: *Element) ?*Element {
    const t = &e.owner.tree;
    var i = t.index.get(e.id) orelse return null;
    while (t.nodes.items[i].parent != tree_mod.none) {
        i = t.nodes.items[i].parent;
        const c = e.owner.elements.get(t.nodes.items[i].id) orelse return null;
        if (supports(c, .selection)) return c;
    }
    return null;
}

fn selectionContainer(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    return uia.out(p, container(e), .simple);
}

fn getSelection(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    var list: [64]*anyopaque = undefined;
    var k: usize = 0;
    for (e.owner.tree.nodes.items) |*n| {
        if (k == list.len or !chosen(n)) continue;
        const d = e.owner.elements.get(n.id) orelse continue;
        if (supports(d, .selection_item) and container(d) == e) {
            list[k] = d.ptr(.simple);
            k += 1;
        }
    }
    p.* = api_mod.unknownArray(list[0..k]);
    return S_OK;
}

fn canSelectMultiple(this: *anyopaque, p: *i32) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    p.* = if (e.node()) |n| @intFromBool(n.states.multiselectable) else 0;
    return S_OK;
}

fn isSelectionRequired(_: *anyopaque, p: *i32) callconv(.winapi) HRESULT {
    p.* = 0;
    return S_OK;
}

fn scrollIntoView(this: *anyopaque) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    return uia.act(e, .scroll_into_view);
}

/// Moves a slider toward a value as the arrow keys do, a step at a time.
fn setRange(this: *anyopaque, v: f64) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    const n = e.node() orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    if (!n.actions.increment) return api_mod.UIA_E_INVALIDOPERATION;
    if (v > n.range.now) return uia.act(e, .increment);
    if (v < n.range.now) return uia.act(e, .decrement);
    return S_OK;
}

fn rangeGetter(comptime get: fn (*const Node) f64) *const anyopaque {
    return @ptrCast(&struct {
        fn f(this: *anyopaque, p: *f64) callconv(.winapi) HRESULT {
            const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
            p.* = if (e.node()) |n| get(n) else 0;
            return S_OK;
        }
    }.f);
}

fn rangeMax(n: *const Node) f64 {
    return n.range.max;
}

fn rangeMin(n: *const Node) f64 {
    return n.range.min;
}

fn largeChange(n: *const Node) f64 {
    return @max(smallChange(n), (n.range.max - n.range.min) / 10);
}

fn rangeReadOnly(this: *anyopaque, p: *i32) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    p.* = if (e.node()) |n| @intFromBool(!n.actions.increment) else 1;
    return S_OK;
}

fn setValue(this: *anyopaque, s: ?[*:0]const u16) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    const n = e.node() orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    if (!n.actions.set_value) return api_mod.UIA_E_INVALIDOPERATION;
    var buf: [4096]u8 = undefined;
    const src = if (s) |p| std.mem.span(p) else &[_]u16{};
    const len = std.unicode.utf16LeToUtf8(&buf, src[0..@min(src.len, buf.len / 3)]) catch return api_mod.E_INVALIDARG;
    return uia.act(e, .{ .set_value = buf[0..len] });
}

fn getValue(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    p.* = api_mod.bstr(if (e.node()) |n| n.value else "");
    return S_OK;
}

fn valueReadOnly(this: *anyopaque, p: *i32) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    p.* = if (e.node()) |n| @intFromBool(!n.actions.set_value) else 1;
    return S_OK;
}

fn expandOr(comptime open: bool) *const anyopaque {
    return @ptrCast(&struct {
        fn f(this: *anyopaque) callconv(.winapi) HRESULT {
            const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
            const n = e.node() orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
            if (n.states.expanded == open) return S_OK;
            return uia.act(e, if (open) .expand else .collapse);
        }
    }.f);
}

fn expandStateGet(this: *anyopaque, p: *i32) callconv(.winapi) HRESULT {
    const e = uia.live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    p.* = if (e.node()) |n| expandState(n) else 0;
    return S_OK;
}

const u = uia.unknown_methods;
const invoke_vtbl = u ++ [_]*const anyopaque{@ptrCast(&press)};
const toggle_vtbl = u ++ [_]*const anyopaque{ @ptrCast(&press), @ptrCast(&toggleStateGet) };
const selection_item_vtbl = u ++ [_]*const anyopaque{ @ptrCast(&select), @ptrCast(&select), @ptrCast(&removeFromSelection), @ptrCast(&isSelected), @ptrCast(&selectionContainer) };
const selection_vtbl = u ++ [_]*const anyopaque{ @ptrCast(&getSelection), @ptrCast(&canSelectMultiple), @ptrCast(&isSelectionRequired) };
const scroll_item_vtbl = u ++ [_]*const anyopaque{@ptrCast(&scrollIntoView)};
const range_vtbl = u ++ [_]*const anyopaque{ @ptrCast(&setRange), rangeGetter(rangeNow), @ptrCast(&rangeReadOnly), rangeGetter(rangeMax), rangeGetter(rangeMin), rangeGetter(largeChange), rangeGetter(smallChange) };
const value_vtbl = u ++ [_]*const anyopaque{ @ptrCast(&setValue), @ptrCast(&getValue), @ptrCast(&valueReadOnly) };
const expand_vtbl = u ++ [_]*const anyopaque{ expandOr(true), expandOr(false), @ptrCast(&expandStateGet) };

pub const vtables = [_]struct { Iface, *const anyopaque }{
    .{ .invoke, &invoke_vtbl },
    .{ .toggle, &toggle_vtbl },
    .{ .selection_item, &selection_item_vtbl },
    .{ .selection, &selection_vtbl },
    .{ .scroll_item, &scroll_item_vtbl },
    .{ .range_value, &range_vtbl },
    .{ .value, &value_vtbl },
    .{ .expand_collapse, &expand_vtbl },
    .{ .text, &text.vtbl },
    .{ .text2, &text.vtbl },
};
