//! The recycle bin, through IFileOperation as Electron's shell.trashItem
//! (after mygo). Windows deletes an item for good when it cannot recycle
//! it: one too big for the recycle bin, or on a drive without one, as
//! network shares and many removable drives are. Without a UI nothing
//! asks first, so a progress sink refuses those deletes and `trash`
//! fails instead, leaving the item where it is.
const std = @import("std");
const w = @import("win32.zig");
const com = @import("com.zig");

const CLSID_FileOperation = com.GUID.parse("3ad05575-8857-4850-9277-11b85bdb8e09");
const IID_IFileOperation = com.GUID.parse("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8");
const IID_IFileOperationProgressSink = com.GUID.parse("04b0f1a7-9490-44bc-96e1-4296a31252e2");
const IID_IShellItem = com.GUID.parse("43826d1e-e718-42ee-bc55-a1e261c37bfe");
const IID_IUnknown = com.GUID.parse("00000000-0000-0000-c000-000000000046");

extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "shell32" fn SHCreateItemFromParsingName(path: [*:0]const u16, ctx: ?*anyopaque, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;
extern "kernel32" fn GetFullPathNameW(name: [*:0]const u16, len: u32, buf: [*]u16, file: ?*?[*:0]u16) callconv(.winapi) u32;

const FOF_SILENT = 0x0004;
const FOF_NOCONFIRMATION = 0x0010;
const FOF_ALLOWUNDO = 0x0040;
const FOF_NOCONFIRMMKDIR = 0x0200;
const FOF_NOERRORUI = 0x0400;
const FOFX_RECYCLEONDELETE = 0x00080000;
const FOFX_ADDUNDORECORD = 0x20000000;
pub const flags: u32 = FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR | FOF_ALLOWUNDO | FOFX_RECYCLEONDELETE | FOFX_ADDUNDORECORD;
/// PreDeleteItem's flag of a delete that goes to the recycle bin.
const TSF_DELETE_RECYCLE_IF_POSSIBLE = 0x80;
const E_ABORT: com.HRESULT = @bitCast(@as(u32, 0x80004004));

// IFileOperation's methods.
const set_operation_flags = 5;
const delete_item = 18;
const perform_operations = 21;
const get_any_operations_aborted = 22;

const P = ?*anyopaque;

/// IFileOperationProgressSink: only PreDeleteItem does anything; the
/// other methods succeed. It lives on `trash`'s stack, which outlives
/// the operation holding it.
pub const Sink = extern struct {
    vtbl: *const Vtbl = &vtbl_shared,
    /// A delete would not have gone to the recycle bin.
    refused: bool = false,

    const Vtbl = extern struct {
        query: *const fn (*Sink, *const com.GUID, *?*anyopaque) callconv(.winapi) com.HRESULT = query,
        add_ref: *const fn (*Sink) callconv(.winapi) u32 = one,
        release: *const fn (*Sink) callconv(.winapi) u32 = one,
        start_operations: *const fn (*Sink) callconv(.winapi) com.HRESULT = ok0,
        finish_operations: *const fn (*Sink, com.HRESULT) callconv(.winapi) com.HRESULT = ok1h,
        pre_rename_item: *const fn (*Sink, u32, P, P) callconv(.winapi) com.HRESULT = ok3,
        post_rename_item: *const fn (*Sink, u32, P, P, com.HRESULT, P) callconv(.winapi) com.HRESULT = ok5,
        pre_move_item: *const fn (*Sink, u32, P, P, P) callconv(.winapi) com.HRESULT = ok4,
        post_move_item: *const fn (*Sink, u32, P, P, P, com.HRESULT, P) callconv(.winapi) com.HRESULT = ok6,
        pre_copy_item: *const fn (*Sink, u32, P, P, P) callconv(.winapi) com.HRESULT = ok4,
        post_copy_item: *const fn (*Sink, u32, P, P, P, com.HRESULT, P) callconv(.winapi) com.HRESULT = ok6,
        pre_delete_item: *const fn (*Sink, u32, P) callconv(.winapi) com.HRESULT = preDelete,
        post_delete_item: *const fn (*Sink, u32, P, com.HRESULT, P) callconv(.winapi) com.HRESULT = ok4h,
        pre_new_item: *const fn (*Sink, u32, P, P) callconv(.winapi) com.HRESULT = ok3,
        post_new_item: *const fn (*Sink, u32, P, P, P, u32, com.HRESULT, P) callconv(.winapi) com.HRESULT = ok7,
        update_progress: *const fn (*Sink, u32, u32) callconv(.winapi) com.HRESULT = ok2,
        reset_timer: *const fn (*Sink) callconv(.winapi) com.HRESULT = ok0,
        pause_timer: *const fn (*Sink) callconv(.winapi) com.HRESULT = ok0,
        resume_timer: *const fn (*Sink) callconv(.winapi) com.HRESULT = ok0,
    };
    const vtbl_shared: Vtbl = .{};

    fn query(s: *Sink, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        if (iid.eql(IID_IUnknown) or iid.eql(IID_IFileOperationProgressSink)) {
            out.* = s;
            return com.S_OK;
        }
        out.* = null;
        return com.E_NOINTERFACE;
    }
    fn one(_: *Sink) callconv(.winapi) u32 {
        return 1;
    }
    fn preDelete(s: *Sink, how: u32, _: P) callconv(.winapi) com.HRESULT {
        if (how & TSF_DELETE_RECYCLE_IF_POSSIBLE == 0) {
            s.refused = true;
            return E_ABORT;
        }
        return com.S_OK;
    }
    fn ok0(_: *Sink) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }
    fn ok1h(_: *Sink, _: com.HRESULT) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }
    fn ok2(_: *Sink, _: u32, _: u32) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }
    fn ok3(_: *Sink, _: u32, _: P, _: P) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }
    fn ok4(_: *Sink, _: u32, _: P, _: P, _: P) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }
    fn ok4h(_: *Sink, _: u32, _: P, _: com.HRESULT, _: P) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }
    fn ok5(_: *Sink, _: u32, _: P, _: P, _: com.HRESULT, _: P) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }
    fn ok6(_: *Sink, _: u32, _: P, _: P, _: P, _: com.HRESULT, _: P) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }
    fn ok7(_: *Sink, _: u32, _: P, _: P, _: P, _: u32, _: com.HRESULT, _: P) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }
};

