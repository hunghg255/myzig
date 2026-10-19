//! Pages and navigation, after mygo's `ui.Router`: the history of the
//! pages of a window, or of a part of one, as a browser keeps a tab's. A
//! page is a path, as "/notes/42", which the view matches to build the
//! page shown: `{name}` takes one part of the path, `{name...}` the rest.
//!
//!     // In the app's state:
//!     router: ui.Router = .init("/notes"),
//!
//!     var pages = s.router.pages(c, .{});
//!     while (pages.next()) |r| {
//!         defer r.end();
//!         if (r.match("/notes")) {
//!             r.title("Notes");
//!             s.notes(c);
//!         } else if (r.match("/notes/{id}")) {
//!             s.note(c, r.param("id"));
//!         } else ui.text(c, "Not found", .{});
//!     }
//!     pages.end();
//!
//! `push` goes to a page, `replace` shows one in its place, `back`,
//! `forward` and `go` move through the history; paths relative to the page
//! shown resolve as links in a web page do (`push("?tab=info")`,
//! `push("edit")`, `push("..")`). Cmd+[ and Cmd+] on macOS, Alt+Left and
//! Alt+Right elsewhere go back and forward, as `historyButtons` do. A page
//! deeper in the paths slides in from the end over the page it leaves, and
//! back; others fade in (all fade with less motion). The page going away
//! is drawn but takes neither the pointer nor Tab. A page keeps the state
//! of its boxes while it is in the history: a path with another query is
//! the same page.
const std = @import("std");
const motion = @import("motion.zig");
const view = @import("router_view.zig");
pub const Route = view.Route;
pub const Pages = view.Pages;
pub const Options = view.Options;

/// The longest location (path and query) a router keeps, in bytes.
pub const max_location = 256;
pub const max_title = 64;
/// Entries of the history kept; the oldest go first.
pub const max_history = 50;

pub const Transition = enum {
    /// Deeper pages slide in, others fade.
    auto,
    fade,
    none,
};

pub const Entry = struct {
    loc_buf: [max_location]u8 = undefined,
    loc_len: u16 = 0,
    title_buf: [max_title]u8 = undefined,
    title_len: u8 = 0,
    /// The page's key: its boxes' ids come from it, so it keeps their
    /// state while it is in the history.
    page: u64 = 0,
    /// The focus in it as it was left, given back as it shows again.
    focus: u64 = 0,

    pub fn location(e: *const Entry) []const u8 {
        return e.loc_buf[0..e.loc_len];
    }

    pub fn path(e: *const Entry) []const u8 {
        return pathOf(e.location());
    }

    pub fn title(e: *const Entry) []const u8 {
        return e.title_buf[0..e.title_len];
    }

    pub fn setTitle(e: *Entry, t: []const u8) void {
        const n = utf8Prefix(t, max_title);
        @memcpy(e.title_buf[0..n], t[0..n]);
        e.title_len = @intCast(n);
    }

    fn set(e: *Entry, loc: []const u8) void {
        @memcpy(e.loc_buf[0..loc.len], loc);
        e.loc_len = @intCast(loc.len);
    }
};

