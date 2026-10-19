//! D-Bus messages, encoded and decoded (little endian), for the few calls
//! myzig makes on the session bus: notifications, the desktop portal's
//! settings, the screen saver's inhibitions. Values are aligned from the
//! message's start, as the specification asks.
const std = @import("std");

pub const Type = enum(u8) { invalid = 0, method_call = 1, method_return = 2, @"error" = 3, signal = 4, _ };

pub const Field = enum(u8) { path = 1, interface = 2, member = 3, error_name = 4, reply_serial = 5, destination = 6, sender = 7, signature = 8, _ };

/// Writes values: the caller follows the signature it declares.
pub const Encoder = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(e: *Encoder) void {
        e.buf.deinit(e.gpa);
    }

    pub fn alignTo(e: *Encoder, n: usize) !void {
        while (e.buf.items.len % n != 0) try e.buf.append(e.gpa, 0);
    }

    pub fn byte(e: *Encoder, v: u8) !void {
        try e.buf.append(e.gpa, v);
    }

    pub fn u32_(e: *Encoder, v: u32) !void {
        try e.alignTo(4);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try e.buf.appendSlice(e.gpa, &b);
    }

    pub fn i32_(e: *Encoder, v: i32) !void {
        try e.u32_(@bitCast(v));
    }

    pub fn boolean(e: *Encoder, v: bool) !void {
        try e.u32_(@intFromBool(v));
    }

    /// A string or an object path.
    pub fn string(e: *Encoder, s: []const u8) !void {
        try e.u32_(@intCast(s.len));
        try e.buf.appendSlice(e.gpa, s);
        try e.buf.append(e.gpa, 0);
    }

    pub fn signature(e: *Encoder, s: []const u8) !void {
        try e.buf.append(e.gpa, @intCast(s.len));
        try e.buf.appendSlice(e.gpa, s);
        try e.buf.append(e.gpa, 0);
    }

    pub const Array = struct { len_at: usize, start: usize };

    /// Starts an array of elements aligned to `elem_align`; `endArray`
    /// writes its length, which counts from the first element (after the
    /// padding).
    pub fn beginArray(e: *Encoder, elem_align: usize) !Array {
        try e.u32_(0);
        const len_at = e.buf.items.len - 4;
        try e.alignTo(elem_align);
        return .{ .len_at = len_at, .start = e.buf.items.len };
    }

    pub fn endArray(e: *Encoder, a: Array) void {
        std.mem.writeInt(u32, e.buf.items[a.len_at..][0..4], @intCast(e.buf.items.len - a.start), .little);
    }

    pub fn structStart(e: *Encoder) !void {
        try e.alignTo(8);
    }
};

pub const Header = struct {
    type: Type,
    flags: u8 = 0,
    serial: u32,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    destination: []const u8 = "",
    sender: []const u8 = "",
    signature: []const u8 = "",
    reply_serial: u32 = 0,
};

/// A whole message of `h` and `body` (encoded by the caller from offset
/// zero: the body starts 8-aligned, so its alignment is the message's).
pub fn message(gpa: std.mem.Allocator, h: Header, body: []const u8) ![]u8 {
    var e: Encoder = .{ .gpa = gpa };
    errdefer e.deinit();
    try e.byte('l');
    try e.byte(@intFromEnum(h.type));
    try e.byte(h.flags);
    try e.byte(1);
    try e.u32_(@intCast(body.len));
    try e.u32_(h.serial);
    const fields = try e.beginArray(8);
    const strings = .{ .{ Field.path, h.path, "o" }, .{ Field.interface, h.interface, "s" }, .{ Field.member, h.member, "s" }, .{ Field.error_name, h.error_name, "s" }, .{ Field.destination, h.destination, "s" }, .{ Field.sender, h.sender, "s" } };
    inline for (strings) |f| if (f[1].len > 0) {
        try e.structStart();
        try e.byte(@intFromEnum(f[0]));
        try e.signature(f[2]);
        try e.string(f[1]);
    };
    if (h.reply_serial != 0) {
        try e.structStart();
        try e.byte(@intFromEnum(Field.reply_serial));
        try e.signature("u");
        try e.u32_(h.reply_serial);
    }
    if (h.signature.len > 0) {
        try e.structStart();
        try e.byte(@intFromEnum(Field.signature));
        try e.signature("g");
        try e.signature(h.signature);
    }
    e.endArray(fields);
    try e.alignTo(8);
    try e.buf.appendSlice(gpa, body);
    return e.buf.toOwnedSlice(gpa);
}

