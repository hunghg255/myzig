//! A web page inside native UI: the system's web view (WebView2 on
//! Windows, WebKitGTK on Linux, WKWebView on macOS) made a child of the
//! window the first frame that shows it, and placed after each frame at
//! its box's content box, in device pixels, cut by the scroll containers
//! and clips around it. One that none of shows, or that the view does not
//! build, hides and keeps its page: a view of tabs builds the web view of
//! the tab shown.
//!
//!     var docs: ui.WebView = .{};
//!     ui.webView(c, &docs, .{ .page = .{ .url = "/docs.html", .assets = &assets }, .grow = 1 });
//!
//! Its page works as a window's: the bridge, the bound services, events
//! sent to the window, the app's schemes and its trust. Tab stops at it
//! and moves into the page, and on past its ends. The web view is a
//! native view over what the window paints; what native UI paints over its
//! box (its children, boxes after it, overlays: popovers, menus, dialogs,
//! toasts) shows above it all the same, in a cover the platform keeps over
//! the page (`page_embed_cover.zig`): the cover takes the pointer where it
//! is opaque, and the page takes it elsewhere.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const ctx_mod = @import("context.zig");
const embed = @import("../page_embed.zig");
const cover_mod = @import("../page_embed_cover.zig");
const Context = ctx_mod.Context;
const Interaction = ctx_mod.Interaction;
const none = ctx_mod.none;

pub const PageOptions = @import("../window_types.zig").PageOptions;
/// The platform's page (`myzig.Page`): load, eval, zoom, navigate.
pub const Page = embed.Page;
/// Where the platform has a page (`WebView.probe`).
pub const Probe = embed.Probe;
/// Where the platform has a page's cover (`WebView.probeCover`).
pub const CoverProbe = embed.CoverProbe;
/// A cover's pixels (`coverImage`).
pub const CoverImage = cover_mod.Image;

/// Where a frame shows a web view, in points of the window: its page's
/// box, and the part of it the clips around it leave.
pub const Placement = struct {
    frame: types.Rect,
    clip: types.Rect,
    /// Device pixels per point.
    scale: f32,
};

/// A web view, kept by the app: its page lives while the window does (or
/// until `destroy`), shown by the frames that build it.
pub const WebView = struct {
    /// The page, once a window showed the web view.
    page: ?*Page = null,
    /// The options the page was made with (the last build's).
    options: PageOptions = .{},
    /// Where the last frame showed it; null while hidden.
    shown: ?Placement = null,
    ctx: ?*Context = null,
    id: u64 = 0,
    node: u32 = none,
    focused: bool = false,
    /// The platform could not make it: not again.
    failed: bool = false,
    /// What the last frame painted over the page, in points of the window,
    /// within `shown.clip`; null when nothing did.
    cover: ?types.Rect = null,
    /// The frame being painted painted the web view's box: what it paints
    /// from this instance on is over the page.
    painted_from: ?usize = null,
    /// The cover's pixels, as the platform shows them.
    cover_px: std.ArrayList(u32) = .empty,
    cover_image: ?cover_mod.Image = null,
    cover_hash: u64 = 0,

    /// Closes the page; a later frame that builds it makes a new one.
    pub fn destroy(self: *WebView) void {
        if (self.page) |p| embed.destroy(p);
        self.page = null;
        self.shown = null;
        self.dropCover();
    }

    fn dropCover(self: *WebView) void {
        if (self.ctx) |c| self.cover_px.deinit(c.gpa);
        self.cover_px = .empty;
        self.cover_image = null;
        self.cover_hash = 0;
    }

    /// The page's Tab went past its last element (`back`: before its
    /// first): the keyboard goes back to native UI, on from the web view.
    pub fn tabOut(self: *WebView, back: bool) void {
        const c = self.ctx orelse return;
        c.focus = self.id;
        _ = c.moveFocus(back);
        self.focused = c.focus == self.id;
    }

    /// Where the platform has the page now, read back from its views, and
    /// where it should be for the last frame's placement (for tests).
    pub fn probe(self: *const WebView) ?[2]embed.Probe {
        const page = self.page orelse return null;
        const now = embed.probe(page) orelse return null;
        return .{ now, if (self.shown) |p| embed.expected(p) else .{} };
    }

    /// Where the platform has the page's cover now, read back from its
    /// views, and where it should be for the last frame (for tests).
    pub fn probeCover(self: *const WebView) ?[2]CoverProbe {
        const page = self.page orelse return null;
        const now = embed.probeCover(page) orelse return null;
        return .{ now, if (self.cover_image) |img| embed.expectedCover(img) else .{} };
    }

    /// Whether the cover's opaque pixels are those of the window's last
    /// frame there, drawn whole on the CPU (for tests).
    pub fn coverMatchesFrame(self: *const WebView) bool {
        const c = self.ctx orelse return false;
        const img = self.cover_image orelse return false;
        const l = c.web orelse return false;
        const pw: usize = @intFromFloat(@round(c.size.w * c.scale));
        const ph: usize = @intFromFloat(@round(c.size.h * c.scale));
        const bytes = c.gpa.alloc(u8, pw * ph * 4) catch return false;
        defer c.gpa.free(bytes);
        const m = maskOf(c) orelse return false;
        defer m.free(c.gpa);
        @import("raster.zig").draw(.{ .bytes = bytes, .width = pw, .height = ph }, l.frame, m.mask, c.text.images.pictures(), c.scale, c.theme.background);
        return cover_mod.matches(img, bytes, pw);
    }

    /// Clicks the cover at `x`, `y` (points of the window) as the
    /// platform's pointer would: native UI gets it (for tests). False
    /// without a cover there.
    pub fn clickCover(self: *const WebView, x: f32, y: f32) bool {
        const page = self.page orelse return false;
        return embed.clickCover(page, x, y);
    }

    /// The page took the keyboard (clicked): native UI's focus is the web view's.
    pub fn tookFocus(self: *WebView) void {
        const c = self.ctx orelse return;
        c.focus = self.id;
        c.focus_visible = false;
        self.focused = true;
    }
};

