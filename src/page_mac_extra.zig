//! A macOS page's asynchronous work: the app's schemes answered in parts
//! (WKURLSchemeTask streams), downloads (WKDownload, macOS 11.3+), PDFs
//! (createPDF, macOS 11+) and the cookies of the default data store
//! (WKHTTPCookieStore). Each waits in the page; a page that closes first
//! fails what is under way, and answers that come later go nowhere.
const std = @import("std");
const objc = @import("objc.zig");
const types = @import("page_types.zig");
const core_mod = @import("page_core.zig");
const serve = @import("page_serve.zig");
const desktop = @import("desktop.zig");
const Page = @import("page.zig").Page;
const callBlock = @import("page_mac_delegate.zig").callBlock;

// Schemes.

/// A request waiting for the app's answer.
pub const Task = struct {
    /// Null once the page closed or WebKit stopped the task.
    page: ?*Page,
    task: objc.Object,
};

pub fn startTask(self_obj: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object) callconv(.c) void {
    const page = objc.getZig(Page, self_obj) orelse return;
    if (page.dead) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const gpa = page.gpa;
    const request = objc.msg(objc.Object, task, "request", .{});
    const nsurl = objc.msg(?objc.Object, request, "URL", .{});
    const url = objc.fromNSString(if (nsurl) |u| objc.msg(?objc.Object, u, "absoluteString", .{}) else null);
    const method = objc.fromNSString(objc.msg(?objc.Object, request, "HTTPMethod", .{}));
    var body: []const u8 = "";
    if (objc.msg(?objc.Object, request, "HTTPBody", .{})) |data| {
        const n = objc.msg(objc.NSUInteger, data, "length", .{});
        if (objc.msg(?[*]const u8, data, "bytes", .{})) |p| body = p[0..n];
    }
    const t = gpa.create(Task) catch return;
    t.* = .{ .page = page, .task = objc.retain(task) };
    page.tasks.append(gpa, t) catch {};
    const r = types.SchemeRequest.create(gpa, if (method.len == 0) "GET" else method, url, body, .{ .ctx = t, .begin = begin, .write = write, .finish = finish }) catch {
        drop(t, gpa);
        return;
    };
    const scheme = url[0 .. std.mem.indexOfScalar(u8, url, ':') orelse 0];
    const page_url = page.currentUrl(gpa) catch null;
    defer if (page_url) |u| gpa.free(u);
    serve.dispatch(&page.core, page.window.app, r, scheme, page_url);
}

pub fn stopTask(self_obj: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object) callconv(.c) void {
    const page = objc.getZig(Page, self_obj) orelse return;
    for (page.tasks.items, 0..) |t, i| if (t.task == task) {
        t.page = null; // WebKit must not hear of it again
        _ = page.tasks.swapRemove(i);
        return;
    };
}

fn begin(ctx: *anyopaque, req: *types.SchemeRequest) void {
    const t: *Task = @ptrCast(@alignCast(ctx));
    if (t.page == null) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    var keys: [64]objc.Object = undefined;
    var values: [64]objc.Object = undefined;
    var n: usize = 0;
    var it = std.mem.splitSequence(u8, req.headers.items, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (n == keys.len) break;
        keys[n] = objc.nsString(line[0..colon]);
        values[n] = objc.nsString(std.mem.trim(u8, line[colon + 1 ..], " "));
        n += 1;
    }
    const headers = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, n) });
    const url = objc.msg(objc.Object, objc.msg(objc.Object, t.task, "request", .{}), "URL", .{});
    const res = objc.msg(objc.Object, objc.alloc("NSHTTPURLResponse"), "initWithURL:statusCode:HTTPVersion:headerFields:", .{
        url, @as(objc.NSInteger, req.status), objc.nsString("HTTP/1.1"), headers,
    });
    defer objc.release(res);
    objc.msg(void, t.task, "didReceiveResponse:", .{res});
}

fn write(ctx: *anyopaque, _: *types.SchemeRequest, bytes: []const u8) void {
    const t: *Task = @ptrCast(@alignCast(ctx));
    if (t.page == null or bytes.len == 0) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len });
    objc.msg(void, t.task, "didReceiveData:", .{data});
}

fn finish(ctx: *anyopaque, req: *types.SchemeRequest) void {
    const t: *Task = @ptrCast(@alignCast(ctx));
    const gpa = req.gpa;
    defer req.destroy();
    if (t.page != null) objc.msg(void, t.task, "didFinish", .{});
    drop(t, gpa);
}

fn drop(t: *Task, gpa: std.mem.Allocator) void {
    if (t.page) |page| for (page.tasks.items, 0..) |x, i| if (x == t) {
        _ = page.tasks.swapRemove(i);
        break;
    };
    objc.release(t.task);
    gpa.destroy(t);
}

