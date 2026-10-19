//! The plugin against the system's SQLite, on temporary databases.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const Db = sqlite.Db;
const Value = sqlite.Value;
const testing = std.testing;

fn tempPath(buf: []u8, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &dir_buf);
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir_buf[0..n], std.fs.path.sep, name });
}

const Note = struct {
    id: i64,
    title: []const u8,
    done: bool,
    score: ?f64,
    tag: enum { work, home } = .home,
};

test "a file database: schema, inserts, rows into structs, and again after reopening" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&buf, &tmp, "notes.db");
    {
        var db = try Db.open(path, .{});
        defer db.close();
        try db.execScript(
            \\CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INTEGER NOT NULL, score REAL, tag TEXT);
            \\CREATE INDEX notes_done ON notes(done);
        );
        const r = try db.exec("INSERT INTO notes(title, done, score, tag) VALUES (?, ?, ?, ?)", .{ "Write tests", false, 2.5, "work" });
        try testing.expectEqual(@as(i64, 1), r.changes);
        try testing.expectEqual(@as(i64, 1), r.last_insert_id);
        _ = try db.exec("INSERT INTO notes(title, done, score) VALUES (?, ?, ?)", .{ "Ship", true, null });
    }
    var db = try Db.open(path, .{ .read_only = true });
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const notes = try db.all(Note, arena.allocator(), "SELECT id, title, done, score, tag FROM notes ORDER BY id", .{});
    try testing.expectEqual(@as(usize, 2), notes.len);
    try testing.expectEqualStrings("Write tests", notes[0].title);
    try testing.expectEqual(false, notes[0].done);
    try testing.expectEqual(@as(?f64, 2.5), notes[0].score);
    try testing.expectEqual(.work, notes[0].tag);
    try testing.expectEqual(true, notes[1].done);
    try testing.expectEqual(@as(?f64, null), notes[1].score);
    // No tag column in the query: the field keeps its default.
    const one = (try db.one(struct { id: i64, tag: @FieldType(Note, "tag") = .home }, arena.allocator(), "SELECT id FROM notes WHERE title = ?", .{"Ship"})).?;
    try testing.expectEqual(@as(i64, 2), one.id);
    try testing.expectEqual(null, try db.one(Note, arena.allocator(), "SELECT * FROM notes WHERE id = ?", .{99}));
    // Read-only means read-only.
    try testing.expectError(error.Sqlite, db.exec("DELETE FROM notes", .{}));
    try testing.expectEqual(@as(c_int, 8), db.diagnostics.code & 0xff); // SQLITE_READONLY
}

test "prepared statements: typed binding, reuse, every storage class" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    _ = try db.exec("CREATE TABLE t (v)", .{});
    var ins = try db.prepare("INSERT INTO t VALUES (?1)");
    defer ins.finalize();
    const big: i64 = std.math.maxInt(i64);
    try ins.bind(1, big);
    _ = try ins.run();
    ins.reset();
    try ins.bind(1, @as(f32, 0.5));
    _ = try ins.run();
    ins.reset();
    try ins.bind(1, sqlite.blob(""));
    _ = try ins.run();
    ins.reset();
    try ins.bind(1, "");
    _ = try ins.run();
    ins.reset();
    try ins.bind(1, @as(?u8, null));
    _ = try ins.run();
    ins.reset();
    try ins.bind(1, Value{ .blob = "\x00\xff" });
    _ = try ins.run();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rows = try db.query(arena.allocator(), "SELECT v, typeof(v) AS kind FROM t ORDER BY rowid", &.{});
    try testing.expectEqualStrings("v", rows.columns[0]);
    try testing.expectEqualStrings("kind", rows.columns[1]);
    try testing.expectEqual(big, rows.rows[0][0].integer);
    try testing.expectEqual(@as(f64, 0.5), rows.rows[1][0].real);
    // Empty blobs and empty text stay distinct from NULL.
    try testing.expectEqualStrings("blob", rows.rows[2][1].text);
    try testing.expectEqualStrings("text", rows.rows[3][1].text);
    try testing.expectEqual(Value.null, rows.rows[4][0]);
    try testing.expectEqualSlices(u8, "\x00\xff", rows.rows[5][0].blob);

    try testing.expectError(error.NonFiniteNumber, ins.bind(1, std.math.nan(f64)));
    try testing.expectError(error.TooLarge, ins.bind(1, @as(u64, std.math.maxInt(u64))));
    try testing.expectError(error.TextNotUtf8, ins.bind(1, "\xff"));
}

