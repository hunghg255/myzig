//! Text as a balanced tree of chunks of UTF-8, as Zed's rope and mygo's
//! `internal/rope`: an AVL tree whose leaves own up to 2 KB of the text
//! each and whose branches count the bytes and newlines below them. An
//! edit touches the leaves it changes and the path to them, so typing in a
//! file of a million lines costs what it does in one of ten, and a line's
//! start, a byte's line and a range of text are found in O(log n).
//!
//! Unlike mygo's, the tree is mutable: undo keeps the edits (`TextDoc`),
//! not versions, which Zig would have to count references for.
const std = @import("std");

/// The most bytes a leaf holds; new leaves get half, room to type in.
pub const max_leaf = 2048;
const build_leaf = max_leaf / 2;

const Node = struct {
    left: ?*Node = null,
    right: ?*Node = null,
    /// Only leaves own bytes.
    text: []u8 = &.{},
    bytes: usize = 0,
    /// Newlines below.
    lines: usize = 0,
    height: u8 = 1,

    fn isLeaf(n: *const Node) bool {
        return n.left == null;
    }
};

fn heightOf(n: ?*Node) u8 {
    return if (n) |v| v.height else 0;
}

fn bytesOf(n: ?*Node) usize {
    return if (n) |v| v.bytes else 0;
}

fn linesOf(n: ?*Node) usize {
    return if (n) |v| v.lines else 0;
}

