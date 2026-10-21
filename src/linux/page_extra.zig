//! A WebKitGTK page's asynchronous work: printing to PDF (GTK's "Print to
//! File" printer, which writes a temporary file), the cookies of the web
//! context (libsoup 3's, with webkit2gtk-4.1), and downloads under way.
//! Each is an `Op` the page keeps until WebKit answers; a page that closes
//! first fails them, and the answers that come later free them.
const std = @import("std");
const gtk = @import("gtk.zig");
const webkit = @import("webkit.zig");
const types = @import("../page_types.zig");
const desktop = @import("desktop.zig");
const Page = @import("page.zig").Page;

pub const Op = struct {
    /// Null once the page closed.
    page: ?*Page,
    gpa: std.mem.Allocator,
    data: Data,

    pub const Data = union(enum) {
        download: struct { url: []const u8, path: []const u8, failed: bool = false, err: []const u8 = "" },
        pdf: struct { cb: types.PdfCallback, path: [:0]const u8 = "", web: ?*anyopaque = null, backgrounds: c_int = 0, err: []const u8 = "" },
        cookies: struct { cb: types.CookiesCallback, all: bool = true },
        done: struct { cb: types.DoneCallback, cookie: ?*anyopaque = null, delete: bool = false, key: []const u8 = "", list: ?*webkit.List = null, pending: u32 = 0, failed: bool = false },
    };

    pub fn create(page: *Page, data: Data) ?*Op {
        const gpa = page.gpa;
        // Ownership of caller-provided data transfers only on success.
        page.ops.ensureUnusedCapacity(gpa, 1) catch return null;
        const op = gpa.create(Op) catch return null;
        op.* = .{ .page = page, .gpa = gpa, .data = data };
        if (data == .download) {
            op.data.download.url = gpa.dupe(u8, data.download.url) catch {
                gpa.destroy(op);
                return null;
            };
            op.data.download.path = "";
        }
        page.ops.appendAssumeCapacity(op);
        return op;
    }

    pub fn setPath(op: *Op, path: []const u8) void {
        const d = &op.data.download;
        if (d.path.len > 0) op.gpa.free(d.path);
        d.path = op.gpa.dupe(u8, path) catch "";
    }

    pub fn setError(op: *Op, msg: []const u8) void {
        switch (op.data) {
            .download => |*d| {
                if (d.err.len > 0) op.gpa.free(d.err);
                d.err = op.gpa.dupe(u8, msg) catch "";
            },
            .pdf => |*p| {
                if (p.err.len > 0) op.gpa.free(p.err);
                p.err = op.gpa.dupe(u8, msg) catch "";
            },
            else => {},
        }
    }

    pub fn finish(op: *Op) void {
        if (op.page) |page| for (page.ops.items, 0..) |o, i| if (o == op) {
            _ = page.ops.swapRemove(i);
            break;
        };
        const gpa = op.gpa;
        switch (op.data) {
            .download => |d| {
                gpa.free(d.url);
                if (d.path.len > 0) gpa.free(d.path);
                if (d.err.len > 0) gpa.free(d.err);
            },
            .pdf => |p| {
                if (p.path.len > 0) gpa.free(p.path);
                if (p.err.len > 0) gpa.free(p.err);
            },
            .done => |d| {
                if (d.cookie) |c| webkit.newer.soup_cookie_free.?(c);
                if (d.key.len > 0) gpa.free(d.key);
                freeList(d.list);
            },
            .cookies => {},
        }
        gpa.destroy(op);
    }
};

/// The page closes: its work fails now, and WebKit's late answers free it.
pub fn abandon(page: *Page) void {
    for (page.ops.items) |op| {
        op.page = null;
        switch (op.data) {
            .pdf => |p| p.cb.func(p.cb.ctx, null, "the page closed"),
            .cookies => |c| c.cb.func(c.cb.ctx, null, "the page closed"),
            .done => |d| d.cb.func(d.cb.ctx, "the page closed"),
            .download => {},
        }
    }
    page.ops.clearRetainingCapacity();
}

// PDF.

