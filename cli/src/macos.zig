//! macOS packaging (after mygo's bundle.go and dmg.go): the .app bundle
//! with its Info.plist and .icns, universal binaries joined in Zig (no
//! lipo), and on a Mac the signed bundle and a compressed disk image
//! (hdiutil, which ships with macOS) whose Finder window comes from a
//! generated .DS_Store.
const std = @import("std");
const builtin = @import("builtin");
const fsx = @import("fsx.zig");
const plist = @import("plist.zig");
const dsstore = @import("dsstore.zig");
const icon = @import("icon.zig");
const proc = @import("proc.zig");
const Config = @import("config.zig").Config;
const Value = @import("zon.zig").Value;
const Ctx = fsx.Ctx;

pub const bundle_icon = "icon.icns";

/// The Info.plist of the app, whose executable is `executable` and icon
/// (in Resources) `icon_file`, or "" for none.
pub fn infoPlist(gpa: std.mem.Allocator, c: Config, executable: []const u8, icon_file: []const u8) ![]u8 {
    var d: plist.Dict = .{};
    try d.str(gpa, "CFBundleName", c.name);
    try d.str(gpa, "CFBundleDisplayName", c.name);
    try d.str(gpa, "CFBundleIdentifier", c.identifier);
    try d.str(gpa, "CFBundleVersion", c.version);
    try d.str(gpa, "CFBundleShortVersionString", c.version);
    try d.str(gpa, "CFBundleExecutable", executable);
    try d.str(gpa, "CFBundlePackageType", "APPL");
    try d.str(gpa, "CFBundleInfoDictionaryVersion", "6.0");
    try d.str(gpa, "LSMinimumSystemVersion", c.macos.minimum_system_version);
    try d.str(gpa, "NSPrincipalClass", "NSApplication");
    try d.put(gpa, "NSHighResolutionCapable", .{ .bool = true });
    try d.put(gpa, "NSSupportsAutomaticGraphicsSwitching", .{ .bool = true });
    if (icon_file.len > 0) try d.str(gpa, "CFBundleIconFile", icon_file);
    if (c.copyright.len > 0) try d.str(gpa, "NSHumanReadableCopyright", c.copyright);
    if (c.file_associations.len > 0) {
        const docs = try gpa.alloc(Value, c.file_associations.len);
        for (c.file_associations, docs) |fa, *doc| {
            var dd: plist.Dict = .{};
            const name = if (fa.name.len > 0) fa.name else try std.fmt.allocPrint(gpa, "{s} file", .{try std.ascii.allocUpperString(gpa, fa.ext[0])});
            try dd.str(gpa, "CFBundleTypeName", name);
            try dd.str(gpa, "CFBundleTypeRole", fa.role);
            try dd.str(gpa, "LSHandlerRank", "Default");
            const exts = try gpa.alloc(Value, fa.ext.len);
            for (fa.ext, exts) |e, *v| v.* = .{ .string = e };
            try dd.put(gpa, "CFBundleTypeExtensions", .{ .list = exts });
            if (fa.mime_type.len > 0) try dd.put(gpa, "CFBundleTypeMIMETypes", .{ .list = try gpa.dupe(Value, &.{.{ .string = fa.mime_type }}) });
            doc.* = dd.value();
        }
        try d.put(gpa, "CFBundleDocumentTypes", .{ .list = docs });
    }
    if (c.url_schemes.len > 0) {
        const schemes = try gpa.alloc(Value, c.url_schemes.len);
        for (c.url_schemes, schemes) |s, *v| v.* = .{ .string = s };
        var t: plist.Dict = .{};
        try t.str(gpa, "CFBundleURLName", c.identifier);
        try t.put(gpa, "CFBundleURLSchemes", .{ .list = schemes });
        try d.put(gpa, "CFBundleURLTypes", .{ .list = try gpa.dupe(Value, &.{t.value()}) });
    }
    // The app's own keys win.
    if (c.macos.info_plist) |extra| for (extra.object) |f| try d.put(gpa, f.key, f.value);
    return plist.document(gpa, d.value());
}

