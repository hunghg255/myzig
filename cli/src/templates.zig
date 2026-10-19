//! The files of new apps (`myzig init`): a Zig package depending on myzig,
//! whose window shows native UI (`native`) or a web page with a frontend
//! calling Zig (`web`). `{{name}}` and the like are filled in by init.
const std = @import("std");
const png = @import("png.zig");

pub const Template = enum { native, web };

pub const build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    // Set by `myzig build`: release builds without debug information, and
    \\    // Windows' icon, manifest and version information.
    \\    const strip = b.option(bool, "strip", "Strip debug information");
    \\    const win32_res = b.option([]const u8, "win32-res", "A compiled resource file (.res) to link on Windows");
    \\{{frontend_option}}
    \\    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    \\    const root = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .strip = strip,
    \\        .imports = &.{.{ .name = "myzig", .module = myzig }},
    \\    });
    \\{{frontend_import}}
    \\    if (win32_res) |res| if (target.result.os.tag == .windows) root.addObjectFile(.{ .cwd_relative = res });
    \\
    \\    const exe = b.addExecutable(.{ .name = "{{executable}}", .root_module = root });
    \\    // Set by `myzig build`: a Windows app that opens no console.
    \\    if (b.option(bool, "windows-gui", "A Windows app without a console") orelse false) exe.subsystem = .windows;
    \\    // Browsers (`myzig build --platform web`): the page calls myzig's exports.
    \\    if (target.result.os.tag == .wasi) exe.rdynamic = true;
    \\    b.installArtifact(exe);
    \\
    \\    const run = b.addRunArtifact(exe);
    \\    run.addPassthruArgs();
    \\    b.step("run", "Run the app").dependOn(&run.step);
    \\
    \\    const tests = b.addTest(.{ .root_module = root });
    \\    b.step("test", "Run the app's tests").dependOn(&b.addRunArtifact(tests).step);
    \\}
    \\
;

pub const frontend_option =
    \\    // The built frontend, embedded into the app (`myzig_assets.zig` lists
    \\    // its files; `myzig generate`, dev and build write it).
    \\    const frontend = b.option([]const u8, "frontend", "The directory of the built frontend") orelse "frontend";
    \\
;

pub const frontend_import =
    \\    root.addImport("assets", b.createModule(.{
    \\        .root_source_file = b.path(b.fmt("{s}/myzig_assets.zig", .{frontend})),
    \\        .imports = &.{.{ .name = "myzig", .module = myzig }},
    \\    }));
    \\
;

pub const build_zig_zon =
    \\.{
    \\    .name = .{{package}},
    \\    .version = "0.1.0",
    \\    .fingerprint = {{fingerprint}},
    \\    .minimum_zig_version = "0.17.0",
    \\    .dependencies = {{dependencies}},
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

pub const myzig_zon_native =
    \\// The app, for the myzig CLI: `myzig dev`, `myzig build`.
    \\.{
    \\    .name = "{{name}}",
    \\    .identifier = "{{identifier}}",
    \\    .icon = "resources/icon.png",
    \\}
    \\
;

pub const myzig_zon_web =
    \\// The app, for the myzig CLI: `myzig dev`, `myzig build`, `myzig generate`.
    \\.{
    \\    .name = "{{name}}",
    \\    .identifier = "{{identifier}}",
    \\    .icon = "resources/icon.png",
    \\    // The pages, embedded into the app. With a dev server (Vite, ...), set
    \\    // .dev_command and .dev_url, and .build_command and .frontend_dist.
    \\    .frontend = "frontend",
    \\}
    \\
;

pub const main_native =
    \\//! {{name}}: a window of native UI, drawn by myzig.
    \\const std = @import("std");
    \\const myzig = @import("myzig");
    \\const ui = myzig.ui;
    \\
    \\const Counter = struct {
    \\    n: i64 = 0,
    \\
    \\    fn view(s: *Counter, c: *ui.Context) void {
    \\        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 16 });
    \\        defer ui.end(c);
    \\        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
    \\        if (ui.button(c, "Increment", .{ .variant = .primary, .size = 16 }).clicked) s.n += 1;
    \\    }
    \\};
    \\
    \\pub fn main(init: std.process.Init) !void {
    \\    const app = try myzig.App.create(init, .{ .name = "{{name_zig}}" });
    \\    defer app.destroy();
    \\    var state: Counter = .{};
    \\    _ = try app.newWindow(.{
    \\        .title = "{{name_zig}}",
    \\        .width = 420,
    \\        .height = 300,
    \\        .content = .{ .view = .init(&state, Counter.view) },
    \\    });
    \\    try app.run();
    \\}
    \\
    \\test "the button counts" {
    \\    var state: Counter = .{};
    \\    var t: ui.Tester = undefined;
    \\    try t.init(std.testing.allocator, .init(&state, Counter.view), .{});
    \\    defer t.deinit();
    \\    try t.clickText("Increment");
    \\    try std.testing.expectEqual(@as(i64, 1), state.n);
    \\}
    \\
;

