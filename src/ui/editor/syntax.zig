//! The code editor's highlighting: the markdown highlighter's languages, a
//! line at a time, from the state each line starts in (in a block comment,
//! in a multiline string). The states are kept per line and follow the
//! document's edits: after an edit only the lines from it are tokenized
//! again, until one starts in the state it started in before, and only as
//! far as the lines shown. Of a line longer than `max_tokenized` bytes
//! (minified code, data on one line), the first `max_tokenized` are
//! colored and the rest is plain, as VS Code does: tokenizing megabytes
//! would stall every frame that shows the line.
const std = @import("std");
const types = @import("../types.zig");
const hl = @import("../markdown/highlight.zig");
const TextDoc = @import("../textdoc.zig").TextDoc;

pub const Language = hl.Language;

/// How much of a line is tokenized (VS Code's maxTokenizationLineLength).
pub const max_tokenized = 20_000;
pub const State = hl.State;

/// The language of a file, by its extension (or its name: a language's).
pub fn languageFor(name: []const u8) ?*const Language {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const ext = if (dot) |d| name[d + 1 ..] else name;
    if (hl.language(ext)) |l| return l;
    const Alias = struct { []const u8, []const u8 };
    const aliases = [_]Alias{ .{ "mts", "ts" }, .{ "cjs", "js" }, .{ "pyw", "py" }, .{ "bashrc", "sh" }, .{ "zon", "zig" } };
    for (aliases) |a| if (std.ascii.eqlIgnoreCase(a[0], ext)) return hl.language(a[1]);
    return null;
}

pub const Syntax = struct {
    /// The state each line starts in: right for lines [0, valid).
    starts: std.ArrayList(State) = .empty,
    valid: usize = 0,
    /// After an edit, the lines from `resume_at` on keep their states, as
    /// far as `known`, if the line before them ends as it did.
    resume_at: usize = 0,
    known: usize = 0,
    seen: u64 = 0,
    synced: bool = false,
    language: ?*const Language = null,
    /// Lines tokenized to find states (tests count them).
    tokenized: usize = 0,
    /// The runs of long lines, kept across frames until the text changes.
    long: [32]Kept = @splat(.{}),
    next_kept: usize = 0,

    const Kept = struct { line: usize = std.math.maxInt(usize), version: u64 = 0, len: usize = 0, dark: bool = false, spans: []types.Span = &.{} };

    pub fn deinit(s: *Syntax, gpa: std.mem.Allocator) void {
        s.starts.deinit(gpa);
        for (s.long) |k| gpa.free(k.spans);
    }

    pub fn setLanguage(s: *Syntax, lang: ?*const Language) void {
        if (s.language == lang) return;
        s.language = lang;
        s.synced = false;
    }

    /// Follows the document's edits since the last call.
    pub fn sync(s: *Syntax, gpa: std.mem.Allocator, doc: *const TextDoc) void {
        const count = doc.lineCount();
        if (s.synced) if (doc.splicesSince(s.seen)) |splices| {
            var first = true;
            for (splices) |sp| {
                if (sp.line + sp.old > s.starts.items.len) break;
                // The first line's start is the same; the others' are new.
                var fill: [64]State = @splat(.none);
                const added = sp.new - 1;
                s.starts.replaceRange(gpa, sp.line + 1, sp.old - 1, fill[0..@min(added, fill.len)]) catch break;
                var k: usize = fill.len;
                while (k < added) : (k += 1) s.starts.insert(gpa, sp.line + 1 + k, .none) catch break;
                const shifted = if (s.known > sp.line + sp.old) s.known + sp.new - sp.old else sp.line + 1;
                const resume_shifted = if (s.resume_at > sp.line + sp.old) s.resume_at + sp.new - sp.old else sp.line + sp.new;
                if (first and s.valid >= s.known) {
                    // One edit since the states were found: those after
                    // it hold if the line before them ends as it did.
                    s.known = shifted;
                    s.resume_at = sp.line + sp.new;
                } else {
                    s.known = @min(shifted, sp.line + 1);
                    s.resume_at = @max(resume_shifted, sp.line + sp.new);
                }
                s.valid = @min(s.valid, sp.line + 1);
                first = false;
            }
            s.seen = doc.spliceSeq();
            if (s.starts.items.len == count) return;
        };
        s.starts.clearRetainingCapacity();
        s.starts.appendNTimes(gpa, .none, count) catch {};
        s.valid = 1;
        s.known = 0;
        s.resume_at = 0;
        s.seen = doc.spliceSeq();
        s.synced = true;
    }

    /// Finds the states of the lines up to `line`.
    fn ensure(s: *Syntax, arena: std.mem.Allocator, doc: *const TextDoc, line: usize, colors: hl.Colors) void {
        const lang = s.language orelse return;
        const n = s.starts.items.len;
        var scratch: std.ArrayList(types.Span) = .empty;
        while (s.valid <= line and s.valid < n) {
            const prev = s.valid - 1;
            const str = doc.slice(arena, doc.lineStart(prev), @min(doc.lineEnd(prev), doc.lineStart(prev) + max_tokenized));
            scratch.clearRetainingCapacity();
            const st = hl.line(arena, lang, str, s.starts.items[prev], 0, colors, &scratch);
            s.tokenized += 1;
            const next = s.valid;
            if (next >= s.resume_at and next < s.known and s.starts.items[next] == st) {
                s.valid = s.known;
                continue;
            }
            s.starts.items[next] = st;
            s.valid = next + 1;
        }
        if (s.valid > s.known) s.known = s.valid;
    }

    /// The colored runs of line `line` (its text `str`), in `arena`; a
    /// long line's are kept (in `doc`'s allocator) until the text changes.
    pub fn spans(s: *Syntax, arena: std.mem.Allocator, doc: *const TextDoc, line: usize, str: []const u8, dark: bool) []const types.Span {
        const lang = s.language orelse return &.{};
        if (line >= s.starts.items.len) return &.{};
        const colors = hl.Colors.of(dark);
        s.ensure(arena, doc, line, colors);
        if (str.len >= 4096) {
            for (s.long) |k| if (k.line == line and k.version == doc.version and k.len == str.len and k.dark == dark) return k.spans;
            const out = s.tokenize(arena, lang, str, line, colors);
            const k = &s.long[s.next_kept];
            s.next_kept = (s.next_kept + 1) % s.long.len;
            doc.gpa.free(k.spans);
            k.* = .{ .line = line, .version = doc.version, .len = str.len, .dark = dark, .spans = doc.gpa.dupe(types.Span, out) catch &.{} };
            return out;
        }
        return s.tokenize(arena, lang, str, line, colors);
    }

    fn tokenize(s: *Syntax, arena: std.mem.Allocator, lang: *const Language, str: []const u8, line: usize, colors: hl.Colors) []types.Span {
        var out: std.ArrayList(types.Span) = .empty;
        _ = hl.line(arena, lang, str[0..@min(str.len, max_tokenized)], s.starts.items[line], 0, colors, &out);
        // Upright: the caret and the selection measure the plain text.
        for (out.items) |*sp| sp.italic = false;
        return out.items;
    }
};

