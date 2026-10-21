//! The web page a window shows on Linux: a WebKitGTK web view with the
//! bridge injected, the app's schemes (`myzig://` and those of
//! `PageOptions.schemes`) served by the app, and the outbox of messages
//! batched into one script per turn of the main loop.
const std = @import("std");
const gtk = @import("gtk.zig");
const webkit = @import("webkit.zig");
const ipc = @import("../ipc.zig");
const window_types = @import("../window_types.zig");
const types = @import("../page_types.zig");
const core_mod = @import("../page_core.zig");
const page_find = @import("../page_find.zig");
const serve = @import("../page_serve.zig");
const events = @import("page_events.zig");
const scheme = @import("page_scheme.zig");
const extra = @import("page_extra.zig");
const embed_mod = @import("page_embed.zig");
const Window = @import("window.zig").Window;

const bridge_js = @embedFile("../bridge.js");
const frame_placeholder = "const frame = \"\";";
const frame_at = at: {
    @setEvalBranchQuota(1_000_000);
    break :at std.mem.indexOf(u8, bridge_js, frame_placeholder).?;
};

/// Events wait for dom-ready so listeners exist; bounded per page.
const max_held = 1024;

/// The pages alive, which signal handlers and the schemes' handler find
/// by their data or web view.
var pages: std.ArrayList(*Page) = .empty;

