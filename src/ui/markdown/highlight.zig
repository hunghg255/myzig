//! A small highlighter for code blocks: keywords, strings, numbers,
//! comments, functions and types of Zig, JavaScript and TypeScript, Go,
//! Python, JSON and shell, a line at a time from the state the line
//! before left (in a block comment, in a multiline string), so that a
//! block streaming in highlights only its new lines.
const std = @import("std");
const types = @import("../types.zig");
const Color = types.Color;
const Span = types.Span;

pub const Language = struct {
    keywords: []const []const u8,
    /// Constants and builtin values (true, null, nil, None).
    constants: []const []const u8 = &.{},
    line_comment: []const u8 = "",
    block_comment: bool = false,
    /// Quotes of strings on one line; `multiline` quotes may go on.
    quotes: []const u8 = "\"'",
    multiline: u8 = 0,
    /// Python's triple quotes.
    triple: bool = false,
    /// Zig's @builtins, shell's $variables.
    sigil: u8 = 0,
    /// JSON: a string before a colon is a key.
    keys: bool = false,
    /// A block comment's delimiters other than C's `/*` and `*/`:
    /// Haskell's `{-` `-}`, OCaml's `(*` `*)`, Lua's `--[[` `]]`.
    block: ?[2][]const u8 = null,
    /// Tags and attributes (HTML, XML, Vue), Markdown's marks, or a
    /// diff's lines, rather than code (`highlight_markup.zig`).
    mode: enum { code, markup, markdown, diff } = .code,
};

/// A language's block comment delimiters, if it has block comments.
fn blockOf(lang: *const Language) ?[2][]const u8 {
    if (lang.block) |b| return b;
    return if (lang.block_comment) .{ "/*", "*/" } else null;
}

const zig: Language = .{
    .keywords = &.{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "break", "continue", "defer", "errdefer", "try", "catch", "orelse", "and", "or", "struct", "enum", "union", "error", "comptime", "inline", "test", "unreachable", "extern", "export", "packed", "align", "noinline", "threadlocal", "usingnamespace", "anytype", "opaque", "suspend", "resume", "nosuspend", "volatile", "allowzero", "linksection", "callconv" },
    .constants = &.{ "true", "false", "null", "undefined", "void", "bool", "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64", "type", "anyerror", "noreturn" },
    .line_comment = "//",
    .sigil = '@',
};
const js: Language = .{
    .keywords = &.{ "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "import", "export", "from", "as", "async", "await", "yield", "try", "catch", "finally", "throw", "interface", "type", "enum", "implements", "private", "public", "protected", "readonly", "static", "declare", "namespace", "keyof", "satisfies" },
    .constants = &.{ "true", "false", "null", "undefined", "NaN", "Infinity", "string", "number", "boolean", "any", "unknown", "never", "void", "object" },
    .line_comment = "//",
    .block_comment = true,
    .multiline = '`',
};
const go: Language = .{
    .keywords = &.{ "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var" },
    .constants = &.{ "true", "false", "nil", "iota", "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "byte", "rune", "float32", "float64", "bool", "error", "any" },
    .line_comment = "//",
    .block_comment = true,
    .multiline = '`',
};
const python: Language = .{
    .keywords = &.{ "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case" },
    .constants = &.{ "True", "False", "None", "self", "int", "str", "float", "bool", "list", "dict", "set", "tuple" },
    .line_comment = "#",
    .triple = true,
};
const json: Language = .{ .keywords = &.{}, .constants = &.{ "true", "false", "null" }, .quotes = "\"", .keys = true };
const shell: Language = .{
    .keywords = &.{ "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "export", "local", "readonly", "source", "alias", "unset", "set" },
    .constants = &.{ "true", "false" },
    .line_comment = "#",
    .sigil = '$',
};

/// The language of a fence's info string, if it is one of these.
pub fn language(name: []const u8) ?*const Language {
    const Entry = struct { []const u8, *const Language };
    const names = [_]Entry{
        .{ "zig", &zig },        .{ "js", &js },       .{ "javascript", &js }, .{ "jsx", &js },     .{ "ts", &js },     .{ "typescript", &js },
        .{ "tsx", &js },         .{ "mjs", &js },      .{ "go", &go },         .{ "golang", &go },  .{ "py", &python }, .{ "python", &python },
        .{ "json", &json },      .{ "jsonc", &json },  .{ "sh", &shell },      .{ "bash", &shell }, .{ "zsh", &shell }, .{ "shell", &shell },
        .{ "console", &shell },
    };
    for (names) |e| if (std.ascii.eqlIgnoreCase(e[0], name)) return e[1];
    return @import("highlight_langs.zig").language(name);
}

pub const Colors = struct {
    keyword: Color,
    string: Color,
    number: Color,
    comment: Color,
    function: Color,
    type: Color,
    key: Color,

    pub fn of(dark: bool) Colors {
        return if (dark) .{
            .keyword = .hex(0xc678dd),
            .string = .hex(0x98c379),
            .number = .hex(0xd19a66),
            .comment = .hex(0x7f848e),
            .function = .hex(0x61afef),
            .type = .hex(0xe5c07b),
            .key = .hex(0xe06c75),
        } else .{
            .keyword = .hex(0xa626a4),
            .string = .hex(0x50a14f),
            .number = .hex(0x986801),
            .comment = .hex(0x8e8f96),
            .function = .hex(0x4078f2),
            .type = .hex(0xc18401),
            .key = .hex(0xe45649),
        };
    }
};

/// What a line leaves open for the next: nothing, a block comment, or a
/// string going on (in backticks, or Python's triple quotes); in markup,
/// a comment, a tag's attributes, a script or a style (and what their
/// code leaves open); in Markdown, a fenced block of code.
pub const State = enum(u8) {
    none,
    comment,
    backtick,
    triple_double,
    triple_single,
    markup_comment,
    markup_tag,
    markup_script,
    markup_script_comment,
    markup_script_backtick,
    markup_style,
    markup_style_comment,
    md_fence,
};

fn identStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn identChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn contains(list: []const []const u8, w: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, w)) return true;
    return false;
}

pub const H = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Span),
    base: usize,
    colors: Colors,

    pub fn span(h: *H, a: usize, b: usize, color: Color, italic: bool) void {
        if (b <= a) return;
        h.out.append(h.gpa, .{ .start = @intCast(h.base + a), .end = @intCast(h.base + b), .color = color, .italic = italic }) catch {};
    }
};

