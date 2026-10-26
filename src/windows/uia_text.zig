//! UI Automation's Text pattern (ITextProvider, ITextProvider2) of text
//! fields, text areas, the code editor and plain text: the document's
//! range, the selection, the ranges in view, the range at a point and
//! the caret's (`uia_range.zig`), and the events of a text that changed
//! and of a selection or caret that moved.
const std = @import("std");
const api_mod = @import("uia_api.zig");
const uia = @import("uia.zig");
const range_mod = @import("uia_range.zig");
const atext = @import("../ui/access_text.zig");
const tree_mod = @import("../ui/access_tree.zig");
const Node = tree_mod.Node;
const Element = uia.Element;
const Range = range_mod.Range;
const HRESULT = api_mod.HRESULT;
const S_OK = api_mod.S_OK;

pub const UiaPoint = extern struct { x: f64 align(api_mod.by_value_align), y: f64 align(api_mod.by_value_align) };

/// Whether the element has the Text pattern.
pub fn supports(n: *const Node) bool {
    return atext.hasText(n);
}

/// Tells clients the text changed, or its selection or caret moved.
pub fn changed(e: *Element, a: *const api_mod.Api, o: *const Node, n: *const Node, ch: tree_mod.Change) void {
    if (!supports(n)) return;
    const p = e.ptr(.simple);
    if (ch.value or !std.mem.eql(u8, atext.textOf(o), atext.textOf(n))) _ = a.UiaRaiseAutomationEvent(p, api_mod.Event.text_changed);
    if (ch.selection and n.actions.select_text) _ = a.UiaRaiseAutomationEvent(p, api_mod.Event.text_selection_changed);
}

/// The element and its text node, unless gone.
fn textOf(this: *anyopaque) ?struct { e: *Element, n: *const Node } {
    const e = uia.live(this) orelse return null;
    const n = e.node() orelse return null;
    if (!supports(n)) return null;
    return .{ .e = e, .n = n };
}

/// A SAFEARRAY of new ranges of `e`, which the array holds.
fn ranges(e: *Element, spans: []const [2]usize) ?*anyopaque {
    var list: [64]*anyopaque = undefined;
    var made: [64]*Range = undefined;
    var k: usize = 0;
    for (spans) |s| {
        if (k == list.len) break;
        const r = Range.create(e, s[0], s[1]) orelse continue;
        made[k] = r;
        list[k] = r.ptr();
        k += 1;
    }
    const arr = api_mod.unknownArray(list[0..k]);
    for (made[0..k]) |r| _ = r.release();
    return arr;
}

fn getSelection(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const t = textOf(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    // Plain text has none.
    const sel = [_][2]usize{.{ t.n.sel_start, t.n.sel_end }};
    p.* = ranges(t.e, if (t.n.actions.select_text) &sel else &.{});
    return S_OK;
}

fn getVisibleRanges(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const t = textOf(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    const s = atext.textOf(t.n);
    if (t.n.rows.len == 0) {
        p.* = ranges(t.e, &.{.{ 0, s.len }});
        return S_OK;
    }
    const shown = atext.visible(t.e.gpa, s, t.n.rows, t.n.rect) catch &.{};
    defer t.e.gpa.free(shown);
    p.* = ranges(t.e, shown);
    return S_OK;
}

fn rangeFromChild(this: *anyopaque, _: ?*anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const t = textOf(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    // Its text has no elements inside.
    return range_mod.out(p, Range.create(t.e, 0, 0));
}

/// The caret's place nearest a point of the screen.
fn rangeFromPoint(this: *anyopaque, pt: UiaPoint, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const t = textOf(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    const at = atext.offsetAt(atext.textOf(t.n), t.n.rows, t.e.owner.fromScreen(pt.x, pt.y)) orelse t.n.caret;
    return range_mod.out(p, Range.create(t.e, at, at));
}

fn documentRange(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const t = textOf(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    return range_mod.out(p, Range.create(t.e, 0, atext.textOf(t.n).len));
}

fn supportedTextSelection(this: *anyopaque, p: *i32) callconv(.winapi) HRESULT {
    const t = textOf(this) orelse {
        p.* = 0;
        return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    };
    p.* = @intFromBool(t.n.actions.select_text); // SupportedTextSelection_Single, or None
    return S_OK;
}

fn rangeFromAnnotation(_: *anyopaque, _: ?*anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    return api_mod.E_INVALIDARG;
}

/// The caret, and whether it is active (the text has the focus).
fn caretRange(this: *anyopaque, active: *i32, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    active.* = 0;
    const t = textOf(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    active.* = @intFromBool(t.n.states.focused);
    return range_mod.out(p, Range.create(t.e, t.n.caret, t.n.caret));
}

/// ITextProvider2's, whose first methods are ITextProvider's.
pub const vtbl = uia.unknown_methods ++ [_]*const anyopaque{
    @ptrCast(&getSelection),
    @ptrCast(&getVisibleRanges),
    @ptrCast(&rangeFromChild),
    @ptrCast(&rangeFromPoint),
    @ptrCast(&documentRange),
    @ptrCast(&supportedTextSelection),
    @ptrCast(&rangeFromAnnotation),
    @ptrCast(&caretRange),
};