pub const Rope = struct {
    gpa: std.mem.Allocator,
    root: ?*Node = null,

    pub fn init(gpa: std.mem.Allocator, s: []const u8) Rope {
        var r: Rope = .{ .gpa = gpa };
        r.root = r.build(s);
        return r;
    }

    pub fn deinit(r: *Rope) void {
        r.destroy(r.root);
        r.root = null;
    }

    /// The text's length in bytes.
    pub fn len(r: *const Rope) usize {
        return bytesOf(r.root);
    }

    /// Its newlines: one less than its lines.
    pub fn newlines(r: *const Rope) usize {
        return linesOf(r.root);
    }

    /// Replaces bytes [a, b) with `s`.
    pub fn replace(r: *Rope, a_in: usize, b_in: usize, s: []const u8) void {
        const total = r.len();
        const a = @min(a_in, total);
        const b = @min(@max(a, b_in), total);
        if (a == b and s.len == 0) return;
        // Typing: most edits stay inside one leaf, edited where it is.
        if (r.root) |root| if (r.editInPlace(root, a, b, s)) return;
        const parts = r.split(r.root, a);
        const rest = r.split(parts[1], b - a);
        r.destroy(rest[0]);
        r.root = r.join(r.join(parts[0], r.build(s)), rest[1]);
    }

    /// The byte at `i` (< len).
    pub fn byteAt(r: *const Rope, i_in: usize) u8 {
        var n = r.root orelse return 0;
        var i = i_in;
        while (!n.isLeaf()) {
            const lb = n.left.?.bytes;
            if (i < lb) n = n.left.? else {
                i -= lb;
                n = n.right.?;
            }
        }
        return if (i < n.text.len) n.text[i] else 0;
    }

    /// The byte line `line` (from 0) starts at; the end past the last line.
    pub fn lineStart(r: *const Rope, line_in: usize) usize {
        if (line_in == 0) return 0;
        if (line_in > r.newlines()) return r.len();
        var n = r.root.?;
        var line = line_in;
        var offset: usize = 0;
        while (!n.isLeaf()) {
            const l = n.left.?;
            if (line <= l.lines) n = l else {
                line -= l.lines;
                offset += l.bytes;
                n = n.right.?;
            }
        }
        var from: usize = 0;
        while (line > 0) : (line -= 1) from = (std.mem.indexOfScalarPos(u8, n.text, from, '\n') orelse n.text.len) + 1;
        return offset + from;
    }

    /// The line byte `at` is on: the newlines before it.
    pub fn lineOf(r: *const Rope, at_in: usize) usize {
        var n = r.root orelse return 0;
        var at = @min(at_in, n.bytes);
        var count: usize = 0;
        while (!n.isLeaf()) {
            const l = n.left.?;
            if (at <= l.bytes) n = l else {
                at -= l.bytes;
                count += l.lines;
                n = n.right.?;
            }
        }
        return count + std.mem.count(u8, n.text[0..at], "\n");
    }

    /// Appends bytes [a, b) to `out`.
    pub fn appendRange(r: *const Rope, gpa: std.mem.Allocator, a: usize, b: usize, out: *std.ArrayList(u8)) !void {
        if (a >= b) return;
        try out.ensureUnusedCapacity(gpa, b - a);
        var it = r.chunks(a);
        var at = a;
        while (at < b) {
            const ch = it.next() orelse break;
            const take = ch[0..@min(ch.len, b - at)];
            out.appendSliceAssumeCapacity(take);
            at += take.len;
        }
    }

    /// Bytes [a, b) in memory of `gpa`.
    pub fn slice(r: *const Rope, gpa: std.mem.Allocator, a: usize, b: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try r.appendRange(gpa, a, @min(b, r.len()), &out);
        return out.toOwnedSlice(gpa);
    }

    /// The text from byte `from`, a leaf's piece at a time.
    pub fn chunks(r: *const Rope, from: usize) Chunks {
        return .{ .rope = r, .at = from };
    }

    pub const Chunks = struct {
        rope: *const Rope,
        at: usize,

        pub fn next(it: *Chunks) ?[]const u8 {
            var n = it.rope.root orelse return null;
            if (it.at >= n.bytes) return null;
            var i = it.at;
            while (!n.isLeaf()) {
                const lb = n.left.?.bytes;
                if (i < lb) n = n.left.? else {
                    i -= lb;
                    n = n.right.?;
                }
            }
            const piece = n.text[i..];
            it.at += piece.len;
            return piece;
        }
    };

    /// The lines from line `first`, without their newlines: a slice of a
    /// leaf, or of `scratch` for a line across leaves (valid until the
    /// next call).
    pub fn lines(r: *const Rope, gpa: std.mem.Allocator, first: usize) Lines {
        return .{ .gpa = gpa, .chunks = r.chunks(r.lineStart(first)), .done = first > r.newlines() };
    }

    pub const Lines = struct {
        gpa: std.mem.Allocator,
        chunks: Chunks,
        piece: []const u8 = &.{},
        scratch: std.ArrayList(u8) = .empty,
        done: bool = false,

        pub fn deinit(it: *Lines) void {
            it.scratch.deinit(it.gpa);
        }

        pub fn next(it: *Lines) ?[]const u8 {
            if (it.done) return null;
            it.scratch.clearRetainingCapacity();
            var spanning = false;
            while (true) {
                if (it.piece.len == 0) {
                    it.piece = it.chunks.next() orelse {
                        // The last line, after the last newline (maybe empty).
                        it.done = true;
                        return it.scratch.items;
                    };
                }
                if (std.mem.indexOfScalar(u8, it.piece, '\n')) |nl| {
                    const line = it.piece[0..nl];
                    it.piece = it.piece[nl + 1 ..];
                    if (!spanning) return line;
                    it.scratch.appendSlice(it.gpa, line) catch {};
                    return it.scratch.items;
                }
                it.scratch.appendSlice(it.gpa, it.piece) catch {};
                spanning = true;
                it.piece = &.{};
            }
        }
    };

    /// What is wrong with the tree, for tests: an oversized or miscounted
    /// leaf, or an unbalanced or miscounted branch.
    pub fn check(r: *const Rope) !void {
        _ = try checkNode(r.root);
    }

    fn checkNode(n_: ?*Node) !struct { bytes: usize, lines: usize, height: u8 } {
        const n = n_ orelse return .{ .bytes = 0, .lines = 0, .height = 0 };
        if (n.isLeaf()) {
            if (n.right != null or n.text.len == 0 or n.text.len > max_leaf or n.bytes != n.text.len or
                n.lines != std.mem.count(u8, n.text, "\n") or n.height != 1) return error.BadLeaf;
            return .{ .bytes = n.bytes, .lines = n.lines, .height = 1 };
        }
        const a = try checkNode(n.left);
        const b = try checkNode(n.right orelse return error.BadBranch);
        const d = @as(i32, a.height) - @as(i32, b.height);
        if (d < -1 or d > 1 or n.height != 1 + @max(a.height, b.height) or n.bytes != a.bytes + b.bytes or n.lines != a.lines + b.lines)
            return error.BadBranch;
        return .{ .bytes = n.bytes, .lines = n.lines, .height = n.height };
    }

    // The tree's nodes. Every node has one owner: split and join consume
    // the trees they are given.

    fn newLeaf(r: *Rope, s: []const u8) ?*Node {
        if (s.len == 0) return null;
        const n = r.gpa.create(Node) catch @panic("OOM");
        const t = r.gpa.dupe(u8, s) catch @panic("OOM");
        n.* = .{ .text = t, .bytes = s.len, .lines = std.mem.count(u8, s, "\n") };
        return n;
    }

    fn branch(r: *Rope, a: ?*Node, b: ?*Node) ?*Node {
        const x = a orelse return b;
        const y = b orelse return a;
        const n = r.gpa.create(Node) catch @panic("OOM");
        n.* = .{ .left = x, .right = y, .bytes = x.bytes + y.bytes, .lines = x.lines + y.lines, .height = 1 + @max(x.height, y.height) };
        return n;
    }

    /// Frees one node (a leaf's text with it), not its children.
    fn free(r: *Rope, n: *Node) void {
        if (n.isLeaf()) r.gpa.free(n.text);
        r.gpa.destroy(n);
    }

    fn destroy(r: *Rope, n_: ?*Node) void {
        const n = n_ orelse return;
        r.destroy(n.left);
        r.destroy(n.right);
        r.free(n);
    }

    fn balance(r: *Rope, n: *Node) *Node {
        if (heightOf(n.left) > heightOf(n.right) + 1) {
            var a = n.left.?;
            const right = n.right;
            r.free(n);
            if (heightOf(a.left) < heightOf(a.right)) {
                const al = a.left;
                const b = a.right.?;
                r.free(a);
                const bl = b.left;
                const br = b.right;
                r.free(b);
                a = r.branch(r.branch(al, bl), br).?;
            }
            const al = a.left;
            const ar = a.right;
            r.free(a);
            return r.branch(al, r.branch(ar, right)).?;
        }
        if (heightOf(n.right) > heightOf(n.left) + 1) {
            var b = n.right.?;
            const left = n.left;
            r.free(n);
            if (heightOf(b.right) < heightOf(b.left)) {
                const br = b.right;
                const a = b.left.?;
                r.free(b);
                const al = a.left;
                const ar = a.right;
                r.free(a);
                b = r.branch(al, r.branch(ar, br)).?;
            }
            const bl = b.left;
            const br = b.right;
            r.free(b);
            return r.branch(r.branch(left, bl), br).?;
        }
        return n;
    }

    /// The text of `a` followed by that of `b`.
    fn join(r: *Rope, a_: ?*Node, b_: ?*Node) ?*Node {
        const a = a_ orelse return b_;
        const b = b_ orelse return a_;
        if (a.isLeaf() and b.isLeaf() and a.bytes + b.bytes <= max_leaf) {
            const t = r.gpa.alloc(u8, a.bytes + b.bytes) catch @panic("OOM");
            @memcpy(t[0..a.bytes], a.text);
            @memcpy(t[a.bytes..], b.text);
            const n = r.gpa.create(Node) catch @panic("OOM");
            n.* = .{ .text = t, .bytes = t.len, .lines = a.lines + b.lines };
            r.free(a);
            r.free(b);
            return n;
        }
        if (a.height > b.height + 1) {
            const al = a.left;
            const ar = a.right;
            r.free(a);
            return r.balance(r.branch(al, r.join(ar, b)).?);
        }
        if (b.height > a.height + 1) {
            const bl = b.left;
            const br = b.right;
            r.free(b);
            return r.balance(r.branch(r.join(a, bl), br).?);
        }
        return r.branch(a, b);
    }

    /// The text before byte `at` and the text from it.
    fn split(r: *Rope, n_: ?*Node, at: usize) [2]?*Node {
        const n = n_ orelse return .{ null, null };
        if (at == 0) return .{ null, n };
        if (at >= n.bytes) return .{ n, null };
        if (n.isLeaf()) {
            const out = [2]?*Node{ r.newLeaf(n.text[0..at]), r.newLeaf(n.text[at..]) };
            r.free(n);
            return out;
        }
        const l = n.left.?;
        const rt = n.right.?;
        r.free(n);
        if (at < l.bytes) {
            const s = r.split(l, at);
            return .{ s[0], r.join(s[1], rt) };
        }
        const s = r.split(rt, at - l.bytes);
        return .{ r.join(l, s[0]), s[1] };
    }

    /// A balanced tree of `s`, in leaves half full, cut between characters.
    fn build(r: *Rope, s: []const u8) ?*Node {
        if (s.len == 0) return null;
        if (s.len <= build_leaf) return r.newLeaf(s);
        var mid = s.len / 2;
        while (mid > 0 and (s[mid] & 0xc0) == 0x80) mid -= 1;
        if (mid == 0) mid = s.len / 2;
        return r.branch(r.build(s[0..mid]), r.build(s[mid..]));
    }

    /// Replaces [a, b) inside one leaf when the leaf has room; false if the
    /// edit spans leaves or would overfill or empty its leaf.
    fn editInPlace(r: *Rope, n: *Node, a: usize, b: usize, s: []const u8) bool {
        if (n.isLeaf()) {
            const new_len = n.text.len - (b - a) + s.len;
            if (new_len == 0 or new_len > max_leaf) return false;
            const t = r.gpa.alloc(u8, new_len) catch @panic("OOM");
            @memcpy(t[0..a], n.text[0..a]);
            @memcpy(t[a .. a + s.len], s);
            @memcpy(t[a + s.len ..], n.text[b..]);
            r.gpa.free(n.text);
            n.text = t;
            n.bytes = new_len;
            n.lines = std.mem.count(u8, t, "\n");
            return true;
        }
        const l = n.left.?;
        const rt = n.right.?;
        const ok = if (b <= l.bytes)
            r.editInPlace(l, a, b, s)
        else if (a >= l.bytes)
            r.editInPlace(rt, a - l.bytes, b - l.bytes, s)
        else
            false;
        if (ok) {
            n.bytes = l.bytes + rt.bytes;
            n.lines = l.lines + rt.lines;
        }
        return ok;
    }
};

