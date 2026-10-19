//! Web pages in a window of native UI: a sidebar of tabs, each a web view
//! (`ui.webView`), under a toolbar. The notes page calls Zig and hears
//! from it through the bridge, as a window's page does; the window's
//! events reach it too. The toolbar's menu opens over the page.
//!
//!     zig build run-embed-webview
//!
//! With `--check` (and `--myzig-hidden`) it tests itself: the pages call
//! Zig, the menu shows over the page (its cover, which takes its click),
//! the web views follow the layout as it changes, hide when cut away or
//! not built, and hear the window's events; it prints "page: ok" (or
//! "page: FAIL ...") and quits (`zig build test-pages` on Windows);
//! `--debug` prints where each page is, and where it should be.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const assets = [_]myzig.Asset{
    .{ .path = "/notes.html", .data = @embedFile("notes.html") },
    .{ .path = "/about.html", .data = @embedFile("about.html") },
};

/// Tells pages how many likes there are.
const Liked = myzig.Event("liked", u32);

const Notes = struct {
    likes: u32 = 0,

    /// Counts a like and tells every page.
    pub fn like(self: *Notes) u32 {
        self.likes += 1;
        Liked.broadcast(app, self.likes);
        // The native count shows them too.
        window.redraw();
        return self.likes;
    }
};

const Tab = struct { id: []const u8, title: []const u8, view: ui.WebView = .{}, url: []const u8 };

const State = struct {
    tab: []const u8 = "notes",
    tabs: [2]Tab = .{
        .{ .id = "notes", .title = "Notes", .url = "/notes.html" },
        .{ .id = "about", .title = "About", .url = "/about.html" },
    },
    side: f32 = 180,
    /// Room above the page in its scroll box (the check moves it away).
    push: f32 = 0,
    /// The toolbar's menu, which opens over the page, and its item.
    menu: ui.OverlayState = .{},
    item: ?ui.Rect = null,
    chosen: u32 = 0,

    fn view(s: *State, c: *ui.Context) void {
        const t = c.theme;
        ui.row(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        var sb = ui.sidebar(c, &s.tab, .{ .width = .{ .px = s.side } });
        for (&s.tabs) |*tb| sb.item(tb.id, tb.title, .{});
        _ = sb.end();
        ui.column(c, .{ .grow = 1, .height = .fill });
        defer ui.end(c);
        const shown = s.current();
        ui.row(c, .{ .width = .fill, .padding = .xy(12, 8), .gap = 8, .align_items = .center });
        if (shown.view.page) |p| {
            if (ui.button(c, "Back", .{ .disabled = !p.canGoBack() }).clicked) p.goBack();
            if (ui.button(c, "Forward", .{ .disabled = !p.canGoForward() }).clicked) p.goForward();
            if (ui.button(c, "Reload", .{}).clicked) p.reload();
        }
        // Native UI over the page: the popover shows above it.
        const more = ui.button(c, "Menu", .{});
        if (more.clicked) s.menu.toggle();
        s.item = null;
        if (ui.popover(c, &s.menu, more, .{})) |m| {
            defer m.end();
            const item = ui.button(c, "Over the page", .{});
            s.item = item.rect;
            if (item.clicked) {
                s.chosen += 1;
                s.menu.close();
            }
        }
        _ = c.leaf(.{ .grow = 1 }, .none, null);
        ui.textf(c, .{}, "{d} likes", .{notes.likes});
        ui.end(c);
        ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .{ .left = 12, .right = 12, .bottom = 12 } });
        defer ui.end(c);
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = s.push } }, .none, null);
        // The page of the tab shown, in a rounded border; the others keep theirs.
        _ = ui.webView(c, &shown.view, .{
            .page = .{ .url = shown.url, .assets = &assets, .user_scripts = if (checking) &check_scripts else &.{} },
            .height = .{ .px = 440 },
            .radius = 12,
            .border = t.border,
            .padding = .all(1),
            .key = shown.id,
        });
    }

    fn current(s: *State) *Tab {
        for (&s.tabs) |*tb| if (std.mem.eql(u8, tb.id, s.tab)) return tb;
        return &s.tabs[0];
    }
};

var app: *myzig.App = undefined;
var window: *myzig.Window = undefined;
var notes: Notes = .{};
var state: State = .{};
var checking = false;
var debug = false;

pub fn main(init: std.process.Init) !void {
    for (try init.minimal.args.toSlice(init.arena.allocator())) |arg| {
        if (std.mem.eql(u8, arg, "--check")) checking = true;
        if (std.mem.eql(u8, arg, "--debug")) debug = true;
    }
    app = try myzig.App.create(init, .{ .name = "EmbedWebview" });
    defer app.destroy();
    try app.bind(&notes);
    try app.bind(&check);
    try app.registerEvent(Liked);
    window = try app.newWindow(.{
        .title = "Web views",
        .width = 900,
        .height = 560,
        .min_width = 560,
        .content = .{ .view = .init(&state, State.view) },
    });
    if (checking) myzig.App.after(60_000, null, guard);
    try app.run();
}

// The check (`--check`): the pages and Zig test each other.

/// What each page runs once its DOM is ready, in the check.
const check_scripts = [_]myzig.page.UserScript{.{ .at_document_end = true, .source =
    \\myzig.on("liked", (n) => { if (n === 42) myzig.call("Check.heard"); });
    \\const ch = new myzig.Channel();
    \\const echoed = new Promise((r) => { ch.onmessage = r; });
    \\myzig.call("Check.echo", ch, 41).then(() => echoed)
    \\  .then((v) => { if (v !== 42) throw new Error("channel " + v); return myzig.call("Notes.like"); })
    \\  .then((n) => myzig.call("Check.ready", location.pathname, n))
    \\  .catch((e) => myzig.log("FAIL " + e));
}};

