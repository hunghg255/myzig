//! The pseudo locales, which test an app's layouts before translations
//! exist, as Android's: their messages are the source language's,
//! transformed. en-XA accents the letters, makes the text about 40% longer
//! and brackets it ("[Šéļéçţ ƒîļéš one two]"), to find strings that are not
//! in a catalog, are cut, or are put together from pieces; ar-XB shows each
//! word right to left, and the app is laid out right to left, to find what
//! does not mirror.
const std = @import("std");
const Writer = std.Io.Writer;
const tag = @import("tag.zig");

pub const Method = enum { none, accents, bidi };

pub fn methodOf(locale: []const u8) Method {
    const t = (tag.normalize(locale) orelse return .none).withoutExtensions();
    if (t.eql(tag.pseudo_accents)) return .accents;
    if (t.eql(tag.pseudo_bidi)) return .bidi;
    return .none;
}

pub const rlm = "\u{200f}"; // right-to-left mark
const rlo = "\u{202e}"; // right-to-left override
const pdf = "\u{202c}"; // pop directional formatting

/// The letters of en-XA, from Android's pseudolocalizer.
fn accented(c: u8) ?[]const u8 {
    const lower = [_][]const u8{ "å", "ƀ", "ç", "ð", "é", "ƒ", "ĝ", "ĥ", "î", "ĵ", "ķ", "ļ", "ɱ", "ñ", "ö", "þ", "ǫ", "ŕ", "š", "ţ", "û", "ṽ", "ŵ", "ẋ", "ý", "ž" };
    const upper = [_][]const u8{ "Å", "Ɓ", "Ç", "Ð", "É", "Ƒ", "Ĝ", "Ĥ", "Î", "Ĵ", "Ķ", "Ļ", "Ṁ", "Ñ", "Ö", "Þ", "Ǫ", "Ŕ", "Š", "Ţ", "Û", "Ṽ", "Ŵ", "Ẋ", "Ý", "Ž" };
    if (c >= 'a' and c <= 'z') return lower[c - 'a'];
    if (c >= 'A' and c <= 'Z') return upper[c - 'A'];
    return null;
}

/// Writes text of a message as `m` transforms it; returns the characters
/// it counted, for the padding of en-XA.
pub fn text(w: *Writer, m: Method, s: []const u8) Writer.Error!usize {
    switch (m) {
        .none => {
            try w.writeAll(s);
            return 0;
        },
        .accents => {
            var n: usize = 0;
            var it = std.unicode.Utf8View.initUnchecked(s).iterator();
            while (it.nextCodepointSlice()) |cp| : (n += 1) {
                if (cp.len == 1) if (accented(cp[0])) |a| {
                    try w.writeAll(a);
                    continue;
                };
                try w.writeAll(cp);
            }
            return n;
        },
        .bidi => {
            // Each run of characters other than spaces in an override,
            // between marks that set it in a right-to-left run.
            var i: usize = 0;
            while (i < s.len) {
                const start = i;
                while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
                try w.writeAll(s[start..i]);
                if (i == s.len) break;
                const word = i;
                while (i < s.len and !std.ascii.isWhitespace(s[i])) i += 1;
                try w.print(rlm ++ rlo ++ "{s}" ++ pdf ++ rlm, .{s[word..i]});
            }
            return 0;
        },
    }
}

const pad_words = [_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty" };

/// What en-XA writes before a message.
pub fn begin(w: *Writer, m: Method) Writer.Error!void {
    if (m == .accents) try w.writeByte('[');
}

/// What en-XA writes after a message of `letters` characters: words that
/// make it 40% longer, rounded up, and its bracket.
pub fn end(w: *Writer, m: Method, letters: usize) Writer.Error!void {
    if (m != .accents) return;
    const pad = (letters * 2 + 4) / 5;
    var n: usize = 0;
    var i: usize = 0;
    while (n < pad) : (i += 1) {
        const word = pad_words[i % pad_words.len];
        try w.print(" {s}", .{word});
        n += 1 + word.len;
    }
    try w.writeByte(']');
}

/// A message without arguments as `m` transforms it, at compile time.
pub fn comptimeText(comptime m: Method, comptime s: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        switch (m) {
            .none => return s,
            .accents => {
                var n: usize = 0;
                var it = std.unicode.Utf8View.initUnchecked(s).iterator();
                while (it.nextCodepointSlice()) |cp| : (n += 1) {
                    out = out ++ (if (cp.len == 1) accented(cp[0]) orelse cp else cp);
                }
                const pad = (n * 2 + 4) / 5;
                var k: usize = 0;
                var i: usize = 0;
                while (k < pad) : (i += 1) {
                    const word = pad_words[i % pad_words.len];
                    out = out ++ " " ++ word;
                    k += 1 + word.len;
                }
                return "[" ++ out ++ "]";
            },
            .bidi => {
                var i: usize = 0;
                while (i < s.len) {
                    const start = i;
                    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
                    out = out ++ s[start..i];
                    if (i == s.len) break;
                    const word = i;
                    while (i < s.len and !std.ascii.isWhitespace(s[i])) i += 1;
                    out = out ++ rlm ++ rlo ++ s[word..i] ++ pdf ++ rlm;
                }
                return out;
            },
        }
    }
}
