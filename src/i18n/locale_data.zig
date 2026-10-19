//! The formatting data of the locales myzig keeps, from CLDR through mygo's
//! tables (`data_numbers.zig`, `data_dates_*.zig`, `data_tags.zig`, written
//! by `gen/dump_test.go`), and how a locale finds the data it formats with.
//! The numbers are small; the dates, with the names of languages, are
//! referenced only by date formatting, so an app that formats no date does
//! not link them.
const std = @import("std");
const tag = @import("tag.zig");
const Tag = tag.Tag;
const tags = @import("data_tags.zig");
const plural = @import("plural.zig");

/// A number pattern of CLDR with the locale's symbols in its affixes.
pub const Affixes = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    neg_prefix: []const u8 = "-",
    neg_suffix: []const u8 = "",
    /// The sizes of the groups of integer digits, 0 for none: 3 and 2 in
    /// the Indian 12,34,567.
    primary: u8 = 3,
    secondary: u8 = 3,
    max_frac: u8 = 3,
    min_int: u8 = 1,
};

/// How a locale writes numbers in a numbering system.
pub const System = struct {
    /// The digit zero; the others follow it in Unicode.
    zero: u21 = '0',
    decimal: []const u8 = ".",
    group: []const u8 = ",",
    minus: []const u8 = "-",
    percent: []const u8 = "%",
    nan: []const u8 = "NaN",
    infinity: []const u8 = "∞",
    /// Digits needed before the first group: 2 where 1234 stays ungrouped (es, pl).
    min_grouping: u8 = 1,
    dec: Affixes = .{},
    pct: Affixes = .{ .suffix = "%", .neg_suffix = "%", .max_frac = 0 },
};

pub const Numbers = struct {
    tag: []const u8,
    /// The default numbering system, an index into `systems`.
    sys: u8,
    /// Latin digits (-u-nu-latn), where the default system has others.
    latn: ?u8 = null,
};

/// Names and patterns of dates. A list is its items joined by '|'.
pub const Dates = struct {
    tag: []const u8,
    autonym: []const u8,
    /// The hour symbol of the locale's times: 'h' (12 hours) or 'H' (24).
    hour: u8,
    first_day: u3,
    /// Months inside a date and standing alone: wide, abbreviated, narrow.
    months: [3][]const u8,
    months_alone: [3][]const u8,
    /// Weekdays from Sunday: wide, abbreviated, short, narrow.
    days: [4][]const u8,
    days_alone: [4][]const u8,
    /// AM and PM: abbreviated, narrow, wide.
    periods: []const u8,
    /// The flexible day periods of B (midnight, noon, morning1, morning2,
    /// afternoon1, afternoon2, evening1, evening2, night1, night2), for the
    /// languages whose rules myzig keeps (Chinese).
    flex: []const u8 = "",
    /// Eras before and after: abbreviated, narrow, wide.
    eras: []const u8,
    /// Patterns by style, full first: dates, times, times in 12 and in 24
    /// hours, and the glue of a date and a time ({1} the date, {0} the time).
    date: []const u8,
    time: []const u8,
    time12: []const u8,
    time24: []const u8,
    glue: []const u8,
    /// GMT format, GMT zero, hour format, UTC's long and short names.
    zone: []const u8,
    /// The best pattern of each skeleton of `data_tags.skeletons`.
    skeletons: []const u8,
};

pub const numbers = @import("data_numbers.zig").numbers;
pub const systems = @import("data_numbers.zig").systems;

/// The dates of every locale, in the order of `numbers`.
pub fn dates(i: usize) *const Dates {
    const a = @import("data_dates_1.zig").dates;
    const b = @import("data_dates_2.zig").dates;
    const c = @import("data_dates_3.zig").dates;
    if (i < a.len) return &a[i];
    if (i < a.len + b.len) return &b[i - a.len];
    return &c[i - a.len - b.len];
}

/// Item `i` of a list joined by '|'.
pub fn item(list: []const u8, i: usize) []const u8 {
    var it = std.mem.splitScalar(u8, list, '|');
    var n: usize = 0;
    while (it.next()) |s| : (n += 1) if (n == i) return s;
    return "";
}

/// How a locale formats: the data it uses and the preferences of its
/// Unicode extension.
pub const Key = struct {
    /// Index in `numbers` (and `dates`).
    data: usize,
    /// 'h' or 'H' from -u-hc, else 0 for the locale's.
    hour_cycle: u8 = 0,
    /// From -u-fw, else null for the region's.
    first_day: ?u3 = null,
    /// -u-nu-latn: Latin digits.
    latn: bool = false,
    /// The region whose week and time data apply, "" for none.
    region_buf: [3]u8 = undefined,
    region_len: u8 = 0,

    pub fn region(k: *const Key) []const u8 {
        return k.region_buf[0..k.region_len];
    }

    pub fn system(k: *const Key) *const System {
        const n = &numbers[k.data];
        if (k.latn) if (n.latn) |l| return &systems[l];
        return &systems[n.sys];
    }
};