const Step = enum { notes, covered, uncovered, moved, partly, cut, about, heard, done };

const Check = struct {
    step: Step = .notes,
    tries: u32 = 0,
    first: ?ui.WebViewProbe = null,

    pub const myzig_params = .{ .ready = .{ "path", "likes" }, .echo = .{ "channel", "value" } };

    /// A channel from a web view's page (not the window's): one value back.
    pub fn echo(_: *Check, channel: myzig.Channel(u32), value: u32) void {
        channel.send(value + 1) catch |e| return fail("echo: {s}", .{@errorName(e)});
    }

    /// A page's bridge works: it called Notes.like, then this.
    pub fn ready(self: *Check, path: []const u8, likes: u32) void {
        if (std.mem.eql(u8, path, "/notes.html") and self.step == .notes) {
            if (likes != 1) return fail("notes: {d} likes", .{likes});
            poll(null);
        } else if (std.mem.eql(u8, path, "/about.html") and self.step == .about) {
            if (likes != 2) return fail("about: {d} likes", .{likes});
            poll(null);
        }
    }

    /// The about page heard the event sent to its window.
    pub fn heard(self: *Check) void {
        if (self.step != .heard) return;
        self.step = .done;
        std.debug.print("page: ok\n", .{});
        end();
    }
};
var check: Check = .{};

/// Whether `v`'s page is where its last frame placed it (`shown`), or hidden.
fn placed(v: *const ui.WebView, shown: bool) ?ui.WebViewProbe {
    const p = v.probe() orelse return null;
    if (debug) std.debug.print("probe {any}\n", .{p});
    if (p[0].shown != shown) return null;
    if (shown and !std.meta.eql(p[0], p[1])) return null;
    return p[0];
}

/// Advances the check as far as the windows' state allows, then looks
/// again next turn (a frame, GTK's layout); fails after many turns.
fn poll(_: ?*anyopaque) callconv(.c) void {
    const notes_view = &state.tabs[0].view;
    const about_view = &state.tabs[1].view;
    while (true) switch (check.step) {
        .notes => {
            const p = placed(notes_view, true) orelse break;
            check.first = p;
            check.step = .covered;
            // The menu opens over the page.
            state.menu.show();
            window.redraw();
        },
        .covered => {
            // Its cover shows where the popover meets the page, with the
            // frame's pixels, and takes the click on its item.
            const p = notes_view.probeCover() orelse break;
            if (debug) std.debug.print("cover {any}\n", .{p});
            if (!p[0].shown or !std.meta.eql(p[0], p[1])) break;
            if (!notes_view.coverMatchesFrame()) return fail("the cover's pixels are not the frame's", .{});
            const r = state.item orelse break;
            if (!notes_view.clickCover(r.x + r.w / 2, r.y + r.h / 2)) return fail("the cover did not take the click on the menu", .{});
            check.step = .uncovered;
        },
        .uncovered => {
            if (state.chosen != 1) return fail("the menu's item heard {d} clicks", .{state.chosen});
            // Closed (once it faded out), nothing covers the page.
            const p = notes_view.probeCover() orelse break;
            if (p[0].shown or notes_view.cover != null) break;
            check.step = .moved;
            state.side = 260;
            window.redraw();
        },
        .moved => {
            const p = placed(notes_view, true) orelse break;
            if (p.clip[0] <= check.first.?.clip[0]) break;
            check.step = .partly;
            // The page goes partly past its scroll box's end: cut there.
            state.push = 200;
            window.redraw();
        },
        .partly => {
            const p = placed(notes_view, true) orelse break;
            if (p.clip[3] >= p.page[3] or p.page[1] != 0) break;
            check.step = .cut;
            // The page goes past its scroll box's end: cut away.
            state.push = 4000;
            window.redraw();
        },
        .cut => {
            if (notes_view.shown != null) break;
            _ = placed(notes_view, false) orelse break;
            check.step = .about;
            state.push = 0;
            state.tab = "about";
            window.redraw();
            check.tries = 0;
            return; // the about page calls Check.ready
        },
        .about => {
            _ = placed(about_view, true) orelse break;
            // Not built: the notes page hides, keeping its page.
            if (notes_view.page == null or placed(notes_view, false) == null) break;
            check.step = .heard;
            Liked.emit(window, 42);
            return;
        },
        .heard, .done => return,
    };
    check.tries += 1;
    if (check.tries > 1000) return fail("the web view did not follow the layout (step {s})", .{@tagName(check.step)});
    myzig.App.after(10, null, poll);
}

var ended = false;

fn fail(comptime fmt: []const u8, args: anytype) void {
    if (ended) return;
    std.debug.print("page: FAIL " ++ fmt ++ "\n", args);
    end();
}

fn end() void {
    if (ended) return;
    ended = true;
    // Not from inside the engine's callback that got here: on the next turn.
    myzig.App.after(0, null, struct {
        fn f(_: ?*anyopaque) callconv(.c) void {
            window.close();
        }
    }.f);
}

fn guard(_: ?*anyopaque) callconv(.c) void {
    fail("timed out at step {s}", .{@tagName(check.step)});
}