pub fn printToPdf(page: *Page, o: types.PdfOptions, cb: types.PdfCallback) void {
    const k = &webkit.api;
    // WebKitGTK crashes printing a web view that never loaded anything.
    if (k.webkit_web_view_get_uri(page.webview) == null) return cb.func(cb.ctx, null, "the page has loaded nothing");
    const gpa = page.gpa;
    const app = page.window.app;
    const tmp = desktop.path(gpa, .temp, app.options.name) catch return cb.func(cb.ctx, null, "no temporary directory");
    defer gpa.free(tmp);
    var raw: [8]u8 = undefined;
    app.io.random(&raw);
    var name: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&name, "/myzig-{s}.pdf", .{std.fmt.bytesToHex(raw, .lower)}) catch unreachable;
    const full = std.mem.concat(gpa, u8, &.{ tmp, path, "\x00" }) catch return cb.func(cb.ctx, null, "out of memory");
    const op = Op.create(page, .{ .pdf = .{ .cb = cb, .path = full[0 .. full.len - 1 :0] } }) orelse {
        gpa.free(full);
        return cb.func(cb.ctx, null, "out of memory");
    };
    var ubuf: [4096]u8 = undefined;
    const uri = webkit.printZ(&ubuf, "file://{s}", .{full[0 .. full.len - 1]}) orelse return failPdf(op, "path too long");
    const settings = k.gtk_print_settings_new();
    k.gtk_print_settings_set(settings, "printer", "Print to File");
    k.gtk_print_settings_set(settings, "output-file-format", "pdf");
    k.gtk_print_settings_set(settings, "output-uri", uri);
    const setup = k.gtk_page_setup_new();
    const inch = 2; // GTK_UNIT_INCH
    const paper = k.gtk_paper_size_new_custom("myzig", "myzig", o.width, o.height, inch);
    k.gtk_page_setup_set_paper_size(setup, paper);
    k.gtk_paper_size_free(paper);
    if (o.landscape) k.gtk_page_setup_set_orientation(setup, 1);
    k.gtk_page_setup_set_top_margin(setup, o.margin_top, inch);
    k.gtk_page_setup_set_right_margin(setup, o.margin_right, inch);
    k.gtk_page_setup_set_bottom_margin(setup, o.margin_bottom, inch);
    k.gtk_page_setup_set_left_margin(setup, o.margin_left, inch);
    const web = k.webkit_web_view_get_settings(page.webview);
    op.data.pdf.web = web;
    op.data.pdf.backgrounds = k.webkit_settings_get_print_backgrounds(web);
    k.webkit_settings_set_print_backgrounds(web, @intFromBool(o.background));
    const print_op = k.webkit_print_operation_new(page.webview);
    k.webkit_print_operation_set_print_settings(print_op, settings);
    k.webkit_print_operation_set_page_setup(print_op, setup);
    gtk.api.g_object_unref(settings);
    gtk.api.g_object_unref(setup);
    gtk.connect(print_op, "failed", @ptrCast(&printFailed), op);
    gtk.connect(print_op, "finished", @ptrCast(&printFinished), op);
    k.webkit_print_operation_print(print_op);
}

fn failPdf(op: *Op, why: []const u8) void {
    const cb = op.data.pdf.cb;
    const alive = op.page != null;
    op.finish();
    if (alive) cb.func(cb.ctx, null, why);
}

const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };

fn printFailed(_: *anyopaque, err: ?*const GError, data: ?*anyopaque) callconv(.c) void {
    const op: *Op = @ptrCast(@alignCast(data));
    op.setError(if (err) |e| webkit.span(e.message) else "printing failed");
}

/// After "failed" too.
fn printFinished(print_op: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const op: *Op = @ptrCast(@alignCast(data));
    defer gtk.api.g_object_unref(print_op);
    const p = op.data.pdf;
    if (op.page) |page| if (p.web) |web| {
        webkit.api.webkit_settings_set_print_backgrounds(web, p.backgrounds);
        const io = page.window.app.io;
        const pdf = std.Io.Dir.cwd().readFileAlloc(io, p.path, op.gpa, .limited(1 << 30)) catch null;
        std.Io.Dir.cwd().deleteFile(io, p.path) catch {};
        if (pdf) |bytes| {
            // `finish` frees the op: not its allocator's copy.
            const gpa = op.gpa;
            defer gpa.free(bytes);
            if (p.err.len == 0 and bytes.len > 0) {
                const cb = p.cb;
                op.finish();
                return cb.func(cb.ctx, bytes, null);
            }
        }
    };
    failPdf(op, if (p.err.len > 0) "printing to PDF failed" else "printing to PDF produced no file");
}

// Cookies.

fn manager() *anyopaque {
    return webkit.api.webkit_web_context_get_cookie_manager(webkit.api.webkit_web_context_get_default());
}

