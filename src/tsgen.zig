//! TypeScript declarations and the JavaScript client, generated at comptime
//! from bound services and events. Zig keeps no parameter names in function
//! types, so a service may name them: `pub const myzig_params = .{ .greet = .{"name"} };`
const std = @import("std");

/// A named type declaration (`interface X {...}` or `type X = ...`), deduped
/// by name across services.
pub const Decl = struct { name: []const u8, source: []const u8 };

pub fn shortName(comptime T: type) []const u8 {
    if (@hasDecl(T, "myzig_name")) return T.myzig_name;
    const full = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// True for the methods a service exposes: public functions whose first
/// parameter is the service itself, but its lifecycle (`init`, `deinit`)
/// and the names its `myzig_skip` lists (`pub const myzig_skip = .{"reset"};`).
/// Functions taking no service (constructors, helpers) are never exposed.
pub fn isMethod(comptime T: type, comptime name: []const u8) bool {
    if (std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "deinit")) return false;
    if (@hasDecl(T, "myzig_skip")) for (T.myzig_skip) |skip| {
        if (std.mem.eql(u8, skip, name)) return false;
    };
    const F = @TypeOf(@field(T, name));
    const info = @typeInfo(F);
    if (info != .@"fn") return false;
    const f = info.@"fn";
    if (f.is_generic or f.param_types.len == 0 or name[0] == '_') return false;
    const P = f.param_types[0] orelse return false;
    return P == T or P == *T or P == *const T;
}

pub fn methodNames(comptime T: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(T).@"struct".decl_names) |name| {
            if (isMethod(T, name)) names = names ++ .{name};
        }
        return names;
    }
}

fn isCallParam(comptime P: type) bool {
    if (@typeInfo(P) != .pointer) return false;
    const C = @typeInfo(P).pointer.child;
    return switch (@typeInfo(C)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(C, "myzig_call_context"),
        else => false,
    };
}

fn paramName(comptime T: type, comptime method: []const u8, comptime i: usize) []const u8 {
    if (@hasDecl(T, "myzig_params") and @hasField(@TypeOf(T.myzig_params), method)) {
        const names = @field(T.myzig_params, method);
        if (i < names.len) return names[i];
    }
    return std.fmt.comptimePrint("arg{d}", .{i});
}

/// The TypeScript type of `T`, appending the declarations it needs to `decls`.
pub fn tsType(comptime T: type, comptime decls: *[]const Decl) []const u8 {
    comptime {
        if (T == std.json.Value) return "unknown";
        switch (@typeInfo(T)) {
            .void, .null => return "void",
            .bool => return "boolean",
            .int, .float, .comptime_int, .comptime_float => return "number",
            .optional => |o| return tsType(o.child, decls) ++ " | null",
            .error_union => |e| return tsType(e.payload, decls),
            .array => |a| return if (a.child == u8) "string" else arrayOf(tsType(a.child, decls)),
            .pointer => |p| switch (p.size) {
                .slice => return if (p.child == u8) "string" else arrayOf(tsType(p.child, decls)),
                .one => {
                    if (@typeInfo(p.child) == .array) return tsType(p.child, decls);
                    return tsType(p.child, decls);
                },
                else => @compileError("myzig: unsupported pointer type " ++ @typeName(T)),
            },
            .@"enum" => |e| {
                const name = shortName(T);
                if (!hasDecl(decls.*, name)) {
                    var src: []const u8 = "export type " ++ name ++ " =";
                    for (e.field_names, 0..) |f, i| src = src ++ (if (i == 0) " " else " | ") ++ "\"" ++ f ++ "\"";
                    decls.* = decls.* ++ .{Decl{ .name = name, .source = src ++ ";" }};
                }
                return name;
            },
            .@"struct" => |s| {
                if (s.is_tuple) @compileError("myzig: tuples are not supported: " ++ @typeName(T));
                if (@hasDecl(T, "myzig_channel")) return "Channel<" ++ tsType(T.myzig_channel, decls) ++ ">";
                const name = shortName(T);
                if (!hasDecl(decls.*, name)) {
                    // Reserve the name first so recursive types terminate.
                    const index = decls.len;
                    decls.* = decls.* ++ .{Decl{ .name = name, .source = "" }};
                    var src: []const u8 = "export interface " ++ name ++ " {\n";
                    for (s.field_names, s.field_types) |f, FT| {
                        const optional = @typeInfo(FT) == .optional;
                        src = src ++ "  " ++ f ++ (if (optional) "?" else "") ++ ": " ++ tsType(FT, decls) ++ ";\n";
                    }
                    var copy = decls.*[0..decls.len].*;
                    copy[index].source = src ++ "}";
                    decls.* = &copy;
                }
                return name;
            },
            else => @compileError("myzig: unsupported type " ++ @typeName(T)),
        }
    }
}

