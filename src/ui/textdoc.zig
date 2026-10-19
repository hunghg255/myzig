//! The text a text area or a code editor edits: a rope, its undo history
//! and a log of the lines each edit replaced, which the views read to
//! update what they keep per line (wrapped rows, highlighting states)
//! without looking at the rest of the document.
//!
//!     var doc = ui.TextDoc.init(gpa, source);
//!     defer doc.deinit();
//!     doc.replace(0, 0, "// Generated.\n"); // one step of undo
const std = @import("std");
const Rope = @import("rope.zig").Rope;

/// A selection: where it was started and its caret, byte offsets.
pub const Sel = struct {
    caret: usize = 0,
    anchor: usize = 0,

    pub fn at(i: usize) Sel {
        return .{ .caret = i, .anchor = i };
    }

    pub fn lo(s: Sel) usize {
        return @min(s.caret, s.anchor);
    }

    pub fn hi(s: Sel) usize {
        return @max(s.caret, s.anchor);
    }

    pub fn empty(s: Sel) bool {
        return s.caret == s.anchor;
    }
};

/// Lines `line` to `line + old` of the text before an edit became lines
/// `line` to `line + new` after it (each count at least 1: the line the
/// edit starts in).
pub const Splice = struct { line: usize, old: usize, new: usize };

/// What a step of undo groups: typing in a row, deleting in a row, or
/// one edit of anything else.
pub const Kind = enum { typing, deleting, other };

const Change = struct { at: usize, removed: []u8, inserted: []u8 };

const Step = struct {
    changes: std.ArrayList(Change) = .empty,
    before: Sel,
    after: Sel,
    kind: Kind,
    time: f64,

    fn deinit(s: *Step, gpa: std.mem.Allocator) void {
        for (s.changes.items) |ch| {
            gpa.free(ch.removed);
            gpa.free(ch.inserted);
        }
        s.changes.deinit(gpa);
    }
};

