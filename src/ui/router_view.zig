//! What a `Router` (`router.zig`) builds: its box, the page shown (and
//! the one going away, while they change), the keys that go back and
//! forward, history buttons, and `Route`, the page being built, which
//! matches its path against patterns.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const router = @import("router.zig");
const direction = @import("direction.zig");
const motion = @import("motion.zig");
const choice = @import("controls_choice.zig");
const Context = ctx_mod.Context;
const Router = router.Router;
const Entry = router.Entry;

pub const Options = struct {
    /// The router's box, where its pages show: all the room it is given
    /// by default.
    style: types.Style = .{ .width = .fill, .height = .fill, .grow = 1 },
    /// Takes the keys that go back and forward (the first router of a
    /// window; a router inside a page leaves them to it).
    keys: bool = true,
};

pub const max_params = 8;

/// A page being built: `match` tells its path apart, `param` reads what
/// the pattern's wildcards took.
pub const Route = struct {
    c: *Context,
    entry: *Entry,
    /// The parts of the path this route matches, after those of the
    /// layouts around it (`nested`).
    path: []const u8,
    /// Going away: drawn, but it takes nothing.
    leaving: bool,
    index: u32 = 0,
    focus_start: usize = 0,
    params: [max_params]struct { name: []const u8, value: []const u8 } = undefined,
    n_params: usize = 0,
    /// Where the `{name...}` of the last match started in `path`.
    rest_at: ?usize = null,

    /// Whether the page's path matches `pattern`, whose parts between
    /// slashes are the path's or wildcards: `{name}` takes one part,
    /// `{name...}` (at the end) the rest, which may be empty. A slash at
    /// the end makes no difference.
    pub fn match(r: *Route, pattern: []const u8) bool {
        var pi = parts(pattern);
        var si = parts(r.path);
        r.n_params = 0;
        r.rest_at = null;
        while (pi.next()) |p| {
            const wild = p.len >= 2 and p[0] == '{' and p[p.len - 1] == '}';
            if (wild and std.mem.endsWith(u8, p, "...}")) {
                // The rest, from the next part of the path.
                const at = si.index;
                const rest = std.mem.trim(u8, r.path[@min(at, r.path.len)..], "/");
                r.addParam(p[1 .. p.len - 4], rest);
                r.rest_at = at;
                return true;
            }
            const s = si.next() orelse return false;
            if (wild) r.addParam(p[1 .. p.len - 1], s) else if (!std.mem.eql(u8, p, s)) return false;
        }
        return si.next() == null;
    }

    fn addParam(r: *Route, name: []const u8, value: []const u8) void {
        if (r.n_params == max_params) return;
        r.params[r.n_params] = .{ .name = name, .value = value };
        r.n_params += 1;
    }

    /// What the wildcard `name` of the last match took, "" if none.
    pub fn param(r: *const Route, name: []const u8) []const u8 {
        for (r.params[0..r.n_params]) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return "";
    }

    /// The value of the query's parameter `name`.
    pub fn query(r: *const Route, name: []const u8) ?[]const u8 {
        return router.queryOf(r.entry.location(), name);
    }

    /// Names the page: history lists show it, and `Router.title`.
    pub fn title(r: *Route, t: []const u8) void {
        if (!r.leaving) r.entry.setTitle(t);
    }

    /// The route of the rest of the path the last match's `{name...}`
    /// took, for a layout around pages of its own: "/fonts" of
    /// "/settings/fonts" after `match("/settings/{section...}")`.
    pub fn nested(r: *const Route) Route {
        var n = r.*;
        const at = r.rest_at orelse r.path.len;
        n.path = r.path[@min(at, r.path.len)..];
        n.n_params = 0;
        n.rest_at = null;
        return n;
    }

    /// Closes the page's box.
    pub fn end(r: *Route) void {
        const c = r.c;
        std.debug.assert(c.stack.items[c.stack.items.len - 1] == r.index);
        c.end();
        const built = c.focus_order.items[@min(r.focus_start, c.focus_order.items.len)..];
        if (r.leaving) {
            // It takes neither Tab nor the pointer.
            c.focus_order.shrinkRetainingCapacity(r.focus_start);
            for (c.nodes.items[r.index..]) |*n| n.interactive = false;
        } else if (std.mem.indexOfScalar(u64, built, c.focus) != null) {
            r.entry.focus = c.focus;
        }
    }
};

