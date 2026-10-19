//! Dates and times in the way of a locale, in the Gregorian calendar, as
//! ICU and Intl.DateTimeFormat write them: by style (dateStyle, timeStyle)
//! or by a skeleton of CLDR, with the locale's names of months, weekdays and
//! day periods, its patterns and its digits, in 12 or 24 hours.
const std = @import("std");
const data = @import("locale_data.zig");
const number = @import("number.zig");
const tags = @import("data_tags.zig");
const Writer = std.Io.Writer;

/// A moment, and the offset of the time zone it is shown in.
pub const DateTime = struct {
    /// Seconds since 1970-01-01 00:00 UTC.
    unix: i64,
    /// Minutes east of UTC of the zone; null is UTC itself, written by
    /// name ("UTC"), where an offset of 0 is written "GMT".
    offset_minutes: ?i16 = null,

    /// The moment of a civil date and time in UTC.
    pub fn utc(year: i32, month: u4, day: u5, hour: u5, minute: u6, second: u6) DateTime {
        const days = daysFromCivil(year, month, day);
        return .{ .unix = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second };
    }

    /// The date and time it shows in its zone.
    pub fn civil(t: DateTime) Civil {
        const local = t.unix + @as(i64, t.offset_minutes orelse 0) * 60;
        const days = @divFloor(local, 86400);
        const secs: u32 = @intCast(local - days * 86400);
        var c = civilFromDays(days);
        c.hour = @intCast(secs / 3600);
        c.minute = @intCast(secs / 60 % 60);
        c.second = @intCast(secs % 60);
        c.weekday = @intCast(@mod(days + 4, 7)); // 1970-01-01 was a Thursday
        return c;
    }
};

pub const Civil = struct {
    year: i32,
    /// 1 to 12.
    month: u4,
    day: u5,
    hour: u5 = 0,
    minute: u6 = 0,
    second: u6 = 0,
    /// 0 for Sunday to 6 for Saturday.
    weekday: u3 = 0,
};

// Howard Hinnant's algorithms of civil dates.
fn daysFromCivil(year: i32, month: u4, day: u5) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = @intCast(yoe + era * 400 + @intFromBool(m <= 2)), .month = @intCast(m), .day = @intCast(d) };
}

/// The length of a date or a time by style.
pub const Style = enum(u3) {
    none,
    /// Numeric: "1/5/26", "1:07 PM".
    short,
    /// Abbreviated: "Jan 5, 2026", "1:07:09 PM".
    medium,
    /// The month written out: "January 5, 2026", "1:07:09 PM UTC".
    long,
    /// Everything: "Monday, January 5, 2026".
    full,

    fn index(s: Style) usize {
        return @intFromEnum(Style.full) - @intFromEnum(s);
    }

    pub fn parse(s: []const u8) ?Style {
        const v = std.meta.stringToEnum(Style, s) orelse return null;
        return if (v == .none) null else v;
    }
};

pub const DateOptions = struct {
    date: Style = .none,
    time: Style = .none,
    /// The fields to write when both styles are none, as a skeleton of
    /// CLDR: one of `skeletons` ("yMMMd", "MMMd", "Ed", "jm"...). No style
    /// and no skeleton is "yMd".
    skeleton: []const u8 = "",
    /// 12 or 24 to write times so, as the user's regional settings say;
    /// 0 keeps the locale's (or its -u-hc).
    hour_cycle: u8 = 0,
};

/// The skeletons myzig has the patterns of, for every locale it formats.
pub const skeletons = tags.skeletons;

pub fn isSkeleton(s: []const u8) bool {
    for (skeletons) |k| if (std.mem.eql(u8, k, s)) return true;
    return false;
}

fn skeletonPattern(d: *const data.Dates, skel: []const u8) []const u8 {
    for (skeletons, 0..) |k, i| if (std.mem.eql(u8, k, skel)) return data.item(d.skeletons, i);
    return data.item(d.skeletons, 0);
}