pub const Router = struct {
    entries: [max_history]Entry = undefined,
    count: usize = 0,
    at: usize = 0,
    pages_made: u64 = 0,
    transition: Transition = .auto,
    /// Seconds pages slide and fade.
    slide_seconds: f32 = 0.25,
    fade_seconds: f32 = 0.15,
    ease: motion.Easing = .ease_out,

    // Kept by `pages`: the page shown last, and the one going away.
    shown: u64 = 0,
    leaving: ?Entry = null,
    /// 1: the new page is deeper (it slides in), -1: shallower (the old
    /// one slides out), 0: they fade.
    dir: i8 = 0,
    started: f64 = 0,

    /// Builds the router's box: its pages follow (`Pages.next`), then
    /// `Pages.end`.
    pub fn pages(r: *Router, c: *@import("context.zig").Context, opts: view.Options) view.Pages {
        return view.pages(r, c, opts);
    }

    /// Back and forward buttons for it: true when they moved it.
    pub fn historyButtons(r: *Router, c: *@import("context.zig").Context) bool {
        return view.historyButtons(r, c);
    }

    /// A router showing the page at `start`.
    pub fn init(start: []const u8) Router {
        var r: Router = .{};
        r.replace(start);
        return r;
    }

    /// The entry shown ("/" for a router never given one).
    pub fn current(r: *Router) *Entry {
        if (r.count == 0) {
            r.entries[0] = .{ .page = r.newPage() };
            r.entries[0].set("/");
            r.count = 1;
            r.at = 0;
        }
        return &r.entries[r.at];
    }

    fn newPage(r: *Router) u64 {
        r.pages_made += 1;
        return r.pages_made *% 0x9e3779b97f4a7c15 ^ 0x726f757465;
    }

    /// Goes to the page at `target`, after the page shown, forgetting the
    /// pages after it. Going to the page shown does nothing.
    pub fn push(r: *Router, target: []const u8) void {
        var buf: [max_location]u8 = undefined;
        const cur = r.current();
        const loc = resolve(&buf, cur.location(), target) orelse return;
        if (std.mem.eql(u8, loc, cur.location())) return;
        var e: Entry = .{ .page = if (std.mem.eql(u8, pathOf(loc), cur.path())) cur.page else r.newPage() };
        e.set(loc);
        if (std.mem.eql(u8, pathOf(loc), cur.path())) e.setTitle(cur.title());
        r.count = r.at + 1;
        if (r.count == max_history) {
            std.mem.copyForwards(Entry, r.entries[0 .. max_history - 1], r.entries[1..max_history]);
            r.count -= 1;
        }
        r.entries[r.count] = e;
        r.count += 1;
        r.at = r.count - 1;
    }

    /// Shows the page at `target` in place of the page shown: back does
    /// not return to the page replaced. The same path with another query
    /// keeps the page and its state.
    pub fn replace(r: *Router, target: []const u8) void {
        var buf: [max_location]u8 = undefined;
        const base = if (r.count > 0) r.entries[r.at].location() else "/";
        const loc = resolve(&buf, base, target) orelse return;
        if (r.count == 0) {
            r.entries[0] = .{ .page = r.newPage() };
            r.entries[0].set(loc);
            r.count = 1;
            r.at = 0;
            return;
        }
        const old = &r.entries[r.at];
        if (std.mem.eql(u8, old.location(), loc)) return;
        if (!std.mem.eql(u8, pathOf(loc), old.path())) {
            old.page = r.newPage();
            old.title_len = 0;
            old.focus = 0;
        }
        old.set(loc);
    }

    pub fn back(r: *Router) void {
        r.go(-1);
    }

    pub fn forward(r: *Router) void {
        r.go(1);
    }

    /// Moves `n` pages through the history, as far as it goes.
    pub fn go(r: *Router, n: isize) void {
        _ = r.current();
        const to = std.math.clamp(@as(isize, @intCast(r.at)) + n, 0, @as(isize, @intCast(r.count - 1)));
        r.at = @intCast(to);
    }

    pub fn canGoBack(r: *const Router) bool {
        return r.at > 0;
    }

    pub fn canGoForward(r: *const Router) bool {
        return r.at + 1 < r.count;
    }

    /// The path of the page shown, as "/notes/42".
    pub fn path(r: *Router) []const u8 {
        return r.current().path();
    }

    /// Its path and query, as "/notes/42?tab=info": what `push` and
    /// `replace` take, to show it again when the app starts.
    pub fn location(r: *Router) []const u8 {
        return r.current().location();
    }

    /// The value of the query's parameter `name` of the page shown.
    pub fn query(r: *Router, name: []const u8) ?[]const u8 {
        return queryOf(r.current().location(), name);
    }

    /// The title the page shown gave itself (`Route.title`).
    pub fn title(r: *Router) []const u8 {
        return r.current().title();
    }

    /// The entries `n` pages back (negative) or forward, for a list of
    /// pages to go to by their titles.
    pub fn entry(r: *Router, n: isize) ?*const Entry {
        const at = @as(isize, @intCast(r.at)) + n;
        if (at < 0 or at >= r.count) return null;
        return &r.entries[@intCast(at)];
    }
};