// The rest.

pub const Op = struct {
    /// Null once the page closed.
    page: ?*Page,
    gpa: std.mem.Allocator,
    data: Data,

    pub const Data = union(enum) {
        download: struct { download: objc.Object, url: []const u8, path: []const u8 = "" },
        pdf: types.PdfCallback,
        cookies: struct { cb: types.CookiesCallback, url: []const u8 = "" },
        done: struct { cb: types.DoneCallback, key: []const u8 = "", pending: u32 = 0 },
    };

    fn create(page: *Page, data: Data) ?*Op {
        const op = page.gpa.create(Op) catch return null;
        op.* = .{ .page = page, .gpa = page.gpa, .data = data };
        page.ops.append(page.gpa, op) catch {
            page.gpa.destroy(op);
            return null;
        };
        return op;
    }

    fn finish(op: *Op) void {
        if (op.page) |page| for (page.ops.items, 0..) |o, i| if (o == op) {
            _ = page.ops.swapRemove(i);
            break;
        };
        const gpa = op.gpa;
        switch (op.data) {
            .download => |d| {
                objc.release(d.download);
                gpa.free(d.url);
                if (d.path.len > 0) gpa.free(d.path);
            },
            .cookies => |c| if (c.url.len > 0) gpa.free(c.url),
            .done => |d| if (d.key.len > 0) gpa.free(d.key),
            .pdf => {},
        }
        gpa.destroy(op);
    }
};

/// The page closes: its work fails now, and late answers go nowhere.
pub fn abandon(page: *Page) void {
    for (page.tasks.items) |t| t.page = null;
    page.tasks.clearRetainingCapacity();
    for (page.ops.items) |op| {
        op.page = null;
        switch (op.data) {
            .pdf => |cb| cb.func(cb.ctx, null, "the page closed"),
            .cookies => |c| c.cb.func(c.cb.ctx, null, "the page closed"),
            .done => |d| d.cb.func(d.cb.ctx, "the page closed"),
            .download => {},
        }
    }
    page.ops.clearRetainingCapacity();
}

// Downloads.

fn downloadOp(page: *Page, download: objc.Object) ?*Op {
    for (page.ops.items) |op| if (op.data == .download and op.data.download.download == download) return op;
    return null;
}

pub fn becameDownload(self_obj: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, download: objc.Object) callconv(.c) void {
    const page = objc.getZig(Page, self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    objc.msg(void, download, "setDelegate:", .{self_obj});
    const request = objc.msg(?objc.Object, download, "originalRequest", .{});
    const nsurl = if (request) |r| objc.msg(?objc.Object, r, "URL", .{}) else null;
    const url = page.gpa.dupe(u8, objc.fromNSString(if (nsurl) |u| objc.msg(?objc.Object, u, "absoluteString", .{}) else null)) catch return;
    _ = Op.create(page, .{ .download = .{ .download = objc.retain(download), .url = url } }) orelse page.gpa.free(url);
}

pub fn decideDestination(self_obj: objc.Object, _: objc.SEL, download: objc.Object, _: objc.Object, suggested: objc.Object, completion: *anyopaque) callconv(.c) void {
    const none: ?objc.Object = null;
    const page = objc.getZig(Page, self_obj) orelse return callBlock(completion, none);
    const op = downloadOp(page, download) orelse return callBlock(completion, none);
    const pool = objc.Pool.push();
    defer pool.pop();
    const gpa = page.gpa;
    const dir = desktop.path(gpa, .downloads, page.window.app.options.name) catch null;
    defer if (dir) |x| gpa.free(x);
    const path = page.core.startDownload(page.window.app.io, dir, op.data.download.url, core_mod.safeName(objc.fromNSString(suggested))) orelse return callBlock(completion, none);
    op.data.download.path = path;
    std.Io.Dir.cwd().deleteFile(page.window.app.io, path) catch {}; // a file there is replaced
    callBlock(completion, @as(?objc.Object, objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)})));
}

pub fn downloadFinished(self_obj: objc.Object, _: objc.SEL, download: objc.Object) callconv(.c) void {
    const page = objc.getZig(Page, self_obj) orelse return;
    const op = downloadOp(page, download) orelse return;
    const d = op.data.download;
    page.core.fire(.{ .download_done = .{ .url = d.url, .path = d.path } });
    op.finish();
}

pub fn downloadFailed(self_obj: objc.Object, _: objc.SEL, download: objc.Object, err: objc.Object, _: ?objc.Object) callconv(.c) void {
    const page = objc.getZig(Page, self_obj) orelse return;
    const op = downloadOp(page, download) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const d = op.data.download;
    page.core.fire(.{ .download_done = .{ .url = d.url, .path = d.path, .err = objc.fromNSString(objc.msg(?objc.Object, err, "localizedDescription", .{})) } });
    op.finish();
}

