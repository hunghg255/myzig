//! NSAccessibility's text of text fields, text areas and plain text
//! (VoiceOver reads and moves through them): the number of characters,
//! the selected range and text (set as the pointer would), the range in
//! view, the string and the box of a range, lines and the range at a
//! point. Ranges count UTF-16 code units, as NSString does; lines are the
//! rows the text is drawn in (`ui/access_text.zig`).
const std = @import("std");
const objc = @import("../objc.zig");
const mac = @import("access_mac.zig");
const atext = @import("access_text.zig");
const types = @import("types.zig");
const Node = @import("access_tree.zig").Node;
const Object = objc.Object;
const SEL = objc.SEL;

pub const NSRange = extern struct { location: objc.NSUInteger = 0, length: objc.NSUInteger = 0 };

extern "c" fn NSAccessibilityFrameInView(view: Object, frame: objc.CGRect) objc.CGRect;

/// The element's node and text, if it has one.
fn textOf(obj: Object) ?struct { n: *const Node, s: []const u8 } {
    const n = mac.nodeOf(obj) orelse return null;
    if (!atext.hasText(n)) return null;
    return .{ .n = n, .s = atext.textOf(n) };
}

fn rangeOf(s: []const u8, a: usize, b: usize) NSRange {
    const lo = atext.utf16Of(s, a);
    return .{ .location = lo, .length = atext.utf16Of(s, b) - lo };
}

/// An NSRange's bytes, within the text.
fn bytesOf(s: []const u8, r: NSRange) [2]usize {
    const a = atext.byteOfUtf16(s, r.location);
    return .{ a, @max(a, atext.byteOfUtf16(s, r.location +| r.length)) };
}

fn characters(obj: Object, _: SEL) callconv(.c) objc.NSInteger {
    const t = textOf(obj) orelse return 0;
    return @intCast(atext.utf16Of(t.s, t.s.len));
}

fn selectedRange(obj: Object, _: SEL) callconv(.c) NSRange {
    const t = textOf(obj) orelse return .{};
    return rangeOf(t.s, t.n.sel_start, t.n.sel_end);
}

fn setSelectedRange(obj: Object, _: SEL, r: NSRange) callconv(.c) void {
    const t = textOf(obj) orelse return;
    if (!t.n.actions.select_text) return;
    const b = bytesOf(t.s, r);
    _ = mac.act(obj, .{ .select_text = .{ @intCast(b[0]), @intCast(b[1]) } });
}

fn selectedText(obj: Object, _: SEL) callconv(.c) ?Object {
    const t = textOf(obj) orelse return null;
    return objc.nsString(t.s[t.n.sel_start..@min(t.n.sel_end, t.s.len)]);
}

/// Typing over the selection, as Voice Control, dictation and automation
/// insert text (kAXSelectedTextAttribute).
fn setSelectedText(obj: Object, _: SEL, v: ?Object) callconv(.c) void {
    const n = mac.nodeOf(obj) orelse return;
    const o = v orelse return;
    if (!n.actions.set_value or !objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class("NSString")})) return;
    _ = mac.act(obj, .{ .insert_text = objc.fromNSString(o) });
}

fn visibleRange(obj: Object, _: SEL) callconv(.c) NSRange {
    const t = textOf(obj) orelse return .{};
    if (t.n.rows.len == 0) return rangeOf(t.s, 0, t.s.len);
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const shown = atext.visible(fba.allocator(), t.s, t.n.rows, t.n.rect) catch return rangeOf(t.s, 0, t.s.len);
    if (shown.len == 0) return .{};
    return rangeOf(t.s, shown[0][0], shown[shown.len - 1][1]);
}

fn stringForRange(obj: Object, _: SEL, r: NSRange) callconv(.c) ?Object {
    const t = textOf(obj) orelse return null;
    const b = bytesOf(t.s, r);
    return objc.nsString(t.s[b[0]..b[1]]);
}

/// The box of a range on the screen: its rows' joined, else the element's.
fn frameForRange(obj: Object, _: SEL, r: NSRange) callconv(.c) objc.CGRect {
    const t = textOf(obj) orelse return .{};
    const e = mac.elemOf(obj) orelse return .{};
    const b = bytesOf(t.s, r);
    const box = atext.bounds(t.n.rows, b[0], b[1]) orelse t.n.rect;
    const cg: objc.CGRect = .{ .origin = .{ .x = box.x, .y = box.y }, .size = .{ .width = box.w, .height = box.h } };
    return NSAccessibilityFrameInView(e.owner.host.view, cg);
}

