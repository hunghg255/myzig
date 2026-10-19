//! Document-based apps, as AppKit's `NSDocument` and SwiftUI's
//! `DocumentGroup` make them on the Mac, on every platform: a window per
//! document, New, Open, Open Recent, Save, Save As, Duplicate, Rename,
//! Move To and Revert, autosave, a recovery copy of every unsaved change,
//! the files the system opens with the app, and the files other apps
//! change while they are open.
//!
//!     const notes = try myzig.Documents([]u8).create(gpa, io, app.documentHost(), .{
//!         .types = &.{.{ .name = "Markdown Document", .extensions = &.{"md"} }},
//!         .read = Text.read, .write = Text.write, .free = Text.free, .equal = Text.equal,
//!         .window = .of(&editor, Editor.window),
//!     });
//!     try notes.start(app.launchFiles());
//!
//! A document's content is a `T` it owns: `Document.set` replaces it
//! (freeing the old one with `free`), and with `equal` a content equal to
//! the file's makes the document unedited again, as undoing back to it
//! does. Reading and writing happen on the main thread.
const std = @import("std");
const file = @import("document_file.zig");
const recovery = @import("document_recovery.zig");
const host_mod = @import("document_host.zig");
const app_types = @import("app_types.zig");
const document = @import("document.zig");

pub const Stamp = file.Stamp;
pub const Strings = host_mod.Strings;
pub const Host = host_mod.Host;

pub const DocumentType = struct {
    /// "Markdown Document": open dialogs show it.
    name: []const u8,
    /// Without dots, lower case; new documents are saved with the first.
    extensions: []const []const u8,
};

pub const Autosave = enum {
    /// Saved to its file a moment after the user stops editing, when its
    /// window loses the focus and when it closes, as Mac apps do.
    in_place,
    /// Saved when the user saves; asks when it closes.
    off,
};

/// What a document is, for its window's title and status.
pub const State = struct {
    name: []const u8,
    /// Empty for an untitled document.
    path: []const u8,
    edited: bool,
    read_only: bool,
    /// Another app changed its file while it has unsaved changes.
    conflict: bool,
    /// Its file was deleted; saving writes it again.
    deleted: bool,
};

pub fn Options(comptime T: type, comptime Window: type) type {
    const Doc = document.Document(T, Window);
    return struct {
        types: []const DocumentType,
        /// A content from a file's bytes.
        read: *const fn (gpa: std.mem.Allocator, bytes: []const u8) anyerror!T,
        /// A content as a file's bytes.
        write: *const fn (gpa: std.mem.Allocator, content: *const T, w: *std.Io.Writer) anyerror!void,
        /// Frees a content the document no longer holds.
        free: ?*const fn (gpa: std.mem.Allocator, content: T) void = null,
        /// The content of a new document; `std.mem.zeroes(T)` without it.
        new: ?*const fn (gpa: std.mem.Allocator) anyerror!T = null,
        /// Compares contents, so that setting the file's content makes the
        /// document unedited again.
        equal: ?*const fn (a: *const T, b: *const T) bool = null,
        /// Makes the window of a document.
        window: WindowMaker(Doc, Window),
        autosave: Autosave = .in_place,
        autosave_delay_ms: u64 = 5000,
        /// How long after the last edit a recovery copy is written.
        backup_delay_ms: u64 = 1000,
        /// Asks to save at quit, rather than keeping documents for the
        /// next launch.
        ask_on_quit: bool = false,
        /// No untitled document when the app starts with nothing to open.
        no_untitled: bool = false,
        strings: Strings = .{},
        /// The app's name, in titles off macOS ("Notes.md - Editor").
        app_name: []const u8 = "",
        /// The app's data directory, where recovery copies are kept; none
        /// are kept without it.
        data_dir: ?[]const u8 = null,
        /// The largest file read.
        max_size: usize = 1 << 30,
    };
}

/// Makes a document's window: `.of(&state, State.method)`, where
/// `fn method(s: *State, doc: *Document) !*Window`.
pub fn WindowMaker(comptime Doc: type, comptime Window: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, doc: *Doc) anyerror!*Window,

        pub fn of(ptr: anytype, comptime func: fn (@TypeOf(ptr), *Doc) anyerror!*Window) @This() {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .func = struct {
                fn call(c: *anyopaque, d: *Doc) anyerror!*Window {
                    return func(@as(P, @ptrCast(@alignCast(c))), d);
                }
            }.call };
        }
    };
}

