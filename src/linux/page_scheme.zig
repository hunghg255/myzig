//! The app's schemes in WebKitGTK: `myzig://` and those of
//! `PageOptions.schemes`, registered once for the web context, their
//! requests answered by the app as `SchemeRequest`s, whole, with the
//! status and headers it gives (WebKitGTK 2.36+; before, the body and its
//! type only).
const std = @import("std");
const gtk = @import("gtk.zig");
const webkit = @import("webkit.zig");
const types = @import("../page_types.zig");
const serve = @import("../page_serve.zig");
const window_types = @import("../window_types.zig");
const Page = @import("page.zig").Page;

/// A request waiting for the app's answer.
pub const Task = struct {
    /// Null once the page closed.
    page: ?*Page,
    request: *anyopaque,
};

var registered: std.ArrayList([]const u8) = .empty;

/// Registers the schemes a page uses that are not yet.
pub fn registerAll(options: window_types.PageOptions) void {
    register("myzig");
    for (options.schemes) |s| register(s.name);
}

fn register(name: []const u8) void {
    for (registered.items) |r| if (std.mem.eql(u8, r, name)) return;
    const gpa = std.heap.page_allocator;
    const z = webkit.dupeZ(gpa, name) catch return;
    registered.append(gpa, z) catch return;
    const k = &webkit.api;
    const ctx = k.webkit_web_context_get_default();
    k.webkit_web_context_register_uri_scheme(ctx, z, handle, null, null);
    const sm = k.webkit_web_context_get_security_manager(ctx);
    k.webkit_security_manager_register_uri_scheme_as_secure(sm, z);
    k.webkit_security_manager_register_uri_scheme_as_cors_enabled(sm, z);
}

/// The page closes: answers still to come go to no page.
pub fn abandon(page: *Page) void {
    for (page.tasks.items) |t| t.page = null;
    page.tasks.clearRetainingCapacity();
}

fn handle(request: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    const k = &webkit.api;
    const page = Page.of(k.webkit_uri_scheme_request_get_web_view(request)) orelse return finishLegacy(request, "Not Found", "text/plain");
    const gpa = page.gpa;
    const method = if (webkit.newer.webkit_uri_scheme_request_get_http_method) |f| webkit.span(f(request)) else "GET";
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    if (webkit.newer.webkit_uri_scheme_request_get_http_body) |f| if (f(request)) |body_stream| {
        var chunk: [16384]u8 = undefined;
        while (body.items.len < 64 << 20) {
            const n = k.g_input_stream_read(body_stream, &chunk, chunk.len, null, null);
            if (n <= 0) break;
            body.appendSlice(gpa, chunk[0..@intCast(n)]) catch break;
        }
        gtk.api.g_object_unref(body_stream);
    };
    const task = gpa.create(Task) catch return finishLegacy(request, "", "text/plain");
    task.* = .{ .page = page, .request = k.g_object_ref(request) };
    page.tasks.append(gpa, task) catch {};
    const url = webkit.span(k.webkit_uri_scheme_request_get_uri(request));
    const r = types.SchemeRequest.create(gpa, if (method.len == 0) "GET" else method, url, body.items, .{ .ctx = task, .begin = begin, .write = null, .finish = finish }) catch {
        finishLegacy(request, "", "text/plain");
        return done(task, gpa);
    };
    const page_url = page.currentUrl(gpa) catch null;
    defer if (page_url) |u| gpa.free(u);
    serve.dispatch(&page.core, page.window.app, r, webkit.span(k.webkit_uri_scheme_request_get_scheme(request)), page_url);
}

fn begin(_: *anyopaque, _: *types.SchemeRequest) void {}

fn finish(ctx: *anyopaque, req: *types.SchemeRequest) void {
    const task: *Task = @ptrCast(@alignCast(ctx));
    const gpa = req.gpa;
    defer req.destroy();
    respond(task.request, req);
    done(task, gpa);
}

fn done(task: *Task, gpa: std.mem.Allocator) void {
    if (task.page) |page| for (page.tasks.items, 0..) |t, i| if (t == task) {
        _ = page.tasks.swapRemove(i);
        break;
    };
    gtk.api.g_object_unref(task.request);
    gpa.destroy(task);
}

/// A memory stream of a copy of `body`, which GLib frees.
fn stream(body: []const u8) *anyopaque {
    const k = &webkit.api;
    const copy = k.g_malloc(@max(body.len, 1)) orelse return k.g_memory_input_stream_new_from_data("", 0, null);
    @memcpy(copy[0..body.len], body);
    return k.g_memory_input_stream_new_from_data(copy, @intCast(body.len), k.g_free);
}

fn respond(request: *anyopaque, req: *types.SchemeRequest) void {
    const n = &webkit.newer;
    var mime_buf: [256]u8 = undefined;
    const mime = webkit.printZ(&mime_buf, "{s}", .{req.header("Content-Type") orelse "application/octet-stream"}) orelse "application/octet-stream";
    const new = n.webkit_uri_scheme_response_new orelse return finishLegacy(request, req.buffer.items, mime);
    const finish_with = n.webkit_uri_scheme_request_finish_with_response orelse return finishLegacy(request, req.buffer.items, mime);
    const s = stream(req.buffer.items);
    defer gtk.api.g_object_unref(s);
    const resp = new(s, @intCast(req.buffer.items.len));
    defer gtk.api.g_object_unref(resp);
    if (n.webkit_uri_scheme_response_set_status) |f| f(resp, req.status, null);
    if (n.webkit_uri_scheme_response_set_content_type) |f| f(resp, mime);
    if (n.soup_message_headers_new) |headers_new| if (n.soup_message_headers_append) |append| if (n.webkit_uri_scheme_response_set_http_headers) |set| {
        const h = headers_new(1); // SOUP_MESSAGE_HEADERS_RESPONSE
        var it = std.mem.splitSequence(u8, req.headers.items, "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            var nb: [256]u8 = undefined;
            var vb: [2048]u8 = undefined;
            const name = webkit.printZ(&nb, "{s}", .{line[0..colon]}) orelse continue;
            const value = webkit.printZ(&vb, "{s}", .{std.mem.trim(u8, line[colon + 1 ..], " ")}) orelse continue;
            append(h, name, value);
        }
        set(resp, h); // takes it
    };
    finish_with(request, resp);
}

fn finishLegacy(request: *anyopaque, body: []const u8, mime: [:0]const u8) void {
    const s = stream(body);
    defer gtk.api.g_object_unref(s);
    webkit.api.webkit_uri_scheme_request_finish(request, s, @intCast(body.len), mime);
}
