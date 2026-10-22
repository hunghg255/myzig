//! The Unicode bidirectional algorithm (UAX #9), for text myzig shapes
//! itself: a paragraph's direction from its first strong character (P2,
//! P3), explicit embeddings, overrides and isolates (X1–X10), weak and
//! neutral types (W1–W7, N1, N2), implicit levels (I1, I2) and the reset
//! of trailing whitespace (L1), giving runs of one level in logical order;
//! `visual` reorders them for display (L2). Bracket pairs (N0) are left
//! to N1 and N2, which resolve the common cases the same; mirrored glyphs
//! are the shaper's (HarfBuzz and DirectWrite mirror in right-to-left runs).
const std = @import("std");
const classes = @import("bidi_class.zig");
const utf8 = @import("utf8.zig");
const Class = classes.Class;

pub const mayHaveRtl = classes.mayHaveRtl;

/// Bytes `start`..`end` of the text, at embedding `level` (odd: right to left).
pub const Run = struct {
    start: u32,
    end: u32,
    level: u8,

    pub fn rtl(r: Run) bool {
        return r.level & 1 != 0;
    }
};

const max_depth = 125;

fn decode(s: []const u8, i: usize) struct { cp: u21, n: usize } {
    const n = @min(utf8.seqLen(s[i]), s.len - i);
    const cp = utf8.decode(s[i .. i + n]) catch return .{ .cp = 0xfffd, .n = 1 };
    return .{ .cp = cp, .n = n };
}

/// The direction of the first strong character of `s` outside isolates:
/// true for right to left, false for left to right, null when it has none.
pub fn firstStrong(s: []const u8) ?bool {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
        i += d.n;
        const c = classes.of(d.cp);
        if (c.isolateInitiator()) {
            depth += 1;
        } else if (c == .PDI) {
            if (depth > 0) depth -= 1;
        } else if (c == .B) {
            break;
        } else if (depth == 0) {
            if (c == .L) return false;
            if (c.strongRtl()) return true;
        }
    }
    return null;
}

/// What resolving a paragraph works on, a character at a time.
const Chars = struct {
    starts: []u32,
    orig: []Class,
    types: []Class,
    levels: []u8,
    /// The index of the PDI closing each isolate initiator (n if none).
    match: []u32,
};

/// Splits `s`, one paragraph, into runs of one level (logical order),
/// appended to `out`; returns the paragraph's level. `base` forces it (0
/// or 1); null takes the first strong character's, else left to right.
pub fn resolve(gpa: std.mem.Allocator, s: []const u8, base: ?u8, out: *std.ArrayList(Run)) !u8 {
    var n: usize = 0;
    {
        var i: usize = 0;
        while (i < s.len) : (n += 1) i += decode(s, i).n;
    }
    const para: u8 = base orelse if (firstStrong(s) orelse false) 1 else 0;
    if (n == 0) return para;
    const words = try gpa.alloc(u32, 2 * n);
    defer gpa.free(words);
    const bytes = try gpa.alloc(u8, 3 * n);
    defer gpa.free(bytes);
    var ch: Chars = .{
        .starts = words[0..n],
        .match = words[n .. 2 * n],
        .orig = @ptrCast(bytes[0..n]),
        .types = @ptrCast(bytes[n .. 2 * n]),
        .levels = bytes[2 * n .. 3 * n],
    };
    {
        var i: usize = 0;
        var k: usize = 0;
        while (i < s.len) : (k += 1) {
            const d = decode(s, i);
            ch.starts[k] = @intCast(i);
            ch.orig[k] = classes.of(d.cp);
            ch.types[k] = ch.orig[k];
            i += d.n;
        }
    }
    matchIsolates(&ch);
    explicit(&ch, s, para);
    try sequences(gpa, &ch, para);
    // Removed characters take the level of the one before them.
    for (0..n) |k| if (ch.orig[k].removed()) {
        ch.levels[k] = if (k > 0) ch.levels[k - 1] else para;
    };
    lineReset(&ch, para);
    var start: usize = 0;
    for (1..n + 1) |k| {
        if (k < n and ch.levels[k] == ch.levels[start]) continue;
        try out.append(gpa, .{ .start = ch.starts[start], .end = if (k < n) ch.starts[k] else @intCast(s.len), .level = ch.levels[start] });
        start = k;
    }
    return para;
}

