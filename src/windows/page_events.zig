//! What a WebView2 page tells the app: navigations, titles, windows it
//! opens, permissions it asks for, and downloads, saved where the app's
//! listener says (the Downloads directory by default) without WebView2's
//! download UI.
const std = @import("std");
const com = @import("com.zig");
const types = @import("../page_types.zig");
const core_mod = @import("../page_core.zig");
const serve = @import("../page_serve.zig");
const desktop = @import("desktop.zig");
const scheme = @import("page_scheme.zig");
const extra = @import("page_extra.zig");
const Page = @import("page.zig").Page;
const ipc = @import("../ipc.zig");

const wv_add_navigation_starting = 7;
const wv_add_content_loading = 9;
const wv_add_navigation_completed = 15;
const wv_add_permission_requested = 23;
const wv_add_new_window_requested = 44;
const wv_add_title_changed = 46;
const wv4_add_download_starting = 75;
const nav_get_uri = 3;
const nav_get_user = 4;
const nav_put_cancel = 8;
const done_get_success = 3;
const done_get_status = 4;
const newwin_get_uri = 3;
const newwin_put_handled = 6;
const perm_get_uri = 3;
const perm_get_kind = 4;
const perm_put_state = 7;
const dl_get_operation = 3;
const dl_put_cancel = 5;
const dl_get_path = 6;
const dl_put_path = 7;
const dl_put_handled = 9;
const op_add_bytes = 3;
const op_remove_bytes = 4;
const op_add_state = 7;
const op_remove_state = 8;
const op_get_uri = 9;
const op_get_total = 12;
const op_get_received = 13;
const op_get_state = 16;
const op_get_interrupt = 17;
const iid_webview4 = com.GUID.parse("20d02d59-6df2-42dc-bd06-f98a694b1302");

pub fn register(page: *Page) void {
    const wv = page.webview.?;
    var token: i64 = 0;
    const list = .{
        .{ wv_add_navigation_starting, navigationStarting },
        .{ wv_add_content_loading, contentLoading },
        .{ wv_add_navigation_completed, navigationCompleted },
        .{ wv_add_title_changed, titleChanged },
        .{ wv_add_new_window_requested, newWindowRequested },
        .{ wv_add_permission_requested, permissionRequested },
    };
    inline for (list) |e| _ = com.withHandler(page, e[1], Page.addEvent, .{ wv, @as(usize, e[0]), &token });
    if (com.query(wv, &iid_webview4)) |wv4| {
        _ = com.withHandler(page, downloadStarting, Page.addEvent, .{ wv4, @as(usize, wv4_add_download_starting), &token });
        com.release(wv4);
    }
}

const pageOf = Page.alive;

/// A URI property of an event's arguments, in the app's form, owned.
fn uriOf(page: *Page, obj: com.Object, index: usize) ?[]u8 {
    var p: ?[*:0]u16 = null;
    if (com.failed(com.call(obj, index, .{&p}))) return null;
    const raw = com.takeString(page.gpa, p) catch return null;
    defer page.gpa.free(raw);
    var buf: [4096]u8 = undefined;
    return page.gpa.dupe(u8, serve.appUrl(&buf, page.options, raw)) catch null;
}

fn navigationStarting(ctx: ?*anyopaque, _: usize, args_ptr: usize) void {
    const page = pageOf(ctx) orelse return;
    startNavigation(page, @ptrFromInt(args_ptr));
}

fn startNavigation(page: *Page, args: com.Object) void {
    const gpa = page.gpa;
    const url = uriOf(page, args, nav_get_uri) orelse return;
    defer gpa.free(url);
    var user: i32 = 0;
    _ = com.call(args, nav_get_user, .{&user});
    const window = page.window;
    const app = window.app;
    const allow = page.core.willNavigate(url, user != 0);
    if (!ipc.stillOpen(app, window, page)) return;
    if (!allow) {
        _ = com.call(args, nav_put_cancel, .{@as(i32, 1)});
        return;
    }
    page.loading = true;
    page.navigated();
    if (!ipc.stillOpen(app, window, page)) return;
    page.core.fire(.{ .load_started = url });
}

