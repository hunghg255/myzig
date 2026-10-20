//! The service pages call (`js/sqlite.js` wraps it): databases opened by
//! file name in the app's data directory, guarded SQL, parameters and
//! cells in their wire form (values.zig). Each connection belongs to the
//! page that opened it, and closes when that page navigates, reloads or
//! closes (`myzig_pageGone`).
//!
//!     var db_service: sqlite.Service = .init(gpa, .{});
//!     defer db_service.deinit();
//!     try app.bind(&db_service);
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const sqlite = @import("sqlite.zig");
const values = @import("values.zig");

pub const Options = struct {
    /// Where pages' databases live; the app's data directory when null.
    directory: ?[]const u8 = null,
    busy_timeout_ms: u31 = 5000,
};

pub const OpenArgs = struct { readOnly: bool = false };

pub const ExecResult = struct {
    changes: i64,
    /// A decimal string: rowids reach past JavaScript's safe integers.
    lastInsertId: []const u8,
};

pub const StatementArgs = struct {
    sql: []const u8,
    params: []const std.json.Value = &.{},
};

const Conn = struct {
    id: u64,
    window: *myzig.Window,
    /// The page that opened it (`myzig.Call.page`).
    page: ?*anyopaque,
    db: sqlite.Db,
};

pub const Service = struct {
    pub const myzig_name = "Sqlite";
    pub const myzig_params = .{
        .open = .{ "name", "options" },
        .execute = .{ "id", "sql", "params" },
        .query = .{ "id", "sql", "params" },
        .transaction = .{ "id", "statements" },
        .close = .{"id"},
    };

    gpa: std.mem.Allocator,
    options: Options,
    conns: std.ArrayList(Conn) = .empty,
    next_id: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, options: Options) Service {
        return .{ .gpa = gpa, .options = options };
    }

    /// Closes every connection still open.
    pub fn deinit(s: *Service) void {
        for (s.conns.items) |*c| c.db.close();
        s.conns.deinit(s.gpa);
    }

    /// Opens `name` (a file name in the directory, or ":memory:") and
    /// returns the connection's id.
    pub fn open(s: *Service, call: *myzig.Call, name: []const u8, options: OpenArgs) ![]const u8 {
        s.sweep(call.window.app);
        var path: []const u8 = name;
        if (!std.mem.eql(u8, name, ":memory:")) {
            try checkName(name);
            const io = call.window.app.io;
            const dir = s.options.directory orelse try myzig.path(call.arena, .data, call.window.app.options.name);
            if (!options.readOnly) try std.Io.Dir.cwd().createDirPath(io, dir);
            path = try std.fs.path.join(call.arena, &.{ dir, name });
            if (std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |st| {
                if (st.kind == .sym_link) return error.SymbolicLink;
            } else |_| {}
        }
        var db = try sqlite.Db.open(path, .{ .read_only = options.readOnly, .busy_timeout_ms = s.options.busy_timeout_ms, .guarded = true });
        errdefer db.close();
        const id = s.next_id;
        s.next_id += 1;
        try s.conns.append(s.gpa, .{ .id = id, .window = call.window, .page = call.page, .db = db });
        return std.fmt.allocPrint(call.arena, "{d}", .{id});
    }

    /// Runs one statement and returns what it changed.
    pub fn execute(s: *Service, call: *myzig.Call, id: []const u8, sql: []const u8, params: []const std.json.Value) !ExecResult {
        const db = try s.conn(call, id);
        const args = try values.paramsFromJson(call.arena, params);
        return wire(call.arena, try withMessage(db, db.execValues(sql, args)));
    }

    /// Runs one query and returns its columns and rows.
    pub fn query(s: *Service, call: *myzig.Call, id: []const u8, sql: []const u8, params: []const std.json.Value) !values.WireRows {
        const db = try s.conn(call, id);
        const args = try values.paramsFromJson(call.arena, params);
        const rows = try withMessage(db, db.query(call.arena, sql, args));
        return values.rowsToWire(call.arena, rows);
    }

    /// Runs statements in one transaction: all of them, or none.
    pub fn transaction(s: *Service, call: *myzig.Call, id: []const u8, statements: []const StatementArgs) ![]const ExecResult {
        const db = try s.conn(call, id);
        const out = try call.arena.alloc(ExecResult, statements.len);
        if (statements.len == 0) return out;
        try withMessage(db, db.begin());
        errdefer db.rollback();
        for (statements, out) |st, *r| {
            const args = try values.paramsFromJson(call.arena, st.params);
            r.* = try wire(call.arena, try withMessage(db, db.execValues(st.sql, args)));
        }
        try withMessage(db, db.commit());
        return out;
    }

    /// Closes a connection; closing it again does nothing.
    pub fn close(s: *Service, call: *myzig.Call, id: []const u8) void {
        const n = std.fmt.parseInt(u64, id, 10) catch return;
        for (s.conns.items, 0..) |*c, i| if (c.id == n and c.window == call.window) {
            c.db.close();
            _ = s.conns.swapRemove(i);
            return;
        };
    }

    fn conn(s: *Service, call: *myzig.Call, id: []const u8) !*sqlite.Db {
        s.sweep(call.window.app);
        const n = std.fmt.parseInt(u64, id, 10) catch return error.DatabaseClosed;
        for (s.conns.items) |*c| if (c.id == n and c.window == call.window) return &c.db;
        // Closed, or another window's.
        return error.DatabaseClosed;
    }

    /// The page that opened databases is gone (it navigated, reloaded or
    /// closed): they close, as a new document opens its own.
    pub fn myzig_pageGone(s: *Service, window: *myzig.Window, page: *anyopaque) void {
        var i: usize = 0;
        while (i < s.conns.items.len) {
            const c = &s.conns.items[i];
            if (c.window == window and c.page == page) {
                c.db.close();
                _ = s.conns.swapRemove(i);
            } else i += 1;
        }
    }

    /// Closes the connections of windows that closed.
    fn sweep(s: *Service, app: *myzig.App) void {
        var i: usize = 0;
        while (i < s.conns.items.len) {
            const c = &s.conns.items[i];
            const live = for (app.windows.items) |w| {
                if (w == c.window) break true;
            } else false;
            if (live) {
                i += 1;
            } else {
                c.db.close();
                _ = s.conns.swapRemove(i);
            }
        }
    }
};

