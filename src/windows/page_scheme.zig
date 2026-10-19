//! The app's schemes in WebView2: requests for `http://<scheme>.localhost/`
//! (and for a `loadHtml` document's base URL) reach WebResourceRequested,
//! become `SchemeRequest`s of `<scheme>://localhost/` for the app, and are
//! answered whole through a deferral, which lets the app answer later.
//! What the app serves as an attachment is saved as a download, which
//! WebView2 cannot do with what it gets from here.
const std = @import("std");
const com = @import("com.zig");
const webview2 = @import("webview2.zig");
const types = @import("../page_types.zig");
const core_mod = @import("../page_core.zig");
const serve = @import("../page_serve.zig");
const desktop = @import("desktop.zig");
const Page = @import("page.zig").Page;

const env_create_response = 4;
const wv_add_resource = 55;
const wv_add_resource_filter = 57;
const res_get_request = 3;
const res_put_response = 5;
const res_get_deferral = 6;
const res_get_context = 7;
const req_get_uri = 3;
const req_get_method = 5;
const req_get_content = 7;
const deferral_complete = 3;
const stream_read = 3;
const context_document = 1;

extern "shlwapi" fn SHCreateMemStream(data: ?[*]const u8, size: u32) callconv(.winapi) ?com.Object;

/// A request waiting for the app's answer.
pub const Task = struct {
    /// Null once the page closed.
    page: ?*Page,
    args: com.Object,
    deferral: com.Object,
    /// A page loads, rather than a resource of one.
    document: bool,
};

pub fn register(page: *Page) void {
    const wv = page.webview.?;
    var token: i64 = 0;
    _ = com.withHandler(page, resourceRequested, Page.addEvent, .{ wv, @as(usize, wv_add_resource), &token });
    addFilter(page, @import("page.zig").origin ++ "/*");
    var buf: [256]u8 = undefined;
    for (page.options.schemes) |s| addFilter(page, std.fmt.bufPrint(&buf, "http://{s}.localhost/*", .{s.name}) catch continue);
    if (page.html) |h| addFilter(page, h.url);
}

pub fn addFilter(page: *Page, pattern: []const u8) void {
    const wv = page.webview orelse return;
    const p = com.wide(page.gpa, pattern) catch return;
    defer page.gpa.free(p);
    _ = com.call(wv, wv_add_resource_filter, .{ p.ptr, @as(i32, 0) }); // all resource contexts
}

/// The page closes: answers still to come go nowhere.
pub fn abandon(page: *Page) void {
    for (page.tasks.items) |t| {
        t.page = null;
        _ = com.call(t.deferral, deferral_complete, .{});
        com.release(t.deferral);
        com.release(t.args);
    }
    page.tasks.clearRetainingCapacity();
}

fn resourceRequested(ctx: ?*anyopaque, _: usize, args_ptr: usize) void {
    const page = Page.alive(ctx) orelse return;
    if (args_ptr == 0) return;
    const gpa = page.gpa;
    const args: com.Object = @ptrFromInt(args_ptr);
    var req: ?com.Object = null;
    if (com.failed(com.call(args, res_get_request, .{&req}))) return;
    const request = req orelse return;
    defer com.release(request);
    var p: ?[*:0]u16 = null;
    _ = com.call(request, req_get_uri, .{&p});
    const uri = com.takeString(gpa, p) catch return;
    defer gpa.free(uri);
    var context: i32 = 0;
    _ = com.call(args, res_get_context, .{&context});
    if (page.html) |h| if (context == context_document and std.mem.eql(u8, h.url, uri)) {
        return respondNow(args, 200, "Content-Type: text/html; charset=utf-8\r\n", h.source);
    };
    var buf: [4096]u8 = undefined;
    const url = serve.appUrl(&buf, page.options, uri);
    if (url.ptr == uri.ptr) return; // not the app's
    p = null;
    _ = com.call(request, req_get_method, .{&p});
    const method = com.takeString(gpa, p) catch return;
    defer gpa.free(method);
    var content: ?com.Object = null;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    if (!com.failed(com.call(request, req_get_content, .{&content}))) if (content) |s| {
        readStream(gpa, s, &body);
        com.release(s);
    };
    var deferral: ?com.Object = null;
    if (com.failed(com.call(args, res_get_deferral, .{&deferral}))) return;
    const task = gpa.create(Task) catch return;
    com.addRef(args);
    task.* = .{ .page = page, .args = args, .deferral = deferral.?, .document = context == context_document };
    page.tasks.append(gpa, task) catch {};
    const r = types.SchemeRequest.create(gpa, method, url, body.items, .{ .ctx = task, .begin = begin, .write = null, .finish = finish }) catch {
        respondNow(args, 500, "", "");
        return finishTask(task);
    };
    const scheme_name = url[0..std.mem.indexOfScalar(u8, url, ':').?];
    // The page asking: a document asks for itself.
    const page_url = if (task.document) null else page.currentUrl(gpa) catch null;
    defer if (page_url) |u| gpa.free(u);
    serve.dispatch(&page.core, page.window.app, r, scheme_name, page_url);
}

