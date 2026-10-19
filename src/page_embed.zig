//! Pages inside native UI (`ui.webView`), on each platform: made in the
//! window `host` (the platform's `*Window`), placed in device pixels where
//! a frame shows them, hidden, given the keyboard, closed; and their
//! covers, which show what native UI paints over them
//! (`page_embed_cover.zig`). Reached only by `ui/webview.zig`: apps
//! without web views link none of it.
const builtin = @import("builtin");
const PageOptions = @import("window_types.zig").PageOptions;
const Placement = @import("ui/webview.zig").Placement;
const WebView = @import("ui/webview.zig").WebView;
const Image = @import("page_embed_cover.zig").Image;

const impl = switch (builtin.os.tag) {
    .windows => @import("windows/page_embed.zig"),
    .linux => @import("linux/page_embed.zig"),
    .macos => @import("page_embed_mac.zig"),
    else => none,
};

pub const Page = impl.Page;

/// Platforms without web views in native UI.
const none = struct {
    pub const Page = opaque {};
    pub fn create(_: *anyopaque, _: PageOptions, _: *WebView) ?*none.Page {
        return null;
    }
    pub fn place(_: *none.Page, _: Placement) void {}
    pub fn hide(_: *none.Page) void {}
    pub fn focus(_: *none.Page, _: bool) void {}
    pub fn destroy(_: *none.Page) void {}
    pub fn probe(_: *none.Page) ?Probe {
        return null;
    }
    pub fn expected(_: Placement) Probe {
        return .{};
    }
    pub fn unit(_: f32) f32 {
        return 1;
    }
    pub fn cover(_: *none.Page, _: ?Image) void {}
    pub fn probeCover(_: *none.Page) ?CoverProbe {
        return null;
    }
    pub fn expectedCover(_: Image) CoverProbe {
        return .{};
    }
    pub fn clickCover(_: *none.Page, _: f32, _: f32) bool {
        return false;
    }
};

/// A page in `host` for the web view `view`, or null when the platform
/// cannot make one (no WebKitGTK, a headless window).
pub fn create(host: *anyopaque, options: PageOptions, view: *WebView) ?*Page {
    return impl.create(host, options, view);
}

/// Shows the page at `p.frame`, cut to `p.clip`.
pub fn place(page: *Page, p: Placement) void {
    impl.place(page, p);
}

/// Hides the page, and its cover.
pub fn hide(page: *Page) void {
    impl.hide(page);
}

/// Gives the page the keyboard, at its first element (its last: `back`).
pub fn focus(page: *Page, back: bool) void {
    impl.focus(page, back);
}

pub fn destroy(page: *Page) void {
    impl.destroy(page);
}

/// Where the platform has an embedded page, in its units (pixels on
/// Windows, points elsewhere): the clip in the window as x, y, width,
/// height, and the page in the clip. For tests.
pub const Probe = struct {
    clip: [4]i32 = .{ 0, 0, 0, 0 },
    page: [4]i32 = .{ 0, 0, 0, 0 },
    shown: bool = false,
};

/// Where the platform has `page` now, read back from its views.
pub fn probe(page: *Page) ?Probe {
    return impl.probe(page);
}

/// Where the platform puts a page placed at `p`.
pub fn expected(p: Placement) Probe {
    return impl.expected(p);
}

/// How many device pixels at `scale` make the unit the platform places
/// views in (a pixel on Windows, a point elsewhere): covers fall on whole
/// units.
pub fn unit(scale: f32) f32 {
    return impl.unit(scale);
}

/// Shows `img` over the page, in a view above it that takes the pointer
/// where the pixels are opaque; null hides it.
pub fn cover(page: *Page, img: ?Image) void {
    impl.cover(page, img);
}

/// Where the platform has a page's cover, in its units as `Probe`: its
/// rectangle in the window, and whether it shows. For tests.
pub const CoverProbe = struct {
    rect: [4]i32 = .{ 0, 0, 0, 0 },
    shown: bool = false,
};

/// Where the platform has the cover of `page` now, read back from its views.
pub fn probeCover(page: *Page) ?CoverProbe {
    return impl.probeCover(page);
}

/// Where the platform puts a cover showing `img`.
pub fn expectedCover(img: Image) CoverProbe {
    return impl.expectedCover(img);
}

/// Presses and releases the left button on the cover of `page` at `x`, `y`
/// (points of the window), as the platform delivers a click there; false
/// without a cover taking it. For tests.
pub fn clickCover(page: *Page, x: f32, y: f32) bool {
    return impl.clickCover(page, x, y);
}
