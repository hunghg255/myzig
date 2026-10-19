//! The dates and times of messages, which a catalog links only when one of
//! its messages has an argument that is a date.
const std = @import("std");
const msg = @import("message.zig");
const date = @import("date.zig");
const data = @import("locale_data.zig");
const Writer = std.Io.Writer;

/// Writes `t` as an argument of a message: {t} as a short date and time,
/// {t, date, style} and {t, time, style} by style or skeleton.
pub fn write(w: *Writer, key: *const data.Key, t: date.DateTime, s: msg.DateStyle, kind: msg.ArgKind) Writer.Error!void {
    const o: date.DateOptions = switch (kind) {
        .date => if (s.skeleton.len > 0) .{ .skeleton = s.skeleton } else .{ .date = s.style },
        .time => if (s.skeleton.len > 0) .{ .skeleton = s.skeleton } else .{ .time = s.style },
        else => .{ .date = .short, .time = .short },
    };
    try date.writeOptions(w, key, t, o);
}
