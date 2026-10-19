//! SQLite for myzig apps: the system's library, loaded at run time (see
//! lib.zig), with prepared statements, typed binding, rows read into Zig
//! structs, and transactions. Pages use it through `Service`.
//!
//!     var db = try sqlite.Db.open("notes.db", .{});
//!     defer db.close();
//!     _ = try db.exec("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT)", .{});
//!     _ = try db.exec("INSERT INTO notes(title) VALUES (?)", .{"Hello"});
//!     const notes = try db.all(Note, arena, "SELECT id, title FROM notes", .{});
const std = @import("std");
pub const lib = @import("lib.zig");
const values = @import("values.zig");
pub const Value = values.Value;
pub const Rows = values.Rows;
pub const Service = @import("service.zig").Service;
pub const ServiceOptions = @import("service.zig").Options;

/// The page's client, an ES module: add it to a page's assets and
/// `import { open } from "/plugins/sqlite.js"`.
pub const client_js = @embedFile("js/sqlite.js");
pub const asset: @import("myzig").Asset = .{ .path = "/plugins/sqlite.js", .data = client_js };

pub const OpenOptions = struct {
    read_only: bool = false,
    /// How long a statement waits for another connection's lock, in
    /// milliseconds; 0 fails at once.
    busy_timeout_ms: u31 = 5000,
    /// Refuses SQL that controls transactions (BEGIN, COMMIT, SAVEPOINT…:
    /// use `transaction`), attaches files (ATTACH, DETACH, VACUUM INTO) or
    /// loads extensions: for SQL that pages send.
    guarded: bool = false,
};

/// What an INSERT, UPDATE or DELETE did.
pub const Result = struct {
    /// Rows the statement changed itself (0 for other statements).
    changes: i64,
    /// The rowid of the connection's last insert.
    last_insert_id: i64,
};

/// The last error of a call that returned `error.Sqlite`.
pub const Diagnostics = struct {
    /// SQLite's extended result code; `code & 0xff` is the primary one.
    code: c_int = 0,
    message: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn text(d: *const Diagnostics) []const u8 {
        return d.message[0..d.message_len];
    }

    fn set(d: *Diagnostics, code: c_int, msg: []const u8) void {
        d.code = code;
        d.message_len = @min(msg.len, d.message.len);
        @memcpy(d.message[0..d.message_len], msg[0..d.message_len]);
    }
};

pub const Error = error{
    /// SQLite failed: `Db.diagnostics` says why.
    Sqlite,
    SqliteMissing,
    InvalidSql,
    /// The SQL holds more than one statement (use `execScript`).
    MultipleStatements,
    EmptyStatement,
    /// Refused on a guarded connection.
    StatementNotAllowed,
    WrongParameterCount,
    NonFiniteNumber,
    TextNotUtf8,
    TooLarge,
    Interrupted,
    Busy,
    Constraint,
    OutOfMemory,
    /// A row's column cannot become the struct field's type.
    ColumnType,
    NoSuchColumn,
};