/// Assembles `<dir>/<name>.app` around the executable `bin` (copied in),
/// with the icon and the resources, and returns the bundle's path.
pub fn writeBundle(ctx: Ctx, c: Config, dir: []const u8, bin: []const u8, resources: []const []const u8) ![]u8 {
    const name = try fsx.fsName(ctx.gpa, c.name);
    const app = try ctx.join(&.{ dir, try ctx.fmt("{s}.app", .{name}) });
    fsx.remove(ctx.io, app);
    const contents = try ctx.join(&.{ app, "Contents" });
    const res_dir = try ctx.join(&.{ contents, "Resources" });
    try fsx.makeDir(ctx.io, res_dir);
    try fsx.writeExecutable(ctx.io, try ctx.join(&.{ contents, "MacOS", name }), try fsx.read(ctx, bin));
    var icon_file: []const u8 = "";
    if (c.icon.len > 0) {
        const src = try fsx.read(ctx, try c.path(ctx.gpa, c.icon));
        try fsx.write(ctx.io, try ctx.join(&.{ res_dir, bundle_icon }), try icon.icns(ctx.gpa, src));
        icon_file = bundle_icon;
    }
    for (resources) |r| try fsx.copyTree(ctx, r, try ctx.join(&.{ res_dir, std.fs.path.basename(r) }));
    if (c.macos.provisioning_profile.len > 0) try embedProfile(ctx, c, contents);
    try fsx.write(ctx.io, try ctx.join(&.{ contents, "Info.plist" }), try infoPlist(ctx.gpa, c, name, icon_file));
    try fsx.write(ctx.io, try ctx.join(&.{ contents, "PkgInfo" }), "APPL????");
    return app;
}

/// Copies `macos.provisioning_profile` into the bundle, where codesign
/// seals it with the rest: `Contents/embedded.provisionprofile`.
fn embedProfile(ctx: Ctx, c: Config, contents: []const u8) !void {
    const p = c.macos.provisioning_profile;
    const src = try c.path(ctx.gpa, p);
    if (!fsx.isFile(ctx.io, src)) {
        if (!ctx.quiet) std.debug.print("error: provisioning profile {s}: {s}\n", .{ p, if (fsx.exists(ctx.io, src)) "not a file" else "no such file" });
        return error.MissingResource;
    }
    try fsx.copyFile(ctx.io, src, try ctx.join(&.{ contents, "embedded.provisionprofile" }));
}

/// Whether the configuration signs ad hoc with a provisioning profile,
/// which codesign cannot do: `myzig build` stops before building.
pub fn profileNeedsIdentity(c: Config) bool {
    return c.macos.provisioning_profile.len > 0 and std.mem.eql(u8, c.macos.signing_identity, "-");
}

pub const profile_ad_hoc = "macos.provisioning_profile needs a signing identity, not ad-hoc signing: set macos.signing_identity";

/// Combines 64-bit Mach-O executables into a universal (fat) binary, as
/// lipo does, aligning each slice to 16 KiB.
pub fn universal(gpa: std.mem.Allocator, slices: []const []const u8) ![]u8 {
    const alignment = 14;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var head: [8]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], 0xcafebabe, .big);
    std.mem.writeInt(u32, head[4..8], @intCast(slices.len), .big);
    try out.appendSlice(gpa, &head);
    var offset: u32 = 1 << alignment;
    for (slices) |s| {
        if (s.len < 12 or std.mem.readInt(u32, s[0..4], .little) != 0xfeedfacf) return error.NotMachO64;
        var e: [20]u8 = undefined;
        std.mem.writeInt(u32, e[0..4], std.mem.readInt(u32, s[4..8], .little), .big); // cputype
        std.mem.writeInt(u32, e[4..8], std.mem.readInt(u32, s[8..12], .little), .big); // cpusubtype
        std.mem.writeInt(u32, e[8..12], offset, .big);
        std.mem.writeInt(u32, e[12..16], @intCast(s.len), .big);
        std.mem.writeInt(u32, e[16..20], alignment, .big);
        try out.appendSlice(gpa, &e);
        offset += std.mem.alignForward(u32, @intCast(s.len), 1 << alignment);
    }
    for (slices) |s| {
        try out.appendNTimes(gpa, 0, std.mem.alignForward(usize, out.items.len, 1 << alignment) - out.items.len);
        try out.appendSlice(gpa, s);
    }
    return out.toOwnedSlice(gpa);
}