/// The line of byte `at`: how many lines start before it.
fn lineOf(n: *const Node, s: []const u8, at: usize) usize {
    var k: usize = 0;
    var i: usize = 0;
    while (true) {
        const nx = atext.next(s, n.rows, i, .line);
        if (nx > at or nx >= s.len) return k;
        k += 1;
        i = nx;
    }
}

fn insertionLine(obj: Object, _: SEL) callconv(.c) objc.NSInteger {
    const t = textOf(obj) orelse return 0;
    return @intCast(lineOf(t.n, t.s, t.n.caret));
}

fn lineForIndex(obj: Object, _: SEL, index: objc.NSInteger) callconv(.c) objc.NSInteger {
    const t = textOf(obj) orelse return 0;
    return @intCast(lineOf(t.n, t.s, atext.byteOfUtf16(t.s, @intCast(@max(index, 0)))));
}

fn rangeForLine(obj: Object, _: SEL, line: objc.NSInteger) callconv(.c) NSRange {
    const t = textOf(obj) orelse return .{};
    var i: usize = 0;
    var k: isize = 0;
    while (k < line and i < t.s.len) : (k += 1) i = atext.next(t.s, t.n.rows, i, .line);
    return rangeOf(t.s, i, atext.next(t.s, t.n.rows, i, .line));
}

fn rangeForIndex(obj: Object, _: SEL, index: objc.NSInteger) callconv(.c) NSRange {
    const t = textOf(obj) orelse return .{};
    const a = atext.byteOfUtf16(t.s, @intCast(@max(index, 0)));
    return rangeOf(t.s, a, atext.nextChar(t.s, a));
}

/// The character at a point of the screen.
fn rangeForPosition(obj: Object, _: SEL, p: objc.CGPoint) callconv(.c) NSRange {
    const t = textOf(obj) orelse return .{};
    const e = mac.elemOf(obj) orelse return .{};
    const view = e.owner.host.view;
    const win = objc.msg(Object, view, "window", .{});
    const r = objc.msg(objc.CGRect, win, "convertRectFromScreen:", .{objc.CGRect{ .origin = p }});
    const local = objc.msg(objc.CGPoint, view, "convertPoint:fromView:", .{ r.origin, @as(?Object, null) });
    const at = atext.offsetAt(t.s, t.n.rows, .{ .x = @floatCast(local.x), .y = @floatCast(local.y) }) orelse t.n.caret;
    return rangeOf(t.s, at, atext.nextChar(t.s, at));
}

const range_type = "{_NSRange=QQ}";

pub const methods = [_]objc.Method{
    .{ .name = "accessibilityNumberOfCharacters", .imp = &characters, .types = "q@:" },
    .{ .name = "accessibilitySelectedTextRange", .imp = &selectedRange, .types = range_type ++ "@:" },
    .{ .name = "setAccessibilitySelectedTextRange:", .imp = &setSelectedRange, .types = "v@:" ++ range_type },
    .{ .name = "accessibilitySelectedText", .imp = &selectedText, .types = "@@:" },
    .{ .name = "setAccessibilitySelectedText:", .imp = &setSelectedText, .types = "v@:@" },
    .{ .name = "accessibilityVisibleCharacterRange", .imp = &visibleRange, .types = range_type ++ "@:" },
    .{ .name = "accessibilityStringForRange:", .imp = &stringForRange, .types = "@@:" ++ range_type },
    .{ .name = "accessibilityFrameForRange:", .imp = &frameForRange, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:" ++ range_type },
    .{ .name = "accessibilityInsertionPointLineNumber", .imp = &insertionLine, .types = "q@:" },
    .{ .name = "accessibilityLineForIndex:", .imp = &lineForIndex, .types = "q@:q" },
    .{ .name = "accessibilityRangeForLine:", .imp = &rangeForLine, .types = range_type ++ "@:q" },
    .{ .name = "accessibilityRangeForIndex:", .imp = &rangeForIndex, .types = range_type ++ "@:q" },
    .{ .name = "accessibilityRangeForPosition:", .imp = &rangeForPosition, .types = range_type ++ "@:{CGPoint=dd}" },
};
