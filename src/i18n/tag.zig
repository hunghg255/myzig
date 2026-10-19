//! Language tags (BCP 47): reading the forms desktops report, their likely
//! scripts and regions, CLDR's parent locales, and the direction they are
//! written in. A `Tag` holds its text inline, so nothing here allocates.
const std = @import("std");
const data = @import("data_tags.zig");

pub const max_len = 63;

/// A BCP 47 tag in its canonical form: "en-US", "zh-Hant-TW", "sr-Latn-RS",
/// "en-GB-u-hc-h23".
pub const Tag = struct {
    buf: [max_len]u8 = undefined,
    len: u8 = 0,

    pub fn slice(t: *const Tag) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn eql(t: *const Tag, s: []const u8) bool {
        return std.mem.eql(u8, t.slice(), s);
    }

    pub fn from(s: []const u8) Tag {
        var t: Tag = .{};
        t.append(s);
        return t;
    }

    fn append(t: *Tag, s: []const u8) void {
        const n = @min(s.len, max_len - t.len);
        @memcpy(t.buf[t.len..][0..n], s[0..n]);
        t.len += @intCast(n);
    }

    fn subtag(t: *Tag, s: []const u8) void {
        if (t.len > 0) t.append("-");
        t.append(s);
    }

    /// Reads `locale` in any case ("en-us" is "en-US"), POSIX locales
    /// ("zh_CN.UTF-8" is "zh-CN", "sr_RS@latin" is "sr-Latn-RS") and old
    /// codes ("iw" is "he", "in" is "id", "tl" is "fil"). Null when it names
    /// no language: "", "C", "POSIX", "und".
    pub fn parse(locale: []const u8) ?Tag {
        var s = std.mem.trim(u8, locale, " \t\r\n");
        var modifier: []const u8 = "";
        if (std.mem.indexOfScalar(u8, s, '@')) |i| {
            modifier = s[i + 1 ..];
            s = s[0..i];
        }
        if (std.mem.indexOfScalar(u8, s, '.')) |i| s = s[0..i];
        if (s.len == 0 or s.len > max_len or std.mem.eql(u8, s, "C") or std.mem.eql(u8, s, "POSIX")) return null;

        var parts: [16][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, s, "-_");
        while (it.next()) |p| {
            if (n == parts.len or p.len == 0 or p.len > 8) return null;
            for (p) |c| if (!std.ascii.isAlphanumeric(c)) return null;
            parts[n] = p;
            n += 1;
        }
        if (n == 0 or s[0] == '-' or s[0] == '_') return null;
        var lang_buf: [8]u8 = undefined;
        const lang = std.ascii.lowerString(&lang_buf, parts[0]);
        if (lang.len < 2 or lang.len > 3 or !allLetters(lang)) return null;
        var t: Tag = .{};
        var scr: []const u8 = "";
        var reg: []const u8 = "";
        const alias = aliasOf(lang);
        t.append(alias.lang);
        var i: usize = 1;
        var script_buf: [4]u8 = undefined;
        var region_buf: [3]u8 = undefined;
        if (i < n and parts[i].len == 4 and allLetters(parts[i])) {
            scr = titleCase(&script_buf, parts[i]);
            i += 1;
        }
        if (i < n and ((parts[i].len == 2 and allLetters(parts[i])) or (parts[i].len == 3 and allDigits(parts[i])))) {
            reg = std.ascii.upperString(&region_buf, parts[i]);
            i += 1;
        }
        if (scr.len == 0) scr = modifierScript(modifier) orelse alias.script;
        if (reg.len == 0) reg = alias.region;
        if (std.mem.eql(u8, t.slice(), "und") and scr.len == 0 and reg.len == 0 and i == n) return null;
        if (scr.len > 0) t.subtag(scr);
        if (reg.len > 0) t.subtag(reg);
        // Variants and extensions, lower case as they are.
        while (i < n) : (i += 1) {
            var low: [8]u8 = undefined;
            t.subtag(std.ascii.lowerString(&low, parts[i]));
        }
        return t;
    }

    fn part(t: *const Tag, index: usize) ?[]const u8 {
        var it = std.mem.splitScalar(u8, t.slice(), '-');
        var i: usize = 0;
        while (it.next()) |p| : (i += 1) {
            if (i > 0 and p.len == 1) return null; // an extension
            if (i == index) return p;
        }
        return null;
    }

    /// The language: "zh" of "zh-Hant-TW".
    pub fn language(t: *const Tag) []const u8 {
        return t.part(0) orelse "";
    }

    /// The script the tag names, as "Hant", or null.
    pub fn script(t: *const Tag) ?[]const u8 {
        const p = t.part(1) orelse return null;
        return if (p.len == 4 and allLetters(p)) p else null;
    }

    /// The region the tag names, as "TW" or "419", or null.
    pub fn region(t: *const Tag) ?[]const u8 {
        var i: usize = 1;
        if (t.script() != null) i = 2;
        const p = t.part(i) orelse return null;
        return if ((p.len == 2 and allLetters(p)) or (p.len == 3 and allDigits(p))) p else null;
    }

    /// The tag without its extensions and private use subtags ("-u-hc-h23").
    pub fn withoutExtensions(t: Tag) Tag {
        var out = t;
        out.len = @intCast(extensionsStart(t.slice()));
        return out;
    }

    /// The value of a key of the tag's Unicode extension: "h23" for "hc"
    /// in "en-GB-u-hc-h23".
    pub fn unicodeKey(t: *const Tag, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, t.slice(), '-');
        var in_u = false;
        while (it.next()) |p| {
            if (p.len == 1) {
                in_u = p[0] == 'u';
                continue;
            }
            if (in_u and std.mem.eql(u8, p, key)) return it.next();
        }
        return null;
    }
};