/// Signs the bundle on a Mac (ad hoc with "-"); elsewhere the executable
/// keeps the ad-hoc signature Zig's linker gave it.
pub fn codesign(ctx: Ctx, c: Config, app: []const u8) !void {
    if (profileNeedsIdentity(c)) {
        std.debug.print("error: {s}\n", .{profile_ad_hoc});
        return error.CommandFailed;
    }
    if (builtin.os.tag != .macos) {
        if (!std.mem.eql(u8, c.macos.signing_identity, "-")) ctx.warn("not signing {s}: code signing needs macOS", .{std.fs.path.basename(app)});
        return;
    }
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(ctx.gpa, &.{ "codesign", "--force", "--deep", "--sign", c.macos.signing_identity });
    if (!std.mem.eql(u8, c.macos.signing_identity, "-")) try args.appendSlice(ctx.gpa, &.{ "--options", "runtime", "--timestamp" });
    if (c.macos.entitlements.len > 0) try args.appendSlice(ctx.gpa, &.{ "--entitlements", try c.path(ctx.gpa, c.macos.entitlements) });
    try args.append(ctx.gpa, app);
    try proc.check(ctx, args.items, null);
}

/// "<Name> <Version> <arch>.dmg".
pub fn dmgName(ctx: Ctx, c: Config, arch: []const u8) ![]u8 {
    return ctx.fmt("{s} {s} {s}.dmg", .{ try fsx.fsName(ctx.gpa, c.name), try fsx.fsName(ctx.gpa, c.version), arch });
}

/// Packages the bundle into a compressed, read-only disk image in `dir`:
/// opening it shows the app beside a link to /Applications. Needs macOS.
pub fn diskImage(ctx: Ctx, c: Config, app: []const u8, dir: []const u8, arch: []const u8) ![]u8 {
    const file = try ctx.join(&.{ dir, try dmgName(ctx, c, arch) });
    const work = try ctx.join(&.{ dir, ".dmg-work" });
    fsx.remove(ctx.io, work);
    defer fsx.remove(ctx.io, work);
    const src = try ctx.join(&.{ work, "src" });
    try fsx.makeDir(ctx.io, src);
    const app_name = std.fs.path.basename(app);
    // ditto keeps the bundle exactly as signed.
    try proc.check(ctx, &.{ "ditto", "--noclone", app, try ctx.join(&.{ src, app_name }) }, null);
    try std.Io.Dir.cwd().symLink(ctx.io, "/Applications", try ctx.join(&.{ src, "Applications" }), .{});
    try fsx.write(ctx.io, try ctx.join(&.{ src, ".DS_Store" }), try dsstore.forDiskImage(ctx.gpa, app_name));
    const icns_path = try ctx.join(&.{ app, "Contents", "Resources", bundle_icon });
    const has_icon = fsx.exists(ctx.io, icns_path);
    if (has_icon) try fsx.copyFile(ctx.io, icns_path, try ctx.join(&.{ src, ".VolumeIcon.icns" }));
    const rw = try ctx.join(&.{ work, "rw.dmg" });
    try proc.check(ctx, &.{ "hdiutil", "create", "-ov", "-volname", c.macos.dmg_title, "-srcfolder", src, "-fs", "HFS+", "-fsargs", "-c c=64,a=16,e=16", "-format", "UDRW", rw }, null);
    if (has_icon) {
        // The volume's custom icon is a Finder flag (0x0400, kHasCustomIcon).
        const mnt = try ctx.join(&.{ work, "mnt" });
        try fsx.makeDir(ctx.io, mnt);
        try proc.check(ctx, &.{ "hdiutil", "attach", "-readwrite", "-noverify", "-noautoopen", "-nobrowse", "-mountpoint", mnt, rw }, null);
        const flagged = proc.check(ctx, &.{ "/usr/bin/xattr", "-wx", "com.apple.FinderInfo", fsx.repeat("0", 16) ++ "0400" ++ fsx.repeat("0", 44), mnt }, null);
        fsx.remove(ctx.io, try ctx.join(&.{ mnt, ".fseventsd" }));
        try proc.check(ctx, &.{ "hdiutil", "detach", mnt }, null);
        try flagged;
    }
    try proc.check(ctx, &.{ "hdiutil", "convert", rw, "-format", "ULMO", "-ov", "-o", file }, null);
    if (!std.mem.eql(u8, c.macos.signing_identity, "-"))
        try proc.check(ctx, &.{ "codesign", "--force", "--timestamp", "--sign", c.macos.signing_identity, file }, null);
    return file;
}