fn arrayOf(comptime t: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, t, ' ') != null) "(" ++ t ++ ")[]" else t ++ "[]";
}

fn hasDecl(decls: []const Decl, name: []const u8) bool {
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return true;
    return false;
}

pub const Service = struct {
    /// `export declare const Name: {...};`
    dts: []const u8,
    /// `export const Name = ...;`
    js: []const u8,
    decls: []const Decl,
};

pub fn service(comptime T: type) Service {
    comptime {
        @setEvalBranchQuota(100_000);
        var decls: []const Decl = &.{};
        const name = shortName(T);
        var dts: []const u8 = "export declare const " ++ name ++ ": {\n";
        var js: []const u8 = "export const " ++ name ++ " = Object.freeze({\n";
        for (methodNames(T)) |m| {
            const f = @typeInfo(@TypeOf(@field(T, m))).@"fn";
            var params: []const u8 = "";
            var n = 0;
            for (f.param_types[1..]) |P| {
                if (isCallParam(P.?)) continue;
                params = params ++ (if (n > 0) ", " else "") ++ paramName(T, m, n) ++ ": " ++ tsType(P.?, &decls);
                n += 1;
            }
            dts = dts ++ "  " ++ m ++ "(" ++ params ++ "): Promise<" ++ tsType(f.return_type.?, &decls) ++ ">;\n";
            js = js ++ "  " ++ m ++ ": (...a) => window.myzig.call(\"" ++ name ++ "." ++ m ++ "\", ...a),\n";
        }
        const d = decls[0..decls.len].*;
        return .{ .dts = dts ++ "};\n", .js = js ++ "});\n", .decls = &d };
    }
}

pub fn event(comptime name: []const u8, comptime T: type) Service {
    comptime {
        @setEvalBranchQuota(100_000);
        var decls: []const Decl = &.{};
        const fn_name = "on" ++ pascal(name);
        const ty = tsType(T, &decls);
        const d = decls[0..decls.len].*;
        return .{
            .dts = "export declare function " ++ fn_name ++ "(listener: (payload: " ++ ty ++ ") => void): () => void;\n",
            .js = "export const " ++ fn_name ++ " = (fn) => window.myzig.on(\"" ++ name ++ "\", fn);\n",
            .decls = &d,
        };
    }
}

/// A kind of channel Zig opens to pages: `onLogsChannel(fn)` for "logs".
pub fn channelKind(comptime name: []const u8, comptime T: type) Service {
    comptime {
        @setEvalBranchQuota(100_000);
        var decls: []const Decl = &.{};
        const fn_name = "on" ++ pascal(name) ++ "Channel";
        const ty = tsType(T, &decls);
        const d = decls[0..decls.len].*;
        return .{
            .dts = "export declare function " ++ fn_name ++ "(listener: (channel: Channel<" ++ ty ++ ">) => void): () => void;\n",
            .js = "export const " ++ fn_name ++ " = (fn) => window.myzig.onChannel(\"" ++ name ++ "\", fn);\n",
            .decls = &d,
        };
    }
}

fn pascal(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = true;
        for (s) |c| {
            if (c == '-' or c == '_' or c == ':' or c == '.') {
                upper = true;
                continue;
            }
            out = out ++ .{if (upper) std.ascii.toUpper(c) else c};
            upper = false;
        }
        return out;
    }
}

