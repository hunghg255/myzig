//! Tunes in the public domain: notes as "E5:0.5", a name with its octave
//! and a length in beats, "C4+E4+G4:1" for a chord, and "r:1" for a rest.
const std = @import("std");

pub const Song = struct {
    name: []const u8,
    bpm: f64,
    notes: []const u8,
};

pub const songs = [_]Song{
    .{ .name = "Twinkle, Twinkle", .bpm = 100, .notes =
    \\C4+C3:1 C4:1 G4+E3:1 G4:1 A4+F3:1 A4:1 G4+E3:2
    \\F4+D3:1 F4:1 E4+C3:1 E4:1 D4+G3:1 D4:1 C4+C3:2
    \\G4+E3:1 G4:1 F4+D3:1 F4:1 E4+C3:1 E4:1 D4+G3:2
    \\G4+E3:1 G4:1 F4+D3:1 F4:1 E4+C3:1 E4:1 D4+G3:2
    \\C4+C3:1 C4:1 G4+E3:1 G4:1 A4+F3:1 A4:1 G4+E3:2
    \\F4+D3:1 F4:1 E4+C3:1 E4:1 D4+G3:1 D4:1 C4+C3:2
    },
    .{ .name = "Ode to Joy", .bpm = 120, .notes =
    \\E4+C3:1 E4:1 F4:1 G4:1 G4+G3:1 F4:1 E4:1 D4:1
    \\C4+A3:1 C4:1 D4:1 E4:1 E4+G3:1.5 D4:0.5 D4:2
    \\E4+C3:1 E4:1 F4:1 G4:1 G4+G3:1 F4:1 E4:1 D4:1
    \\C4+A3:1 C4:1 D4:1 E4:1 D4+G3:1.5 C4:0.5 C4+C3:2
    },
    .{ .name = "Für Elise", .bpm = 66, .notes =
    \\E5:0.25 D#5:0.25 E5:0.25 D#5:0.25 E5:0.25 B4:0.25 D5:0.25 C5:0.25
    \\A4+A3:0.5 r:0.25 C4:0.25 E4:0.25 A4:0.25
    \\B4+E3:0.5 r:0.25 E4:0.25 G#4:0.25 B4:0.25
    \\C5+A3:0.5 r:0.25 E4:0.25 E5:0.25 D#5:0.25
    \\E5:0.25 D#5:0.25 E5:0.25 B4:0.25 D5:0.25 C5:0.25
    \\A4+A3:0.5 r:0.25 C4:0.25 E4:0.25 A4:0.25
    \\B4+E3:0.5 r:0.25 E4:0.25 C5:0.25 B4:0.25
    \\A4+A3:1.5
    },
    .{ .name = "Happy Birthday", .bpm = 100, .notes =
    \\G4:0.75 G4:0.25 A4+F3:1 G4:1 C5+E3:1 B4+G3:2
    \\G4:0.75 G4:0.25 A4+G3:1 G4:1 D5+F3:1 C5+E3:2
    \\G4:0.75 G4:0.25 G5+E3:1 E5:1 C5+A3:1 B4:1 A4+F3:1
    \\F5:0.75 F5:0.25 E5+C3:1 C5:1 D5+G3:1 C5+C3:2
    },
};

/// An event of a song: up to four notes held for a length in beats.
pub const Event = struct {
    notes: [4]u8 = undefined,
    count: u8 = 0,
    beats: f64,
};

/// The song's events, one after another.
pub const Events = struct {
    it: std.mem.TokenIterator(u8, .any),

    pub fn of(s: *const Song) Events {
        return .{ .it = std.mem.tokenizeAny(u8, s.notes, " \n") };
    }

    pub fn next(e: *Events) ?Event {
        const tok = e.it.next() orelse return null;
        const colon = std.mem.indexOfScalar(u8, tok, ':') orelse return null;
        var ev: Event = .{ .beats = std.fmt.parseFloat(f64, tok[colon + 1 ..]) catch 1 };
        const name = tok[0..colon];
        if (!std.mem.eql(u8, name, "r")) {
            var parts = std.mem.splitScalar(u8, name, '+');
            while (parts.next()) |n| if (ev.count < 4) {
                ev.notes[ev.count] = noteNumber(n);
                ev.count += 1;
            };
        }
        return ev;
    }
};

/// The MIDI number of a name such as C4 or G#3.
pub fn noteNumber(name: []const u8) u8 {
    const semis = [7]u8{ 9, 11, 0, 2, 4, 5, 7 }; // A B C D E F G
    var semi: u8 = semis[name[0] - 'A'];
    var rest = name[1..];
    if (rest.len > 0 and rest[0] == '#') {
        semi += 1;
        rest = rest[1..];
    }
    const octave = std.fmt.parseInt(u8, rest, 10) catch 4;
    return (octave + 1) * 12 + semi;
}

test noteNumber {
    try std.testing.expectEqual(@as(u8, 60), noteNumber("C4"));
    try std.testing.expectEqual(@as(u8, 69), noteNumber("A4"));
    try std.testing.expectEqual(@as(u8, 56), noteNumber("G#3"));
}
