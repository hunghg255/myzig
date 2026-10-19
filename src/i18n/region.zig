//! Regional formats: how a reader writes dates, times and numbers, which
//! may be another language's than the one they read, with the changes they
//! made in the system's settings (an English reader in Germany who wants
//! weeks to start on Monday and times in 24 hours).
const std = @import("std");
const tag = @import("tag.zig");
const data = @import("locale_data.zig");

pub const Region = struct {
    /// The locale of the formats, as "en-GB" or "de-DE", or "" when the
    /// system names none.
    locale: []const u8 = "",
    /// The day calendars start their weeks on, 0 Sunday to 6 Saturday.
    first_weekday: u3 = 0,
    /// 12 for times with AM and PM, 24 without, 0 when not known (which
    /// makes `first_weekday` mean nothing).
    hour_cycle: u8 = 0,

    /// The locale a reader of `lang` with these formats writes numbers and
    /// dates in, as Apple's Locale.current puts the two together: the
    /// language with the region of the formats, and their first weekday and
    /// hour cycle in its Unicode extension: "en-GB-u-fw-mon-hc-h23" for
    /// English read with British formats, "en-DE-u-fw-mon-hc-h23" with
    /// German ones, "zh-Hant-DE-..." for zh-HK (the script it implies
    /// stays). The pseudo locales format as English.
    pub fn formatLocale(r: Region, lang: []const u8) tag.Tag {
        var t = (if (tag.isPseudo(lang)) null else tag.Tag.parse(lang)) orelse tag.Tag.from("en");
        t = t.withoutExtensions();
        if (tag.Tag.parse(r.locale)) |rt| if (rt.region()) |reg| {
            const m = tag.maximize(&t);
            var out = tag.Tag.from(m.lang);
            // The script the reader reads, named or implied, unless the new
            // region implies it too.
            var buf: [16]u8 = undefined;
            const implied = tag.maximize(&tag.Tag.from(std.fmt.bufPrint(&buf, "{s}-{s}", .{ m.lang, reg }) catch m.lang));
            if (t.script() != null or (!m.usual_script and !std.mem.eql(u8, implied.script, m.script))) {
                out = join(out, m.script);
            }
            t = join(out, reg);
        };
        if (r.hour_cycle != 12 and r.hour_cycle != 24) return t;
        const days = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
        var buf: [tag.max_len]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}-u-fw-{s}-hc-{s}", .{ t.slice(), days[r.first_weekday], if (r.hour_cycle == 12) "h12" else "h23" }) catch return t;
        return tag.Tag.from(s);
    }
};

fn join(t: tag.Tag, sub: []const u8) tag.Tag {
    var buf: [tag.max_len]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}-{s}", .{ t.slice(), sub }) catch return t;
    return tag.Tag.from(s);
}

/// The regional formats CLDR gives `locale`: its region's first day of the
/// week and hour cycle. The system's settings may differ.
pub fn regionFor(locale: []const u8) Region {
    return .{ .locale = locale, .first_weekday = data.firstWeekday(locale), .hour_cycle = data.hourCycle(locale) };
}