fn wire(arena: std.mem.Allocator, r: sqlite.Result) !ExecResult {
    return .{ .changes = r.changes, .lastInsertId = try std.fmt.allocPrint(arena, "{d}", .{r.last_insert_id}) };
}

/// Logs SQLite's message with its error: pages see the error's name.
fn withMessage(db: *sqlite.Db, result: anytype) @TypeOf(result) {
    return result catch |err| {
        if (err == error.Sqlite or err == error.Constraint or err == error.Busy)
            std.log.warn("sqlite: {s} (code {d})", .{ db.diagnostics.text(), db.diagnostics.code });
        return err;
    };
}

/// A file name, not a path: nothing that leaves the directory or that
/// Windows reserves.
pub fn checkName(name: []const u8) !void {
    const bad = name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfAny(u8, name, "/\\\x00:<>\"|?*") != null or
        !std.mem.eql(u8, std.mem.trim(u8, name, " \t\r\n"), name) or name[name.len - 1] == '.';
    if (bad) return error.InvalidDatabaseName;
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    var up: [8]u8 = undefined;
    if (stem.len > up.len) return;
    const u = std.ascii.upperString(&up, stem);
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |r| if (std.mem.eql(u8, u, r)) return error.InvalidDatabaseName;
    if (u.len == 4 and (std.mem.startsWith(u8, u, "COM") or std.mem.startsWith(u8, u, "LPT")) and u[3] >= '1' and u[3] <= '9') return error.InvalidDatabaseName;
}

test checkName {
    try checkName("app.db");
    try checkName("notes");
    for ([_][]const u8{ "", ".", "..", "a/b", "..\\x", "c:x", " a", "a.", "CON", "nul.db", "com1.sqlite", "LPT9" }) |n|
        try std.testing.expectError(error.InvalidDatabaseName, checkName(n));
    try checkName("com10.db");
    try checkName("console.db");
}

test {
    // Compile every method, as bound services are.
    std.testing.refAllDecls(Service);
}
