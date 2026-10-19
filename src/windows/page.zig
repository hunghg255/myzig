//! The web page a window shows on Windows: a WebView2 web view with the
//! bridge injected, the app's schemes served at `http://<scheme>.localhost/`
//! (the `myzig://localhost/` of macOS: WebView2 treats *.localhost as a
//! secure origin), and the outbox of messages batched into one script per
//! turn of the message loop. The web view comes later than the window: the
//! environment and its controller are created asynchronously, and what
//! the page is asked meanwhile waits (its URL, scripts, zoom).
const std = @import("std");
const com = @import("com.zig");
const w = @import("win32.zig");
const webview2 = @import("webview2.zig");
const ipc = @import("../ipc.zig");
const window_types = @import("../window_types.zig");
const types = @import("../page_types.zig");
const core_mod = @import("../page_core.zig");
const serve = @import("../page_serve.zig");
const events = @import("page_events.zig");
const scheme = @import("page_scheme.zig");
const extra = @import("page_extra.zig");
const Window = @import("window.zig").Window;

const scripts = @import("page_scripts.zig");
const embed_mod = @import("page_embed.zig");
pub const origin = "http://myzig.localhost";

/// Events wait for dom-ready so listeners exist; bounded per page.
const max_held = 1024;

/// Window messages a page posts to its window.
pub const WM_FLUSH = w.WM_APP + 1;

// Vtable indices, from WebView2.h (each interface extends the previous
// version, so they stay valid for newer runtimes).
const env_create_controller = 3;
const ctl_put_visible = 4;
const ctl_put_bounds = 6;
const ctl_get_zoom = 7;
const ctl_put_zoom = 8;
const ctl_move_focus = 12;
const ctl_close = 24;
const ctl_get_webview = 25;
pub const wv_get_settings = 3;
const wv_get_source = 4;
const wv_navigate = 5;
const wv_navigate_to_string = 6;
const wv_execute_script = 29;
const wv_reload = 31;
const wv_add_message = 34;
const wv_can_go_back = 38;
const wv_can_go_forward = 39;
const wv_go_back = 40;
const wv_go_forward = 41;
const wv_stop = 43;
const wv_get_title = 48;
const wv_open_dev_tools = 51;
const set_put_status_bar = 10;
const set_put_dev_tools = 12;
const set2_get_user_agent = 21;
const set2_put_user_agent = 22;
const msg_try_string = 5;
const iid_settings2 = com.GUID.parse("ee9a0f68-f46c-4e32-ac23-ef8cac224d2a");

/// The pages alive, which handlers check their context against.
var live: std.ArrayList(*Page) = .empty;
/// Controllers (and their web views) of destroyed pages, to close, and
/// the windows that held embedded ones.
var closing: std.ArrayList(struct { ?com.Object, ?com.Object, ?w.HWND }) = .empty;