/// The pattern of options in a locale, as CLDR's letters ("MMM d, y").
pub const Pattern = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn slice(p: *const Pattern) []const u8 {
        return p.buf[0..p.len];
    }

    fn set(p: *Pattern, s: []const u8) void {
        p.len = 0;
        p.add(s);
    }

    fn add(p: *Pattern, s: []const u8) void {
        const n = @min(s.len, p.buf.len - p.len);
        @memcpy(p.buf[p.len..][0..n], s[0..n]);
        p.len += n;
    }
};

pub fn pattern(locale: []const u8, o: DateOptions) Pattern {
    const k = data.keyOf(locale);
    return patternOf(&k, o);
}

fn patternOf(k: *const data.Key, o: DateOptions) Pattern {
    const d = data.dates(k.data);
    var p: Pattern = .{};
    var hc: u8 = switch (o.hour_cycle) {
        12 => 'h',
        24 => 'H',
        else => k.hour_cycle,
    };
    if (o.date == .none and o.time == .none) {
        var skel = if (o.skeleton.len == 0) "yMd" else o.skeleton;
        if (o.hour_cycle == 0) {
            // An hour letter of the skeleton is an hour cycle, as V8 reads it.
            if (std.mem.indexOfAny(u8, skel, "hH")) |i| hc = skel[i];
        }
        if (hc != 0 and skel.len > 0 and skel[0] == 'j') {
            skel = if (std.mem.eql(u8, skel, "jms"))
                (if (hc == 'h') "hms" else "Hms")
            else
                (if (hc == 'h') "hm" else "Hm");
        }
        p.set(skeletonPattern(d, skel));
        return p;
    }
    const time = if (o.time == .none) "" else data.item(switch (hc) {
        'h' => d.time12,
        'H' => d.time24,
        else => d.time,
    }, o.time.index());
    if (o.date == .none) {
        p.set(time);
        return p;
    }
    const date = data.item(d.date, o.date.index());
    if (o.time == .none) {
        p.set(date);
        return p;
    }
    const glue = data.item(d.glue, o.date.index());
    var i: usize = 0;
    while (i < glue.len) {
        if (std.mem.startsWith(u8, glue[i..], "{1}")) {
            p.add(date);
            i += 3;
        } else if (std.mem.startsWith(u8, glue[i..], "{0}")) {
            p.add(time);
            i += 3;
        } else {
            p.add(glue[i .. i + 1]);
            i += 1;
        }
    }
    return p;
}

/// Writes `t` in the way of `locale`.
pub fn formatDate(w: *Writer, locale: []const u8, t: DateTime, o: DateOptions) Writer.Error!void {
    const k = data.keyOf(locale);
    try writeOptions(w, &k, t, o);
}

/// Writes `t` with options, in the locale of `k`.
pub fn writeOptions(w: *Writer, k: *const data.Key, t: DateTime, o: DateOptions) Writer.Error!void {
    const p = patternOf(k, o);
    try writePattern(w, k, p.slice(), t);
}

pub fn bufFormatDate(buf: []u8, locale: []const u8, t: DateTime, o: DateOptions) Writer.Error![]u8 {
    var w: Writer = .fixed(buf);
    try formatDate(&w, locale, t, o);
    return w.buffered();
}

/// Writes `t` by a pattern of CLDR's letters, in the locale of `k`.
pub fn writePattern(w: *Writer, k: *const data.Key, pat: []const u8, t: DateTime) Writer.Error!void {
    const c = t.civil();
    const has_min = std.mem.indexOfScalar(u8, pat, 'm') != null;
    var i: usize = 0;
    while (i < pat.len) {
        const ch = pat[i];
        if (ch == '\'') {
            if (i + 1 < pat.len and pat[i + 1] == '\'') {
                try w.writeByte('\'');
                i += 2;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, pat, i + 1, '\'') orelse pat.len;
            try w.writeAll(pat[i + 1 .. end]);
            i = @min(end + 1, pat.len);
            continue;
        }
        if (!std.ascii.isAlphabetic(ch)) {
            try w.writeByte(ch);
            i += 1;
            continue;
        }
        var n: usize = 1;
        while (i + n < pat.len and pat[i + n] == ch) n += 1;
        try field(w, k, ch, n, c, t, has_min);
        i += n;
    }
}