test infoPlist {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var extra = [_]@import("zon.zig").Field{
        .{ .key = "NSCameraUsageDescription", .value = .{ .string = "Scan <docs>" } },
        .{ .key = "LSMinimumSystemVersion", .value = .{ .string = "13.0" } },
    };
    const c: Config = .{
        .root = "/a", .name = "My App", .identifier = "com.example.myapp", .version = "1.2.0",
        .copyright = "(c) Me", .url_schemes = &.{"myapp"},
        .file_associations = &.{.{ .ext = &.{"md"}, .name = "Markdown", .mime_type = "text/markdown" }},
        .macos = .{ .info_plist = .{ .object = &extra } },
    };
    const doc = try infoPlist(gpa, c, "My App", bundle_icon);
    for ([_][]const u8{
        "\t<key>CFBundleExecutable</key>\n\t<string>My App</string>\n",
        "\t<key>CFBundleIdentifier</key>\n\t<string>com.example.myapp</string>\n",
        "\t<key>CFBundleIconFile</key>\n\t<string>icon.icns</string>\n",
        "\t<key>CFBundleShortVersionString</key>\n\t<string>1.2.0</string>\n",
        "\t<key>NSHighResolutionCapable</key>\n\t<true/>\n",
        "\t<key>NSHumanReadableCopyright</key>\n\t<string>(c) Me</string>\n",
        "\t\t\t<key>CFBundleURLSchemes</key>\n\t\t\t<array>\n\t\t\t\t<string>myapp</string>\n",
        "\t\t\t<key>CFBundleTypeExtensions</key>\n\t\t\t<array>\n\t\t\t\t<string>md</string>\n",
        "\t\t\t<key>CFBundleTypeMIMETypes</key>\n\t\t\t<array>\n\t\t\t\t<string>text/markdown</string>\n",
        // The app's keys, escaped, and replacing myzig's.
        "\t<key>NSCameraUsageDescription</key>\n\t<string>Scan &lt;docs&gt;</string>\n",
        "\t<key>LSMinimumSystemVersion</key>\n\t<string>13.0</string>\n",
    }) |want| if (std.mem.indexOf(u8, doc, want) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ want, doc });
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.endsWith(u8, doc, "</dict>\n</plist>\n"));
}

test universal {
    const gpa = std.testing.allocator;
    var a: [40]u8 = @splat(0);
    var b: [70]u8 = @splat(0);
    for ([_]*[40]u8{&a}) |s| std.mem.writeInt(u32, s[0..4], 0xfeedfacf, .little);
    std.mem.writeInt(u32, b[0..4], 0xfeedfacf, .little);
    std.mem.writeInt(u32, a[4..8], 0x0100000c, .little); // arm64
    std.mem.writeInt(u32, b[4..8], 0x01000007, .little); // x86_64
    const fat = try universal(gpa, &.{ &a, &b });
    defer gpa.free(fat);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), std.mem.readInt(u32, fat[0..4], .big));
    try std.testing.expectEqual(@as(u32, 0x0100000c), std.mem.readInt(u32, fat[8..12], .big));
    try std.testing.expectEqual(@as(u32, 1 << 14), std.mem.readInt(u32, fat[16..20], .big));
    try std.testing.expectEqual(@as(u32, 2 << 14), std.mem.readInt(u32, fat[36..40], .big));
    try std.testing.expectEqualSlices(u8, &b, fat[2 << 14 ..]);
    try std.testing.expectError(error.NotMachO64, universal(gpa, &.{"nope"}));
}

