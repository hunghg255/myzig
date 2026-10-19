//! What a WebKitGTK page tells the app: navigations, titles, windows it
//! opens, permissions it asks for, and downloads, saved where the app's
//! listener says (the Downloads directory by default).
const std = @import("std");
const gtk = @import("gtk.zig");
const webkit = @import("webkit.zig");
const types = @import("../page_types.zig");
const core_mod = @import("../page_core.zig");
const desktop = @import("desktop.zig");
const extra = @import("page_extra.zig");
const Page = @import("page.zig").Page;

var downloads_hooked = false;

pub fn register(page: *Page) void {
    const wv = page.webview;
    gtk.connect(wv, "load-changed", @ptrCast(&loadChanged), page);
    gtk.connect(wv, "load-failed", @ptrCast(&loadFailed), page);
    gtk.connect(wv, "notify::title", @ptrCast(&titleChanged), page);
    gtk.connect(wv, "decide-policy", @ptrCast(&decidePolicy), page);
    gtk.connect(wv, "permission-request", @ptrCast(&permissionRequest), page);
    gtk.connect(wv, "create", @ptrCast(&create), page);
    if (!downloads_hooked) {
        downloads_hooked = true;
        gtk.connect(webkit.api.webkit_web_context_get_default(), "download-started", @ptrCast(&downloadStarted), null);
    }
}

fn loadChanged(_: *anyopaque, event: c_int, data: ?*anyopaque) callconv(.c) void {
    const page = Page.alive(data) orelse return;
    const url = page.url(page.gpa) catch return;
    defer page.gpa.free(url);
    switch (event) {
        0 => { // WEBKIT_LOAD_STARTED
            page.navigated();
            page.core.fire(.{ .load_started = url });
        },
        2 => page.core.fire(.{ .committed = url }), // WEBKIT_LOAD_COMMITTED
        3 => page.core.fire(.{ .load_finished = url }), // WEBKIT_LOAD_FINISHED
        else => {},
    }
}

/// GError: a domain, a code, then the message.
const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };

fn loadFailed(_: *anyopaque, _: c_int, uri: ?[*:0]const u8, err: ?*const GError, data: ?*anyopaque) callconv(.c) c_int {
    const page = Page.alive(data) orelse return 0;
    const e = err orelse return 0;
    // Canceled loads (302) and navigations stopped by policy (102) are no failures.
    if (e.code == 302 or e.code == 102) return 0;
    page.core.fire(.{ .load_failed = .{ .url = webkit.span(uri), .code = e.code, .description = webkit.span(e.message) } });
    return 0;
}

fn titleChanged(_: *anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = Page.alive(data) orelse return;
    const t = page.title(page.gpa) catch return;
    defer page.gpa.free(t);
    if (t.len == 0) return;
    page.core.fire(.{ .title_changed = t });
}

fn decidePolicy(_: *anyopaque, decision: *anyopaque, kind: c_int, data: ?*anyopaque) callconv(.c) c_int {
    const page = Page.alive(data) orelse return 0;
    const k = &webkit.api;
    if (kind != 0 and kind != 1) return 0; // a response: WebKit's choice
    const action = k.webkit_navigation_policy_decision_get_navigation_action(decision);
    const url = webkit.span(k.webkit_uri_request_get_uri(k.webkit_navigation_action_get_request(action)));
    if (kind == 1) { // WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION
        k.webkit_policy_decision_ignore(decision);
        page.core.newWindow(url);
        return 1;
    }
    if (page.core.willNavigate(url, k.webkit_navigation_action_is_user_gesture(action) != 0))
        k.webkit_policy_decision_use(decision)
    else
        k.webkit_policy_decision_ignore(decision);
    return 1;
}

