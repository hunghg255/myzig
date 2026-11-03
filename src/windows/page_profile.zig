//! A headless WebView2 profile belongs to the run's temporary directories.
const std = @import("std");
const headless = @import("../headless.zig");

pub fn path(app: anytype, buf: []u8) ![]const u8 {
    if (headless.active()) {
        const cache = try @import("desktop.zig").path(app.gpa, .cache, app.options.name);
        defer app.gpa.free(cache);
        return std.fmt.bufPrint(buf, "{s}\\WebView2", .{cache});
    }
    const base = app.environ.get("LOCALAPPDATA") orelse app.environ.get("TEMP") orelse ".";
    return std.fmt.bufPrint(buf, "{s}\\{s}\\WebView2", .{ base, app.options.name });
}

test "headless WebView2 profile stays in its temporary run, even with LOCALAPPDATA set" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(temp);
    headless.begin(t.io, temp);
    defer headless.end(t.io);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("LOCALAPPDATA", "C:\\must-not-use-user-profile");
    const app = .{ .gpa = t.allocator, .environ = &env, .options = .{ .name = "ProfileTest" } };
    var buf: [2048]u8 = undefined;
    const actual = try path(app, &buf);
    try t.expect(std.mem.startsWith(u8, actual, temp));
    try t.expect(std.mem.endsWith(u8, actual, "\\ProfileTest\\cache\\WebView2"));
    var tiny: [1]u8 = undefined;
    try t.expectError(error.NoSpaceLeft, path(app, &tiny));
}

const com = @import("com.zig");
// Microsoft.Web.WebView2 1.0.1072.54: ICoreWebView2_13's get_Profile and
// ICoreWebView2Profile's put_PreferredColorScheme (WebView2.h).
const iid_webview13 = com.GUID.parse("f75f09a8-667e-4983-88d6-c8773f315e84");
const wv13_get_profile = 105;
const profile_put_color_scheme = 9;

/// Makes the pages' prefers-color-scheme follow an appearance the app
/// forced (`App.setAppearance`); `.system` leaves it to WebView2. The
/// profile's scheme holds from a document's start. Runtimes without it
/// keep the system's.
pub fn applyColorScheme(webview: ?com.Object) void {
    const wv = webview orelse return;
    const wv13 = com.query(wv, &iid_webview13) orelse return;
    defer com.release(wv13);
    var profile: ?com.Object = null;
    if (com.failed(com.call(wv13, wv13_get_profile, .{&profile}))) return;
    const p = profile orelse return;
    defer com.release(p);
    _ = com.call(p, profile_put_color_scheme, .{colorScheme(@import("../appearance.zig").chosen)});
}

/// COREWEBVIEW2_PREFERRED_COLOR_SCHEME: auto, light, dark.
fn colorScheme(a: @import("../appearance.zig").Appearance) i32 {
    return switch (a) {
        .system => 0,
        .light => 1,
        .dark => 2,
    };
}

test "a forced appearance is WebView2's preferred color scheme" {
    try std.testing.expectEqual(@as(i32, 0), colorScheme(.system));
    try std.testing.expectEqual(@as(i32, 2), colorScheme(.dark));
}