fn readStream(gpa: std.mem.Allocator, s: com.Object, out: *std.ArrayList(u8)) void {
    var chunk: [16384]u8 = undefined;
    while (out.items.len < 64 << 20) {
        var n: u32 = 0;
        const hr = com.call(s, stream_read, .{ &chunk, @as(u32, chunk.len), &n });
        if (com.failed(hr) or n == 0) return;
        out.appendSlice(gpa, chunk[0..n]) catch return;
    }
}

fn begin(_: *anyopaque, _: *types.SchemeRequest) void {}

fn finish(ctx: *anyopaque, req: *types.SchemeRequest) void {
    const task: *Task = @ptrCast(@alignCast(ctx));
    defer req.destroy();
    const page = task.page orelse return req.gpa.destroy(task);
    const ok = req.status >= 200 and req.status < 300;
    if (task.document and ok and isDownload(req)) {
        // The page stays; the app's answer becomes a file.
        respondNow(task.args, 204, "", "");
        save(page, req.url, req);
    } else {
        respondNow(task.args, req.status, req.headers.items, req.buffer.items);
    }
    finishTask(task);
}

fn finishTask(task: *Task) void {
    if (task.page) |page| {
        for (page.tasks.items, 0..) |t, i| if (t == task) {
            _ = page.tasks.swapRemove(i);
            break;
        };
        const gpa = page.gpa;
        _ = com.call(task.deferral, deferral_complete, .{});
        com.release(task.deferral);
        com.release(task.args);
        gpa.destroy(task);
    }
}

/// An attachment, or bytes a page cannot show.
fn isDownload(req: *const types.SchemeRequest) bool {
    if (req.header("Content-Disposition")) |d| if (std.ascii.startsWithIgnoreCase(std.mem.trim(u8, d, " "), "attachment")) return true;
    if (req.header("Content-Type")) |t| return std.ascii.startsWithIgnoreCase(t, "application/octet-stream");
    return false;
}

fn respondNow(args: com.Object, status: u16, headers: []const u8, body: []const u8) void {
    const env = webview2.environment.env orelse return;
    var buf: [8192]u16 = undefined;
    const hn = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], std.mem.trimEnd(u8, headers, "\r\n")) catch 0;
    buf[hn] = 0;
    const stream = SHCreateMemStream(body.ptr, @intCast(body.len)) orelse return;
    defer com.release(stream);
    const reason = std.unicode.utf8ToUtf16LeStringLiteral("OK");
    var resp: ?com.Object = null;
    if (com.failed(com.call(env, env_create_response, .{ stream, @as(i32, status), reason.ptr, @as([*:0]const u16, buf[0..hn :0]), &resp }))) return;
    defer com.release(resp);
    _ = com.call(args, res_put_response, .{resp.?});
}

// Downloads of what the app serves.

/// Serves `url` of an app scheme into a download.
pub fn download(page: *Page, url: []const u8, name: []const u8) void {
    const gpa = page.gpa;
    const d = gpa.create(Saving) catch return;
    d.* = .{ .page = page, .name = gpa.dupe(u8, name) catch return gpa.destroy(d) };
    const r = types.SchemeRequest.create(gpa, "GET", url, "", .{ .ctx = d, .begin = Saving.begin, .write = null, .finish = Saving.finish }) catch {
        gpa.free(d.name);
        return gpa.destroy(d);
    };
    const scheme_name = url[0..std.mem.indexOfScalar(u8, url, ':').?];
    serve.dispatch(&page.core, page.window.app, r, scheme_name, null);
}

const Saving = struct {
    page: *Page,
    name: []u8,

    fn begin(_: *anyopaque, _: *types.SchemeRequest) void {}

    fn finish(ctx: *anyopaque, req: *types.SchemeRequest) void {
        const d: *Saving = @ptrCast(@alignCast(ctx));
        defer req.destroy();
        defer {
            req.gpa.free(d.name);
            req.gpa.destroy(d);
        }
        // The page may have closed meanwhile.
        for (d.page.window.app.windows.items) |win| if (win.page == d.page) {
            if (req.status >= 400) return d.page.core.fire(.{ .download_done = .{ .url = req.url, .path = "", .err = "the app's handler failed" } });
            return saveAs(d.page, req.url, d.name, req);
        };
    }
};

fn save(page: *Page, url: []const u8, req: *types.SchemeRequest) void {
    var name: []const u8 = std.fs.path.basename(req.path);
    if (req.header("Content-Disposition")) |cd| if (std.mem.indexOf(u8, cd, "filename=")) |i| {
        name = std.mem.trim(u8, cd[i + "filename=".len ..], "\" ;");
    };
    saveAs(page, url, core_mod.safeName(name), req);
}

fn saveAs(page: *Page, url: []const u8, name: []const u8, req: *types.SchemeRequest) void {
    const gpa = page.gpa;
    const io = page.window.app.io;
    const dir = desktop.path(gpa, .downloads, page.window.app.options.name) catch null;
    defer if (dir) |x| gpa.free(x);
    const path = page.core.startDownload(io, dir, url, name) orelse return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = req.buffer.items }) catch |err|
        return page.core.fire(.{ .download_done = .{ .url = url, .path = path, .err = @errorName(err) } });
    page.core.fire(.{ .download_progress = .{ .url = url, .received = req.buffer.items.len, .total = req.buffer.items.len } });
    page.core.fire(.{ .download_done = .{ .url = url, .path = path } });
}
