//! Downloads the terminal's native libraries into the user's cache
//! (`<cache>/myzig/natives/<sha256>/<name>`), where `library.find` looks,
//! checking their SHA-256: for programs that are not packaged apps, as
//! examples and tests, as mygo's terminal does under `go run`. Opt-in: an
//! app that never calls `fetch` carries no HTTP client.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const library = @import("library.zig");

/// Makes sure library `name` ("libghostty-vt", "conpty", "openconsole")
/// is somewhere `library.find` looks, downloading it if not. Its path,
/// allocated with `gpa`.
pub fn fetch(gpa: std.mem.Allocator, io: Io, name: []const u8) ![:0]u8 {
    if (try library.find(gpa, io, name)) |p| return p;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = try library.build(arena, name);
    const cache = (try library.cacheDir(arena, "myzig")) orelse return error.NoCacheDir;
    const dir = try std.fs.path.join(arena, &.{ cache, f.sha256 });
    try Io.Dir.cwd().createDirPath(io, dir);
    const dest = try std.fs.path.joinZ(gpa, &.{ dir, f.name });
    errdefer gpa.free(dest);
    const tmp = try std.fmt.allocPrint(arena, "{s}.part", .{dest});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var file = try Io.Dir.cwd().createFile(io, tmp, .{});
    var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
    get(&client, arena, f.url, io, file, &sha) catch |err| {
        file.close(io);
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    file.close(io);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, f.sha256)) {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return error.ChecksumMismatch;
    }
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), dest, io);
    return dest;
}

/// Makes sure every library this platform needs is there: libghostty-vt,
/// and on Windows ConPTY's two files.
pub fn fetchAll(gpa: std.mem.Allocator, io: Io) !void {
    gpa.free(try fetch(gpa, io, "libghostty-vt"));
    if (builtin.os.tag == .windows) {
        gpa.free(try fetch(gpa, io, "conpty"));
        gpa.free(try fetch(gpa, io, "openconsole"));
    }
}

fn get(client: *std.http.Client, arena: std.mem.Allocator, url: []const u8, io: Io, file: Io.File, sha: *std.crypto.hash.sha2.Sha256) !void {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .init(10), .headers = .{ .user_agent = .{ .override = "myzig-terminal" } } });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [8192]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);
    if (res.head.status != .ok) return error.HttpStatus;
    var transfer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const window: []u8 = switch (res.head.content_encoding) {
        .identity => &.{},
        else => try arena.alloc(u8, std.compress.flate.max_window_len),
    };
    const body = res.readerDecompressing(&transfer, &decompress, window);
    var buf: [64 << 10]u8 = undefined;
    while (true) {
        var w: Io.Writer = .fixed(&buf);
        const n = body.stream(&w, .limited(buf.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return res.bodyErr() orelse error.ReadFailed,
            error.WriteFailed => unreachable,
        };
        sha.update(buf[0..n]);
        try file.writeStreamingAll(io, buf[0..n]);
    }
}
