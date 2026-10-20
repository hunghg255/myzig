//! The configuration of an app: `myzig.zon` (or `myzig.json`) at its root,
//! after mygo's Config (cmd/mygo/config.go). Every field is optional:
//!
//!     .{
//!         .name = "My App",
//!         .identifier = "com.example.myapp",
//!         .version = "1.2.0",              // default: build.zig.zon's
//!         .copyright = "© 2026 Example Inc.",
//!         .icon = "resources/icon.png",    // default when it exists
//!         .executable = "my_app",          // the artifact build.zig installs
//!         .frontend = "frontend",          // the web frontend's sources
//!         .frontend_dist = "frontend",     // what build.zig embeds
//!         .dev_url = "http://localhost:5173",
//!         .dev_command = "bun run dev",
//!         .build_command = "bun run build",
//!         .out = "dist",
//!         .resources = .{"third_party/licenses"},
//!         .url_schemes = .{"myapp"},
//!         .file_associations = .{.{ .ext = .{"md"}, .name = "Markdown Document" }},
//!         .watch = .{"assets"},            // more for `myzig dev` to watch
//!         .macos = .{ .minimum_system_version = "12.0", .signing_identity = "-" },
//!         .windows = .{ .installer = true },
//!         .linux = .{ .maintainer = "Jane <jane@example.com>", .command = "my-app" },
//!         .updates = .{ .public_key = "…", .github = "you/my-app" }, // updates.zig
//!     }
const std = @import("std");
const zon = @import("zon.zig");
const fsx = @import("fsx.zig");
const updates = @import("updates.zig");
const Ctx = fsx.Ctx;

pub const zon_file = "myzig.zon";
pub const json_file = "myzig.json";

pub const FileAssociation = struct {
    ext: []const []const u8,
    name: []const u8 = "",
    mime_type: []const u8 = "",
    /// "Editor" (the default) or "Viewer", on macOS.
    role: []const u8 = "Editor",
};

pub const MacOS = struct {
    minimum_system_version: []const u8 = "12.0",
    /// "-" signs ad hoc (runs on the Mac that built it).
    signing_identity: []const u8 = "-",
    entitlements: []const u8 = "",
    /// Embedded as Contents/embedded.provisionprofile before signing: it
    /// must authorize the app's identifier and entitlements and match its
    /// signing identity; ad-hoc signing cannot use one.
    provisioning_profile: []const u8 = "",
    dmg_title: []const u8 = "",
    /// Keys added to Info.plist, replacing myzig's.
    info_plist: ?zon.Value = null,
};

pub const Windows = struct {
    /// Makes an NSIS installer when makensis is found.
    installer: bool = true,
    /// Arguments the uninstaller runs the app with, and waits for, before
    /// it takes the files away: for the app to undo what it set up itself
    /// (a command on the PATH, File Explorer's menus). "" for none.
    uninstall_run: []const u8 = "",
    /// Folders of the app's data (NSIS paths, as `$APPDATA\\MyApp`) the
    /// uninstaller offers to delete too, asking first; silent
    /// uninstalls keep them.
    uninstall_data: []const []const u8 = &.{},
};

pub const Linux = struct {
    maintainer: []const u8 = "",
    comment: []const u8 = "",
    categories: []const []const u8 = &.{"Utility"},
    depends: []const []const u8 = &.{},
    command: []const u8 = "",
};