/// BD9: the PDI matching each isolate initiator.
fn matchIsolates(ch: *Chars) void {
    const n = ch.orig.len;
    @memset(ch.match, @intCast(n));
    var stack: [max_depth + 2]u32 = undefined;
    var depth: usize = 0;
    var overflow: usize = 0;
    for (ch.orig, 0..) |c, k| {
        if (c.isolateInitiator()) {
            if (depth < stack.len) {
                stack[depth] = @intCast(k);
                depth += 1;
            } else overflow += 1;
        } else if (c == .PDI) {
            if (overflow > 0) {
                overflow -= 1;
            } else if (depth > 0) {
                depth -= 1;
                ch.match[stack[depth]] = @intCast(k);
            }
        } else if (c == .B) {
            depth = 0;
            overflow = 0;
        }
    }
}

const Entry = struct { level: u8, override: ?Class, isolate: bool };

/// X1–X8: explicit levels and overrides.
fn explicit(ch: *Chars, s: []const u8, para: u8) void {
    var stack: [max_depth + 2]Entry = undefined;
    stack[0] = .{ .level = para, .override = null, .isolate = false };
    var depth: usize = 1;
    var overflow_isolate: usize = 0;
    var overflow_embedding: usize = 0;
    var valid_isolate: usize = 0;
    for (ch.orig, 0..) |c, k| {
        const top = stack[depth - 1];
        switch (c) {
            .RLE, .LRE, .RLO, .LRO => {
                const rtl = c == .RLE or c == .RLO;
                const level: u8 = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                ch.levels[k] = top.level;
                if (level <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    stack[depth] = .{ .level = level, .override = if (c == .RLO) .R else if (c == .LRO) .L else null, .isolate = false };
                    depth += 1;
                } else if (overflow_isolate == 0) overflow_embedding += 1;
            },
            .RLI, .LRI, .FSI => {
                ch.levels[k] = top.level;
                if (top.override) |o| ch.types[k] = o;
                var rtl = c == .RLI;
                if (c == .FSI) {
                    const end = if (ch.match[k] < ch.orig.len) ch.starts[ch.match[k]] else s.len;
                    const from = if (k + 1 < ch.orig.len) ch.starts[k + 1] else s.len;
                    rtl = firstStrong(s[from..end]) orelse false;
                }
                const level: u8 = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                if (level <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    valid_isolate += 1;
                    stack[depth] = .{ .level = level, .override = null, .isolate = true };
                    depth += 1;
                } else overflow_isolate += 1;
            },
            .PDI => {
                if (overflow_isolate > 0) {
                    overflow_isolate -= 1;
                } else if (valid_isolate > 0) {
                    overflow_embedding = 0;
                    while (!stack[depth - 1].isolate) depth -= 1;
                    depth -= 1;
                    valid_isolate -= 1;
                }
                const now = stack[depth - 1];
                ch.levels[k] = now.level;
                if (now.override) |o| ch.types[k] = o;
            },
            .PDF => {
                if (overflow_isolate > 0) {} else if (overflow_embedding > 0) {
                    overflow_embedding -= 1;
                } else if (!top.isolate and depth >= 2) depth -= 1;
                ch.levels[k] = stack[depth - 1].level;
            },
            .B => ch.levels[k] = para,
            .BN => ch.levels[k] = top.level,
            else => {
                ch.levels[k] = top.level;
                if (top.override) |o| ch.types[k] = o;
            },
        }
    }
}

/// X10: the isolating run sequences, each resolved (W1–I2).
fn sequences(gpa: std.mem.Allocator, ch: *Chars, para: u8) !void {
    const n = ch.orig.len;
    // Level runs of the characters X9 keeps: [start, end) of indices.
    var runs: std.ArrayList([2]u32) = .empty;
    defer runs.deinit(gpa);
    var run_of = try gpa.alloc(u32, n);
    defer gpa.free(run_of);
    {
        var cur: ?[2]u32 = null;
        var last: u32 = 0;
        for (0..n) |k| {
            if (ch.orig[k].removed()) continue;
            if (cur) |c| {
                if (ch.levels[k] != ch.levels[c[0]]) {
                    try runs.append(gpa, .{ c[0], last + 1 });
                    cur = .{ @intCast(k), 0 };
                }
            } else cur = .{ @intCast(k), 0 };
            run_of[k] = @intCast(runs.items.len);
            last = @intCast(k);
        }
        if (cur) |c| try runs.append(gpa, .{ c[0], last + 1 });
    }
    var seq: std.ArrayList(u32) = .empty;
    defer seq.deinit(gpa);
    for (runs.items) |rr| {
        // A run starting with a PDI that closes an isolate continues one.
        if (ch.orig[rr[0]] == .PDI and closesIsolate(ch, rr[0])) continue;
        seq.clearRetainingCapacity();
        var cur = rr;
        while (true) {
            for (cur[0]..cur[1]) |k| if (!ch.orig[k].removed()) try seq.append(gpa, @intCast(k));
            const last = seq.items[seq.items.len - 1];
            if (!ch.orig[last].isolateInitiator() or ch.match[last] >= n) break;
            cur = runs.items[run_of[ch.match[last]]];
        }
        resolveSequence(ch, seq.items, para);
    }
}