/// Reads values of a message whose bytes it borrows.
pub const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,
    /// Where alignment counts from (the message's start).
    base: usize = 0,

    pub fn alignTo(d: *Decoder, n: usize) !void {
        const rel = d.pos - d.base;
        d.pos = d.base + std.mem.alignForward(usize, rel, n);
        if (d.pos > d.bytes.len) return error.Truncated;
    }

    pub fn byte(d: *Decoder) !u8 {
        if (d.pos >= d.bytes.len) return error.Truncated;
        d.pos += 1;
        return d.bytes[d.pos - 1];
    }

    pub fn u32_(d: *Decoder) !u32 {
        try d.alignTo(4);
        if (d.pos + 4 > d.bytes.len) return error.Truncated;
        defer d.pos += 4;
        return std.mem.readInt(u32, d.bytes[d.pos..][0..4], .little);
    }

    pub fn string(d: *Decoder) ![]const u8 {
        const n = try d.u32_();
        if (d.pos + n + 1 > d.bytes.len) return error.Truncated;
        defer d.pos += n + 1;
        return d.bytes[d.pos .. d.pos + n];
    }

    pub fn signature(d: *Decoder) ![]const u8 {
        const n = try d.byte();
        if (d.pos + n + 1 > d.bytes.len) return error.Truncated;
        defer d.pos += n + 1;
        return d.bytes[d.pos .. d.pos + n];
    }

    /// Skips one value of the complete type at the start of `sig`;
    /// returns the rest of the signature.
    pub fn skip(d: *Decoder, sig: []const u8) error{ Truncated, BadSignature }![]const u8 {
        if (sig.len == 0) return error.BadSignature;
        switch (sig[0]) {
            'y' => _ = try d.byte(),
            'b', 'u', 'i', 'h' => _ = try d.u32_(),
            'n', 'q' => {
                try d.alignTo(2);
                d.pos += 2;
            },
            'x', 't', 'd' => {
                try d.alignTo(8);
                d.pos += 8;
            },
            's', 'o' => _ = try d.string(),
            'g' => _ = try d.signature(),
            'v' => {
                const inner = try d.signature();
                _ = try d.skip(inner);
            },
            'a' => {
                const n = try d.u32_();
                const elem = sig[1..];
                try d.alignTo(alignment(elem));
                d.pos += n;
                if (d.pos > d.bytes.len) return error.Truncated;
                return sig[1 + try completeLen(elem) ..];
            },
            '(', '{' => {
                try d.alignTo(8);
                const close: u8 = if (sig[0] == '(') ')' else '}';
                var rest = sig[1..];
                while (rest.len > 0 and rest[0] != close) rest = try d.skip(rest);
                if (rest.len == 0) return error.BadSignature;
                return rest[1..];
            },
            else => return error.BadSignature,
        }
        if (d.pos > d.bytes.len) return error.Truncated;
        return sig[1..];
    }
};

fn alignment(sig: []const u8) usize {
    if (sig.len == 0) return 1;
    return switch (sig[0]) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'x', 't', 'd', '(', '{' => 8,
        else => 4,
    };
}

/// The length of the complete type at the start of `sig`.
pub fn completeLen(sig: []const u8) error{BadSignature}!usize {
    if (sig.len == 0) return error.BadSignature;
    switch (sig[0]) {
        'a' => return 1 + try completeLen(sig[1..]),
        '(', '{' => {
            const close: u8 = if (sig[0] == '(') ')' else '}';
            var i: usize = 1;
            while (i < sig.len and sig[i] != close) i += try completeLen(sig[i..]);
            if (i >= sig.len) return error.BadSignature;
            return i + 1;
        },
        else => return 1,
    }
}

pub const Message = struct {
    header: Header,
    /// The body's decoder, at its first value.
    body: Decoder,
    /// The whole message's length.
    len: usize,
};