// PDF.

pub fn printToPdf(page: *Page, _: types.PdfOptions, cb: types.PdfCallback) void {
    if (!objc.msg(objc.BOOL, page.webview, "respondsToSelector:", .{objc.sel("createPDFWithConfiguration:completionHandler:")}))
        return cb.func(cb.ctx, null, "printing to PDF needs macOS 11");
    const op = Op.create(page, .{ .pdf = cb }) orelse return cb.func(cb.ctx, null, "out of memory");
    var block = objc.Block(Op, &.{ ?objc.Object, ?objc.Object }).init(op, pdfDone);
    objc.msg(void, page.webview, "createPDFWithConfiguration:completionHandler:", .{ @as(?objc.Object, null), &block });
}

fn pdfDone(op: *Op, data: ?objc.Object, err: ?objc.Object) void {
    const cb = op.data.pdf;
    const alive = op.page != null;
    op.finish();
    if (!alive) return;
    const d = data orelse return cb.func(cb.ctx, null, if (err) |e| objc.fromNSString(objc.msg(?objc.Object, e, "localizedDescription", .{})) else "createPDF failed");
    const n = objc.msg(objc.NSUInteger, d, "length", .{});
    const p = objc.msg(?[*]const u8, d, "bytes", .{}) orelse return cb.func(cb.ctx, null, "an empty PDF");
    cb.func(cb.ctx, p[0..n], null);
}

// Cookies.

fn store() objc.Object {
    const ds = objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "defaultDataStore", .{});
    return objc.msg(objc.Object, ds, "httpCookieStore", .{});
}

pub fn listCookies(page: *Page, url: ?[]const u8, cb: types.CookiesCallback) void {
    const copy = page.gpa.dupe(u8, url orelse "") catch return cb.func(cb.ctx, null, "out of memory");
    const op = Op.create(page, .{ .cookies = .{ .cb = cb, .url = copy } }) orelse {
        page.gpa.free(copy);
        return cb.func(cb.ctx, null, "out of memory");
    };
    var block = objc.Block(Op, &.{objc.Object}).init(op, listed);
    objc.msg(void, store(), "getAllCookies:", .{&block});
}

/// Whether a request to `url` sends the cookie: its host in the domain,
/// its path under the cookie's, https for a secure one.
fn sends(url: []const u8, c: types.Cookie) bool {
    const https = std.ascii.startsWithIgnoreCase(url, "https://");
    if (c.secure and !https) return false;
    const rest = url[(std.mem.indexOf(u8, url, "://") orelse return false) + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, ":/?#") orelse rest.len;
    const host = rest[0..host_end];
    const domain = std.mem.trimStart(u8, c.domain, ".");
    const in_domain = std.ascii.eqlIgnoreCase(host, domain) or (host.len > domain.len and std.ascii.endsWithIgnoreCase(host, domain) and host[host.len - domain.len - 1] == '.');
    if (!in_domain) return false;
    const path = types.pathOf(url);
    return std.mem.startsWith(u8, path, c.path);
}

fn readCookie(c: objc.Object) types.Cookie {
    const expires = objc.msg(?objc.Object, c, "expiresDate", .{});
    const same = objc.fromNSString(objc.msg(?objc.Object, c, "sameSitePolicy", .{}));
    return .{
        .name = objc.fromNSString(objc.msg(?objc.Object, c, "name", .{})),
        .value = objc.fromNSString(objc.msg(?objc.Object, c, "value", .{})),
        .domain = objc.fromNSString(objc.msg(?objc.Object, c, "domain", .{})),
        .path = objc.fromNSString(objc.msg(?objc.Object, c, "path", .{})),
        .expires = if (expires) |e| @intFromFloat(objc.msg(f64, e, "timeIntervalSince1970", .{})) else null,
        .secure = objc.msg(objc.BOOL, c, "isSecure", .{}),
        .http_only = objc.msg(objc.BOOL, c, "isHTTPOnly", .{}),
        .same_site = if (std.ascii.eqlIgnoreCase(same, "strict")) .strict else if (same.len == 0 or std.ascii.eqlIgnoreCase(same, "lax")) .lax else .none,
    };
}

fn listed(op: *Op, cookies: objc.Object) void {
    const c = op.data.cookies;
    const alive = op.page != null;
    defer op.finish();
    if (!alive) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    var out: std.ArrayList(types.Cookie) = .empty;
    defer out.deinit(op.gpa);
    const n = objc.msg(objc.NSUInteger, cookies, "count", .{});
    for (0..n) |i| {
        const k = readCookie(objc.msg(objc.Object, cookies, "objectAtIndex:", .{@as(objc.NSUInteger, i)}));
        if (c.url.len > 0 and !sends(c.url, k)) continue;
        out.append(op.gpa, k) catch {};
    }
    c.cb.func(c.cb.ctx, out.items, null);
}