pub const Config = struct {
    /// The app's directory, absolute.
    root: []const u8,
    /// The configuration file, "" without one.
    file: []const u8 = "",
    name: []const u8 = "",
    identifier: []const u8 = "",
    version: []const u8 = "",
    copyright: []const u8 = "",
    icon: []const u8 = "",
    executable: []const u8 = "",
    frontend: []const u8 = "",
    frontend_dist: []const u8 = "",
    dev_url: []const u8 = "",
    dev_command: []const u8 = "",
    build_command: []const u8 = "",
    out: []const u8 = "dist",
    resources: []const []const u8 = &.{},
    url_schemes: []const []const u8 = &.{},
    file_associations: []const FileAssociation = &.{},
    watch: []const []const u8 = &.{},
    macos: MacOS = .{},
    windows: Windows = .{},
    linux: Linux = .{},
    /// Signed updates, which the updater plugin installs (`updates.zig`).
    updates: ?updates.Updates = null,

    /// A path of the app, absolute.
    pub fn path(c: Config, gpa: std.mem.Allocator, p: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(p)) return gpa.dupe(u8, p);
        return std.fs.path.join(gpa, &.{ c.root, p });
    }

    /// The MIME type of an association, and whether the app defines it.
    pub fn mimeType(c: Config, gpa: std.mem.Allocator, fa: FileAssociation) !struct { []const u8, bool } {
        if (fa.mime_type.len > 0) return .{ fa.mime_type, false };
        const ext = try std.ascii.allocLowerString(gpa, fa.ext[0]);
        return .{ try std.fmt.allocPrint(gpa, "application/x-{s}-{s}", .{ try slug(gpa, c.executable, '-'), ext }), true };
    }
};

pub const LoadError = error{ConfigInvalid} || std.mem.Allocator.Error;

/// What went wrong, for the message the CLI prints.
pub var message: []const u8 = "";

pub fn invalid(gpa: std.mem.Allocator, comptime f: []const u8, args: anytype) LoadError {
    message = try std.fmt.allocPrint(gpa, f, args);
    return error.ConfigInvalid;
}

/// Reads the configuration of the app in `dir`.
pub fn load(ctx: Ctx, dir: []const u8) !Config {
    if (!fsx.isDir(ctx.io, dir)) return invalid(ctx.gpa, "{s} is not a directory", .{dir});
    const root = try fsx.absolute(ctx, dir);
    const zp = try ctx.join(&.{ root, zon_file });
    const jp = try ctx.join(&.{ root, json_file });
    const has_zon = fsx.exists(ctx.io, zp);
    const has_json = fsx.exists(ctx.io, jp);
    if (has_zon and has_json) return invalid(ctx.gpa, "{s} and {s} both configure the app; keep one", .{ zon_file, json_file });
    var c: Config = .{ .root = root };
    if (has_zon or has_json) {
        c.file = if (has_zon) zon_file else json_file;
        const src = try fsx.read(ctx, if (has_zon) zp else jp);
        const v = try parseSource(ctx.gpa, src, has_json, c.file);
        try decode(ctx.gpa, &c, v);
    }
    try applyDefaults(ctx, &c);
    try validate(ctx.gpa, c);
    return c;
}

/// Parses `src` as ZON or JSON.
pub fn parseSource(gpa: std.mem.Allocator, src: []const u8, json: bool, file: []const u8) LoadError!zon.Value {
    if (json) return zon.parseJson(gpa, src) catch |e| invalid(gpa, "{s}: not JSON ({t})", .{ file, e });
    var d: zon.Diagnostic = .{};
    return zon.parse(gpa, src, &d) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Syntax => invalid(gpa, "{s}:{d}:{d}: {s}", .{ file, d.line, d.column, d.message }),
    };
}

const Fields = []const []const u8;

pub fn checkKeys(gpa: std.mem.Allocator, v: zon.Value, where: []const u8, known: Fields) LoadError!void {
    if (v != .object) return invalid(gpa, "{s} is not a struct of fields", .{where});
    outer: for (v.object) |f| {
        for (known) |k| if (std.mem.eql(u8, k, f.key)) continue :outer;
        return invalid(gpa, "{s} has no field {s}", .{ where, f.key });
    }
}

pub fn str(gpa: std.mem.Allocator, v: zon.Value, key: []const u8, out: *[]const u8) LoadError!void {
    const x = v.get(key) orelse return;
    if (x != .string) return invalid(gpa, "{s} is a string", .{key});
    out.* = x.string;
}

