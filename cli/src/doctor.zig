//! `myzig doctor`: checks the machine for what building and running myzig
//! apps needs: Zig, the platform's SDK and libraries (the macOS SDK; GTK 3
//! and WebKitGTK on Linux; the WebView2 Runtime on Windows), and the tools
//! of optional features.
const std = @import("std");
const builtin = @import("builtin");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const package = @import("package.zig");
const Ctx = fsx.Ctx;

const Report = struct {
    ctx: Ctx,
    ok: bool = true,

    fn check(r: *Report, name: []const u8, good: bool, detail: []const u8) void {
        if (!good) r.ok = false;
        fsx.out(r.ctx.io, "{s} {s: <10} {s}\n", .{ if (good) "\x1b[32m✓\x1b[0m" else "\x1b[31m✗\x1b[0m", name, detail });
    }

    fn optional(r: *Report, name: []const u8, found: ?[]const u8, feature: []const u8) void {
        if (found) |d| {
            fsx.out(r.ctx.io, "\x1b[32m✓\x1b[0m {s: <10} {s}\n", .{ name, d });
        } else fsx.out(r.ctx.io, "- {s: <10} not found (optional: {s})\n", .{ name, feature });
    }
};

/// Whether a Zig version ("0.17.0", "0.18.0-dev.349+d924f83bf") is at
/// least 0.17.
pub fn zigSupported(v: []const u8) bool {
    var it = std.mem.splitScalar(u8, v[0 .. std.mem.indexOfAny(u8, v, "-+") orelse v.len], '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    return major > 0 or minor >= 17;
}

pub fn run(ctx: Ctx) !void {
    var r: Report = .{ .ctx = ctx };
    if (proc.firstLine(ctx, &.{ ctx.zig, "version" })) |v| {
        r.check("zig", zigSupported(v), try ctx.fmt("{s}{s}", .{ v, if (zigSupported(v)) "" else " (myzig needs 0.17 or later)" }));
    } else r.check("zig", false, "not found: install Zig 0.17 (https://ziglang.org/download), or set ZIG");

    switch (builtin.os.tag) {
        .macos => {
            const v = proc.firstLine(ctx, &.{ "sw_vers", "-productVersion" }) orelse "";
            const major = std.fmt.parseInt(u32, v[0 .. std.mem.indexOfScalar(u8, v, '.') orelse v.len], 10) catch 0;
            r.check("macOS", major >= 12, try ctx.fmt("{s} (WKWebView, Metal; macOS 12 or later)", .{v}));
            const sdk = proc.firstLine(ctx, &.{ "xcrun", "--show-sdk-path" });
            r.check("sdk", sdk != null, sdk orelse "no macOS SDK: install the Command Line Tools (xcode-select --install)");
            r.optional("hdiutil", proc.which(ctx, "hdiutil"), "disk images in myzig build");
        },
        .linux => {
            const gtk = findLibrary(ctx, &.{"libgtk-3.so.0"});
            r.check("gtk", gtk != null, gtk orelse "GTK 3 not found: install libgtk-3-0 (Debian, Ubuntu) or gtk3 (Fedora)");
            const webkit = findLibrary(ctx, &.{ "libwebkit2gtk-4.1.so.0", "libwebkit2gtk-4.0.so.37" });
            r.check("webkit", webkit != null, webkit orelse "WebKitGTK not found (pages need it): install libwebkit2gtk-4.1-0 (Debian, Ubuntu) or webkit2gtk4.1 (Fedora)");
        },
        .windows => {
            const wv = @import("doctor_windows.zig").webview2(ctx);
            r.check("webview2", wv != null, wv orelse "the WebView2 Runtime is not installed (pages need it): https://go.microsoft.com/fwlink/p/?LinkId=2124703");
            fsx.out(ctx.io, "\x1b[32m✓\x1b[0m {s: <10} not needed: Zig links Windows apps itself\n", .{"sdk"});
        },
        else => r.check(@tagName(builtin.os.tag), false, "myzig has no backend for this system"),
    }

    r.optional("makensis", package.makensisPath(ctx), "the Windows installer, https://nsis.sourceforge.io");
    r.optional("bun", proc.which(ctx, "bun"), "frontends with a dev server and a build, https://bun.sh");
    r.optional("git", proc.which(ctx, "git"), "fetching myzig in myzig init");
    if (!r.ok) return error.ChecksFailed;
}

/// A shared library's path in the usual directories, or as ldconfig
/// knows it.
fn findLibrary(ctx: Ctx, names: []const []const u8) ?[]const u8 {
    const dirs = [_][]const u8{ "/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu", "/usr/lib64", "/usr/lib", "/lib/x86_64-linux-gnu", "/lib/aarch64-linux-gnu", "/lib64", "/usr/local/lib" };
    for (names) |n| for (dirs) |d| {
        const p = ctx.join(&.{ d, n }) catch continue;
        if (fsx.exists(ctx.io, p)) return p;
    };
    const r = proc.capture(ctx, &.{ "ldconfig", "-p" }, null) catch return null;
    for (names) |n| if (std.mem.indexOf(u8, r.stdout, n)) |at| {
        const end = std.mem.indexOfScalarPos(u8, r.stdout, at, '\n') orelse r.stdout.len;
        const line = r.stdout[at..end];
        return if (std.mem.indexOf(u8, line, "=> ")) |i| line[i + 3 ..] else n;
    };
    return null;
}

test zigSupported {
    try std.testing.expect(zigSupported("0.17.0"));
    try std.testing.expect(zigSupported("0.18.0-dev.349+d924f83bf"));
    try std.testing.expect(zigSupported("1.0.0"));
    try std.testing.expect(!zigSupported("0.15.2"));
    try std.testing.expect(!zigSupported("garbage"));
}
