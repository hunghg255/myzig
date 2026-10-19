//! Archives written in memory: tar (ustar, for .tar.gz and Debian
//! packages), ar (the container of a .deb) and zip, with the modes that
//! make executables runnable wherever the archive was made.
const std = @import("std");
const compress = @import("compress.zig");
const fsx = @import("fsx.zig");

pub const Entry = struct {
    /// Relative, with forward slashes; directories without a trailing one.
    path: []const u8,
    kind: enum { file, dir, symlink } = .file,
    data: []const u8 = "",
    mode: u32 = 0o644,
    /// The target of a symbolic link.
    link: []const u8 = "",
};

pub const TarOptions = struct {
    /// Put before every path: "./" in Debian packages.
    prefix: []const u8 = "",
    mtime: u64 = 0,
    /// Owner and group names (root in Debian packages).
    owner: []const u8 = "root",
};

fn octal(field: []u8, v: u64) void {
    // Digits, then a NUL, right aligned with leading zeros.
    @memset(field, '0');
    field[field.len - 1] = 0;
    var x = v;
    var i = field.len - 1;
    while (i > 0 and x > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(x & 7));
        x >>= 3;
    }
}

/// A tar archive (ustar; names over 100 bytes go into its prefix field).
pub fn tar(gpa: std.mem.Allocator, entries: []const Entry, opts: TarOptions) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (entries) |e| {
        const name = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ opts.prefix, e.path, if (e.kind == .dir) "/" else "" });
        defer gpa.free(name);
        var h: [512]u8 = @splat(0);
        if (name.len <= 100) {
            @memcpy(h[0..name.len], name);
        } else {
            const cut = std.mem.lastIndexOfScalar(u8, name[0..@min(name.len, 156)], '/') orelse return error.NameTooLong;
            if (name.len - cut - 1 > 100) return error.NameTooLong;
            @memcpy(h[345..][0..cut], name[0..cut]);
            @memcpy(h[0 .. name.len - cut - 1], name[cut + 1 ..]);
        }
        octal(h[100..108], e.mode);
        octal(h[108..116], 0);
        octal(h[116..124], 0);
        octal(h[124..136], if (e.kind == .file) e.data.len else 0);
        octal(h[136..148], opts.mtime);
        h[156] = switch (e.kind) {
            .file => '0',
            .symlink => '2',
            .dir => '5',
        };
        if (e.kind == .symlink) {
            if (e.link.len > 100) return error.NameTooLong;
            @memcpy(h[157..][0..e.link.len], e.link);
        }
        @memcpy(h[257..265], "ustar\x0000");
        @memcpy(h[265..][0..opts.owner.len], opts.owner);
        @memcpy(h[297..][0..opts.owner.len], opts.owner);
        // The checksum is summed with its own field as spaces.
        @memset(h[148..156], ' ');
        var sum: u64 = 0;
        for (h) |b| sum += b;
        octal(h[148..155], sum);
        h[155] = ' ';
        try out.appendSlice(gpa, &h);
        if (e.kind == .file) {
            try out.appendSlice(gpa, e.data);
            try out.appendNTimes(gpa, 0, std.mem.alignForward(usize, e.data.len, 512) - e.data.len);
        }
    }
    try out.appendNTimes(gpa, 0, 1024);
    return out.toOwnedSlice(gpa);
}

pub fn tarGz(gpa: std.mem.Allocator, entries: []const Entry, opts: TarOptions) ![]u8 {
    const t = try tar(gpa, entries, opts);
    defer gpa.free(t);
    return compress.deflate(gpa, t, .gzip);
}

/// An ar archive of members (name, data), as `dpkg-deb` writes them.
pub fn ar(gpa: std.mem.Allocator, members: []const struct { []const u8, []const u8 }, mtime: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "!<arch>\n");
    for (members) |m| {
        if (m[0].len > 16) return error.NameTooLong;
        var h: [60]u8 = @splat(' ');
        @memcpy(h[0..m[0].len], m[0]);
        _ = try std.fmt.bufPrint(h[16..28], "{d}", .{mtime});
        h[28] = '0';
        h[34] = '0';
        _ = try std.fmt.bufPrint(h[40..48], "100644", .{});
        _ = try std.fmt.bufPrint(h[48..58], "{d}", .{m[1].len});
        h[58..60].* = .{ '`', '\n' };
        try out.appendSlice(gpa, &h);
        try out.appendSlice(gpa, m[1]);
        if (m[1].len % 2 == 1) try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// MS-DOS time and date of a Unix time (UTC).
fn dosTime(t: u64) struct { u16, u16 } {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @max(t, 315532800) }; // 1980
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    const time: u16 = @intCast(@as(u32, ds.getHoursIntoDay()) << 11 | @as(u32, ds.getMinutesIntoHour()) << 5 | ds.getSecondsIntoMinute() / 2);
    const date: u16 = @intCast(@as(u32, day.year - 1980) << 9 | @as(u32, md.month.numeric()) << 5 | (md.day_index + 1));
    return .{ time, date };
}

