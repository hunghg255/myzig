//! Documents with temporary files and a host of the test's own: questions
//! answered as the test says, timers run when it says, no window.
const std = @import("std");
const docs_mod = @import("documents.zig");
const host_mod = @import("document_host.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

const FakeWindow = struct { title: [128]u8 = undefined, title_len: usize = 0, closed: bool = false };

/// The app as documents see it, in a test.
const Fake = struct {
    windows: std.ArrayList(*FakeWindow) = .empty,
    /// The buttons the next questions are answered with, in order.
    answers: std.ArrayList(usize) = .empty,
    questions: std.ArrayList([]u8) = .empty,
    save_paths: std.ArrayList([]const u8) = .empty,
    timers: std.ArrayList(struct { arg: ?*anyopaque, func: host_mod.TimerFn }) = .empty,
    watches: u32 = 0,
    recent: u32 = 0,
    quits: u32 = 0,
    focused: ?*FakeWindow = null,

    fn deinit(f: *Fake) void {
        // Timers fire after the documents are gone, as the app's loop
        // would run them: they free what waited for them.
        while (f.timers.items.len > 0) f.runTimers();
        for (f.windows.items) |w| gpa.destroy(w);
        f.windows.deinit(gpa);
        f.answers.deinit(gpa);
        for (f.questions.items) |q| gpa.free(q);
        f.questions.deinit(gpa);
        f.save_paths.deinit(gpa);
        f.timers.deinit(gpa);
    }

    /// Runs the timers set so far (as their time came).
    fn runTimers(f: *Fake) void {
        const ts = f.timers.toOwnedSlice(gpa) catch unreachable;
        defer gpa.free(ts);
        for (ts) |t| t.func(t.arg);
    }

    fn host(f: *Fake) host_mod.Host(FakeWindow) {
        return .{ .ctx = f, .vtable = &vtable };
    }

    const vtable: host_mod.Host(FakeWindow).VTable = .{
        .message = message,
        .save_path = savePath,
        .open_paths = openPaths,
        .after = after,
        .set_title = setTitle,
        .close_window = closeWindow,
        .focus_window = focusWindow,
        .focused_window = focusedWindow,
        .watch = watch,
        .unwatch = unwatch,
        .add_recent = addRecent,
        .quit = quit,
    };

    fn of(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn message(ctx: *anyopaque, _: ?*FakeWindow, opts: host_mod.MessageOptions) usize {
        const f = of(ctx);
        f.questions.append(gpa, gpa.dupe(u8, opts.title) catch unreachable) catch unreachable;
        if (f.answers.items.len == 0) return opts.buttons.len; // nothing: a cancel
        return f.answers.orderedRemove(0);
    }
    fn savePath(ctx: *anyopaque, a: std.mem.Allocator, _: ?*FakeWindow, _: host_mod.SaveOptions) ?[]u8 {
        const f = of(ctx);
        if (f.save_paths.items.len == 0) return null;
        return a.dupe(u8, f.save_paths.orderedRemove(0)) catch null;
    }
    fn openPaths(_: *anyopaque, _: std.mem.Allocator, _: host_mod.OpenOptions) ?[][]u8 {
        return null;
    }
    fn after(ctx: *anyopaque, _: u64, arg: ?*anyopaque, func: host_mod.TimerFn) void {
        of(ctx).timers.append(gpa, .{ .arg = arg, .func = func }) catch unreachable;
    }
    fn setTitle(_: *anyopaque, w: *FakeWindow, title: []const u8) void {
        const n = @min(title.len, w.title.len);
        @memcpy(w.title[0..n], title[0..n]);
        w.title_len = n;
    }
    fn closeWindow(_: *anyopaque, w: *FakeWindow) void {
        w.closed = true;
    }
    fn focusWindow(ctx: *anyopaque, w: *FakeWindow) void {
        of(ctx).focused = w;
    }
    fn focusedWindow(ctx: *anyopaque) ?*FakeWindow {
        return of(ctx).focused;
    }
    fn watch(ctx: *anyopaque, _: []const u8, _: ?*anyopaque, _: host_mod.TimerFn) ?host_mod.WatchId {
        of(ctx).watches += 1;
        return of(ctx).watches;
    }
    fn unwatch(_: *anyopaque, _: host_mod.WatchId) void {}
    fn addRecent(ctx: *anyopaque, _: []const u8) void {
        of(ctx).recent += 1;
    }
    fn quit(ctx: *anyopaque) void {
        of(ctx).quits += 1;
    }

    fn window(f: *Fake, _: *Docs.Document) anyerror!*FakeWindow {
        const w = try gpa.create(FakeWindow);
        w.* = .{};
        try f.windows.append(gpa, w);
        f.focused = w;
        return w;
    }
};

/// Text documents: the content is the file's bytes.
const Text = struct {
    fn read(a: std.mem.Allocator, bytes: []const u8) anyerror![]u8 {
        return a.dupe(u8, bytes);
    }
    fn write(_: std.mem.Allocator, content: *const []u8, w: *std.Io.Writer) anyerror!void {
        try w.writeAll(content.*);
    }
    fn free(a: std.mem.Allocator, content: []u8) void {
        a.free(content);
    }
    fn equal(x: *const []u8, y: *const []u8) bool {
        return std.mem.eql(u8, x.*, y.*);
    }
};

const Docs = docs_mod.Documents([]u8, FakeWindow);

const Fixture = struct {
    tmp: std.testing.TmpDir,
    dir: [:0]u8,
    data: []u8,
    fake: Fake = .{},

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        try tmp.dir.createDirPath(io, "data");
        const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        const data = try std.fs.path.join(gpa, &.{ dir, "data" });
        return .{ .tmp = tmp, .dir = dir, .data = data };
    }

    fn deinit(f: *Fixture) void {
        f.fake.deinit();
        gpa.free(f.dir);
        gpa.free(f.data);
        f.tmp.cleanup();
    }

    fn docs(f: *Fixture, autosave: docs_mod.Autosave) !*Docs {
        return Docs.create(gpa, io, f.fake.host(), .{
            .types = &.{.{ .name = "Text Document", .extensions = &.{"txt"} }},
            .read = Text.read,
            .write = Text.write,
            .free = Text.free,
            .equal = Text.equal,
            .window = .of(&f.fake, Fake.window),
            .autosave = autosave,
            .data_dir = f.data,
            .app_name = "Editor",
        });
    }

    fn path(f: *Fixture, name: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ f.dir, name });
    }

    fn read(f: *Fixture, name: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
    }
};

