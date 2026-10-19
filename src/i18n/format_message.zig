//! A message of the app's own, outside catalogs: written at compile time,
//! formatted with the values of its arguments. Its arguments take any value
//! their use allows: a number where it is counted, a DateTime where it is a
//! date, a string, an enum, a bool or a number elsewhere.
//!
//!     try i18n.formatMessage(w, "de", "{n, plural, one {# Datei} other {# Dateien}}", .{ .n = 1000 });
const std = @import("std");
const msg = @import("message.zig");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const data = @import("locale_data.zig");
const pseudo = @import("pseudo.zig");
const catalog = @import("catalog.zig");
const Writer = std.Io.Writer;

fn nodesOf(comptime message: []const u8) []const msg.Node {
    return switch (msg.parse(message)) {
        .ok => |n| n,
        .err => |e| @compileError(std.fmt.comptimePrint("i18n: the message \"{s}\" does not parse at byte {d}: {s}", .{ message, e.offset, e.why })),
    };
}

/// Writes `message` with `args` (a struct of a field per argument) in
/// `locale`: its plural rules, numbers and dates. The pseudo locales
/// transform it, with English's plural rules.
pub fn formatMessage(w: *Writer, locale: []const u8, comptime message: []const u8, args: anytype) Writer.Error!void {
    const parsed = comptime nodesOf(message);
    const uses = comptime msg.args(parsed);
    const A = @TypeOf(args);
    const params = comptime blk: {
        var out: [uses.len]catalog.Param = undefined;
        for (uses, 0..) |u, i| out[i] = .{ .name = u.name, .type = switch (u.use) {
            .plural, .number => .number,
            .date => .date_time,
            .plain, .select => .object,
        } };
        break :blk out;
    };
    inline for (params) |p| if (!@hasField(A, p.name)) @compileError("i18n: the message needs the argument " ++ p.name);
    inline for (@typeInfo(A).@"struct".field_names) |f| {
        if (comptime catalog.paramIndex(&params, f) == null) @compileError("i18n: the message has no argument " ++ f);
    }
    var values: [params.len]render.Value = undefined;
    inline for (params, 0..) |p, i| {
        const V = @TypeOf(@field(args, p.name));
        if (comptime args_mod.mismatch(p.type, V)) |why| @compileError("i18n: the argument " ++ p.name ++ " " ++ why);
        values[i] = args_mod.value(@field(args, p.name));
    }
    const nodes = comptime catalog.indexArgs(parsed, &params);
    const method = pseudo.methodOf(locale);
    const lang = if (method != .none) "en" else locale;
    var ctx: render.Ctx = .{
        .locale = lang,
        .key = data.keyOf(lang),
        .plural_lang = lang,
        .values = &values,
        .pseudo = method,
        .dates = comptime if (hasDates(&params)) &@import("render_dates.zig").write else null,
    };
    try pseudo.begin(w, method);
    try render.write(w, &ctx, nodes);
    try pseudo.end(w, method, ctx.letters);
}

pub fn bufFormatMessage(buf: []u8, locale: []const u8, comptime message: []const u8, args: anytype) Writer.Error![]u8 {
    var w: Writer = .fixed(buf);
    try formatMessage(&w, locale, message, args);
    return w.buffered();
}

fn hasDates(comptime params: []const catalog.Param) bool {
    for (params) |p| if (p.type == .date_time or p.type == .object) return true;
    return false;
}