fn closeControllers(_: ?w.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    _ = w.KillTimer(null, id);
    const list = closing.toOwnedSlice(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(list);
    for (list) |pair| {
        if (pair[0]) |c| _ = com.call(c, ctl_close, .{});
        com.release(pair[1]);
        com.release(pair[0]);
        if (pair[2]) |h| _ = w.DestroyWindow(h);
    }
}

pub const Page = struct {
    window: *Window,
    gpa: std.mem.Allocator,
    options: window_types.PageOptions,
    core: core_mod.Core,
    controller: ?com.Object = null,
    webview: ?com.Object = null,
    /// The URL to load once the web view exists.
    url_next: []u8 = &.{},
    /// A document `loadHtml` serves at its base URL (in the web view's form).
    html: ?struct { url: []u8, source: []u8 } = null,
    /// The ids WebView2 gave the scripts it runs in every document.
    script_ids: std.ArrayList([:0]u16) = .empty,
    outbox: std.ArrayList(u8) = .empty,
    held: std.ArrayList([]u8) = .empty,
    /// Requests of the app's schemes not answered yet.
    tasks: std.ArrayList(*scheme.Task) = .empty,
    /// Asynchronous work under way (cookies, PDFs, downloads).
    ops: std.ArrayList(*extra.Op) = .empty,
    dom_ready: bool = false,
    flush_posted: bool = false,
    loading: bool = false,
    /// Destroyed while the environment or controller was being created:
    /// their completion frees it.
    dead: bool = false,
    waiting: bool = false,
    /// Set for a page inside native UI (`ui.webView`): where it goes.
    embed: ?*embed_mod.Embed = null,

    pub fn create(window: *Window, options: window_types.PageOptions) !*Page {
        return open(window, options, null);
    }

    pub fn open(window: *Window, options: window_types.PageOptions, embed: ?*embed_mod.Embed) !*Page {
        const gpa = window.app.gpa;
        const self = try gpa.create(Page);
        self.* = .{ .window = window, .gpa = gpa, .options = options, .core = .init(gpa, window, window.app, options), .embed = embed };
        live.append(std.heap.page_allocator, self) catch {};
        self.load(options.url);
        self.waiting = true;
        var buf: [1024]u8 = undefined;
        webview2.environment.get(window.app.environ, userData(window.app, &buf), .{ .ctx = self, .func = envReady });
        return self;
    }

    /// Where WebView2 keeps the app's profile: %LOCALAPPDATA%\<name>\WebView2.
    fn userData(app: anytype, buf: []u8) []const u8 {
        const base = app.environ.get("LOCALAPPDATA") orelse app.environ.get("TEMP") orelse ".";
        return std.fmt.bufPrint(buf, "{s}\\{s}\\WebView2", .{ base, app.options.name }) catch ".";
    }

    /// The page of a handler's context, unless it was destroyed: WebView2
    /// may still call a handler until its controller closes.
    pub fn alive(ctx: ?*anyopaque) ?*Page {
        for (live.items) |p| if (@as(*anyopaque, p) == ctx) return if (p.dead) null else p;
        return null;
    }

    pub fn destroy(self: *Page) void {
        for (live.items, 0..) |p, i| if (p == self) {
            _ = live.swapRemove(i);
            break;
        };
        scheme.abandon(self);
        extra.abandon(self);
        const host = if (self.embed) |e| embed_mod.drop(self, e) else null;
        if (self.controller != null or host != null) {
            // Not from inside a handler of WebView2 (a completion may close
            // the window), which it does not survive: on the next turn.
            closing.append(std.heap.page_allocator, .{ self.controller, self.webview, host }) catch {};
            if (closing.items.len == 1) _ = w.SetTimer(null, 0, 0, closeControllers);
        }
        self.controller = null;
        self.webview = null;
        const gpa = self.gpa;
        self.core.deinit();
        gpa.free(self.url_next);
        self.dropHtml();
        for (self.script_ids.items) |id| gpa.free(id);
        self.script_ids.deinit(gpa);
        self.outbox.deinit(gpa);
        for (self.held.items) |m| gpa.free(m);
        self.held.deinit(gpa);
        self.tasks.deinit(gpa);
        self.ops.deinit(gpa);
        if (self.waiting) self.dead = true else gpa.destroy(self);
    }

    fn envReady(ctx: *anyopaque, env: ?com.Object) void {
        const self: *Page = @ptrCast(@alignCast(ctx));
        if (self.dead) return self.gpa.destroy(self);
        const e = env orelse {
            self.waiting = false;
            return;
        };
        const hwnd = (if (self.embed) |em| em.hwnd else self.window.hwnd) orelse {
            self.waiting = false;
            return;
        };
        const hr = com.withHandler(self, controllerReady, createController, .{ e, hwnd });
        if (com.failed(hr)) {
            self.waiting = false;
            std.log.err("myzig: creating the WebView2 controller failed (HRESULT 0x{x:0>8})", .{@as(u32, @bitCast(hr))});
        }
    }

    fn createController(env: com.Object, hwnd: w.HWND, handler: com.Object) com.HRESULT {
        return com.call(env, env_create_controller, .{ hwnd, handler });
    }

    fn controllerReady(ctx: ?*anyopaque, hr: usize, controller: usize) void {
        const self: *Page = @ptrCast(@alignCast(ctx));
        self.waiting = false;
        if (self.dead) {
            if (controller != 0) _ = com.call(@ptrFromInt(controller), ctl_close, .{});
            return self.gpa.destroy(self);
        }
        if (com.failed(@bitCast(@as(u32, @truncate(hr)))) or controller == 0) {
            std.log.err("myzig: creating the WebView2 controller failed (HRESULT 0x{x:0>8})", .{@as(u32, @truncate(hr))});
            return;
        }
        const c: com.Object = @ptrFromInt(controller);
        com.addRef(c);
        self.controller = c;
        var wv: ?com.Object = null;
        _ = com.call(c, ctl_get_webview, .{&wv});
        self.webview = wv orelse return;
        self.setUp();
    }

    fn setUp(self: *Page) void {
        const wv = self.webview.?;
        var settings: ?com.Object = null;
        if (!com.failed(com.call(wv, wv_get_settings, .{&settings}))) if (settings) |s| {
            _ = com.call(s, set_put_status_bar, .{@as(i32, 0)});
            _ = com.call(s, set_put_dev_tools, .{@as(i32, @intFromBool(self.options.inspectable))});
            com.release(s);
        };
        if (self.core.user_agent != null or self.core.uaSuffix().len > 0) self.applyUserAgent(self.core.user_agent orelse "");
        scripts.addAll(self);
        var token: i64 = 0;
        _ = com.withHandler(self, messageReceived, addEvent, .{ wv, @as(usize, wv_add_message), &token });
        events.register(self);
        scheme.register(self);
        _ = com.call(self.controller.?, ctl_put_visible, .{@as(i32, 1)});
        if (self.core.zoom != 1) _ = com.call(self.controller.?, ctl_put_zoom, .{self.core.zoom});
        if (self.embed) |e| e.setUp(self) else self.resize();
        self.navigate();
        if (self.embed == null and self.window.isFocused()) self.focus();
    }

    pub fn addEvent(wv: com.Object, index: usize, token: *i64, handler: com.Object) com.HRESULT {
        return com.call(wv, index, .{ handler, token });
    }

    pub fn ignore(_: ?*anyopaque, _: usize, _: usize) void {}

    /// Fits the web view to the window's client area.
    pub fn resize(self: *Page) void {
        const c = self.controller orelse return;
        const hwnd = self.window.hwnd orelse return;
        var r: w.RECT = .{};
        _ = w.GetClientRect(hwnd, &r);
        _ = com.call(c, ctl_put_bounds, .{r});
    }

    pub fn focus(self: *Page) void {
        if (self.controller) |c| _ = com.call(c, ctl_move_focus, .{@as(i32, 0)}); // programmatic
    }

    // Loading.

    pub fn load(self: *Page, url_or_path: []const u8) void {
        const gpa = self.gpa;
        var dev: [2048]u8 = undefined;
        const start = self.core.startUrl(&dev, url_or_path);
        var web: [2048]u8 = undefined;
        const full = if (std.mem.indexOf(u8, start, "://") != null or std.mem.startsWith(u8, start, "about:"))
            gpa.dupe(u8, serve.webUrl(&web, self.options, start))
        else
            std.fmt.allocPrint(gpa, origin ++ "{s}{s}", .{ if (start.len > 0 and start[0] == '/') "" else "/", start });
        gpa.free(self.url_next);
        self.url_next = full catch &.{};
        self.dom_ready = false;
        if (self.webview != null) self.navigate();
    }

    fn navigate(self: *Page) void {
        const wv = self.webview orelse return;
        if (self.url_next.len == 0) return;
        const u = com.wide(self.gpa, self.url_next) catch return;
        defer self.gpa.free(u);
        _ = com.call(wv, wv_navigate, .{u.ptr});
    }

    /// Loads `html` at `base_url` (relative URLs resolve against it, and
    /// it is the page's origin), or at about:blank when it is null.
    pub fn loadHtml(self: *Page, html: []const u8, base_url: ?[]const u8) void {
        const gpa = self.gpa;
        self.dropHtml();
        if (base_url) |b| {
            var web: [2048]u8 = undefined;
            const target = gpa.dupe(u8, serve.webUrl(&web, self.options, b)) catch return;
            const source = gpa.dupe(u8, html) catch return gpa.free(target);
            self.html = .{ .url = target, .source = source };
            // The app's schemes are filtered already.
            if (std.mem.eql(u8, serve.appUrl(&web, self.options, target), target)) scheme.addFilter(self, target);
            return self.load(target);
        }
        const wv = self.webview orelse return;
        self.dom_ready = false;
        const s = com.wide(gpa, html) catch return;
        defer gpa.free(s);
        _ = com.call(wv, wv_navigate_to_string, .{s.ptr});
    }

    fn dropHtml(self: *Page) void {
        const h = self.html orelse return;
        self.gpa.free(h.url);
        self.gpa.free(h.source);
        self.html = null;
    }

    /// Loads a file of the disk (an absolute path).
    pub fn loadFile(self: *Page, path: []const u8) void {
        var buf: [4096]u8 = undefined;
        self.load(serve.fileUrl(&buf, path) orelse return);
    }

    pub fn reload(self: *Page) void {
        if (self.webview) |wv| _ = com.call(wv, wv_reload, .{});
    }

    pub fn stop(self: *Page) void {
        if (self.webview) |wv| _ = com.call(wv, wv_stop, .{});
    }

    pub fn goBack(self: *Page) void {
        if (self.webview) |wv| _ = com.call(wv, wv_go_back, .{});
    }

    pub fn goForward(self: *Page) void {
        if (self.webview) |wv| _ = com.call(wv, wv_go_forward, .{});
    }

    pub fn canGoBack(self: *Page) bool {
        return self.getBool(wv_can_go_back);
    }

    pub fn canGoForward(self: *Page) bool {
        return self.getBool(wv_can_go_forward);
    }

    fn getBool(self: *Page, index: usize) bool {
        const wv = self.webview orelse return false;
        var v: i32 = 0;
        _ = com.call(wv, index, .{&v});
        return v != 0;
    }

    pub fn isLoading(self: *Page) bool {
        return self.loading;
    }

    /// The document's URL as the web view has it (`http://myzig.localhost/...`).
    pub fn currentUrl(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        const wv = self.webview orelse return gpa.dupe(u8, self.url_next);
        var p: ?[*:0]u16 = null;
        if (com.failed(com.call(wv, wv_get_source, .{&p}))) return error.NoUrl;
        return com.takeString(gpa, p);
    }

    /// The document's URL, with the app's schemes as `<scheme>://localhost/...`.
    pub fn url(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        const raw = try self.currentUrl(gpa);
        defer gpa.free(raw);
        var buf: [2048]u8 = undefined;
        return gpa.dupe(u8, serve.appUrl(&buf, self.options, raw));
    }

    pub fn title(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        const wv = self.webview orelse return gpa.dupe(u8, "");
        var p: ?[*:0]u16 = null;
        _ = com.call(wv, wv_get_title, .{&p});
        return com.takeString(gpa, p);
    }

    // Scripts, zoom, user agent, developer tools.

    /// Adds a script every later document runs; returns its id.
    pub fn addUserScript(self: *Page, script: types.UserScript) !u32 {
        const entry = try self.core.addScript(script);
        const id = entry.id;
        scripts.add(self, entry.source);
        return id;
    }

    /// Removes a script `addUserScript` added: later documents go without it.
    pub fn removeUserScript(self: *Page, id: u32) void {
        if (self.core.removeScript(id) == null) return;
        scripts.replace(self);
    }

    pub fn setZoom(self: *Page, factor: f64) void {
        self.core.zoom = factor;
        if (self.controller) |c| _ = com.call(c, ctl_put_zoom, .{factor});
    }

    pub fn zoom(self: *Page) f64 {
        const c = self.controller orelse return self.core.zoom;
        var f: f64 = 1;
        _ = com.call(c, ctl_get_zoom, .{&f});
        return f;
    }

    pub fn setUserAgent(self: *Page, ua: []const u8) void {
        if (self.core.user_agent) |old| self.gpa.free(old);
        self.core.user_agent = self.gpa.dupe(u8, ua) catch null;
        self.applyUserAgent(ua);
    }

    /// Sets the user agent the page sends, which WebView2 decides for an
    /// empty one; the options' suffix stays on the end of it, whether
    /// WebView2 kept the user agent or went back to its own.
    fn applyUserAgent(self: *Page, ua: []const u8) void {
        const s2 = self.settings2() orelse return;
        defer com.release(s2);
        const full = self.core.withSuffix(self.gpa, ua) catch return;
        defer self.gpa.free(full);
        self.putUserAgent(s2, if (ua.len > 0) full else "");
        if (ua.len > 0 or self.core.uaSuffix().len == 0) return;
        var p: ?[*:0]u16 = null;
        _ = com.call(s2, set2_get_user_agent, .{&p});
        const cur = com.takeString(self.gpa, p) catch return;
        defer self.gpa.free(cur);
        if (cur.len == 0) return;
        const with = self.core.withSuffix(self.gpa, cur) catch return;
        defer self.gpa.free(with);
        if (with.len != cur.len) self.putUserAgent(s2, with);
    }

    fn putUserAgent(self: *Page, s2: com.Object, ua: []const u8) void {
        const s = com.wide(self.gpa, ua) catch return;
        defer self.gpa.free(s);
        _ = com.call(s2, set2_put_user_agent, .{s.ptr});
    }

    pub fn userAgent(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        const s2 = self.settings2() orelse return gpa.dupe(u8, self.core.user_agent orelse "");
        defer com.release(s2);
        var p: ?[*:0]u16 = null;
        _ = com.call(s2, set2_get_user_agent, .{&p});
        return com.takeString(gpa, p);
    }

    fn settings2(self: *Page) ?com.Object {
        const wv = self.webview orelse return null;
        var settings: ?com.Object = null;
        if (com.failed(com.call(wv, wv_get_settings, .{&settings}))) return null;
        defer com.release(settings);
        return com.query(settings orelse return null, &iid_settings2);
    }

    pub fn openDevTools(self: *Page) void {
        if (!self.options.inspectable) return;
        if (self.webview) |wv| _ = com.call(wv, wv_open_dev_tools, .{});
    }

    // Messages.

    /// Queues a message for the page. Events (`hold`) wait for dom-ready.
    pub fn enqueue(self: *Page, msg: []const u8, hold: bool) void {
        const gpa = self.gpa;
        if (hold and !self.dom_ready) {
            if (self.held.items.len >= max_held) return;
            const copy = gpa.dupe(u8, msg) catch return;
            self.held.append(gpa, copy) catch gpa.free(copy);
            return;
        }
        if (self.outbox.items.len > 0) self.outbox.append(gpa, ',') catch return;
        self.outbox.appendSlice(gpa, msg) catch return;
        if (!self.flush_posted) if (if (self.embed) |e| e.hwnd else self.window.hwnd) |h| {
            self.flush_posted = true;
            _ = w.PostMessageW(h, WM_FLUSH, 0, 0);
        };
    }

    pub fn domReady(self: *Page) void {
        self.dom_ready = true;
        const gpa = self.gpa;
        for (self.held.items) |m| {
            self.enqueue(m, false);
            gpa.free(m);
        }
        self.held.clearRetainingCapacity();
        if (self.window.app.flags.eval) |js| self.execute(js);
    }

    /// A new document: what waited for the last one's DOM is dropped.
    pub fn navigated(self: *Page) void {
        self.dom_ready = false;
        for (self.held.items) |m| self.gpa.free(m);
        self.held.clearRetainingCapacity();
        self.core.navigated();
    }

    pub fn startDrag(self: *Page) void {
        const h = self.window.hwnd orelse return;
        _ = w.ReleaseCapture();
        _ = w.SendMessageW(h, w.WM_NCLBUTTONDOWN, 2, 0); // HTCAPTION
    }

    /// Runs `js` in the page, not waiting for it.
    pub fn eval(self: *Page, js: []const u8) void {
        self.execute(js);
    }

    /// Evaluates the expression `js` (a promise is awaited) and passes
    /// its value as JSON, or its error, to `cb`. The page's bridge answers:
    /// a navigation fails what is under way.
    pub fn evalResult(self: *Page, js: []const u8, cb: types.EvalCallback) void {
        if (self.webview == null) return cb.func(cb.ctx, .{ .err = "the page is not ready" });
        const script = self.core.evalScript(js, cb) catch return cb.func(cb.ctx, .{ .err = "out of memory" });
        defer self.gpa.free(script);
        self.execute(script);
    }

    pub fn execute(self: *Page, js: []const u8) void {
        const wv = self.webview orelse return;
        const s = com.wide(self.gpa, js) catch return;
        defer self.gpa.free(s);
        _ = com.withHandler(null, ignore, executeScript, .{ wv, s.ptr });
    }

    fn executeScript(wv: com.Object, js: [*:0]const u16, handler: com.Object) com.HRESULT {
        return com.call(wv, wv_execute_script, .{ js, handler });
    }

    /// Sends the outbox (the window's WM_FLUSH).
    pub fn flush(self: *Page) void {
        self.flush_posted = false;
        if (self.outbox.items.len == 0 or self.webview == null) return;
        const gpa = self.gpa;
        var script: std.ArrayList(u8) = .empty;
        defer script.deinit(gpa);
        script.appendSlice(gpa, "__myzig.receive([") catch return;
        script.appendSlice(gpa, self.outbox.items) catch return;
        script.appendSlice(gpa, "])") catch return;
        self.outbox.clearRetainingCapacity();
        self.execute(script.items);
    }

    fn messageReceived(ctx: ?*anyopaque, _: usize, args: usize) void {
        const self = alive(ctx) orelse return;
        if (args == 0) return;
        var p: ?[*:0]u16 = null;
        if (com.failed(com.call(@ptrFromInt(args), msg_try_string, .{&p}))) return; // not a string
        // The message may close the window, and free the page.
        const gpa = self.gpa;
        const body = com.takeString(gpa, p) catch return;
        defer gpa.free(body);
        ipc.handleMessage(self.window, self, body);
    }

    // Finding, printing and cookies (page_extra.zig).

    pub fn findInPage(self: *Page, text: []const u8, opts: types.FindOptions, cb: types.FindCallback) void {
        extra.find(self, text, opts, cb);
    }

    pub fn stopFind(self: *Page) void {
        self.execute("window.__myzig&&__myzig.stopFind()");
    }

    /// Shows the print dialog.
    pub fn print(self: *Page) void {
        self.execute("window.print()");
    }

    pub fn printToPdf(self: *Page, opts: types.PdfOptions, cb: types.PdfCallback) void {
        extra.printToPdf(self, opts, cb);
    }

    /// The cookies a request to `url_filter` sends, or all of them.
    pub fn listCookies(self: *Page, url_filter: ?[]const u8, cb: types.CookiesCallback) void {
        extra.listCookies(self, url_filter, cb);
    }

    pub fn setCookie(self: *Page, cookie: types.Cookie, cb: types.DoneCallback) void {
        extra.setCookie(self, cookie, cb);
    }

    pub fn deleteCookie(self: *Page, name: []const u8, domain: []const u8, path: []const u8, cb: types.DoneCallback) void {
        extra.deleteCookie(self, name, domain, path, cb);
    }

    pub fn clearCookies(self: *Page, cb: types.DoneCallback) void {
        extra.clearCookies(self, cb);
    }
};