/// A zip archive, files deflated (stored when that is not smaller), with
/// Unix modes in their external attributes.
pub fn zip(gpa: std.mem.Allocator, entries: []const Entry, mtime: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var central: std.ArrayList(u8) = .empty;
    defer central.deinit(gpa);
    const time, const date = dosTime(mtime);
    const W = struct {
        fn int(l: *std.ArrayList(u8), a: std.mem.Allocator, comptime T: type, v: T) !void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .little);
            try l.appendSlice(a, &b);
        }
    };
    for (entries) |e| {
        const name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ e.path, if (e.kind == .dir) "/" else "" });
        defer gpa.free(name);
        const content = switch (e.kind) {
            .file => e.data,
            .symlink => e.link,
            .dir => "",
        };
        const deflated = try compress.deflate(gpa, content, .raw);
        defer gpa.free(deflated);
        const store = deflated.len >= content.len;
        const body = if (store) content else deflated;
        const crc = compress.crc32(content);
        const kind_bits: u32 = switch (e.kind) {
            .file => 0o100000,
            .dir => 0o040000,
            .symlink => 0o120000,
        };
        const offset: u32 = @intCast(out.items.len);
        inline for (.{ &out, &central }, 0..) |l, k| {
            try W.int(l, gpa, u32, if (k == 0) 0x04034b50 else 0x02014b50);
            if (k == 1) try W.int(l, gpa, u16, 3 << 8 | 20); // made by Unix, 2.0
            try W.int(l, gpa, u16, 20); // version needed
            try W.int(l, gpa, u16, 0x0800); // UTF-8 names
            try W.int(l, gpa, u16, if (store) 0 else 8);
            try W.int(l, gpa, u16, time);
            try W.int(l, gpa, u16, date);
            try W.int(l, gpa, u32, crc);
            try W.int(l, gpa, u32, @intCast(body.len));
            try W.int(l, gpa, u32, @intCast(content.len));
            try W.int(l, gpa, u16, @intCast(name.len));
            try W.int(l, gpa, u16, 0); // extra
            if (k == 1) {
                try W.int(l, gpa, u16, 0); // comment
                try W.int(l, gpa, u16, 0); // disk
                try W.int(l, gpa, u16, 0); // internal attributes
                try W.int(l, gpa, u32, (kind_bits | e.mode) << 16 | @as(u32, if (e.kind == .dir) 0x10 else 0));
                try W.int(l, gpa, u32, offset);
            }
            try l.appendSlice(gpa, name);
        }
        try out.appendSlice(gpa, body);
    }
    const cd_at: u32 = @intCast(out.items.len);
    try out.appendSlice(gpa, central.items);
    try W.int(&out, gpa, u32, 0x06054b50);
    try W.int(&out, gpa, u16, 0);
    try W.int(&out, gpa, u16, 0);
    try W.int(&out, gpa, u16, @intCast(entries.len));
    try W.int(&out, gpa, u16, @intCast(entries.len));
    try W.int(&out, gpa, u32, @intCast(central.items.len));
    try W.int(&out, gpa, u32, cd_at);
    try W.int(&out, gpa, u16, 0);
    return out.toOwnedSlice(gpa);
}

