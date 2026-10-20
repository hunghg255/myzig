//! A terminal and the program it runs: the emulator (`vt.Vt`), the
//! pseudo-terminal, and the threads that read the program's output into
//! the emulator and write what is typed to the program. Its methods are
//! for the main thread; the emulator is shared with the reader under
//! `lock`. Events (output, title, bell, exit) reach the app on the main
//! thread through `Options.on_event`, posted with the mainthread plugin.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const vt = @import("vt.zig");
const ptys = @import("pty.zig");
const library = @import("library.zig");
const Theme = @import("theme.zig").Theme;
const waker = @import("waker.zig");
const encode = @import("encode.zig");

/// `.notify`: a program asked for a desktop notification (OSC 9, OSC
/// 777), whose text `notification` gives.
pub const Event = enum { output, title, bell, exit, notify };

pub const EventHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, t: *Terminal, ev: Event) void,
};

pub const Options = struct {
    /// The program and its arguments: the user's shell when empty (`$SHELL`,
    /// else /bin/zsh on macOS and /bin/sh elsewhere; PowerShell on Windows).
    /// Kept by the caller until the program starts.
    command: []const []const u8 = &.{},
    /// The working directory: this process's when null.
    dir: ?[]const u8 = null,
    /// Variables added to the environment ("KEY=value"), over TERM,
    /// COLORTERM and LANG, which the terminal sets.
    env: []const []const u8 = &.{},
    /// No program: the terminal shows what `feed` gives it.
    no_program: bool = false,
    /// The colors in light and dark windows; the window's when null.
    theme: ?Theme = null,
    dark_theme: ?Theme = null,
    cursor: vt.CursorStyle = .block,
    /// About how many bytes of output to keep above the screen.
    scrollback: usize = 10 << 20,
    /// The text's size in points (DIPs). The font options may change while
    /// the terminal shows: the grid follows them.
    font_size: f32 = 13,
    /// A family other than the theme's monospaced one, OpenType features
    /// ("calt=0"), and a weight from 100 to 900 (0: regular), as
    /// `ui.TextStyle` takes them.
    font_family: ?[]const u8 = null,
    font_features: []const u8 = "",
    font_weight: u16 = 0,
    /// Events, on the main thread: what an app redraws its window on
    /// (`.output`), titles it with (`.title`), and closes it on (`.exit`).
    on_event: ?EventHandler = null,
    /// Opens a link Ctrl+click (Command+click on macOS) chose: a hyperlink
    /// (OSC 8), a URL or a file path printed as text. True if it did;
    /// otherwise the system opens URLs.
    open_link: ?*const fn (ctx: ?*anyopaque, link: []const u8, path: bool) bool = null,
    open_link_ctx: ?*anyopaque = null,
    /// Copies what a drag or a double or triple click selects as the pointer
    /// lets go.
    copy_on_select: bool = false,
    /// Reads the clipboard's text for a paste: the system's when null.
    read_clipboard: ?*const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 = null,
    read_clipboard_ctx: ?*anyopaque = null,
};