/// A connection. Use it from one thread at a time; `interrupt` is safe
/// from any thread.
pub const Db = struct {
    api: *const lib.Api,
    handle: *lib.Handle,
    guarded: bool,
    /// Lets the plugin's own BEGIN, COMMIT and ROLLBACK through the guard.
    control: bool = false,
    diagnostics: Diagnostics = .{},

    /// Opens (or creates, unless read-only) the database file at `path`,
    /// or ":memory:" for a private one in memory.
    pub fn open(path: []const u8, options: OpenOptions) Error!Db {
        const api = lib.load() catch return error.SqliteMissing;
        if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidSql;
        var buf: [4097]u8 = undefined;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        // READWRITE | CREATE, or READONLY; FULLMUTEX either way.
        const flags: c_int = if (options.read_only) 0x1 | 0x10000 else 0x2 | 0x4 | 0x10000;
        var h: ?*lib.Handle = null;
        const rc = api.sqlite3_open_v2(buf[0..path.len :0], &h, flags, null);
        const handle = h orelse return error.OutOfMemory;
        var db: Db = .{ .api = api, .handle = handle, .guarded = options.guarded };
        if (rc != 0) {
            const err = db.fail(rc);
            _ = api.sqlite3_close_v2(handle);
            return err;
        }
        _ = api.sqlite3_extended_result_codes(handle, 1);
        _ = api.sqlite3_busy_timeout(handle, options.busy_timeout_ms);
        return db;
    }

    /// Closes the connection; statements still open close with it.
    pub fn close(db: *Db) void {
        _ = db.api.sqlite3_close_v2(db.handle);
        db.* = undefined;
    }

    /// Makes the running statement fail with `error.Interrupted`, from any thread.
    pub fn interrupt(db: *Db) void {
        db.api.sqlite3_interrupt(db.handle);
    }

    /// Compiles one statement; trailing semicolons and comments may follow.
    pub fn prepare(db: *Db, sql: []const u8) Error!Statement {
        if (sql.len > std.math.maxInt(c_int) or std.mem.indexOfScalar(u8, sql, 0) != null or !std.unicode.utf8ValidateSlice(sql)) return error.InvalidSql;
        if (db.guarded and !db.control) {
            if (vacuumInto(sql)) return error.StatementNotAllowed;
            _ = db.api.sqlite3_set_authorizer(db.handle, guard, null);
        }
        defer if (db.guarded and !db.control) {
            _ = db.api.sqlite3_set_authorizer(db.handle, null, null);
        };
        var stmt: ?*lib.Stmt = null;
        var tail: ?[*]const u8 = null;
        const rc = db.api.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, &tail);
        if (rc != 0) {
            if (stmt) |s| _ = db.api.sqlite3_finalize(s);
            // SQLITE_AUTH: the guard said no.
            if (rc == 23) return error.StatementNotAllowed;
            return db.fail(rc);
        }
        const s = stmt orelse return error.EmptyStatement;
        const rest = sql[@intFromPtr(tail.?) - @intFromPtr(sql.ptr) ..];
        if (!onlyCommentsOrSemicolons(rest)) {
            _ = db.api.sqlite3_finalize(s);
            return error.MultipleStatements;
        }
        return .{ .db = db, .stmt = s };
    }

    /// Runs one statement with `args` (a tuple, bound to ?1, ?2…), reading
    /// past any rows it returns.
    pub fn exec(db: *Db, sql: []const u8, args: anytype) Error!Result {
        var st = try db.prepare(sql);
        defer st.finalize();
        try st.bindAll(args);
        return st.run();
    }

    /// `exec` with dynamic values, as pages send them.
    pub fn execValues(db: *Db, sql: []const u8, args: []const Value) Error!Result {
        var st = try db.prepare(sql);
        defer st.finalize();
        try st.bindValues(args);
        return st.run();
    }

    /// A query's columns and rows of dynamic values, copied with `gpa`
    /// (an arena suits it).
    pub fn query(db: *Db, gpa: std.mem.Allocator, sql: []const u8, args: []const Value) Error!Rows {
        var st = try db.prepare(sql);
        defer st.finalize();
        try st.bindValues(args);
        const n = st.columnCount();
        const columns = try gpa.alloc([]const u8, n);
        for (columns, 0..) |*c, i| c.* = try gpa.dupe(u8, st.columnName(i));
        var rows: std.ArrayList([]const Value) = .empty;
        while (try st.step()) {
            const row = try gpa.alloc(Value, n);
            for (row, 0..) |*v, i| v.* = try st.value(gpa, i);
            try rows.append(gpa, row);
        }
        return .{ .columns = columns, .rows = try rows.toOwnedSlice(gpa) };
    }

    /// Runs SQL of any number of statements without parameters, such as a
    /// schema. Not on guarded connections.
    pub fn execScript(db: *Db, sql: []const u8) Error!void {
        if (db.guarded) return error.StatementNotAllowed;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(std.heap.page_allocator);
        try buf.appendSlice(std.heap.page_allocator, sql);
        try buf.append(std.heap.page_allocator, 0);
        const rc = db.api.sqlite3_exec(db.handle, buf.items[0..sql.len :0], null, null, null);
        if (rc != 0) return db.fail(rc);
    }

    /// Every row of a query, each read into a `T` (by column name:
    /// see `Statement.read`), allocated with `gpa` (text and blobs too).
    pub fn all(db: *Db, comptime T: type, gpa: std.mem.Allocator, sql: []const u8, args: anytype) Error![]T {
        var st = try db.prepare(sql);
        defer st.finalize();
        try st.bindAll(args);
        var out: std.ArrayList(T) = .empty;
        errdefer out.deinit(gpa);
        while (try st.step()) try out.append(gpa, try st.read(T, gpa));
        return out.toOwnedSlice(gpa);
    }

    /// The first row of a query, or null when it has none.
    pub fn one(db: *Db, comptime T: type, gpa: std.mem.Allocator, sql: []const u8, args: anytype) Error!?T {
        var st = try db.prepare(sql);
        defer st.finalize();
        try st.bindAll(args);
        if (!try st.step()) return null;
        return try st.read(T, gpa);
    }

    /// Runs `body(db, ctx)` in a transaction (BEGIN IMMEDIATE): committed
    /// when it returns, rolled back when it fails.
    pub fn transaction(db: *Db, ctx: anytype, comptime body: fn (*Db, @TypeOf(ctx)) anyerror!void) anyerror!void {
        try db.begin();
        body(db, ctx) catch |err| {
            db.rollback();
            return err;
        };
        db.commit() catch |err| {
            db.rollback();
            return err;
        };
    }

    pub fn begin(db: *Db) Error!void {
        try db.controlStatement("BEGIN IMMEDIATE");
    }

    pub fn commit(db: *Db) Error!void {
        try db.controlStatement("COMMIT");
    }

    /// Rolls back the open transaction, if there is one.
    pub fn rollback(db: *Db) void {
        if (db.api.sqlite3_get_autocommit(db.handle) != 0) return;
        db.controlStatement("ROLLBACK") catch {};
    }

    pub fn inTransaction(db: *Db) bool {
        return db.api.sqlite3_get_autocommit(db.handle) == 0;
    }

    fn controlStatement(db: *Db, sql: []const u8) Error!void {
        db.control = true;
        defer db.control = false;
        _ = try db.exec(sql, .{});
    }

    /// Records SQLite's error and turns `rc` into a Zig error.
    pub fn fail(db: *Db, rc: c_int) Error {
        const code = db.api.sqlite3_extended_errcode(db.handle);
        db.diagnostics.set(if (code != 0) code else rc, std.mem.span(db.api.sqlite3_errmsg(db.handle)));
        return switch (rc & 0xff) {
            9 => error.Interrupted,
            5, 6 => error.Busy,
            19 => error.Constraint,
            7 => error.OutOfMemory,
            18 => error.TooLarge,
            else => error.Sqlite,
        };
    }
};

