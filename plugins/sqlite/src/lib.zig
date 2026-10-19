//! The system's SQLite, loaded when the first database opens: no C code,
//! nothing linked. macOS ships /usr/lib/libsqlite3.dylib, Linux
//! distributions libsqlite3.so.0, and Windows 10 and later
//! winsqlite3.dll. `MYZIG_SQLITE_LIBRARY` names another build.
const std = @import("std");
const builtin = @import("builtin");

/// winsqlite3.dll is built with `__stdcall`, as are the callbacks it
/// calls; elsewhere (and on x86_64 Windows, where the two are one) C's.
pub const cc: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const Handle = opaque {};
pub const Stmt = opaque {};
/// A destructor for bound text and blobs, as an address: myzig only
/// passes SQLITE_TRANSIENT (-1, not aligned as a function's), with which
/// SQLite copies them before the call returns.
pub const Destructor = isize;
pub const transient: Destructor = -1;
pub const Authorizer = *const fn (ctx: ?*anyopaque, action: c_int, a: ?[*:0]const u8, b: ?[*:0]const u8, c: ?[*:0]const u8, d: ?[*:0]const u8) callconv(cc) c_int;

/// The functions myzig calls, looked up by name.
pub const Api = struct {
    sqlite3_libversion: *const fn () callconv(cc) [*:0]const u8,
    sqlite3_open_v2: *const fn (path: [*:0]const u8, db: *?*Handle, flags: c_int, vfs: ?[*:0]const u8) callconv(cc) c_int,
    sqlite3_close_v2: *const fn (db: *Handle) callconv(cc) c_int,
    sqlite3_extended_result_codes: *const fn (db: *Handle, on: c_int) callconv(cc) c_int,
    sqlite3_extended_errcode: *const fn (db: *Handle) callconv(cc) c_int,
    sqlite3_errmsg: *const fn (db: *Handle) callconv(cc) [*:0]const u8,
    sqlite3_errstr: *const fn (code: c_int) callconv(cc) [*:0]const u8,
    sqlite3_busy_timeout: *const fn (db: *Handle, ms: c_int) callconv(cc) c_int,
    sqlite3_interrupt: *const fn (db: *Handle) callconv(cc) void,
    sqlite3_set_authorizer: *const fn (db: *Handle, cb: ?Authorizer, ctx: ?*anyopaque) callconv(cc) c_int,
    sqlite3_prepare_v2: *const fn (db: *Handle, sql: [*]const u8, len: c_int, stmt: *?*Stmt, tail: *?[*]const u8) callconv(cc) c_int,
    sqlite3_finalize: *const fn (stmt: *Stmt) callconv(cc) c_int,
    sqlite3_reset: *const fn (stmt: *Stmt) callconv(cc) c_int,
    sqlite3_clear_bindings: *const fn (stmt: *Stmt) callconv(cc) c_int,
    sqlite3_step: *const fn (stmt: *Stmt) callconv(cc) c_int,
    sqlite3_bind_parameter_count: *const fn (stmt: *Stmt) callconv(cc) c_int,
    sqlite3_bind_parameter_index: *const fn (stmt: *Stmt, name: [*:0]const u8) callconv(cc) c_int,
    sqlite3_bind_null: *const fn (stmt: *Stmt, i: c_int) callconv(cc) c_int,
    sqlite3_bind_int64: *const fn (stmt: *Stmt, i: c_int, v: i64) callconv(cc) c_int,
    sqlite3_bind_double: *const fn (stmt: *Stmt, i: c_int, v: f64) callconv(cc) c_int,
    sqlite3_bind_text: *const fn (stmt: *Stmt, i: c_int, v: [*]const u8, n: c_int, d: Destructor) callconv(cc) c_int,
    sqlite3_bind_blob: *const fn (stmt: *Stmt, i: c_int, v: ?*const anyopaque, n: c_int, d: Destructor) callconv(cc) c_int,
    sqlite3_bind_zeroblob: *const fn (stmt: *Stmt, i: c_int, n: c_int) callconv(cc) c_int,
    sqlite3_column_count: *const fn (stmt: *Stmt) callconv(cc) c_int,
    sqlite3_column_name: *const fn (stmt: *Stmt, i: c_int) callconv(cc) ?[*:0]const u8,
    sqlite3_column_type: *const fn (stmt: *Stmt, i: c_int) callconv(cc) c_int,
    sqlite3_column_int64: *const fn (stmt: *Stmt, i: c_int) callconv(cc) i64,
    sqlite3_column_double: *const fn (stmt: *Stmt, i: c_int) callconv(cc) f64,
    sqlite3_column_text: *const fn (stmt: *Stmt, i: c_int) callconv(cc) ?[*]const u8,
    sqlite3_column_blob: *const fn (stmt: *Stmt, i: c_int) callconv(cc) ?[*]const u8,
    sqlite3_column_bytes: *const fn (stmt: *Stmt, i: c_int) callconv(cc) c_int,
    sqlite3_changes: *const fn (db: *Handle) callconv(cc) c_int,
    sqlite3_total_changes: *const fn (db: *Handle) callconv(cc) c_int,
    sqlite3_last_insert_rowid: *const fn (db: *Handle) callconv(cc) i64,
    sqlite3_get_autocommit: *const fn (db: *Handle) callconv(cc) c_int,
    sqlite3_exec: *const fn (db: *Handle, sql: [*:0]const u8, cb: ?*const anyopaque, ctx: ?*anyopaque, err: ?*?[*:0]u8) callconv(cc) c_int,
};