pub fn boolean(gpa: std.mem.Allocator, v: zon.Value, key: []const u8, out: *bool) LoadError!void {
    const x = v.get(key) orelse return;
    if (x != .bool) return invalid(gpa, "{s} is true or false", .{key});
    out.* = x.bool;
}

fn strList(gpa: std.mem.Allocator, v: zon.Value, key: []const u8, out: *[]const []const u8) LoadError!void {
    const x = v.get(key) orelse return;
    // `.{}` is an empty list too.
    if (x == .object and x.object.len == 0) {
        out.* = &.{};
        return;
    }
    if (x != .list) return invalid(gpa, "{s} is a list of strings", .{key});
    const items = try gpa.alloc([]const u8, x.list.len);
    for (x.list, items) |e, *s| {
        if (e != .string) return invalid(gpa, "{s} is a list of strings", .{key});
        s.* = e.string;
    }
    out.* = items;
}

fn decode(gpa: std.mem.Allocator, c: *Config, v: zon.Value) LoadError!void {
    try checkKeys(gpa, v, c.file, &.{ "name", "identifier", "version", "copyright", "icon", "executable", "frontend", "frontend_dist", "dev_url", "dev_command", "build_command", "out", "resources", "url_schemes", "file_associations", "watch", "macos", "windows", "linux", "updates" });
    inline for (.{ "name", "identifier", "version", "copyright", "icon", "executable", "frontend", "frontend_dist", "dev_url", "dev_command", "build_command", "out" }) |k|
        try str(gpa, v, k, &@field(c, k));
    inline for (.{ "resources", "url_schemes", "watch" }) |k| try strList(gpa, v, k, &@field(c, k));
    if (v.get("file_associations")) |fas| {
        const list: []const zon.Value = if (fas == .list) fas.list else if (fas == .object and fas.object.len == 0) &.{} else return invalid(gpa, "file_associations is a list", .{});
        const out = try gpa.alloc(FileAssociation, list.len);
        for (list, out, 0..) |fa, *o, i| {
            const where = try std.fmt.allocPrint(gpa, "file_associations[{d}]", .{i});
            try checkKeys(gpa, fa, where, &.{ "ext", "name", "mime_type", "role" });
            o.* = .{ .ext = &.{} };
            try strList(gpa, fa, "ext", &o.ext);
            try str(gpa, fa, "name", &o.name);
            try str(gpa, fa, "mime_type", &o.mime_type);
            try str(gpa, fa, "role", &o.role);
        }
        c.file_associations = out;
    }
    if (v.get("macos")) |m| {
        try checkKeys(gpa, m, "macos", &.{ "minimum_system_version", "signing_identity", "entitlements", "provisioning_profile", "dmg_title", "info_plist" });
        inline for (.{ "minimum_system_version", "signing_identity", "entitlements", "provisioning_profile", "dmg_title" }) |k| try str(gpa, m, k, &@field(c.macos, k));
        if (m.get("info_plist")) |p| {
            if (p != .object) return invalid(gpa, "macos.info_plist is a struct of keys", .{});
            c.macos.info_plist = p;
        }
    }
    if (v.get("windows")) |w| {
        try checkKeys(gpa, w, "windows", &.{ "installer", "uninstall_run", "uninstall_data" });
        try boolean(gpa, w, "installer", &c.windows.installer);
        try str(gpa, w, "uninstall_run", &c.windows.uninstall_run);
        try strList(gpa, w, "uninstall_data", &c.windows.uninstall_data);
    }
    if (v.get("updates")) |u| c.updates = try updates.decode(gpa, u);
    if (v.get("linux")) |l| {
        try checkKeys(gpa, l, "linux", &.{ "maintainer", "comment", "categories", "depends", "command" });
        inline for (.{ "maintainer", "comment", "command" }) |k| try str(gpa, l, k, &@field(c.linux, k));
        try strList(gpa, l, "categories", &c.linux.categories);
        try strList(gpa, l, "depends", &c.linux.depends);
    }
}

