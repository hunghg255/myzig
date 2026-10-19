//! WebSocket frames (RFC 6455, section 5): headers, lengths, masking, and
//! the rules a peer must keep, for either end (clients mask what they
//! send, servers must not).
const std = @import("std");
const Io = std.Io;

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    pub fn isControl(op: Opcode) bool {
        return @intFromEnum(op) & 0x8 != 0;
    }
};

pub const Role = enum {
    /// Sends masked frames, expects unmasked ones.
    client,
    server,
};

/// Close codes (section 7.4.1).
pub const Code = struct {
    pub const normal: u16 = 1000;
    pub const going_away: u16 = 1001;
    pub const protocol_error: u16 = 1002;
    pub const unsupported: u16 = 1003;
    pub const no_status: u16 = 1005;
    pub const abnormal: u16 = 1006;
    pub const invalid_data: u16 = 1007;
    pub const too_big: u16 = 1009;
};

pub const Error = error{
    /// The peer broke the protocol: fail with 1002.
    ProtocolError,
    /// Text that is not UTF-8: fail with 1007.
    InvalidUtf8,
    /// A message over the limit: fail with 1009.
    MessageTooBig,
};

/// The close code to fail a connection with, for an error of reading.
pub fn failCode(err: anyerror) ?u16 {
    return switch (err) {
        error.ProtocolError => Code.protocol_error,
        error.InvalidUtf8 => Code.invalid_data,
        error.MessageTooBig => Code.too_big,
        else => null,
    };
}

pub const Header = struct {
    fin: bool,
    opcode: Opcode,
    len: u64,
    mask: ?[4]u8,
};

/// Reads a frame's header and checks it against the rules for `role`'s
/// peer: no reserved bits (no extensions are negotiated), known opcodes,
/// control frames final and at most 125 bytes, masking as the role wants.
pub fn readHeader(r: *Io.Reader, role: Role) !Header {
    const b = try r.takeArray(2);
    const fin = b[0] & 0x80 != 0;
    if (b[0] & 0x70 != 0) return error.ProtocolError;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b[0])));
    switch (opcode) {
        .continuation, .text, .binary, .close, .ping, .pong => {},
        _ => return error.ProtocolError,
    }
    const masked = b[1] & 0x80 != 0;
    if (masked != (role == .server)) return error.ProtocolError;
    var len: u64 = b[1] & 0x7f;
    if (len == 126) {
        len = try r.takeInt(u16, .big);
        if (len < 126) return error.ProtocolError;
    } else if (len == 127) {
        len = try r.takeInt(u64, .big);
        if (len < 0x10000 or len >> 63 != 0) return error.ProtocolError;
    }
    if (opcode.isControl() and (!fin or len > 125)) return error.ProtocolError;
    const mask: ?[4]u8 = if (masked) (try r.takeArray(4)).* else null;
    return .{ .fin = fin, .opcode = opcode, .len = len, .mask = mask };
}

/// Reads `h`'s payload into `out` (exactly `h.len` bytes), unmasked.
pub fn readPayload(r: *Io.Reader, h: Header, out: []u8) !void {
    std.debug.assert(out.len == h.len);
    try r.readSliceAll(out);
    if (h.mask) |m| applyMask(out, m, 0);
}

pub fn applyMask(bytes: []u8, mask: [4]u8, offset: usize) void {
    for (bytes, offset..) |*b, i| b.* ^= mask[i % 4];
}

/// Writes one frame. A client passes a fresh random `mask`; a server null.
pub fn write(w: *Io.Writer, opcode: Opcode, fin: bool, payload: []const u8, mask: ?[4]u8) Io.Writer.Error!void {
    var head: [14]u8 = undefined;
    head[0] = @as(u8, if (fin) 0x80 else 0) | @intFromEnum(opcode);
    const m: u8 = if (mask != null) 0x80 else 0;
    var n: usize = 2;
    if (payload.len < 126) {
        head[1] = m | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xffff) {
        head[1] = m | 126;
        std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        head[1] = m | 127;
        std.mem.writeInt(u64, head[2..10], payload.len, .big);
        n = 10;
    }
    if (mask) |k| {
        @memcpy(head[n..][0..4], &k);
        n += 4;
    }
    try w.writeAll(head[0..n]);
    const k = mask orelse return w.writeAll(payload);
    var chunk: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < payload.len) {
        const len = @min(chunk.len, payload.len - i);
        @memcpy(chunk[0..len], payload[i..][0..len]);
        applyMask(chunk[0..len], k, i);
        try w.writeAll(chunk[0..len]);
        i += len;
    }
}

