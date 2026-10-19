//! An open document: its content, its file, whether it has unsaved
//! changes, saving, reverting, autosave, recovery copies, its file
//! changing under it, and closing.
const std = @import("std");
const file = @import("document_file.zig");
const host_mod = @import("document_host.zig");
const app_types = @import("app_types.zig");
const documents = @import("documents.zig");

/// How a write happens: autosave writes nothing over a file another app
/// changed; a save asks first; a save anyway overwrites it.
pub const WriteOp = enum { autosave, save, save_anyway };

pub fn Document(comptime T: type, comptime Window: type) type {
    return struct {
        const Self = @This();
        const Ds = documents.Documents(T, Window);

        ds: *Ds,
        id: u64,
        content: T,
        /// The content the file has, with `equal`: what makes the document
        /// unedited again.
        saved: ?T = null,
        window: ?*Window = null,
        path: ?[]u8 = null,
        /// "Untitled" is 1, "Untitled 2" 2.
        untitled: u32 = 0,
        stamp: file.Stamp = .{},
        edited: bool = false,
        read_only: bool = false,
        conflict: bool = false,
        deleted: bool = false,
        /// Closing without saving: its recovery copy goes.
        discarded: bool = false,
        /// Edits so far, and how many the recovery copy has.
        changes: u32 = 0,
        backed_up: u32 = 0,
        /// The generation of autosave timers: an edit sets a new one.
        autosave_gen: u32 = 0,
        autosave_max_set: bool = false,
        copy_id: [12]u8 = @splat('0'),
        watch_id: ?host_mod.WatchId = null,
        watch_tick: ?*Ds.Tick = null,
        /// The app shows the new content after the file was read again.
        on_reload: ?app_types.Handler(*Self) = null,
        /// The state changed (edited, saved, renamed, in conflict...).
        on_state: ?app_types.Handler(*Self) = null,
        name_buf: [96]u8 = undefined,

        pub fn deinit(d: *Self) void {
            d.unwatch();
            d.freeContent();
            if (d.saved) |s| if (d.ds.opts.free) |f| f(d.ds.gpa, s);
            if (d.path) |p| d.ds.gpa.free(p);
        }

        pub fn freeContent(d: *Self) void {
            if (d.ds.opts.free) |f| f(d.ds.gpa, d.content);
        }

        /// The name it shows: its file's, or "Untitled", "Untitled 2"…
        pub fn name(d: *Self) []const u8 {
            if (d.path) |p| return file.displayName(p);
            return file.untitledName(&d.name_buf, d.ds.opts.strings.untitled, d.untitled);
        }

        pub fn state(d: *Self) documents.State {
            return .{ .name = d.name(), .path = d.path orelse "", .edited = d.edited, .read_only = d.read_only, .conflict = d.conflict, .deleted = d.deleted };
        }

        /// Replaces the content, which it then owns, freeing the old one:
        /// an edit, unless `equal` says it is what the file has.
        pub fn set(d: *Self, content: T) void {
            d.freeContent();
            d.content = content;
            const same = if (d.saved) |*s| (if (d.ds.opts.equal) |eq| eq(&d.content, s) else false) else false;
            d.edit(!same);
        }

        /// The content was changed in place (a mutable content): an edit.
        pub fn changed(d: *Self) void {
            d.edit(true);
        }

        /// Sets whether it has unsaved changes, for an app that knows
        /// better (its own undo history): false makes the content what the
        /// file has, without writing it.
        pub fn setEdited(d: *Self, edited: bool) void {
            d.edit(edited);
        }

        fn edit(d: *Self, edited: bool) void {
            d.changes +%= 1;
            const was = d.edited;
            d.edited = edited;
            if (!edited) d.forgetCopy();
            if (edited) d.scheduleSaves();
            if (was != edited) d.notify();
        }

        /// Whether saving happens by itself: autosave in place, to a file
        /// that may be written as is.
        pub fn autosaves(d: *Self) bool {
            return d.ds.opts.autosave == .in_place and d.path != null and !d.read_only and !d.conflict and !d.deleted;
        }

        fn scheduleSaves(d: *Self) void {
            const o = d.ds.opts;
            if (d.autosaves()) {
                d.autosave_gen +%= 1;
                d.ds.schedule(d, o.autosave_delay_ms, .autosave, d.autosave_gen);
                // At least every 30 seconds while the user keeps editing.
                if (!d.autosave_max_set) {
                    d.autosave_max_set = true;
                    d.ds.schedule(d, @max(o.autosave_delay_ms, 30_000), .autosave_max, 0);
                }
            } else if (d.ds.store != null) d.ds.schedule(d, o.backup_delay_ms, .backup, d.changes);
        }

        pub fn timer(d: *Self, kind: Ds.Kind, gen: u32) void {
            switch (kind) {
                .autosave => if (gen == d.autosave_gen and d.edited) d.autosaveNow(),
                .autosave_max => {
                    d.autosave_max_set = false;
                    if (d.edited) d.autosaveNow();
                },
                .backup => if (gen == d.changes) d.backup(),
                .watch => d.checkDisk(),
            }
        }

        /// Saves in place now (autosave): if it can't, the recovery copy
        /// keeps the changes.
        pub fn autosaveNow(d: *Self) void {
            if (!d.autosaves() or !d.writeInPlace(.autosave)) d.backup();
        }

        /// Writes the document to its file; false if it didn't (another
        /// app changed the file and `op` is autosave, or an error).
        pub fn writeInPlace(d: *Self, op: WriteOp) bool {
            const p = d.path orelse return false;
            d.writeTo(p, op) catch return false;
            return true;
        }

        /// Writes the content to `target`, which the document then is.
        pub fn writeTo(d: *Self, target: []const u8, op: WriteOp) !void {
            const ds = d.ds;
            const same_file = if (d.path) |p| std.mem.eql(u8, p, target) else false;
            if (same_file and op != .save_anyway) {
                if (file.stampOf(ds.io, target)) |now| if (!now.eql(d.stamp)) {
                    d.conflict = true;
                    d.notify();
                    return error.DocumentChanged;
                };
            }
            var aw: std.Io.Writer.Allocating = .init(ds.gpa);
            defer aw.deinit();
            try ds.opts.write(ds.gpa, &d.content, &aw.writer);
            const changes = d.changes;
            d.stamp = try file.writeSafely(ds.gpa, ds.io, target, aw.written());
            if (!same_file) {
                try d.setPath(target);
                d.untitled = 0;
                d.watch();
            }
            try d.keepSaved(aw.written());
            d.read_only = false;
            d.conflict = false;
            d.deleted = false;
            if (d.changes == changes) {
                d.edited = false;
                d.forgetCopy();
            }
            ds.host.addRecent(target);
            d.notify();
        }

        /// Keeps the content `bytes` make, the file's, for `equal`.
        pub fn keepSaved(d: *Self, bytes: []const u8) !void {
            const eq = d.ds.opts.equal;
            if (eq == null) return;
            const v = try d.ds.opts.read(d.ds.gpa, bytes);
            if (d.saved) |s| if (d.ds.opts.free) |f| f(d.ds.gpa, s);
            d.saved = v;
        }

        pub fn setPath(d: *Self, p: []const u8) !void {
            const owned = try d.ds.gpa.dupe(u8, p);
            if (d.path) |old| d.ds.gpa.free(old);
            d.path = owned;
        }

        /// As File > Save: an untitled document asks where, a read-only one
        /// for another file, one whose file another app changed whether to
        /// overwrite it. Returns false when it isn't saved (canceled).
        pub fn save(d: *Self) bool {
            return d.saveInteractive(false);
        }

        /// As File > Save As: asks where, unless `path` is given.
        pub fn saveAs(d: *Self, path: ?[]const u8) bool {
            if (path) |p| {
                d.writeTo(p, .save_anyway) catch |err| {
                    d.ds.showError(d.window, p, err);
                    return false;
                };
                return true;
            }
            return d.saveInteractive(true);
        }

        /// Writes it even when another app changed its file.
        pub fn saveAnyway(d: *Self) bool {
            const p = d.path orelse return d.saveInteractive(true);
            d.writeTo(p, .save_anyway) catch |err| {
                d.ds.showError(d.window, p, err);
                return false;
            };
            return true;
        }

        pub fn saveInteractive(d: *Self, as: bool) bool {
            const ds = d.ds;
            if (as or d.path == null or d.read_only) {
                const target = d.askPath() orelse return false;
                defer ds.gpa.free(target);
                d.writeTo(target, .save_anyway) catch |err| {
                    ds.showError(d.window, target, err);
                    return false;
                };
                return true;
            }
            const p = d.path.?;
            d.writeTo(p, .save) catch |err| switch (err) {
                error.DocumentChanged => return d.resolveConflict(),
                else => {
                    ds.showError(d.window, p, err);
                    return false;
                },
            };
            return true;
        }

        /// Another app changed the file: save this version anyway, or
        /// revert to the other app's.
        fn resolveConflict(d: *Self) bool {
            const ds = d.ds;
            const s = ds.opts.strings;
            var arena = std.heap.ArenaAllocator.init(ds.gpa);
            defer arena.deinit();
            const b = host_mod.SaveButtons.of(s.save_anyway, s.revert, s.cancel);
            const i = ds.host.message(d.window, .{ .title = host_mod.fill(arena.allocator(), s.changed_on_disk, d.name()), .detail = s.changed_on_disk_detail, .kind = .warning, .buttons = &b.labels });
            return switch (host_mod.answerOf(b, i)) {
                .save => d.saveAnyway(),
                .discard => blk: {
                    d.revert() catch break :blk false;
                    break :blk true;
                },
                .cancel => false,
            };
        }

        fn askPath(d: *Self) ?[]u8 {
            const ds = d.ds;
            var buf: [256]u8 = undefined;
            const ext = ds.opts.types[0].extensions[0];
            const suggested = if (d.path) |p| file.displayName(p) else std.fmt.bufPrint(&buf, "{s}.{s}", .{ d.name(), ext }) catch d.name();
            const dir = if (d.path) |p| std.fs.path.dirname(p) orelse "" else "";
            const got = ds.host.savePath(ds.gpa, d.window, .{ .title = ds.opts.strings.save_as, .name = suggested, .directory = dir, .extensions = ds.extensions }) orelse return null;
            if (std.fs.path.extension(got).len > 0) return got;
            defer ds.gpa.free(got);
            return file.withExtension(ds.gpa, got, ext) catch null;
        }

        /// Reads its file again, dropping its unsaved changes.
        pub fn revert(d: *Self) !void {
            const ds = d.ds;
            const p = d.path orelse return error.Untitled;
            const bytes = try file.readAll(ds.gpa, ds.io, p, ds.opts.max_size);
            defer ds.gpa.free(bytes);
            const v = try ds.opts.read(ds.gpa, bytes);
            d.freeContent();
            d.content = v;
            d.stamp = file.stampOf(ds.io, p) orelse .{};
            try d.keepSaved(bytes);
            d.edited = false;
            d.conflict = false;
            d.deleted = false;
            d.read_only = !file.writable(ds.io, p);
            d.changes +%= 1;
            d.forgetCopy();
            if (d.on_reload) |h| h.call(d);
            d.notify();
        }

        /// An untitled copy of it, in a window of its own ("Notes copy").
        pub fn duplicate(d: *Self) !*Self {
            const ds = d.ds;
            var aw: std.Io.Writer.Allocating = .init(ds.gpa);
            defer aw.deinit();
            try ds.opts.write(ds.gpa, &d.content, &aw.writer);
            const copy = try ds.add(try ds.opts.read(ds.gpa, aw.written()));
            copy.untitled = 1;
            if (d.path == null) copy.untitled = d.untitled;
            copy.edited = true;
            try ds.show(copy);
            copy.scheduleSaves();
            return copy;
        }

        /// Renames its file in its folder (`new_name` is a file name).
        pub fn rename(d: *Self, new_name: []const u8) !void {
            const p = d.path orelse return error.Untitled;
            const dir = std.fs.path.dirname(p) orelse ".";
            const target = try std.fs.path.join(d.ds.gpa, &.{ dir, new_name });
            defer d.ds.gpa.free(target);
            try d.relocate(target);
        }

        /// Moves its file to the folder `dir`.
        pub fn moveTo(d: *Self, dir: []const u8) !void {
            const p = d.path orelse return error.Untitled;
            const target = try std.fs.path.join(d.ds.gpa, &.{ dir, file.displayName(p) });
            defer d.ds.gpa.free(target);
            try d.relocate(target);
        }

        fn relocate(d: *Self, target: []const u8) !void {
            const ds = d.ds;
            if (file.stampOf(ds.io, target) != null) return error.PathAlreadyExists;
            const cwd = std.Io.Dir.cwd();
            try cwd.rename(d.path.?, cwd, target, ds.io);
            try d.setPath(target);
            d.watch();
            ds.host.addRecent(target);
            d.notify();
        }

        /// Closes its window, asking to save first where it must. Returns
        /// false when it stays open (the user canceled, saving failed).
        pub fn close(d: *Self) bool {
            if (d.edited) {
                const saved = d.autosaves() and d.writeInPlace(.autosave);
                if (!saved and !d.askToSave()) return false;
            }
            d.forgetCopy();
            const ds = d.ds;
            if (d.window) |w| {
                d.window = null;
                ds.host.closeWindow(w);
            }
            ds.drop(d);
            return true;
        }

        /// Asks whether to save its changes before it closes, saves or
        /// discards them, and tells whether it may close.
        pub fn askToSave(d: *Self) bool {
            const ds = d.ds;
            const s = ds.opts.strings;
            var arena = std.heap.ArenaAllocator.init(ds.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var b: host_mod.SaveButtons = undefined;
            var opts: host_mod.MessageOptions = .{ .title = "", .kind = .warning };
            if (d.path == null and ds.opts.autosave == .in_place) {
                b = .of(s.save_ellipsis, s.delete, s.cancel);
                opts.title = host_mod.fill(a, s.keep_new, d.name());
                opts.detail = s.keep_new_detail;
            } else {
                b = .of(if (d.path == null) s.save_ellipsis else s.save, s.dont_save, s.cancel);
                opts.title = host_mod.fill(a, s.save_changes, d.name());
                opts.detail = s.changes_lost;
            }
            opts.buttons = &b.labels;
            return switch (host_mod.answerOf(b, ds.host.message(d.window, opts))) {
                .save => d.saveInteractive(false),
                .discard => blk: {
                    d.discard();
                    break :blk true;
                },
                .cancel => false,
            };
        }

        /// Drops its unsaved changes as it closes.
        pub fn discard(d: *Self) void {
            d.discarded = true;
            d.forgetCopy();
        }

        /// Writes its recovery copy, if it changed since the last.
        pub fn backup(d: *Self) void {
            const ds = d.ds;
            const store = if (ds.store) |*s| s else return;
            if (!d.edited or (d.backed_up == d.changes and store.has(&d.copy_id))) return;
            var aw: std.Io.Writer.Allocating = .init(ds.gpa);
            defer aw.deinit();
            ds.opts.write(ds.gpa, &d.content, &aw.writer) catch return;
            store.save(.{ .id = &d.copy_id, .path = d.path orelse "", .name = if (d.path == null) d.name() else "", .stamp = d.stamp }, aw.written()) catch return;
            d.backed_up = d.changes;
        }

        pub fn forgetCopy(d: *Self) void {
            if (d.ds.store) |*s| s.remove(&d.copy_id);
        }

        /// Looks at its file: one without unsaved changes reads it again
        /// (`on_reload`); one with is in conflict; a deleted file leaves
        /// it open, `deleted`, and saving writes it again.
        pub fn checkDisk(d: *Self) void {
            const ds = d.ds;
            if (file.stampOf(ds.io, d.path orelse return) == null) d.followRename();
            const p = d.path.?;
            const now = file.stampOf(ds.io, p) orelse {
                if (!d.deleted) {
                    d.deleted = true;
                    d.notify();
                }
                return;
            };
            if (d.deleted) {
                d.deleted = false;
                d.notify();
            }
            if (now.eql(d.stamp)) return;
            if (!d.edited) {
                d.revert() catch {};
                return;
            }
            if (!d.conflict) {
                d.conflict = true;
                // The changes stay in the recovery copy, not the file.
                d.backup();
                d.notify();
            }
        }

        /// Its file went away: where another app renamed it in its folder,
        /// found by the identity of the file it last read or wrote (one
        /// that replaced the file it opened, as an editor's save does, and
        /// was renamed after: the stamp is of the last it saw), the
        /// document follows it, as it follows its own `rename`.
        fn followRename(d: *Self) void {
            const ds = d.ds;
            const id = d.stamp.file orelse return;
            const dir = std.fs.path.dirname(d.path.?) orelse return;
            const moved = file.findRenamed(ds.gpa, ds.io, dir, id) orelse return;
            defer ds.gpa.free(moved);
            d.setPath(moved) catch return;
            d.watch();
            ds.host.addRecent(moved);
            d.notify();
        }

        /// Watches its file for other apps' changes.
        pub fn watch(d: *Self) void {
            d.unwatch();
            const p = d.path orelse return;
            const t = d.ds.gpa.create(Ds.Tick) catch return;
            t.* = .{ .ds = d.ds, .doc = d.id, .gen = 0, .kind = .watch };
            d.watch_id = d.ds.host.watch(p, t, onWatch);
            if (d.watch_id == null) {
                d.ds.gpa.destroy(t);
                return;
            }
            d.watch_tick = t;
        }

        fn unwatch(d: *Self) void {
            if (d.watch_id) |id| d.ds.host.unwatch(id);
            d.watch_id = null;
            if (d.watch_tick) |t| d.ds.gpa.destroy(t);
            d.watch_tick = null;
        }

        fn onWatch(arg: ?*anyopaque) callconv(.c) void {
            const t: *Ds.Tick = @ptrCast(@alignCast(arg));
            for (t.ds.docs.items) |d| if (d.id == t.doc) return d.checkDisk();
        }

        /// Shows the state: the window's title, then the app's handlers.
        pub fn notify(d: *Self) void {
            const ds = d.ds;
            if (d.window) |w| {
                var buf: [256]u8 = undefined;
                ds.host.setTitle(w, file.windowTitle(&buf, d.name(), ds.opts.app_name, d.edited));
            }
            if (d.on_state) |h| h.call(d);
            if (ds.on_change) |h| h.call(d);
        }
    };
}
