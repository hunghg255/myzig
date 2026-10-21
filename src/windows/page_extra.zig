//! A WebView2 page's asynchronous work: printing to PDF (the DevTools
//! protocol's Page.printToPDF, as Chromium's headless mode), the cookies
//! of its profile (ICoreWebView2CookieManager), and the downloads under
//! way. Each is an `Op` the page keeps until WebView2 answers; a page that
//! closes first fails them, and the answers that come later free them.
const std = @import("std");
const com = @import("com.zig");
const types = @import("../page_types.zig");
const page_find = @import("../page_find.zig");
const Page = @import("page.zig").Page;

const wv_call_dev_tools = 36;
const wv2_get_cookie_manager = 66;
const cm_create = 3;
const cm_get = 5;
const cm_add = 6;
const cm_delete_path = 9;
const cm_delete_all = 10;
const list_count = 3;
const list_value = 4;
const ck_name = 3;
const ck_value = 4;
const ck_domain = 6;
const ck_path = 7;
const ck_get_expires = 8;
const ck_put_expires = 9;
const ck_get_http_only = 10;
const ck_put_http_only = 11;
const ck_get_same_site = 12;
const ck_put_same_site = 13;
const ck_get_secure = 14;
const ck_put_secure = 15;
const ck_get_session = 16;
const iid_webview2_2 = com.GUID.parse("9e8f0cf8-e670-4b5e-b2bc-73e061e3184c");

pub const Op = struct {
    /// Null once the page closed.
    page: ?*Page,
    gpa: std.mem.Allocator,
    data: Data,

    pub const Data = union(enum) {
        download: struct { url: []const u8, path: []const u8, operation: ?com.Object = null, tokens: [2]i64 = .{ 0, 0 } },
        pdf: types.PdfCallback,
        cookies: types.CookiesCallback,
        settle: Settle,
    };

    pub fn create(page: *Page, data: Data) ?*Op {
        const gpa = page.gpa;
        // Ownership of caller-provided data transfers only on success.
        page.ops.ensureUnusedCapacity(gpa, 1) catch return null;
        const op = gpa.create(Op) catch return null;
        op.* = .{ .page = page, .gpa = gpa, .data = data };
        if (data == .download) {
            const url = gpa.dupe(u8, data.download.url) catch return destroyNow(op);
            const path = gpa.dupe(u8, data.download.path) catch {
                gpa.free(url);
                return destroyNow(op);
            };
            op.data.download.url = url;
            op.data.download.path = path;
        }
        page.ops.appendAssumeCapacity(op);
        return op;
    }

    fn destroyNow(op: *Op) ?*Op {
        op.gpa.destroy(op);
        return null;
    }

    pub fn finish(op: *Op) void {
        if (op.page) |page| for (page.ops.items, 0..) |o, i| if (o == op) {
            _ = page.ops.swapRemove(i);
            break;
        };
        switch (op.data) {
            .download => |d| {
                op.gpa.free(d.url);
                op.gpa.free(d.path);
                com.release(d.operation);
            },
            .settle => |s| op.gpa.free(s.strings),
            else => {},
        }
        op.gpa.destroy(op);
    }
};

/// A change of cookies the engine makes after its call returns: done once
/// GetCookies shows it (the cookie there, or gone), which it does within
/// a few round trips; it fails if `max_tries` of them do not.
pub const Settle = struct {
    cb: types.DoneCallback,
    strings: []u8,
    name: []const u8,
    domain: []const u8,
    path: []const u8,
    /// For a set: the value it has.
    value: ?[]const u8,
    present: bool,
    /// Every cookie gone (clearCookies).
    all: bool = false,
    tries: u32 = 0,
};
const max_tries = 500;

