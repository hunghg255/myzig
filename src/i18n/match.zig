//! Language negotiation: of the languages an app is written in, the one
//! that suits a reader best, by the languages they read in the order they
//! prefer them.
const std = @import("std");
const tag = @import("tag.zig");
const Tag = tag.Tag;

/// The index in `supported` of the language that best suits a reader of
/// `preferred` (most preferred first), or null when none does.
///
/// A supported language suits a reader when it is the same language in the
/// same script, named or likely: zh-Hant for zh-TW but not zh-Hans, sr-Latn
/// for sr_RS@latin but not for sr-Cyrl; nb and no are one language. Of
/// those, the closest wins: the same tag, then the same likely region (en-US
/// for en, zh-Hant for zh-TW), then a parent of the reader's (es-419 for
/// es-MX before es), then a sibling under a common parent (en-GB for en-AU,
/// both en-001), then the language alone, then its usual region, then any
/// other. A language the reader prefers more wins over a closer match of one
/// they prefer less: fr for fr-CA wins over de for de.
pub fn match(preferred: []const []const u8, supported: []const []const u8) ?usize {
    for (preferred) |p| {
        const want = Tag.parse(p) orelse continue;
        var best: ?usize = null;
        var best_score: u8 = 255;
        for (supported, 0..) |s, i| {
            const have = Tag.parse(s) orelse continue;
            const sc = score(want, have) orelse continue;
            if (sc < best_score) {
                best = i;
                best_score = sc;
            }
        }
        if (best) |b| return b;
    }
    return null;
}

/// Like `match`, for one preferred language.
pub fn matchOne(preferred: []const u8, supported: []const []const u8) ?usize {
    return match(&.{preferred}, supported);
}

fn sameLanguage(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const nb = std.mem.eql(u8, a, "nb") or std.mem.eql(u8, a, "no");
    return nb and (std.mem.eql(u8, b, "nb") or std.mem.eql(u8, b, "no"));
}

/// How far `have` is from `want`, lower is closer; null when it does not suit.
fn score(want_full: Tag, have_full: Tag) ?u8 {
    const want = want_full.withoutExtensions();
    const have = have_full.withoutExtensions();
    if (std.mem.eql(u8, want.slice(), have.slice())) return 0;
    const mw = tag.maximize(&want);
    const mh = tag.maximize(&have);
    if (!sameLanguage(mw.lang, mh.lang) or !std.mem.eql(u8, mw.script, mh.script)) return null;
    const have_region = have.region() != null;
    if (std.mem.eql(u8, mw.region, mh.region) and mw.region.len > 0) return 1;
    const scripted_want = tag.withImpliedScript(want);
    const scripted_have = tag.withImpliedScript(have);
    const cw = tag.chain(scripted_want.slice());
    for (cw.items()[1..], 0..) |*t, depth| {
        if (t.eql(scripted_have.slice())) return @intCast(2 + depth);
    }
    // A sibling: a parent in common other than the bare language.
    const ch = tag.chain(scripted_have.slice());
    for (ch.items()[1..]) |*t| {
        if (t.script() == null and t.region() == null) continue;
        if (cw.contains(t.slice())) return 12;
    }
    if (!have_region) return 13;
    if (std.mem.eql(u8, mh.region, tag.likelyRegion(mh.lang))) return 14;
    return 15;
}

/// The tags to look an app's message up in for `locale`, nearest first:
/// the language of `langs` that suits it best and its parents (zh-Hant for
/// zh-TW, en-GB then en for en-AU), then the locale's own parents, in the
/// script it implies (zh-Hant-TW's), then `source` and its parents. Only
/// tags of `langs` are kept, as indices into it. (mygo looks in the locale's
/// parents first, which gives a reader of zh-TW the zh of a catalog that has
/// zh and zh-Hant.)
pub const Fallbacks = struct {
    indices: [16]u8 = undefined,
    len: u8 = 0,

    pub fn items(f: *const Fallbacks) []const u8 {
        return f.indices[0..f.len];
    }

    fn add(f: *Fallbacks, i: usize) void {
        for (f.items()) |j| if (j == i) return;
        if (f.len == f.indices.len) return;
        f.indices[f.len] = @intCast(i);
        f.len += 1;
    }

    fn addChain(f: *Fallbacks, langs: []const []const u8, locale: []const u8) void {
        const c = tag.chain(locale);
        for (c.items()) |*t| {
            for (langs, 0..) |l, i| if (t.eql(l)) f.add(i);
        }
    }
};

pub fn fallbacks(locale: []const u8, langs: []const []const u8, source: []const u8) Fallbacks {
    var f: Fallbacks = .{};
    if (Tag.parse(locale)) |t0| {
        const t = t0.withoutExtensions();
        if (matchOne(t.slice(), langs)) |m| f.addChain(langs, langs[m]);
        f.addChain(langs, tag.withImpliedScript(t).slice());
    }
    f.addChain(langs, source);
    return f;
}