pub const Terminal = struct {
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
    effects: vt.Effects = .{},
    /// Guards `vt`, `size`, the flags below, and `chunks`.
    lock: Io.Mutex = .init,
    changed: Io.Condition = .init,
    vt: vt.Vt,
    size: [4]u16 = .{ 80, 24, 8, 16 },
    /// Output chunks processed so far: what `waitOutput` waits on.
    chunks: u64 = 0,
    title_changed: bool = false,
    bells: u32 = 0,
    notes: @import("notify.zig").Scanner = .{},
    /// The text of the last notification delivered (main thread).
    note_buf: [512]u8 = undefined,
    note_len: usize = 0,
    exited: bool = false,
    exit_code: i32 = 0,
    started: bool = false,

    pty: ?ptys.Pty = null,
    reader: ?std.Thread = null,
    writer: ?std.Thread = null,
    waiter: ?std.Thread = null,
    /// What is typed, written to the program by `writer` in order: a
    /// program that does not read its input must not block the reader.
    qlock: Io.Mutex = .init,
    qcond: Io.Condition = .init,
    queue: std.ArrayList(u8) = .empty,
    closing: bool = false,
    wake: ?*waker.Waker = null,
    /// What its view keeps between frames.
    view_state: @import("view.zig").State = .{},

    /// Makes a terminal; its program starts at the size the first view
    /// gives it (`resize`), or with `start`.
    pub fn create(gpa: std.mem.Allocator, io: Io, opts: Options) !*Terminal {
        try library.load(gpa, io);
        const t = try gpa.create(Terminal);
        errdefer gpa.destroy(t);
        t.* = .{ .gpa = gpa, .io = io, .opts = opts, .vt = undefined };
        t.effects = .{ .ctx = t, .write_pty = onWritePty, .bell = onBell, .title_changed = onTitle, .size = onSize };
        t.vt = try vt.Vt.init(80, 24, &t.effects);
        t.vt.setTerminfoName("xterm-256color");
        // Grapheme clusters take the cells of their width, as in Ghostty.
        t.vt.setModeDefault(.graphemes, true);
        t.vt.setScrollback(opts.scrollback);
        t.vt.setDefaultCursor(opts.cursor, false);
        // ConPTY keeps a screen of its own, which a resize pulling rows
        // back from the scrollback would disagree with.
        if (builtin.os.tag == .windows and !opts.no_program) t.vt.setResizePullBack(false);
        (opts.theme orelse Theme.light).apply(t.vt);
        if (opts.on_event != null) t.wake = try waker.Waker.create(t, deliver);
        return t;
    }

    /// Hangs up the program and frees the terminal. Main thread.
    pub fn destroy(t: *Terminal) void {
        if (t.pty) |*p| {
            t.lock.lockUncancelable(t.io);
            const ended = t.exited;
            t.lock.unlock(t.io);
            // Windows ends what the console runs as it closes; elsewhere
            // the program's group is killed, which closes the terminal.
            p.hangUp();
            if (!ended and builtin.os.tag != .windows) p.kill();
        }
        if (t.reader) |th| th.join();
        if (t.waiter) |th| th.join();
        t.qlock.lockUncancelable(t.io);
        t.closing = true;
        t.qcond.broadcast(t.io);
        t.qlock.unlock(t.io);
        if (t.writer) |th| th.join();
        if (t.pty) |*p| p.deinit();
        if (t.wake) |w| w.kill();
        t.view_state.deinit();
        t.queue.deinit(t.gpa);
        t.vt.deinit();
        t.gpa.destroy(t);
    }

    /// Starts the program, once, at the terminal's size. Main thread.
    pub fn start(t: *Terminal) void {
        if (t.started or t.opts.no_program) return;
        t.started = true;
        var arena_state: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        t.launch(arena) catch |err| {
            t.lock.lockUncancelable(t.io);
            t.vt.write(std.fmt.allocPrint(arena, "\x1b[31mterminal: {s}\x1b[0m", .{@errorName(err)}) catch "\x1b[31mterminal: error\x1b[0m");
            t.exited = true;
            t.exit_code = -1;
            t.lock.unlock(t.io);
            t.post(.exit);
        };
    }

    fn launch(t: *Terminal, arena: std.mem.Allocator) !void {
        var argv: []const []const u8 = t.opts.command;
        if (argv.len == 0) {
            const shell = try ptys.defaultShell(arena);
            // A login shell ("-zsh") would need argv[0] apart from the
            // program: the shell runs as a plain interactive one.
            argv = try arena.dupe([]const u8, &.{shell});
        }
        var env: std.ArrayList([]const u8) = .empty;
        try env.appendSlice(arena, &.{ "TERM=xterm-256color", "COLORTERM=truecolor" });
        if (builtin.os.tag != .windows and std.c.getenv("LANG") == null and std.c.getenv("LC_ALL") == null)
            try env.append(arena, "LANG=en_US.UTF-8");
        try env.appendSlice(arena, t.opts.env);
        const s = t.size;
        t.pty = try ptys.Pty.start(t.gpa, t.io, .{
            .argv = argv,
            .dir = t.opts.dir,
            .env = env.items,
            .cols = s[0],
            .rows = s[1],
            .width = s[0] *| s[2],
            .height = s[1] *| s[3],
        });
        t.reader = try std.Thread.spawn(.{}, readLoop, .{t});
        t.waiter = try std.Thread.spawn(.{}, waitLoop, .{t});
        t.writer = try std.Thread.spawn(.{}, writeLoop, .{t});
    }

    fn readLoop(t: *Terminal) void {
        var buf: [64 << 10]u8 = undefined;
        const p = &t.pty.?;
        while (true) {
            const n = p.read(&buf);
            if (n == 0) break;
            t.lock.lockUncancelable(t.io);
            t.vt.write(buf[0..n]);
            t.notes.feed(buf[0..n]);
            t.chunks += 1;
            t.changed.broadcast(t.io);
            t.lock.unlock(t.io);
            t.post(.output);
        }
        // The program's output ended: once it exited, say so.
        if (t.waiter) |th| {
            th.join();
            t.waiter = null;
        }
        t.lock.lockUncancelable(t.io);
        var msg_buf: [64]u8 = undefined;
        const msg = if (t.exit_code == 0) "[Process exited]" else std.fmt.bufPrint(&msg_buf, "[Process exited with code {d}]", .{t.exit_code}) catch "[Process exited]";
        if (t.vt.cursor()[0] > 0) t.vt.write("\r\n");
        t.vt.write("\x1b[0;2m");
        t.vt.write(msg);
        t.vt.write("\x1b[0m");
        t.exited = true;
        t.chunks += 1;
        t.changed.broadcast(t.io);
        t.lock.unlock(t.io);
        t.qlock.lockUncancelable(t.io);
        t.closing = true;
        t.qcond.broadcast(t.io);
        t.qlock.unlock(t.io);
        t.post(.exit);
    }

    fn waitLoop(t: *Terminal) void {
        const p = &t.pty.?;
        const code = p.wait();
        t.lock.lockUncancelable(t.io);
        t.exit_code = @bitCast(code);
        t.lock.unlock(t.io);
        // What the program wrote is still to be read; ConPTY then closes
        // its output once the console closes.
        p.hangUp();
    }

    fn writeLoop(t: *Terminal) void {
        var chunk: std.ArrayList(u8) = .empty;
        defer chunk.deinit(t.gpa);
        while (true) {
            t.qlock.lockUncancelable(t.io);
            while (t.queue.items.len == 0 and !t.closing) t.qcond.waitUncancelable(t.io, &t.qlock);
            if (t.closing) {
                t.qlock.unlock(t.io);
                return;
            }
            std.mem.swap(std.ArrayList(u8), &chunk, &t.queue);
            t.qlock.unlock(t.io);
            t.pty.?.write(chunk.items) catch return;
            chunk.clearRetainingCapacity();
        }
    }

    /// Sends `bytes` to the program as if typed. Any thread.
    pub fn send(t: *Terminal, bytes: []const u8) void {
        if (bytes.len == 0) return;
        t.qlock.lockUncancelable(t.io);
        defer t.qlock.unlock(t.io);
        if (t.closing) return;
        t.queue.appendSlice(t.gpa, bytes) catch return;
        t.qcond.signal(t.io);
    }

    /// Pastes `data`: bracketed when the program asks (mode 2004), so that
    /// pasted lines do not run as commands. Main thread.
    pub fn paste(t: *Terminal, data: []const u8) void {
        t.lock.lockUncancelable(t.io);
        const bracketed = t.vt.mode(.bracketed_paste);
        t.vt.scrollToBottom();
        t.lock.unlock(t.io);
        const bytes = encode.paste(t.gpa, data, bracketed) catch return;
        defer t.gpa.free(bytes);
        t.send(bytes);
    }

    /// The last notification's text (its title and body), as `.notify` said.
    pub fn notification(t: *const Terminal) []const u8 {
        return t.note_buf[0..t.note_len];
    }

    /// Shows `bytes` as if the program wrote them: text and escape sequences.
    pub fn feed(t: *Terminal, bytes: []const u8) void {
        t.lock.lockUncancelable(t.io);
        t.vt.write(bytes);
        t.chunks += 1;
        t.changed.broadcast(t.io);
        t.lock.unlock(t.io);
    }

    /// Sets the size of the screen in cells and of a cell in pixels; the
    /// program starts at the first. Main thread.
    pub fn resize(t: *Terminal, cols: u16, rows: u16, cell_w: u16, cell_h: u16) void {
        const s: [4]u16 = .{ @max(cols, 1), @max(rows, 1), @max(cell_w, 1), @max(cell_h, 1) };
        t.lock.lockUncancelable(t.io);
        const same = std.mem.eql(u16, &s, &t.size);
        if (!same) {
            t.size = s;
            t.vt.resize(s[0], s[1], s[2], s[3]);
        }
        t.lock.unlock(t.io);
        if (!same) if (t.pty) |*p| p.resize(s[0], s[1], s[0] *| s[2], s[1] *| s[3]);
        if (!t.started) t.start();
    }

    /// Waits until output came after `seen` chunks (or the program
    /// exited), and returns how many chunks have come: for tests and
    /// tools without an event loop. Any thread but the reader.
    pub fn waitOutput(t: *Terminal, seen: u64) u64 {
        t.lock.lockUncancelable(t.io);
        defer t.lock.unlock(t.io);
        while (t.chunks == seen and !t.exited) t.changed.waitUncancelable(t.io, &t.lock);
        return t.chunks;
    }

    /// Whether the program exited, and its exit code (-1 if it never ran).
    pub fn exitCode(t: *Terminal) ?i32 {
        t.lock.lockUncancelable(t.io);
        defer t.lock.unlock(t.io);
        return if (t.exited) t.exit_code else null;
    }

    /// The title the program set, allocated with `gpa`.
    pub fn title(t: *Terminal, gpa: std.mem.Allocator) ![]u8 {
        t.lock.lockUncancelable(t.io);
        defer t.lock.unlock(t.io);
        return gpa.dupe(u8, t.vt.title());
    }

    /// The text of the screen and its scrollback, allocated with `gpa`.
    pub fn text(t: *Terminal, gpa: std.mem.Allocator) []u8 {
        t.lock.lockUncancelable(t.io);
        defer t.lock.unlock(t.io);
        return t.vt.text(gpa);
    }

    /// The state as escape sequences, which restore it in a terminal of
    /// the same size; allocated with `gpa`.
    pub fn snapshot(t: *Terminal, gpa: std.mem.Allocator) ?[]u8 {
        t.lock.lockUncancelable(t.io);
        defer t.lock.unlock(t.io);
        return t.vt.snapshot(gpa);
    }

    fn post(t: *Terminal, ev: Event) void {
        if (t.wake) |w| w.post(@intFromEnum(ev));
    }

    /// Runs on the main thread with the events that came.
    fn deliver(ctx: *anyopaque, events: u32) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        const h = t.opts.on_event orelse return;
        t.lock.lockUncancelable(t.io);
        const titled = t.title_changed;
        t.title_changed = false;
        const bells = t.bells;
        t.bells = 0;
        const noted = t.notes.pending;
        if (noted) {
            t.notes.pending = false;
            t.note_len = t.notes.note_len;
            @memcpy(t.note_buf[0..t.note_len], t.notes.note[0..t.note_len]);
        }
        t.lock.unlock(t.io);
        if (events & (1 << @intFromEnum(Event.output)) != 0) h.func(h.ctx, t, .output);
        if (titled) h.func(h.ctx, t, .title);
        if (bells > 0) h.func(h.ctx, t, .bell);
        if (noted) h.func(h.ctx, t, .notify);
        if (events & (1 << @intFromEnum(Event.exit)) != 0) h.func(h.ctx, t, .exit);
    }

    // Effects, called while the emulator processes output (`lock` held).
    fn onWritePty(ctx: ?*anyopaque, bytes: []const u8) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx.?));
        t.send(bytes);
    }

    fn onBell(ctx: ?*anyopaque) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx.?));
        t.bells += 1;
    }

    fn onTitle(ctx: ?*anyopaque) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx.?));
        t.title_changed = true;
    }

    fn onSize(ctx: ?*anyopaque) [4]u32 {
        const t: *Terminal = @ptrCast(@alignCast(ctx.?));
        return .{ t.size[0], t.size[1], t.size[2], t.size[3] };
    }
};
