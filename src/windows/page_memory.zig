//! WebView2's inactive memory target keeps scripts and connections running.
const com = @import("com.zig");
const gdi = @import("gdi.zig");

// Microsoft.Web.WebView2 1.0.1823.32, ICoreWebView2_19 (WebView2.h).
pub const iid = com.GUID.parse("6921f954-79b0-437f-a997-c85811897c68");
const put_target = 120;

pub const Level = enum(i32) { normal = 0, low = 1 };

pub const State = struct {
    applied: ?Level = null,
    unsupported: bool = false,

    pub fn apply(s: *State, webview: ?com.Object, level: Level) void {
        if (s.unsupported) return;
        if (s.applied) |previous| if (previous == level) return;
        const wv = webview orelse return;
        const newer = com.query(wv, &iid) orelse {
            s.unsupported = true;
            return;
        };
        defer com.release(newer);
        if (!com.failed(com.call(newer, put_target, .{@backingInt(level)}))) s.applied = level;
    }
};

pub fn levelFor(visible: bool, minimized: bool, embedded_shown: bool) Level {
    return if (visible and !minimized and embedded_shown) .normal else .low;
}

fn applyPage(page: anytype, visible: bool, minimized: bool) void {
    const level = levelFor(visible, minimized, if (page.embed) |e| e.shown else true);
    // Embedded controllers keep their existing placement/visibility contract.
    if (page.embed == null) page.visibility.apply(page.controller, visible and !minimized);
    // Trim after the document loads; restore normal promptly even during a load.
    if (level == .low and !page.dom_ready) return;
    page.memory_target.apply(page.webview, level);
}

pub fn refresh(page: anytype) void {
    const window = page.window;
    const minimized = if (window.hwnd) |h| gdi.IsIconic(h) != 0 else false;
    applyPage(page, window.isVisible(), minimized);
}

pub fn windowChanged(window: anytype, visible: bool, minimized: bool) void {
    if (window.page) |page| applyPage(page, visible, minimized);
    for (window.web_views.items) |page| applyPage(page, visible, minimized);
}
