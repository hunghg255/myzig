//! UI Automation's Text pattern in process: a text field's and a text
//! area's ranges through the provider's COM interfaces (text, moves by
//! words and lines, boxes, the range at a point, the caret, a selection
//! set from a range), then through UI Automation's own client
//! (CUIAutomation), which asks the hidden window as Narrator does.
const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32.zig");
const com = @import("com.zig");
const api_mod = @import("uia_api.zig");
const uia = @import("uia.zig");
const ui = @import("../ui/ui.zig");
const access = @import("../ui/access.zig");
const testing = std.testing;

const App = struct {
    name: ui.TextBuffer = .{},
    notes: ui.TextArea = undefined,

    fn view(s: *App, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        _ = ui.textField(c, &s.name, .{ .label = "Name" });
        _ = ui.textArea(c, &s.notes, .{ .height = .{ .px = 120 } });
    }
};

const Fixture = struct {
    app: App = .{},
    t: ui.Tester = undefined,
    hwnd: w.HWND = undefined,
    acc: *uia.Access = undefined,

    var current: ?*Fixture = null;

    fn perform(p: *anyopaque, id: u64, role: access.Role, action: access.Action) void {
        const f: *Fixture = @ptrCast(@alignCast(p));
        access.perform(&f.t.ctx, id, role, action);
    }

    fn frameNow(p: *anyopaque) void {
        const f: *Fixture = @ptrCast(@alignCast(p));
        f.step();
    }

    fn scale(_: *anyopaque) f32 {
        return 1;
    }

    fn step(f: *Fixture) void {
        f.t.frame();
        f.acc.update();
    }

    fn wndProc(h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
        if (msg == api_mod.WM_GETOBJECT) if (current) |f| if (f.acc.getObject(wp, lp)) |r| return r;
        return w.DefWindowProcW(h, msg, wp, lp);
    }

    fn init(f: *Fixture) !void {
        f.app.name.set("hello wide world");
        f.app.notes = .init(testing.allocator, "first line\nsecond line");
        errdefer f.app.notes.deinit();
        try f.t.init(testing.allocator, .init(&f.app, App.view), .{});
        errdefer f.t.deinit();
        const class = std.unicode.utf8ToUtf16LeStringLiteral("myzig-uia-text-test");
        const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .lpszClassName = class, .hInstance = w.GetModuleHandleW(null) };
        _ = w.RegisterClassExW(&wc);
        // Never shown: no WS_VISIBLE, and nothing shows it.
        f.hwnd = w.CreateWindowExW(0, class, class, 0x00CF0000, 0, 0, 480, 360, null, null, w.GetModuleHandleW(null), null) orelse return error.NoWindow;
        f.acc = try uia.Access.create(testing.allocator, f.hwnd, .{ .ptr = f, .ctx = &f.t.ctx, .perform = perform, .frame_now = frameNow, .scale = scale });
        current = f;
        f.step();
        f.step();
    }

    fn deinit(f: *Fixture) void {
        current = null;
        f.acc.destroy();
        _ = DestroyWindow(f.hwnd);
        f.t.deinit();
        f.app.notes.deinit();
    }

    /// The provider of the text element `multiline` or not.
    fn textElement(f: *Fixture, multiline: bool) !*uia.Element {
        for (f.acc.tree.nodes.items) |n| if (n.role == .text_field and n.states.multiline == multiline) return f.acc.element(n.id) orelse error.NoElement;
        return error.NoField;
    }

    fn selection(f: *Fixture, multiline: bool) ![2]u32 {
        for (f.acc.tree.nodes.items) |n| if (n.role == .text_field and n.states.multiline == multiline) return .{ n.sel_start, n.sel_end };
        return error.NoField;
    }
};

extern "user32" fn DestroyWindow(h: w.HWND) callconv(.winapi) i32;
extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT;
extern "oleaut32" fn SafeArrayGetUBound(sa: *anyopaque, dim: u32, out: *i32) callconv(.winapi) com.HRESULT;
extern "oleaut32" fn SafeArrayGetElement(sa: *anyopaque, index: *const i32, out: *anyopaque) callconv(.winapi) com.HRESULT;
extern "oleaut32" fn SafeArrayDestroy(sa: *anyopaque) callconv(.winapi) com.HRESULT;

/// A range's text (GetText, method 12 of providers and clients alike).
fn textOf(range: *anyopaque) ![]u8 {
    var b: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(range, 12, .{ @as(i32, -1), &b }));
    const a = api_mod.api().?;
    defer a.SysFreeString(b);
    const p: [*:0]const u16 = @ptrCast(@alignCast(b orelse return testing.allocator.dupe(u8, "")));
    return std.unicode.utf16LeToUtf8Alloc(testing.allocator, std.mem.span(p));
}

