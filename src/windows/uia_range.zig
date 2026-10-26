//! UI Automation's text ranges (ITextRangeProvider): bytes [start, end)
//! of an element's text, COM objects of their own, which Narrator moves
//! and grows by characters, words, lines, paragraphs and the document
//! (`ui/access_text.zig`), reads, compares, finds text in, selects, and
//! asks the boxes and the formats of. A range holds its element and reads
//! its node as it is when used: the text may have changed since.
const std = @import("std");
const api_mod = @import("uia_api.zig");
const uia = @import("uia.zig");
const atext = @import("../ui/access_text.zig");
const tree_mod = @import("../ui/access_tree.zig");
const Node = tree_mod.Node;
const Element = uia.Element;
const HRESULT = api_mod.HRESULT;
const S_OK = api_mod.S_OK;
const VARIANT = api_mod.VARIANT;
const Unit = atext.Unit;

pub const iid: api_mod.GUID = .parse("5347ad7b-c355-46f8-aff5-909033582f63");

pub const Range = extern struct {
    vtbl: *const anyopaque = &range_vtbl,
    refs: u32 = 1,
    e: *Element,
    start: usize,
    end: usize,

    /// A range of `e`'s text, holding `e`; null without memory.
    pub fn create(e: *Element, start: usize, end: usize) ?*Range {
        const r = e.gpa.create(Range) catch return null;
        r.* = .{ .e = e, .start = start, .end = @max(start, end) };
        _ = e.addRef();
        return r;
    }

    pub fn ptr(r: *Range) *anyopaque {
        return @ptrCast(r);
    }

    pub fn release(r: *Range) u32 {
        r.refs -= 1;
        const left = r.refs;
        if (left == 0) {
            const e = r.e;
            e.gpa.destroy(r);
            _ = e.release();
        }
        return left;
    }

    /// Its element's node and text, the range kept within it; null once
    /// the element is gone.
    pub fn live(r: *Range) ?struct { n: *const Node, s: []const u8 } {
        const n = r.e.node() orelse return null;
        if (!atext.hasText(n)) return null;
        const s = atext.textOf(n);
        var x: atext.Range = .{ .start = r.start, .end = r.end };
        x.clamp(s);
        r.start = x.start;
        r.end = x.end;
        return .{ .n = n, .s = s };
    }

    fn span(r: *const Range) atext.Range {
        return .{ .start = r.start, .end = r.end };
    }

    fn set(r: *Range, x: atext.Range) void {
        r.start = x.start;
        r.end = x.end;
    }
};

fn of(this: *anyopaque) *Range {
    return @ptrCast(@alignCast(this));
}

/// Another range of ours (COM hands back what it was given), or null.
fn other(p: ?*anyopaque) ?*Range {
    const q = p orelse return null;
    const r = of(q);
    return if (r.vtbl == @as(*const anyopaque, &range_vtbl)) r else null;
}

/// Stores a new range (owned by the caller), or null.
pub fn out(p: *?*anyopaque, r: ?*Range) HRESULT {
    p.* = if (r) |x| x.ptr() else null;
    return S_OK;
}

fn endpoint(r: *const Range, ep: i32) usize {
    return if (ep != 0) r.end else r.start;
}

const gone = api_mod.UIA_E_ELEMENTNOTAVAILABLE;

fn queryInterface(this: *anyopaque, id: *const api_mod.GUID, p: *?*anyopaque) callconv(.winapi) HRESULT {
    if (id.eql(api_mod.iid_unknown) or id.eql(iid)) {
        of(this).refs += 1;
        p.* = this;
        return S_OK;
    }
    p.* = null;
    return api_mod.E_NOINTERFACE;
}

fn addRef(this: *anyopaque) callconv(.winapi) u32 {
    of(this).refs += 1;
    return of(this).refs;
}

fn release(this: *anyopaque) callconv(.winapi) u32 {
    return of(this).release();
}

fn clone(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    const r = of(this);
    return out(p, Range.create(r.e, r.start, r.end));
}

fn compare(this: *anyopaque, q: ?*anyopaque, p: *i32) callconv(.winapi) HRESULT {
    const r = of(this);
    const o = other(q);
    p.* = @intFromBool(o != null and o.?.e == r.e and o.?.start == r.start and o.?.end == r.end);
    return S_OK;
}