/// The path of a location, without its query.
pub fn pathOf(loc: []const u8) []const u8 {
    return loc[0 .. std.mem.indexOfScalar(u8, loc, '?') orelse loc.len];
}

/// The value of parameter `name` in the query of `loc`; "" for one
/// without a value.
pub fn queryOf(loc: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, loc, '?') orelse return null;
    var it = std.mem.splitScalar(u8, loc[q + 1 ..], '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse kv.len;
        if (std.mem.eql(u8, kv[0..eq], name)) return if (eq < kv.len) kv[eq + 1 ..] else "";
    }
    return null;
}

/// `target` resolved against `base` as a link in a web page is, its path
/// made absolute and clean, into `buf`.
pub fn resolve(buf: *[max_location]u8, base: []const u8, target: []const u8) ?[]const u8 {
    var raw: [max_location * 2]u8 = undefined;
    var w: std.Io.Writer = .fixed(&raw);
    const base_path = pathOf(base);
    const t_path = pathOf(target);
    const t_query = target[t_path.len..];
    if (t_path.len == 0) {
        // Only a query (or nothing): the same path.
        w.writeAll(base_path) catch return null;
    } else if (t_path[0] == '/') {
        w.writeAll(t_path) catch return null;
    } else {
        // Beside the base's last part.
        const dir = base_path[0 .. (std.mem.lastIndexOfScalar(u8, base_path, '/') orelse 0) + 1];
        w.writeAll(dir) catch return null;
        w.writeAll(t_path) catch return null;
    }
    // Clean: no empty parts, ".", or ".." past the root.
    var parts: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, w.buffered(), '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            n -|= 1;
            continue;
        }
        if (n == parts.len) return null;
        parts[n] = p;
        n += 1;
    }
    var out: std.Io.Writer = .fixed(buf);
    if (n == 0) out.writeAll("/") catch return null;
    for (parts[0..n]) |p| {
        out.writeAll("/") catch return null;
        out.writeAll(p) catch return null;
    }
    out.writeAll(t_query) catch return null;
    return out.buffered();
}

fn utf8Prefix(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
    return n;
}

test "resolve" {
    var b: [max_location]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("/notes/42", resolve(&b, "/notes", "/notes/42").?);
    try t.expectEqualStrings("/notes/edit", resolve(&b, "/notes/42", "edit").?);
    try t.expectEqualStrings("/notes/42?tab=info", resolve(&b, "/notes/42?x=1", "?tab=info").?);
    try t.expectEqualStrings("/", resolve(&b, "/notes/42", "..").?);
    try t.expectEqualStrings("/a/c", resolve(&b, "/a/b/x", "../c").?);
    try t.expectEqualStrings("/files", resolve(&b, "/", "//files/./").?);
    try t.expectEqualStrings("1", queryOf("/s?q=1&n", "q").?);
    try t.expectEqualStrings("", queryOf("/s?q=1&n", "n").?);
    try t.expect(queryOf("/s?q=1", "z") == null);
}

test "history" {
    const t = std.testing;
    var r: Router = .init("/notes");
    try t.expect(!r.canGoBack());
    r.push("/notes/1");
    r.push("2");
    try t.expectEqualStrings("/notes/2", r.path());
    r.back();
    try t.expectEqualStrings("/notes/1", r.path());
    try t.expect(r.canGoForward());
    // A push forgets the pages after.
    r.push("/files");
    try t.expect(!r.canGoForward());
    r.go(-10);
    try t.expectEqualStrings("/notes", r.path());
    // The same path with another query is the same page.
    const page = r.current().page;
    r.push("?sort=date");
    try t.expectEqual(page, r.current().page);
    try t.expectEqualStrings("date", r.query("sort").?);
    r.replace("/other");
    try t.expect(r.current().page != page);
    r.back();
    try t.expectEqualStrings("/notes", r.path());
    // The oldest go first.
    for (0..max_history + 5) |i| {
        var buf: [32]u8 = undefined;
        r.push(std.fmt.bufPrint(&buf, "/p/{d}", .{i}) catch unreachable);
    }
    try t.expectEqual(@as(usize, max_history), r.count);
}