fn parts(p: []const u8) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, p, '/');
}

/// The pages a router builds this frame: the one going away while they
/// change, then the one shown. Each is a `Route` to build and `end`.
pub const Pages = struct {
    c: *Context,
    r: *Router,
    index: u32,
    step: u8 = 0,
    /// How far the change is, 0 to 1 (1: none under way).
    progress: f32 = 1,
    width: f32 = 0,
    route: Route = undefined,

    pub fn next(p: *Pages) ?*Route {
        const c = p.c;
        const r = p.r;
        while (p.step < 2) {
            const step = p.step;
            p.step += 1;
            const leaving = step == 0;
            if (leaving and (r.leaving == null or p.progress >= 1)) continue;
            const e: *Entry = if (leaving) &r.leaving.? else r.current();
            p.route = .{ .c = c, .entry = e, .path = e.path(), .leaving = leaving };
            p.route.index = p.openPage(e, leaving);
            p.route.focus_start = c.focus_order.items.len;
            return &p.route;
        }
        return null;
    }

    fn openPage(p: *Pages, e: *const Entry, leaving: bool) u32 {
        const c = p.c;
        const r = p.r;
        var s: types.Style = .{ .direction = .column, .grow = 1, .width = .fill, .min_width = 0 };
        if (p.progress < 1) {
            const t = r.ease.at(p.progress);
            s = .{ .direction = .column, .absolute = true, .width = .fill, .height = .fill, .background = c.theme.background };
            // Toward the end of the line: right, or left right to left.
            const sign: f32 = if (direction.current(c) == .rtl) -1 else 1;
            switch (r.dir) {
                0 => s.opacity = if (leaving) 1 - t else t,
                1 => if (!leaving) {
                    s.transform = .translation(sign * p.width * (1 - t), 0);
                    s.shadow = .{ .color = c.theme.shadow, .blur = 16, .y = 0 };
                } else {
                    s.opacity = 1 - 0.3 * t;
                },
                else => if (leaving) {
                    s.transform = .translation(sign * p.width * t, 0);
                    s.shadow = .{ .color = c.theme.shadow, .blur = 16, .y = 0 };
                },
            }
        }
        c.next_key_int = e.page;
        const index = c.open(s, null);
        return index;
    }

    /// Closes the router's box.
    pub fn end(p: *Pages) void {
        const c = p.c;
        std.debug.assert(c.stack.items[c.stack.items.len - 1] == p.index);
        // The page going away is drawn under the one coming, unless it
        // slides out over it.
        if (p.r.dir == -1 and p.progress < 1) {
            const box = c.node(p.index);
            const first = box.first_child;
            if (first != ctx_mod.none and c.node(first).next != ctx_mod.none) {
                const second = c.node(first).next;
                box.first_child = second;
                c.node(first).next = ctx_mod.none;
                c.node(second).next = first;
                box.last_child = first;
            }
        }
        c.end();
    }
};

/// Opens the router's box and starts a change of page when the page shown
/// changed: then `Pages.next` gives the pages to build.
pub fn pages(r: *Router, c: *Context, opts: Options) Pages {
    if (opts.keys) keys(r, c);
    const cur = r.current();
    if (r.shown != cur.page) {
        start(r, c, cur);
        r.shown = cur.page;
    }
    var style = opts.style;
    var p: Pages = .{ .c = c, .r = r, .index = 0 };
    if (r.leaving != null) {
        const seconds = if (r.dir == 0) r.fade_seconds else r.slide_seconds;
        p.progress = if (seconds <= 0) 1 else @floatCast(std.math.clamp((c.time - r.started) / seconds, 0, 1));
        if (p.progress >= 1) r.leaving = null else {
            c.animationFrame();
            style.clip = true;
        }
    }
    p.index = c.open(style, null);
    p.width = if (c.rects.get(c.node(p.index).id)) |rect| rect.w else c.size.w;
    return p;
}