fn compareEndpoints(this: *anyopaque, ep: i32, q: ?*anyopaque, qep: i32, p: *i32) callconv(.winapi) HRESULT {
    const o = other(q) orelse return api_mod.E_INVALIDARG;
    const a: i64 = @intCast(endpoint(of(this), ep));
    const b: i64 = @intCast(endpoint(o, qep));
    p.* = @intCast(std.math.clamp(a - b, std.math.minInt(i32), std.math.maxInt(i32)));
    return S_OK;
}

fn expandToEnclosingUnit(this: *anyopaque, unit: i32) callconv(.winapi) HRESULT {
    const r = of(this);
    const l = r.live() orelse return gone;
    var x = r.span();
    x.expand(l.s, l.n.rows, Unit.of(unit));
    r.set(x);
    return S_OK;
}

/// The value of a text attribute, the same over all the text (one
/// format); null for those it has not.
fn attribute(n: *const Node, attr: i32) ?VARIANT {
    return switch (attr) {
        40005 => .string("Segoe UI"), // FontName
        40007 => .int(400), // FontWeight
        40012 => .int(0), // HorizontalTextAlignment: left
        40013 => .boolean(false), // IsHidden
        40014 => .boolean(false), // IsItalic
        40015 => .boolean(!n.actions.set_value), // IsReadOnly
        40039 => .int(0), // CaretBidiMode: left to right
        else => null,
    };
}

fn same(a: VARIANT, b: VARIANT) bool {
    if (a.vt != b.vt) return false;
    return switch (a.vt) {
        api_mod.VT_BOOL => (a.data[0] & 0xffff != 0) == (b.data[0] & 0xffff != 0),
        api_mod.VT_I4 => @as(u32, @truncate(a.data[0])) == @as(u32, @truncate(b.data[0])),
        api_mod.VT_BSTR => blk: {
            const x: ?[*:0]const u16 = @ptrFromInt(@as(usize, @intCast(a.data[0])));
            const y: ?[*:0]const u16 = @ptrFromInt(@as(usize, @intCast(b.data[0])));
            if (x == null or y == null) break :blk x == y;
            break :blk std.mem.eql(u16, std.mem.span(x.?), std.mem.span(y.?));
        },
        else => a.data[0] == b.data[0],
    };
}

fn findAttribute(this: *anyopaque, attr: i32, val: VARIANT, _: i32, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const r = of(this);
    const l = r.live() orelse return gone;
    var v = attribute(l.n, attr) orelse return S_OK;
    defer _ = api_mod.api().?.VariantClear(&v);
    // One format: the whole range has it, or none does.
    if (same(v, val)) return out(p, Range.create(r.e, r.start, r.end));
    return S_OK;
}

fn findText(this: *anyopaque, s: ?[*:0]const u16, backward: i32, ignore_case: i32, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const r = of(this);
    const l = r.live() orelse return gone;
    const w = s orelse return api_mod.E_INVALIDARG;
    const needle = std.unicode.utf16LeToUtf8Alloc(r.e.gpa, std.mem.span(w)) catch return api_mod.E_INVALIDARG;
    defer r.e.gpa.free(needle);
    const at = atext.find(l.s[r.start..r.end], needle, backward != 0, ignore_case != 0) orelse return S_OK;
    return out(p, Range.create(r.e, r.start + at, r.start + at + needle.len));
}

fn getAttributeValue(this: *anyopaque, attr: i32, p: *VARIANT) callconv(.winapi) HRESULT {
    p.* = .{};
    const r = of(this);
    const l = r.live() orelse return gone;
    if (attribute(l.n, attr)) |v| {
        p.* = v;
        return S_OK;
    }
    const a = api_mod.api() orelse return S_OK;
    var unk: ?*anyopaque = null;
    _ = a.UiaGetReservedNotSupportedValue(&unk);
    p.* = .of(api_mod.VT_UNKNOWN, @intFromPtr(unk));
    return S_OK;
}