const unsupported = "cookies need webkit2gtk-4.1 (libsoup 3)";

pub fn listCookies(page: *Page, url: ?[]const u8, cb: types.CookiesCallback) void {
    const n = &webkit.newer;
    const op = Op.create(page, .{ .cookies = .{ .cb = cb, .all = url == null } }) orelse return cb.func(cb.ctx, null, "out of memory");
    if (n.soup_cookie_get_name == null) return failList(op, unsupported);
    if (url) |u| {
        const get = n.webkit_cookie_manager_get_cookies orelse return failList(op, unsupported);
        const z = webkit.dupeZ(page.gpa, u) catch return failList(op, "out of memory");
        defer page.gpa.free(z);
        get(manager(), z, null, listed, op);
    } else {
        const all = n.webkit_cookie_manager_get_all_cookies orelse return failList(op, "listing every cookie needs WebKitGTK 2.42");
        all(manager(), null, listed, op);
    }
}

fn failList(op: *Op, why: []const u8) void {
    const cb = op.data.cookies.cb;
    const alive = op.page != null;
    op.finish();
    if (alive) cb.func(cb.ctx, null, why);
}

fn listed(source: ?*anyopaque, res: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const op: *Op = @ptrCast(@alignCast(data));
    const n = &webkit.newer;
    const finish = (if (op.data.cookies.all) n.webkit_cookie_manager_get_all_cookies_finish else n.webkit_cookie_manager_get_cookies_finish) orelse return op.finish();
    const list = finish(source.?, res, null);
    var arena: std.heap.ArenaAllocator = .init(op.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(types.Cookie) = .empty;
    var it = list;
    while (it) |node| : (it = node.next) {
        const c = node.data orelse continue;
        const expires: ?i64 = if (n.soup_cookie_get_expires.?(c)) |dt| n.g_date_time_to_unix.?(dt) else null;
        out.append(a, .{
            .name = a.dupe(u8, std.mem.span(n.soup_cookie_get_name.?(c))) catch continue,
            .value = a.dupe(u8, std.mem.span(n.soup_cookie_get_value.?(c))) catch continue,
            .domain = a.dupe(u8, std.mem.span(n.soup_cookie_get_domain.?(c))) catch continue,
            .path = a.dupe(u8, std.mem.span(n.soup_cookie_get_path.?(c))) catch continue,
            .expires = expires,
            .secure = n.soup_cookie_get_secure.?(c) != 0,
            .http_only = n.soup_cookie_get_http_only.?(c) != 0,
            .same_site = switch (n.soup_cookie_get_same_site_policy.?(c)) {
                0 => .none,
                2 => .strict,
                else => .lax,
            },
        }) catch {};
        n.soup_cookie_free.?(c);
    }
    webkit.api.g_list_free(list);
    const cb = op.data.cookies.cb;
    const alive = op.page != null;
    op.finish();
    if (alive) cb.func(cb.ctx, out.items, null);
}

fn newCookie(c: types.Cookie) ?*anyopaque {
    const n = &webkit.newer;
    const make = n.soup_cookie_new orelse return null;
    var b: [4][1024]u8 = undefined;
    const name = webkit.printZ(&b[0], "{s}", .{c.name}) orelse return null;
    const value = webkit.printZ(&b[1], "{s}", .{c.value}) orelse return null;
    const domain = webkit.printZ(&b[2], "{s}", .{c.domain}) orelse return null;
    const path = webkit.printZ(&b[3], "{s}", .{if (c.path.len == 0) "/" else c.path}) orelse return null;
    const cookie = make(name, value, domain, path, -1);
    n.soup_cookie_set_secure.?(cookie, @intFromBool(c.secure));
    n.soup_cookie_set_http_only.?(cookie, @intFromBool(c.http_only));
    n.soup_cookie_set_same_site_policy.?(cookie, switch (c.same_site) {
        .none => 0,
        .lax => 1,
        .strict => 2,
    });
    if (c.expires) |e| if (n.g_date_time_new_from_unix_utc.?(e)) |dt| {
        n.soup_cookie_set_expires.?(cookie, dt);
        n.g_date_time_unref.?(dt);
    };
    return cookie;
}

pub fn setCookie(page: *Page, c: types.Cookie, cb: types.DoneCallback) void {
    const add = webkit.newer.webkit_cookie_manager_add_cookie orelse return cb.func(cb.ctx, unsupported);
    const cookie = newCookie(c) orelse return cb.func(cb.ctx, "a cookie libsoup does not take");
    const op = Op.create(page, .{ .done = .{ .cb = cb, .cookie = cookie } }) orelse return cb.func(cb.ctx, "out of memory");
    add(manager(), cookie, null, changed, op);
}

/// Deletes the cookies of a name, domain and path: those WebKit has, which
/// it deletes as they are (a cookie made to match them is not enough).
pub fn deleteCookie(page: *Page, name: []const u8, domain: []const u8, path: []const u8, cb: types.DoneCallback) void {
    const n = &webkit.newer;
    if (n.webkit_cookie_manager_delete_cookie == null or n.soup_cookie_get_name == null) return cb.func(cb.ctx, unsupported);
    const all = n.webkit_cookie_manager_get_all_cookies orelse return cb.func(cb.ctx, "deleting cookies needs WebKitGTK 2.42");
    const key = std.mem.concat(page.gpa, u8, &.{ name, "\x00", std.mem.trimStart(u8, domain, "."), "\x00", if (path.len == 0) "/" else path }) catch return cb.func(cb.ctx, "out of memory");
    const op = Op.create(page, .{ .done = .{ .cb = cb, .delete = true, .key = key } }) orelse {
        page.gpa.free(key);
        return cb.func(cb.ctx, "out of memory");
    };
    all(manager(), null, toDelete, op);
}

fn toDelete(source: ?*anyopaque, res: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const op: *Op = @ptrCast(@alignCast(data));
    const n = &webkit.newer;
    const d = &op.data.done;
    d.list = n.webkit_cookie_manager_get_all_cookies_finish.?(source.?, res, null);
    var parts = std.mem.splitScalar(u8, d.key, 0);
    const name = parts.next().?;
    const domain = parts.next().?;
    const path = parts.next().?;
    var it = d.list;
    while (it) |node| : (it = node.next) {
        const c = node.data orelse continue;
        if (!std.mem.eql(u8, std.mem.span(n.soup_cookie_get_name.?(c)), name)) continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trimStart(u8, std.mem.span(n.soup_cookie_get_domain.?(c)), "."), domain)) continue;
        if (!std.mem.eql(u8, std.mem.span(n.soup_cookie_get_path.?(c)), path)) continue;
        d.pending += 1;
        n.webkit_cookie_manager_delete_cookie.?(manager(), c, null, changed, op);
    }
    if (d.pending == 0) done(op);
}

