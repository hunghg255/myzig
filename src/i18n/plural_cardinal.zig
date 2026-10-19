// Generated from mygo's i18n/tables.go (CLDR 48.2.0) by src/i18n/gen/plurals.py. Do not edit.
//! The cardinal plural rules of CLDR, a branch per distinct rule set.
const plural = @import("plural.zig");
const Plural = plural.Plural;
const Operands = plural.Operands;

/// The category of `o` by the cardinal rules of rule set `r`.
pub fn rule(r: u8, o: *const Operands) Plural {
    switch (r) {
        1 => {
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
        },
        2 => {
            // n = 0..1
            if (o.f == 0 and o.i <= 1) {
                return .one;
            }
        },
        3 => {
            // i = 0 or n = 1
            if (o.i == 0 or (o.f == 0 and o.i == 1)) {
                return .one;
            }
        },
        4 => {
            // n = 0
            if (o.f == 0 and o.i == 0) {
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
            // n % 100 = 3..10
            if (o.f == 0 and (o.i % 100 >= 3 and o.i % 100 <= 10)) {
                return .few;
            }
            // n % 100 = 11..99
            if (o.f == 0 and (o.i % 100 >= 11 and o.i % 100 <= 99)) {
                return .many;
            }
        },
        5 => {
            // i = 1 and v = 0
            if (o.i == 1 and o.v == 0) {
                return .one;
            }
        },
        6 => {
            // n % 10 = 1 and n % 100 != 11
            if (o.f == 0 and o.i % 10 == 1 and !(o.i % 100 == 11)) {
                return .one;
            }
            // n % 10 = 2..4 and n % 100 != 12..14
            if (o.f == 0 and (o.i % 10 >= 2 and o.i % 10 <= 4) and !(o.i % 100 >= 12 and o.i % 100 <= 14)) {
                return .few;
            }
            // n % 10 = 0 or n % 10 = 5..9 or n % 100 = 11..14
            if ((o.f == 0 and o.i % 10 == 0) or (o.f == 0 and (o.i % 10 >= 5 and o.i % 10 <= 9)) or (o.f == 0 and (o.i % 100 >= 11 and o.i % 100 <= 14))) {
                return .many;
            }
        },
        7 => {
            // n = 0
            if (o.f == 0 and o.i == 0) {
                return .zero;
            }
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
        },
        8 => {
            // n % 10 = 1 and n % 100 != 11,71,91
            if (o.f == 0 and o.i % 10 == 1 and !(o.i % 100 == 11 or o.i % 100 == 71 or o.i % 100 == 91)) {
                return .one;
            }
            // n % 10 = 2 and n % 100 != 12,72,92
            if (o.f == 0 and o.i % 10 == 2 and !(o.i % 100 == 12 or o.i % 100 == 72 or o.i % 100 == 92)) {
                return .two;
            }
            // n % 10 = 3..4,9 and n % 100 != 10..19,70..79,90..99
            if (o.f == 0 and (o.i % 10 >= 3 and o.i % 10 <= 4 or o.i % 10 == 9) and !(o.i % 100 >= 10 and o.i % 100 <= 19 or o.i % 100 >= 70 and o.i % 100 <= 79 or o.i % 100 >= 90 and o.i % 100 <= 99)) {
                return .few;
            }
            // n != 0 and n % 1000000 = 0
            if (o.f == 0 and !(o.i == 0) and o.i % 1000000 == 0) {
                return .many;
            }
        },
        9 => {
            // v = 0 and i % 10 = 1 and i % 100 != 11 or f % 10 = 1 and f % 100 != 11
            if ((o.v == 0 and o.i % 10 == 1 and !(o.i % 100 == 11)) or (o.f % 10 == 1 and !(o.f % 100 == 11))) {
                return .one;
            }
            // v = 0 and i % 10 = 2..4 and i % 100 != 12..14 or f % 10 = 2..4 and f % 100 != 12..14
            if ((o.v == 0 and (o.i % 10 >= 2 and o.i % 10 <= 4) and !(o.i % 100 >= 12 and o.i % 100 <= 14)) or ((o.f % 10 >= 2 and o.f % 10 <= 4) and !(o.f % 100 >= 12 and o.f % 100 <= 14))) {
                return .few;
            }
        },
        10 => {
            // i = 1 and v = 0
            if (o.i == 1 and o.v == 0) {
                return .one;
            }
            // e = 0 and i != 0 and i % 1000000 = 0 and v = 0 or e != 0..5
            if ((o.c == 0 and !(o.i == 0) and o.i % 1000000 == 0 and o.v == 0) or !(o.c <= 5)) {
                return .many;
            }
        },
        11 => {
            // v = 0 and i = 1,2,3 or v = 0 and i % 10 != 4,6,9 or v != 0 and f % 10 != 4,6,9
            if ((o.v == 0 and (o.i == 1 or o.i == 2 or o.i == 3)) or (o.v == 0 and !(o.i % 10 == 4 or o.i % 10 == 6 or o.i % 10 == 9)) or (!(o.v == 0) and !(o.f % 10 == 4 or o.f % 10 == 6 or o.f % 10 == 9))) {
                return .one;
            }
        },
        12 => {
            // i = 1 and v = 0
            if (o.i == 1 and o.v == 0) {
                return .one;
            }
            // i = 2..4 and v = 0
            if ((o.i >= 2 and o.i <= 4) and o.v == 0) {
                return .few;
            }
            // v != 0
            if (!(o.v == 0)) {
                return .many;
            }
        },
        13 => {
            // n = 0
            if (o.f == 0 and o.i == 0) {
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
            // n = 3
            if (o.f == 0 and o.i == 3) {
                return .few;
            }
            // n = 6
            if (o.f == 0 and o.i == 6) {
                return .many;
            }
        },
        14 => {
            // n = 1 or t != 0 and i = 0,1
            if ((o.f == 0 and o.i == 1) or (!(o.t == 0) and (o.i == 0 or o.i == 1))) {
                return .one;
            }
        },
        15 => {
            // v = 0 and i % 100 = 1 or f % 100 = 1
            if ((o.v == 0 and o.i % 100 == 1) or o.f % 100 == 1) {
                return .one;
            }
            // v = 0 and i % 100 = 2 or f % 100 = 2
            if ((o.v == 0 and o.i % 100 == 2) or o.f % 100 == 2) {
                return .two;
            }
            // v = 0 and i % 100 = 3..4 or f % 100 = 3..4
            if ((o.v == 0 and (o.i % 100 >= 3 and o.i % 100 <= 4)) or (o.f % 100 >= 3 and o.f % 100 <= 4)) {
                return .few;
            }
        },
        16 => {
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
            // e = 0 and i != 0 and i % 1000000 = 0 and v = 0 or e != 0..5
            if ((o.c == 0 and !(o.i == 0) and o.i % 1000000 == 0 and o.v == 0) or !(o.c <= 5)) {
                return .many;
            }
        },
        17 => {
            // i = 0,1
            if (o.i == 0 or o.i == 1) {
                return .one;
            }
        },
        18 => {
            // i = 0,1
            if (o.i == 0 or o.i == 1) {
                return .one;
            }
            // e = 0 and i != 0 and i % 1000000 = 0 and v = 0 or e != 0..5
            if ((o.c == 0 and !(o.i == 0) and o.i % 1000000 == 0 and o.v == 0) or !(o.c <= 5)) {
                return .many;
            }
        },
        19 => {
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
            // n = 2
            if (o.f == 0 and o.i == 2) {
                return .two;
            }
            // n = 3..6
            if (o.f == 0 and (o.i >= 3 and o.i <= 6)) {
                return .few;
            }
            // n = 7..10
            if (o.f == 0 and (o.i >= 7 and o.i <= 10)) {
                return .many;
            }
        },
        20 => {
            // n = 1,11
            if (o.f == 0 and (o.i == 1 or o.i == 11)) {
                return .one;
            }
            // n = 2,12
            if (o.f == 0 and (o.i == 2 or o.i == 12)) {
                return .two;
            }
            // n = 3..10,13..19
            if (o.f == 0 and (o.i >= 3 and o.i <= 10 or o.i >= 13 and o.i <= 19)) {
                return .few;
            }
        },
        21 => {
            // v = 0 and i % 10 = 1
            if (o.v == 0 and o.i % 10 == 1) {
                return .one;
            }
            // v = 0 and i % 10 = 2
            if (o.v == 0 and o.i % 10 == 2) {
                return .two;
            }
            // v = 0 and i % 100 = 0,20,40,60,80
            if (o.v == 0 and (o.i % 100 == 0 or o.i % 100 == 20 or o.i % 100 == 40 or o.i % 100 == 60 or o.i % 100 == 80)) {
                return .few;
            }
            // v != 0
            if (!(o.v == 0)) {
                return .many;
            }
        },
        22 => {
            // i = 1 and v = 0 or i = 0 and v != 0
            if ((o.i == 1 and o.v == 0) or (o.i == 0 and !(o.v == 0))) {
                return .one;
            }
            // i = 2 and v = 0
            if (o.i == 2 and o.v == 0) {
                return .two;
            }
        },
        23 => {
            // t = 0 and i % 10 = 1 and i % 100 != 11 or t % 10 = 1 and t % 100 != 11
            if ((o.t == 0 and o.i % 10 == 1 and !(o.i % 100 == 11)) or (o.t % 10 == 1 and !(o.t % 100 == 11))) {
                return .one;
            }
        },
        24 => {
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
            // n = 2
            if (o.f == 0 and o.i == 2) {
                return .two;
            }
        },
        25 => {
            // n = 0
            if (o.f == 0 and o.i == 0) {
                return .zero;
            }
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
            // n % 100 = 2,22,42,62,82 or n % 1000 = 0 and n % 100000 = 1000..20000,40000,60000,80000 or n != 0 and n % 1000000 = 100000
            if ((o.f == 0 and (o.i % 100 == 2 or o.i % 100 == 22 or o.i % 100 == 42 or o.i % 100 == 62 or o.i % 100 == 82)) or (o.f == 0 and o.i % 1000 == 0 and (o.i % 100000 >= 1000 and o.i % 100000 <= 20000 or o.i % 100000 == 40000 or o.i % 100000 == 60000 or o.i % 100000 == 80000)) or (o.f == 0 and !(o.i == 0) and o.i % 1000000 == 100000)) {
                return .two;
            }
            // n % 100 = 3,23,43,63,83
            if (o.f == 0 and (o.i % 100 == 3 or o.i % 100 == 23 or o.i % 100 == 43 or o.i % 100 == 63 or o.i % 100 == 83)) {
                return .few;
            }
            // n != 1 and n % 100 = 1,21,41,61,81
            if (o.f == 0 and !(o.i == 1) and (o.i % 100 == 1 or o.i % 100 == 21 or o.i % 100 == 41 or o.i % 100 == 61 or o.i % 100 == 81)) {
                return .many;
            }
        },
        26 => {
            // n = 0
            if (o.f == 0 and o.i == 0) {
                return .zero;
            }
            // i = 0,1 and n != 0
            if ((o.i == 0 or o.i == 1) and !(o.f == 0 and (o.i == 0))) {
                return .one;
            }
        },
        27 => {
            // n % 10 = 1 and n % 100 != 11..19
            if (o.f == 0 and o.i % 10 == 1 and !(o.i % 100 >= 11 and o.i % 100 <= 19)) {
                return .one;
            }
            // n % 10 = 2..9 and n % 100 != 11..19
            if (o.f == 0 and (o.i % 10 >= 2 and o.i % 10 <= 9) and !(o.i % 100 >= 11 and o.i % 100 <= 19)) {
                return .few;
            }
            // f != 0
            if (!(o.f == 0)) {
                return .many;
            }
        },
        28 => {
            // n % 10 = 0 or n % 100 = 11..19 or v = 2 and f % 100 = 11..19
            if ((o.f == 0 and o.i % 10 == 0) or (o.f == 0 and (o.i % 100 >= 11 and o.i % 100 <= 19)) or (o.v == 2 and (o.f % 100 >= 11 and o.f % 100 <= 19))) {
                return .zero;
            }
            // n % 10 = 1 and n % 100 != 11 or v = 2 and f % 10 = 1 and f % 100 != 11 or v != 2 and f % 10 = 1
            if ((o.f == 0 and o.i % 10 == 1 and !(o.i % 100 == 11)) or (o.v == 2 and o.f % 10 == 1 and !(o.f % 100 == 11)) or (!(o.v == 2) and o.f % 10 == 1)) {
                return .one;
            }
        },
        29 => {
            // v = 0 and i % 10 = 1 and i % 100 != 11 or f % 10 = 1 and f % 100 != 11
            if ((o.v == 0 and o.i % 10 == 1 and !(o.i % 100 == 11)) or (o.f % 10 == 1 and !(o.f % 100 == 11))) {
                return .one;
            }
        },
        30 => {
            // i = 1 and v = 0
            if (o.i == 1 and o.v == 0) {
                return .one;
            }
            // v != 0 or n = 0 or n != 1 and n % 100 = 1..19
            if (!(o.v == 0) or (o.f == 0 and o.i == 0) or (o.f == 0 and !(o.i == 1) and (o.i % 100 >= 1 and o.i % 100 <= 19))) {
                return .few;
            }
        },
        31 => {
            // n = 1
            if (o.f == 0 and o.i == 1) {
                return .one;
            }
            // n = 2
            if (o.f == 0 and o.i == 2) {
                return .two;
            }
            // n = 0 or n % 100 = 3..10
            if ((o.f == 0 and o.i == 0) or (o.f == 0 and (o.i % 100 >= 3 and o.i % 100 <= 10))) {
                return .few;
            }
            // n % 100 = 11..19
            if (o.f == 0 and (o.i % 100 >= 11 and o.i % 100 <= 19)) {
                return .many;
            }
        },
        32 => {
            // i = 1 and v = 0
            if (o.i == 1 and o.v == 0) {
                return .one;
            }
            // v = 0 and i % 10 = 2..4 and i % 100 != 12..14
            if (o.v == 0 and (o.i % 10 >= 2 and o.i % 10 <= 4) and !(o.i % 100 >= 12 and o.i % 100 <= 14)) {
                return .few;
            }
            // v = 0 and i != 1 and i % 10 = 0..1 or v = 0 and i % 10 = 5..9 or v = 0 and i % 100 = 12..14
            if ((o.v == 0 and !(o.i == 1) and o.i % 10 <= 1) or (o.v == 0 and (o.i % 10 >= 5 and o.i % 10 <= 9)) or (o.v == 0 and (o.i % 100 >= 12 and o.i % 100 <= 14))) {
                return .many;
            }
        },
        33 => {
            // i = 0..1
            if (o.i <= 1) {
                return .one;
            }
            // e = 0 and i != 0 and i % 1000000 = 0 and v = 0 or e != 0..5
            if ((o.c == 0 and !(o.i == 0) and o.i % 1000000 == 0 and o.v == 0) or !(o.c <= 5)) {
                return .many;
            }
        },
        34 => {
            // v = 0 and i % 10 = 1 and i % 100 != 11
            if (o.v == 0 and o.i % 10 == 1 and !(o.i % 100 == 11)) {
                return .one;
            }
            // v = 0 and i % 10 = 2..4 and i % 100 != 12..14
            if (o.v == 0 and (o.i % 10 >= 2 and o.i % 10 <= 4) and !(o.i % 100 >= 12 and o.i % 100 <= 14)) {
                return .few;
            }
            // v = 0 and i % 10 = 0 or v = 0 and i % 10 = 5..9 or v = 0 and i % 100 = 11..14
            if ((o.v == 0 and o.i % 10 == 0) or (o.v == 0 and (o.i % 10 >= 5 and o.i % 10 <= 9)) or (o.v == 0 and (o.i % 100 >= 11 and o.i % 100 <= 14))) {
                return .many;
            }
        },
        35 => {
            // n % 10 = 1 and n % 100 != 11
            if (o.f == 0 and o.i % 10 == 1 and !(o.i % 100 == 11)) {
                return .one;
            }
            // n = 2
            if (o.f == 0 and o.i == 2) {
                return .two;
            }
            // n != 2 and n % 10 = 2..9 and n % 100 != 11..19
            if (o.f == 0 and !(o.i == 2) and (o.i % 10 >= 2 and o.i % 10 <= 9) and !(o.i % 100 >= 11 and o.i % 100 <= 19)) {
                return .few;
            }
            // f != 0
            if (!(o.f == 0)) {
                return .many;
            }
        },
        36 => {
            // i = 0 or n = 1
            if (o.i == 0 or (o.f == 0 and o.i == 1)) {
                return .one;
            }
            // n = 2..10
            if (o.f == 0 and (o.i >= 2 and o.i <= 10)) {
                return .few;
            }
        },
        37 => {
            // n = 0,1 or i = 0 and f = 1
            if ((o.f == 0 and (o.i == 0 or o.i == 1)) or (o.i == 0 and o.f == 1)) {
                return .one;
            }
        },
        38 => {
            // v = 0 and i % 100 = 1
            if (o.v == 0 and o.i % 100 == 1) {
                return .one;
            }
            // v = 0 and i % 100 = 2
            if (o.v == 0 and o.i % 100 == 2) {
                return .two;
            }
            // v = 0 and i % 100 = 3..4 or v != 0
            if ((o.v == 0 and (o.i % 100 >= 3 and o.i % 100 <= 4)) or !(o.v == 0)) {
                return .few;
            }
        },
        39 => {
            // n = 0..1 or n = 11..99
            if ((o.f == 0 and o.i <= 1) or (o.f == 0 and (o.i >= 11 and o.i <= 99))) {
                return .one;
            }
        },
        else => {},
    }
    return .other;
}

/// The languages with cardinal rules, sorted, and the rule set of each.
pub const langs = [_][]const u8{
    "af",  "ak",  "am",  "an",  "ar",  "ars", "as",  "asa", "ast",   "az",  "bal",
    "be",  "bem", "bez", "bg",  "bho", "blo", "bm",  "bn",  "bo",    "br",  "brx",
    "bs",  "ca",  "ce",  "ceb", "cgg", "chr", "ckb", "cs",  "csw",   "cv",  "cy",
    "da",  "de",  "doi", "dsb", "dv",  "dz",  "ee",  "el",  "en",    "eo",  "es",
    "et",  "eu",  "fa",  "ff",  "fi",  "fil", "fo",  "fr",  "fur",   "fy",  "ga",
    "gd",  "gl",  "gsw", "gu",  "guw", "gv",  "ha",  "haw", "he",    "hi",  "hnj",
    "hr",  "hsb", "hu",  "hy",  "ia",  "id",  "ie",  "ig",  "ii",    "io",  "is",
    "it",  "iu",  "ja",  "jbo", "jgo", "jmc", "jv",  "jw",  "ka",    "kab", "kaj",
    "kcg", "kde", "kea", "kk",  "kkj", "kl",  "km",  "kn",  "ko",    "kok", "kok-Latn",
    "ks",  "ksb", "ksh", "ku",  "kw",  "ky",  "lag", "lb",  "lg",    "lij", "lkt",
    "lld", "ln",  "lo",  "lt",  "lv",  "mas", "mg",  "mgo", "mk",    "ml",  "mn",
    "mo",  "mr",  "ms",  "mt",  "my",  "nah", "naq", "nb",  "nd",    "ne",  "nl",
    "nn",  "nnh", "no",  "nqo", "nr",  "nso", "ny",  "nyn", "om",    "or",  "os",
    "osa", "pa",  "pap", "pcm", "pl",  "prg", "ps",  "pt",  "pt-PT", "rm",  "ro",
    "rof", "ru",  "rwk", "sah", "saq", "sat", "sc",  "scn", "sd",    "sdh", "se",
    "seh", "ses", "sg",  "sgs", "sh",  "shi", "si",  "sk",  "sl",    "sma", "smi",
    "smj", "smn", "sms", "sn",  "so",  "sq",  "sr",  "ss",  "ssy",   "st",  "su",
    "sv",  "sw",  "syr", "ta",  "te",  "teo", "th",  "ti",  "tig",   "tk",  "tl",
    "tn",  "to",  "tpi", "tr",  "ts",  "tzm", "ug",  "uk",  "und",   "ur",  "uz",
    "ve",  "vec", "vi",  "vo",  "vun", "wa",  "wae", "wo",  "xh",    "xog", "yi",
    "yo",  "yue", "zh",  "zu",
};
pub const rules = [_]u8{
    1,  2,  3,  1,  4,  4,  3,  1,  5,  1,  1,  6,  1,  1,  1,  2,  7, 0,  3,  0,  8,  1,  9,  10,
    1,  11, 1,  1,  1,  12, 2,  7,  13, 14, 5,  3,  15, 1,  0,  1,  1, 5,  1,  16, 5,  1,  3,  17,
    5,  11, 1,  18, 1,  5,  19, 20, 5,  1,  3,  2,  21, 1,  1,  22, 3, 0,  9,  15, 1,  17, 5,  0,
    5,  0,  0,  5,  23, 10, 24, 0,  0,  1,  1,  0,  0,  1,  17, 1,  1, 0,  0,  1,  1,  1,  0,  3,
    0,  3,  3,  1,  1,  7,  1,  25, 1,  26, 1,  1,  5,  0,  10, 2,  0, 27, 28, 1,  2,  1,  29, 1,
    1,  30, 1,  0,  31, 0,  1,  24, 1,  1,  1,  5,  1,  1,  1,  0,  1, 2,  1,  1,  1,  1,  1,  0,
    2,  1,  3,  32, 28, 1,  33, 10, 1,  30, 1,  34, 1,  0,  1,  24, 5, 10, 1,  1,  24, 1,  0,  0,
    35, 9,  36, 37, 12, 38, 24, 24, 24, 24, 24, 1,  1,  1,  9,  1,  1, 1,  0,  5,  5,  1,  1,  1,
    1,  0,  2,  1,  1,  11, 1,  0,  0,  1,  1,  39, 1,  34, 0,  5,  1, 1,  10, 0,  1,  1,  2,  1,
    0,  1,  1,  5,  0,  0,  0,  3,
};
/// The categories of each rule set, a bit per `Plural`.
pub const categories = [_]u8{
    32, 34, 34, 34, 63, 34, 58, 35, 62, 42, 50, 34, 58, 63, 34, 46, 50, 34,
    50, 62, 46, 62, 38, 34, 38, 63, 35, 58, 35, 34, 42, 62, 58, 50, 58, 62,
    42, 34, 46, 34,
};
