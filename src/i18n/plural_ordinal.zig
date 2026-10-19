// Generated from mygo's i18n/tables.go (CLDR 48.2.0) by src/i18n/gen/plurals.py. Do not edit.
//! The ordinal plural rules of CLDR, a branch per distinct rule set.
const plural = @import("plural.zig");
const Plural = plural.Plural;
const Operands = plural.Operands;

/// The category of `o` by the ordinal rules of rule set `r`.
pub fn rule(r: u8, o: *const Operands) Plural {
    switch (r) {
        1 => {
            // n = 1,5,7,8,9,10
            if (o.f == 0 and (o.i == 1 or o.i == 5 or o.i == 7 or o.i == 8 or o.i == 9 or o.i == 10)) {
                return .one;
            }
            // n = 2,3
            if (o.f == 0 and (o.i == 2 or o.i == 3)) {
                return .two;
            }
            // n = 4
            if (o.f == 0 and o.i == 4) {
                return .few;
            }
            // n = 6
            if (o.f == 0 and o.i == 6) {
                return .many;
            }
        },
        2 => {
            // i % 10 = 1,2,5,7,8 or i % 100 = 20,50,70,80
            if ((o.i % 10 == 1 or o.i % 10 == 2 or o.i % 10 == 5 or o.i % 10 == 7 or o.i % 10 == 8) or (o.i % 100 == 20 or o.i % 100 == 50 or o.i % 100 == 70 or o.i % 100 == 80)) {
                return .one;
            }
            // i % 10 = 3,4 or i % 1000 = 100,200,300,400,500,600,700,800,900
            if ((o.i % 10 == 3 or o.i % 10 == 4) or (o.i % 1000 == 100 or o.i % 1000 == 200 or o.i % 1000 == 300 or o.i % 1000 == 400 or o.i % 1000 == 500 or o.i % 1000 == 600 or o.i % 1000 == 700 or o.i % 1000 == 800 or o.i % 1000 == 900)) {
                return .few;
            }
            // i = 0 or i % 10 = 6 or i % 100 = 40,60,90
            if (o.i == 0 or o.i % 10 == 6 or (o.i % 100 == 40 or o.i % 100 == 60 or o.i % 100 == 90)) {
                return .many;
            }
        },
        3 => {
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
        },
        4 => {
            // n % 10 = 2,3 and n % 100 != 12,13
            if (o.f == 0 and (o.i % 10 == 2 or o.i % 10 == 3) and !(o.i % 100 == 12 or o.i % 100 == 13)) {
                return .few;
            }
        },
        5 => {
            // i = 0
            if (o.i == 0) {
                return .zero;
            }
            // i = 1
            if (o.i == 1) {
                return .one;
            }
            // i = 2,3,4,5,6
            if (o.i == 2 or o.i == 3 or o.i == 4 or o.i == 5 or o.i == 6) {
                return .few;
            }
        },
        6 => {
            // n = 1,3
            if (o.f == 0 and (o.i == 1 or o.i == 3)) {
                return .one;
            }
            // n = 2
            if (o.f == 0 and o.i == 2) {
                return .two;
            }
            // n = 4
            if (o.f == 0 and o.i == 4) {
                return .few;
            }
        },
        7 => {
            // n = 0,7,8,9
            if (o.f == 0 and (o.i == 0 or o.i == 7 or o.i == 8 or o.i == 9)) {
                return .zero;
            }
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
            // n = 2
            if (o.f == 0 and o.i == 2) {
                return .two;
            }
            // n = 3,4
            if (o.f == 0 and (o.i == 3 or o.i == 4)) {
                return .few;
            }
            // n = 5,6
            if (o.f == 0 and (o.i == 5 or o.i == 6)) {
                return .many;
            }
        },
        8 => {
            // n % 10 = 1 and n % 100 != 11
            if (o.f == 0 and o.i % 10 == 1 and !(o.i % 100 == 11)) {
                return .one;
            }
            // n % 10 = 2 and n % 100 != 12
            if (o.f == 0 and o.i % 10 == 2 and !(o.i % 100 == 12)) {
                return .two;
            }
            // n % 10 = 3 and n % 100 != 13
            if (o.f == 0 and o.i % 10 == 3 and !(o.i % 100 == 13)) {
                return .few;
            }
        },
        9 => {
            // n = 1,11
            if (o.f == 0 and (o.i == 1 or o.i == 11)) {
                return .one;
            }
            // n = 2,12
            if (o.f == 0 and (o.i == 2 or o.i == 12)) {
                return .two;
            }
            // n = 3,13
            if (o.f == 0 and (o.i == 3 or o.i == 13)) {
                return .few;
            }
        },
        10 => {
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
            // n = 2,3
            if (o.f == 0 and (o.i == 2 or o.i == 3)) {
                return .two;
            }
            // n = 4
            if (o.f == 0 and o.i == 4) {
                return .few;
            }
            // n = 6
            if (o.f == 0 and o.i == 6) {
                return .many;
            }
        },
        11 => {
            // n = 1,5
            if (o.f == 0 and (o.i == 1 or o.i == 5)) {
                return .one;
            }
        },
        12 => {
            // n = 11,8,80,800
            if (o.f == 0 and (o.i == 11 or o.i == 8 or o.i == 80 or o.i == 800)) {
                return .many;
            }
        },
        13 => {
            // i = 1
            if (o.i == 1) {
                return .one;
            }
            // i = 0 or i % 100 = 2..20,40,60,80
            if (o.i == 0 or (o.i % 100 >= 2 and o.i % 100 <= 20 or o.i % 100 == 40 or o.i % 100 == 60 or o.i % 100 == 80)) {
                return .many;
            }
        },
        14 => {
            // n % 10 = 6 or n % 10 = 9 or n % 10 = 0 and n != 0
            if ((o.f == 0 and o.i % 10 == 6) or (o.f == 0 and o.i % 10 == 9) or (o.f == 0 and o.i % 10 == 0 and !(o.i == 0))) {
                return .many;
            }
        },
        15 => {
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
            // n = 2,3
            if (o.f == 0 and (o.i == 2 or o.i == 3)) {
                return .two;
            }
            // n = 4
            if (o.f == 0 and o.i == 4) {
                return .few;
            }
        },
        16 => {
            // n = 1..4 or n % 100 = 1..4,21..24,41..44,61..64,81..84
            if ((o.f == 0 and (o.i >= 1 and o.i <= 4)) or (o.f == 0 and (o.i % 100 >= 1 and o.i % 100 <= 4 or o.i % 100 >= 21 and o.i % 100 <= 24 or o.i % 100 >= 41 and o.i % 100 <= 44 or o.i % 100 >= 61 and o.i % 100 <= 64 or o.i % 100 >= 81 and o.i % 100 <= 84))) {
                return .one;
            }
            // n = 5 or n % 100 = 5
            if ((o.f == 0 and o.i == 5) or (o.f == 0 and o.i % 100 == 5)) {
                return .many;
            }
        },
        17 => {
            // n = 11,8,80..89,800..899
            if (o.f == 0 and (o.i == 11 or o.i == 8 or o.i >= 80 and o.i <= 89 or o.i >= 800 and o.i <= 899)) {
                return .many;
            }
        },
        18 => {
            // i % 10 = 1 and i % 100 != 11
            if (o.i % 10 == 1 and !(o.i % 100 == 11)) {
                return .one;
            }
            // i % 10 = 2 and i % 100 != 12
            if (o.i % 10 == 2 and !(o.i % 100 == 12)) {
                return .two;
            }
            // i % 10 = 7,8 and i % 100 != 17,18
            if ((o.i % 10 == 7 or o.i % 10 == 8) and !(o.i % 100 == 17 or o.i % 100 == 18)) {
                return .many;
            }
        },
        19 => {
            // n = 1..4
            if (o.f == 0 and (o.i >= 1 and o.i <= 4)) {
                return .one;
            }
        },
        20 => {
            // n = 1,5,7..9
            if (o.f == 0 and (o.i == 1 or o.i == 5 or o.i >= 7 and o.i <= 9)) {
                return .one;
            }
            // n = 2,3
            if (o.f == 0 and (o.i == 2 or o.i == 3)) {
                return .two;
            }
            // n = 4
            if (o.f == 0 and o.i == 4) {
                return .few;
            }
            // n = 6
            if (o.f == 0 and o.i == 6) {
                return .many;
            }
        },
        21 => {
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
            // n % 10 = 4 and n % 100 != 14
            if (o.f == 0 and o.i % 10 == 4 and !(o.i % 100 == 14)) {
                return .many;
            }
        },
        22 => {
            // n % 10 = 1,2 and n % 100 != 11,12
            if (o.f == 0 and (o.i % 10 == 1 or o.i % 10 == 2) and !(o.i % 100 == 11 or o.i % 100 == 12)) {
                return .one;
            }
        },
        23 => {
            // n % 10 = 6,9 or n = 10
            if ((o.f == 0 and (o.i % 10 == 6 or o.i % 10 == 9)) or (o.f == 0 and o.i == 10)) {
                return .few;
            }
        },
        24 => {
            // n % 10 = 3 and n % 100 != 13
            if (o.f == 0 and o.i % 10 == 3 and !(o.i % 100 == 13)) {
                return .few;
            }
        },
        else => {},
    }
    return .other;
}