pub const Options = struct {
    /// The page's, as a window's (read when the page is made).
    page: PageOptions = .{},
    width: types.Length = .fill,
    height: types.Length = .fill,
    grow: f32 = 0,
    min_width: f32 = 0,
    min_height: f32 = 0,
    /// Around the page, in the box's background and border.
    padding: types.Edges = .{},
    background: ?types.Color = null,
    border: ?types.Color = null,
    border_width: f32 = 1,
    radius: f32 = 0,
    key: ?[]const u8 = null,
};

/// Shows `state`'s web view in a box (as large as the room it is given
/// by default): its page fills the content box. Focusable: Tab gives the
/// page the keyboard.
pub fn webView(c: *Context, state: *WebView, opts: Options) Interaction {
    const index = c.leaf(.{
        .width = opts.width,
        .height = opts.height,
        .grow = opts.grow,
        .min_width = opts.min_width,
        .min_height = opts.min_height,
        .padding = opts.padding,
        .background = opts.background,
        .border = opts.border,
        .border_width = opts.border_width,
        .radius = opts.radius,
    }, .none, opts.key);
    const it = c.interact(index, .{ .focusable = true });
    state.options = opts.page;
    state.ctx = c;
    state.id = it.id;
    state.node = index;
    state.painted_from = null;
    const l = list(c) orelse return it;
    l.built.append(c.gpa, state) catch {};
    return it;
}

/// The web views a context's frames show.
pub const List = struct {
    /// Built by the frame being made.
    built: std.ArrayList(*WebView) = .empty,
    /// Shown by the last frame.
    shown: std.ArrayList(*WebView) = .empty,
    place: *const fn (c: *Context, frame: []const gpu.Instance) void,
    /// The painter painted box `index`, whose children come from
    /// instance `at` on (`paint.zig`).
    mark: *const fn (l: *List, index: u32, at: usize) void,
    /// The last frame's instances (until the next frame).
    frame: []const gpu.Instance = &.{},

    pub fn destroy(l: *List, gpa: std.mem.Allocator) void {
        for (l.shown.items) |v| v.dropCover();
        l.built.deinit(gpa);
        l.shown.deinit(gpa);
        gpa.destroy(l);
    }
};

fn list(c: *Context) ?*List {
    if (c.web) |l| return l;
    const l = c.gpa.create(List) catch return null;
    l.* = .{ .place = placeAll, .mark = markAll };
    c.web = l;
    return l;
}

fn markAll(l: *List, index: u32, at: usize) void {
    for (l.built.items) |v| if (v.node == index) {
        v.painted_from = at;
    };
}

/// After a frame: those it built go where it shows them, with what it
/// painted over them; those it no longer builds hide.
fn placeAll(c: *Context, frame: []const gpu.Instance) void {
    const l = c.web.?;
    l.frame = frame;
    for (l.built.items, 0..) |v, i| {
        // Built twice (an exit transition): the first shows.
        if (std.mem.indexOfScalar(*WebView, l.built.items[0..i], v) != null) continue;
        place(c, v, frame);
    }
    for (l.shown.items) |v| if (std.mem.indexOfScalar(*WebView, l.built.items, v) == null) hide(v);
    l.shown.clearRetainingCapacity();
    l.shown.appendSlice(c.gpa, l.built.items) catch {};
}