/// The entries of a directory on disk under `prefix`: its directories and
/// files, those named in `executables` (or executable on disk) 0755.
pub fn collect(ctx: fsx.Ctx, list: *std.ArrayList(Entry), dir: []const u8, prefix: []const u8, executables: []const []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(ctx.io, dir, .{ .iterate = true });
    defer d.close(ctx.io);
    var walker = try d.walk(ctx.gpa);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |e| {
        const rel = try ctx.gpa.dupe(u8, e.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        const path = if (prefix.len > 0) try ctx.fmt("{s}/{s}", .{ prefix, rel }) else rel;
        switch (e.kind) {
            .directory => try list.append(ctx.gpa, .{ .path = path, .kind = .dir, .mode = 0o755 }),
            .file => {
                const disk = try ctx.join(&.{ dir, e.path });
                var exec = fsx.isExecutable(ctx.io, disk);
                for (executables) |x| if (std.mem.eql(u8, x, rel)) {
                    exec = true;
                };
                try list.append(ctx.gpa, .{ .path = path, .data = try fsx.read(ctx, disk), .mode = if (exec) 0o755 else 0o644 });
            },
            else => {},
        }
    }
}

test tar {
    const gpa = std.testing.allocator;
    const long = "a/" ++ rep("d", 60) ++ "/" ++ rep("f", 60);
    const t = try tar(gpa, &.{
        .{ .path = "opt", .kind = .dir, .mode = 0o755 },
        .{ .path = "opt/app", .data = "hello", .mode = 0o755 },
        .{ .path = "usr/bin/app", .kind = .symlink, .link = "../../opt/app", .mode = 0o777 },
        .{ .path = long, .data = "x" },
    }, .{ .prefix = "./", .mtime = 1700000000 });
    defer gpa.free(t);
    try std.testing.expectEqual(@as(usize, 512 * 6 + 1024), t.len);
    try std.testing.expectEqualStrings("./opt/", std.mem.sliceTo(t[0..100], 0));
    try std.testing.expectEqual(@as(u8, '5'), t[156]);
    const f = t[512..];
    try std.testing.expectEqualStrings("./opt/app", std.mem.sliceTo(f[0..100], 0));
    try std.testing.expectEqualStrings("0000755", std.mem.sliceTo(f[100..108], 0));
    try std.testing.expectEqualStrings("00000000005", std.mem.sliceTo(f[124..136], 0));
    try std.testing.expectEqualStrings("ustar", std.mem.sliceTo(f[257..263], 0));
    try std.testing.expectEqualStrings("root", std.mem.sliceTo(f[265..297], 0));
    try std.testing.expectEqualStrings("hello", f[512..517]);
    // The checksum: the header's bytes, with the field as spaces.
    var h = f[0..512].*;
    @memset(h[148..156], ' ');
    var sum: u64 = 0;
    for (h) |b| sum += b;
    try std.testing.expectEqual(sum, try std.fmt.parseInt(u64, std.mem.sliceTo(f[148..155], 0), 8));
    const l = t[1536..];
    try std.testing.expectEqual(@as(u8, '2'), l[156]);
    try std.testing.expectEqualStrings("../../opt/app", std.mem.sliceTo(l[157..257], 0));
    const p = t[2048..];
    try std.testing.expectEqualStrings(rep("f", 60), std.mem.sliceTo(p[0..100], 0));
    try std.testing.expectEqualStrings("./a/" ++ rep("d", 60), std.mem.sliceTo(p[345..500], 0));
}

test ar {
    const gpa = std.testing.allocator;
    const a = try ar(gpa, &.{ .{ "debian-binary", "2.0\n" }, .{ "x", "odd" } }, 1700000000);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("!<arch>\n", a[0..8]);
    try std.testing.expectEqualStrings("debian-binary   1700000000  0     0     100644  4         `\n", a[8..68]);
    try std.testing.expectEqualStrings("2.0\n", a[68..72]);
    try std.testing.expectEqualStrings("x               ", a[72..88]);
    try std.testing.expectEqualStrings("odd\n", a[132..136]); // padded to even
    try std.testing.expectEqual(@as(usize, 136), a.len);
}

test zip {
    const gpa = std.testing.allocator;
    const text = rep("zip ", 100);
    const z = try zip(gpa, &.{
        .{ .path = "App", .kind = .dir, .mode = 0o755 },
        .{ .path = "App/app.exe", .data = text, .mode = 0o755 },
    }, 1700000000);
    defer gpa.free(z);
    // The end record points at the central directory, which points at the
    // local headers; the deflated file reads back.
    const eocd = z[z.len - 22 ..];
    try std.testing.expectEqual(@as(u32, 0x06054b50), std.mem.readInt(u32, eocd[0..4], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, eocd[10..12], .little));
    var cd = z[std.mem.readInt(u32, eocd[16..20], .little)..];
    for (0..2) |i| {
        try std.testing.expectEqual(@as(u32, 0x02014b50), std.mem.readInt(u32, cd[0..4], .little));
        const method = std.mem.readInt(u16, cd[10..12], .little);
        const csize = std.mem.readInt(u32, cd[20..24], .little);
        const usize_ = std.mem.readInt(u32, cd[24..28], .little);
        const nlen = std.mem.readInt(u16, cd[28..30], .little);
        const attrs = std.mem.readInt(u32, cd[38..42], .little);
        const local = std.mem.readInt(u32, cd[42..46], .little);
        const name = cd[46..][0..nlen];
        try std.testing.expectEqualStrings(if (i == 0) "App/" else "App/app.exe", name);
        try std.testing.expectEqual(@as(u32, 0o755), (attrs >> 16) & 0o777);
        const lh = z[local..];
        try std.testing.expectEqual(@as(u32, 0x04034b50), std.mem.readInt(u32, lh[0..4], .little));
        const data = lh[30 + nlen ..][0..csize];
        if (i == 1) {
            try std.testing.expectEqual(@as(u16, 8), method);
            const back = try compress.inflate(gpa, data, .raw);
            defer gpa.free(back);
            try std.testing.expectEqualStrings(text, back);
            try std.testing.expectEqual(@as(u32, text.len), usize_);
            try std.testing.expectEqual(compress.crc32(text), std.mem.readInt(u32, lh[14..18], .little));
        }
        cd = cd[46 + nlen ..];
    }
}
const rep = fsx.repeat;
