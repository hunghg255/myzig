//! Data that drags (and the clipboard) carry: ordered items, each offering
//! alternative formats of the same content (text and HTML of one note),
//! named by MIME types, with explicit bytes or bytes made when a receiver
//! asks (`Lazy`). Native data never holds a pointer; `value` offers a Zig
//! value to drop targets of the same process only.
//!
//!     var data = try transfer.Data.init(gpa, &.{.{ .reps = &.{
//!         transfer.bytes(transfer.text, note.title),
//!         transfer.lazy("application/vnd.example.note+json", .of(note, Note.json)),
//!     } }});
//!     defer data.deinit();
const std = @import("std");
const builtin = @import("builtin");

pub const text = "text/plain";
pub const html = "text/html";
pub const uri_list = "text/uri-list";
/// A URI list known to hold local files: the system's file list.
pub const file_list = "application/x-myzig-file-list";
pub const png = "image/png";
pub const markdown = "text/markdown";
/// A Zig value of this process (`value`): `application/x-myzig-value;type=T`.
pub const value_prefix = "application/x-myzig-value;type=";

/// Makes a representation's bytes when a receiver asks: `.of(&x, X.make)`
/// where `fn make(x: *X, gpa) ![]u8`. Runs at most once per data.
pub const Provider = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) anyerror![]u8,

    pub fn of(ptr: anytype, comptime func: fn (@TypeOf(ptr), std.mem.Allocator) anyerror![]u8) Provider {
        const P = @TypeOf(ptr);
        return .{ .ctx = @ptrCast(@constCast(ptr)), .func = struct {
            fn call(c: *anyopaque, gpa: std.mem.Allocator) anyerror![]u8 {
                return func(@as(P, @ptrCast(@alignCast(c))), gpa);
            }
        }.call };
    }
};

/// A format of an item, as given to `Data.init`.
pub const Rep = struct {
    format: []const u8,
    bytes: ?[]const u8 = null,
    provider: ?Provider = null,
};

pub fn bytes(format: []const u8, b: []const u8) Rep {
    return .{ .format = format, .bytes = b };
}

pub fn lazy(format: []const u8, p: Provider) Rep {
    return .{ .format = format, .provider = p };
}

pub const ItemInit = struct { reps: []const Rep };

const Stored = struct {
    format: []u8,
    bytes: ?[]u8,
    provider: ?Provider,
    failed: bool = false,
};