fn num(w: *Writer, sys: *const data.System, v: i64, digits: usize) Writer.Error!void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{@abs(v)}) catch unreachable;
    if (v < 0) try w.writeAll(sys.minus);
    var pad = digits -| s.len;
    while (pad > 0) : (pad -= 1) try number.writeDigits(w, sys, "0");
    try number.writeDigits(w, sys, s);
}

fn width3(n: usize) usize {
    // CLDR's lists: wide, abbreviated, narrow.
    return switch (n) {
        4 => 0,
        5 => 2,
        else => 1,
    };
}

fn field(w: *Writer, k: *const data.Key, ch: u8, n: usize, c: Civil, t: DateTime, has_min: bool) Writer.Error!void {
    const d = data.dates(k.data);
    const sys = k.system();
    switch (ch) {
        'G' => {
            const era: usize = @intFromBool(c.year > 0);
            const wi: usize = switch (n) {
                4 => 2,
                5 => 1,
                else => 0,
            };
            try w.writeAll(data.item(d.eras, wi * 2 + era));
        },
        'y', 'u' => {
            const year: i64 = if (ch == 'y' and c.year <= 0) 1 - @as(i64, c.year) else c.year;
            if (n == 2) try num(w, sys, @mod(year, 100), 2) else try num(w, sys, year, n);
        },
        'M', 'L' => {
            if (n <= 2) return num(w, sys, c.month, n);
            const lists = if (ch == 'L') d.months_alone else d.months;
            try w.writeAll(data.item(lists[width3(n)], c.month - 1));
        },
        'd' => try num(w, sys, c.day, n),
        'E', 'c', 'e' => {
            if (ch != 'E' and n <= 2) {
                const first = k.first_day orelse d.first_day;
                return num(w, sys, @mod(@as(i64, c.weekday) - first + 7, 7) + 1, n);
            }
            const lists = if (ch == 'c') d.days_alone else d.days;
            const wi: usize = switch (n) {
                4 => 0,
                5 => 3,
                6 => 2,
                else => 1,
            };
            try w.writeAll(data.item(lists[wi], c.weekday));
        },
        'a', 'b' => try w.writeAll(data.item(d.periods, periodWidth(n) * 2 + @intFromBool(c.hour >= 12))),
        'B' => {
            // Chinese's flexible periods: 0-5 night1, 5-8 morning1, 8-12
            // morning2, 12-13 afternoon1, 13-19 afternoon2, 19-24 evening1.
            if (d.flex.len == 0 or n != 1) return field(w, k, 'a', @min(n, 5), c, t, has_min);
            const by_hour = [24]u8{ 8, 8, 8, 8, 8, 2, 2, 2, 3, 3, 3, 3, 4, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6 };
            const name = data.item(d.flex, by_hour[c.hour]);
            if (name.len == 0) return field(w, k, 'a', 1, c, t, has_min);
            try w.writeAll(name);
        },
        'h' => try num(w, sys, if (c.hour % 12 == 0) 12 else c.hour % 12, n),
        'H' => try num(w, sys, c.hour, n),
        'K' => try num(w, sys, c.hour % 12, n),
        'k' => try num(w, sys, if (c.hour == 0) 24 else c.hour, n),
        'm' => try num(w, sys, c.minute, n),
        's' => try num(w, sys, c.second, n),
        'z', 'O', 'v', 'V', 'Z', 'X', 'x' => try zone(w, d, sys, ch, n, t),
        else => for (0..n) |_| try w.writeByte(ch),
    }
}

fn periodWidth(n: usize) usize {
    // The list of periods: abbreviated, narrow, wide.
    return switch (n) {
        4 => 2,
        5 => 1,
        else => 0,
    };
}