/// Where the extensions of a tag begin: the "-" before its first
/// one-letter subtag ("-u-", "-x-", or "-x" at the end), else its length.
/// It scans the tag, which formatting a message does every time.
pub fn extensionsStart(s: []const u8) usize {
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i - 1] == '-' and s[i] != '-' and (i + 1 == s.len or s[i + 1] == '-')) return i - 1;
    }
    return s.len;
}

fn allLetters(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn titleCase(buf: *[4]u8, s: []const u8) []const u8 {
    for (s, 0..) |c, i| buf[i] = if (i == 0) std.ascii.toUpper(c) else std.ascii.toLower(c);
    return buf[0..s.len];
}

const Alias = struct { lang: []const u8, script: []const u8 = "", region: []const u8 = "" };

/// The old codes of languages, as CLDR replaces them.
fn aliasOf(lang: []const u8) Alias {
    const table = [_]struct { []const u8, Alias }{
        .{ "iw", .{ .lang = "he" } },                 .{ "in", .{ .lang = "id" } },
        .{ "ji", .{ .lang = "yi" } },                 .{ "jw", .{ .lang = "jv" } },
        .{ "tl", .{ .lang = "fil" } },                .{ "sh", .{ .lang = "sr", .script = "Latn" } },
        .{ "mo", .{ .lang = "ro", .region = "MD" } },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], lang)) return e[1];
    return .{ .lang = lang };
}

/// The scripts the modifiers of POSIX locales name.
fn modifierScript(m: []const u8) ?[]const u8 {
    const table = [_][2][]const u8{ .{ "latin", "Latn" }, .{ "cyrillic", "Cyrl" }, .{ "arabic", "Arab" }, .{ "devanagari", "Deva" }, .{ "hebrew", "Hebr" } };
    for (table) |e| if (std.ascii.eqlIgnoreCase(e[0], m)) return e[1];
    return null;
}

