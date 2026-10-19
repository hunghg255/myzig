//! Undo for the rich text editor: each step keeps the blocks an edit
//! replaced, whole, with their styles and marks, so that undo brings the
//! formats back with the text. Typing (or deleting) in a row within a
//! second is one step, and an input method's whole composition is one.
const std = @import("std");
const model = @import("model.zig");
const Block = model.Block;
const Doc = model.Doc;
const Sel = model.Sel;

pub const Kind = enum { typing, deleting, other };

const Step = struct {
    /// Blocks [at, at + count) of the document are what the step made of
    /// `blocks` (what it replaced): undo swaps them back, redo again.
    at: usize,
    count: usize,
    blocks: []Block,
    before: Sel,
    after: Sel,
    kind: Kind,
    time: f64,

    fn deinit(s: *Step, gpa: std.mem.Allocator) void {
        for (s.blocks) |*b| b.deinit(gpa);
        gpa.free(s.blocks);
    }
};

pub const History = struct {
    undo_steps: std.ArrayList(Step) = .empty,
    redo_steps: std.ArrayList(Step) = .empty,
    /// The last step takes more of its kind.
    open: bool = false,
    /// The end of the range the edit begun last said it would replace.
    pending_end: usize = 0,
    max_steps: usize = 500,
    group_seconds: f64 = 1,

    pub fn deinit(h: *History, gpa: std.mem.Allocator) void {
        h.clear(gpa);
        h.undo_steps.deinit(gpa);
        h.redo_steps.deinit(gpa);
    }

    pub fn clear(h: *History, gpa: std.mem.Allocator) void {
        clearSteps(gpa, &h.undo_steps);
        clearSteps(gpa, &h.redo_steps);
        h.open = false;
    }

    fn clearSteps(gpa: std.mem.Allocator, steps: *std.ArrayList(Step)) void {
        for (steps.items) |*s| s.deinit(gpa);
        steps.clearRetainingCapacity();
    }

    pub fn canUndo(h: *const History) bool {
        return h.undo_steps.items.len > 0;
    }

    pub fn canRedo(h: *const History) bool {
        return h.redo_steps.items.len > 0;
    }

    /// The next edit is a step of its own (the caret moved).
    pub fn breakGroup(h: *History) void {
        h.open = false;
    }

    /// Starts a step that replaces blocks [a, b) of `d`, unless it
    /// continues the open one: the same kind of typing in a row (or any
    /// edit while an input method composes) within those blocks.
    pub fn begin(h: *History, d: *const Doc, kind: Kind, a: usize, b: usize, sel: Sel, time: f64, composing: bool) void {
        h.pending_end = b;
        if (h.open and h.undo_steps.items.len > 0) {
            const last = &h.undo_steps.items[h.undo_steps.items.len - 1];
            const inside = a >= last.at and b <= last.at + last.count;
            const in_a_row = kind != .other and last.kind == kind and time - last.time < h.group_seconds and
                last.after.caret.eql(sel.caret) and sel.empty();
            if (inside and (composing or in_a_row)) {
                last.time = time;
                return;
            }
        }
        clearSteps(d.gpa, &h.redo_steps);
        if (h.undo_steps.items.len >= h.max_steps) {
            h.undo_steps.items[0].deinit(d.gpa);
            _ = h.undo_steps.orderedRemove(0);
        }
        const blocks = d.gpa.alloc(Block, b - a) catch @panic("OOM");
        for (d.blocks.items[a..b], blocks) |*src, *dst| dst.* = src.clone(d.gpa);
        h.undo_steps.append(d.gpa, .{ .at = a, .count = b - a, .blocks = blocks, .before = sel, .after = sel, .kind = kind, .time = time }) catch @panic("OOM");
        h.open = kind != .other or composing;
    }

    /// Ends the step: the range begun as [a, b) is now [a, new_end), and
    /// `sel` the selection after it.
    pub fn end(h: *History, new_end: usize, sel: Sel) void {
        if (h.undo_steps.items.len == 0) return;
        const last = &h.undo_steps.items[h.undo_steps.items.len - 1];
        last.count = last.count + new_end - h.pending_end;
        last.after = sel;
    }

    fn swapStep(d: *Doc, s: *Step) void {
        const taken = d.swap(s.at, s.count, s.blocks);
        const n = s.blocks.len;
        d.gpa.free(s.blocks);
        s.count = n;
        s.blocks = taken;
    }

    /// Takes back the last step; returns the selection before it.
    pub fn undo(h: *History, d: *Doc) ?Sel {
        var s = h.undo_steps.pop() orelse return null;
        swapStep(d, &s);
        h.open = false;
        h.redo_steps.append(d.gpa, s) catch s.deinit(d.gpa);
        return s.before;
    }

    /// Does the step undone last again; returns the selection after it.
    pub fn redo(h: *History, d: *Doc) ?Sel {
        var s = h.redo_steps.pop() orelse return null;
        swapStep(d, &s);
        h.open = false;
        h.undo_steps.append(d.gpa, s) catch s.deinit(d.gpa);
        return s.after;
    }
};

const testing = std.testing;

test "steps swap blocks back and forth" {
    const gpa = testing.allocator;
    var d = Doc.init(gpa);
    defer d.deinit();
    var h: History = .{};
    defer h.deinit(gpa);
    d.block(0).insert(gpa, 0, "ab", .{});
    h.begin(&d, .other, 0, 1, .{}, 0, false);
    d.split(.{ .block = 0, .off = 1 });
    h.end(2, .at(.{ .block = 1 }));
    try testing.expectEqual(@as(usize, 2), d.count());
    try testing.expectEqual(@as(usize, 0), h.undo(&d).?.caret.block);
    try testing.expectEqual(@as(usize, 1), d.count());
    try testing.expectEqualStrings("ab", d.block(0).str());
    try testing.expectEqual(@as(usize, 1), h.redo(&d).?.caret.block);
    try testing.expectEqual(@as(usize, 2), d.count());
    try testing.expectEqualStrings("b", d.block(1).str());
}
