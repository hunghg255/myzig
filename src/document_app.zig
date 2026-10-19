//! Documents in a real app: the `Host` made of a `myzig.App` (its dialogs,
//! timers, windows, file watches, recent documents), its document windows'
//! closing, and the File menu.
//!
//!     var docs_host: myzig.DocumentHost = .{ .app = app };
//!     const notes = try myzig.Documents(Note).create(gpa, io, docs_host.host(), .{ ... });
//!     defer notes.destroy();
//!     app.options.on_open_file = .of(notes, @TypeOf(notes.*).openFile);
//!     docs_host.start(@TypeOf(notes.*), notes); // after the files the app was started with
//!     try app.setMenu(&.{ .{ .role = .app_menu }, docs_host.fileMenu(@TypeOf(notes.*), notes), .{ .role = .edit_menu } });
//!
//! In the window maker, `docs_host.attach(Ds, notes, win)` makes closing the
//! window close its document.
const std = @import("std");
const builtin = @import("builtin");
const host_mod = @import("document_host.zig");
const file_watch = @import("file_watch.zig");
const system = @import("system.zig");

pub fn AppHost(comptime App: type, comptime Window: type, comptime dialog: type, comptime menu: type) type {
    const MenuItem = menu.MenuItem;
    const MenuClick = menu.Click;
    return struct {
        const Self = @This();
        app: *App,
        watches: std.AutoHashMapUnmanaged(host_mod.WatchId, *file_watch.Watch) = .empty,
        next_watch: host_mod.WatchId = 1,
        /// What the File menu shows, kept while the menu shows it.
        recent: [][]u8 = &.{},
        recent_items: []MenuItem = &.{},

        pub fn deinit(self: *Self) void {
            var it = self.watches.valueIterator();
            while (it.next()) |w| w.*.cancel();
            self.watches.deinit(self.app.gpa);
            self.freeRecent();
        }

        fn freeRecent(self: *Self) void {
            for (self.recent) |p| self.app.gpa.free(p);
            if (self.recent.len > 0) self.app.gpa.free(self.recent);
            if (self.recent_items.len > 0) self.app.gpa.free(self.recent_items);
            self.recent = &.{};
            self.recent_items = &.{};
        }

        pub fn host(self: *Self) host_mod.Host(Window) {
            return .{ .ctx = self, .vtable = &vtable };
        }

        const vtable: host_mod.Host(Window).VTable = .{
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

        fn of(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }
        fn message(_: *anyopaque, _: ?*Window, opts: host_mod.MessageOptions) usize {
            return dialog.message(opts).button;
        }
        fn savePath(_: *anyopaque, gpa: std.mem.Allocator, _: ?*Window, opts: host_mod.SaveOptions) ?[]u8 {
            return dialog.save(gpa, opts) catch null;
        }
        fn openPaths(_: *anyopaque, gpa: std.mem.Allocator, opts: host_mod.OpenOptions) ?[][]u8 {
            return dialog.open(gpa, opts) catch null;
        }
        fn after(_: *anyopaque, ms: u64, arg: ?*anyopaque, func: host_mod.TimerFn) void {
            App.after(ms, arg, func);
        }
        fn setTitle(_: *anyopaque, w: *Window, title: []const u8) void {
            w.setTitle(title);
        }
        fn closeWindow(_: *anyopaque, w: *Window) void {
            w.close();
        }
        fn focusWindow(_: *anyopaque, w: *Window) void {
            w.focus();
        }
        fn focusedWindow(ctx: *anyopaque) ?*Window {
            const app = of(ctx).app;
            if (@hasDecl(App, "keyWindow")) return app.keyWindow();
            for (app.windows.items) |w| if (w.isFocused()) return w;
            return null;
        }
        fn watch(ctx: *anyopaque, path: []const u8, arg: ?*anyopaque, func: host_mod.TimerFn) ?host_mod.WatchId {
            const self = of(ctx);
            const w = file_watch.watch(path, arg, func) catch return null;
            const id = self.next_watch;
            self.next_watch +%= 1;
            self.watches.put(self.app.gpa, id, w) catch {
                w.cancel();
                return null;
            };
            return id;
        }
        fn unwatch(ctx: *anyopaque, id: host_mod.WatchId) void {
            const self = of(ctx);
            if (self.watches.fetchRemove(id)) |kv| kv.value.cancel();
        }
        fn addRecent(ctx: *anyopaque, path: []const u8) void {
            system.addRecentDocument(of(ctx).app, path) catch {};
        }
        fn quit(ctx: *anyopaque) void {
            of(ctx).app.quit();
        }

        /// Makes closing `w` close its document: what the window's close
        /// button does (its changes stay in the recovery copy until windows
        /// can ask before they close). The window's own `on_close` still runs.
        pub fn attach(self: *Self, comptime Ds: type, ds: *Ds, w: *Window) !void {
            const Link = struct {
                ds: *Ds,
                prev: ?@TypeOf(w.on_close.?),
                gpa: std.mem.Allocator,
                fn closed(ctx: *anyopaque, win: *Window) void {
                    const l: *@This() = @ptrCast(@alignCast(ctx));
                    l.ds.windowClosed(win);
                    if (l.prev) |p| p.func(p.ctx, win);
                    l.gpa.destroy(l);
                }
            };
            const l = try self.app.gpa.create(Link);
            l.* = .{ .ds = ds, .prev = w.on_close, .gpa = self.app.gpa };
            w.on_close = .{ .ctx = l, .func = Link.closed };
        }

        /// Opens what the app starts with, once the files it was started
        /// with reached `on_open_file` (in the first turn of the loop).
        pub fn start(_: *Self, comptime Ds: type, ds: *Ds) void {
            App.after(0, ds, struct {
                fn run(arg: ?*anyopaque) callconv(.c) void {
                    const d: *Ds = @ptrCast(@alignCast(arg));
                    d.start(&.{}) catch {};
                }
            }.run);
        }

        /// The File menu: New, Open…, Open Recent, Save, Save As…, Revert,
        /// Close, as Notepad and KDE have it (DocumentGroup's order on
        /// macOS). Build it again (and `App.setMenu`) when Open Recent
        /// changes (`Documents.on_change`).
        pub fn fileMenu(self: *Self, comptime Ds: type, ds: *Ds) MenuItem {
            const C = Clicks(Ds);
            self.freeRecent();
            self.recent = system.recentDocuments(self.app) catch &.{};
            const gpa = self.app.gpa;
            if (gpa.alloc(MenuItem, self.recent.len + 2)) |items| {
                for (self.recent, 0..) |p, i| items[i] = .{ .label = std.fs.path.basename(p), .id = p, .click = C.click(ds, C.openRecent) };
                items[self.recent.len] = .separator;
                items[self.recent.len + 1] = .{ .label = "Clear Menu", .id = "documents.clear_recent", .click = C.click(ds, C.clearRecent) };
                self.recent_items = items;
            } else |_| {}
            C.fill(self, ds);
            return .{ .label = "File", .submenu = &C.items };
        }

        fn Clicks(comptime Ds: type) type {
            return struct {
                const Item = *menu.Item;
                var items: [10]MenuItem = undefined;

                fn click(ds: *Ds, comptime f: fn (*Ds, Item) void) MenuClick {
                    return .{ .ctx = ds, .func = struct {
                        fn call(ctx: *anyopaque, item: Item) void {
                            f(@ptrCast(@alignCast(ctx)), item);
                        }
                    }.call };
                }

                fn fill(self: *Self, ds: *Ds) void {
                    const mac = builtin.os.tag == .macos;
                    items = .{
                        .{ .label = "New", .accelerator = "CmdOrCtrl+N", .id = "documents.new", .click = click(ds, new) },
                        .{ .label = "Open…", .accelerator = "CmdOrCtrl+O", .id = "documents.open", .click = click(ds, open) },
                        .{ .label = "Open Recent", .id = "documents.recent", .submenu = self.recent_items, .disabled = self.recent.len == 0 },
                        .separator,
                        .{ .label = "Save", .accelerator = "CmdOrCtrl+S", .id = "documents.save", .click = click(ds, save) },
                        .{ .label = "Save As…", .accelerator = if (mac) "Alt+Shift+Cmd+S" else "CmdOrCtrl+Shift+S", .id = "documents.save_as", .click = click(ds, saveAs) },
                        .{ .label = if (mac) "Revert to Saved" else "Revert", .id = "documents.revert", .click = click(ds, revert) },
                        .separator,
                        .{ .label = "Close", .accelerator = "CmdOrCtrl+W", .id = "documents.close", .click = click(ds, close) },
                        if (mac) .separator else .{ .role = .quit },
                    };
                }

                fn new(ds: *Ds, _: Item) void {
                    _ = ds.new() catch {};
                }
                fn open(ds: *Ds, _: Item) void {
                    ds.openDialog();
                }
                fn openRecent(ds: *Ds, item: Item) void {
                    _ = ds.open(item.id) catch |err| ds.showError(null, item.id, err);
                }
                fn clearRecent(ds: *Ds, _: Item) void {
                    const h: *Self = @ptrCast(@alignCast(ds.host.ctx));
                    system.clearRecentDocuments(h.app);
                }
                fn save(ds: *Ds, _: Item) void {
                    if (ds.focused()) |d| _ = d.save();
                }
                fn saveAs(ds: *Ds, _: Item) void {
                    if (ds.focused()) |d| _ = d.saveAs(null);
                }
                fn revert(ds: *Ds, _: Item) void {
                    if (ds.focused()) |d| d.revert() catch {};
                }
                fn close(ds: *Ds, _: Item) void {
                    if (ds.focused()) |d| _ = d.close();
                }
            };
        }
    };
}
