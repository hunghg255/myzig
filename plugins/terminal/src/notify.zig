//! Desktop notifications programs ask for (an agent done, a build failed),
//! which the emulator leaves out: OSC 9 (`ESC ] 9 ; text BEL`, as iTerm2
//! and ConEmu take it, but `9;4;` progress) and OSC 777
//! (`ESC ] 777 ; notify ; title ; body BEL`, as rxvt's), found in the
//! output as it comes, split across reads as it may be.
const std = @import("std");

pub const Scanner = struct {
    state: enum { text, esc, osc, osc_esc } = .text,
    buf: [512]u8 = undefined,
    len: usize = 0,
    /// The last notification's text: its title and body, by a space.
    note: [512]u8 = undefined,
    note_len: usize = 0,
    /// Set when a notification came; the reader clears it.
    pending: bool = false,

    pub fn feed(s: *Scanner, bytes: []const u8) void {
        for (bytes) |b| switch (s.state) {
            .text => if (b == 0x1b) {
                s.state = .esc;
            },
            .esc => {
                s.state = if (b == ']') .osc else .text;
                s.len = 0;
            },
            .osc => switch (b) {
                0x07 => s.done(),
                0x1b => s.state = .osc_esc,
                else => if (s.len < s.buf.len) {
                    s.buf[s.len] = b;
                    s.len += 1;
                } else {
                    // Too long for a notification: something else.
                    s.state = .text;
                },
            },
            .osc_esc => if (b == '\\') s.done() else {
                s.state = if (b == ']') .osc else .text;
                s.len = 0;
            },
        };
    }

    fn done(s: *Scanner) void {
        s.state = .text;
        const p = s.buf[0..s.len];
        if (std.mem.startsWith(u8, p, "9;") and !std.mem.startsWith(u8, p, "9;4;")) {
            s.set(p[2..], "");
        } else if (std.mem.startsWith(u8, p, "777;notify;")) {
            const rest = p[11..];
            const semi = std.mem.indexOfScalar(u8, rest, ';');
            if (semi) |k| s.set(rest[0..k], rest[k + 1 ..]) else s.set(rest, "");
        }
    }

    fn set(s: *Scanner, title: []const u8, body: []const u8) void {
        var w: std.Io.Writer = .fixed(&s.note);
        w.writeAll(std.mem.trim(u8, title, " ")) catch {};
        if (body.len > 0) {
            if (w.buffered().len > 0) w.writeAll(" ") catch {};
            w.writeAll(std.mem.trim(u8, body, " ")) catch {};
        }
        s.note_len = w.buffered().len;
        s.pending = true;
    }
};

test Scanner {
    var s: Scanner = .{};
    s.feed("hi \x1b]9;Build don");
    try std.testing.expect(!s.pending);
    s.feed("e\x07 more");
    try std.testing.expect(s.pending);
    try std.testing.expectEqualStrings("Build done", s.note[0..s.note_len]);
    s.pending = false;
    s.feed("\x1b]777;notify;Claude;Waiting for you\x1b\\");
    try std.testing.expectEqualStrings("Claude Waiting for you", s.note[0..s.note_len]);
    s.pending = false;
    s.feed("\x1b]9;4;1;50\x07\x1b]0;title\x07");
    try std.testing.expect(!s.pending);
}
