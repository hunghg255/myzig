//! What the diff viewer shows: two texts compared line by line (`diff`),
//! as rows, one over the other (unified) or side by side (split), the
//! unchanged lines between changes collapsed past a few of context, which
//! a click expands; and each side's highlighting states, found once.
const std = @import("std");
const diff = @import("diff.zig");
const hl = @import("markdown/highlight.zig");
const types = @import("types.zig");

pub const Mode = enum { unified, split };

/// A row's line on a side: unchanged, deleted, added; a gap of hidden lines;
/// or none (a split row's side beside more lines on the other).
pub const Kind = enum { same, deleted, added, gap, empty };

pub const Row = struct {
    kind: Kind,
    /// The lines of each side the row shows; in a split row `kind` is the
    /// old side's, `new_kind` the new side's.
    old: ?u32 = null,
    new: ?u32 = null,
    new_kind: Kind = .same,
    /// The line on the other side it is compared with, word by word.
    pair: ?u32 = null,
    /// A gap's hidden lines, and the old line its run starts at.
    hidden: u32 = 0,
    run: u32 = 0,
};

pub const DiffView = struct {
    gpa: std.mem.Allocator,
    old_text: []u8 = &.{},
    new_text: []u8 = &.{},
    old_lines: [][]const u8 = &.{},
    new_lines: [][]const u8 = &.{},
    hunks: []diff.Hunk = &.{},
    rows: std.ArrayList(Row) = .empty,
    mode: Mode = .unified,
    /// Unchanged lines shown around each change.
    context: usize = 3,
    /// The runs of unchanged lines expanded, by the old line they start at.
    expanded: std.AutoHashMapUnmanaged(u32, void) = .empty,
    language: ?*const hl.Language = null,
    old_states: []hl.State = &.{},
    new_states: []hl.State = &.{},
    /// The rows are built again before they are shown.
    dirty: bool = true,
    built_mode: Mode = .unified,

    /// The changes from `old` to `new` (copied), highlighted as the
    /// language of a file named `name`.
    pub fn init(gpa: std.mem.Allocator, old: []const u8, new: []const u8, name: ?[]const u8) !DiffView {
        var dv: DiffView = .{ .gpa = gpa };
        if (name) |n| dv.language = @import("editor/syntax.zig").languageFor(n);
        try dv.set(old, new);
        return dv;
    }

    pub fn deinit(dv: *DiffView) void {
        dv.clear();
        dv.rows.deinit(dv.gpa);
        dv.expanded.deinit(dv.gpa);
    }

    fn clear(dv: *DiffView) void {
        const gpa = dv.gpa;
        gpa.free(dv.old_text);
        gpa.free(dv.new_text);
        gpa.free(dv.old_lines);
        gpa.free(dv.new_lines);
        gpa.free(dv.hunks);
        gpa.free(dv.old_states);
        gpa.free(dv.new_states);
        dv.old_text = &.{};
        dv.new_text = &.{};
        dv.old_lines = &.{};
        dv.new_lines = &.{};
        dv.hunks = &.{};
        dv.old_states = &.{};
        dv.new_states = &.{};
    }

    /// Compares two other texts.
    pub fn set(dv: *DiffView, old: []const u8, new: []const u8) !void {
        dv.clear();
        const gpa = dv.gpa;
        dv.old_text = try gpa.dupe(u8, old);
        dv.new_text = try gpa.dupe(u8, new);
        dv.old_lines = try diff.splitLines(gpa, dv.old_text);
        dv.new_lines = try diff.splitLines(gpa, dv.new_text);
        dv.hunks = try diff.lines(gpa, dv.old_lines, dv.new_lines);
        dv.old_states = try states(gpa, dv.language, dv.old_lines);
        dv.new_states = try states(gpa, dv.language, dv.new_lines);
        dv.expanded.clearRetainingCapacity();
        dv.dirty = true;
    }

    /// The lines added and deleted.
    pub fn stats(dv: *const DiffView) struct { added: usize, deleted: usize } {
        var a: usize = 0;
        var d: usize = 0;
        for (dv.hunks) |h| {
            a += h.b1 - h.b0;
            d += h.a1 - h.a0;
        }
        return .{ .added = a, .deleted = d };
    }

    pub fn setMode(dv: *DiffView, mode: Mode) void {
        dv.mode = mode;
        dv.dirty = true;
    }

    /// Shows the unchanged lines a gap row hides.
    pub fn expand(dv: *DiffView, run: u32) void {
        dv.expanded.put(dv.gpa, run, {}) catch return;
        dv.dirty = true;
    }

    pub fn expandAll(dv: *DiffView) void {
        for (dv.rows.items) |r| if (r.kind == .gap) dv.expanded.put(dv.gpa, r.run, {}) catch {};
        dv.dirty = true;
    }

    pub fn collapseAll(dv: *DiffView) void {
        dv.expanded.clearRetainingCapacity();
        dv.dirty = true;
    }

    /// Builds the rows again if the mode or what is expanded changed.
    pub fn build(dv: *DiffView) void {
        if (!dv.dirty and dv.built_mode == dv.mode) return;
        dv.dirty = false;
        dv.built_mode = dv.mode;
        dv.rows.clearRetainingCapacity();
        var pa: usize = 0;
        var pb: usize = 0;
        for (dv.hunks) |h| {
            dv.same(pa, pb, h.a0 - pa, pa == 0, false);
            dv.change(h);
            pa = h.a1;
            pb = h.b1;
        }
        dv.same(pa, pb, dv.old_lines.len - pa, pa == 0, true);
    }

    fn add(dv: *DiffView, r: Row) void {
        dv.rows.append(dv.gpa, r) catch {};
    }

    /// A run of `n` unchanged lines from old line `a` (new line `b`).
    fn same(dv: *DiffView, a: usize, b: usize, n: usize, first: bool, last: bool) void {
        const ctx = dv.context;
        const head: usize = if (first) 0 else ctx;
        const tail: usize = if (last) 0 else ctx;
        const all = dv.hunks.len == 0 or n <= head + tail + 1 or dv.expanded.contains(@intCast(a));
        if (all) {
            for (0..n) |k| dv.add(.{ .kind = .same, .old = @intCast(a + k), .new = @intCast(b + k), .new_kind = .same });
            return;
        }
        for (0..head) |k| dv.add(.{ .kind = .same, .old = @intCast(a + k), .new = @intCast(b + k) });
        dv.add(.{ .kind = .gap, .hidden = @intCast(n - head - tail), .run = @intCast(a) });
        for (n - tail..n) |k| dv.add(.{ .kind = .same, .old = @intCast(a + k), .new = @intCast(b + k) });
    }

    fn change(dv: *DiffView, h: diff.Hunk) void {
        const dels = h.a1 - h.a0;
        const adds = h.b1 - h.b0;
        const pairs = @min(dels, adds);
        switch (dv.mode) {
            .unified => {
                for (0..dels) |k| dv.add(.{ .kind = .deleted, .old = @intCast(h.a0 + k), .pair = if (k < pairs) @intCast(h.b0 + k) else null });
                for (0..adds) |k| dv.add(.{ .kind = .added, .new = @intCast(h.b0 + k), .pair = if (k < pairs) @intCast(h.a0 + k) else null });
            },
            .split => for (0..@max(dels, adds)) |k| dv.add(.{
                .kind = if (k < dels) .deleted else .empty,
                .old = if (k < dels) @intCast(h.a0 + k) else null,
                .new = if (k < adds) @intCast(h.b0 + k) else null,
                .new_kind = if (k < adds) .added else .empty,
            }),
        }
    }
};

/// The state each line starts in, for highlighting a line alone.
fn states(gpa: std.mem.Allocator, lang: ?*const hl.Language, lines: []const []const u8) ![]hl.State {
    const out = try gpa.alloc(hl.State, lines.len);
    @memset(out, .none);
    const l = lang orelse return out;
    var scratch: std.ArrayList(types.Span) = .empty;
    defer scratch.deinit(gpa);
    const colors = hl.Colors.of(false);
    var st: hl.State = .none;
    for (lines, 0..) |line, i| {
        out[i] = st;
        scratch.clearRetainingCapacity();
        st = hl.line(gpa, l, line, st, 0, colors, &scratch);
    }
    return out;
}