pub const TextDoc = struct {
    gpa: std.mem.Allocator,
    rope: Rope,
    undo_steps: std.ArrayList(Step) = .empty,
    redo_steps: std.ArrayList(Step) = .empty,
    /// The last step takes more typing (or deleting) of its kind.
    open: bool = false,
    /// Bumped by every edit.
    version: u64 = 0,
    /// The newest splices; `splice_base` is the sequence number of the
    /// first. A reader that fell behind them reads the whole text again.
    splices: std.ArrayList(Splice) = .empty,
    splice_base: u64 = 0,
    /// The most steps undo keeps.
    max_undo: usize = 1000,
    /// Seconds within which typing joins the step before.
    group_seconds: f64 = 1,

    pub fn init(gpa: std.mem.Allocator, s: []const u8) TextDoc {
        return .{ .gpa = gpa, .rope = .init(gpa, s) };
    }

    pub fn deinit(d: *TextDoc) void {
        d.rope.deinit();
        clearSteps(d.gpa, &d.undo_steps);
        clearSteps(d.gpa, &d.redo_steps);
        d.undo_steps.deinit(d.gpa);
        d.redo_steps.deinit(d.gpa);
        d.splices.deinit(d.gpa);
    }

    fn clearSteps(gpa: std.mem.Allocator, steps: *std.ArrayList(Step)) void {
        for (steps.items) |*s| s.deinit(gpa);
        steps.clearRetainingCapacity();
    }

    pub fn len(d: *const TextDoc) usize {
        return d.rope.len();
    }

    pub fn lineCount(d: *const TextDoc) usize {
        return d.rope.newlines() + 1;
    }

    pub fn lineStart(d: *const TextDoc, i: usize) usize {
        return d.rope.lineStart(i);
    }

    /// Where line `line` ends, before its newline.
    pub fn lineEnd(d: *const TextDoc, i: usize) usize {
        if (i + 1 >= d.lineCount()) return d.len();
        return d.rope.lineStart(i + 1) - 1;
    }

    pub fn lineOf(d: *const TextDoc, at: usize) usize {
        return d.rope.lineOf(at);
    }

    pub fn byteAt(d: *const TextDoc, i: usize) u8 {
        return d.rope.byteAt(i);
    }

    /// Line `line` without its newline, in memory of `gpa`.
    pub fn line(d: *const TextDoc, gpa: std.mem.Allocator, i: usize) []u8 {
        return d.rope.slice(gpa, d.lineStart(i), d.lineEnd(i)) catch &.{};
    }

    pub fn slice(d: *const TextDoc, gpa: std.mem.Allocator, a: usize, b: usize) []u8 {
        return d.rope.slice(gpa, a, b) catch &.{};
    }

    /// The whole text, in memory of `gpa`.
    pub fn text(d: *const TextDoc, gpa: std.mem.Allocator) []u8 {
        return d.slice(gpa, 0, d.len());
    }

    /// The splices since sequence number `seen`, or null when they are
    /// gone (or the text was reset): read everything again.
    pub fn splicesSince(d: *const TextDoc, seen: u64) ?[]const Splice {
        if (seen < d.splice_base) return null;
        const from: usize = @intCast(seen - d.splice_base);
        if (from > d.splices.items.len) return null;
        return d.splices.items[from..];
    }

    /// The sequence number after the newest splice.
    pub fn spliceSeq(d: *const TextDoc) u64 {
        return d.splice_base + d.splices.items.len;
    }

    /// Edits the rope and logs the lines replaced, outside the history.
    fn apply(d: *TextDoc, a: usize, b: usize, s: []const u8) void {
        const first = d.lineOf(a);
        const old_lines = if (b > a) d.lineOf(b) - first else 0;
        d.rope.replace(a, b, s);
        d.version += 1;
        if (d.splices.items.len >= 4096) {
            const drop = d.splices.items.len / 2;
            d.splices.replaceRange(d.gpa, 0, drop, &.{}) catch {};
            d.splice_base += drop;
        }
        d.splices.append(d.gpa, .{ .line = first, .old = old_lines + 1, .new = std.mem.count(u8, s, "\n") + 1 }) catch {
            // Out of memory: readers start over.
            d.splice_base = d.spliceSeq() + 1;
            d.splices.clearRetainingCapacity();
        };
    }

    /// Starts a step of undo with the selection before it, unless `kind`
    /// continues the open step (typing in a row within `group_seconds`).
    pub fn begin(d: *TextDoc, kind: Kind, sel: Sel, time: f64) void {
        if (d.open and kind != .other and d.undo_steps.items.len > 0) {
            const last = &d.undo_steps.items[d.undo_steps.items.len - 1];
            if (last.kind == kind and time - last.time < d.group_seconds and last.after.caret == sel.caret and sel.empty()) {
                last.time = time;
                return;
            }
        }
        clearSteps(d.gpa, &d.redo_steps);
        if (d.undo_steps.items.len >= d.max_undo) {
            d.undo_steps.items[0].deinit(d.gpa);
            _ = d.undo_steps.orderedRemove(0);
        }
        d.undo_steps.append(d.gpa, .{ .before = sel, .after = sel, .kind = kind, .time = time }) catch return;
        d.open = kind != .other;
    }

    /// Ends the step with the selection after it.
    pub fn end(d: *TextDoc, sel: Sel) void {
        if (d.undo_steps.items.len == 0) return;
        d.undo_steps.items[d.undo_steps.items.len - 1].after = sel;
    }

    /// The next edit starts a step of its own (the caret moved).
    pub fn breakGroup(d: *TextDoc) void {
        d.open = false;
    }

    /// Replaces bytes [a, b) with `s` in the step begun last, or in one
    /// step of its own when none is (an app's edit).
    pub fn edit(d: *TextDoc, a_in: usize, b_in: usize, s: []const u8) void {
        const a = @min(a_in, d.len());
        const b = @min(@max(a, b_in), d.len());
        if (a == b and s.len == 0) return;
        if (d.undo_steps.items.len == 0) d.begin(.other, .at(a), 0);
        const step = &d.undo_steps.items[d.undo_steps.items.len - 1];
        const removed = d.slice(d.gpa, a, b);
        // Typing in a row grows the change before it.
        if (step.changes.items.len > 0 and b == a and removed.len == 0) {
            const last = &step.changes.items[step.changes.items.len - 1];
            if (last.at + last.inserted.len == a) {
                const grown = d.gpa.realloc(last.inserted, last.inserted.len + s.len) catch null;
                if (grown) |g| {
                    @memcpy(g[last.inserted.len..], s);
                    last.inserted = g;
                    d.apply(a, b, s);
                    return;
                }
            }
        }
        const inserted = d.gpa.dupe(u8, s) catch @panic("OOM");
        step.changes.append(d.gpa, .{ .at = a, .removed = removed, .inserted = inserted }) catch @panic("OOM");
        d.apply(a, b, s);
    }

    /// Replaces [a, b) with `s` as one step of undo.
    pub fn replace(d: *TextDoc, a: usize, b: usize, s: []const u8) void {
        d.begin(.other, .at(a), 0);
        d.edit(a, b, s);
        d.end(.at(@min(a, d.len()) + s.len));
    }

    /// Replaces the whole text as one step of undo.
    pub fn set(d: *TextDoc, s: []const u8) void {
        d.replace(0, d.len(), s);
    }

    /// Replaces the whole text as a new document, without history.
    pub fn reset(d: *TextDoc, s: []const u8) void {
        d.rope.deinit();
        d.rope = .init(d.gpa, s);
        clearSteps(d.gpa, &d.undo_steps);
        clearSteps(d.gpa, &d.redo_steps);
        d.open = false;
        d.version += 1;
        d.splice_base = d.spliceSeq() + 1;
        d.splices.clearRetainingCapacity();
    }

    pub fn canUndo(d: *const TextDoc) bool {
        return d.undo_steps.items.len > 0;
    }

    pub fn canRedo(d: *const TextDoc) bool {
        return d.redo_steps.items.len > 0;
    }

    /// Takes back the last step; returns the selection before it.
    pub fn undo(d: *TextDoc) ?Sel {
        var step = d.undo_steps.pop() orelse return null;
        var i = step.changes.items.len;
        while (i > 0) {
            i -= 1;
            const ch = step.changes.items[i];
            d.apply(ch.at, ch.at + ch.inserted.len, ch.removed);
        }
        d.open = false;
        d.redo_steps.append(d.gpa, step) catch step.deinit(d.gpa);
        return step.before;
    }

    /// Does the step undone last again; returns the selection after it.
    pub fn redo(d: *TextDoc) ?Sel {
        const step = d.redo_steps.pop() orelse return null;
        for (step.changes.items) |ch| d.apply(ch.at, ch.at + ch.removed.len, ch.inserted);
        d.open = false;
        var s = step;
        d.undo_steps.append(d.gpa, s) catch s.deinit(d.gpa);
        return step.after;
    }
};

