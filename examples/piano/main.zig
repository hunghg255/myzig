//! A piano in native UI that plays with `myzig.audio`: click or drag
//! across its keys, play it from the keyboard, or have it play a tune.
//! Its sound is synthesized, a sound per key (`synth.zig`).
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const audio = myzig.audio;
const synth = @import("synth.zig");
const songs = @import("songs.zig");

const lowest = synth.lowest;
const highest = synth.highest;

// The keyboard's geometry, in points.
const white_w: f32 = 36;
const black_w: f32 = 22;
const keyboard_h: f32 = 180;
const black_h: f32 = 110;
const keyboard_w: f32 = @as(f32, whites()) * white_w;

/// Keys of a computer keyboard for the notes of two octaves: the lower
/// row and the one above it, as trackers lay them out; the comma plays
/// the C after M, as Q does.
const computer_keys = "zsxdcvgbhnjmq2w3er5t6y7ui";

fn black(note: u8) bool {
    return "010100101010"[note % 12] == '1';
}

fn whites() u8 {
    var n: u8 = 0;
    for (lowest..highest + 1) |note| n += @intFromBool(!black(@intCast(note)));
    return n;
}

/// Where `note`'s key is on the keyboard.
fn keyRect(note: u8) ui.Rect {
    var w: f32 = 0;
    for (lowest..note) |n| w += @floatFromInt(@intFromBool(!black(@intCast(n))));
    if (black(note)) return .{ .x = w * white_w - black_w / 2, .w = black_w, .h = black_h };
    return .{ .x = w * white_w, .w = white_w, .h = keyboard_h };
}

/// The note of the key at (x, y), black keys over white.
fn keyAt(x: f32, y: f32) ?u8 {
    for ([_]bool{ true, false }) |want_black| {
        for (lowest..highest + 1) |n| {
            const note: u8 = @intCast(n);
            if (black(note) == want_black and keyRect(note).contains(.{ .x = x, .y = y })) return note;
        }
    }
    return null;
}

const Timed = struct { note_down: f64, note_up: f64, ev: songs.Event };

