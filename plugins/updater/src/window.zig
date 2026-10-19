//! The update window, in native UI, after mygo's updater/native: Sparkle's
//! window on every platform, without a webview. It follows a `Service`:
//! when a background check finds a new version it shows its release notes
//! and offers to install it, skip it or remind the user later; installing
//! shows the download, then offers to relaunch. A check the user asks for
//! (`checkForUpdates`, from a "Check for Updates…" menu item labeled
//! `menuItemLabel()`) shows the window at once, and says when the app is up
//! to date or the check failed.
//!
//!     var service: updater.Service = try .init(gpa, app, .{ .manifest_url = url, .current = version, .public_key = key });
//!     var window: updater.Window = undefined;
//!     window.init(&service, .{});
//!     defer window.deinit();
//!     service.startBackgroundChecks(10_000);
//!
//! The window speaks the language the app shows when its check begins and
//! keeps it while it is open (`texts.zig`).
const std = @import("std");
const myzig = @import("myzig");
const Service = @import("service.zig").Service;
const State = @import("service.zig").State;
const view_mod = @import("window_view.zig");
const View = view_mod.View;
const Texts = @import("texts.zig").Texts;

pub const Options = struct {
    /// The language of the window: "" follows the language the app shows
    /// (`i18n.locale()`) when each check begins.
    language: []const u8 = "",
    width: f64 = 540,
    height: f64 = 380,
};

pub const Window = struct {
    service: *Service,
    options: Options,
    view: View,
    /// The window while it is open.
    win: ?*myzig.Window = null,
    /// The version, notes and error the view shows.
    arena: std.heap.ArenaAllocator,
    /// Whether the user asked for the check under way.
    user: bool = false,

    /// Follows `service`, which must outlive it. Main thread.
    pub fn init(w: *Window, service: *Service, options: Options) void {
        w.* = .{ .service = service, .options = options, .arena = .init(service.gpa), .view = undefined };
        w.view = w.newView();
        service.listener = .{ .ctx = w, .state = onState, .begin = onBegin };
    }

    pub fn deinit(w: *Window) void {
        w.service.listener = null;
        if (w.win) |win| win.close();
        w.arena.deinit();
    }

    /// Checks as the user asked: the window shows at once, skipped versions
    /// too. While a check is under way, it brings its window to the front.
    pub fn checkForUpdates(w: *Window) void {
        w.service.check() catch {
            if (w.win) |win| win.focus();
        };
    }

    fn newView(w: *Window) View {
        return .{
            .texts = .init(w.options.language),
            .app_name = w.service.app.options.name,
            .current = w.service.options.current,
            .answer = .{ .ctx = w, .func = answered },
        };
    }

    fn onBegin(ctx: *anyopaque, user: bool) void {
        const w: *Window = @ptrCast(@alignCast(ctx));
        // A window open keeps its language; a new check takes the app's.
        if (w.win == null) {
            _ = w.arena.reset(.retain_capacity);
            w.view = w.newView();
        }
        w.user = user;
        if (user) {
            w.view.show(.checking);
            w.open();
        }
    }

    fn onState(ctx: *anyopaque, state: State) void {
        const w: *Window = @ptrCast(@alignCast(ctx));
        const v = &w.view;
        const a = w.arena.allocator();
        switch (state.kind) {
            .checking => if (w.win != null) v.show(.checking),
            .upToDate => if (w.user) {
                v.show(.up_to_date);
                w.open();
            },
            .available => {
                // With automatic downloads, background checks install
                // without asking: no window.
                if (state.background and w.service.prefs.automaticDownloads) return;
                v.version = a.dupe(u8, state.version) catch "";
                v.notes = a.dupe(u8, state.notes) catch "";
                v.automatic = w.service.prefs.automaticDownloads;
                v.show(.available);
                w.open();
            },
            .downloading => if (w.win != null) {
                v.done = state.done;
                v.total = state.total;
                v.show(.downloading);
            },
            .ready => if (w.win != null) v.show(.ready),
            .failed => {
                const installing = v.step == .downloading or v.step == .available;
                if (w.win == null and state.background) return;
                v.detail = a.dupe(u8, state.message) catch "";
                v.show(if (installing) .install_failed else .check_failed);
                w.open();
            },
        }
        if (w.win) |win| win.redraw();
    }

    fn answered(ctx: *anyopaque, action: view_mod.Action, automatic: bool) void {
        const w: *Window = @ptrCast(@alignCast(ctx));
        const s = w.service;
        switch (action) {
            .ok, .later, .cancel => w.close(),
            .skip => {
                s.skip() catch {};
                w.close();
            },
            .install => {
                if (automatic != s.prefs.automaticDownloads) s.setAutomaticDownloads(automatic) catch {};
                w.view.done = 0;
                w.view.total = null;
                w.view.show(.downloading);
                s.install() catch |err| {
                    w.view.detail = @errorName(err);
                    w.view.show(.install_failed);
                };
            },
            .relaunch => s.relaunch() catch {},
        }
        if (w.win) |win| win.redraw();
    }

    fn open(w: *Window) void {
        if (w.win) |win| {
            win.redraw();
            return;
        }
        w.win = w.service.app.newWindow(.{
            .title = w.view.texts.text(.title),
            .width = w.options.width,
            .height = w.options.height,
            .min_width = 420,
            .min_height = 150,
            .content = .{ .view = .init(&w.view, View.build) },
            .on_close = .{ .ctx = w, .func = closed },
        }) catch null;
    }

    fn close(w: *Window) void {
        if (w.win) |win| win.close();
    }

    fn closed(ctx: *anyopaque, _: *myzig.Window) void {
        const w: *Window = @ptrCast(@alignCast(ctx));
        w.win = null;
    }
};