pub const Page = struct {
    window: *Window,
    gpa: std.mem.Allocator,
    options: window_types.PageOptions,
    core: core_mod.Core,
    webview: *webkit.WebView,
    ucm: *anyopaque,
    outbox: std.ArrayList(u8) = .empty,
    held: std.ArrayList([]u8) = .empty,
    /// Requests of the app's schemes not answered yet.
    tasks: std.ArrayList(*scheme.Task) = .empty,
    /// Asynchronous work under way (cookies, PDFs).
    ops: std.ArrayList(*extra.Op) = .empty,
    dom_ready: bool = false,
    flush_scheduled: bool = false,
    /// The main loop's source of the scheduled flush.
    flush_source: c_uint = 0,
    dead: bool = false,
    /// The last button press in the page, where a window drag starts.
    press: ?struct { x: f64, y: f64, time: u32 } = null,
    /// Set for a page inside native UI (`ui.webView`): where it goes.
    embed: ?*embed_mod.Embed = null,

    pub fn create(window: *Window, options: window_types.PageOptions) !*Page {
        return open(window, options, null);
    }

    pub fn open(window: *Window, options: window_types.PageOptions, embed: ?*embed_mod.Embed) !*Page {
        if (!webkit.load()) return error.WebKitMissing;
        const k = &webkit.api;
        const gpa = window.app.gpa;
        scheme.registerAll(options);
        const self = try gpa.create(Page);
        errdefer gpa.destroy(self);
        try pages.append(std.heap.page_allocator, self);
        const ucm = k.webkit_user_content_manager_new();
        _ = k.webkit_user_content_manager_register_script_message_handler(ucm, "myzig");
        gtk.connect(ucm, "script-message-received::myzig", @ptrCast(&onMessage), self);
        const wv = k.webkit_web_view_new_with_user_content_manager(ucm);
        const settings = k.webkit_web_view_get_settings(wv);
        if (options.inspectable) k.webkit_settings_set_enable_developer_extras(settings, 1);
        // Windows the page opens go to the app (PageEvent.new_window), not a popup blocker.
        k.webkit_settings_set_javascript_can_open_windows_automatically(settings, 1);
        gtk.connect(wv, "button-press-event", @ptrCast(&onPress), self);
        self.* = .{ .window = window, .gpa = gpa, .options = options, .core = .init(gpa, window, window.app, options), .webview = wv, .ucm = ucm, .embed = embed };
        self.addScripts();
        if (self.core.user_agent != null or self.core.uaSuffix().len > 0) self.applyUserAgent(self.core.user_agent orelse "");
        if (self.core.zoom != 1) k.webkit_web_view_set_zoom_level(wv, self.core.zoom);
        events.register(self);
        if (embed) |e| e.adopt(wv) else if (window.gtkwindow) |win| gtk.api.gtk_container_add(win, wv);
        self.load(options.url);
        return self;
    }

    /// The page of a signal's data, unless it was destroyed.
    pub fn alive(data: ?*anyopaque) ?*Page {
        for (pages.items) |p| if (@as(*anyopaque, p) == data) return p;
        return null;
    }

    /// The page of a web view.
    pub fn of(wv: ?*webkit.WebView) ?*Page {
        for (pages.items) |p| if (@as(?*anyopaque, p.webview) == wv) return p;
        return null;
    }

    pub fn destroy(self: *Page) void {
        for (pages.items, 0..) |p, i| if (p == self) {
            _ = pages.swapRemove(i);
            break;
        };
        scheme.abandon(self);
        extra.abandon(self);
        if (self.embed) |e| embed_mod.drop(self, e);
        // Services let go of what they kept for it.
        self.window.app.bindings.pageGone(self.window, self);
        const gpa = self.gpa;
        self.core.deinit();
        gtk.api.g_object_unref(self.ucm);
        self.outbox.deinit(gpa);
        for (self.held.items) |m| gpa.free(m);
        self.held.deinit(gpa);
        self.tasks.deinit(gpa);
        self.ops.deinit(gpa);
        // A scheduled flush goes with the page.
        if (self.flush_scheduled) _ = gtk.api.g_source_remove(self.flush_source);
        gpa.destroy(self);
    }

    fn addScripts(self: *Page) void {
        self.addBridge();
        for (self.core.scripts.items) |s| self.addScript(s.source);
    }

    /// The bridge, its messages marked with the page's token: only the
    /// main frame, where user scripts run, knows it.
    fn addBridge(self: *Page) void {
        const source = std.mem.concat(self.gpa, u8, &.{ bridge_js[0..frame_at], "const frame = \"", &self.core.token, "\";", bridge_js[frame_at + frame_placeholder.len ..] }) catch return;
        defer self.gpa.free(source);
        self.addScript(source);
    }

    fn addScript(self: *Page, source: []const u8) void {
        const k = &webkit.api;
        const z = webkit.dupeZ(self.gpa, source) catch return;
        defer self.gpa.free(z);
        const script = k.webkit_user_script_new(z, 1, 0, null, null); // top frame, at document start
        k.webkit_user_content_manager_add_script(self.ucm, script);
        k.webkit_user_script_unref(script);
    }

    // Loading.

    pub fn load(self: *Page, url_or_path: []const u8) void {
        var dev: [2048]u8 = undefined;
        const target = self.core.startUrl(&dev, url_or_path);
        var buf: [2048]u8 = undefined;
        const full = if (std.mem.indexOfScalar(u8, target, ':') != null)
            webkit.printZ(&buf, "{s}", .{target}) orelse return
        else
            webkit.printZ(&buf, "myzig://localhost{s}{s}", .{ if (target.len > 0 and target[0] == '/') "" else "/", target }) orelse return;
        self.dom_ready = false;
        webkit.api.webkit_web_view_load_uri(self.webview, full);
    }

    /// Loads `html` at `base_url` (relative URLs resolve against it, and
    /// it is the page's origin), or at about:blank when it is null.
    pub fn loadHtml(self: *Page, html: []const u8, base_url: ?[]const u8) void {
        const gpa = self.gpa;
        const h = webkit.dupeZ(gpa, html) catch return;
        defer gpa.free(h);
        const b = if (base_url) |u| webkit.dupeZ(gpa, u) catch return else null;
        defer if (b) |x| gpa.free(x);
        self.dom_ready = false;
        webkit.api.webkit_web_view_load_html(self.webview, h, if (b) |x| x.ptr else null);
    }

    /// Loads a file of the disk (an absolute path).
    pub fn loadFile(self: *Page, path: []const u8) void {
        var buf: [4096]u8 = undefined;
        self.load(serve.fileUrl(&buf, path) orelse return);
    }

    pub fn reload(self: *Page) void {
        webkit.api.webkit_web_view_reload(self.webview);
    }

    pub fn stop(self: *Page) void {
        webkit.api.webkit_web_view_stop_loading(self.webview);
    }

    pub fn goBack(self: *Page) void {
        webkit.api.webkit_web_view_go_back(self.webview);
    }

    pub fn goForward(self: *Page) void {
        webkit.api.webkit_web_view_go_forward(self.webview);
    }

    pub fn canGoBack(self: *Page) bool {
        return webkit.api.webkit_web_view_can_go_back(self.webview) != 0;
    }

    pub fn canGoForward(self: *Page) bool {
        return webkit.api.webkit_web_view_can_go_forward(self.webview) != 0;
    }

    pub fn isLoading(self: *Page) bool {
        return webkit.api.webkit_web_view_is_loading(self.webview) != 0;
    }

    /// The document's URL.
    pub fn currentUrl(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        return gpa.dupe(u8, webkit.span(webkit.api.webkit_web_view_get_uri(self.webview)));
    }

    pub const url = currentUrl;

    pub fn title(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        return gpa.dupe(u8, webkit.span(webkit.api.webkit_web_view_get_title(self.webview)));
    }

    // Scripts, zoom, user agent, developer tools.

    /// Adds a script every later document runs; returns its id.
    pub fn addUserScript(self: *Page, script: types.UserScript) !u32 {
        const entry = try self.core.addScript(script);
        const id = entry.id;
        self.addScript(entry.source);
        return id;
    }

    /// Removes a script `addUserScript` added: later documents go without it.
    pub fn removeUserScript(self: *Page, id: u32) void {
        if (self.core.removeScript(id) == null) return;
        webkit.api.webkit_user_content_manager_remove_all_scripts(self.ucm);
        self.addScripts();
    }

    pub fn setZoom(self: *Page, factor: f64) void {
        self.core.zoom = factor;
        webkit.api.webkit_web_view_set_zoom_level(self.webview, factor);
    }

    pub fn zoom(self: *Page) f64 {
        return webkit.api.webkit_web_view_get_zoom_level(self.webview);
    }

    pub fn setUserAgent(self: *Page, ua: []const u8) void {
        if (self.core.user_agent) |old| self.gpa.free(old);
        self.core.user_agent = self.gpa.dupe(u8, ua) catch null;
        self.applyUserAgent(ua);
    }

    /// Sets the user agent with the options' suffix; an empty one restores
    /// WebKitGTK's, which the suffix appends to as application details.
    fn applyUserAgent(self: *Page, ua: []const u8) void {
        const settings = webkit.api.webkit_web_view_get_settings(self.webview);
        const suffix = self.core.uaSuffix();
        if (ua.len == 0 and suffix.len > 0) {
            // WebKitGTK takes the details as a name and a version and joins
            // them with "/", which is where the suffix splits: at the first.
            const slash = std.mem.indexOfScalar(u8, suffix, '/');
            const name = webkit.dupeZ(self.gpa, suffix[0 .. slash orelse suffix.len]) catch return;
            defer self.gpa.free(name);
            const version = webkit.dupeZ(self.gpa, if (slash) |i| suffix[i + 1 ..] else "") catch return;
            defer self.gpa.free(version);
            webkit.api.webkit_settings_set_user_agent_with_application_details(settings, name, if (slash != null) version else null);
            return;
        }
        const full = self.core.withSuffix(self.gpa, ua) catch return;
        defer self.gpa.free(full);
        const z = webkit.dupeZ(self.gpa, if (ua.len > 0) full else "") catch return;
        defer self.gpa.free(z);
        webkit.api.webkit_settings_set_user_agent(settings, z);
    }

    pub fn userAgent(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        return gpa.dupe(u8, webkit.span(webkit.api.webkit_settings_get_user_agent(webkit.api.webkit_web_view_get_settings(self.webview))));
    }

    pub fn openDevTools(self: *Page) void {
        if (!self.options.inspectable) return;
        webkit.api.webkit_web_inspector_show(webkit.api.webkit_web_view_get_inspector(self.webview));
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
        if (!self.flush_scheduled) {
            self.flush_scheduled = true;
            self.flush_source = gtk.api.g_idle_add(flushJob, self);
        }
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
        const window = self.window;
        const app = window.app;
        self.dom_ready = false;
        for (self.held.items) |m| self.gpa.free(m);
        self.held.clearRetainingCapacity();
        self.core.navigated();
        if (ipc.stillOpen(app, window, self)) app.bindings.pageGone(window, self);
    }

    pub fn startDrag(self: *Page) void {
        const p = self.press orelse return;
        const win = self.window.gtkwindow orelse return;
        webkit.api.gtk_window_begin_move_drag(win, 1, @intFromFloat(p.x), @intFromFloat(p.y), p.time);
    }

    /// Runs `js` in the page, not waiting for it.
    pub fn eval(self: *Page, js: []const u8) void {
        self.execute(js);
    }

    /// Evaluates the expression `js` (a promise is awaited) and passes
    /// its value as JSON, or its error, to `cb`. The page's bridge answers:
    /// a navigation fails what is under way.
    pub fn evalResult(self: *Page, js: []const u8, cb: types.EvalCallback) void {
        const script = self.core.evalScript(js, cb) catch return cb.func(cb.ctx, .{ .err = "out of memory" });
        defer self.gpa.free(script);
        self.execute(script);
    }

    pub fn execute(self: *Page, js: []const u8) void {
        const z = webkit.dupeZ(self.gpa, js) catch return;
        defer self.gpa.free(z);
        webkit.api.webkit_web_view_run_javascript(self.webview, z, null, null, null);
    }

    fn flush(self: *Page) void {
        self.flush_scheduled = false;
        if (self.outbox.items.len == 0) return;
        const gpa = self.gpa;
        var script: std.ArrayList(u8) = .empty;
        defer script.deinit(gpa);
        script.appendSlice(gpa, "__myzig.receive([") catch return;
        script.appendSlice(gpa, self.outbox.items) catch return;
        script.appendSlice(gpa, "])") catch return;
        self.outbox.clearRetainingCapacity();
        self.execute(script.items);
    }

    // Finding, printing and cookies (page_extra.zig).

    pub fn findInPage(self: *Page, text: []const u8, opts: types.FindOptions, cb: types.FindCallback) void {
        page_find.find(self, text, opts, cb);
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

fn flushJob(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Page = @ptrCast(@alignCast(data));
    if (self.dead) {
        self.gpa.destroy(self);
        return 0;
    }
    self.flush();
    return 0;
}

fn onMessage(_: *anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = Page.alive(data) orelse return;
    const k = &webkit.api;
    const value = k.webkit_javascript_result_get_js_value(result);
    if (k.jsc_value_is_string(value) == 0) return;
    const s = k.jsc_value_to_string(value);
    defer gtk.api.g_free(s);
    // Subframes have the handler too, but not the token.
    const message = std.mem.span(s);
    if (!std.mem.startsWith(u8, message, &self.core.token)) return;
    // The message may close the window, and free the page.
    ipc.handleMessage(self.window, self, message[self.core.token.len..]);
}

fn onPress(_: *anyopaque, event: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const self = Page.alive(data) orelse return 0;
    var x: f64 = 0;
    var y: f64 = 0;
    if (webkit.api.gdk_event_get_root_coords(event, &x, &y) != 0)
        self.press = .{ .x = x, .y = y, .time = webkit.api.gdk_event_get_time(event) };
    return 0; // the page gets it too
}