test "page regression: a navigation listener may close its window" {
    const t = std.testing;
    const Fixture = @import("page_test_support.zig").Fixture;
    const Window = @import("window.zig").Window;
    const Args = struct {
        vtbl: [*]const *const anyopaque = &table,
        canceled: bool = false,
        const table = [_]*const anyopaque{
            @ptrCast(&uri),    @ptrCast(&uri),    @ptrCast(&uri),    @ptrCast(&uri),    @ptrCast(&user),
            @ptrCast(&cancel), @ptrCast(&cancel), @ptrCast(&cancel), @ptrCast(&cancel),
        };
        fn uri(_: com.Object, out: *?[*:0]u16) callconv(.winapi) com.HRESULT {
            out.* = com.coString("https://example.org/");
            return if (out.* != null) com.S_OK else com.E_FAIL;
        }
        fn user(_: com.Object, out: *i32) callconv(.winapi) com.HRESULT {
            out.* = 1;
            return com.S_OK;
        }
        fn cancel(ctx: com.Object, value: i32) callconv(.winapi) com.HRESULT {
            const a: *@This() = @ptrCast(@alignCast(ctx));
            a.canceled = value != 0;
            return com.S_OK;
        }
    };
    const Probe = struct {
        calls: usize = 0,
        cancel: bool,
        close_started: bool = false,
        fn event(p: *@This(), win: *Window, e: types.PageEvent) void {
            p.calls += 1;
            if (e == .will_navigate) {
                e.will_navigate.cancel = p.cancel;
                if (!p.close_started) win.close();
            } else if (e == .load_started and p.close_started) win.close();
        }
    };
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    for ([_]bool{ false, true }) |cancel| {
        var probe: Probe = .{ .cancel = cancel };
        const page = try f.open(.{ .on_event = .of(&probe, Probe.event) });
        var args: Args = .{};
        startNavigation(page, &args);
        try t.expectEqual(@as(usize, 0), f.app.windows.items.len);
        try t.expectEqual(@as(usize, 1), probe.calls);
        try t.expect(!args.canceled);
    }
    // Closing from load_started must also leave the deferred URL free safe.
    var probe: Probe = .{ .cancel = false, .close_started = true };
    const page = try f.open(.{ .on_event = .of(&probe, Probe.event) });
    var args: Args = .{};
    startNavigation(page, &args);
    try t.expectEqual(@as(usize, 0), f.app.windows.items.len);
    try t.expectEqual(@as(usize, 2), probe.calls);
}

fn contentLoading(ctx: ?*anyopaque, _: usize, _: usize) void {
    const page = pageOf(ctx) orelse return;
    const gpa = page.gpa;
    const url = page.url(gpa) catch return;
    defer gpa.free(url);
    page.core.fire(.{ .committed = url });
}

fn navigationCompleted(ctx: ?*anyopaque, _: usize, args_ptr: usize) void {
    const page = pageOf(ctx) orelse return;
    const gpa = page.gpa;
    const args: com.Object = @ptrFromInt(args_ptr);
    page.loading = false;
    var ok: i32 = 0;
    _ = com.call(args, done_get_success, .{&ok});
    const url = page.url(gpa) catch return;
    defer gpa.free(url);
    if (ok != 0) return page.core.fire(.{ .load_finished = url });
    var status: i32 = 0;
    _ = com.call(args, done_get_status, .{&status});
    if (status == 13) return; // canceled: another navigation
    page.core.fire(.{ .load_failed = .{ .url = url, .code = status, .description = "navigation failed (COREWEBVIEW2_WEB_ERROR_STATUS)" } });
}

fn titleChanged(ctx: ?*anyopaque, _: usize, _: usize) void {
    const page = pageOf(ctx) orelse return;
    const gpa = page.gpa;
    const t = page.title(gpa) catch return;
    defer gpa.free(t);
    page.core.fire(.{ .title_changed = t });
}

fn newWindowRequested(ctx: ?*anyopaque, _: usize, args_ptr: usize) void {
    const page = pageOf(ctx) orelse return;
    const gpa = page.gpa;
    const args: com.Object = @ptrFromInt(args_ptr);
    // WebView2 must not open windows of its own.
    _ = com.call(args, newwin_put_handled, .{@as(i32, 1)});
    const url = uriOf(page, args, newwin_get_uri) orelse return;
    defer gpa.free(url);
    page.core.newWindow(url);
}

fn permissionRequested(ctx: ?*anyopaque, _: usize, args_ptr: usize) void {
    const page = pageOf(ctx) orelse return;
    const gpa = page.gpa;
    const args: com.Object = @ptrFromInt(args_ptr);
    var kind: i32 = 0;
    _ = com.call(args, perm_get_kind, .{&kind});
    const k: types.Permission = switch (kind) {
        1 => .microphone,
        2 => .camera,
        3 => .geolocation,
        4 => .notifications,
        else => return, // WebView2 asks the user about the others
    };
    const url = uriOf(page, args, perm_get_uri) orelse return;
    defer gpa.free(url);
    var buf: [core_mod.max_origin]u8 = undefined;
    const allow = page.core.permission(&.{k}, core_mod.originOf(&buf, url));
    _ = com.call(args, perm_put_state, .{@as(i32, if (allow) 1 else 2)});
}