pub fn Documents(comptime T: type, comptime Window: type) type {
    return struct {
        const Self = @This();
        pub const Document = document.Document(T, Window);
        pub const Opts = Options(T, Window);

        gpa: std.mem.Allocator,
        io: std.Io,
        host: Host(Window),
        opts: Opts,
        docs: std.ArrayList(*Document) = .empty,
        store: ?recovery.Store = null,
        next_id: u64 = 1,
        /// Timers not yet fired: a destroyed `Documents` lives on until
        /// the last one fires (`dead`), since timers can't be canceled.
        pending: u32 = 0,
        dead: bool = false,
        /// Called after a document's state changes (any document's): for
        /// the File menu's items, Open Recent.
        on_change: ?app_types.Handler(*Document) = null,
        /// Every type's extensions.
        extensions: []const []const u8 = &.{},

        pub fn create(gpa: std.mem.Allocator, io: std.Io, host: Host(Window), opts: Opts) !*Self {
            std.debug.assert(opts.types.len > 0 and opts.types[0].extensions.len > 0);
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{ .gpa = gpa, .io = io, .host = host, .opts = opts };
            var exts: std.ArrayList([]const u8) = .empty;
            for (opts.types) |t| try exts.appendSlice(gpa, t.extensions);
            self.extensions = try exts.toOwnedSlice(gpa);
            errdefer gpa.free(self.extensions);
            if (opts.data_dir) |d| {
                var kind: [128]u8 = undefined;
                const name = std.fmt.bufPrint(&kind, "{s}-{s}", .{ opts.types[0].name, opts.types[0].extensions[0] }) catch opts.types[0].name;
                self.store = try recovery.Store.init(gpa, io, d, name);
            }
            return self;
        }

        /// Closes every document without asking: their unsaved changes
        /// stay in their recovery copies for the next launch.
        pub fn destroy(self: *Self) void {
            while (self.docs.items.len > 0) {
                const d = self.docs.items[self.docs.items.len - 1];
                if (d.edited and !d.discarded) d.backup();
                if (d.window) |w| {
                    d.window = null;
                    self.host.closeWindow(w);
                }
                self.drop(d);
            }
            self.docs.deinit(self.gpa);
            if (self.store) |*s| s.deinit();
            self.store = null;
            self.gpa.free(self.extensions);
            self.extensions = &.{};
            if (self.pending > 0) {
                self.dead = true;
                return;
            }
            self.gpa.destroy(self);
        }

        /// Opens what the app starts with: the documents a crash or a
        /// quit left with unsaved changes, the files it was started with
        /// (`paths`), or else an untitled document.
        pub fn start(self: *Self, paths: []const []const u8) !void {
            _ = self.restore();
            for (paths) |p| _ = self.open(p) catch |err| self.showError(null, p, err);
            if (self.docs.items.len == 0 and !self.opts.no_untitled) _ = try self.new();
        }

        /// A new untitled document, in its window.
        pub fn new(self: *Self) !*Document {
            const content = if (self.opts.new) |f| try f(self.gpa) else std.mem.zeroes(T);
            const d = try self.add(content);
            d.untitled = self.nextUntitled();
            try self.show(d);
            return d;
        }

        /// Opens the file `path`, or focuses its window if it is open.
        pub fn open(self: *Self, path_in: []const u8) !*Document {
            const path = std.Io.Dir.cwd().realPathFileAlloc(self.io, path_in, self.gpa) catch |err| return err;
            defer self.gpa.free(path);
            if (self.find(path)) |d| {
                if (d.window) |w| self.host.focusWindow(w);
                return d;
            }
            const bytes = try file.readAll(self.gpa, self.io, path, self.opts.max_size);
            defer self.gpa.free(bytes);
            const stamp = file.stampOf(self.io, path) orelse return error.FileNotFound;
            const content = try self.opts.read(self.gpa, bytes);
            const d = try self.add(content);
            errdefer self.drop(d);
            try d.setPath(path);
            d.stamp = stamp;
            d.read_only = !file.writable(self.io, path);
            try d.keepSaved(bytes);
            d.watch();
            self.host.addRecent(path);
            try self.show(d);
            return d;
        }

        /// Asks which files to open, and opens them.
        pub fn openDialog(self: *Self) void {
            const paths = self.host.openPaths(self.gpa, .{ .multiple = true, .extensions = self.allExtensions() }) orelse return;
            defer {
                for (paths) |p| self.gpa.free(p);
                self.gpa.free(paths);
            }
            for (paths) |p| _ = self.open(p) catch |err| self.showError(null, p, err);
        }

        /// The extensions of every type, for dialogs.
        pub fn allExtensions(self: *Self) []const []const u8 {
            return self.extensions;
        }

        /// Whether the app opens `path` as one of these documents (the
        /// files the system hands it: `AppOptions.on_open_file`).
        pub fn handles(self: *Self, path: []const u8) bool {
            for (self.opts.types) |t| if (file.hasExtension(path, t.extensions)) return true;
            return false;
        }

        /// A file the system asks the app to open (Finder, Explorer, the
        /// command line, a later instance): give it to `on_open_file`.
        pub fn openFile(self: *Self, path: []const u8) void {
            if (!self.handles(path)) return;
            _ = self.open(path) catch |err| self.showError(null, path, err);
        }

        /// The open document of a file.
        pub fn find(self: *Self, path: []const u8) ?*Document {
            for (self.docs.items) |d| if (d.path) |p| if (samePath(p, path)) return d;
            return null;
        }

        /// The document of a window.
        pub fn forWindow(self: *Self, w: *Window) ?*Document {
            for (self.docs.items) |d| if (d.window == w) return d;
            return null;
        }

        /// The document of the focused window, for the File menu.
        pub fn focused(self: *Self) ?*Document {
            const w = self.host.focusedWindow() orelse return null;
            return self.forWindow(w);
        }

        /// A document's window closed without its document asking (the
        /// window's close button until windows can ask first, a parent
        /// closing): its unsaved changes stay in its recovery copy.
        pub fn windowClosed(self: *Self, w: *Window) void {
            const d = self.forWindow(w) orelse return;
            d.window = null;
            if (d.edited and !d.discarded) d.backup() else d.forgetCopy();
            self.drop(d);
        }

        /// A document's window got the focus: its file may have changed
        /// while no watch saw it, as VS Code and Notepad++ look.
        pub fn windowFocused(self: *Self, w: *Window) void {
            if (self.forWindow(w)) |d| d.checkDisk();
        }

        /// A document's window lost the focus: autosave saves it now.
        pub fn windowBlurred(self: *Self, w: *Window) void {
            if (self.forWindow(w)) |d| if (d.edited and d.autosaves()) d.autosaveNow();
        }

        /// Takes care of the documents before the app quits, and tells
        /// whether it may: autosaved ones are saved, the others keep their
        /// recovery copies for the next launch, or with `ask_on_quit` the
        /// user is asked. False when the user canceled.
        pub fn prepareQuit(self: *Self) bool {
            var ask: std.ArrayList(*Document) = .empty;
            defer ask.deinit(self.gpa);
            for (self.docs.items) |d| {
                if (!d.edited) continue;
                if (d.autosaves() and d.writeInPlace(.autosave)) continue;
                if (self.opts.ask_on_quit) {
                    ask.append(self.gpa, d) catch return false;
                } else d.backup();
            }
            if (ask.items.len == 0) return true;
            if (ask.items.len == 1) {
                const d = ask.items[0];
                if (d.window) |w| self.host.focusWindow(w);
                return d.askToSave();
            }
            return self.askMany(ask.items);
        }

        /// Quits once the documents are taken care of.
        pub fn quit(self: *Self) void {
            if (self.prepareQuit()) self.host.quit();
        }

        fn askMany(self: *Self, ask: []const *Document) bool {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const s = self.opts.strings;
            var names: std.ArrayList(u8) = .empty;
            for (ask) |d| {
                names.appendSlice(a, d.name()) catch {};
                names.append(a, '\n') catch {};
            }
            names.appendSlice(a, "\n") catch {};
            names.appendSlice(a, s.changes_lost) catch {};
            const count = std.fmt.allocPrint(a, "{d}", .{ask.len}) catch "";
            const b = host_mod.SaveButtons.of(s.save_all, s.dont_save, s.cancel);
            const i = self.host.message(null, .{ .title = host_mod.fill(a, s.save_many, count), .detail = names.items, .kind = .warning, .buttons = &b.labels });
            switch (host_mod.answerOf(b, i)) {
                .save => {
                    for (ask) |d| if (!d.saveInteractive(false)) return false;
                    return true;
                },
                .discard => {
                    for (ask) |d| d.discard();
                    return true;
                },
                .cancel => return false,
            }
        }

        /// Opens the documents of the sessions no instance holds, edited,
        /// keeping their copies in this session. Returns how many.
        pub fn restore(self: *Self) usize {
            const store = if (self.store) |*s| s else return 0;
            const orphans = store.claim() catch return 0;
            defer recovery.freeOrphans(self.gpa, orphans);
            var n: usize = 0;
            for (orphans) |o| {
                const e = o.entry;
                if (e.path.len > 0 and self.find(e.path) != null) continue;
                const content = self.opts.read(self.gpa, o.bytes) catch continue;
                const d = self.add(content) catch continue;
                if (e.path.len > 0) {
                    d.setPath(e.path) catch {};
                    d.stamp = e.stamp;
                    if (file.stampOf(self.io, e.path)) |now| {
                        d.conflict = !now.eql(e.stamp);
                        d.read_only = !file.writable(self.io, e.path);
                        // What the file has, for `equal`.
                        if (!d.conflict) if (file.readAll(self.gpa, self.io, e.path, self.opts.max_size)) |b| {
                            defer self.gpa.free(b);
                            d.keepSaved(b) catch {};
                        } else |_| {};
                    } else d.deleted = true;
                    d.watch();
                } else d.untitled = @max(1, file.untitledNumber(e.name, self.opts.strings.untitled));
                d.edited = true;
                d.backup();
                self.show(d) catch {
                    self.drop(d);
                    continue;
                };
                n += 1;
            }
            return n;
        }

        // Inside.

        pub fn add(self: *Self, content: T) !*Document {
            const d = try self.gpa.create(Document);
            d.* = .{ .ds = self, .id = self.next_id, .content = content };
            recovery.randomName(self.io, &d.copy_id);
            self.next_id += 1;
            self.docs.append(self.gpa, d) catch |err| {
                d.freeContent();
                self.gpa.destroy(d);
                return err;
            };
            return d;
        }

        /// Makes a document's window and shows its title.
        pub fn show(self: *Self, d: *Document) !void {
            d.window = try self.opts.window.func(self.opts.window.ctx, d);
            d.notify();
        }

        /// Forgets a document whose window is gone.
        pub fn drop(self: *Self, d: *Document) void {
            for (self.docs.items, 0..) |x, i| if (x == d) {
                _ = self.docs.orderedRemove(i);
                break;
            };
            d.deinit();
            self.gpa.destroy(d);
        }

        /// The lowest number no untitled document has.
        fn nextUntitled(self: *Self) u32 {
            var n: u32 = 1;
            while (true) : (n += 1) {
                var used = false;
                for (self.docs.items) |d| if (d.path == null and d.untitled == n) {
                    used = true;
                };
                if (!used) return n;
            }
        }

        pub fn showError(self: *Self, parent: ?*Window, what: []const u8, err: anyerror) void {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const title = host_mod.fill(arena.allocator(), self.opts.strings.cant_save, file.displayName(what));
            _ = self.host.message(parent, .{ .title = title, .detail = @errorName(err), .kind = .critical });
        }

        /// A timer of a document: `kind` with the generation it was set at.
        pub const Tick = struct { ds: *Self, doc: u64, gen: u32, kind: Kind };
        pub const Kind = enum { autosave, autosave_max, backup, watch };

        pub fn schedule(self: *Self, d: *Document, ms: u64, kind: Kind, gen: u32) void {
            const t = self.gpa.create(Tick) catch return;
            t.* = .{ .ds = self, .doc = d.id, .gen = gen, .kind = kind };
            self.pending += 1;
            self.host.after(ms, t, fire);
        }

        fn fire(arg: ?*anyopaque) callconv(.c) void {
            const t: *Tick = @ptrCast(@alignCast(arg));
            const self = t.ds;
            const tick = t.*;
            self.gpa.destroy(t);
            self.pending -= 1;
            if (self.dead) {
                if (self.pending == 0) self.gpa.destroy(self);
                return;
            }
            for (self.docs.items) |d| if (d.id == tick.doc) return d.timer(tick.kind, tick.gen);
        }
    };
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (@import("builtin").os.tag == .windows) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

test {
    _ = file;
    _ = recovery;
    _ = host_mod;
}