var api: Api = undefined;
var state: std.atomic.Value(u8) = .init(0); // 0 not loaded, 1 loading, 2 loaded, 3 failed
var loaded_from: []const u8 = "";

const candidates: []const [:0]const u8 = switch (builtin.os.tag) {
    .windows => &.{ "winsqlite3.dll", "sqlite3.dll" },
    .macos => &.{ "/usr/lib/libsqlite3.dylib", "libsqlite3.dylib" },
    else => &.{ "libsqlite3.so.0", "libsqlite3.so" },
};

/// Loads the library once; safe from any thread.
pub fn load() !*const Api {
    while (true) switch (state.load(.acquire)) {
        2 => return &api,
        3 => return error.SqliteMissing,
        0 => if (state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            const ok = loadOnce();
            state.store(if (ok) 2 else 3, .release);
        },
        else => std.atomic.spinLoopHint(),
    };
}

/// The library that was loaded, for diagnostics.
pub fn path() []const u8 {
    return loaded_from;
}

fn loadOnce() bool {
    var custom: [512:0]u8 = undefined;
    if (envLibrary(&custom)) |p| return loadFrom(p);
    for (candidates) |name| if (loadFrom(name)) return true;
    return false;
}

fn loadFrom(name: [:0]const u8) bool {
    const lib = dl.open(name) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |f| {
        const sym = dl.sym(lib, f) orelse return false;
        @field(api, f) = @ptrCast(@alignCast(sym));
    }
    loaded_from = name;
    return true;
}

fn envLibrary(buf: *[512:0]u8) ?[:0]const u8 {
    if (builtin.os.tag == .windows) {
        var wide: [512]u16 = undefined;
        const n = dl.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("MYZIG_SQLITE_LIBRARY"), &wide, wide.len);
        if (n == 0 or n >= wide.len) return null;
        const len = std.unicode.utf16LeToUtf8(buf, wide[0..n]) catch return null;
        if (len >= buf.len) return null;
        buf[len] = 0;
        return buf[0..len :0];
    }
    const v = std.c.getenv("MYZIG_SQLITE_LIBRARY") orelse return null;
    const s = std.mem.span(v);
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

const dl = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(lib: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;

    fn open(name: [:0]const u8) ?*anyopaque {
        var wide: [512:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, name) catch return null;
        wide[n] = 0;
        return LoadLibraryW(wide[0..n :0]);
    }

    fn sym(lib: *anyopaque, name: [:0]const u8) ?*anyopaque {
        return GetProcAddress(lib, name);
    }
} else struct {
    fn open(name: [:0]const u8) ?*anyopaque {
        return std.c.dlopen(name, .{ .NOW = true });
    }

    fn sym(lib: *anyopaque, name: [:0]const u8) ?*anyopaque {
        return std.c.dlsym(lib, name);
    }
};