pub const Error = error{ NotFound, PermanentDelete, Failed, Com };

/// Moves the file or folder at `path` (relative to the working directory,
/// or absolute) to the recycle bin; never deletes it for good: where it
/// cannot go to the recycle bin it fails with `error.PermanentDelete`
/// and leaves it.
pub fn trash(path: []const u8) Error!void {
    var buf: [4096]u16 = undefined;
    var full: [4096]u16 = undefined;
    const n = GetFullPathNameW(w.wide(&buf, path), full.len, &full, null);
    if (n == 0 or n >= full.len) return error.NotFound;
    full[n] = 0;
    // COM in this thread, if the app hasn't (a single-threaded apartment).
    const init = com.CoInitializeEx(null, 0x2);
    defer if (init == com.S_OK) CoUninitialize();
    var item: ?com.Object = null;
    if (com.failed(SHCreateItemFromParsingName(full[0..n :0].ptr, null, &IID_IShellItem, &item)) or item == null) return error.NotFound;
    defer com.release(item);
    var sink: Sink = .{};
    var op: ?com.Object = null;
    if (com.failed(CoCreateInstance(&CLSID_FileOperation, null, 1, &IID_IFileOperation, &op)) or op == null) return error.Com;
    // Released before the sink's stack goes.
    defer com.release(op);
    if (com.failed(com.call(op.?, set_operation_flags, .{flags}))) return error.Com;
    if (com.failed(com.call(op.?, delete_item, .{ item.?, @as(*anyopaque, &sink) }))) return error.Com;
    const hr = com.call(op.?, perform_operations, .{});
    var aborted: w.BOOL = 0;
    _ = com.call(op.?, get_any_operations_aborted, .{&aborted});
    if (sink.refused) return error.PermanentDelete;
    if (com.failed(hr) or aborted != 0) return error.Failed;
}

const testing = std.testing;

test "the progress sink refuses deletes that would not go to the recycle bin" {
    var s: Sink = .{};
    try testing.expectEqual(com.S_OK, s.vtbl.pre_delete_item(&s, TSF_DELETE_RECYCLE_IF_POSSIBLE, null));
    try testing.expect(!s.refused);
    try testing.expectEqual(E_ABORT, s.vtbl.pre_delete_item(&s, 0, null));
    try testing.expect(s.refused);
    var out: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, s.vtbl.query(&s, &IID_IFileOperationProgressSink, &out));
    try testing.expectEqual(@as(usize, 19), @sizeOf(Sink.Vtbl) / @sizeOf(usize));
}

test "trashing a missing file fails; a file on a share without a recycle bin is left where it is" {
    // Nothing reaches the user's recycle bin: the one file that could is
    // refused, as Windows would delete it for good.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const missing = try std.fs.path.join(gpa, &.{ dir, "missing.txt" });
    defer gpa.free(missing);
    try testing.expectError(error.NotFound, trash(missing));

    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "keep me" });
    // \\localhost\C$\...: an administrative share, which has no recycle bin.
    if (dir.len < 3 or dir[1] != ':') return;
    const unc = try std.fmt.allocPrint(gpa, "\\\\localhost\\{c}$\\{s}\\kept.txt", .{ dir[0], dir[3..] });
    defer gpa.free(unc);
    std.Io.Dir.cwd().access(io, unc, .{}) catch return; // no share here
    try testing.expectError(error.PermanentDelete, trash(unc));
    try tmp.dir.access(io, "kept.txt", .{});
}