fn indexOf(s: []const u8) ?usize {
    for (numbers, 0..) |n, i| if (std.mem.eql(u8, n.tag, s)) return i;
    return null;
}

const en_index = indexOf("en").?;

/// How `locale` formats: the data of the locale that suits it best (en-GB
/// for en-GB, en-001 for en-AU, zh-Hant for zh-TW... down to its language),
/// else English's. The pseudo locales format as English.
pub fn keyOf(locale: []const u8) Key {
    var k: Key = .{ .data = en_index };
    const t0 = tag.normalize(locale) orelse return k;
    if (t0.unicodeKey("hc")) |hc| {
        if (std.mem.eql(u8, hc, "h12") or std.mem.eql(u8, hc, "h11")) k.hour_cycle = 'h';
        if (std.mem.eql(u8, hc, "h23") or std.mem.eql(u8, hc, "h24")) k.hour_cycle = 'H';
    }
    if (t0.unicodeKey("fw")) |fw| {
        const names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
        for (names, 0..) |n, d| if (std.mem.eql(u8, n, fw)) {
            k.first_day = @intCast(d);
        };
    }
    if (t0.unicodeKey("nu")) |nu| k.latn = std.mem.eql(u8, nu, "latn");
    if (tag.isPseudo(locale)) return k;
    const t = t0.withoutExtensions();
    if (t.region()) |r| {
        @memcpy(k.region_buf[0..r.len], r);
        k.region_len = @intCast(r.len);
    }
    const candidates = [_]Tag{ tag.withImpliedScript(t), t };
    for (candidates) |c| {
        const ch = tag.chain(c.slice());
        for (ch.items()) |*p| if (indexOf(p.slice())) |i| {
            k.data = i;
            return k;
        };
    }
    return k;
}

/// The region of `k`, else the likely one of its locale's language.
fn regionOrLikely(k: *const Key, locale: []const u8) []const u8 {
    if (k.region_len > 0) return k.region();
    const t = Tag.parse(locale) orelse return "001";
    const m = tag.maximize(&t.withoutExtensions());
    return if (m.region.len > 0) m.region else "001";
}

/// The day weeks start on in `locale` (0 Sunday to 6 Saturday), by CLDR's
/// week data for its region or its language's likely one: Sunday for "en"
/// (the United States), Monday for "en-GB" and "de"; or its -u-fw.
pub fn firstWeekday(locale: []const u8) u3 {
    const k = keyOf(locale);
    if (k.first_day) |d| return d;
    const r = regionOrLikely(&k, locale);
    const i = plural.search(&tags.week_regions, r) orelse plural.search(&tags.week_regions, "001").?;
    return @intCast(tags.week[i] & 15);
}

/// 12 for times with AM and PM, 24 for times without, by CLDR's time data
/// for the region of `locale` (or its -u-hc).
pub fn hourCycle(locale: []const u8) u8 {
    return if (preferredHour(locale) == 'h') 12 else 24;
}

pub fn preferredHour(locale: []const u8) u8 {
    const k = keyOf(locale);
    if (k.hour_cycle != 0) return k.hour_cycle;
    const r = regionOrLikely(&k, locale);
    var buf: [16]u8 = undefined;
    const lang = if (Tag.parse(locale)) |t| t.language() else "en";
    const lr = std.fmt.bufPrint(&buf, "{s}-{s}", .{ lang, r }) catch r;
    for ([_][]const u8{ lr, r, "001" }) |key| {
        if (plural.search(&tags.hour_keys, key)) |i| {
            const h = tags.hours[i];
            return if (h == 'h' or h == 'K') 'h' else 'H';
        }
    }
    return 'H';
}

/// The name of a language in itself, for menus of languages: "English",
/// "Deutsch", "简体中文"... of the locales myzig has data of, or of the one
/// `locale` formats with; "" when it has none for its language.
pub fn autonym(locale: []const u8) []const u8 {
    const t = (Tag.parse(locale) orelse return "").withoutExtensions();
    if (tag.isPseudo(t.slice())) return pseudoName(t.slice());
    if (indexOf(t.slice())) |i| return dates(i).autonym;
    for (tags.autonyms) |a| if (t.eql(a[0])) return a[1];
    const k = keyOf(t.slice());
    const name = numbers[k.data].tag;
    const lang_end = std.mem.indexOfScalar(u8, name, '-') orelse name.len;
    if (!std.mem.eql(u8, name[0..lang_end], t.language())) return "";
    return dates(k.data).autonym;
}

fn pseudoName(s: []const u8) []const u8 {
    return if (std.mem.eql(u8, s, tag.pseudo_accents)) tag.pseudo_accents else tag.pseudo_bidi;
}