test "memory regression: cookie settle allocation failures free strings once" {
    const t = std.testing;
    const Probe = struct {
        calls: usize = 0,
        fn done(ctx: ?*anyopaque, err: ?[]const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(err != null);
            p.calls += 1;
        }
    };
    // Fail each allocation in turn, then exercise successful registration.
    for (0..4) |fail_index| {
        var f: @import("page_test_support.zig").Fixture = undefined;
        f.init();
        defer f.deinit();
        const page = try f.open(.{});
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        page.gpa = failing.allocator();
        defer page.gpa = t.allocator;
        var p: Probe = .{};
        settle(page, .{ .ctx = &p, .func = Probe.done }, "name", "localhost", "/", "value", true, false);
        try t.expectEqual(@as(usize, 1), p.calls);
        try t.expectEqual(@as(usize, 0), page.ops.items.len);
        page.ops.deinit(failing.allocator());
        page.ops = .empty;
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

fn settle(page: *Page, cb: types.DoneCallback, name: []const u8, domain: []const u8, path: []const u8, value: ?[]const u8, present: bool, all: bool) void {
    const gpa = page.gpa;
    const v = value orelse "";
    const strings = std.mem.concat(gpa, u8, &.{ name, domain, path, v }) catch return cb.func(cb.ctx, "out of memory");
    var s: Settle = .{ .cb = cb, .strings = strings, .name = strings[0..name.len], .domain = strings[name.len..][0..domain.len], .path = strings[name.len + domain.len ..][0..path.len], .value = null, .present = present, .all = all };
    if (value != null) s.value = strings[name.len + domain.len + path.len ..];
    const op = Op.create(page, .{ .settle = s }) orelse {
        gpa.free(strings);
        return cb.func(cb.ctx, "out of memory");
    };
    check(op);
}

fn check(op: *Op) void {
    const page = op.page orelse return op.finish();
    const m = manager(page) orelse return failOp(op, "the page closed");
    defer com.release(m);
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    if (com.failed(com.withHandler(op, checked, getCookies, .{ m, empty.ptr }))) failOp(op, "GetCookies failed");
}

fn checked(ctx: ?*anyopaque, hr: usize, list_ptr: usize) void {
    const op: *Op = @ptrCast(@alignCast(ctx));
    if (op.page == null) return op.finish();
    if (com.failed(@bitCast(@as(u32, @truncate(hr)))) or list_ptr == 0) return failOp(op, "GetCookies failed");
    const s = &op.data.settle;
    const list: com.Object = @ptrFromInt(list_ptr);
    var arena: std.heap.ArenaAllocator = .init(op.gpa);
    defer arena.deinit();
    var count: u32 = 0;
    _ = com.call(list, list_count, .{&count});
    var found = false;
    for (0..count) |i| {
        var c: ?com.Object = null;
        if (com.failed(com.call(list, list_value, .{ @as(u32, @intCast(i)), &c }))) continue;
        const cookie = c orelse continue;
        defer com.release(cookie);
        const k = readCookie(arena.allocator(), cookie) catch continue;
        if (s.all or (std.mem.eql(u8, k.name, s.name) and std.ascii.eqlIgnoreCase(std.mem.trimStart(u8, k.domain, "."), std.mem.trimStart(u8, s.domain, ".")) and std.mem.eql(u8, k.path, s.path) and
            (s.value == null or std.mem.eql(u8, k.value, s.value.?))))
        {
            found = true;
            break;
        }
    }
    if (found == s.present) {
        const cb = s.cb;
        op.finish();
        return cb.func(cb.ctx, null);
    }
    s.tries += 1;
    if (s.tries >= max_tries) return failOp(op, if (s.present) "the engine did not keep the cookie" else "the cookie is still there");
    check(op);
}

/// The page closes: its work fails now, and WebView2's late answers free it.
pub fn abandon(page: *Page) void {
    for (page.ops.items) |op| {
        op.page = null;
        switch (op.data) {
            .pdf => |cb| cb.func(cb.ctx, null, "the page closed"),
            .cookies => |cb| cb.func(cb.ctx, null, "the page closed"),
            .settle => |s| s.cb.func(s.cb.ctx, "the page closed"),
            .download => {},
        }
    }
    page.ops.clearRetainingCapacity();
}

pub fn find(page: *Page, text: []const u8, opts: types.FindOptions, cb: types.FindCallback) void {
    page_find.find(page, text, opts, cb);
}

// PDF.

pub fn printToPdf(page: *Page, o: types.PdfOptions, cb: types.PdfCallback) void {
    const wv = page.webview orelse return cb.func(cb.ctx, null, "the page is not ready");
    const params = std.fmt.allocPrint(page.gpa, "{{\"landscape\":{},\"printBackground\":{},\"paperWidth\":{d},\"paperHeight\":{d},\"marginTop\":{d},\"marginRight\":{d},\"marginBottom\":{d},\"marginLeft\":{d},\"preferCSSPageSize\":false}}", .{
        o.landscape, o.background, o.width, o.height, o.margin_top, o.margin_right, o.margin_bottom, o.margin_left,
    }) catch return cb.func(cb.ctx, null, "out of memory");
    defer page.gpa.free(params);
    const op = Op.create(page, .{ .pdf = cb }) orelse return cb.func(cb.ctx, null, "out of memory");
    const wparams = com.wide(page.gpa, params) catch return failOp(op, "out of memory");
    defer page.gpa.free(wparams);
    const method = std.unicode.utf8ToUtf16LeStringLiteral("Page.printToPDF");
    const hr = com.withHandler(op, pdfDone, devtools, .{ wv, method.ptr, wparams.ptr });
    if (com.failed(hr)) failOp(op, "Page.printToPDF failed");
}

fn devtools(wv: com.Object, method: [*:0]const u16, params: [*:0]const u16, handler: com.Object) com.HRESULT {
    return com.call(wv, wv_call_dev_tools, .{ method, params, handler });
}

fn failOp(op: *Op, why: []const u8) void {
    if (op.page != null) switch (op.data) {
        .pdf => |cb| cb.func(cb.ctx, null, why),
        .cookies => |cb| cb.func(cb.ctx, null, why),
        .settle => |s| s.cb.func(s.cb.ctx, why),
        .download => {},
    };
    op.finish();
}

fn pdfDone(ctx: ?*anyopaque, hr: usize, json_ptr: usize) void {
    const op: *Op = @ptrCast(@alignCast(ctx));
    if (op.page == null) return op.finish();
    if (com.failed(@bitCast(@as(u32, @truncate(hr)))) or json_ptr == 0) return failOp(op, "Page.printToPDF failed");
    const gpa = op.gpa;
    const json = std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(@as([*:0]const u16, @ptrFromInt(json_ptr)))) catch return failOp(op, "out of memory");
    defer gpa.free(json);
    const parsed = std.json.parseFromSlice(struct { data: []const u8 }, gpa, json, .{ .ignore_unknown_fields = true }) catch return failOp(op, "an unexpected answer of Page.printToPDF");
    defer parsed.deinit();
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(parsed.value.data) catch return failOp(op, "bad base64");
    const pdf = gpa.alloc(u8, n) catch return failOp(op, "out of memory");
    defer gpa.free(pdf);
    dec.decode(pdf, parsed.value.data) catch return failOp(op, "bad base64");
    const cb = op.data.pdf;
    op.finish();
    cb.func(cb.ctx, pdf, null);
}

// Cookies.

fn manager(page: *Page) ?com.Object {
    const wv = page.webview orelse return null;
    const wv2 = com.query(wv, &iid_webview2_2) orelse return null;
    defer com.release(wv2);
    var m: ?com.Object = null;
    if (com.failed(com.call(wv2, wv2_get_cookie_manager, .{&m}))) return null;
    return m;
}

pub fn listCookies(page: *Page, url: ?[]const u8, cb: types.CookiesCallback) void {
    const m = manager(page) orelse return cb.func(cb.ctx, null, "the page is not ready");
    defer com.release(m);
    const op = Op.create(page, .{ .cookies = cb }) orelse return cb.func(cb.ctx, null, "out of memory");
    const wurl = com.wide(page.gpa, url orelse "") catch return failOp(op, "out of memory");
    defer page.gpa.free(wurl);
    const hr = com.withHandler(op, cookiesListed, getCookies, .{ m, wurl.ptr });
    if (com.failed(hr)) failOp(op, "GetCookies failed");
}

fn getCookies(m: com.Object, url: [*:0]const u16, handler: com.Object) com.HRESULT {
    return com.call(m, cm_get, .{ url, handler });
}

fn cookiesListed(ctx: ?*anyopaque, hr: usize, list_ptr: usize) void {
    const op: *Op = @ptrCast(@alignCast(ctx));
    if (op.page == null) return op.finish();
    if (com.failed(@bitCast(@as(u32, @truncate(hr)))) or list_ptr == 0) return failOp(op, "GetCookies failed");
    const list: com.Object = @ptrFromInt(list_ptr);
    var arena: std.heap.ArenaAllocator = .init(op.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var count: u32 = 0;
    _ = com.call(list, list_count, .{&count});
    const out = a.alloc(types.Cookie, count) catch return failOp(op, "out of memory");
    var n: usize = 0;
    for (0..count) |i| {
        var c: ?com.Object = null;
        if (com.failed(com.call(list, list_value, .{ @as(u32, @intCast(i)), &c }))) continue;
        const cookie = c orelse continue;
        defer com.release(cookie);
        out[n] = readCookie(a, cookie) catch continue;
        n += 1;
    }
    const cb = op.data.cookies;
    op.finish();
    cb.func(cb.ctx, out[0..n], null);
}

fn readCookie(a: std.mem.Allocator, c: com.Object) !types.Cookie {
    const str = struct {
        fn get(alloc: std.mem.Allocator, obj: com.Object, index: usize) ![]u8 {
            var p: ?[*:0]u16 = null;
            if (com.failed(com.call(obj, index, .{&p}))) return error.Cookie;
            return com.takeString(alloc, p);
        }
    }.get;
    var secure: i32 = 0;
    var http_only: i32 = 0;
    var session: i32 = 0;
    var same_site: i32 = 1;
    var expires: f64 = -1;
    _ = com.call(c, ck_get_secure, .{&secure});
    _ = com.call(c, ck_get_http_only, .{&http_only});
    _ = com.call(c, ck_get_session, .{&session});
    _ = com.call(c, ck_get_same_site, .{&same_site});
    _ = com.call(c, ck_get_expires, .{&expires});
    return .{
        .name = try str(a, c, ck_name),
        .value = try str(a, c, ck_value),
        .domain = try str(a, c, ck_domain),
        .path = try str(a, c, ck_path),
        .expires = if (session != 0 or !(expires >= 0 and expires < 253402300800)) null else @intFromFloat(expires),
        .secure = secure != 0,
        .http_only = http_only != 0,
        .same_site = switch (same_site) {
            0 => .none,
            2 => .strict,
            else => .lax,
        },
    };
}

/// Adds the cookie, or replaces the one of its name, domain and path.
pub fn setCookie(page: *Page, c: types.Cookie, cb: types.DoneCallback) void {
    const m = manager(page) orelse return cb.func(cb.ctx, "the page is not ready");
    defer com.release(m);
    const gpa = page.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const w = struct {
        fn f(alloc: std.mem.Allocator, s: []const u8) ![*:0]const u16 {
            return (try com.wide(alloc, s)).ptr;
        }
    }.f;
    var cookie: ?com.Object = null;
    const name = w(a, c.name) catch return cb.func(cb.ctx, "out of memory");
    const value = w(a, c.value) catch return cb.func(cb.ctx, "out of memory");
    const domain = w(a, c.domain) catch return cb.func(cb.ctx, "out of memory");
    const path = w(a, if (c.path.len == 0) "/" else c.path) catch return cb.func(cb.ctx, "out of memory");
    if (com.failed(com.call(m, cm_create, .{ name, value, domain, path, &cookie }))) return cb.func(cb.ctx, "CreateCookie failed");
    const obj = cookie orelse return cb.func(cb.ctx, "CreateCookie failed");
    defer com.release(obj);
    const expires: f64 = if (c.expires) |e| @floatFromInt(e) else -1;
    _ = com.call(obj, ck_put_expires, .{expires});
    _ = com.call(obj, ck_put_secure, .{@as(i32, @intFromBool(c.secure))});
    _ = com.call(obj, ck_put_http_only, .{@as(i32, @intFromBool(c.http_only))});
    _ = com.call(obj, ck_put_same_site, .{@as(i32, switch (c.same_site) {
        .none => 0,
        .lax => 1,
        .strict => 2,
    })});
    if (com.failed(com.call(m, cm_add, .{obj}))) return cb.func(cb.ctx, "AddOrUpdateCookie failed (a name, value or domain the engine refuses)");
    settle(page, cb, c.name, c.domain, if (c.path.len == 0) "/" else c.path, c.value, true, false);
}

pub fn deleteCookie(page: *Page, name: []const u8, domain: []const u8, path: []const u8, cb: types.DoneCallback) void {
    const m = manager(page) orelse return cb.func(cb.ctx, "the page is not ready");
    defer com.release(m);
    var arena: std.heap.ArenaAllocator = .init(page.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const n = com.wide(a, name) catch return cb.func(cb.ctx, "out of memory");
    const d = com.wide(a, domain) catch return cb.func(cb.ctx, "out of memory");
    const p = com.wide(a, if (path.len == 0) "/" else path) catch return cb.func(cb.ctx, "out of memory");
    if (com.failed(com.call(m, cm_delete_path, .{ n.ptr, d.ptr, p.ptr }))) return cb.func(cb.ctx, "DeleteCookiesWithDomainAndPath failed");
    settle(page, cb, name, domain, if (path.len == 0) "/" else path, null, false, false);
}

pub fn clearCookies(page: *Page, cb: types.DoneCallback) void {
    const m = manager(page) orelse return cb.func(cb.ctx, "the page is not ready");
    defer com.release(m);
    if (com.failed(com.call(m, cm_delete_all, .{}))) return cb.func(cb.ctx, "DeleteAllCookies failed");
    settle(page, cb, "", "", "", null, false, true);
}