/// A compiled statement: bind, step through its rows, read them.
pub const Statement = struct {
    db: *Db,
    stmt: *lib.Stmt,

    pub fn finalize(st: *Statement) void {
        _ = st.db.api.sqlite3_finalize(st.stmt);
    }

    /// Makes it ready to run again, keeping its bindings.
    pub fn reset(st: *Statement) void {
        _ = st.db.api.sqlite3_reset(st.stmt);
    }

    pub fn parameterCount(st: *Statement) usize {
        return @intCast(st.db.api.sqlite3_bind_parameter_count(st.stmt));
    }

    /// Binds a tuple to parameters 1, 2…: it must give every parameter.
    pub fn bindAll(st: *Statement, args: anytype) Error!void {
        const fields = @typeInfo(@TypeOf(args)).@"struct".field_names;
        if (fields.len != st.parameterCount()) return error.WrongParameterCount;
        inline for (fields, 1..) |f, i| try st.bind(i, @field(args, f));
    }

    /// Binds dynamic values to parameters 1, 2…: it must give every parameter.
    pub fn bindValues(st: *Statement, args: []const Value) Error!void {
        if (args.len != st.parameterCount()) return error.WrongParameterCount;
        for (args, 1..) |v, i| try st.bind(i, v);
    }

    /// Binds one value (1-based): null, bools (0 or 1), integers, floats,
    /// text ([]const u8, string literals), `Value`s, optionals of these,
    /// and `sqlite.blob(bytes)`.
    pub fn bind(st: *Statement, index: usize, v: anytype) Error!void {
        const api = st.db.api;
        const i: c_int = @intCast(index);
        const T = @TypeOf(v);
        const rc: c_int = switch (@typeInfo(T)) {
            .null => api.sqlite3_bind_null(st.stmt, i),
            .optional => return if (v) |some| st.bind(index, some) else st.bind(index, null),
            .bool => api.sqlite3_bind_int64(st.stmt, i, @intFromBool(v)),
            .int, .comptime_int => blk: {
                const n = std.math.cast(i64, v) orelse return error.TooLarge;
                break :blk api.sqlite3_bind_int64(st.stmt, i, n);
            },
            .float, .comptime_float => blk: {
                const f: f64 = v;
                if (!std.math.isFinite(f)) return error.NonFiniteNumber;
                break :blk api.sqlite3_bind_double(st.stmt, i, f);
            },
            .@"enum" => return st.bind(index, @tagName(v)),
            else => if (T == Value) switch (v) {
                .null => return st.bind(index, null),
                .integer => |n| return st.bind(index, n),
                .real => |f| return st.bind(index, f),
                .text => |s| return st.bind(index, s),
                .blob => |b| return st.bind(index, Blob{ .bytes = b }),
            } else if (T == Blob) blk: {
                const n = std.math.cast(c_int, v.bytes.len) orelse return error.TooLarge;
                // An empty blob, not NULL.
                if (n == 0) break :blk api.sqlite3_bind_zeroblob(st.stmt, i, 0);
                break :blk api.sqlite3_bind_blob(st.stmt, i, v.bytes.ptr, n, lib.transient);
            } else blk: {
                const s: []const u8 = v;
                if (!std.unicode.utf8ValidateSlice(s)) return error.TextNotUtf8;
                const n = std.math.cast(c_int, s.len) orelse return error.TooLarge;
                break :blk api.sqlite3_bind_text(st.stmt, i, s.ptr, n, lib.transient);
            },
        };
        if (rc != 0) return st.db.fail(rc);
    }

    /// Advances to the next row: false when there are no more.
    pub fn step(st: *Statement) Error!bool {
        const rc = st.db.api.sqlite3_step(st.stmt);
        return switch (rc) {
            100 => true,
            101 => false,
            else => st.db.fail(rc),
        };
    }

    /// Steps to the end, as for statements that change rows.
    pub fn run(st: *Statement) Error!Result {
        const api = st.db.api;
        const before = api.sqlite3_total_changes(st.db.handle);
        while (try st.step()) {}
        const changed = api.sqlite3_total_changes(st.db.handle) != before;
        return .{
            .changes = if (changed) api.sqlite3_changes(st.db.handle) else 0,
            .last_insert_id = api.sqlite3_last_insert_rowid(st.db.handle),
        };
    }

    pub fn columnCount(st: *Statement) usize {
        return @intCast(st.db.api.sqlite3_column_count(st.stmt));
    }

    pub fn columnName(st: *Statement, i: usize) []const u8 {
        const p = st.db.api.sqlite3_column_name(st.stmt, @intCast(i)) orelse return "";
        return std.mem.span(p);
    }

    pub fn isNull(st: *Statement, i: usize) bool {
        return st.db.api.sqlite3_column_type(st.stmt, @intCast(i)) == 5;
    }

    pub fn int(st: *Statement, i: usize) i64 {
        return st.db.api.sqlite3_column_int64(st.stmt, @intCast(i));
    }

    pub fn float(st: *Statement, i: usize) f64 {
        return st.db.api.sqlite3_column_double(st.stmt, @intCast(i));
    }

    /// The column as text, valid until the next step: copy it to keep it.
    pub fn text(st: *Statement, i: usize) []const u8 {
        const api = st.db.api;
        const p = api.sqlite3_column_text(st.stmt, @intCast(i)) orelse return "";
        return p[0..@intCast(api.sqlite3_column_bytes(st.stmt, @intCast(i)))];
    }

    /// The column as bytes, valid until the next step.
    pub fn bytes(st: *Statement, i: usize) []const u8 {
        const api = st.db.api;
        const p = api.sqlite3_column_blob(st.stmt, @intCast(i)) orelse return "";
        return p[0..@intCast(api.sqlite3_column_bytes(st.stmt, @intCast(i)))];
    }

    /// The column as a dynamic value, text and blobs copied with `gpa`.
    pub fn value(st: *Statement, gpa: std.mem.Allocator, i: usize) Error!Value {
        return switch (st.db.api.sqlite3_column_type(st.stmt, @intCast(i))) {
            1 => .{ .integer = st.int(i) },
            2 => .{ .real = st.float(i) },
            3 => .{ .text = try gpa.dupe(u8, st.text(i)) },
            4 => .{ .blob = try gpa.dupe(u8, st.bytes(i)) },
            else => .null,
        };
    }

    /// The row as a `T`: each field from the column of its name. Fields
    /// may be integers, floats, bools, enums (from text), []const u8 (text
    /// or blob, copied with `gpa`), `Value`, and optionals (NULL) of these;
    /// fields with defaults may have no column, or NULL in it.
    pub fn read(st: *Statement, comptime T: type, gpa: std.mem.Allocator) Error!T {
        const info = @typeInfo(T).@"struct";
        var out: T = undefined;
        const n = st.columnCount();
        inline for (info.field_names, info.field_types, 0..) |f, FT, fi| {
            const col: ?usize = for (0..n) |i| {
                if (std.mem.eql(u8, st.columnName(i), f)) break i;
            } else null;
            const default = info.field_attrs[fi].default_value_ptr;
            if (col != null and default != null and @typeInfo(FT) != .optional and st.isNull(col.?)) {
                // NULL into a field that has a default: the default.
                @field(out, f) = @as(*const FT, @ptrCast(@alignCast(default.?))).*;
            } else if (col) |i| {
                @field(out, f) = try st.cell(FT, gpa, i);
            } else if (info.field_attrs[fi].default_value_ptr) |d| {
                @field(out, f) = @as(*const FT, @ptrCast(@alignCast(d))).*;
            } else return error.NoSuchColumn;
        }
        return out;
    }

    fn cell(st: *Statement, comptime F: type, gpa: std.mem.Allocator, i: usize) Error!F {
        if (F == Value) return st.value(gpa, i);
        switch (@typeInfo(F)) {
            .optional => |o| return if (st.isNull(i)) null else try st.cell(o.child, gpa, i),
            else => {},
        }
        if (st.isNull(i)) return error.ColumnType;
        return switch (@typeInfo(F)) {
            .int => std.math.cast(F, st.int(i)) orelse error.ColumnType,
            .float => @floatCast(st.float(i)),
            .bool => st.int(i) != 0,
            .@"enum" => std.meta.stringToEnum(F, st.text(i)) orelse error.ColumnType,
            .pointer => |p| if (p.size == .slice and p.child == u8)
                try gpa.dupe(u8, if (st.db.api.sqlite3_column_type(st.stmt, @intCast(i)) == 4) st.bytes(i) else st.text(i))
            else
                @compileError("sqlite: unsupported field type " ++ @typeName(F)),
            else => @compileError("sqlite: unsupported field type " ++ @typeName(F)),
        };
    }
};

