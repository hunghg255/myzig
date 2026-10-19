//! The app's jump list on Windows (right click on its taskbar button):
//! the Tasks category, links that run the app (or another program) with
//! arguments, such as a URL of the app's own scheme, and the Recent
//! category of the documents the app recorded. Windows keeps the list
//! after the app quits: apps set it once at startup.
const std = @import("std");
const com = @import("com.zig");

pub const Task = struct {
    title: []const u8,
    description: []const u8 = "",
    /// The program; the app's own executable when empty.
    path: []const u8 = "",
    /// Its command line arguments, quoted as given.
    args: []const u8 = "",
    icon_path: []const u8 = "",
    icon_index: i32 = 0,
};

extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, ctx: u32, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT;

const CLSID_DestinationList = com.GUID.parse("77f10cf0-3db5-4966-b520-b7c54fd35ed6");
const IID_ICustomDestinationList = com.GUID.parse("6332debf-87b5-4670-90c0-5e57b408a49e");
const IID_IObjectArray = com.GUID.parse("92ca9dcd-5622-4bba-a805-5e9f541bd8c9");
const CLSID_EnumerableObjectCollection = com.GUID.parse("2d3468c1-36a7-43b6-ac24-d3f02fd9607a");
const IID_IObjectCollection = com.GUID.parse("5632b1a4-e38a-400a-928a-d4cd63230295");
const CLSID_ShellLink = com.GUID.parse("00021401-0000-0000-c000-000000000046");
const IID_IShellLinkW = com.GUID.parse("000214f9-0000-0000-c000-000000000046");
const IID_IPropertyStore = com.GUID.parse("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");

const PROPERTYKEY = extern struct { fmtid: com.GUID, pid: u32 };
const PKEY_Title: PROPERTYKEY = .{ .fmtid = com.GUID.parse("f29f85e0-4ff9-1068-ab91-08002b27b3d9"), .pid = 2 };
/// PROPVARIANT holding a VT_LPWSTR (31).
const PROPVARIANT = extern struct { vt: u16 = 31, r1: u16 = 0, r2: u16 = 0, r3: u16 = 0, ptr: ?[*:0]const u16, pad: usize = 0 };

// Vtable indices.
const begin_list = 4;
const add_user_tasks = 7;
const commit_list = 8;
const append_known_category = 6;
const delete_list = 10;
const abort_list = 11;
const add_object = 5;
const set_description = 7;
const set_arguments = 11;
const set_icon_location = 17;
const set_path = 20;
const set_value = 6;
const commit = 7;

fn create(clsid: *const com.GUID, iid: *const com.GUID) !com.Object {
    var out: ?com.Object = null;
    if (com.failed(CoCreateInstance(clsid, null, 1, iid, &out))) return error.Com;
    return out orelse error.Com;
}

fn link(gpa: std.mem.Allocator, t: Task, exe: []const u8) !com.Object {
    const l = try create(&CLSID_ShellLink, &IID_IShellLinkW);
    errdefer com.release(l);
    const path = try com.wide(gpa, if (t.path.len > 0) t.path else exe);
    defer gpa.free(path);
    if (com.failed(com.call(l, set_path, .{path.ptr}))) return error.Com;
    const args = try com.wide(gpa, t.args);
    defer gpa.free(args);
    _ = com.call(l, set_arguments, .{args.ptr});
    if (t.description.len > 0) {
        const d = try com.wide(gpa, t.description);
        defer gpa.free(d);
        _ = com.call(l, set_description, .{d.ptr});
    }
    if (t.icon_path.len > 0) {
        const i = try com.wide(gpa, t.icon_path);
        defer gpa.free(i);
        _ = com.call(l, set_icon_location, .{ i.ptr, t.icon_index });
    }
    const store = com.query(l, &IID_IPropertyStore) orelse return error.Com;
    defer com.release(store);
    const title = try com.wide(gpa, t.title);
    defer gpa.free(title);
    const v: PROPVARIANT = .{ .ptr = title.ptr };
    if (com.failed(com.call(store, set_value, .{ &PKEY_Title, &v }))) return error.Com;
    _ = com.call(store, commit, .{});
    return l;
}

pub const Mode = enum { commit, abort };

/// Replaces the jump list's tasks (none: removes them), with the Recent
/// category when `recent`. `.abort` builds it and throws it away (tests).
pub fn set(gpa: std.mem.Allocator, exe: []const u8, tasks: []const Task, recent: bool, mode: Mode) !void {
    const list = try create(&CLSID_DestinationList, &IID_ICustomDestinationList);
    defer com.release(list);
    if (tasks.len == 0 and !recent) {
        if (mode == .commit) _ = com.call(list, delete_list, .{@as(?[*:0]const u16, null)});
        return;
    }
    var slots: u32 = 0;
    var removed: ?com.Object = null;
    if (com.failed(com.call(list, begin_list, .{ &slots, &IID_IObjectArray, &removed }))) return error.Com;
    com.release(removed);
    errdefer _ = com.call(list, abort_list, .{});
    if (recent) _ = com.call(list, append_known_category, .{@as(i32, 2)}); // KDC_RECENT
    if (tasks.len > 0) {
        const coll = try create(&CLSID_EnumerableObjectCollection, &IID_IObjectCollection);
        defer com.release(coll);
        for (tasks) |t| {
            const l = try link(gpa, t, exe);
            defer com.release(l);
            if (com.failed(com.call(coll, add_object, .{l}))) return error.Com;
        }
        const arr = com.query(coll, &IID_IObjectArray) orelse return error.Com;
        defer com.release(arr);
        if (com.failed(com.call(list, add_user_tasks, .{arr}))) return error.Com;
    }
    if (mode == .abort) {
        _ = com.call(list, abort_list, .{});
        return;
    }
    if (com.failed(com.call(list, commit_list, .{}))) return error.Com;
}

test "a jump list's tasks are built (and thrown away, the user's list untouched)" {
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 24), @sizeOf(PROPVARIANT));
    _ = com.CoInitializeEx(null, 0x2);
    try set(std.testing.allocator, "C:\\Windows\\notepad.exe", &.{
        .{ .title = "New note", .args = "notes://new", .description = "Opens a new note" },
        .{ .title = "Open the folder", .path = "C:\\Windows\\explorer.exe", .args = "C:\\" },
    }, true, .abort);
}