pub const Data = struct {
    gpa: std.mem.Allocator,
    /// Each item's representations, in preference order.
    items: [][]Stored = &.{},

    /// Copies the formats and bytes of `items`.
    pub fn init(gpa: std.mem.Allocator, items: []const ItemInit) !Data {
        var d: Data = .{ .gpa = gpa };
        errdefer d.deinit();
        d.items = try gpa.alloc([]Stored, items.len);
        for (d.items) |*it| it.* = &.{};
        for (items, d.items) |src, *dst| {
            dst.* = try gpa.alloc(Stored, src.reps.len);
            for (dst.*) |*r| r.* = .{ .format = &.{}, .bytes = null, .provider = null };
            for (src.reps, dst.*) |r, *s| {
                if (r.format.len == 0 or std.mem.indexOfAny(u8, r.format, "\x00\r\n") != null) return error.InvalidFormat;
                s.format = try gpa.dupe(u8, r.format);
                s.bytes = if (r.bytes) |b| try gpa.dupe(u8, b) else null;
                s.provider = if (r.bytes == null) r.provider else null;
                if (s.bytes == null and s.provider == null) return error.NoBytes;
            }
        }
        return d;
    }

    pub fn deinit(d: *Data) void {
        for (d.items) |it| {
            for (it) |r| {
                d.gpa.free(r.format);
                if (r.bytes) |b| d.gpa.free(b);
            }
            d.gpa.free(it);
        }
        d.gpa.free(d.items);
        d.items = &.{};
    }

    /// An independent copy (its own lazy cache; providers are shared).
    pub fn clone(d: *const Data, gpa: std.mem.Allocator) !Data {
        var out: Data = .{ .gpa = gpa };
        errdefer out.deinit();
        out.items = try gpa.alloc([]Stored, d.items.len);
        for (out.items) |*it| it.* = &.{};
        for (d.items, out.items) |src, *dst| {
            dst.* = try gpa.alloc(Stored, src.len);
            for (dst.*) |*r| r.* = .{ .format = &.{}, .bytes = null, .provider = null };
            for (src, dst.*) |r, *s| {
                s.format = try gpa.dupe(u8, r.format);
                s.bytes = if (r.bytes) |b| try gpa.dupe(u8, b) else null;
                s.provider = if (r.bytes == null) r.provider else null;
                s.failed = r.failed;
            }
        }
        return out;
    }

    /// Whether an item offers `format`.
    pub fn has(d: *const Data, format: []const u8) bool {
        for (d.items) |it| for (it) |r| if (std.mem.eql(u8, r.format, format)) return true;
        return false;
    }

    /// The first of `wanted` (the receiver's preference order) offered.
    pub fn preferred(d: *const Data, wanted: []const []const u8) ?[]const u8 {
        for (wanted) |w| if (d.has(w)) return w;
        return null;
    }

    /// The formats offered, without repeats, in order (frame memory: `a`).
    pub fn formats(d: *const Data, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (d.items) |it| for (it) |r| {
            for (out.items) |f| {
                if (std.mem.eql(u8, f, r.format)) break;
            } else try out.append(a, r.format);
        };
        return out.toOwnedSlice(a);
    }

    fn resolve(d: *Data, r: *Stored) ![]const u8 {
        if (r.bytes) |b| return b;
        if (r.failed) return error.ProviderFailed;
        const p = r.provider orelse return error.FormatUnavailable;
        r.bytes = p.func(p.ctx, d.gpa) catch |err| {
            r.failed = true;
            return err;
        };
        return r.bytes.?;
    }

    /// The bytes of `format`, the items' coalesced as native transfers do:
    /// text joined by newlines, URI lists by CRLF, other formats the first
    /// item's. Lazy providers run now (once). In `a`'s memory.
    pub fn read(d: *Data, a: std.mem.Allocator, format: []const u8) ![]u8 {
        const sep: ?[]const u8 = if (std.mem.eql(u8, format, text) or std.mem.eql(u8, format, markdown)) "\n" else if (std.mem.eql(u8, format, uri_list) or std.mem.eql(u8, format, file_list)) "\r\n" else null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var found = false;
        outer: for (d.items) |it| for (it) |*r| if (std.mem.eql(u8, r.format, format)) {
            const b = try d.resolve(r);
            if (found) try out.appendSlice(a, sep.?);
            try out.appendSlice(a, b);
            found = true;
            if (sep == null) break :outer;
            break; // an item's first representation of it
        };
        if (!found) return error.FormatUnavailable;
        return out.toOwnedSlice(a);
    }

    /// The bytes item `index` offers as `format` (owned by the data):
    /// its provider runs now when lazy (once).
    pub fn itemBytes(d: *Data, index: usize, format: []const u8) ![]const u8 {
        if (index >= d.items.len) return error.FormatUnavailable;
        for (d.items[index]) |*r| if (std.mem.eql(u8, r.format, format)) return d.resolve(r);
        return error.FormatUnavailable;
    }

    /// The local files of a file list or URI list (paths in `a`'s memory).
    pub fn files(d: *Data, a: std.mem.Allocator) ![][]u8 {
        const f: []const u8 = if (d.has(file_list)) file_list else uri_list;
        const list = d.read(a, f) catch return a.alloc([]u8, 0);
        var out: std.ArrayList([]u8) = .empty;
        var it = std.mem.tokenizeAny(u8, list, "\r\n");
        while (it.next()) |line| {
            if (line[0] == '#') continue;
            if (try pathOfUrl(a, line)) |p| try out.append(a, p);
        }
        return out.toOwnedSlice(a);
    }

    /// The process-local value of type `T` this data offers (`value`).
    pub fn value(d: *Data, comptime T: type) ?*T {
        for (d.items) |it| for (it) |r| if (std.mem.eql(u8, r.format, value_format(T))) {
            const b = r.bytes orelse return null;
            if (b.len != @sizeOf(usize)) return null;
            return @ptrFromInt(std.mem.readInt(usize, b[0..@sizeOf(usize)], .little));
        };
        return null;
    }
};

pub fn value_format(comptime T: type) []const u8 {
    return value_prefix ++ @typeName(T);
}

/// Text, as one item.
pub fn textData(gpa: std.mem.Allocator, s: []const u8) !Data {
    return Data.init(gpa, &.{.{ .reps = &.{bytes(text, s)} }});
}

/// A Zig value of this process: drop targets of the same window take it
/// (`DropTarget.value`); it never leaves the process.
pub fn valueData(gpa: std.mem.Allocator, comptime T: type, ptr: *T) !Data {
    var b: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &b, @intFromPtr(ptr), .little);
    return Data.init(gpa, &.{.{ .reps = &.{bytes(value_format(T), &b)} }});
}

/// Files (absolute paths), one item each, as file URLs.
pub fn fileData(gpa: std.mem.Allocator, paths: []const []const u8) !Data {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try a.alloc(ItemInit, paths.len);
    for (paths, items) |p, *it| {
        const url = try urlOfPath(a, p);
        const reps = try a.alloc(Rep, 2);
        reps[0] = bytes(file_list, url);
        reps[1] = bytes(uri_list, url);
        it.* = .{ .reps = reps };
    }
    return Data.init(gpa, items);
}