/// UTC's names for UTC, else the offset from GMT in the locale's format.
fn zone(w: *Writer, d: *const data.Dates, sys: *const data.System, ch: u8, n: usize, t: DateTime) Writer.Error!void {
    const long = n >= 4 or ch == 'V';
    const off_min = t.offset_minutes orelse {
        if (ch == 'z' or ch == 'v') return w.writeAll(data.item(d.zone, if (long) 3 else 4));
        return w.writeAll(data.item(d.zone, 1));
    };
    if (off_min == 0) return w.writeAll(data.item(d.zone, 1));
    const hour_format = data.item(d.zone, 2);
    const semi = std.mem.indexOfScalar(u8, hour_format, ';') orelse hour_format.len;
    var p = if (off_min < 0) hour_format[@min(semi + 1, hour_format.len)..] else hour_format[0..semi];
    const off: u32 = @abs(off_min);
    const hours = off / 60;
    const mins = off % 60;
    var hour_digits: usize = 2;
    if (!long) {
        hour_digits = 1;
        if (mins == 0) {
            const mm = std.mem.indexOf(u8, p, "mm") orelse 0;
            if (std.mem.lastIndexOfScalar(u8, p[0..mm], 'H')) |h| p = p[0 .. h + 1];
        }
    }
    var buf: [48]u8 = undefined;
    var o: Writer = .fixed(&buf);
    var i: usize = 0;
    while (i < p.len) {
        if (p[i] == 'H') {
            try num(&o, sys, hours, hour_digits);
            while (i < p.len and p[i] == 'H') i += 1;
        } else if (std.mem.startsWith(u8, p[i..], "mm")) {
            try num(&o, sys, mins, 2);
            i += 2;
        } else {
            try o.writeByte(p[i]);
            i += 1;
        }
    }
    const gmt = data.item(d.zone, 0);
    const at = std.mem.indexOf(u8, gmt, "{0}") orelse return w.writeAll(gmt);
    try w.print("{s}{s}{s}", .{ gmt[0..at], o.buffered(), gmt[at + 3 ..] });
}

/// The widths of the names of months, weekdays and day periods.
pub const Width = enum {
    /// Whole: "January", "Monday".
    wide,
    /// Short: "Jan", "Mon".
    abbreviated,
    /// Shorter still, for weekdays only: "Mo"; months take abbreviated.
    short,
    /// A letter or so: "J", "M", for calendars.
    narrow,
};

/// The names of the months in `locale`, January first. A name standing
/// alone, as a calendar's heading, takes `stand_alone`: some languages
/// write it otherwise inside a date ("января" of "5 января", "январь" alone).
pub fn months(locale: []const u8, width: Width, stand_alone: bool) [12][]const u8 {
    const d = data.dates(data.keyOf(locale).data);
    const lists = if (stand_alone) d.months_alone else d.months;
    const list = lists[
        switch (width) {
            .wide => 0,
            .abbreviated, .short => 1,
            .narrow => 2,
        }
    ];
    var out: [12][]const u8 = undefined;
    for (&out, 0..) |*m, i| m.* = data.item(list, i);
    return out;
}

/// The names of the days of the week in `locale`, Sunday first.
pub fn weekdays(locale: []const u8, width: Width, stand_alone: bool) [7][]const u8 {
    const d = data.dates(data.keyOf(locale).data);
    const lists = if (stand_alone) d.days_alone else d.days;
    const list = lists[@intFromEnum(width)];
    var out: [7][]const u8 = undefined;
    for (&out, 0..) |*m, i| m.* = data.item(list, i);
    return out;
}

/// The names of the halves of the day, before noon and after: "AM" and
/// "PM" in English, "上午" and "下午" in Chinese.
pub fn dayPeriods(locale: []const u8, width: Width) [2][]const u8 {
    const d = data.dates(data.keyOf(locale).data);
    const wi: usize = switch (width) {
        .wide => 2,
        .narrow => 1,
        else => 0,
    };
    return .{ data.item(d.periods, wi * 2), data.item(d.periods, wi * 2 + 1) };
}