fn setText(d: *Docs.Document, s: []const u8) void {
    d.set(gpa.dupe(u8, s) catch unreachable);
}

test "documents: edited, asked on close, saved; undoing back is unedited" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" });
    const p = try f.path("a.txt");
    defer gpa.free(p);
    const ds = try f.docs(.off);
    defer ds.destroy();
    const d = try ds.open(p);
    try std.testing.expectEqualStrings("hello", d.content);
    try std.testing.expectEqualStrings("a.txt", d.name());
    try std.testing.expect(!d.edited);

    setText(d, "hello!");
    try std.testing.expect(d.edited);
    const w = d.window.?;
    if (@import("builtin").os.tag != .macos) try std.testing.expectEqualStrings("*a.txt - Editor", w.title[0..w.title_len]);
    // Back to what the file has: unedited again.
    setText(d, "hello");
    try std.testing.expect(!d.edited);
    setText(d, "hello, world");

    // Cancel keeps it open.
    try std.testing.expect(!d.close());
    try std.testing.expectEqual(@as(usize, 1), f.fake.questions.items.len);
    try std.testing.expectEqualStrings("Do you want to save the changes made to the document “a.txt”?", f.fake.questions.items[0]);
    try std.testing.expect(!w.closed);
    // Save closes it, with the file written.
    const b = host_mod.SaveButtons.of("", "", "");
    try f.fake.answers.append(gpa, b.save);
    try std.testing.expect(d.close());
    try std.testing.expect(w.closed);
    try std.testing.expectEqual(@as(usize, 0), ds.docs.items.len);
    const back = try f.read("a.txt");
    defer gpa.free(back);
    try std.testing.expectEqualStrings("hello, world", back);
}