/// `s` in lower case with runs of other characters than letters and
/// digits replaced by `sep` (or dropped when `sep` is 0).
pub fn slug(gpa: std.mem.Allocator, s: []const u8, sep: u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending = false;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (pending and out.items.len > 0 and sep != 0) try out.append(gpa, sep);
            pending = false;
            try out.append(gpa, std.ascii.toLower(ch));
        } else pending = true;
    }
    return out.toOwnedSlice(gpa);
}

/// The `.name` and `.version` of build.zig.zon, where they are.
fn package(ctx: Ctx, root: []const u8) struct { name: []const u8 = "", version: []const u8 = "" } {
    const p = ctx.join(&.{ root, "build.zig.zon" }) catch return .{};
    const src = fsx.read(ctx, p) catch return .{};
    var d: zon.Diagnostic = .{};
    const v = zon.parse(ctx.gpa, src, &d) catch return .{};
    return .{
        .name = if (v.get("name")) |n| (if (n == .string) n.string else "") else "",
        .version = if (v.get("version")) |n| (if (n == .string) n.string else "") else "",
    };
}

fn applyDefaults(ctx: Ctx, c: *Config) !void {
    const pkg = package(ctx, c.root);
    if (c.name.len == 0) c.name = std.fs.path.basename(c.root);
    if (c.executable.len == 0) c.executable = if (pkg.name.len > 0) pkg.name else try slug(ctx.gpa, c.name, '_');
    if (c.executable.len == 0) c.executable = "app";
    if (c.version.len == 0) c.version = if (pkg.version.len > 0) pkg.version else "0.1.0";
    if (c.identifier.len == 0) {
        const s = try slug(ctx.gpa, c.name, 0);
        c.identifier = try ctx.fmt("com.myzig.{s}", .{if (s.len == 0) "app" else s});
    }
    if (c.icon.len == 0) {
        const p = try ctx.join(&.{ c.root, "resources", "icon.png" });
        if (fsx.exists(ctx.io, p)) c.icon = "resources/icon.png";
    }
    if (c.frontend.len == 0 and fsx.isDir(ctx.io, try ctx.join(&.{ c.root, "frontend" }))) c.frontend = "frontend";
    if (c.frontend_dist.len == 0) c.frontend_dist = c.frontend;
    if (c.out.len == 0) c.out = "dist";
    if (c.macos.dmg_title.len == 0) c.macos.dmg_title = c.name;
    if (c.linux.maintainer.len == 0) c.linux.maintainer = c.name;
}

fn validName(s: []const u8, first: []const u8, rest: []const u8) bool {
    if (s.len == 0) return false;
    const okFirst = std.ascii.isAlphabetic(s[0]) or (std.mem.indexOfScalar(u8, first, s[0]) != null);
    if (!okFirst) return false;
    for (s[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, rest, ch) == null) return false;
    return true;
}

pub fn validate(gpa: std.mem.Allocator, c: Config) LoadError!void {
    for (c.file_associations, 0..) |fa, i| {
        if (fa.ext.len == 0) return invalid(gpa, "file_associations[{d}] has no ext", .{i});
        for (fa.ext) |e| if (!validName(e, "0123456789", "_+-"))
            return invalid(gpa, "file_associations[{d}]: \"{s}\" is not a file name extension (without the dot)", .{ i, e });
        if (!std.mem.eql(u8, fa.role, "Editor") and !std.mem.eql(u8, fa.role, "Viewer"))
            return invalid(gpa, "file_associations[{d}].role is Editor or Viewer", .{i});
    }
    for (c.url_schemes) |s| if (!validName(s, "", "+.-"))
        return invalid(gpa, "url_schemes: \"{s}\" is not a URL scheme (a letter, then letters, digits, +, - or .)", .{s});
    if (c.linux.command.len > 0 and !validName(c.linux.command, "0123456789", "._+-"))
        return invalid(gpa, "linux.command \"{s}\" is not a command name", .{c.linux.command});
    if (c.dev_url.len > 0) {
        const ok = (std.mem.startsWith(u8, c.dev_url, "http://") and c.dev_url.len > 7) or
            (std.mem.startsWith(u8, c.dev_url, "https://") and c.dev_url.len > 8);
        if (!ok) return invalid(gpa, "dev_url \"{s}\" is not an http(s) URL", .{c.dev_url});
    }
    for ([_][]const u8{ c.name, c.version, c.identifier }) |v| {
        for (v) |ch| if (ch < ' ' or ch == '"') return invalid(gpa, "\"{s}\" cannot contain quotes or control characters", .{v});
    }
    if (!validName(c.identifier, "", ".-")) return invalid(gpa, "identifier \"{s}\" is not a reverse DNS name, as com.example.myapp", .{c.identifier});
    if (c.updates) |u| try updates.validate(gpa, u);
}

