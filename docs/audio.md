# Audio

`myzig.audio` plays sound from Zig: effects decoded once into memory and
played as often as they sound, music streamed from a file as it plays, and
sound the app makes itself, a synthesizer's or a game's. myzig mixes the
players and sends them to the system's output, which it loads when
something first plays: an app that plays nothing links none of it, and an
app that stopped playing closes the device a few seconds later.

```zig
const std = @import("std");
const myzig = @import("myzig");
const audio = myzig.audio;

pub fn main(init: std.process.Init) !void {
    const engine = try audio.Engine.create(init.gpa, init.io, .{});
    defer engine.destroy();

    const hoe = try engine.decodeSound(@embedFile("hoe.wav")); // decoded once
    defer hoe.release();
    engine.play(hoe); // as often as it sounds, over itself

    const music = try engine.openStream("spring.wav"); // decoded as it plays
    music.setLoop(true).setVolume(0.6).play();
    // ...
}
```

The `piano` example plays notes it synthesizes, and the `farm` example
(`examples/farm`) has effects and a tune made as it plays.

## The engine

`audio.Engine.create(gpa, io, options)` makes the engine; `destroy` stops
everything and closes the output. `gpa` must be safe from several threads:
players are allocated on the app's threads and freed after the output's
thread let them go. Every method of the engine and its players is safe
from any thread.

`audio.Options` has:

- `device`: `.system` plays on the system's default output. `.manual`
  opens none: the app, or a test, pulls the mixed frames itself with
  `engine.render(out)`, which fills interleaved stereo frames at
  `audio.rate` and returns whether anything played. The `piano` example
  uses it when it runs headless (`--myzig-hidden`, `--myzig-snapshot`), so
  its tests make no sound.
- `idle_close_ms`: how long the output stays open with nothing playing
  (5000).

`engine.setVolume(v)` sets the volume of everything, 1 as decoded.

## Sounds and streams

A `Sound` holds decoded samples in memory, which any number of players
read at once. It is reference counted: `release` it when the app is done,
and it is freed once its last player is gone too.

- `engine.decodeSound(bytes)` decodes a WAV, Ogg Vorbis or MP3 file (told by its first bytes) in memory (the bytes of
  `@embedFile`, or a file read) into a sound, which copies what it needs.
- `engine.newSound(sample_rate, channels, samples)` makes a sound of
  samples the app computed, interleaved floats allocated with the
  engine's `gpa`, which the sound takes.

A stream decodes as it plays, for music too long to keep in memory, or for
sound the app makes as it plays:

- `engine.openStream(path)` returns a paused player of a WAV, Ogg Vorbis or MP3 file (told by its first bytes).
- `engine.newStreamPlayer(decoder)` returns a paused player of any
  `audio.Decoder`, which it closes with the player.

A `Decoder` is an interface of the app's: a `ptr`, a `vtable` of `read`,
`seek` and `deinit`, its `rate`, `channels`, and `frames` (null for an
endless stream). `read` fills a buffer with a whole number of interleaved
float frames and returns how many it read, 0 only at the end:

```zig
const Tone = struct {
    gpa: std.mem.Allocator,
    pos: u64 = 0,

    fn decoder(gpa: std.mem.Allocator) !audio.Decoder {
        const t = try gpa.create(Tone);
        t.* = .{ .gpa = gpa };
        return .{ .ptr = t, .vtable = &vtable, .rate = 48000, .channels = 1, .frames = null };
    }

    const vtable: audio.Decoder.VTable = .{ .read = read, .seek = seek, .deinit = deinit };

    fn read(p: *anyopaque, dst: []f32) anyerror!usize {
        const t: *Tone = @ptrCast(@alignCast(p));
        for (dst) |*s| {
            s.* = 0.2 * @sin(2 * std.math.pi * 440 * @as(f32, @floatFromInt(t.pos)) / 48000);
            t.pos += 1;
        }
        return dst.len; // mono: one sample a frame
    }
    fn seek(p: *anyopaque, frame: u64) anyerror!void {
        const t: *Tone = @ptrCast(@alignCast(p));
        t.pos = frame;
    }
    fn deinit(p: *anyopaque) void {
        const t: *Tone = @ptrCast(@alignCast(p));
        t.gpa.destroy(t);
    }
};

const tone = try engine.newStreamPlayer(try Tone.decoder(gpa));
tone.play();
```

`read` runs on the output's thread, under the mixer's lock: it must be
quick and must not wait on the main thread.

## Players

`engine.play(sound)` plays a sound once, in a player of its own, freed
when it ends: what effects want. For more control,
`engine.newPlayer(sound)` returns a paused `Player` to set up first. A
player:

- `play()` plays from where it is, and after its end from the start
  again; `pause()` pauses, fading out over 5 ms; `stop()` pauses and goes
  back to the start.
- `playing()` tells whether it plays: false at its end, so a game can wait
  for a sound.
- `seek(seconds)` moves; `position()` is where it is, and `duration()` how
  long it plays (null when endless or unknown), in seconds.
- `setVolume(x)` (1 as decoded, 0 silent), `setPan(x)` (-1 left to 1
  right), `setSpeed(x)` (speed and pitch together, as a record's: 2 is an
  octave higher), `setLoop(on)` (starts again at the end, without a gap)
  and `setLoopRange(start, end)` (loops from `end`, null for the end, back
  to `start`: a tune's intro plays once, then its loop). They return the
  player, to chain them.
- `release()` lets it go: it plays on to its end, or stays paused, then it
  is freed. The player can't be used after.

```zig
const step = try engine.newPlayer(footstep);
step.setPan(-0.4).setSpeed(1.1).play();
step.release();
```

Starting, pausing and seeking in the middle of a sound fade in and out
over 5 ms, so they make no clicks.

## Formats

`audio.wav` reads WAV files of integer PCM of 8 to 32 bits and 32 or 64
bit floats, at any rate and with any number of channels, from memory or
from a file as they play. `audio.wav.write(writer, samples, rate,
channels, .pcm16)` (or `.float32`) writes float samples as a WAV file,
what a test that records a `manual` engine saves.

`audio.vorbis` decodes Ogg Vorbis (floors 0 and 1, residues 0–2, any
channels) and `audio.mp3` decodes MPEG-1/2/2.5 layer III (gapless with
LAME's tag, ID3v2 skipped). Both decode as they play, from memory or a
file, and both seek. Other formats: a `Decoder` of the app's.

## The output

The engine mixes at 48 kHz in stereo (`audio.rate`, `audio.channels`),
about 40 ms ahead, on a thread of its own that sleeps while nothing plays.
Players of other rates are resampled as they play, on a Catmull-Rom
spline; mono sounds play in both speakers, and pan between them.

| | output | loaded |
|---|---|---|
| macOS | an Audio Queue on the default output, which follows it | AudioToolbox, with `dlopen` |
| Linux | PulseAudio's simple API (which PipeWire serves too), else ALSA's default device | with `dlopen` |
| Windows | WASAPI in shared mode on the default output, opened again when the default changes or the device goes | COM |
| browsers | none yet | |

Where no output opens (no sound server, no device, a browser), players
still play on time, unheard, so they end when they would have, and
`engine.outputError()` tells why. The engine tries the real device again
after a while.