/// The languages with ordinal rules, sorted, and the rule set of each.
pub const langs = [_][]const u8{
    "af", "am",  "an", "ar",  "as",  "ast", "az",       "bal", "be",  "bg",  "blo", "bn",
    "bs", "ca",  "ce", "cs",  "cv",  "cy",  "da",       "de",  "dsb", "el",  "en",  "es",
    "et", "eu",  "fa", "fi",  "fil", "fr",  "fy",       "ga",  "gd",  "gl",  "gsw", "gu",
    "he", "hi",  "hr", "hsb", "hu",  "hy",  "ia",       "id",  "ie",  "is",  "it",  "ja",
    "ka", "kk",  "km", "kn",  "ko",  "kok", "kok-Latn", "kw",  "ky",  "lij", "lld", "lo",
    "lt", "lv",  "mk", "ml",  "mn",  "mo",  "mr",       "ms",  "my",  "nb",  "ne",  "nl",
    "no", "or",  "pa", "pl",  "prg", "ps",  "pt",       "ro",  "ru",  "sc",  "scn", "sd",
    "sh", "si",  "sk", "sl",  "sq",  "sr",  "sv",       "sw",  "ta",  "te",  "th",  "tk",
    "tl", "tpi", "tr", "uk",  "und", "ur",  "uz",       "vec", "vi",  "yue", "zh",  "zu",
};
pub const rules = [_]u8{
    0, 0, 0, 0,  1,  0,  2,  3,  4,  0, 5,  1, 0,  6,  0, 0,  0,  7, 0, 0, 0,  0,  8, 0,  0,
    0, 0, 0, 3,  3,  0,  3,  9,  0,  0, 10, 0, 10, 0,  0, 11, 3,  0, 0, 0, 0,  12, 0, 13, 14,
    0, 0, 0, 15, 15, 16, 0,  17, 12, 3, 0,  0, 18, 0,  0, 3,  15, 3, 0, 0, 19, 0,  0, 20, 0,
    0, 0, 0, 0,  3,  0,  12, 17, 0,  0, 0,  0, 0,  21, 0, 22, 0,  0, 0, 0, 23, 3,  0, 0,  24,
    0, 0, 0, 12, 3,  0,  0,  0,
};
/// The categories of each rule set, a bit per `Plural`.
pub const categories = [_]u8{
    32, 62, 58, 34, 40, 43, 46, 63, 46, 46, 62, 34, 48, 50, 48, 46, 50, 48,
    54, 34, 62, 50, 34, 40, 40,
};