test "defaults and fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var c: Config = .{ .root = "/apps/My Notes", .file = zon_file };
    const v = try parseSource(gpa,
        \\.{
        \\    .version = "1.2.0",
        \\    .url_schemes = .{"notes"},
        \\    .file_associations = .{ .{ .ext = .{ "md", "markdown" }, .name = "Markdown" } },
        \\    .macos = .{ .info_plist = .{ .NSCameraUsageDescription = "Scan" } },
        \\    .linux = .{ .categories = .{ "Office", "Utility" }, .command = "notes" },
        \\}
    , false, zon_file);
    try decode(gpa, &c, v);
    try std.testing.expectEqualStrings("1.2.0", c.version);
    try std.testing.expectEqual(@as(usize, 2), c.file_associations[0].ext.len);
    try std.testing.expectEqualStrings("Editor", c.file_associations[0].role);
    try std.testing.expectEqualStrings("Office", c.linux.categories[0]);
    try std.testing.expect(c.macos.info_plist.?.get("NSCameraUsageDescription") != null);
    c.name = "My Notes";
    c.executable = "my_notes";
    c.identifier = "com.myzig.mynotes";
    try validate(gpa, c);
    const mt = try c.mimeType(gpa, c.file_associations[0]);
    try std.testing.expectEqualStrings("application/x-my-notes-md", mt[0]);
    try std.testing.expect(mt[1]);
}

test "mistakes are named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var c: Config = .{ .root = "/a", .file = zon_file };
    try std.testing.expectError(error.ConfigInvalid, decode(gpa, &c, try parseSource(gpa, ".{ .nmae = \"x\" }", false, zon_file)));
    try std.testing.expectEqualStrings("myzig.zon has no field nmae", message);
    try std.testing.expectError(error.ConfigInvalid, decode(gpa, &c, try parseSource(gpa, ".{ .name = 3 }", false, zon_file)));
    try std.testing.expectError(error.ConfigInvalid, parseSource(gpa, ".{ .name = }", false, zon_file));
    try std.testing.expect(std.mem.startsWith(u8, message, "myzig.zon:1:"));
    c = .{ .root = "/a", .name = "A", .identifier = "com.a", .version = "1", .url_schemes = &.{"1bad"} };
    try std.testing.expectError(error.ConfigInvalid, validate(gpa, c));
    c = .{ .root = "/a", .name = "A", .identifier = "com.a", .version = "1", .dev_url = "localhost:5173" };
    try std.testing.expectError(error.ConfigInvalid, validate(gpa, c));
    c = .{ .root = "/a", .name = "A", .identifier = "com.a", .version = "1", .file_associations = &.{.{ .ext = &.{".md"} }} };
    try std.testing.expectError(error.ConfigInvalid, validate(gpa, c));
}

test "json configuration" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var c: Config = .{ .root = "/a", .file = json_file };
    try decode(gpa, &c, try parseSource(gpa, "{\"name\":\"Hello\",\"dev_url\":\"http://localhost:5173\",\"windows\":{\"installer\":false}}", true, json_file));
    try std.testing.expectEqualStrings("Hello", c.name);
    try std.testing.expect(!c.windows.installer);
}

test slug {
    const s = try slug(std.testing.allocator, "My  Cool-App 2", '_');
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("my_cool_app_2", s);
}
