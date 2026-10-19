//! A catalog's messages for pages: a part of the generated client
//! (`myzig.js`, `myzig.d.ts`) with a typed function per key, which says the
//! message in the page's language with the browser's Intl, by the same
//! messages, cases and fallbacks as Zig. The messages are in the client,
//! so the first paint is in the right language.
//!
//!     try app.registerEvent(i18n.Page(L)); // adds `messages` to the client
//!
//!     import { messages, messagesIn, languages, onLocaleChange } from "./myzig.js";
//!     heading.textContent = messages.filesSelected(3);
//!     messagesIn("de").greeting("Ada"); // "Hallo, Ada!"
const std = @import("std");
const msg = @import("message.zig");
const tsgen = @import("../tsgen.zig");
const tag = @import("tag.zig");
const date = @import("date.zig");

/// A type whose `client` is the part of the client of catalog `L`, as
/// `App.registerEvent` takes it.
pub fn Page(comptime L: type) type {
    return struct {
        pub const client: tsgen.Service = .{ .dts = dts(L), .js = js(L), .decls = &.{} };
    };
}

fn jsString(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            out = out ++ switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0...8, 11, 12, 14...0x1f, 0x7f => std.fmt.comptimePrint("\\x{x:0>2}", .{c}),
                else => blk: {
                    // U+2028 and U+2029 end lines in old JavaScript.
                    if (c == 0xe2 and i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xa8 or s[i + 2] == 0xa9)) {
                        i += 2;
                        break :blk if (s[i] == 0xa8) "\\u2028" else "\\u2029";
                    }
                    break :blk &[_]u8{c};
                },
            };
        }
        return out ++ "\"";
    }
}

/// The options of Intl.DateTimeFormat for a skeleton of `date.skeletons`.
fn skeletonOptions(comptime skel: []const u8) []const u8 {
    const table = .{
        .{ "yMd", "{year:'numeric',month:'numeric',day:'numeric'}" },
        .{ "yMMMd", "{year:'numeric',month:'short',day:'numeric'}" },
        .{ "yMMMMd", "{year:'numeric',month:'long',day:'numeric'}" },
        .{ "yMMMEd", "{year:'numeric',month:'short',day:'numeric',weekday:'short'}" },
        .{ "yMMMMEEEEd", "{year:'numeric',month:'long',day:'numeric',weekday:'long'}" },
        .{ "yM", "{year:'numeric',month:'numeric'}" },
        .{ "yMMM", "{year:'numeric',month:'short'}" },
        .{ "yMMMM", "{year:'numeric',month:'long'}" },
        .{ "y", "{year:'numeric'}" },
        .{ "Md", "{month:'numeric',day:'numeric'}" },
        .{ "MMMd", "{month:'short',day:'numeric'}" },
        .{ "MMMMd", "{month:'long',day:'numeric'}" },
        .{ "MEd", "{month:'numeric',day:'numeric',weekday:'short'}" },
        .{ "MMMEd", "{month:'short',day:'numeric',weekday:'short'}" },
        .{ "Ed", "{day:'numeric',weekday:'short'}" },
        .{ "d", "{day:'numeric'}" },
        .{ "MMM", "{month:'short'}" },
        .{ "LLLL", "{month:'long'}" },
        .{ "E", "{weekday:'short'}" },
        .{ "EEEE", "{weekday:'long'}" },
        .{ "jm", "{hour:'numeric',minute:'2-digit'}" },
        .{ "jms", "{hour:'numeric',minute:'2-digit',second:'2-digit'}" },
        .{ "Hm", "{hour:'2-digit',minute:'2-digit',hourCycle:'h23'}" },
        .{ "Hms", "{hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}" },
        .{ "hm", "{hour:'numeric',minute:'2-digit',hourCycle:'h12'}" },
        .{ "hms", "{hour:'numeric',minute:'2-digit',second:'2-digit',hourCycle:'h12'}" },
    };
    inline for (table) |e| if (comptime std.mem.eql(u8, e[0], skel)) return e[1];
    @compileError("i18n: no Intl options for the skeleton " ++ skel);
}

