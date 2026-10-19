//! Pseudo-terminals on Windows: ConPTY. The Windows Terminal team's
//! (conpty.dll, which runs the console in its OpenConsole.exe) when the
//! app ships it or the user's cache has it (`library.conpty`), else
//! Windows' own (kernel32). Windows 10's own renders the screen again
//! rather than pass the program's output through: full-screen programs
//! lose their mouse, alternate screen and synchronized updates.
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const Options = @import("pty.zig").Options;

const HANDLE = *anyopaque;
const HPCON = *anyopaque;
const BOOL = c_int;
const invalid: HANDLE = @ptrFromInt(std.math.maxInt(usize));

const STARTUPINFOW = extern struct {
    cb: u32 = @sizeOf(STARTUPINFOEXW),
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
const STARTUPINFOEXW = extern struct { info: STARTUPINFOW = .{}, attributes: ?*anyopaque = null };
const PROCESS_INFORMATION = extern struct { hProcess: HANDLE, hThread: HANDLE, dwProcessId: u32, dwThreadId: u32 };

extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attrs: ?*anyopaque, size: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, len: u32, read: *u32, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: u32, flags: u32, size: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: u32, attr: usize, value: ?*anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: u32, env: ?*anyopaque, dir: ?[*:0]const u16, si: *STARTUPINFOEXW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
extern "kernel32" fn FreeEnvironmentStringsW(env: [*]u16) callconv(.winapi) BOOL;
extern "kernel32" fn SearchPathW(path: ?[*:0]const u16, file: [*:0]const u16, ext: ?[*:0]const u16, len: u32, buf: [*]u16, part: ?*?[*]u16) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(lib: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;

const CreateFn = *const fn (size: u32, in: HANDLE, out: HANDLE, flags: u32, pc: *HPCON) callconv(.winapi) i32;
const ResizeFn = *const fn (pc: HPCON, size: u32) callconv(.winapi) i32;
const CloseFn = *const fn (pc: HPCON) callconv(.winapi) void;

/// A ConPTY's functions: Windows' own, or those of conpty.dll.
const Api = struct { create: CreateFn, resize: ResizeFn, close: CloseFn, shipped: bool };

var shipped_api: ?Api = null;
var shipped_tried = std.atomic.Value(bool).init(false);

fn shipped(gpa: std.mem.Allocator, io: Io) ?Api {
    if (shipped_tried.swap(true, .acq_rel)) return shipped_api;
    if (library.env(gpa, "MYZIG_CONPTY") catch null) |v| {
        defer gpa.free(v);
        if (std.mem.eql(u8, v, "inbox")) return null;
    }
    const path = (library.conpty(gpa, io) catch null) orelse return null;
    defer gpa.free(path);
    var wide: [1024:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return null;
    wide[n] = 0;
    const lib = LoadLibraryW(wide[0..n :0]) orelse return null;
    shipped_api = .{
        .create = @ptrCast(@alignCast(GetProcAddress(lib, "ConptyCreatePseudoConsole") orelse return null)),
        .resize = @ptrCast(@alignCast(GetProcAddress(lib, "ConptyResizePseudoConsole") orelse return null)),
        .close = @ptrCast(@alignCast(GetProcAddress(lib, "ConptyClosePseudoConsole") orelse return null)),
        .shipped = true,
    };
    return shipped_api;
}

fn inbox() ?Api {
    const k = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse return null;
    return .{
        .create = @ptrCast(@alignCast(GetProcAddress(k, "CreatePseudoConsole") orelse return null)),
        .resize = @ptrCast(@alignCast(GetProcAddress(k, "ResizePseudoConsole") orelse return null)),
        .close = @ptrCast(@alignCast(GetProcAddress(k, "ClosePseudoConsole") orelse return null)),
        .shipped = false,
    };
}

fn coord(cols: u16, rows: u16) u32 {
    return @as(u32, @max(1, @min(cols, 0x7FFF))) | (@as(u32, @max(1, @min(rows, 0x7FFF))) << 16);
}

pub const Pty = struct {
    api: Api,
    console: ?HPCON,
    in: ?HANDLE,
    out: HANDLE,
    process: HANDLE,
    pid: u32,
    lock: std.atomic.Value(bool) = .init(false),

    pub fn start(gpa: std.mem.Allocator, io: Io, o: Options) !Pty {
        // The ConPTY the app ships, and Windows' own when it fails, as
        // when a security product stops OpenConsole.exe.
        if (shipped(gpa, io)) |api| {
            if (startWith(gpa, api, o)) |p| return p else |err| switch (err) {
                error.ConsoleFailed => {},
                else => return err, // the program's own failure, as a missing one
            }
        }
        const api = inbox() orelse return error.ConptyUnavailable;
        return startWith(gpa, api, o) catch |err| switch (err) {
            error.ConsoleFailed => error.ConptyUnavailable,
            else => err,
        };
    }

    fn startWith(gpa: std.mem.Allocator, api: Api, o: Options) !Pty {
        // The console reads what is typed from in_r and writes the output
        // to out_w; this side writes to in_w and reads out_r.
        var in_r: HANDLE = undefined;
        var in_w: HANDLE = undefined;
        var out_r: HANDLE = undefined;
        var out_w: HANDLE = undefined;
        if (CreatePipe(&in_r, &in_w, null, 0) == 0) return error.PipeFailed;
        if (CreatePipe(&out_r, &out_w, null, 0) == 0) {
            _ = CloseHandle(in_r);
            _ = CloseHandle(in_w);
            return error.PipeFailed;
        }
        var console: HPCON = undefined;
        const hr = api.create(coord(o.cols, o.rows), in_r, out_w, 0, &console);
        // The console has its own copies of its ends.
        _ = CloseHandle(in_r);
        _ = CloseHandle(out_w);
        if (hr != 0) {
            _ = CloseHandle(in_w);
            _ = CloseHandle(out_r);
            return error.ConsoleFailed;
        }
        var p: Pty = .{ .api = api, .console = console, .in = in_w, .out = out_r, .process = undefined, .pid = 0 };
        p.spawn(gpa, o) catch |err| {
            api.close(console);
            _ = CloseHandle(in_w);
            _ = CloseHandle(out_r);
            return err;
        };
        return p;
    }

    fn spawn(p: *Pty, gpa: std.mem.Allocator, o: Options) !void {
        var size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
        const list = try gpa.alignedAlloc(u8, .of(usize), size);
        defer gpa.free(list);
        if (InitializeProcThreadAttributeList(list.ptr, 1, 0, &size) == 0) return error.SpawnFailed;
        defer DeleteProcThreadAttributeList(list.ptr);
        const pseudoconsole: usize = 0x00020016;
        if (UpdateProcThreadAttribute(list.ptr, 0, pseudoconsole, p.console, @sizeOf(HPCON), null, null) == 0) return error.SpawnFailed;
        var si: STARTUPINFOEXW = .{ .attributes = list.ptr };
        // The console's own standard handles: without invalid ones, a child
        // of a process whose output is redirected would write there.
        si.info.dwFlags = 0x100; // STARTF_USESTDHANDLES
        si.info.hStdInput = invalid;
        si.info.hStdOutput = invalid;
        si.info.hStdError = invalid;

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const exe = try resolve(arena, o.argv[0]);
        const cmdline = try commandLine(arena, exe, o.argv[1..]);
        const dir: ?[*:0]const u16 = if (o.dir) |d| try std.unicode.utf8ToUtf16LeAllocZ(arena, d) else null;
        const env = try environmentBlock(arena, o.env);
        var pi: PROCESS_INFORMATION = undefined;
        const flags: u32 = 0x00080000 | 0x00000400; // EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT
        if (CreateProcessW(null, cmdline, null, null, 0, flags, env.ptr, dir, &si, &pi) == 0) return error.SpawnFailed;
        _ = CloseHandle(pi.hThread);
        p.process = pi.hProcess;
        p.pid = pi.dwProcessId;
    }

    /// Reads the program's output: 0 once the console closed.
    pub fn read(p: *Pty, buf: []u8) usize {
        var n: u32 = 0;
        if (ReadFile(p.out, buf.ptr, @intCast(@min(buf.len, 1 << 30)), &n, null) == 0) return 0;
        return n;
    }

    /// Types `bytes` into the terminal.
    pub fn write(p: *Pty, bytes: []const u8) !void {
        const h = p.in orelse return error.Closed;
        var rest = bytes;
        while (rest.len > 0) {
            var n: u32 = 0;
            if (WriteFile(h, rest.ptr, @intCast(@min(rest.len, 1 << 30)), &n, null) == 0) return error.Closed;
            rest = rest[n..];
        }
    }

    pub fn resize(p: *Pty, cols: u16, rows: u16, _: u16, _: u16) void {
        while (p.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer p.lock.store(false, .release);
        if (p.console) |c| _ = p.api.resize(c, coord(cols, rows));
    }

    /// Waits for the program to exit: its exit code.
    pub fn wait(p: *Pty) u32 {
        _ = WaitForSingleObject(p.process, 0xFFFFFFFF);
        var code: u32 = 0;
        _ = GetExitCodeProcess(p.process, &code);
        return code;
    }

    /// Closes the console, which ends the processes attached to it; `read`
    /// returns 0 once the console wrote what it had. ClosePseudoConsole
    /// waits for the output to be read on Windows before 11 24H2: call it
    /// while a thread reads.
    pub fn hangUp(p: *Pty) void {
        while (p.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        const c = p.console;
        p.console = null;
        const in = p.in;
        p.in = null;
        p.lock.store(false, .release);
        if (in) |h| _ = CloseHandle(h);
        if (c) |console| p.api.close(console);
    }

    pub fn kill(p: *Pty) void {
        _ = TerminateProcess(p.process, 1);
    }

    /// Frees what is left, once `read` returned 0 and `wait` returned.
    pub fn deinit(p: *Pty) void {
        p.hangUp();
        _ = CloseHandle(p.out);
        _ = CloseHandle(p.process);
    }
};

/// The path of program `name`, looked for on the PATH (with .exe).
fn resolve(arena: std.mem.Allocator, name: []const u8) ![:0]const u16 {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(arena, name);
    var buf: [1024]u16 = undefined;
    const n = SearchPathW(null, w, std.unicode.utf8ToUtf16LeStringLiteral(".exe"), buf.len, &buf, null);
    if (n == 0 or n >= buf.len) return error.ProgramNotFound;
    const out = try arena.allocSentinel(u16, n, 0);
    @memcpy(out, buf[0..n]);
    return out;
}

/// Joins a program and its arguments as the C runtime splits them.
fn commandLine(arena: std.mem.Allocator, exe: []const u16, args: []const []const u8) ![:0]u16 {
    var s: std.ArrayList(u8) = .empty;
    const exe8 = try std.unicode.utf16LeToUtf8Alloc(arena, exe);
    try quote(arena, &s, exe8);
    for (args) |a| {
        try s.append(arena, ' ');
        try quote(arena, &s, a);
    }
    return std.unicode.utf8ToUtf16LeAllocZ(arena, s.items);
}

/// Quotes an argument for CommandLineToArgvW and the C runtime.
pub fn quote(arena: std.mem.Allocator, s: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) return s.appendSlice(arena, arg);
    try s.append(arena, '"');
    var slashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            slashes += 1;
            continue;
        }
        if (ch == '"') try s.appendNTimes(arena, '\\', slashes * 2 + 1) else try s.appendNTimes(arena, '\\', slashes);
        slashes = 0;
        try s.append(arena, ch);
    }
    try s.appendNTimes(arena, '\\', slashes * 2);
    try s.append(arena, '"');
}

/// This process's environment with `extra` ("KEY=value") set, as
/// CreateProcessW takes it: NUL-terminated UTF-16 strings, then a NUL.
fn environmentBlock(arena: std.mem.Allocator, extra: []const []const u8) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    if (GetEnvironmentStringsW()) |block| {
        defer _ = FreeEnvironmentStringsW(block);
        var i: usize = 0;
        while (block[i] != 0) {
            const start = i;
            while (block[i] != 0) i += 1;
            const entry = block[start..i];
            i += 1;
            if (!overridden(entry, extra)) {
                try out.appendSlice(arena, entry);
                try out.append(arena, 0);
            }
        }
    }
    for (extra) |kv| {
        const w = try std.unicode.utf8ToUtf16LeAlloc(arena, kv);
        try out.appendSlice(arena, w);
        try out.append(arena, 0);
    }
    if (out.items.len == 0) try out.append(arena, 0);
    try out.append(arena, 0);
    return out.items;
}

/// Whether `extra` sets the variable of the UTF-16 entry `entry`.
fn overridden(entry: []const u16, extra: []const []const u8) bool {
    // Entries such as "=C:=C:\dir" name drives: never overridden.
    const eq = std.mem.indexOfScalarPos(u16, entry, 1, '=') orelse return false;
    for (extra) |kv| {
        const k = kv[0 .. std.mem.indexOfScalar(u8, kv, '=') orelse kv.len];
        if (k.len != eq) continue;
        var same = true;
        for (k, entry[0..eq]) |a, b| {
            if (b > 0x7f or std.ascii.toUpper(a) != std.ascii.toUpper(@intCast(b))) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

/// The user's shell: PowerShell 7, Windows PowerShell, %COMSPEC%, cmd.
/// Allocated with `gpa`.
pub fn defaultShell(gpa: std.mem.Allocator) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_][]const u8{ "pwsh.exe", "powershell.exe" }) |name| {
        if (resolve(arena.allocator(), name)) |_| return gpa.dupe(u8, name) else |_| {}
    }
    if (try library.env(gpa, "COMSPEC")) |c| {
        defer gpa.free(c);
        return gpa.dupe(u8, c);
    }
    return gpa.dupe(u8, "cmd.exe");
}

test quote {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var s: std.ArrayList(u8) = .empty;
    try quote(arena.allocator(), &s, "a b\\\"c\\");
    try std.testing.expectEqualStrings("\"a b\\\\\\\"c\\\\\"", s.items);
}