test "named parameters bind by index; every parameter needs a value" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try db.query(arena.allocator(), "SELECT :a + $b, @c || 'x'", &.{ .{ .integer = 2 }, .{ .integer = 3 }, .{ .text = "y" } });
    try testing.expectEqual(@as(i64, 5), r.rows[0][0].integer);
    try testing.expectEqualStrings("yx", r.rows[0][1].text);
    try testing.expectError(error.WrongParameterCount, db.exec("SELECT ?, ?", .{1}));
    try testing.expectError(error.WrongParameterCount, db.exec("SELECT ?", .{ 1, 2 }));
}

test "one statement at a time: trailing semicolons and comments pass" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    _ = try db.exec("SELECT 1; -- done\n ; /* and */", .{});
    try testing.expectError(error.MultipleStatements, db.exec("SELECT 1; SELECT 2", .{}));
    try testing.expectError(error.EmptyStatement, db.exec("  -- nothing", .{}));
    try testing.expectError(error.Sqlite, db.exec("SELEC 1", .{}));
    try testing.expect(std.mem.indexOf(u8, db.diagnostics.text(), "syntax error") != null);
}

test "transactions commit together or roll back together" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    _ = try db.exec("CREATE TABLE t (n INTEGER UNIQUE)", .{});
    try db.transaction({}, struct {
        fn body(d: *Db, _: void) !void {
            _ = try d.exec("INSERT INTO t VALUES (1)", .{});
            _ = try d.exec("INSERT INTO t VALUES (2)", .{});
        }
    }.body);
    try testing.expectError(error.Constraint, db.transaction({}, struct {
        fn body(d: *Db, _: void) !void {
            _ = try d.exec("INSERT INTO t VALUES (3)", .{});
            _ = try d.exec("INSERT INTO t VALUES (1)", .{});
        }
    }.body));
    try testing.expect(!db.inTransaction());
    const Count = struct { n: i64 };
    const c = (try db.one(Count, testing.allocator, "SELECT count(*) AS n FROM t", .{})).?;
    try testing.expectEqual(@as(i64, 2), c.n);
}

test "guarded connections refuse transaction control, attaching files and VACUUM INTO" {
    var db = try Db.open(":memory:", .{ .guarded = true });
    defer db.close();
    _ = try db.exec("CREATE TABLE t (n)", .{});
    for ([_][]const u8{ "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT a", "RELEASE a", "ATTACH 'x.db' AS x", "DETACH x", "VACUUM INTO 'x.db'", "vacuum main into 'x.db'", "/* c */ VACUUM \"main\" INTO 'x'" }) |sql|
        testing.expectError(error.StatementNotAllowed, db.exec(sql, .{})) catch |e| {
            std.debug.print("allowed: {s}\n", .{sql});
            return e;
        };
    try testing.expectError(error.StatementNotAllowed, db.execScript("SELECT 1"));
    // The plugin's own transactions still work, and ordinary VACUUM.
    try db.begin();
    _ = try db.exec("INSERT INTO t VALUES (1)", .{});
    try db.commit();
    _ = try db.exec("VACUUM", .{});
}

test "a second connection waits for the lock, then gives up" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&buf, &tmp, "busy.db");
    var a = try Db.open(path, .{});
    defer a.close();
    var b = try Db.open(path, .{ .busy_timeout_ms = 0 });
    defer b.close();
    _ = try a.exec("CREATE TABLE t (n)", .{});
    try a.begin();
    _ = try a.exec("INSERT INTO t VALUES (1)", .{});
    try testing.expectError(error.Busy, b.exec("INSERT INTO t VALUES (2)", .{}));
    try a.commit();
    _ = try b.exec("INSERT INTO t VALUES (2)", .{});
}

test "the library loaded is SQLite 3" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    const v = std.mem.span(db.api.sqlite3_libversion());
    try testing.expect(std.mem.startsWith(u8, v, "3."));
    try testing.expect(sqlite.lib.path().len > 0);
}