fn expectText(range: *anyopaque, want: []const u8) !void {
    const got = try textOf(range);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

/// A SAFEARRAY's doubles (destroyed).
fn doubles(sa: ?*anyopaque, out: []f64) !usize {
    const arr = sa orelse return 0;
    defer _ = SafeArrayDestroy(arr);
    var hi: i32 = -1;
    _ = SafeArrayGetUBound(arr, 1, &hi);
    const n: usize = @intCast(hi + 1);
    try testing.expect(n <= out.len);
    for (0..n) |i| {
        const at: i32 = @intCast(i);
        _ = SafeArrayGetElement(arr, &at, &out[i]);
    }
    return n;
}

/// A SAFEARRAY's first interface (AddRef'd), the array destroyed.
fn firstOf(sa: ?*anyopaque) !?*anyopaque {
    const arr = sa orelse return null;
    defer _ = SafeArrayDestroy(arr);
    var hi: i32 = -1;
    _ = SafeArrayGetUBound(arr, 1, &hi);
    if (hi < 0) return null;
    var p: ?*anyopaque = null;
    const at: i32 = 0;
    _ = SafeArrayGetElement(arr, &at, @ptrCast(&p));
    return p;
}

fn pattern(el: *anyopaque, id: i32) !*anyopaque {
    var p: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(el, 4, .{ id, &p }));
    return p orelse error.NoPattern;
}

const UiaPoint = @import("uia_text.zig").UiaPoint;

test "the Text pattern's ranges through the provider: words, lines, boxes, points, selection" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (api_mod.api() == null) return error.SkipZigTest;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();

    const field = try f.textElement(false);
    const simple = field.ptr(.simple);
    const text = try pattern(simple, 10014);
    defer com.release(text);
    var doc: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(text, 7, .{&doc})); // DocumentRange
    defer com.release(doc);
    try expectText(doc.?, "hello wide world");

    // A caret at the start, grown to its word, moved a word on.
    var r: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(doc.?, 3, .{&r})); // Clone
    const word = r.?;
    defer com.release(word);
    try testing.expectEqual(com.S_OK, com.call(word, 15, .{ @as(i32, 1), doc.?, @as(i32, 0) })); // MoveEndpointByRange: end to start
    try expectText(word, "");
    try testing.expectEqual(com.S_OK, com.call(word, 6, .{@as(i32, 2)})); // ExpandToEnclosingUnit: word
    try expectText(word, "hello ");
    var moved: i32 = 0;
    try testing.expectEqual(com.S_OK, com.call(word, 13, .{ @as(i32, 2), @as(i32, 1), &moved })); // Move
    try testing.expectEqual(@as(i32, 1), moved);
    try expectText(word, "wide ");
    var cmp: i32 = 0;
    try testing.expectEqual(com.S_OK, com.call(word, 5, .{ @as(i32, 0), doc.?, @as(i32, 0), &cmp })); // CompareEndpoints
    try testing.expect(cmp > 0);

    // Its box: on the field's row, right of its start.
    var box: [8]f64 = undefined;
    var sa: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(word, 10, .{&sa}));
    try testing.expectEqual(@as(usize, 4), try doubles(sa, &box));
    var whole: api_mod.UiaRect = .{};
    try testing.expectEqual(com.S_OK, com.call(field.ptr(.fragment), 5, .{&whole}));
    try testing.expect(box[2] > 0 and box[3] > 0);
    try testing.expect(box[0] > whole.left + 20 and box[0] + box[2] < whole.left + whole.width);
    try testing.expect(box[1] >= whole.top and box[1] + box[3] <= whole.top + whole.height + 0.5);

    // The range at the middle of that box is in that word.
    var at: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(text, 6, .{ UiaPoint{ .x = box[0] + box[2] / 2 - 4, .y = box[1] + box[3] / 2 }, &at })); // RangeFromPoint
    defer com.release(at);
    try testing.expectEqual(com.S_OK, com.call(at.?, 6, .{@as(i32, 2)}));
    try expectText(at.?, "wide ");

    // Found without case; read only it is not.
    const b = api_mod.bstr("WIDE").?;
    var found: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(doc.?, 8, .{ b, @as(i32, 0), @as(i32, 1), &found })); // FindText
    api_mod.api().?.SysFreeString(b);
    try expectText(found.?, "wide");
    var v: api_mod.VARIANT = .{};
    try testing.expectEqual(com.S_OK, com.call(found.?, 9, .{ @as(i32, 40015), &v }));
    try testing.expectEqual(api_mod.VT_BOOL, v.vt);
    try testing.expectEqual(@as(u64, 0), v.data[0] & 0xffff);

    // Selected from the range: the field's selection, and the provider's.
    try testing.expectEqual(com.S_OK, com.call(found.?, 16, .{})); // Select
    com.release(found);
    f.step();
    try testing.expectEqual([2]u32{ 6, 10 }, try f.selection(false));
    var sel: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(text, 3, .{&sel})); // GetSelection
    const first = (try firstOf(sel)) orelse return error.NoSelection;
    defer com.release(first);
    try expectText(first, "wide");
    // The caret, at the selection's end, through ITextProvider2.
    const text2 = try pattern(simple, 10024);
    defer com.release(text2);
    var active: i32 = -1;
    var caret: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(text2, 10, .{ &active, &caret }));
    defer com.release(caret);
    try testing.expectEqual(@as(i32, 0), active);
    try testing.expectEqual(com.S_OK, com.call(caret.?, 14, .{ @as(i32, 0), @as(i32, 2), @as(i32, -1), &moved })); // start back a word
    try expectText(caret.?, "wide");

    // The text area: lines, a box for each.
    const area = try f.textElement(true);
    const atext = try pattern(area.ptr(.simple), 10014);
    defer com.release(atext);
    var adoc: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(atext, 7, .{&adoc}));
    defer com.release(adoc);
    try expectText(adoc.?, "first line\nsecond line");
    sa = null;
    try testing.expectEqual(com.S_OK, com.call(adoc.?, 10, .{&sa}));
    try testing.expectEqual(@as(usize, 8), try doubles(sa, &box));
    try testing.expect(box[5] >= box[1] + box[3] - 0.5);
    r = null;
    try testing.expectEqual(com.S_OK, com.call(adoc.?, 3, .{&r}));
    const line = r.?;
    defer com.release(line);
    try testing.expectEqual(com.S_OK, com.call(line, 15, .{ @as(i32, 1), adoc.?, @as(i32, 0) }));
    try testing.expectEqual(com.S_OK, com.call(line, 6, .{@as(i32, 3)})); // line
    try expectText(line, "first line\n");
    try testing.expectEqual(com.S_OK, com.call(line, 13, .{ @as(i32, 3), @as(i32, 1), &moved }));
    try expectText(line, "second line");
    try testing.expectEqual(com.S_OK, com.call(line, 16, .{}));
    f.step();
    try testing.expectEqual([2]u32{ 11, 22 }, try f.selection(true));
    try testing.expectEqual(@as(usize, 11), f.app.notes.sel.lo());
}