fn closesIsolate(ch: *const Chars, k: usize) bool {
    for (0..k) |j| if (ch.match[j] == k) return true;
    return false;
}

/// The level of the nearest kept character before (`dir` -1) or after (+1)
/// index `k`, or the paragraph's.
fn neighborLevel(ch: *const Chars, k: usize, comptime dir: i2, para: u8) u8 {
    var j: isize = @as(isize, @intCast(k)) + dir;
    while (j >= 0 and j < ch.orig.len) : (j += dir) {
        const u: usize = @intCast(j);
        if (!ch.orig[u].removed()) return ch.levels[u];
    }
    return para;
}

fn dirOf(level: u8) Class {
    return if (level & 1 != 0) .R else .L;
}

fn neutral(c: Class) bool {
    return switch (c) {
        .B, .S, .WS, .ON, .LRI, .RLI, .FSI, .PDI => true,
        else => false,
    };
}

fn resolveSequence(ch: *Chars, seq: []const u32, para: u8) void {
    if (seq.len == 0) return;
    const level = ch.levels[seq[0]];
    const first = seq[0];
    const last = seq[seq.len - 1];
    const sos = dirOf(@max(level, neighborLevel(ch, first, -1, para)));
    const after: u8 = if (ch.orig[last].isolateInitiator()) para else neighborLevel(ch, last, 1, para);
    const eos = dirOf(@max(level, after));
    const t = ch.types;
    // W1: marks take the type of what they follow.
    for (seq, 0..) |k, i| if (t[k] == .NSM) {
        if (i == 0) {
            t[k] = sos;
        } else {
            const p = t[seq[i - 1]];
            t[k] = if (p.isolateInitiator() or p == .PDI) .ON else p;
        }
    };
    // W2, W3: European digits after Arabic letters are Arabic; AL is R.
    var strong = sos;
    for (seq) |k| switch (t[k]) {
        .L, .R => strong = t[k],
        .AL => {
            strong = .AL;
            t[k] = .R;
        },
        .EN => if (strong == .AL) {
            t[k] = .AN;
        },
        else => {},
    };
    // W4: one separator between two numbers of a kind joins them.
    for (seq, 0..) |k, i| {
        if (i == 0 or i + 1 >= seq.len) continue;
        const a = t[seq[i - 1]];
        const b = t[seq[i + 1]];
        if (t[k] == .ES and a == .EN and b == .EN) t[k] = .EN else if (t[k] == .CS and a == b and (a == .EN or a == .AN)) t[k] = a;
    }
    // W5: terminators next to European digits are European digits.
    var i: usize = 0;
    while (i < seq.len) {
        if (t[seq[i]] != .ET) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < seq.len and t[seq[j]] == .ET) j += 1;
        const touches = (i > 0 and t[seq[i - 1]] == .EN) or (j < seq.len and t[seq[j]] == .EN);
        if (touches) for (seq[i..j]) |k| {
            t[k] = .EN;
        };
        i = j;
    }
    // W6, W7.
    strong = sos;
    for (seq) |k| switch (t[k]) {
        .ES, .ET, .CS => t[k] = .ON,
        .L, .R => strong = t[k],
        .EN => if (strong == .L) {
            t[k] = .L;
        },
        else => {},
    };
    // N1, N2: neutrals between two of a direction take it, others the
    // embedding's (numbers count as right to left).
    const e = dirOf(level);
    i = 0;
    while (i < seq.len) {
        if (!neutral(t[seq[i]])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < seq.len and neutral(t[seq[j]])) j += 1;
        const before = if (i == 0) sos else strongish(t[seq[i - 1]]);
        const next = if (j == seq.len) eos else strongish(t[seq[j]]);
        const d = if (before == next) before else e;
        for (seq[i..j]) |k| t[k] = d;
        i = j;
    }
    // I1, I2.
    for (seq) |k| {
        const odd = ch.levels[k] & 1 != 0;
        switch (t[k]) {
            .R => if (!odd) {
                ch.levels[k] += 1;
            },
            .AN, .EN => ch.levels[k] += if (odd) 1 else 2,
            .L => if (odd) {
                ch.levels[k] += 1;
            },
            else => {},
        }
    }
}

