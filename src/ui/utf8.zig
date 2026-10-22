//! UTF-8 helpers every platform shares.

const std = @import("std");

/// The length of the UTF-8 sequence starting with `b` (1 for a stray byte).
pub fn seqLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b >> 5 == 0b110) return 2;
    if (b >> 4 == 0b1110) return 3;
    if (b >> 3 == 0b11110) return 4;
    return 1;
}

/// The code point of `s`, one sequence, or an error when `s` is cut short or
/// starts within a sequence, where `std.unicode.utf8Decode` asserts (a text cut
/// at a byte, not a character, would crash).
pub fn decode(s: []const u8) error{Invalid}!u21 {
    if (s.len == 0 or s.len != seqLen(s[0])) return error.Invalid;
    return std.unicode.utf8Decode(s) catch error.Invalid;
}

test "decode refuses a sequence cut short" {
    try std.testing.expectEqual(@as(u21, 0x1ea1), try decode("\xe1\xba\xa1"));
    try std.testing.expectError(error.Invalid, decode("\xe1\xba"));
    try std.testing.expectError(error.Invalid, decode("\xba\xa1"));
    try std.testing.expectEqual(@as(u21, 'a'), try decode("a"));
}
