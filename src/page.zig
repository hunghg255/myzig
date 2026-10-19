//! The web page a window shows on macOS: a WKWebView with the bridge
//! injected, the app's schemes (`myzig://` and those of
//! `PageOptions.schemes`) served by the app, and the outbox of messages
//! batched into one evaluation per main-loop turn. Its handler object is
//! the web view's script message handler, scheme handler, navigation and
//! UI delegate (page_mac_delegate.zig).
const std = @import("std");
const objc = @import("objc.zig");
const ipc = @import("ipc.zig");
const window_mod = @import("window.zig");
const types = @import("page_types.zig");
const core_mod = @import("page_core.zig");
const page_find = @import("page_find.zig");
const delegate = @import("page_mac_delegate.zig");
const extra = @import("page_mac_extra.zig");
const embed_mod = @import("page_embed_mac.zig");
const Window = window_mod.Window;

const bridge_js = @embedFile("bridge.js");

/// Events wait for dom-ready so listeners exist; bounded per page.
const max_held = 1024;

pub const Page = struct {
    window: *Window,
    gpa: std.mem.Allocator,
    options: window_mod.PageOptions,
    core: core_mod.Core,
    webview: objc.Object,
    handler: objc.Object,
    outbox: std.ArrayList(u8) = .empty,
    held: std.ArrayList([]u8) = .empty,
    /// Requests of the app's schemes not answered yet.
    tasks: std.ArrayList(*extra.Task) = .empty,
    /// Asynchronous work under way (cookies, PDFs, downloads).
    ops: std.ArrayList(*extra.Op) = .empty,
    dom_ready: bool = false,
    flush_scheduled: bool = false,
    dead: bool = false,
    last_mouse_down: ?objc.Object = null,
    /// Set for a page inside native UI (`ui.webView`): where it goes.
    embed: ?*embed_mod.Embed = null,

    pub fn create(window: *Window, options: window_mod.PageOptions) !*Page {
        return open(window, options, null);
    }

    pub fn open(window: *Window, options: window_mod.PageOptions, embed: ?*embed_mod.Embed) !*Page {
        const gpa = window.app.gpa;
        const self = try gpa.create(Page);
        errdefer gpa.destroy(self);

        const handler = objc.msg(objc.Object, delegate.handlerClass(), "new", .{});
        objc.setZig(handler, self);
        const webview_class = objc.defineClass(.{
            .name = "MyZigWebView",
            .superclass = "WKWebView",
            .methods = &.{
                .{ .name = "mouseDown:", .imp = &webViewMouseDown, .types = "v@:@" },
            },
        });

        const config = objc.new("WKWebViewConfiguration");
        defer objc.release(config);
        const ucm = objc.msg(objc.Object, config, "userContentController", .{});
        objc.msg(void, ucm, "addScriptMessageHandler:name:", .{ handler, objc.nsString("myzig") });
        objc.msg(void, config, "setURLSchemeHandler:forURLScheme:", .{ handler, objc.nsString("myzig") });
        for (options.schemes) |s| objc.msg(void, config, "setURLSchemeHandler:forURLScheme:", .{ handler, objc.nsString(s.name) });
        const prefs = objc.msg(objc.Object, config, "preferences", .{});
        const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
        if (options.inspectable) objc.msg(void, prefs, "setValue:forKey:", .{ yes, objc.nsString("developerExtrasEnabled") });
        // Windows the page opens go to the app (PageEvent.new_window), not a popup blocker.
        objc.msg(void, prefs, "setJavaScriptCanOpenWindowsAutomatically:", .{objc.YES});
        // Tab reaches buttons, links and the other controls too, as in
        // Chrome and WebView2, whatever the system's keyboard navigation
        // setting, unless the app asked for Safari's way (macOS 11.3+).
        if (objc.msg(objc.BOOL, prefs, "respondsToSelector:", .{objc.sel("setTabFocusesLinks:")}))
            objc.msg(void, prefs, "setTabFocusesLinks:", .{@as(objc.BOOL, !options.safari_tab_focus)});
        // WebKit appends the application's name to its own user agent.
        const suffix = std.mem.trim(u8, options.user_agent_suffix, " \t");
        if (suffix.len > 0) objc.msg(void, config, "setApplicationNameForUserAgent:", .{objc.nsString(suffix)});

        const content_view = objc.msg(objc.Object, window.nswindow, "contentView", .{});
        const bounds = objc.msg(objc.CGRect, content_view, "bounds", .{});
        const webview = objc.msg(objc.Object, objc.msg(objc.Object, webview_class, "alloc", .{}), "initWithFrame:configuration:", .{ bounds, config });
        objc.setZig(webview, self);
        objc.msg(void, webview, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)}); // width | height sizable
        if (options.inspectable and objc.msg(objc.BOOL, webview, "respondsToSelector:", .{objc.sel("setInspectable:")}))
            objc.msg(void, webview, "setInspectable:", .{objc.YES});
        objc.msg(void, webview, "setNavigationDelegate:", .{handler});
        objc.msg(void, webview, "setUIDelegate:", .{handler});
        objc.msg(void, webview, "addObserver:forKeyPath:options:context:", .{ handler, objc.nsString("title"), @as(objc.NSUInteger, 1), @as(?*anyopaque, null) });
        // The web view is not the content view: WebKit docks the inspector in its superview.
        if (embed) |e| e.adopt(webview) else objc.msg(void, content_view, "addSubview:", .{webview});

        self.* = .{ .window = window, .gpa = gpa, .options = options, .core = .init(gpa, window, window.app, options), .webview = webview, .handler = handler, .embed = embed };
        self.addScripts();
        if (self.core.user_agent) |ua| self.setUserAgent(ua);
        if (self.core.zoom != 1) self.setZoom(self.core.zoom);
        self.load(options.url);
        return self;
    }

    pub fn destroy(self: *Page) void {
        extra.abandon(self);
        if (self.embed) |e| embed_mod.drop(self, e);
        const ucm = objc.msg(objc.Object, objc.msg(objc.Object, self.webview, "configuration", .{}), "userContentController", .{});
        objc.msg(void, ucm, "removeScriptMessageHandlerForName:", .{objc.nsString("myzig")});
        objc.msg(void, self.webview, "removeObserver:forKeyPath:", .{ self.handler, objc.nsString("title") });
        objc.msg(void, self.webview, "setNavigationDelegate:", .{@as(?objc.Object, null)});
        objc.msg(void, self.webview, "setUIDelegate:", .{@as(?objc.Object, null)});
        objc.setZig(self.handler, null);
        objc.setZig(self.webview, null);
        objc.msg(void, self.webview, "removeFromSuperview", .{});
        objc.release(self.webview);
        objc.release(self.handler);
        if (self.last_mouse_down) |e| objc.release(e);
        const gpa = self.gpa;
        self.core.deinit();
        self.outbox.deinit(gpa);
        for (self.held.items) |m| gpa.free(m);
        self.held.deinit(gpa);
        self.tasks.deinit(gpa);
        self.ops.deinit(gpa);
        // A scheduled flush frees the page when it runs.
        if (self.flush_scheduled) self.dead = true else gpa.destroy(self);
    }

    fn addScripts(self: *Page) void {
        const ucm = objc.msg(objc.Object, objc.msg(objc.Object, self.webview, "configuration", .{}), "userContentController", .{});
        objc.msg(void, ucm, "removeAllUserScripts", .{});
        self.addScript(ucm, bridge_js);
        for (self.core.scripts.items) |s| self.addScript(ucm, s.source);
    }

    fn addScript(_: *Page, ucm: objc.Object, source: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const script = objc.msg(objc.Object, objc.alloc("WKUserScript"), "initWithSource:injectionTime:forMainFrameOnly:", .{
            objc.nsString(source), @as(objc.NSInteger, 0), objc.YES,
        });
        defer objc.release(script);
        objc.msg(void, ucm, "addUserScript:", .{script});
    }

    // Loading.

    pub fn load(self: *Page, url_or_path: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        var dev: [2048]u8 = undefined;
        const target = self.core.startUrl(&dev, url_or_path);
        var buf: [2048]u8 = undefined;
        const full = if (std.mem.indexOfScalar(u8, target, ':') != null)
            target
        else
            std.fmt.bufPrint(&buf, "myzig://localhost{s}{s}", .{ if (target.len > 0 and target[0] == '/') "" else "/", target }) catch target;
        const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(full)}) orelse return;
        const req = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl});
        self.dom_ready = false;
        _ = objc.msg(?objc.Object, self.webview, "loadRequest:", .{req});
    }

    /// Loads `html` at `base_url` (relative URLs resolve against it, and
    /// it is the page's origin), or at about:blank when it is null.
    pub fn loadHtml(self: *Page, html: []const u8, base_url: ?[]const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const base: ?objc.Object = if (base_url) |b| objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(b)}) else null;
        self.dom_ready = false;
        _ = objc.msg(?objc.Object, self.webview, "loadHTMLString:baseURL:", .{ objc.nsString(html), base });
    }

    /// Loads a file of the disk (an absolute path); its directory's files may load too.
    pub fn loadFile(self: *Page, path: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const file = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
        const dir = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(std.fs.path.dirname(path) orelse "/")});
        self.dom_ready = false;
        _ = objc.msg(?objc.Object, self.webview, "loadFileURL:allowingReadAccessToURL:", .{ file, dir });
    }

    pub fn reload(self: *Page) void {
        _ = objc.msg(?objc.Object, self.webview, "reload", .{});
    }

    pub fn stop(self: *Page) void {
        objc.msg(void, self.webview, "stopLoading", .{});
    }

    pub fn goBack(self: *Page) void {
        _ = objc.msg(?objc.Object, self.webview, "goBack", .{});
    }

    pub fn goForward(self: *Page) void {
        _ = objc.msg(?objc.Object, self.webview, "goForward", .{});
    }

    pub fn canGoBack(self: *Page) bool {
        return objc.msg(objc.BOOL, self.webview, "canGoBack", .{});
    }

    pub fn canGoForward(self: *Page) bool {
        return objc.msg(objc.BOOL, self.webview, "canGoForward", .{});
    }

    pub fn isLoading(self: *Page) bool {
        return objc.msg(objc.BOOL, self.webview, "isLoading", .{});
    }

    /// The document's URL.
    pub fn currentUrl(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const u = objc.msg(?objc.Object, self.webview, "URL", .{}) orelse return gpa.dupe(u8, "");
        return gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{})));
    }

    pub const url = currentUrl;

    pub fn title(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        return gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, self.webview, "title", .{})));
    }

    // Scripts, zoom, user agent, developer tools.

    /// Adds a script every later document runs; returns its id.
    pub fn addUserScript(self: *Page, script: types.UserScript) !u32 {
        const entry = try self.core.addScript(script);
        const id = entry.id;
        self.addScripts();
        return id;
    }

    /// Removes a script `addUserScript` added: later documents go without it.
    pub fn removeUserScript(self: *Page, id: u32) void {
        if (self.core.removeScript(id) == null) return;
        self.addScripts();
    }

    pub fn setZoom(self: *Page, factor: f64) void {
        self.core.zoom = factor;
        if (objc.msg(objc.BOOL, self.webview, "respondsToSelector:", .{objc.sel("setPageZoom:")}))
            objc.msg(void, self.webview, "setPageZoom:", .{@as(objc.CGFloat, factor)});
    }

    pub fn zoom(self: *Page) f64 {
        if (!objc.msg(objc.BOOL, self.webview, "respondsToSelector:", .{objc.sel("pageZoom")})) return self.core.zoom;
        return objc.msg(objc.CGFloat, self.webview, "pageZoom", .{});
    }

    pub fn setUserAgent(self: *Page, ua: []const u8) void {
        // `create` passes the one it keeps.
        if (self.core.user_agent == null or self.core.user_agent.?.ptr != ua.ptr) {
            if (self.core.user_agent) |old| self.gpa.free(old);
            self.core.user_agent = self.gpa.dupe(u8, ua) catch null;
        }
        const pool = objc.Pool.push();
        defer pool.pop();
        // An empty one restores WebKit's, which the configuration still
        // appends the suffix to; another gets the suffix here.
        const full = self.core.withSuffix(self.gpa, ua) catch return;
        defer self.gpa.free(full);
        const custom: ?objc.Object = if (ua.len > 0) objc.nsString(full) else null;
        objc.msg(void, self.webview, "setCustomUserAgent:", .{custom});
    }

    pub fn userAgent(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const custom = objc.fromNSString(objc.msg(?objc.Object, self.webview, "customUserAgent", .{}));
        if (custom.len > 0) return gpa.dupe(u8, custom);
        const v = objc.msg(?objc.Object, self.webview, "valueForKey:", .{objc.nsString("userAgent")});
        return gpa.dupe(u8, objc.fromNSString(v));
    }

    /// Shows Web Inspector (a private API of WebKit's, which may go).
    pub fn openDevTools(self: *Page) void {
        if (!self.options.inspectable) return;
        if (!objc.msg(objc.BOOL, self.webview, "respondsToSelector:", .{objc.sel("_inspector")})) return;
        const inspector = objc.msg(?objc.Object, self.webview, "_inspector", .{}) orelse return;
        objc.msg(void, inspector, "show", .{});
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
            objc.dispatchMain(self, flushJob);
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
        self.dom_ready = false;
        for (self.held.items) |m| self.gpa.free(m);
        self.held.clearRetainingCapacity();
        self.core.navigated();
    }

    pub fn startDrag(self: *Page) void {
        const ev = self.last_mouse_down orelse return;
        objc.msg(void, self.window.nswindow, "performWindowDragWithEvent:", .{ev});
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
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.webview, "evaluateJavaScript:completionHandler:", .{ objc.nsString(js), @as(?*anyopaque, null) });
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

    /// A message of the bridge (the handler's script message).
    pub fn received(self: *Page, body: []const u8) void {
        ipc.handleMessage(self.window, self, body);
    }

    // Finding, printing and cookies (page_mac_extra.zig).

    pub fn findInPage(self: *Page, text: []const u8, opts: types.FindOptions, cb: types.FindCallback) void {
        page_find.find(self, text, opts, cb);
    }

    pub fn stopFind(self: *Page) void {
        self.execute("window.__myzig&&__myzig.stopFind()");
    }

    /// Shows the print panel.
    pub fn print(self: *Page) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const info = objc.msg(objc.Object, objc.class("NSPrintInfo"), "sharedPrintInfo", .{});
        const op = objc.msg(objc.Object, self.webview, "printOperationWithPrintInfo:", .{info});
        objc.msg(void, op, "runOperationModalForWindow:delegate:didRunSelector:contextInfo:", .{ self.window.nswindow, @as(?objc.Object, null), @as(?objc.SEL, null), @as(?*anyopaque, null) });
    }

    /// The page as one PDF page as tall as the document (WKWebView's
    /// createPDF, macOS 11+): the paper size and margins are not used.
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

fn flushJob(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Page = @ptrCast(@alignCast(ctx));
    if (self.dead) {
        self.gpa.destroy(self);
        return;
    }
    self.flush();
}

fn webViewMouseDown(self_obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    if (objc.getZig(Page, self_obj)) |page| {
        if (page.last_mouse_down) |old| objc.release(old);
        page.last_mouse_down = objc.retain(event);
    }
    objc.msgSuper(void, self_obj, objc.class("WKWebView"), "mouseDown:", .{event});
}