fn strongish(c: Class) Class {
    return switch (c) {
        .EN, .AN, .R => .R,
        else => .L,
    };
}

/// L1: separators, and whitespace before them or the line's end, at the
/// paragraph's level.
fn lineReset(ch: *Chars, para: u8) void {
    const n = ch.orig.len;
    var trailing = true;
    var k = n;
    while (k > 0) {
        k -= 1;
        const c = ch.orig[k];
        if (c == .S or c == .B) {
            ch.levels[k] = para;
            trailing = true;
        } else if (c == .WS or c.isolateInitiator() or c == .PDI or c.removed()) {
            if (trailing) ch.levels[k] = para;
        } else trailing = false;
    }
}

/// L2: the order runs of a line are shown in, left to right, as indices
/// into `runs` (logical order), written to `order`.
pub fn visual(runs: []const Run, order: []u32) void {
    for (order, 0..) |*o, i| o.* = @intCast(i);
    var highest: u8 = 0;
    var lowest_odd: u8 = 255;
    for (runs) |rn| {
        highest = @max(highest, rn.level);
        if (rn.level & 1 != 0) lowest_odd = @min(lowest_odd, rn.level);
    }
    if (lowest_odd == 255) return;
    var lvl = highest;
    while (lvl >= lowest_odd) : (lvl -= 1) {
        var i: usize = 0;
        while (i < order.len) {
            if (runs[order[i]].level < lvl) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < order.len and runs[order[j]].level >= lvl) j += 1;
            std.mem.reverse(u32, order[i..j]);
            i = j;
        }
        if (lvl == 0) break;
    }
}

fn expectRuns(s: []const u8, base: ?u8, want: []const Run) !void {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Run) = .empty;
    defer out.deinit(gpa);
    _ = try resolve(gpa, s, base, &out);
    try std.testing.expectEqualSlices(Run, want, out.items);
}

test "levels of mixed text" {
    // "abc אבג def": the Hebrew word at level 1 in a left-to-right paragraph.
    try expectRuns("abc \xd7\x90\xd7\x91\xd7\x92 def", null, &.{
        .{ .start = 0, .end = 4, .level = 0 },
        .{ .start = 4, .end = 10, .level = 1 },
        .{ .start = 10, .end = 14, .level = 0 },
    });
    // A Hebrew paragraph with a number: digits at level 2.
    try expectRuns("\xd7\x90 12", null, &.{
        .{ .start = 0, .end = 3, .level = 1 },
        .{ .start = 3, .end = 5, .level = 2 },
    });
    // Trailing whitespace goes back to the paragraph's level (L1).
    try expectRuns("abc \xd7\x90 ", null, &.{
        .{ .start = 0, .end = 4, .level = 0 },
        .{ .start = 4, .end = 6, .level = 1 },
        .{ .start = 6, .end = 7, .level = 0 },
    });
    // An Arabic paragraph: a Latin word inside at level 2.
    try expectRuns("\xd8\xa8 ok \xd8\xa8", null, &.{
        .{ .start = 0, .end = 3, .level = 1 },
        .{ .start = 3, .end = 5, .level = 2 },
        .{ .start = 5, .end = 8, .level = 1 },
    });
    try std.testing.expectEqual(@as(?bool, true), firstStrong("123 \xd7\x90 abc"));
    try std.testing.expectEqual(@as(?bool, null), firstStrong("123 ..."));
}

test "explicit isolates and overrides" {
    // RLO forces Latin letters to read right to left.
    try expectRuns("\u{202E}ab\u{202C}", 0, &.{
        .{ .start = 0, .end = 3, .level = 0 },
        .{ .start = 3, .end = 5, .level = 1 },
        .{ .start = 5, .end = 8, .level = 0 },
    });
    // An RLI isolate in a left-to-right paragraph.
    try expectRuns("a\u{2067}\xd7\x90\u{2069}b", null, &.{
        .{ .start = 0, .end = 4, .level = 0 },
        .{ .start = 4, .end = 6, .level = 1 },
        .{ .start = 6, .end = 10, .level = 0 },
    });
}

test "visual order" {
    const runs = [_]Run{
        .{ .start = 0, .end = 1, .level = 0 },
        .{ .start = 1, .end = 2, .level = 1 },
        .{ .start = 2, .end = 3, .level = 2 },
        .{ .start = 3, .end = 4, .level = 1 },
        .{ .start = 4, .end = 5, .level = 0 },
    };
    var order: [5]u32 = undefined;
    visual(&runs, &order);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 2, 1, 4 }, &order);
}