/// Bytes bound as a BLOB rather than TEXT.
pub const Blob = struct { bytes: []const u8 };

pub fn blob(bytes: []const u8) Blob {
    return .{ .bytes = bytes };
}

/// SQLite's authorizer for guarded connections.
fn guard(_: ?*anyopaque, action: c_int, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8) callconv(lib.cc) c_int {
    return switch (action) {
        // TRANSACTION, ATTACH, DETACH, SAVEPOINT: SQLITE_DENY.
        22, 24, 25, 32 => 1,
        else => 0,
    };
}

/// Skips whitespace and SQL comments.
fn skip(sql: []const u8, start: usize) usize {
    var i = start;
    while (i < sql.len) {
        if (std.ascii.isWhitespace(sql[i])) {
            i += 1;
        } else if (std.mem.startsWith(u8, sql[i..], "--")) {
            i = std.mem.indexOfScalarPos(u8, sql, i, '\n') orelse sql.len;
        } else if (std.mem.startsWith(u8, sql[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, sql, i + 2, "*/")) |e| e + 2 else sql.len;
        } else break;
    }
    return i;
}

fn onlyCommentsOrSemicolons(sql: []const u8) bool {
    var i = skip(sql, 0);
    while (i < sql.len and sql[i] == ';') i = skip(sql, i + 1);
    return i == sql.len;
}

