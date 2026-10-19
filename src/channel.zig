//! Typed channels between Zig and pages. A bound method takes one the
//! page made:
//!
//!     pub fn tail(_: *Shell, lines: myzig.Channel([]const u8)) void {
//!         keep = lines; // send later, as the lines come
//!     }
//!
//!     const lines = new Channel<string>();
//!     Shell.tail(lines);
//!     for await (const line of lines) output.append(line);
//!
//! or Zig opens one, which the page hears of with the generated
//! `onLogsChannel(fn)` of `const Logs = myzig.ChannelKind("logs", Line)`
//! (registered with `app.registerEvent(Logs)`). Either side sends values
//! of `T`, and closes it; navigating away closes the page's channels.
//! Main thread only.
const std = @import("std");
const builtin = @import("builtin");
const tsgen = @import("tsgen.zig");
const ipc = @import("ipc.zig");
const reg = @import("page_channel.zig");
const Window = ipc.Window;
/// The platform's page: a window's, or a web view's in its native UI.
const Page = @typeInfo(@FieldType(Window, "page")).optional.child;

pub const CloseReason = reg.CloseReason;

pub fn Channel(comptime T: type) type {
    return struct {
        window: *Window,
        /// The page it belongs to (the window's, or one of its web views).
        page: Page,
        id: i64,
        /// The page's document it belongs to.
        generation: u32,

        const Self = @This();
        pub const myzig_channel = T;

        /// The channel the page passed to a call as `arg` (its id).
        pub fn fromArg(window: *Window, arg: std.json.Value) !Self {
            return fromArgOf(window, null, arg);
        }

        /// As `fromArg`, from the page that called (null: the window's).
        pub fn fromArgOf(window: *Window, from: ?Page, arg: std.json.Value) !Self {
            const id: i64 = switch (arg) {
                .integer => |i| i,
                else => return error.InvalidArgument,
            };
            if (id <= 0) return error.InvalidArgument;
            const page = from orelse window.page orelse return error.NoPage;
            _ = try page.core.channels.ensure(window.app.gpa, id);
            return .{ .window = window, .page = page, .id = id, .generation = page.core.generation };
        }

        /// Opens a channel to the window's page, which its listeners of
        /// `name` get (`myzig.onChannel(name, fn)`).
        pub fn open(window: *Window, name: []const u8) !Self {
            const page = window.page orelse return error.NoPage;
            const gpa = window.app.gpa;
            const opened = try page.core.channels.open(gpa, name);
            defer gpa.free(opened[1]);
            page.enqueue(opened[1], true);
            return .{ .window = window, .page = page, .id = opened[0].id, .generation = page.core.generation };
        }

        fn entry(self: Self) ?*reg.Entry {
            // The window and its page may have closed meanwhile.
            if (!ipc.stillOpen(self.window.app, self.window, self.page)) return null;
            if (self.page.core.generation != self.generation) return null;
            return self.page.core.channels.get(self.id);
        }

        pub fn isOpen(self: Self) bool {
            return self.entry() != null;
        }

        /// Sends `value` to the page. Fails once the channel is closed, and
        /// while the page has a window of bytes yet to take (`onDrain`).
        pub fn send(self: Self, value: T) error{ ChannelClosed, ChannelFull, OutOfMemory }!void {
            const e = self.entry() orelse return error.ChannelClosed;
            const gpa = self.window.app.gpa;
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            ipc.writeJson(value, &aw.writer) catch return error.OutOfMemory;
            const page = self.page;
            const msg = try page.core.channels.encodeValue(gpa, e, aw.written());
            defer gpa.free(msg);
            page.enqueue(msg, true);
        }

        /// Closes the channel; the page's iteration ends after the values sent.
        pub fn close(self: Self) void {
            if (self.entry() == null) return;
            const page = self.page;
            const gpa = self.window.app.gpa;
            if (page.core.channels.close(gpa, self.id, .zig)) |m| {
                defer gpa.free(m);
                page.enqueue(m, true);
            }
        }

        /// Calls `func(ptr, channel, value)` for each value the page sends.
        pub fn onMessage(self: Self, ptr: anytype, comptime func: fn (@TypeOf(ptr), Self, T) void) void {
            const e = self.entry() orelse return;
            const P = @TypeOf(ptr);
            const Impl = struct {
                fn call(ctx: ?*anyopaque, id: i64, json: []const u8) void {
                    const h: *Handle = @ptrCast(@alignCast(ctx));
                    const win: *Window = @ptrCast(@alignCast(h.window));
                    var arena: std.heap.ArenaAllocator = .init(win.app.gpa);
                    defer arena.deinit();
                    const v = std.json.parseFromSliceLeaky(T, arena.allocator(), json, .{ .ignore_unknown_fields = true }) catch {
                        std.log.warn("myzig: channel {d}: a value that is not a {s}", .{ id, @typeName(T) });
                        return;
                    };
                    func(@as(P, @ptrCast(@alignCast(h.ptr))), .{ .window = @ptrCast(@alignCast(h.window)), .page = @ptrCast(@alignCast(h.page)), .id = id, .generation = h.generation }, v);
                }
            };
            const h = handle(self, @ptrCast(@constCast(ptr))) orelse return;
            e.on_message = .{ .ctx = h, .func = Impl.call };
        }

        /// Calls `func(ptr, channel, reason)` once the channel closes.
        pub fn onClose(self: Self, ptr: anytype, comptime func: fn (@TypeOf(ptr), Self, CloseReason) void) void {
            const e = self.entry() orelse return;
            const P = @TypeOf(ptr);
            const Impl = struct {
                fn call(ctx: ?*anyopaque, id: i64, reason: CloseReason) void {
                    const h: *Handle = @ptrCast(@alignCast(ctx));
                    func(@as(P, @ptrCast(@alignCast(h.ptr))), .{ .window = @ptrCast(@alignCast(h.window)), .page = @ptrCast(@alignCast(h.page)), .id = id, .generation = h.generation }, reason);
                }
            };
            const h = handle(self, @ptrCast(@constCast(ptr))) orelse return;
            e.on_close = .{ .ctx = h, .func = Impl.call };
        }

        /// Calls `func(ptr, channel)` when the page took enough values that
        /// a send which failed with `error.ChannelFull` would succeed.
        pub fn onDrain(self: Self, ptr: anytype, comptime func: fn (@TypeOf(ptr), Self) void) void {
            const e = self.entry() orelse return;
            const P = @TypeOf(ptr);
            const Impl = struct {
                fn call(ctx: ?*anyopaque, id: i64, _: CloseReason) void {
                    const h: *Handle = @ptrCast(@alignCast(ctx));
                    func(@as(P, @ptrCast(@alignCast(h.ptr))), .{ .window = @ptrCast(@alignCast(h.window)), .page = @ptrCast(@alignCast(h.page)), .id = id, .generation = h.generation });
                }
            };
            const h = handle(self, @ptrCast(@constCast(ptr))) orelse return;
            e.on_drain = .{ .ctx = h, .func = Impl.call };
        }
    };
}

const Handle = reg.Handle;

fn handle(ch: anytype, ptr: *anyopaque) ?*Handle {
    const page = ch.page;
    const gpa = ch.window.app.gpa;
    const h = gpa.create(Handle) catch return null;
    h.* = .{ .window = ch.window, .page = page, .generation = ch.generation, .ptr = ptr };
    page.core.handles.append(gpa, h) catch {
        gpa.destroy(h);
        return null;
    };
    return h;
}

/// A kind of channel Zig opens to pages, declared for the generated client
/// (`onLogsChannel`): `const Logs = myzig.ChannelKind("logs", Line);`.
pub fn ChannelKind(comptime kind_name: []const u8, comptime T: type) type {
    return struct {
        pub const name = kind_name;
        pub const client = tsgen.channelKind(kind_name, T);

        pub fn open(window: *Window) !Channel(T) {
            return Channel(T).open(window, kind_name);
        }
    };
}
