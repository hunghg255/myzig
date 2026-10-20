//! `myzig init <dir>`: a new app, a Zig package depending on myzig, that
//! builds and runs with `zig build run` (after mygo's init.go).
const std = @import("std");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const templates = @import("templates.zig");
const appbuild = @import("appbuild.zig");
const assets = @import("assets.zig");
const Ctx = fsx.Ctx;

/// Where apps get myzig unless --myzig names another source: the release
/// of this CLI's version, which it was made with.
pub const default_source = "git+https://github.com/hunghg255/myzig#v" ++ @import("build_options").version;

pub const Options = struct {
    dir: []const u8,
    template: templates.Template = .native,
    name: []const u8 = "",
    /// A checkout of myzig (a path dependency) or a URL for `zig fetch`.
    myzig: []const u8 = "",
    /// Don't build the web template to write its client.
    skip_generate: bool = false,
};

/// The package name build.zig.zon wants: an identifier of at most 32
/// characters.
pub fn packageName(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    var s = try config.slug(gpa, name, '_');
    if (s.len == 0) s = try gpa.dupe(u8, "app");
    if (std.ascii.isDigit(s[0])) s = try std.fmt.allocPrint(gpa, "app_{s}", .{s});
    return s[0..@min(s.len, 32)];
}

/// A fingerprint of the package: a random id and the name's checksum.
pub fn fingerprint(io: std.Io, package: []const u8) u64 {
    var id: u32 = 0;
    while (id == 0 or id == 0xffffffff) {
        var b: [4]u8 = undefined;
        io.random(&b);
        id = std.mem.readInt(u32, &b, .little);
    }
    return @as(u64, std.hash.Crc32.hash(package)) << 32 | id;
}

/// `s` for a Zig string literal (names hold no quotes or control
/// characters: the configuration refuses them).
fn zigString(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, s, "\\", "\\\\");
}

fn htmlText(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    try @import("plist.zig").escape(&w.writer, s);
    return w.toOwnedSlice();
}

pub fn run(ctx: Ctx, o: Options) !void {
    if (fsx.exists(ctx.io, o.dir)) {
        var d = try std.Io.Dir.cwd().openDir(ctx.io, o.dir, .{ .iterate = true });
        defer d.close(ctx.io);
        var it = d.iterate();
        if (try it.next(ctx.io) != null) {
            std.debug.print("error: {s} is not empty\n", .{o.dir});
            return error.NotEmpty;
        }
    }
    try fsx.makeDir(ctx.io, o.dir);
    const root = try fsx.absolute(ctx, o.dir);
    const name = if (o.name.len > 0) o.name else std.fs.path.basename(root);
    const package = try packageName(ctx.gpa, name);
    const slug = try config.slug(ctx.gpa, name, 0);
    const identifier = try ctx.fmt("com.example.{s}", .{if (slug.len == 0) "app" else slug});
    try config.validate(ctx.gpa, .{ .root = root, .name = name, .identifier = identifier, .version = "0.1.0" });

    // myzig: a path dependency on a checkout, else fetched (a URL, or a
    // checkout on another drive).
    var source = o.myzig;
    if (source.len == 0) source = ctx.env.get("MYZIG_ROOT") orelse default_source;
    var dependencies: []const u8 = ".{}";
    var fetch: ?[]const u8 = source;
    if (std.mem.indexOf(u8, source, "://") == null) {
        if (!fsx.isFile(ctx.io, try ctx.join(&.{ source, "src", "myzig.zig" }))) {
            std.debug.print("error: {s} is not a checkout of myzig (no src/myzig.zig)\n", .{source});
            return error.NotMyzig;
        }
        const abs = try fsx.absolute(ctx, source);
        if (try fsx.relative(ctx.gpa, root, abs)) |rel| {
            dependencies = try ctx.fmt(".{{\n        .myzig = .{{ .path = \"{s}\" }},\n    }}", .{rel});
            fetch = null;
        } else fetch = abs;
    }

    const name_zig = try zigString(ctx.gpa, name);
    const web = o.template == .web;
    const vars = [_][2][]const u8{
        .{ "name", name },
        .{ "name_zig", name_zig },
        .{ "name_html", try htmlText(ctx.gpa, name) },
        .{ "identifier", identifier },
        .{ "package", package },
        .{ "executable", package },
        .{ "fingerprint", try ctx.fmt("0x{x:0>16}", .{fingerprint(ctx.io, package)}) },
        .{ "dependencies", dependencies },
        .{ "frontend_option", if (web) templates.frontend_option else "" },
        .{ "frontend_import", if (web) templates.frontend_import else "" },
    };
    const files = [_]struct { []const u8, []const u8, bool }{
        .{ "build.zig", templates.build_zig, true },
        .{ "build.zig.zon", templates.build_zig_zon, true },
        .{ "myzig.zon", templates.myzig_zon_native, !web },
        .{ "myzig.zon", templates.myzig_zon_web, web },
        .{ "src/main.zig", templates.main_native, !web },
        .{ "src/main.zig", templates.main_web, web },
        .{ "frontend/index.html", templates.index_html, web },
        .{ "frontend/main.js", templates.main_js, web },
        .{ "frontend/style.css", templates.style_css, web },
        .{ ".gitignore", templates.gitignore, true },
    };
    for (files) |f| if (f[2]) {
        try fsx.write(ctx.io, try ctx.join(&.{ root, f[0] }), try templates.fill(ctx.gpa, f[1], &vars));
    };
    try fsx.write(ctx.io, try ctx.join(&.{ root, "resources", "icon.png" }), try templates.defaultIcon(ctx.gpa));
    if (web) _ = try assets.write(ctx, try ctx.join(&.{ root, "frontend" }));
    ctx.log("Created {s} ({t}) in {s}", .{ name, o.template, root });

    if (fetch) |src| {
        ctx.log("Fetching myzig from {s}", .{src});
        try proc.check(ctx, &.{ ctx.zig, "fetch", "--save=myzig", src }, root);
    }
    if (web and !o.skip_generate) {
        const c = try config.load(ctx, root);
        try appbuild.generate(ctx, c);
    }
    ctx.log(
        \\
        \\Next:
        \\  cd {s}
        \\  myzig dev        # run it, rebuilding as you edit
        \\  zig build run    # or with Zig alone
        \\  myzig build      # the release and its package
    , .{o.dir});
}

test packageName {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings("my_app", try packageName(gpa, "My App!"));
    try std.testing.expectEqualStrings("app_2048", try packageName(gpa, "2048"));
    try std.testing.expectEqualStrings("app", try packageName(gpa, "???"));
    try std.testing.expectEqual(@as(usize, 32), (try packageName(gpa, "abcdefghijklmnopqrstuvwxyz0123456789")).len);
}

test fingerprint {
    const f = fingerprint(std.testing.io, "my_app");
    try std.testing.expectEqual(std.hash.Crc32.hash("my_app"), @as(u32, @intCast(f >> 32)));
    try std.testing.expect(@as(u32, @truncate(f)) != 0);
}