/// VACUUM INTO writes a file of SQL's choosing; the authorizer cannot see it.
fn vacuumInto(sql: []const u8) bool {
    var i = skip(sql, 0);
    if (!startsWithWord(sql[i..], "vacuum")) return false;
    i += 6;
    while (i < sql.len) {
        i = skip(sql, i);
        if (i >= sql.len or sql[i] == ';') return false;
        if (startsWithWord(sql[i..], "into")) return true;
        // A schema name, maybe quoted.
        if (sql[i] == '"' or sql[i] == '`' or sql[i] == '[' or sql[i] == '\'') {
            const close: u8 = if (sql[i] == '[') ']' else sql[i];
            i = (std.mem.indexOfScalarPos(u8, sql, i + 1, close) orelse return true) + 1;
        } else {
            while (i < sql.len and (std.ascii.isAlphanumeric(sql[i]) or sql[i] == '_')) i += 1;
            if (i < sql.len and !std.ascii.isWhitespace(sql[i]) and sql[i] != ';' and sql[i] != '-' and sql[i] != '/') return true;
        }
    }
    return false;
}

fn startsWithWord(s: []const u8, word: []const u8) bool {
    if (s.len < word.len or !std.ascii.eqlIgnoreCase(s[0..word.len], word)) return false;
    return s.len == word.len or !(std.ascii.isAlphanumeric(s[word.len]) or s[word.len] == '_');
}

test {
    _ = @import("tests.zig");
    _ = @import("service.zig");
    _ = values;
}