fn hide(v: *WebView) void {
    v.shown = null;
    v.cover = null;
    v.dropCover();
    if (v.page) |p| embed.hide(p);
    if (v.focused) v.focused = false;
}

/// Where the frame shows the web view of `v`, if any of it shows.
pub fn placement(c: *Context, v: *const WebView) ?Placement {
    if (v.node >= c.nodes.items.len) return null;
    const n = c.node(v.node);
    if (n.id != v.id) return null;
    var inner = n.rect.inset(n.style.padding);
    if (n.style.border != null) inner = inner.inset(.all(n.style.border_width));
    const s = c.scale;
    const x0 = @round(inner.x * s) / s;
    const y0 = @round(inner.y * s) / s;
    const frame: types.Rect = .{ .x = x0, .y = y0, .w = @round((inner.x + inner.w) * s) / s - x0, .h = @round((inner.y + inner.h) * s) / s - y0 };
    if (frame.w <= 0 or frame.h <= 0) return null;
    // Cut by the window and the boxes around it that clip; faded out, none shows.
    var clip: types.Rect = .{ .w = c.size.w, .h = c.size.h };
    var opacity = n.style.opacity;
    var at = n.parent;
    while (at != none) {
        const a = c.node(at);
        if (a.style.clip or a.style.scroll) clip = clip.intersect(a.rect);
        opacity *= a.style.opacity;
        at = a.parent;
    }
    if (opacity <= 0.001) return null;
    const visible = frame.intersect(clip);
    if (visible.w <= 0 or visible.h <= 0) return null;
    return .{ .frame = frame, .clip = visible, .scale = s };
}

/// The glyph atlas as the CPU renderer reads it: read back from the GPU
/// where it lives there (macOS).
const Mask = struct {
    mask: @import("raster.zig").Mask,
    owned: ?[]u8 = null,

    fn free(m: Mask, gpa: std.mem.Allocator) void {
        if (m.owned) |b| gpa.free(b);
    }
};

fn maskOf(c: *Context) ?Mask {
    const a = &c.text.atlas;
    if (@hasDecl(@TypeOf(a.*), "mask")) return .{ .mask = a.mask() };
    const bytes = a.read(c.gpa) catch return null;
    return .{ .mask = .{ .pixels = bytes, .size = a.size }, .owned = bytes };
}

fn generationOf(c: *Context) u64 {
    const a = &c.text.atlas;
    const g: u64 = if (@hasField(@TypeOf(a.*), "generation")) a.generation else 0;
    return g *% 31 +% c.text.images.generation;
}

/// The pixels of what the last frame painted over `v`'s page, drawn alone
/// over transparency, where the platform places its cover (`v.cover`, in
/// device pixels); null when nothing is over it. Drawn again only when
/// what is over it changed (`cover_hash`).
pub fn coverImage(c: *Context, v: *WebView) ?cover_mod.Image {
    const r = v.cover orelse return null;
    const p = v.shown orelse return null;
    const from = v.painted_from orelse return null;
    const frame = (c.web orelse return null).frame;
    const area = cover_mod.pixelArea(r, p.clip, p.scale, embed.unit(p.scale)) orelse return null;
    const h = cover_mod.hashOf(frame, from, area, p.scale, generationOf(c));
    if (v.cover_image != null and h == v.cover_hash) return v.cover_image;
    const m = maskOf(c) orelse return null;
    defer m.free(c.gpa);
    v.cover_image = cover_mod.render(c.gpa, &v.cover_px, frame, from, area, m.mask, c.text.images.pictures(), p.scale) catch return null;
    v.cover_hash = h;
    return v.cover_image;
}

fn place(c: *Context, v: *WebView, frame: []const gpu.Instance) void {
    const p = placement(c, v) orelse return hide(v);
    v.shown = p;
    // What the frame painted over it: everything after its box there.
    v.cover = if (v.painted_from) |from| cover_mod.overlap(frame, from, p.clip) else null;
    // Tab came to it: the page takes the keyboard, at its first element
    // (its last with Shift).
    const focused = c.focus == v.id;
    const entered = focused and !v.focused;
    v.focused = focused;
    const host = c.host orelse return;
    if (v.page == null and !v.failed) {
        v.page = embed.create(host, v.options, v);
        if (v.page == null) v.failed = true;
    }
    const page = v.page orelse return;
    embed.place(page, p);
    // Nothing over it: no cover, nothing drawn; the same over it: nothing
    // drawn again.
    const had = v.cover_image != null;
    const before = v.cover_hash;
    const img = if (v.cover != null) coverImage(c, v) else null;
    if (img == null) {
        if (had) {
            v.dropCover();
            embed.cover(page, null);
        }
    } else if (!had or v.cover_hash != before) embed.cover(page, img);
    if (entered) embed.focus(page, c.input.shift);
}