fn downloadStarting(ctx: ?*anyopaque, _: usize, args_ptr: usize) void {
    const page = pageOf(ctx) orelse return;
    const window = page.window;
    const app = window.app;
    const gpa = page.gpa;
    const args: com.Object = @ptrFromInt(args_ptr);
    var op: ?com.Object = null;
    if (com.failed(com.call(args, dl_get_operation, .{&op}))) return;
    const operation = op orelse return;
    defer com.release(operation);
    var p: ?[*:0]u16 = null;
    _ = com.call(operation, op_get_uri, .{&p});
    const raw = com.takeString(gpa, p) catch return;
    defer gpa.free(raw);
    p = null;
    _ = com.call(args, dl_get_path, .{&p});
    const suggested = com.takeString(gpa, p) catch return;
    defer gpa.free(suggested);
    _ = com.call(args, dl_put_handled, .{@as(i32, 1)}); // no download UI of WebView2
    var buf: [4096]u8 = undefined;
    const url = serve.appUrl(&buf, page.options, raw);
    if (url.ptr != raw.ptr) {
        // WebView2 cannot download what the app serves: the app serves it again.
        _ = com.call(args, dl_put_cancel, .{@as(i32, 1)});
        return scheme.download(page, url, core_mod.safeName(suggested));
    }
    const dir = desktop.path(gpa, .downloads, page.window.app.options.name) catch null;
    defer if (dir) |d| gpa.free(d);
    const path = page.core.startDownload(page.window.app.io, dir, url, core_mod.safeName(suggested)) orelse {
        _ = com.call(args, dl_put_cancel, .{@as(i32, 1)});
        return;
    };
    defer gpa.free(path);
    if (!ipc.stillOpen(app, window, page)) {
        _ = com.call(args, dl_put_cancel, .{@as(i32, 1)});
        return;
    }
    std.Io.Dir.cwd().deleteFile(page.window.app.io, path) catch {}; // a file there is replaced
    const wpath = com.wide(gpa, path) catch return;
    defer gpa.free(wpath);
    _ = com.call(args, dl_put_path, .{wpath.ptr});
    const d = extra.Op.create(page, .{ .download = .{ .url = url, .path = path } }) orelse return;
    com.addRef(operation);
    d.data.download.operation = operation;
    _ = com.withHandler(d, bytesReceived, Page.addEvent, .{ operation, @as(usize, op_add_bytes), &d.data.download.tokens[0] });
    _ = com.withHandler(d, stateChanged, Page.addEvent, .{ operation, @as(usize, op_add_state), &d.data.download.tokens[1] });
}

fn bytesReceived(ctx: ?*anyopaque, sender: usize, _: usize) void {
    const d: *extra.Op = @ptrCast(@alignCast(ctx));
    const page = d.page orelse return;
    const op: com.Object = @ptrFromInt(sender);
    var received: i64 = 0;
    var total: i64 = 0;
    _ = com.call(op, op_get_received, .{&received});
    _ = com.call(op, op_get_total, .{&total});
    page.core.fire(.{ .download_progress = .{ .url = d.data.download.url, .received = @intCast(@max(received, 0)), .total = @intCast(@max(total, 0)) } });
}

fn stateChanged(ctx: ?*anyopaque, sender: usize, _: usize) void {
    const d: *extra.Op = @ptrCast(@alignCast(ctx));
    const op: com.Object = @ptrFromInt(sender);
    var state: i32 = 0;
    _ = com.call(op, op_get_state, .{&state});
    if (state == 0) return; // in progress
    var why: [64]u8 = undefined;
    var err: ?[]const u8 = null;
    if (state == 1) {
        var reason: i32 = 0;
        _ = com.call(op, op_get_interrupt, .{&reason});
        err = std.fmt.bufPrint(&why, "download interrupted (reason {d})", .{reason}) catch "download interrupted";
    }
    const dl = &d.data.download;
    _ = com.call(op, op_remove_bytes, .{dl.tokens[0]});
    _ = com.call(op, op_remove_state, .{dl.tokens[1]});
    if (d.page) |page| page.core.fire(.{ .download_done = .{ .url = dl.url, .path = dl.path, .err = err } });
    d.finish();
}