const testing = std.testing;

fn expectText(r: *const Rope, want: []const u8) !void {
    const got = try r.slice(testing.allocator, 0, r.len());
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
    try r.check();
}

test "edits, lines and chunks" {
    var r = Rope.init(testing.allocator, "hello\nworld");
    defer r.deinit();
    try expectText(&r, "hello\nworld");
    r.replace(5, 5, ", there");
    try expectText(&r, "hello, there\nworld");
    r.replace(0, 5, "");
    try expectText(&r, ", there\nworld");
    try testing.expectEqual(@as(usize, 1), r.newlines());
    try testing.expectEqual(@as(usize, 8), r.lineStart(1));
    try testing.expectEqual(@as(usize, 1), r.lineOf(8));
    try testing.expectEqual(@as(usize, 0), r.lineOf(7));
    try testing.expectEqual(@as(u8, 'w'), r.byteAt(8));
    r.replace(0, r.len(), "");
    try expectText(&r, "");
    try testing.expectEqual(@as(usize, 0), r.lineStart(3));
}

test "large texts stay balanced through random edits, as a slice does" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);
    for (0..20000) |i| try model.appendSlice(gpa, if (i % 7 == 0) "line\n" else "abcdefgh ");
    var r = Rope.init(gpa, model.items);
    defer r.deinit();
    try r.check();
    const words = [_][]const u8{ "", "x", "yz\n", "\n\n", "ü", "a longer piece of text that is inserted\n" };
    for (0..3000) |step| {
        const a = rand.uintAtMost(usize, model.items.len);
        const b = @min(model.items.len, a + rand.uintAtMost(usize, if (step % 50 == 0) 5000 else 8));
        const s = words[rand.uintLessThan(usize, words.len)];
        r.replace(a, b, s);
        try model.replaceRange(gpa, a, b - a, s);
    }
    try expectText(&r, model.items);
    // Lines agree with the model's.
    var line: usize = 0;
    var start: usize = 0;
    for (model.items, 0..) |ch, i| if (ch == '\n') {
        try testing.expectEqual(start, r.lineStart(line));
        try testing.expectEqual(line, r.lineOf(i));
        line += 1;
        start = i + 1;
    };
    try testing.expectEqual(line, r.newlines());
    var it = r.lines(gpa, 0);
    defer it.deinit();
    var n: usize = 0;
    var split = std.mem.splitScalar(u8, model.items, '\n');
    while (split.next()) |want| : (n += 1) try testing.expectEqualStrings(want, it.next().?);
    try testing.expect(it.next() == null);
    try testing.expectEqual(line + 1, n);
}