const Piano = struct {
    engine: *audio.Engine,
    bank: *synth.Bank,
    held: [highest + 1]?audio.Player = @splat(null),
    /// What holds each key: a count of computer keys, the pointer and the tune.
    sources: [highest + 1]u8 = @splat(0),
    pointer: ?u8 = null,
    sustain: bool = false,
    /// Where the keyboard's lower row starts.
    octave: u8 = 4,
    /// The computer keys held, with the note each pressed.
    keys_down: [128]?u8 = @splat(null),
    // The tune playing: its events on the context's clock.
    song: ?usize = null,
    events: [128]Timed = undefined,
    event_count: usize = 0,
    next_down: usize = 0,
    next_up: usize = 0,
    start_song: bool = false,

    /// Lets go of the strings still sounding.
    fn deinit(p: *Piano) void {
        for (&p.held) |*h| if (h.*) |pl| {
            pl.stop();
            pl.release();
            h.* = null;
        };
    }

    fn down(p: *Piano, note: u8) void {
        if (note < lowest or note > highest) return;
        p.sources[note] += 1;
        if (p.sources[note] > 1) return;
        if (p.held[note]) |old| damp(old);
        p.held[note] = null;
        const s = p.bank.get(note) orelse return;
        const pl = p.engine.newPlayer(s) catch return;
        pl.play();
        p.held[note] = pl;
    }

    /// Lets go of `note`: the damper stops it, unless the pedal is down.
    fn up(p: *Piano, note: u8) void {
        if (note < lowest or note > highest or p.sources[note] == 0) return;
        p.sources[note] -= 1;
        if (p.sources[note] > 0 or p.sustain) return;
        if (p.held[note]) |pl| damp(pl);
        p.held[note] = null;
    }

    /// Lifting the pedal damps the strings of the keys up.
    fn pedal(p: *Piano, on: bool) void {
        p.sustain = on;
        if (on) return;
        for (&p.held, p.sources) |*h, n| if (n == 0) if (h.*) |pl| {
            damp(pl);
            h.* = null;
        };
    }

    /// Stops a string as a damper does (a 5 ms fade), and lets it go.
    fn damp(pl: audio.Player) void {
        pl.pause();
        pl.release();
    }

    fn play(p: *Piano, i: usize) void {
        p.stop();
        p.song = i;
        p.start_song = true;
    }

    /// Lays the song's events out from `now`, each from the start, not
    /// after the last, so the tune keeps its tempo.
    fn schedule(p: *Piano, now: f64) void {
        const s = &songs.songs[p.song.?];
        const beat = 60 / s.bpm;
        var at = now;
        var it = songs.Events.of(s);
        p.event_count = 0;
        while (it.next()) |ev| {
            if (p.event_count == p.events.len) break;
            const len = ev.beats * beat;
            // Held for most of its length, as a pianist would.
            p.events[p.event_count] = .{ .note_down = at, .note_up = at + len * 0.9, .ev = ev };
            p.event_count += 1;
            at += len;
        }
        p.next_down = 0;
        p.next_up = 0;
    }

    /// Presses and lets go of the song's notes due by `now`.
    fn advance(p: *Piano, c: *ui.Context, now: f64) void {
        if (p.song == null) return;
        if (p.start_song) {
            p.schedule(now);
            p.start_song = false;
        }
        while (p.next_down < p.event_count and p.events[p.next_down].note_down <= now) : (p.next_down += 1) {
            const ev = p.events[p.next_down].ev;
            for (ev.notes[0..ev.count]) |n| p.down(n);
        }
        while (p.next_up < p.next_down and p.events[p.next_up].note_up <= now) : (p.next_up += 1) {
            const ev = p.events[p.next_up].ev;
            for (ev.notes[0..ev.count]) |n| p.up(n);
        }
        if (p.next_up == p.event_count) {
            p.song = null;
            return;
        }
        const next = if (p.next_down < p.event_count) @min(p.events[p.next_down].note_down, p.events[p.next_up].note_up) else p.events[p.next_up].note_up;
        c.frameIn(@floatCast(@max(0, next - now)));
    }

    /// Stops the tune, letting go of what it holds.
    fn stop(p: *Piano) void {
        if (p.song == null) return;
        for (p.events[p.next_up..p.next_down]) |t| for (t.ev.notes[0..t.ev.count]) |n| p.up(n);
        p.song = null;
        p.start_song = false;
    }

    fn keys(p: *Piano, c: *ui.Context) void {
        c.wants_keys = true;
        if (c.input.cmd or c.input.ctrl) return;
        if (c.input.key_down) |k| switch (k) {
            ' ' => p.pedal(true),
            ui.Shortcut.left => p.octave = @max(p.octave - 1, 3),
            ui.Shortcut.right => p.octave = @min(p.octave + 1, 4),
            else => if (k < 128) {
                const off: ?u8 = if (k == ',') 12 else if (std.mem.indexOfScalar(u8, computer_keys, @intCast(k))) |i| @intCast(i) else null;
                if (off) |o| {
                    const note = (p.octave + 1) * 12 + o;
                    p.keys_down[k] = note;
                    p.down(note);
                }
            },
        };
        if (c.input.key_up) |k| {
            if (k == ' ') p.pedal(false) else if (k < 128) if (p.keys_down[k]) |note| {
                p.keys_down[k] = null;
                p.up(note);
            };
        }
    }

    fn view(p: *Piano, c: *ui.Context) void {
        const th = c.theme;
        p.keys(c);
        p.advance(c, c.time);
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 18, .padding = .all(20) });
        defer ui.end(c);
        {
            ui.row(c, .{ .gap = 8 });
            defer ui.end(c);
            for (songs.songs, 0..) |s, i| if (ui.button(c, s.name, .{}).clicked) p.play(i);
            if (ui.button(c, "Stop", .{ .disabled = p.song == null }).clicked) p.stop();
        }
        p.keyboard(c);
        ui.text(c, c.print("Keys Z–M and Q–I play from C{d} · Space sustains · ← → change octaves", .{p.octave}), .{ .size = 12, .color = th.muted });
        if (p.engine.outputError()) |err| ui.text(c, c.print("No sound: {t}", .{err}), .{ .size = 12, .color = th.muted });
    }

    /// The keys, as wide as they can be up to their size, keeping their shape.
    fn keyboard(p: *Piano, c: *ui.Context) void {
        const th = c.theme;
        const id = c.peekId("keyboard");
        const room = if (c.rects.get(id)) |r| r.w else keyboard_w;
        const s = @min(1, room / keyboard_w);
        const box = c.open(.{ .width = .fill, .max_width = keyboard_w, .height = .{ .px = keyboard_h * s } }, "keyboard");
        defer c.end();
        const it = c.interact(box, .{ .focusable = true });
        if (it.hovered) c.cursor_hand = false;
        // Dragging across the keys plays each it enters.
        if (it.pressed) {
            c.wants_moves = true;
            const r = it.rect orelse ui.Rect{};
            const note = keyAt((c.input.mouse.x - r.x) / s, (c.input.mouse.y - r.y) / s);
            if (note != p.pointer) {
                if (p.pointer) |n| p.up(n);
                p.pointer = note;
                if (note) |n| p.down(n);
            }
        } else if (p.pointer) |n| {
            p.up(n);
            p.pointer = null;
        }
        const label_style: ui.TextStyle = .{ .size = 11 * s };
        for ([_]bool{ false, true }) |blacks| {
            for (lowest..highest + 1) |n| {
                const note: u8 = @intCast(n);
                if (black(note) != blacks) continue;
                const k = keyRect(note);
                const sounding = p.sources[note] > 0;
                const face: ui.Color = if (blacks) (if (sounding) th.accent else .hex(0x18181b)) else if (sounding) th.accent.mix(.hex(0xfbfbf8), 0.55) else .hex(0xfbfbf8);
                _ = c.open(.{
                    .absolute = true,
                    .offset = .{ .x = k.x * s, .y = k.y * s },
                    .width = .{ .px = k.w * s },
                    .height = .{ .px = k.h * s },
                    .radius = @as(f32, if (blacks) 3 else 4) * s,
                    .background = face,
                    .border = if (blacks) null else ui.Color.hex(0xa1a1aa),
                    .align_items = .center,
                    .justify = .end,
                    .padding = .{ .bottom = 10 * s },
                    .gap = 4 * s,
                }, null);
                if (!blacks and note % 12 == 0) _ = c.leaf(.{}, .{ .text = .{ .str = c.print("C{d}", .{note / 12 - 1}), .style = .{ .size = 10 * s }, .color = .hex(0xa1a1aa) } }, null);
                const base = (@as(u16, p.octave) + 1) * 12;
                if (note >= base and note < base + computer_keys.len) {
                    const ch = computer_keys[note - base];
                    const lbl = c.print("{c}", .{std.ascii.toUpper(ch)});
                    _ = c.leaf(.{}, .{ .text = .{ .str = lbl, .style = label_style, .color = if (blacks) .hex(0xd4d4d8) else .hex(0x71717a) } }, null);
                }
                c.end();
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Piano" });
    defer app.destroy();
    // Headless runs (snapshots, scripts) play into no device.
    const engine = try audio.Engine.create(init.gpa, init.io, .{ .device = if (app.flags.hidden) .manual else .system });
    defer engine.destroy();
    var bank: synth.Bank = .{ .engine = engine, .gpa = init.gpa };
    bank.start();
    defer bank.deinit();
    var p: Piano = .{ .engine = engine, .bank = &bank };
    defer p.deinit();
    _ = try app.newWindow(.{
        .title = "Piano",
        .width = keyboard_w + 48,
        .height = 330,
        .content = .{ .view = .init(&p, Piano.view) },
    });
    try app.run();
}

test {
    _ = songs;
}