fn permissionRequest(wv: *anyopaque, req: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const page = Page.alive(data) orelse return 0;
    const k = &webkit.api;
    var kinds: [2]types.Permission = undefined;
    var n: usize = 0;
    if (k.g_type_check_instance_is_a(req, k.webkit_user_media_permission_request_get_type()) != 0) {
        if (k.webkit_user_media_permission_is_for_video_device(req) != 0) {
            kinds[n] = .camera;
            n += 1;
        }
        if (k.webkit_user_media_permission_is_for_audio_device(req) != 0) {
            kinds[n] = .microphone;
            n += 1;
        }
    } else if (k.g_type_check_instance_is_a(req, k.webkit_geolocation_permission_request_get_type()) != 0) {
        kinds[0] = .geolocation;
        n = 1;
    } else if (k.g_type_check_instance_is_a(req, k.webkit_notification_permission_request_get_type()) != 0) {
        kinds[0] = .notifications;
        n = 1;
    }
    if (n == 0) return 0; // WebKit's default answer
    var buf: [256]u8 = undefined;
    const origin = core_mod.originOf(&buf, webkit.span(k.webkit_web_view_get_uri(wv)));
    if (page.core.permission(kinds[0..n], origin)) k.webkit_permission_request_allow(req) else k.webkit_permission_request_deny(req);
    return 1;
}

// Downloads.

fn downloadStarted(_: *anyopaque, download: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    const k = &webkit.api;
    const page = Page.of(k.webkit_download_get_web_view(download)) orelse return;
    const url = webkit.span(k.webkit_uri_request_get_uri(k.webkit_download_get_request(download)));
    const op = extra.Op.create(page, .{ .download = .{ .url = url, .path = "" } }) orelse return;
    gtk.connect(download, "decide-destination", @ptrCast(&decideDestination), op);
    gtk.connect(download, "received-data", @ptrCast(&receivedData), op);
    gtk.connect(download, "failed", @ptrCast(&downloadFailed), op);
    gtk.connect(download, "finished", @ptrCast(&downloadFinished), op);
}

fn decideDestination(download: *anyopaque, suggested: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) c_int {
    const op: *extra.Op = @ptrCast(@alignCast(data));
    const page = op.page orelse {
        webkit.api.webkit_download_cancel(download);
        return 1;
    };
    const gpa = page.gpa;
    const d = &op.data.download;
    const dir = desktop.path(gpa, .downloads, page.window.app.options.name) catch null;
    defer if (dir) |x| gpa.free(x);
    const path = page.core.startDownload(page.window.app.io, dir, d.url, core_mod.safeName(webkit.span(suggested))) orelse {
        webkit.api.webkit_download_cancel(download);
        return 1;
    };
    defer gpa.free(path);
    op.setPath(path);
    var buf: [4096]u8 = undefined;
    const uri = webkit.printZ(&buf, "file://{s}", .{path}) orelse {
        webkit.api.webkit_download_cancel(download);
        return 1;
    };
    webkit.api.webkit_download_set_allow_overwrite(download, 1);
    webkit.api.webkit_download_set_destination(download, uri);
    return 1;
}

fn receivedData(download: *anyopaque, _: u64, data: ?*anyopaque) callconv(.c) void {
    const op: *extra.Op = @ptrCast(@alignCast(data));
    const page = op.page orelse return;
    const k = &webkit.api;
    const total = if (k.webkit_download_get_response(download)) |r| k.webkit_uri_response_get_content_length(r) else 0;
    page.core.fire(.{ .download_progress = .{ .url = op.data.download.url, .received = k.webkit_download_get_received_data_length(download), .total = total } });
}

fn downloadFailed(_: *anyopaque, err: ?*const GError, data: ?*anyopaque) callconv(.c) void {
    const op: *extra.Op = @ptrCast(@alignCast(data));
    op.data.download.failed = true;
    const e = err orelse return;
    op.setError(webkit.span(e.message));
}

/// After "failed" too.
fn downloadFinished(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const op: *extra.Op = @ptrCast(@alignCast(data));
    const d = op.data.download;
    if (op.page) |page| if (d.path.len > 0) {
        page.core.fire(.{ .download_done = .{ .url = d.url, .path = d.path, .err = if (d.failed) (if (d.err.len > 0) d.err else "download failed") else null } });
    };
    op.finish();
}

/// `window.open`: WebKit asks for a web view, which the page does not get
/// (a related view would share the opener's messages); the app hears of
/// the window instead.
fn create(_: *anyopaque, action: *anyopaque, data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const page = Page.alive(data) orelse return null;
    const k = &webkit.api;
    page.core.newWindow(webkit.span(k.webkit_uri_request_get_uri(k.webkit_navigation_action_get_request(action))));
    return null;
}