test writeBundle {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: Ctx = .{ .gpa = arena.allocator(), .io = std.testing.io, .env = undefined };
    const root = try fsx.absolute(ctx, try ctx.join(&.{ ".zig-cache", "tmp", &tmp.sub_path }));
    const bin = try ctx.join(&.{ root, "app-bin" });
    try fsx.write(ctx.io, bin, "\xcf\xfa\xed\xfe fake");
    try fsx.write(ctx.io, try ctx.join(&.{ root, "icon.png" }), try @import("png.zig").testIcon(ctx.gpa, 64, .{ 9, 9, 9 }));
    const res = try ctx.join(&.{ root, "data" });
    try fsx.write(ctx.io, try ctx.join(&.{ res, "a.txt" }), "a");
    const c: Config = .{ .root = root, .name = "My App", .identifier = "com.example.myapp", .version = "1.0.0", .icon = "icon.png" };
    const app = try writeBundle(ctx, c, try ctx.join(&.{ root, "out" }), bin, &.{res});
    try std.testing.expect(std.mem.endsWith(u8, app, "My App.app"));
    try std.testing.expectEqualStrings("\xcf\xfa\xed\xfe fake", try fsx.read(ctx, try ctx.join(&.{ app, "Contents", "MacOS", "My App" })));
    try std.testing.expectEqualStrings("APPL????", try fsx.read(ctx, try ctx.join(&.{ app, "Contents", "PkgInfo" })));
    try std.testing.expectEqualStrings("a", try fsx.read(ctx, try ctx.join(&.{ app, "Contents", "Resources", "data", "a.txt" })));
    const icns = try fsx.read(ctx, try ctx.join(&.{ app, "Contents", "Resources", bundle_icon }));
    try std.testing.expect(std.mem.startsWith(u8, icns, "icns"));
    const info = try fsx.read(ctx, try ctx.join(&.{ app, "Contents", "Info.plist" }));
    try std.testing.expect(std.mem.indexOf(u8, info, "<key>CFBundleIconFile</key>\n\t<string>icon.icns</string>") != null);
    if (std.Io.File.Permissions.has_executable_bit) try std.testing.expect(fsx.isExecutable(ctx.io, try ctx.join(&.{ app, "Contents", "MacOS", "My App" })));
}

test "provisioning profiles are embedded before signing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: Ctx = .{ .gpa = arena.allocator(), .io = std.testing.io, .env = undefined, .quiet = true };
    const root = try fsx.absolute(ctx, try ctx.join(&.{ ".zig-cache", "tmp", &tmp.sub_path }));
    const bin = try ctx.join(&.{ root, "app-bin" });
    try fsx.write(ctx.io, bin, "executable");
    try fsx.write(ctx.io, try ctx.join(&.{ root, "profiles", "App.provisionprofile" }), "signed profile bytes");
    const abs = try ctx.join(&.{ root, "profiles", "App.provisionprofile" });
    for ([_][]const u8{ "", "profiles/App.provisionprofile", abs, "missing", "profiles" }, 0..) |profile, i| {
        const c: Config = .{ .root = root, .name = "App", .identifier = "com.example.app", .version = "1.0.0", .macos = .{ .provisioning_profile = profile } };
        const out = try ctx.join(&.{ root, try ctx.fmt("out{d}", .{i}) });
        if (i >= 3) {
            try std.testing.expectError(error.MissingResource, writeBundle(ctx, c, out, bin, &.{}));
            continue;
        }
        const app = try writeBundle(ctx, c, out, bin, &.{});
        const embedded = try ctx.join(&.{ app, "Contents", "embedded.provisionprofile" });
        if (profile.len == 0) {
            try std.testing.expect(!fsx.exists(ctx.io, embedded));
        } else try std.testing.expectEqualStrings("signed profile bytes", try fsx.read(ctx, embedded));
    }
    // Ad-hoc signing cannot use a profile.
    try std.testing.expect(profileNeedsIdentity(.{ .root = root, .macos = .{ .provisioning_profile = "p" } }));
    try std.testing.expect(!profileNeedsIdentity(.{ .root = root, .macos = .{ .provisioning_profile = "p", .signing_identity = "Developer ID Application: A (T)" } }));
    try std.testing.expect(!profileNeedsIdentity(.{ .root = root }));
}