fn getBoundingRectangles(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const r = of(this);
    const l = r.live() orelse return gone;
    const gpa = r.e.gpa;
    const boxes = atext.rects(gpa, l.n.rows, r.start, r.end) catch &.{};
    defer gpa.free(boxes);
    var values: std.ArrayList(f64) = .empty;
    defer values.deinit(gpa);
    const self = r.e.owner;
    if (l.n.rows.len == 0 and r.end > r.start) {
        const b = self.screenRect(l.n);
        values.appendSlice(gpa, &.{ b.left, b.top, b.width, b.height }) catch {};
    }
    for (boxes) |box| {
        // Clipped to what shows of the element.
        const vis = box.intersect(l.n.rect);
        if (vis.h <= 0 or (vis.w <= 0 and box.w > 1)) continue;
        const b = self.toScreen(.{ .x = vis.x, .y = vis.y, .w = @max(vis.w, 1), .h = vis.h });
        values.appendSlice(gpa, &.{ b.left, b.top, b.width, b.height }) catch {};
    }
    p.* = api_mod.doubleArray(values.items);
    return S_OK;
}

fn getEnclosingElement(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    const r = of(this);
    if (r.e.dead) {
        p.* = null;
        return gone;
    }
    return uia.out(p, r.e, .simple);
}

fn getText(this: *anyopaque, max: i32, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const r = of(this);
    const l = r.live() orelse return gone;
    p.* = api_mod.bstrLong(r.e.gpa, l.s[r.start..r.end], max);
    return S_OK;
}

fn move(this: *anyopaque, unit: i32, count: i32, p: *i32) callconv(.winapi) HRESULT {
    p.* = 0;
    const r = of(this);
    const l = r.live() orelse return gone;
    var x = r.span();
    p.* = x.move(l.s, l.n.rows, Unit.of(unit), count);
    r.set(x);
    return S_OK;
}

fn moveEndpointByUnit(this: *anyopaque, ep: i32, unit: i32, count: i32, p: *i32) callconv(.winapi) HRESULT {
    p.* = 0;
    const r = of(this);
    const l = r.live() orelse return gone;
    var x = r.span();
    p.* = x.moveEndpoint(l.s, l.n.rows, ep != 0, Unit.of(unit), count);
    r.set(x);
    return S_OK;
}

fn moveEndpointByRange(this: *anyopaque, ep: i32, q: ?*anyopaque, qep: i32) callconv(.winapi) HRESULT {
    const r = of(this);
    const o = other(q) orelse return api_mod.E_INVALIDARG;
    const at = endpoint(o, qep);
    if (ep != 0) {
        r.end = at;
        r.start = @min(r.start, at);
    } else {
        r.start = at;
        r.end = @max(r.end, at);
    }
    return S_OK;
}

/// Selects the range in its text field, as the pointer would.
fn select(this: *anyopaque) callconv(.winapi) HRESULT {
    const r = of(this);
    const l = r.live() orelse return gone;
    if (!l.n.actions.select_text) return api_mod.UIA_E_INVALIDOPERATION;
    return uia.act(r.e, .{ .select_text = .{ @intCast(r.start), @intCast(r.end) } });
}

fn noSelection(_: *anyopaque) callconv(.winapi) HRESULT {
    return api_mod.UIA_E_INVALIDOPERATION;
}

fn scrollIntoView(this: *anyopaque, _: i32) callconv(.winapi) HRESULT {
    const r = of(this);
    const l = r.live() orelse return gone;
    if (!l.n.actions.scroll_into_view) return S_OK;
    return uia.act(r.e, .scroll_into_view);
}

fn getChildren(_: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = api_mod.unknownArray(&.{});
    return S_OK;
}

const range_vtbl = [_]*const anyopaque{
    @ptrCast(&queryInterface),        @ptrCast(&addRef),                @ptrCast(&release),
    @ptrCast(&clone),                 @ptrCast(&compare),               @ptrCast(&compareEndpoints),
    @ptrCast(&expandToEnclosingUnit), @ptrCast(&findAttribute),         @ptrCast(&findText),
    @ptrCast(&getAttributeValue),     @ptrCast(&getBoundingRectangles), @ptrCast(&getEnclosingElement),
    @ptrCast(&getText),               @ptrCast(&move),                  @ptrCast(&moveEndpointByUnit),
    @ptrCast(&moveEndpointByRange),   @ptrCast(&select),                @ptrCast(&noSelection),
    @ptrCast(&noSelection),           @ptrCast(&scrollIntoView),        @ptrCast(&getChildren),
};