/// A message as the page's interpreter reads it: a string, or an array
/// of parts: strings, and [kind, ...] for arguments.
fn nodesJs(comptime nodes: []const msg.Node) []const u8 {
    comptime {
        if (msg.plainText(nodes)) |p| return jsString(p);
        var out: []const u8 = "[";
        for (nodes, 0..) |n, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ switch (n) {
                .text => |t| jsString(t),
                .pound => "[1]",
                .arg => |a| switch (a.kind) {
                    .plain => std.fmt.comptimePrint("[0,{d}]", .{a.index}),
                    .number => std.fmt.comptimePrint("[2,{d},{s}]", .{ a.index, numberOptions(a.number) }),
                    .date, .time => std.fmt.comptimePrint("[3,{d},{s}]", .{ a.index, dateOptions(a) }),
                },
                .choice => |c| blk: {
                    var cases: []const u8 = "[";
                    for (c.cases, 0..) |cs, j| {
                        const key = switch (cs.key) {
                            .exact => |e| "=" ++ e,
                            .category => |p| @tagName(p),
                            .word => |w| w,
                        };
                        cases = cases ++ (if (j > 0) "," else "") ++ "[" ++ jsString(key) ++ "," ++ nodesJs(cs.nodes) ++ "]";
                    }
                    cases = cases ++ "]";
                    break :blk switch (c.kind) {
                        .select => std.fmt.comptimePrint("[5,{d},{s}]", .{ c.index, cases }),
                        else => std.fmt.comptimePrint("[4,{d},{d},{d},{s}]", .{ c.index, @intFromBool(c.kind == .selectordinal), c.offset, cases }),
                    };
                },
            };
        }
        return out ++ "]";
    }
}

fn numberOptions(comptime n: msg.NumberStyle) []const u8 {
    comptime {
        var o: []const u8 = "{";
        if (n.percent) o = o ++ "style:'percent',";
        if (n.integer) o = o ++ "maximumFractionDigits:0,roundingMode:'halfEven',";
        if (!n.grouping) o = o ++ "useGrouping:false,";
        if (n.max_fraction) |m| o = o ++ std.fmt.comptimePrint("minimumFractionDigits:{d},maximumFractionDigits:{d},", .{ n.min_fraction orelse 0, m });
        return o ++ "}";
    }
}

fn dateOptions(comptime a: msg.Arg) []const u8 {
    if (a.date.skeleton.len > 0) return skeletonOptions(a.date.skeleton);
    const style = @tagName(a.date.style);
    return if (a.kind == .time) "{timeStyle:'" ++ style ++ "'}" else "{dateStyle:'" ++ style ++ "'}";
}

fn js(comptime L: type) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var langs: []const u8 = "[";
        var chains: []const u8 = "[";
        for (L.languages, 0..) |l, i| {
            const sep = if (i > 0) "," else "";
            langs = langs ++ sep ++ jsString(l);
            // The catalog's languages a language falls back to, then the source.
            var ch: []const u8 = "[";
            const c = tag.chain(l);
            var n = 0;
            for (c.items()) |*p| for (L.languages, 0..) |o, j| if (p.eql(o)) {
                ch = ch ++ (if (n > 0) "," else "") ++ std.fmt.comptimePrint("{d}", .{j});
                n += 1;
            };
            if (i != 0) ch = ch ++ ",0";
            chains = chains ++ sep ++ ch ++ "]";
        }
        var keys: []const u8 = "{";
        for (L.keys, 0..) |k, ki| {
            var row: []const u8 = "[";
            for (L.messages[ki], 0..) |m, li| row = row ++ (if (li > 0) "," else "") ++ (if (m) |x| nodesJs(x.nodes) else "null");
            keys = keys ++ (if (ki > 0) ",\n" else "\n") ++ "  " ++ k ++ ":" ++ row ++ "]";
        }
        return "export const languages = Object.freeze(" ++ langs ++ "]);\n" ++
            "const __i18n = " ++ "{ chains: " ++ chains ++ "], messages: " ++ keys ++ "\n} };\n" ++ runtime;
    }
}