const testing = std.testing;

fn expectDoc(d: *const TextDoc, want: []const u8) !void {
    const got = d.text(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "typing in a row is one step; undo and redo" {
    var d = TextDoc.init(testing.allocator, "");
    defer d.deinit();
    for ("hello", 0..) |ch, i| {
        d.begin(.typing, .at(i), @as(f64, @floatFromInt(i)) * 0.2);
        d.edit(i, i, &.{ch});
        d.end(.at(i + 1));
    }
    try expectDoc(&d, "hello");
    // Seconds later: a step of its own.
    d.begin(.typing, .at(5), 20);
    d.edit(5, 5, "!");
    d.end(.at(6));
    try testing.expectEqual(@as(usize, 2), d.undo_steps.items.len);
    try testing.expectEqual(@as(usize, 5), d.undo().?.caret);
    try expectDoc(&d, "hello");
    try testing.expectEqual(@as(usize, 0), d.undo().?.caret);
    try expectDoc(&d, "");
    try testing.expect(d.undo() == null);
    try testing.expectEqual(@as(usize, 5), d.redo().?.caret);
    try expectDoc(&d, "hello");
    d.replace(0, 1, "J");
    try expectDoc(&d, "Jello");
    // A new edit drops what could be redone.
    try testing.expect(!d.canRedo());
}

test "splices say which lines each edit replaced" {
    var d = TextDoc.init(testing.allocator, "a\nb\nc\n");
    defer d.deinit();
    const seen = d.spliceSeq();
    d.replace(2, 3, "x\ny");
    d.replace(0, d.lineStart(2), "");
    const s = d.splicesSince(seen).?;
    try testing.expectEqual(@as(usize, 2), s.len);
    try testing.expectEqual(Splice{ .line = 1, .old = 1, .new = 2 }, s[0]);
    try testing.expectEqual(Splice{ .line = 0, .old = 3, .new = 1 }, s[1]);
    try expectDoc(&d, "y\nc\n");
    d.reset("new");
    try testing.expect(d.splicesSince(seen + 2) == null);
    try testing.expectEqual(@as(usize, 0), d.splicesSince(d.spliceSeq()).?.len);
}