/// `file:///` and the path, slashes forward, escaped as URLs are.
pub fn urlOfPath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    if (path.len == 0 or (path[0] != '/' and path[0] != '\\')) try out.append(a, '/');
    for (path) |ch| {
        const c = if (ch == '\\') '/' else ch;
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/:", c) != null) {
            try out.append(a, c);
        } else try out.print(a, "%{X:0>2}", .{c});
    }
    return out.toOwnedSlice(a);
}

/// The local path of a `file:` URL (null for other URLs and remote hosts).
pub fn pathOfUrl(a: std.mem.Allocator, url: []const u8) !?[]u8 {
    if (!std.ascii.startsWithIgnoreCase(url, "file://")) return null;
    var rest = url[7..];
    if (std.mem.startsWith(u8, rest, "localhost/")) rest = rest[9..];
    if (rest.len == 0 or rest[0] != '/') return null; // a remote host
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    // file:///C:/x is C:/x on Windows.
    if (builtin.os.tag == .windows and rest.len >= 3 and rest[2] == ':') i = 1;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return null;
            try out.append(a, v);
            i += 2;
        } else try out.append(a, if (builtin.os.tag == .windows and rest[i] == '/') '\\' else rest[i]);
    }
    return try out.toOwnedSlice(a);
}

/// Frees what `clipboard.formats` returns.
pub fn freeFormats(gpa: std.mem.Allocator, fs: [][]u8) void {
    for (fs) |f| gpa.free(f);
    gpa.free(fs);
}

/// What a drop does to the source's value.
pub const Effect = enum { none, copy, move, link };

/// The effects a source allows or a target accepts.
pub const Effects = packed struct {
    copy: bool = true,
    move: bool = false,
    link: bool = false,

    pub const copy_move: Effects = .{ .copy = true, .move = true };

    pub fn allows(e: Effects, x: Effect) bool {
        return switch (x) {
            .copy => e.copy,
            .move => e.move,
            .link => e.link,
            .none => false,
        };
    }
};

/// The effect of a drop: the modifier keys' suggestion when both ends
/// allow it (Option copies and Command moves on macOS; Ctrl copies and
/// Shift moves elsewhere), else copy, then move, then link.
pub fn negotiate(source: Effects, target: Effects, suggested: ?Effect) Effect {
    if (suggested) |s| if (source.allows(s) and target.allows(s)) return s;
    inline for (.{ Effect.copy, Effect.move, Effect.link }) |e| if (source.allows(e) and target.allows(e)) return e;
    return .none;
}

test "data: items, formats, coalescing, lazy providers once, files, values" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Note = struct {
        title: []const u8,
        calls: usize = 0,
        fn json(n: *@This(), g: std.mem.Allocator) anyerror![]u8 {
            n.calls += 1;
            return std.fmt.allocPrint(g, "{{\"title\":\"{s}\"}}", .{n.title});
        }
    };
    var note: Note = .{ .title = "Hi" };
    var d = try Data.init(gpa, &.{
        .{ .reps = &.{ bytes(text, "Hi"), lazy("application/json", .of(&note, Note.json)) } },
        .{ .reps = &.{bytes(text, "there")} },
    });
    defer d.deinit();
    try std.testing.expect(d.has("application/json"));
    try std.testing.expectEqual(@as(usize, 0), note.calls); // asking what it has asks no bytes
    try std.testing.expectEqualStrings("Hi\nthere", try d.read(a, text));
    try std.testing.expectEqualStrings("{\"title\":\"Hi\"}", try d.read(a, "application/json"));
    _ = try d.read(a, "application/json");
    try std.testing.expectEqual(@as(usize, 1), note.calls);
    try std.testing.expectEqualStrings("application/json", d.preferred(&.{ "application/json", text }).?);
    try std.testing.expectError(error.FormatUnavailable, d.read(a, png));
    const fs = try d.formats(a);
    try std.testing.expectEqual(@as(usize, 2), fs.len);

    const p = if (builtin.os.tag == .windows) "C:\\My Files\\a b.txt" else "/tmp/My Files/a b.txt";
    var f = try fileData(gpa, &.{p});
    defer f.deinit();
    const url = try f.read(a, uri_list);
    try std.testing.expect(std.mem.indexOf(u8, url, "My%20Files/a%20b.txt") != null);
    const back = try f.files(a);
    try std.testing.expectEqualStrings(p, back[0]);
    try std.testing.expect((try pathOfUrl(a, "file://server/share")) == null);

    var x: u32 = 7;
    var v = try valueData(gpa, u32, &x);
    defer v.deinit();
    try std.testing.expectEqual(&x, v.value(u32).?);
    try std.testing.expect(v.value(i64) == null);

    try std.testing.expectEqual(Effect.copy, negotiate(.copy_move, .copy_move, null));
    try std.testing.expectEqual(Effect.move, negotiate(.copy_move, .copy_move, .move));
    try std.testing.expectEqual(Effect.copy, negotiate(.copy_move, .{}, .move));
    try std.testing.expectEqual(Effect.none, negotiate(.{ .copy = false, .move = true }, .{}, null));
}