/// Starts the change from the page shown last to `cur`.
fn start(r: *Router, c: *Context, cur: *Entry) void {
    const first = r.shown == 0;
    // The page going away gives the focus it had back when shown again,
    // and the new one takes it, unless it was outside the router.
    var old: ?Entry = null;
    for (r.entries[0..r.count]) |*e| if (e.page == r.shown) {
        old = e.*;
    };
    if (old == null) if (r.leaving) |l| {
        old = l;
    };
    if (!first) {
        if (old) |o| if (o.focus != 0 and o.focus == c.focus) {
            c.focus = cur.focus;
        };
        r.leaving = old;
    }
    r.started = c.time;
    r.dir = 0;
    if (first or r.transition == .none or old == null) {
        r.leaving = null;
        return;
    }
    if (r.transition == .auto and !motion.reduced(c)) {
        const from = old.?.path();
        const to = cur.path();
        if (deeper(to, from)) r.dir = 1 else if (deeper(from, to)) r.dir = -1;
    }
}

/// Whether path `a` is below path `b`: "/notes/42" below "/notes".
fn deeper(a: []const u8, b: []const u8) bool {
    if (a.len <= b.len or !std.mem.startsWith(u8, a, b)) return false;
    return std.mem.eql(u8, b, "/") or a[b.len] == '/';
}

/// Back and forward from the keyboard: Cmd+[ and Cmd+] on macOS, Alt and
/// the arrow pointing back elsewhere (Alt+Right right to left).
fn keys(r: *Router, c: *Context) void {
    const S = ctx_mod.Shortcut;
    const mac = @import("builtin").os.tag == .macos;
    const rtl = direction.current(c) == .rtl;
    const back: S = if (mac) .{ .key = '[', .cmd = true } else .{ .key = if (rtl) S.right else S.left, .alt = true };
    const fwd: S = if (mac) .{ .key = ']', .cmd = true } else .{ .key = if (rtl) S.left else S.right, .alt = true };
    if (r.canGoBack() and c.shortcut(back)) r.back() //
    else if (r.canGoForward() and c.shortcut(fwd)) r.forward();
}

/// Back and forward buttons for the router, disabled at the ends of its
/// history: true when they moved it.
pub fn historyButtons(r: *Router, c: *Context) bool {
    const action = choice.historyButtons(c, .{ .can_back = r.canGoBack(), .can_forward = r.canGoForward(), .shortcuts = false });
    switch (action) {
        .back => r.back(),
        .forward => r.forward(),
        .none => return false,
    }
    return true;
}

test "match" {
    const t = std.testing;
    var e: Entry = .{};
    var r: Route = .{ .c = undefined, .entry = &e, .path = "/notes/42", .leaving = false };
    try t.expect(!r.match("/notes"));
    try t.expect(r.match("/notes/{id}"));
    try t.expectEqualStrings("42", r.param("id"));
    try t.expect(r.match("/notes/42/"));
    try t.expect(!r.match("/files/{p...}"));
    r.path = "/files/docs/a.txt";
    try t.expect(r.match("/files/{p...}"));
    try t.expectEqualStrings("docs/a.txt", r.param("p"));
    r.path = "/files";
    try t.expect(r.match("/files/{p...}"));
    try t.expectEqualStrings("", r.param("p"));
    r.path = "/settings/fonts";
    try t.expect(r.match("/settings/{section...}"));
    var n = r.nested();
    try t.expectEqualStrings("/fonts", n.path);
    try t.expect(n.match("/fonts"));
    try t.expect(deeper("/notes/42", "/notes"));
    try t.expect(!deeper("/notes2", "/notes"));
    try t.expect(deeper("/notes", "/"));
}