fn changed(source: ?*anyopaque, res: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const op: *Op = @ptrCast(@alignCast(data));
    const n = &webkit.newer;
    const d = &op.data.done;
    const finish = if (d.delete) n.webkit_cookie_manager_delete_cookie_finish.? else n.webkit_cookie_manager_add_cookie_finish.?;
    if (finish(source.?, res, null) == 0) d.failed = true;
    if (d.pending > 0) d.pending -= 1;
    if (d.pending == 0) done(op);
}

fn done(op: *Op) void {
    const cb = op.data.done.cb;
    const failed = op.data.done.failed;
    const alive = op.page != null;
    op.finish();
    if (alive) cb.func(cb.ctx, if (failed) "WebKit refused the change" else null);
}

fn freeList(list: ?*webkit.List) void {
    const n = &webkit.newer;
    var it = list;
    while (it) |node| : (it = node.next) if (node.data) |c| n.soup_cookie_free.?(c);
    if (list != null) webkit.api.g_list_free(list);
}

pub fn clearCookies(page: *Page, cb: types.DoneCallback) void {
    const k = &webkit.api;
    const op = Op.create(page, .{ .done = .{ .cb = cb } }) orelse return cb.func(cb.ctx, "out of memory");
    const m = k.webkit_web_context_get_website_data_manager(k.webkit_web_context_get_default());
    k.webkit_website_data_manager_clear(m, 1 << 8, 0, null, cleared, op); // WEBKIT_WEBSITE_DATA_COOKIES
}

fn cleared(source: ?*anyopaque, res: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const op: *Op = @ptrCast(@alignCast(data));
    const ok = webkit.api.webkit_website_data_manager_clear_finish(source.?, res, null) != 0;
    const cb = op.data.done.cb;
    const alive = op.page != null;
    op.finish();
    if (alive) cb.func(cb.ctx, if (ok) null else "WebKit could not clear the cookies");
}