pub const main_web =
    \\//! {{name}}: a window showing a web page whose frontend calls Zig through
    \\//! the generated client (`/myzig.js`, typed by frontend/myzig.d.ts).
    \\const std = @import("std");
    \\const myzig = @import("myzig");
    \\const assets = @import("assets");
    \\
    \\const Greeter = struct {
    \\    pub const myzig_params = .{ .greet = .{"name"} };
    \\
    \\    /// Returns a greeting.
    \\    pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
    \\        const who = std.mem.trim(u8, name, " ");
    \\        return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{if (who.len == 0) "stranger" else who});
    \\    }
    \\};
    \\
    \\pub fn main(init: std.process.Init) !void {
    \\    const app = try myzig.App.create(init, .{ .name = "{{name_zig}}" });
    \\    defer app.destroy();
    \\    var greeter: Greeter = .{};
    \\    try app.bind(&greeter);
    \\    // `myzig dev` points the window at the dev server, when there is one.
    \\    const url = init.environ_map.get("MYZIG_DEV_URL") orelse "/";
    \\    _ = try app.newWindow(.{
    \\        .title = "{{name_zig}}",
    \\        .width = 720,
    \\        .height = 520,
    \\        .content = .{ .page = .{ .url = url, .assets = &assets.files } },
    \\    });
    \\    try app.run();
    \\}
    \\
;

pub const index_html =
    \\<!doctype html>
    \\<html lang="en">
    \\  <head>
    \\    <meta charset="utf-8" />
    \\    <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\    <title>{{name_html}}</title>
    \\    <link rel="stylesheet" href="/style.css" />
    \\  </head>
    \\  <body>
    \\    <main>
    \\      <h1>{{name_html}}</h1>
    \\      <form id="form">
    \\        <input id="name" placeholder="Your name" autocomplete="off" />
    \\        <button type="submit">Greet</button>
    \\      </form>
    \\      <p id="greeting">Calls <code>Greeter.greet</code> in Zig.</p>
    \\    </main>
    \\    <script type="module" src="/main.js"></script>
    \\  </body>
    \\</html>
    \\
;

pub const main_js =
    \\// The client is generated from the Zig services (see myzig.d.ts for its types).
    \\import { Greeter } from "/myzig.js";
    \\
    \\const $ = (id) => document.getElementById(id);
    \\
    \\$("form").addEventListener("submit", async (e) => {
    \\  e.preventDefault();
    \\  $("greeting").textContent = await Greeter.greet($("name").value);
    \\});
    \\
;

pub const style_css =
    \\:root { color-scheme: light dark; font-family: system-ui, sans-serif; }
    \\body { margin: 0; display: grid; place-items: center; min-height: 100vh; }
    \\main { text-align: center; }
    \\form { display: flex; gap: 8px; justify-content: center; }
    \\input, button { font: inherit; padding: 6px 10px; }
    \\
;

pub const gitignore =
    \\.zig-cache/
    \\zig-out/
    \\.myzig/
    \\dist/
    \\
;

/// Fills `{{key}}`s in `text`.
pub fn fill(gpa: std.mem.Allocator, text: []const u8, vars: []const [2][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "{{")) {
            if (std.mem.indexOfPos(u8, text, i + 2, "}}")) |end| {
                const key = text[i + 2 .. end];
                const v = for (vars) |kv| {
                    if (std.mem.eql(u8, kv[0], key)) break kv[1];
                } else null;
                if (v) |val| {
                    try out.appendSlice(gpa, val);
                    i = end + 2;
                    continue;
                }
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// The default icon: a rounded square in a blue to violet gradient, with a
/// white ring.
pub fn defaultIcon(gpa: std.mem.Allocator) ![]u8 {
    const n = 512;
    const px = try gpa.alloc(u8, n * n * 4);
    defer gpa.free(px);
    const r = 112.0; // corner radius
    const half = n / 2.0;
    for (0..n) |y| for (0..n) |x| {
        const fx = @as(f64, @floatFromInt(x)) + 0.5;
        const fy = @as(f64, @floatFromInt(y)) + 0.5;
        // Distance outside the rounded square (inset 32 px), for coverage.
        const qx = @max(@abs(fx - half) - (half - 32 - r), 0);
        const qy = @max(@abs(fy - half) - (half - 32 - r), 0);
        const outside = @sqrt(qx * qx + qy * qy) - r;
        const cover = std.math.clamp(0.5 - outside, 0, 1);
        const t = fy / n;
        var c = [3]f64{ 40 + 90 * t, 110 - 60 * t, 240 - 20 * t };
        const d = @sqrt((fx - half) * (fx - half) + (fy - half) * (fy - half));
        const ring = std.math.clamp(28 - @abs(d - 120), 0, 1);
        for (&c) |*v| v.* = v.* * (1 - ring) + 255 * ring;
        const p = px[(y * n + x) * 4 ..][0..4];
        p.* = .{ @intFromFloat(c[0]), @intFromFloat(c[1]), @intFromFloat(c[2]), @intFromFloat(@round(cover * 255)) };
    };
    return png.encode(gpa, .{ .width = n, .height = n, .rgba = px });
}

test fill {
    const gpa = std.testing.allocator;
    const s = try fill(gpa, "a {{x}} b {{y}} {{unknown}} {", &.{ .{ "x", "1" }, .{ "y", "two" } });
    defer gpa.free(s);
    try std.testing.expectEqualStrings("a 1 b two {{unknown}} {", s);
}

test defaultIcon {
    const gpa = std.testing.allocator;
    const icon = try defaultIcon(gpa);
    defer gpa.free(icon);
    try png.validateIcon(icon);
    const img = try png.decode(gpa, icon);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), img.rgba[3]); // a transparent corner
    try std.testing.expectEqual(@as(u8, 255), img.rgba[(256 * 512 + 256) * 4 + 3]);
}