fn dts(comptime L: type) []const u8 {
    comptime {
        var fns: []const u8 = "";
        for (L.keys, L.arguments) |k, ps| {
            var params: []const u8 = "";
            for (ps, 0..) |p, i| params = params ++ (if (i > 0) ", " else "") ++ p.name ++ ": " ++ p.type.ts();
            fns = fns ++ "  " ++ k ++ "(" ++ params ++ "): string;\n";
        }
        return "export declare const languages: readonly string[];\n" ++
            "export interface Messages {\n" ++ fns ++ "}\n" ++
            "/** The messages in the page's language: the app's, else the browser's. */\n" ++
            "export declare const messages: Messages;\n" ++
            "export declare function messagesIn(locale: string): Messages;\n" ++
            "export declare function onLocaleChange(listener: (locale: string) => void): () => void;\n";
    }
}

/// The interpreter of the messages, over the browser's Intl.
const runtime =
    \\const __locale = () => (window.myzig && window.myzig.locale) || document.documentElement.lang || navigator.language;
    \\const __pick = (locale) => {
    \\  let want;
    \\  try { want = new Intl.Locale(locale).maximize(); } catch { return __i18n.chains[0]; }
    \\  let best = -1, score = 9;
    \\  languages.forEach((l, i) => {
    \\    const have = new Intl.Locale(l), m = have.maximize();
    \\    if (m.language !== want.language || m.script !== want.script) return;
    \\    const s = have.baseName === want.baseName || l === locale ? 0 : m.region === want.region ? 1 : !have.region ? 2 : 3;
    \\    if (s < score) { best = i; score = s; }
    \\  });
    \\  return best < 0 ? __i18n.chains[0] : __i18n.chains[best];
    \\};
    \\const __num = (locale, n, o) => new Intl.NumberFormat(locale, o).format(n);
    \\const __write = (locale, lang, parts, args, pound) => {
    \\  if (typeof parts === "string") return parts;
    \\  let s = "";
    \\  for (const p of parts) {
    \\    if (typeof p === "string") { s += p; continue; }
    \\    const v = args[p[1]];
    \\    switch (p[0]) {
    \\      case 0: s += typeof v === "number" ? __num(locale, v) : v instanceof Date ? new Intl.DateTimeFormat(locale, { dateStyle: "short", timeStyle: "short" }).format(v) : String(v); break;
    \\      case 1: s += pound === undefined ? "#" : __num(locale, pound); break;
    \\      case 2: s += __num(locale, v, p[2]); break;
    \\      case 3: s += new Intl.DateTimeFormat(locale, p[2]).format(v); break;
    \\      case 4: {
    \\        const cases = new Map(p[4]);
    \\        const exact = cases.get("=" + v);
    \\        const shown = v - p[3];
    \\        const cat = new Intl.PluralRules(lang, { type: p[2] ? "ordinal" : "cardinal" }).select(Number(__num("en", shown, { useGrouping: false })));
    \\        s += __write(locale, lang, exact !== undefined ? exact : cases.has(cat) ? cases.get(cat) : cases.get("other"), args, shown);
    \\        break;
    \\      }
    \\      case 5: { const cases = new Map(p[2]); const c = cases.get(String(v)); s += __write(locale, lang, c !== undefined ? c : cases.get("other"), args, pound); break; }
    \\    }
    \\  }
    \\  return s;
    \\};
    \\export const messagesIn = (locale) => {
    \\  const chain = __pick(locale);
    \\  return new Proxy({}, { get: (_, key) => (...args) => {
    \\    const row = __i18n.messages[key];
    \\    if (!row) return String(key);
    \\    for (const i of chain) if (row[i] !== null) return __write(locale, languages[i], row[i], args);
    \\    return __write(locale, languages[0], row[0], args);
    \\  } });
    \\};
    \\export const messages = new Proxy({}, { get: (_, key) => messagesIn(__locale())[key] });
    \\export const onLocaleChange = (fn) => window.myzig.on("myzig:locale", fn);
    \\
;
