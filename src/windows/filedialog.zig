//! The open dialog of Windows Vista on (IFileOpenDialog): files, or
//! folders (`FOS_PICKFOLDERS`), one or several, with the Explorer's
//! navigation pane, address bar and search, as other apps' dialogs show.
//! Null when COM can't make it, for the older dialogs to take over.
const std = @import("std");
const com = @import("com.zig");
const w = @import("win32.zig");
const dialog_types = @import("../dialog_types.zig");

const clsid_file_open = com.GUID.parse("dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7");
const iid_file_open = com.GUID.parse("d57c7288-d4ad-4768-be02-9d969532d960");
const iid_shell_item = com.GUID.parse("43826d1e-e718-42ee-bc55-a1e261c37bfe");

/// IFileDialog's methods (after IUnknown and IModalWindow's Show) and
/// IFileOpenDialog's, by vtable index, from shobjidl_core.h.
const m = struct {
    const show = 3;
    const set_file_types = 4;
    const set_options = 9;
    const get_options = 10;
    const set_folder = 12;
    const set_title = 17;
    const set_ok_button_label = 18;
    const get_result = 20;
    const get_results = 27;
};
/// IShellItem's GetDisplayName; IShellItemArray's GetCount and GetItemAt.
const item_get_display_name = 5;
const array_get_count = 7;
const array_get_item_at = 8;

const fos_pick_folders = 0x20;
const fos_force_filesystem = 0x40;
const fos_allow_multiselect = 0x200;
const fos_path_must_exist = 0x800;
const fos_file_must_exist = 0x1000;
const fos_force_show_hidden = 0x10000000;
const sigdn_filesyspath: u32 = 0x80058000;
/// HRESULT_FROM_WIN32(ERROR_CANCELLED): the dialog was cancelled.
const cancelled: com.HRESULT = @bitCast(@as(u32, 0x800704C7));

const FilterSpec = extern struct { name: [*:0]const u16, spec: [*:0]const u16 };

extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
extern "shell32" fn SHCreateItemFromParsingName(path: [*:0]const u16, bc: ?*anyopaque, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;
extern "user32" fn GetActiveWindow() callconv(.winapi) ?*anyopaque;

pub const Result = union(enum) {
    /// COM didn't make the dialog: the caller falls back.
    unavailable,
    cancelled,
    chosen: [][]u8,
};

pub fn open(gpa: std.mem.Allocator, opts: dialog_types.OpenOptions) !Result {
    _ = com.CoInitializeEx(null, 0x2);
    var dlg_opt: ?com.Object = null;
    if (com.failed(CoCreateInstance(&clsid_file_open, null, 1, &iid_file_open, &dlg_opt))) return .unavailable;
    const dlg = dlg_opt orelse return .unavailable;
    defer com.release(dlg);

    var flags: u32 = 0;
    _ = com.call(dlg, m.get_options, .{&flags});
    flags |= fos_force_filesystem | fos_path_must_exist;
    if (opts.directories and !opts.files) flags |= fos_pick_folders else flags |= fos_file_must_exist;
    if (opts.multiple) flags |= fos_allow_multiselect;
    if (opts.show_hidden) flags |= fos_force_show_hidden;
    _ = com.call(dlg, m.set_options, .{flags});

    var buf: [1024]u16 = undefined;
    if (opts.title.len > 0) _ = com.call(dlg, m.set_title, .{w.wide(&buf, opts.title)});
    if (opts.button.len > 0) _ = com.call(dlg, m.set_ok_button_label, .{w.wide(&buf, opts.button)});
    if (opts.directory.len > 0) {
        var item: ?com.Object = null;
        if (!com.failed(SHCreateItemFromParsingName(w.wide(&buf, opts.directory), null, &iid_shell_item, &item))) if (item) |it| {
            _ = com.call(dlg, m.set_folder, .{it});
            com.release(it);
        };
    }
    // The extensions allowed, as one filter ("*.png;*.jpg").
    if (opts.extensions.len > 0 and opts.files) {
        var spec: std.ArrayList(u8) = .empty;
        defer spec.deinit(gpa);
        for (opts.extensions, 0..) |e, i| {
            if (i > 0) try spec.append(gpa, ';');
            try spec.print(gpa, "*.{s}", .{e});
        }
        var name_w: [512]u16 = undefined;
        var spec_w: [1024]u16 = undefined;
        const filter = [_]FilterSpec{.{ .name = w.wide(&name_w, spec.items), .spec = w.wide(&spec_w, spec.items) }};
        _ = com.call(dlg, m.set_file_types, .{ @as(u32, 1), &filter });
    }

    const hr = com.call(dlg, m.show, .{GetActiveWindow()});
    if (hr == cancelled) return .cancelled;
    if (com.failed(hr)) return .unavailable;

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var items: ?com.Object = null;
    if (!com.failed(com.call(dlg, m.get_results, .{&items}))) if (items) |arr| {
        defer com.release(arr);
        var n: u32 = 0;
        _ = com.call(arr, array_get_count, .{&n});
        for (0..n) |i| {
            var it: ?com.Object = null;
            if (com.failed(com.call(arr, array_get_item_at, .{ @as(u32, @intCast(i)), &it }))) continue;
            const item = it orelse continue;
            defer com.release(item);
            if (try pathOf(gpa, item)) |p| try out.append(gpa, p);
        }
    };
    if (out.items.len == 0) return .cancelled;
    return .{ .chosen = try out.toOwnedSlice(gpa) };
}

/// A shell item's path on the file system, or null for one with none.
fn pathOf(gpa: std.mem.Allocator, item: com.Object) !?[]u8 {
    var name: ?[*:0]u16 = null;
    if (com.failed(com.call(item, item_get_display_name, .{ sigdn_filesyspath, &name }))) return null;
    const p = name orelse return null;
    defer CoTaskMemFree(p);
    return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(p, 0));
}