/// Reads `locale` as `Tag.parse` does, null when it names no language.
/// Formatting a message normalizes locales every time (that of its plural
/// rules, the pseudo locales): the last few read are kept, per thread, so
/// one read again costs a comparison.
pub fn normalize(locale: []const u8) ?Tag {
    if (@inComptime() or locale.len > max_len) return Tag.parse(locale);
    const C = struct {
        const n = 4;
        threadlocal var inputs: [n][max_len]u8 = undefined;
        threadlocal var lens: [n]u8 = @splat(max_len + 1);
        threadlocal var results: [n]?Tag = @splat(null);
        threadlocal var next: u8 = 0;
    };
    for (&C.lens, 0..) |len, i| {
        if (len == locale.len and std.mem.eql(u8, C.inputs[i][0..len], locale)) return C.results[i];
    }
    const t = Tag.parse(locale);
    const i = C.next;
    C.next = (i + 1) % C.n;
    @memcpy(C.inputs[i][0..locale.len], locale);
    C.lens[i] = @intCast(locale.len);
    C.results[i] = t;
    return t;
}

const Likely = struct { lang: []const u8, script: []const u8, region: []const u8 };

/// Scans CLDR's likely subtags (a string of "lang Script RG;" entries,
/// 3 KB, smaller linked than a table of slices).
fn likelyOf(lang: []const u8) ?Likely {
    var it = std.mem.tokenizeScalar(u8, data.likely, ';');
    while (it.next()) |e| {
        if (e.len <= lang.len or e[lang.len] != ' ' or !std.mem.eql(u8, e[0..lang.len], lang)) continue;
        var f = std.mem.splitScalar(u8, e[lang.len + 1 ..], ' ');
        const sc = f.next().?;
        const r = f.next().?;
        return .{ .lang = lang, .script = if (std.mem.eql(u8, sc, "Zzzz")) "" else sc, .region = if (std.mem.eql(u8, r, "ZZ")) "" else r };
    }
    return null;
}

/// The script `lang` is most likely written in ("Latn" for "en", "Hans" for
/// "zh"), or "" when CLDR's likely subtags do not say.
pub fn likelyScript(lang: []const u8) []const u8 {
    return if (likelyOf(lang)) |l| l.script else "";
}

/// The region `lang` is most likely spoken in ("US" for "en"), or "".
pub fn likelyRegion(lang: []const u8) []const u8 {
    return if (likelyOf(lang)) |l| l.region else "";
}

fn lookupPair(list: []const []const u8, key: []const u8) ?[]const u8 {
    for (list) |e| {
        const sp = std.mem.indexOfScalar(u8, e, ' ').?;
        if (std.mem.eql(u8, e[0..sp], key)) return e[sp + 1 ..];
    }
    return null;
}

/// A tag with its likely subtags: "zh-TW" is zh, Hant, TW.
pub const Maximized = struct {
    lang: []const u8,
    script: []const u8,
    region: []const u8,
    /// Whether the script is the one the language is most often written
    /// in, so a tag without it means it: zh-TW's Hant is not zh's.
    usual_script: bool,
};

/// Adds the likely script and region to `t`, as CLDR's likely subtags do.
pub fn maximize(t: *const Tag) Maximized {
    const lang = t.language();
    const usual = likelyScript(lang);
    var buf: [16]u8 = undefined;
    var script: []const u8 = t.script() orelse "";
    var region: []const u8 = t.region() orelse "";
    if (script.len == 0 and region.len > 0) {
        const key = std.fmt.bufPrint(&buf, "{s}-{s}", .{ lang, region }) catch "";
        script = lookupPair(&data.region_scripts, key) orelse usual;
    }
    if (script.len == 0) script = usual;
    if (region.len == 0) {
        if (!std.mem.eql(u8, script, usual)) {
            const key = std.fmt.bufPrint(&buf, "{s}-{s}", .{ lang, script }) catch "";
            region = lookupPair(&data.script_regions, key) orelse likelyRegion(lang);
        } else region = likelyRegion(lang);
    }
    return .{ .lang = lang, .script = script, .region = region, .usual_script = std.mem.eql(u8, script, usual) };
}

/// `t` with the script it implies inserted where that differs from its
/// language's usual one: zh-TW is zh-Hant-TW, whose parent is zh-Hant.
pub fn withImpliedScript(t: Tag) Tag {
    if (t.script() != null) return t;
    const m = maximize(&t);
    if (m.usual_script or m.script.len == 0) return t;
    var out: Tag = .{};
    out.append(m.lang);
    out.subtag(m.script);
    const rest = t.slice()[m.lang.len..];
    out.append(rest);
    return out;
}