test "documents: an untitled document asks where to save, Don't Save discards" {
    var f = try Fixture.init();
    defer f.deinit();
    const ds = try f.docs(.in_place);
    defer ds.destroy();
    try ds.start(&.{});
    try std.testing.expectEqual(@as(usize, 1), ds.docs.items.len);
    const d = ds.docs.items[0];
    try std.testing.expectEqualStrings("Untitled", d.name());
    const d2 = try ds.new();
    try std.testing.expectEqualStrings("Untitled 2", d2.name());
    setText(d, "draft");
    setText(d2, "other");
    // Closing an edited untitled document with autosave: keep it?
    const target = try f.path("draft.txt");
    defer gpa.free(target);
    try f.fake.save_paths.append(gpa, target);
    try f.fake.answers.append(gpa, host_mod.SaveButtons.of("", "", "").save);
    try std.testing.expect(d.close());
    try std.testing.expectEqualStrings("Do you want to keep this new document “Untitled”?", f.fake.questions.items[0]);
    const back = try f.read("draft.txt");
    defer gpa.free(back);
    try std.testing.expectEqualStrings("draft", back);
    // Delete drops it.
    try f.fake.answers.append(gpa, host_mod.SaveButtons.of("", "", "").discard);
    try std.testing.expect(d2.close());
    try std.testing.expectEqual(@as(usize, 0), ds.docs.items.len);
}

test "documents: autosave writes a moment after the last edit, without asking" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "one" });
    const p = try f.path("b.txt");
    defer gpa.free(p);
    const ds = try f.docs(.in_place);
    defer ds.destroy();
    const d = try ds.open(p);
    setText(d, "two");
    setText(d, "three");
    f.fake.runTimers();
    try std.testing.expect(!d.edited);
    const back = try f.read("b.txt");
    defer gpa.free(back);
    try std.testing.expectEqualStrings("three", back);
    // A saved, edited document closes without a question: saved first.
    setText(d, "four");
    try std.testing.expect(d.close());
    try std.testing.expectEqual(@as(usize, 0), f.fake.questions.items.len);
    const after = try f.read("b.txt");
    defer gpa.free(after);
    try std.testing.expectEqualStrings("four", after);
    f.fake.runTimers(); // late timers of a closed document do nothing
}

test "documents: recovery after a crash brings unsaved changes back, edited" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "saved" });
    const p = try f.path("c.txt");
    defer gpa.free(p);
    {
        const ds = try f.docs(.off);
        const d = try ds.open(p);
        setText(d, "unsaved work");
        const u = try ds.new();
        setText(u, "new note");
        f.fake.runTimers(); // the recovery copies, a second later
        // The crash: nothing is saved, the lock goes with the process.
        crash(ds);
    }
    const ds = try f.docs(.off);
    defer ds.destroy();
    try ds.start(&.{});
    try std.testing.expectEqual(@as(usize, 2), ds.docs.items.len);
    var found_file = false;
    var found_new = false;
    for (ds.docs.items) |d| {
        try std.testing.expect(d.edited);
        if (d.path != null) {
            found_file = true;
            try std.testing.expectEqualStrings("unsaved work", d.content);
            try std.testing.expect(!d.conflict);
        } else {
            found_new = true;
            try std.testing.expectEqualStrings("new note", d.content);
        }
    }
    try std.testing.expect(found_file and found_new);
    // The file itself was never touched.
    const back = try f.read("c.txt");
    defer gpa.free(back);
    try std.testing.expectEqualStrings("saved", back);
}

/// What a crash leaves: documents freed without a word, the session's
/// lock released (by the system).
fn crash(ds: *Docs) void {
    for (ds.docs.items) |d| {
        d.deinit();
        gpa.destroy(d);
    }
    ds.docs.deinit(gpa);
    if (ds.store) |*s| {
        if (s.lock) |l| l.close(io);
        s.lock = null;
        // Keep its files: free the memory only.
        for (s.entries.items) |e| {
            gpa.free(e.id);
            gpa.free(e.path);
            gpa.free(e.name);
        }
        s.entries.clearRetainingCapacity();
        const sess = s.session;
        s.session = null;
        s.deinit();
        if (sess) |x| gpa.free(x);
    }
    gpa.free(ds.extensions);
    gpa.destroy(ds);
}