pub fn setCookie(page: *Page, c: types.Cookie, cb: types.DoneCallback) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    var keys: [8]objc.Object = undefined;
    var values: [8]objc.Object = undefined;
    var n: usize = 0;
    const put = struct {
        fn f(k: []objc.Object, v: []objc.Object, i: *usize, key: []const u8, value: objc.Object) void {
            k[i.*] = objc.nsString(key);
            v[i.*] = value;
            i.* += 1;
        }
    }.f;
    put(&keys, &values, &n, "Name", objc.nsString(c.name));
    put(&keys, &values, &n, "Value", objc.nsString(c.value));
    put(&keys, &values, &n, "Domain", objc.nsString(c.domain));
    put(&keys, &values, &n, "Path", objc.nsString(if (c.path.len == 0) "/" else c.path));
    if (c.secure) put(&keys, &values, &n, "Secure", objc.nsString("TRUE"));
    if (c.http_only) put(&keys, &values, &n, "HttpOnly", objc.nsString("TRUE"));
    put(&keys, &values, &n, "SameSite", objc.nsString(@tagName(c.same_site)));
    if (c.expires) |e| put(&keys, &values, &n, "Expires", objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSince1970:", .{@as(f64, @floatFromInt(e))}));
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, n) });
    const cookie = objc.msg(?objc.Object, objc.class("NSHTTPCookie"), "cookieWithProperties:", .{props}) orelse return cb.func(cb.ctx, "a cookie WebKit does not take");
    const op = Op.create(page, .{ .done = .{ .cb = cb, .pending = 1 } }) orelse return cb.func(cb.ctx, "out of memory");
    var block = objc.Block(Op, &.{}).init(op, changed);
    objc.msg(void, store(), "setCookie:completionHandler:", .{ cookie, &block });
}

fn changed(op: *Op) void {
    const d = &op.data.done;
    if (d.pending > 0) d.pending -= 1;
    if (d.pending > 0) return;
    const cb = d.cb;
    const alive = op.page != null;
    op.finish();
    if (alive) cb.func(cb.ctx, null);
}

/// Deletes the cookies WebKit has of a name, domain and path.
pub fn deleteCookie(page: *Page, name: []const u8, domain: []const u8, path: []const u8, cb: types.DoneCallback) void {
    const key = std.mem.concat(page.gpa, u8, &.{ name, "\x00", std.mem.trimStart(u8, domain, "."), "\x00", if (path.len == 0) "/" else path }) catch return cb.func(cb.ctx, "out of memory");
    const op = Op.create(page, .{ .done = .{ .cb = cb, .key = key } }) orelse {
        page.gpa.free(key);
        return cb.func(cb.ctx, "out of memory");
    };
    var block = objc.Block(Op, &.{objc.Object}).init(op, toDelete);
    objc.msg(void, store(), "getAllCookies:", .{&block});
}

fn toDelete(op: *Op, cookies: objc.Object) void {
    const d = &op.data.done;
    var parts = std.mem.splitScalar(u8, d.key, 0);
    const name = parts.next().?;
    const domain = parts.next().?;
    const path = parts.next().?;
    const n = objc.msg(objc.NSUInteger, cookies, "count", .{});
    d.pending = 1; // until every delete is asked
    for (0..n) |i| {
        const obj = objc.msg(objc.Object, cookies, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const k = readCookie(obj);
        if (!std.mem.eql(u8, k.name, name) or !std.ascii.eqlIgnoreCase(std.mem.trimStart(u8, k.domain, "."), domain) or !std.mem.eql(u8, k.path, path)) continue;
        d.pending += 1;
        var block = objc.Block(Op, &.{}).init(op, changed);
        objc.msg(void, store(), "deleteCookie:completionHandler:", .{ obj, &block });
    }
    changed(op);
}

pub fn clearCookies(page: *Page, cb: types.DoneCallback) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const op = Op.create(page, .{ .done = .{ .cb = cb, .pending = 1 } }) orelse return cb.func(cb.ctx, "out of memory");
    const ds = objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "defaultDataStore", .{});
    const kinds = objc.msg(objc.Object, objc.class("NSSet"), "setWithObject:", .{objc.nsString("WKWebsiteDataTypeCookies")});
    const since = objc.msg(objc.Object, objc.class("NSDate"), "distantPast", .{});
    var block = objc.Block(Op, &.{}).init(op, changed);
    objc.msg(void, ds, "removeDataOfTypes:modifiedSince:completionHandler:", .{ kinds, since, &block });
}