/// A close frame's payload: the code, then the reason.
pub fn closePayload(buf: *[125]u8, code: u16, reason: []const u8) []const u8 {
    if (code == Code.no_status) return buf[0..0];
    std.mem.writeInt(u16, buf[0..2], code, .big);
    const n = @min(reason.len, 123);
    @memcpy(buf[2..][0..n], reason[0..n]);
    return buf[0 .. 2 + n];
}

pub const Close = struct { code: u16, reason: []const u8 };

/// Parses a close frame's payload, checking its code and reason.
pub fn parseClose(payload: []const u8) Error!Close {
    if (payload.len == 0) return .{ .code = Code.no_status, .reason = "" };
    if (payload.len == 1) return error.ProtocolError;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (!validCloseCode(code)) return error.ProtocolError;
    const reason = payload[2..];
    if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;
    return .{ .code = code, .reason = reason };
}

/// The codes a close frame may carry (1005, 1006 and 1015 never travel).
pub fn validCloseCode(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1014 => true,
        3000...4999 => true,
        else => false,
    };
}

test "frames round-trip, masked and not, at every length encoding" {
    for ([_]usize{ 0, 5, 125, 126, 300, 0xffff, 0x10000 }) |len| {
        const payload = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(payload);
        for (payload, 0..) |*b, i| b.* = @truncate(i *% 7);
        for ([_]?[4]u8{ null, .{ 1, 2, 3, 4 } }) |mask| {
            var aw: Io.Writer.Allocating = .init(std.testing.allocator);
            defer aw.deinit();
            try write(&aw.writer, .binary, true, payload, mask);
            var r: Io.Reader = .fixed(aw.written());
            const h = try readHeader(&r, if (mask != null) .server else .client);
            try std.testing.expectEqual(len, h.len);
            try std.testing.expect(h.fin);
            const out = try std.testing.allocator.alloc(u8, len);
            defer std.testing.allocator.free(out);
            try readPayload(&r, h, out);
            try std.testing.expectEqualSlices(u8, payload, out);
        }
    }
}

test "a masked frame is on the wire as RFC 6455's example" {
    // Section 5.7: a masked "Hello".
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, .text, true, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d });
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, aw.written());
}

test "frames that break the rules" {
    const cases = [_][]const u8{
        &.{ 0x81, 0x85, 0, 0, 0, 0, 0 }, // masked, from a server
        &.{ 0xc1, 0x00 }, // a reserved bit
        &.{ 0x83, 0x00 }, // an unknown opcode
        &.{ 0x09, 0x00 }, // a ping that is not final
        &.{ 0x89, 0x7e, 0x00, 0x7e }, // a ping over 125 bytes
        &.{ 0x82, 0x7e, 0x00, 0x05 }, // a length not in its shortest form
    };
    for (cases) |bytes| {
        var r: Io.Reader = .fixed(bytes);
        try std.testing.expectError(error.ProtocolError, readHeader(&r, .client));
    }
}

test "close frames: codes and reasons" {
    var buf: [125]u8 = undefined;
    const p = closePayload(&buf, 4000, "bye");
    const c = try parseClose(p);
    try std.testing.expectEqual(@as(u16, 4000), c.code);
    try std.testing.expectEqualStrings("bye", c.reason);
    try std.testing.expectEqual(@as(u16, 1005), (try parseClose("")).code);
    try std.testing.expectError(error.ProtocolError, parseClose(&.{0x03}));
    try std.testing.expectError(error.ProtocolError, parseClose(&.{ 0x03, 0xed })); // 1005
    try std.testing.expectError(error.InvalidUtf8, parseClose(&.{ 0x03, 0xe8, 0xff }));
}