test "documents: another app's change reloads an unedited document, conflicts with an edited one" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "v1" });
    const p = try f.path("d.txt");
    defer gpa.free(p);
    const ds = try f.docs(.in_place);
    defer ds.destroy();
    const d = try ds.open(p);
    try std.testing.expect(f.fake.watches > 0);
    const R = struct {
        var reloads: usize = 0;
        fn reload(_: *usize, _: *Docs.Document) void {
            reloads += 1;
        }
    };
    var dummy: usize = 0;
    d.on_reload = .of(&dummy, R.reload);

    try f.tmp.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "v2 from another app" });
    d.checkDisk(); // as the watch or the window's focus does
    try std.testing.expectEqualStrings("v2 from another app", d.content);
    try std.testing.expectEqual(@as(usize, 1), R.reloads);
    try std.testing.expect(!d.edited);

    setText(d, "mine");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "v3, longer, from another app" });
    d.checkDisk();
    try std.testing.expect(d.conflict);
    try std.testing.expect(!d.autosaves());
    f.fake.runTimers(); // autosave writes nothing over it
    const kept = try f.read("d.txt");
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("v3, longer, from another app", kept);
    // Saving asks: Save Anyway writes this version.
    try f.fake.answers.append(gpa, host_mod.SaveButtons.of("", "", "").save);
    try std.testing.expect(d.save());
    const now = try f.read("d.txt");
    defer gpa.free(now);
    try std.testing.expectEqualStrings("mine", now);
    try std.testing.expect(!d.conflict and !d.edited);
    // A deleted file leaves the document open, deleted.
    try f.tmp.dir.deleteFile(io, "d.txt");
    d.checkDisk();
    try std.testing.expect(d.deleted);
}

test "documents: quitting keeps unsaved documents for the next launch, or asks" {
    var f = try Fixture.init();
    defer f.deinit();
    const ds = try f.docs(.off);
    const a = try ds.new();
    const b = try ds.new();
    setText(a, "a");
    setText(b, "b");
    // Without ask_on_quit: no question, both kept in recovery copies.
    try std.testing.expect(ds.prepareQuit());
    try std.testing.expectEqual(@as(usize, 0), f.fake.questions.items.len);
    try std.testing.expectEqual(@as(usize, 2), ds.store.?.entries.items.len);
    ds.opts.ask_on_quit = true;
    // Asked: Cancel keeps the app.
    try std.testing.expect(!ds.prepareQuit());
    try std.testing.expectEqualStrings("Do you want to save the changes made to 2 documents?", f.fake.questions.items[0]);
    // Don't Save quits.
    try f.fake.answers.append(gpa, host_mod.SaveButtons.of("", "", "").discard);
    ds.quit();
    try std.testing.expectEqual(@as(u32, 1), f.fake.quits);
    ds.destroy();
}

test "documents: a file renamed right after another app replaced it is followed, not deleted" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "doc.txt", .data = "one" });
    const p = try f.path("doc.txt");
    defer gpa.free(p);
    const ds = try f.docs(.off);
    defer ds.destroy();
    const d = try ds.open(p);
    // Another app saves as editors do: a new file renamed over the old.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "doc.txt.tmp", .data = "two, longer" });
    try f.tmp.dir.rename("doc.txt.tmp", f.tmp.dir, "doc.txt", io);
    d.checkDisk(); // as the watch or the window's focus does
    try std.testing.expectEqualStrings("two, longer", d.content);
    // Then renames it: the document finds it by what it last read.
    const recent = f.fake.recent;
    try f.tmp.dir.rename("doc.txt", f.tmp.dir, "renamed.txt", io);
    d.checkDisk();
    try std.testing.expect(!d.deleted);
    try std.testing.expectEqualStrings("renamed.txt", std.fs.path.basename(d.path.?));
    try std.testing.expectEqual(recent + 1, f.fake.recent);
    try std.testing.expectEqualStrings("two, longer", d.content);
    // Gone for good: deleted, with nothing of its identity left.
    try f.tmp.dir.deleteFile(io, "renamed.txt");
    d.checkDisk();
    try std.testing.expect(d.deleted);
}
