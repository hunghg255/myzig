//! Languages: an app's messages in the language of the people who use it,
//! after mygo's package i18n.
//!
//! An app's messages live in catalogs, an ARB file (JSON) per language,
//! embedded at build time and checked at compile time (`Catalog`): a key the
//! catalog lacks, an argument a call leaves out or gives the wrong type, a
//! translation with keys or arguments its source does not have, a message
//! that does not parse, are compile errors. Messages are ICU MessageFormat,
//! whose plural cases follow CLDR's plural rules for every language CLDR has
//! (`cardinalCategory`). The whole app shows one language (`locale`), of
//! its catalogs' the one that suits the user best (`match`), and pages get
//! the same messages (`Page`).
//!
//!     const L = i18n.Catalog(.{ .files = .{ .en = @embedFile("locales/en.json"), .de = @embedFile("locales/de.json") } });
//!     i18n.setLocale(i18n.matchedLanguage(preferred, L.languages));
//!     ui.text(c, .{}, L.t(c, .filesSelected, .{ .count = n }));
//!
//! Numbers and dates are written as ICU and Intl write them, with the data
//! of CLDR (through mygo's tables) for 62 locales and those that fall back
//! to them: separators, grouping, digits, month and weekday names, patterns
//! by style and skeleton, 12 or 24 hours. Nothing here is linked into an
//! app that does not use it; date data only into one that formats dates.
const std = @import("std");

pub const cldr_version = "48.2.0";

const plural = @import("plural.zig");
pub const Plural = plural.Plural;
pub const Operands = plural.Operands;
pub const Categories = plural.Categories;
pub const cardinalCategory = plural.cardinalCategory;
pub const ordinalCategory = plural.ordinalCategory;
pub const cardinalCategories = plural.cardinalCategories;
pub const ordinalCategories = plural.ordinalCategories;

const tag = @import("tag.zig");
pub const Tag = tag.Tag;
pub const normalize = tag.normalize;
pub const parent = tag.parent;
pub const chain = tag.chain;
pub const base = tag.base;
pub const maximize = tag.maximize;
pub const likelyScript = tag.likelyScript;
pub const likelyRegion = tag.likelyRegion;
pub const Direction = tag.Direction;
pub const direction = tag.direction;
pub const isPseudo = tag.isPseudo;
pub const pseudo_accents = tag.pseudo_accents;
pub const pseudo_bidi = tag.pseudo_bidi;

const match_mod = @import("match.zig");
pub const match = match_mod.match;
pub const matchOne = match_mod.matchOne;
pub const fallbacks = match_mod.fallbacks;
pub const Fallbacks = match_mod.Fallbacks;

/// The language of `supported` that suits a reader of `preferred` best,
/// else the first of `supported` (an app's source language), as the app
/// shows it.
pub fn matchedLanguage(preferred: []const []const u8, supported: []const []const u8) []const u8 {
    if (supported.len == 0) return "en";
    return supported[match(preferred, supported) orelse 0];
}

const number = @import("number.zig");
pub const NumberOptions = number.NumberOptions;
pub const formatNumber = number.formatNumber;
pub const bufFormatNumber = number.bufFormatNumber;

pub const date = @import("date.zig");
pub const DateTime = date.DateTime;
pub const DateOptions = date.DateOptions;
pub const Style = date.Style;
pub const Width = date.Width;
pub const formatDate = date.formatDate;
pub const bufFormatDate = date.bufFormatDate;
pub const months = date.months;
pub const weekdays = date.weekdays;
pub const dayPeriods = date.dayPeriods;

const locale_data = @import("locale_data.zig");
pub const firstWeekday = locale_data.firstWeekday;
pub const hourCycle = locale_data.hourCycle;
pub const autonym = locale_data.autonym;

const region = @import("region.zig");
pub const Region = region.Region;
pub const regionFor = region.regionFor;

const catalog = @import("catalog.zig");
pub const Catalog = catalog.Catalog;
pub const Message = catalog.Message;

const fm = @import("format_message.zig");
pub const formatMessage = fm.formatMessage;
pub const bufFormatMessage = fm.bufFormatMessage;

const args = @import("args.zig");
pub const Exact = args.Exact;
pub const exact = args.exact;

const shown = @import("shown.zig");
pub const locale = shown.locale;
pub const setLocale = shown.setLocale;
pub const localeGeneration = shown.localeGeneration;

pub const Page = @import("pages.zig").Page;

/// The message parser, for tools that read messages at compile time.
pub const message = @import("message.zig");

test {
    _ = @import("tests_plural.zig");
    _ = @import("tests_tag.zig");
    _ = @import("tests_format.zig");
    _ = @import("tests_message_cases.zig");
    _ = @import("tests_catalog.zig");
    _ = @import("tests_pages.zig");
}