/// Highlights one line, its spans offset by `base`; returns the state it leaves.
pub fn line(gpa: std.mem.Allocator, lang: *const Language, s: []const u8, state_in: State, base: usize, colors: Colors, out: *std.ArrayList(Span)) State {
    switch (lang.mode) {
        .code => {},
        else => return @import("highlight_markup.zig").line(gpa, lang, s, state_in, base, colors, out),
    }
    var h: H = .{ .gpa = gpa, .out = out, .base = base, .colors = colors };
    var i: usize = 0;
    var state = state_in;
    const block = blockOf(lang);
    // What the line before left open.
    switch (state) {
        .none => {},
        .comment => {
            const close = if (block) |b| b[1] else "*/";
            const e = std.mem.indexOf(u8, s, close) orelse {
                h.span(0, s.len, colors.comment, true);
                return state;
            };
            h.span(0, e + close.len, colors.comment, true);
            i = e + close.len;
            state = .none;
        },
        // A state of markup's, given to code: begun afresh.
        else => if (state != .backtick and state != .triple_double and state != .triple_single) {
            state = .none;
        },
        .backtick, .triple_double, .triple_single => {
            const close: []const u8 = switch (state) {
                .backtick => "`",
                .triple_double => "\"\"\"",
                else => "'''",
            };
            const e = std.mem.indexOf(u8, s, close) orelse {
                h.span(0, s.len, colors.string, false);
                return state;
            };
            h.span(0, e + close.len, colors.string, false);
            i = e + close.len;
            state = .none;
        },
    }
    while (i < s.len) {
        const c = s[i];
        const rest = s[i..];
        if (lang.line_comment.len > 0 and std.mem.startsWith(u8, rest, lang.line_comment) and (lang.line_comment[0] != '#' or i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) {
            h.span(i, s.len, colors.comment, true);
            return state;
        }
        if (block) |b| if (std.mem.startsWith(u8, rest, b[0])) {
            const e = std.mem.indexOfPos(u8, s, i + b[0].len, b[1]) orelse {
                h.span(i, s.len, colors.comment, true);
                return .comment;
            };
            h.span(i, e + b[1].len, colors.comment, true);
            i = e + b[1].len;
            continue;
        };
        if (lang.triple and (std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''"))) {
            const e = std.mem.indexOfPos(u8, s, i + 3, rest[0..3]) orelse {
                h.span(i, s.len, colors.string, false);
                return if (c == '"') .triple_double else .triple_single;
            };
            h.span(i, e + 3, colors.string, false);
            i = e + 3;
            continue;
        }
        if (lang.multiline != 0 and c == lang.multiline) {
            const e = std.mem.indexOfScalarPos(u8, s, i + 1, c) orelse {
                h.span(i, s.len, colors.string, false);
                return .backtick;
            };
            h.span(i, e + 1, colors.string, false);
            i = e + 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, lang.quotes, c) != null) {
            var j = i + 1;
            while (j < s.len and s[j] != c) : (j += 1) {
                if (s[j] == '\\') j += 1;
            }
            const e = @min(s.len, j + 1);
            var k = e;
            while (k < s.len and s[k] == ' ') k += 1;
            const is_key = lang.keys and k < s.len and s[k] == ':';
            h.span(i, e, if (is_key) colors.key else colors.string, false);
            i = e;
            continue;
        }
        // Zig's multiline strings: \\ to the end of the line.
        if (lang.sigil == '@' and std.mem.startsWith(u8, rest, "\\\\")) {
            h.span(i, s.len, colors.string, false);
            return state;
        }
        if (std.ascii.isDigit(c) and (i == 0 or !identChar(s[i - 1]))) {
            var j = i + 1;
            while (j < s.len and (identChar(s[j]) or s[j] == '.')) j += 1;
            h.span(i, j, colors.number, false);
            i = j;
            continue;
        }
        if (lang.sigil != 0 and c == lang.sigil and i + 1 < s.len and (identStart(s[i + 1]) or s[i + 1] == '{')) {
            var j = i + 1;
            if (s[j] == '{') {
                j = (std.mem.indexOfScalarPos(u8, s, j, '}') orelse s.len - 1) + 1;
            } else while (j < s.len and identChar(s[j])) j += 1;
            h.span(i, j, if (lang.sigil == '@') colors.function else colors.key, false);
            i = j;
            continue;
        }
        if (identStart(c)) {
            var j = i + 1;
            while (j < s.len and identChar(s[j])) j += 1;
            const w = s[i..j];
            var k = j;
            while (k < s.len and s[k] == ' ') k += 1;
            if (contains(lang.keywords, w)) {
                h.span(i, j, colors.keyword, false);
            } else if (contains(lang.constants, w)) {
                h.span(i, j, colors.number, false);
            } else if (k < s.len and s[k] == '(') {
                h.span(i, j, colors.function, false);
            } else if (std.ascii.isUpper(w[0]) and !lang.keys and lang.sigil != '$') {
                h.span(i, j, colors.type, false);
            }
            i = j;
            continue;
        }
        i += 1;
    }
    return state;
}

/// Highlights `code`, a line at a time, from `state`; returns what its
/// last line leaves open.
pub fn highlight(gpa: std.mem.Allocator, lang: *const Language, code: []const u8, state_in: State, base: usize, colors: Colors, out: *std.ArrayList(Span)) State {
    var state = state_in;
    var start: usize = 0;
    while (start <= code.len) {
        const e = std.mem.indexOfScalarPos(u8, code, start, '\n') orelse code.len;
        state = line(gpa, lang, code[start..e], state, base + start, colors, out);
        start = e + 1;
    }
    return state;
}

test "highlight" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Span) = .empty;
    defer out.deinit(gpa);
    const colors = Colors.of(false);
    const st = highlight(gpa, language("zig").?, "const x = @import(\"std\"); // hi\nfn f() u8 { return 42; }", .none, 0, colors, &out);
    try std.testing.expectEqual(State.none, st);
    try std.testing.expect(out.items.len >= 7);
    try std.testing.expectEqual(colors.keyword, out.items[0].color.?);
    try std.testing.expectEqual(@as(u32, 5), out.items[0].end);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(State.comment, highlight(gpa, language("go").?, "x /* a", .none, 0, colors, &out));
    out.clearRetainingCapacity();
    try std.testing.expectEqual(State.triple_double, highlight(gpa, language("python").?, "s = \"\"\"doc", .none, 0, colors, &out));
    out.clearRetainingCapacity();
    _ = highlight(gpa, language("json").?, "{\"a\": 1}", .none, 0, colors, &out);
    try std.testing.expectEqual(colors.key, out.items[0].color.?);
    try std.testing.expect(language("rust") != null); // highlight_langs.zig
    try std.testing.expect(language("cobol") == null);
}