test "UI Automation's client reads a field's text by ranges and selects in it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (api_mod.api() == null) return error.SkipZigTest;
    _ = com.CoInitializeEx(null, 2);
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();

    const clsid: com.GUID = .parse("ff48dba4-60ef-4201-aa87-54103eef594e");
    const iid: com.GUID = .parse("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee");
    var client: ?*anyopaque = null;
    if (com.failed(CoCreateInstance(&clsid, null, 1, &iid, &client))) return error.SkipZigTest;
    const automation = client.?;
    defer com.release(automation);
    var window: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(automation, 6, .{ f.hwnd, &window })); // ElementFromHandle
    defer com.release(window);
    var cond: ?*anyopaque = null;
    var name: api_mod.VARIANT = .string("Name");
    defer _ = api_mod.api().?.VariantClear(&name);
    try testing.expectEqual(com.S_OK, com.call(automation, 23, .{ @as(i32, api_mod.Prop.name), name, &cond })); // CreatePropertyCondition
    defer com.release(cond);
    var el: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(window.?, 5, .{ @as(i32, 4), cond.?, &el })); // FindFirst
    const field = el orelse return error.NotFound;
    defer com.release(field);

    var pat: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(field, 16, .{ @as(i32, 10014), &pat })); // GetCurrentPattern
    const text = pat orelse return error.NoText;
    defer com.release(text);
    var doc: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(text, 7, .{&doc})); // get_DocumentRange
    defer com.release(doc);
    try expectText(doc.?, "hello wide world");
    // The last word: the start moved on two words.
    var r: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(doc.?, 3, .{&r}));
    const last = r.?;
    defer com.release(last);
    var moved: i32 = 0;
    try testing.expectEqual(com.S_OK, com.call(last, 14, .{ @as(i32, 0), @as(i32, 2), @as(i32, 2), &moved })); // MoveEndpointByUnit
    try testing.expectEqual(@as(i32, 2), moved);
    try expectText(last, "world");
    var box: [8]f64 = undefined;
    var sa: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(last, 10, .{&sa})); // GetBoundingRectangles
    try testing.expectEqual(@as(usize, 4), try doubles(sa, &box));
    try testing.expect(box[2] > 0);
    try testing.expectEqual(com.S_OK, com.call(last, 16, .{})); // Select
    f.step();
    try testing.expectEqual([2]u32{ 11, 16 }, try f.selection(false));

    pat = null;
    try testing.expectEqual(com.S_OK, com.call(field, 16, .{ @as(i32, 10024), &pat }));
    const text2 = pat orelse return error.NoText2;
    defer com.release(text2);
    var active: i32 = -1;
    var caret: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, com.call(text2, 10, .{ &active, &caret })); // GetCaretRange
    defer com.release(caret);
    try testing.expectEqual(com.S_OK, com.call(caret.?, 14, .{ @as(i32, 0), @as(i32, 0), @as(i32, -5), &moved }));
    try expectText(caret.?, "world");
}