/// The language of `locale` without script and region: "zh" for
/// "zh-Hant-TW", "he" for "iw"; null when it names no language.
pub fn base(locale: []const u8) ?Tag {
    const t = Tag.parse(locale) orelse return null;
    return Tag.from(t.language());
}

/// The pseudo locales, which test layouts without translations: en-XA
/// accents the source's messages and makes them longer, ar-XB shows them
/// right to left.
pub const pseudo_accents = "en-XA";
pub const pseudo_bidi = "ar-XB";

pub fn isPseudo(locale: []const u8) bool {
    const t = (normalize(locale) orelse return false).withoutExtensions();
    return t.eql(pseudo_accents) or t.eql(pseudo_bidi);
}

pub const Direction = enum { ltr, rtl };

/// The scripts of Unicode written right to left.
const rtl_scripts = [_][]const u8{
    "Adlm", "Arab", "Aran", "Armi", "Avst", "Chrs", "Cprt", "Elym", "Hatr", "Hebr", "Hung", "Khar",
    "Lydi", "Mand", "Mani", "Mend", "Merc", "Mero", "Narb", "Nbat", "Nkoo", "Orkh", "Ougr", "Palm",
    "Phli", "Phlp", "Phnx", "Prti", "Rohg", "Samr", "Sarb", "Sogd", "Sogo", "Syrc", "Thaa", "Yezi",
};

/// The direction `locale` is written in, that of its script, named or
/// likely: right to left for Arabic, Hebrew, Persian, Urdu... and ar-XB.
pub fn direction(locale: []const u8) Direction {
    const t = Tag.parse(locale) orelse return .ltr;
    const m = maximize(&t);
    for (rtl_scripts) |s| if (std.mem.eql(u8, s, m.script)) return .rtl;
    return .ltr;
}

/// The locale `locale` inherits what it lacks from, by CLDR's parent
/// locales, or null at the root: "en-001" for "en-AU", "en" for "en-001",
/// "zh-Hant-HK" for "zh-Hant-MO", "no" for "nb", else the tag without its
/// last subtag. A language in a script other than its usual one inherits
/// from nothing (CLDR's nonlikelyScript rule): "zh-Hant" and "sr-Latn" are
/// roots. Extensions are dropped first.
pub fn parent(locale: []const u8) ?Tag {
    const t = (Tag.parse(locale) orelse return null).withoutExtensions();
    return parentOf(t);
}

pub fn parentOf(t: Tag) ?Tag {
    const s = t.slice();
    if (@import("plural.zig").search(&data.parent_children, s)) |i| {
        const p = data.parent_locales[i];
        return if (p.len == 0) null else Tag.from(p);
    }
    const dash = std.mem.indexOfScalar(u8, s, '-') orelse return null;
    const rest = s[dash + 1 ..];
    if (rest.len == 4 and allLetters(rest)) {
        const usual = likelyScript(s[0..dash]);
        if (usual.len > 0 and !std.mem.eql(u8, usual, rest)) return null;
    }
    return Tag.from(s[0..std.mem.lastIndexOfScalar(u8, s, '-').?]);
}

/// A tag and its parents, nearest first, without the root.
pub const Chain = struct {
    tags: [8]Tag = undefined,
    len: usize = 0,

    pub fn items(c: *const Chain) []const Tag {
        return c.tags[0..c.len];
    }

    pub fn contains(c: *const Chain, s: []const u8) bool {
        for (c.items()) |*t| if (t.eql(s)) return true;
        return false;
    }
};

pub fn chain(locale: []const u8) Chain {
    var c: Chain = .{};
    var t: ?Tag = (Tag.parse(locale) orelse return c).withoutExtensions();
    while (t) |cur| : (t = parentOf(cur)) {
        if (c.len == c.tags.len) break;
        c.tags[c.len] = cur;
        c.len += 1;
    }
    return c;
}