const testing = std.testing;

test "states follow edits; only the lines from an edit are tokenized again" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "/* a\nb */\n");
    for (0..1000) |i| try src.print(gpa, "const x{d} = {d};\n", .{ i, i });
    var doc = TextDoc.init(gpa, src.items);
    defer doc.deinit();
    var s: Syntax = .{};
    defer s.deinit(gpa);
    s.setLanguage(languageFor("main.js"));
    s.sync(gpa, &doc);
    const a = arena.allocator();
    _ = s.spans(a, &doc, 1000, doc.line(a, 1000), false);
    try testing.expectEqual(State.comment, s.starts.items[1]);
    try testing.expectEqual(State.none, s.starts.items[2]);
    const before = s.tokenized;
    // An edit inside line 500 that changes no state.
    const at = doc.lineStart(500) + 2;
    doc.replace(at, at, "nst");
    s.sync(gpa, &doc);
    _ = s.spans(a, &doc, 1000, doc.line(a, 1000), false);
    try testing.expect(s.tokenized - before <= 3);
    // Opening a comment changes every line after it.
    doc.replace(doc.lineStart(600), doc.lineStart(600), "/*");
    s.sync(gpa, &doc);
    const sp = s.spans(a, &doc, 700, doc.line(a, 700), false);
    try testing.expectEqual(State.comment, s.starts.items[700]);
    try testing.expectEqual(@as(usize, 1), sp.len);
    // Closing it again.
    doc.replace(doc.lineStart(600), doc.lineStart(600) + 2, "");
    s.sync(gpa, &doc);
    _ = s.spans(a, &doc, 700, doc.line(a, 700), false);
    try testing.expectEqual(State.none, s.starts.items[700]);
    try testing.expect(languageFor("x.unknown") == null);
    try testing.expect(languageFor("build.zig") != null);
}