pub const runtime_dts =
    \\// Generated by myzig. Do not edit.
    \\/** A stream of values between Zig and the page, both ways, until either closes it. */
    \\export interface Channel<T> extends AsyncIterable<T> {
    \\  /** Gets each value from Zig; values wait for it (or the iteration) to take them. */
    \\  onmessage: ((value: T) => void) | null;
    \\  onclose: (() => void) | null;
    \\  readonly closed: boolean;
    \\  /** Sends a value to Zig; resolves once Zig has room for more. */
    \\  send(value: T): Promise<void>;
    \\  close(): void;
    \\}
    \\/** Makes a channel to pass to a bound method taking `myzig.Channel(T)`. */
    \\export declare const Channel: new <T>(onmessage?: (value: T) => void) => Channel<T>;
    \\export declare const myzig: {
    \\  call(method: string, ...args: unknown[]): Promise<unknown>;
    \\  on(event: string, listener: (payload: unknown) => void): () => void;
    \\  once(event: string, listener: (payload: unknown) => void): () => void;
    \\  onChannel(kind: string, listener: (channel: Channel<unknown>) => void): () => void;
    \\  log(...values: unknown[]): void;
    \\  window: { close(): void; minimize(): void; toggleMaximize(): void; setTitle(title: string): void };
    \\  platform: "macos" | "linux" | "windows";
    \\  version: string;
    \\};
    \\
;

pub const runtime_js =
    \\// Generated by myzig. Do not edit.
    \\export const myzig = window.myzig;
    \\export const Channel = window.myzig.Channel;
    \\
;

test "types" {
    const Todo = struct { id: u32, title: []const u8, done: bool, note: ?[]const u8 };
    comptime var decls: []const Decl = &.{};
    try std.testing.expectEqualStrings("Todo[]", comptime tsType([]const Todo, &decls));
    try std.testing.expectEqualStrings("(string | null)[]", comptime tsType([]const ?[]const u8, &decls));
    try std.testing.expectEqualStrings(
        "export interface Todo {\n  id: number;\n  title: string;\n  done: boolean;\n  note?: string | null;\n}",
        decls[0].source,
    );
}

test "lifecycle, helpers without the service and skipped names are not exposed" {
    const Store = struct {
        items: u32 = 0,
        pub const myzig_skip = .{"reset"};
        pub fn init(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
        pub fn create() @This() {
            return .{};
        }
        pub fn helper(_: u32) u32 {
            return 0;
        }
        pub fn reset(s: *@This()) void {
            s.items = 0;
        }
        pub fn count(s: *const @This()) u32 {
            return s.items;
        }
    };
    const names = comptime methodNames(Store);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("count", names[0]);
    const svc = comptime service(Store);
    try std.testing.expect(std.mem.indexOf(u8, svc.dts, "count(") != null);
    for ([_][]const u8{ "init(", "deinit(", "create(", "helper(", "reset(" }) |hidden| {
        try std.testing.expect(std.mem.indexOf(u8, svc.dts, hidden) == null);
        try std.testing.expect(std.mem.indexOf(u8, svc.js, hidden) == null);
    }
}

test "channels" {
    const Line = struct { text: []const u8 };
    const Chan = struct {
        pub const myzig_channel = Line;
    };
    comptime var decls: []const Decl = &.{};
    try std.testing.expectEqualStrings("Channel<Line>", comptime tsType(Chan, &decls));
    try std.testing.expectEqualStrings("export interface Line {\n  text: string;\n}", decls[0].source);
    const Shell = struct {
        pub const myzig_params = .{ .tail = .{ "command", "lines" } };
        pub fn tail(_: *@This(), _: []const u8, _: Chan) void {}
    };
    const svc = comptime service(Shell);
    try std.testing.expect(std.mem.indexOf(u8, svc.dts, "tail(command: string, lines: Channel<Line>): Promise<void>;") != null);
    const kind = comptime channelKind("build-logs", Line);
    try std.testing.expectEqualStrings("export declare function onBuildLogsChannel(listener: (channel: Channel<Line>) => void): () => void;\n", kind.dts);
    try std.testing.expectEqualStrings("export const onBuildLogsChannel = (fn) => window.myzig.onChannel(\"build-logs\", fn);\n", kind.js);
}
