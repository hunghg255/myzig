//! Tray icons' options, the same on every platform.

pub fn Options(comptime MenuItem: type, comptime Tray: type) type {
    return struct {
        /// Names the icon across launches, unique among the app's icons.
        /// On macOS, where the user moves menu bar items by dragging them
        /// with ⌘ held, the icon goes back where the user put it (the
        /// status item's autosave name); without one a new icon goes left
        /// of those already there. On Windows it numbers the icon, which
        /// keeps whether the user shows it on the taskbar or in its
        /// overflow whatever order the app makes its icons in. Nothing on
        /// Linux, whose panels place icons themselves.
        id: []const u8 = "",
        /// Text shown next to the icon (macOS's menu bar, Linux's panels
        /// that show labels); the tooltip elsewhere when it has none.
        title: []const u8 = "",
        /// The name of an SF Symbol ("star.fill"), drawn as a template image
        /// that follows the menu bar's appearance (macOS).
        symbol: []const u8 = "",
        /// The icon as a PNG file's bytes (Windows: 16 or 32 pixels square
        /// suit the notification area); the app's icon when empty.
        icon: []const u8 = "",
        /// The icon is black and transparent: macOS tints it to match the
        /// menu bar, Windows shows it white on a dark taskbar.
        template: bool = false,
        tooltip: []const u8 = "",
        /// Shown on a right click (Windows), on any click elsewhere.
        menu: []const MenuItem = &.{},
        /// A left click (Windows, and macOS when there is no menu).
        on_click: ?Click(Tray) = null,
        /// The bar the icon shows on turned dark or light (`Tray.dark`),
        /// on the main thread: an icon in color draws itself for it again
        /// (`setIcon`). A template icon follows the bar by itself.
        on_appearance: ?Click(Tray) = null,
    };
}

pub fn Click(comptime Tray: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, tray: *Tray) void,

        pub fn of(ptr: anytype, comptime func: fn (@TypeOf(ptr), *Tray) void) @This() {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .func = struct {
                fn call(c: *anyopaque, t: *Tray) void {
                    func(@as(P, @ptrCast(@alignCast(c))), t);
                }
            }.call };
        }
    };
}