/// The length of the message `bytes` starts with, once its fixed header
/// is there (16 bytes); null before.
pub fn messageLen(bytes: []const u8) ?usize {
    if (bytes.len < 16) return null;
    const body = std.mem.readInt(u32, bytes[4..8], .little);
    const fields = std.mem.readInt(u32, bytes[12..16], .little);
    return std.mem.alignForward(usize, 16 + fields, 8) + body;
}

/// Decodes the message at the start of `bytes` (whole: `messageLen`).
pub fn parse(bytes: []const u8) !Message {
    const len = messageLen(bytes) orelse return error.Truncated;
    if (bytes.len < len or bytes[0] != 'l') return error.Truncated;
    var d: Decoder = .{ .bytes = bytes[0..len] };
    d.pos = 1;
    var h: Header = .{ .type = @enumFromInt(try d.byte()), .flags = try d.byte(), .serial = 0 };
    _ = try d.byte();
    const body_len = try d.u32_();
    h.serial = try d.u32_();
    const fields_len = try d.u32_();
    try d.alignTo(8);
    const fields_end = d.pos + fields_len;
    while (d.pos < fields_end) {
        try d.alignTo(8);
        const code: Field = @enumFromInt(try d.byte());
        const sig = try d.signature();
        switch (code) {
            .path, .interface, .member, .error_name, .destination, .sender => {
                const s = try d.string();
                switch (code) {
                    .path => h.path = s,
                    .interface => h.interface = s,
                    .member => h.member = s,
                    .error_name => h.error_name = s,
                    .destination => h.destination = s,
                    else => h.sender = s,
                }
            },
            .reply_serial => h.reply_serial = try d.u32_(),
            .signature => h.signature = try d.signature(),
            else => _ = try d.skip(sig),
        }
    }
    d.pos = fields_end;
    try d.alignTo(8);
    if (d.pos + body_len != len) return error.Truncated;
    return .{ .header = h, .body = d, .len = len };
}

test "a method call encoded and decoded" {
    const gpa = std.testing.allocator;
    // Body "susssasa{sv}i" at the message's alignment: encode it after an
    // 8-aligned start, which is what the header ends with.
    var b: Encoder = .{ .gpa = gpa };
    defer b.deinit();
    try b.string("app");
    try b.u32_(0);
    try b.string("");
    try b.string("Title");
    try b.string("Body");
    const actions = try b.beginArray(4);
    try b.string("default");
    try b.string("Open");
    b.endArray(actions);
    const hints = try b.beginArray(8);
    try b.structStart();
    try b.string("suppress-sound");
    try b.signature("b");
    try b.boolean(true);
    b.endArray(hints);
    try b.i32_(-1);
    const msg = try message(gpa, .{ .type = .method_call, .serial = 7, .path = "/org/freedesktop/Notifications", .interface = "org.freedesktop.Notifications", .member = "Notify", .destination = "org.freedesktop.Notifications", .signature = "susssasa{sv}i" }, b.buf.items);
    defer gpa.free(msg);
    try std.testing.expectEqual(@as(?usize, msg.len), messageLen(msg));
    var m = try parse(msg);
    try std.testing.expectEqual(Type.method_call, m.header.type);
    try std.testing.expectEqual(@as(u32, 7), m.header.serial);
    try std.testing.expectEqualStrings("Notify", m.header.member);
    try std.testing.expectEqualStrings("/org/freedesktop/Notifications", m.header.path);
    try std.testing.expectEqualStrings("susssasa{sv}i", m.header.signature);
    try std.testing.expectEqualStrings("app", try m.body.string());
    var rest: []const u8 = "usssasa{sv}i";
    rest = try m.body.skip(rest);
    rest = try m.body.skip(rest);
    try std.testing.expectEqualStrings("Title", try m.body.string());
    rest = "sasa{sv}i";
    rest = try m.body.skip(rest);
    rest = try m.body.skip(rest);
    rest = try m.body.skip(rest);
    try std.testing.expectEqualStrings("i", rest);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), try m.body.u32_());
    try std.testing.expectEqual(@as(usize, 5), try completeLen("a{sv}i"));
    try std.testing.expectError(error.Truncated, parse(msg[0 .. msg.len - 1]));
}
