//! UI Automation's provider side without headers: its functions, loaded
//! from uiautomationcore.dll and oleaut32.dll the first time assistive
//! technology asks a window (an app no screen reader reads never loads
//! them), its identifiers, and VARIANTs, BSTRs and SAFEARRAYs.
const std = @import("std");
const com = @import("com.zig");
const w = @import("win32.zig");
const Role = @import("../ui/access.zig").Role;

pub const GUID = com.GUID;
pub const HRESULT = com.HRESULT;
pub const S_OK = com.S_OK;
pub const E_NOINTERFACE = com.E_NOINTERFACE;
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub const UIA_E_ELEMENTNOTENABLED: HRESULT = @bitCast(@as(u32, 0x80040200));
pub const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040201));
pub const UIA_E_INVALIDOPERATION: HRESULT = @bitCast(@as(u32, 0x80131509));

pub const WM_GETOBJECT: u32 = 0x003D;
pub const UiaRootObjectId: i32 = -25;
pub const OBJID_CLIENT: i32 = -4;
pub const EVENT_OBJECT_FOCUS: u32 = 0x8005;

/// The interfaces of an element, by index.
pub const Iface = enum(u8) {
    simple,
    fragment,
    root,
    invoke,
    toggle,
    selection_item,
    range_value,
    value,
    expand_collapse,
    selection,
    scroll_item,
    text,
    text2,
};
pub const iface_count = @typeInfo(Iface).@"enum".field_names.len;

pub const iids = [iface_count]GUID{
    .parse("d6dd68d1-86fd-4332-8666-9abedea2d24c"), // IRawElementProviderSimple
    .parse("f7063da8-8359-439c-9297-bbc5299a7d87"), // IRawElementProviderFragment
    .parse("620ce2a5-ab8f-40a9-86cb-de3c75599b58"), // IRawElementProviderFragmentRoot
    .parse("54fcb24b-e18e-47a2-b4d3-eccbe77599a2"), // IInvokeProvider
    .parse("56d00bd0-c4f4-433c-a836-1a52a57e0892"), // IToggleProvider
    .parse("2acad808-b2d4-452d-a407-91ff1ad167b2"), // ISelectionItemProvider
    .parse("36dc7aef-33e6-4691-afe1-2be7274b3d33"), // IRangeValueProvider
    .parse("c7935180-6fb3-4201-b174-7df73adbf64a"), // IValueProvider
    .parse("d847d3a5-cab0-4a98-8c32-ecb45c59ad24"), // IExpandCollapseProvider
    .parse("fb8b03af-3bdf-48d4-bd36-1a65793be168"), // ISelectionProvider
    .parse("2360c714-4bf1-4b26-ba65-9b21316127eb"), // IScrollItemProvider
    .parse("3589c92c-63f3-4367-99bb-ada653b77cf2"), // ITextProvider
    .parse("0dc5e6ed-3e16-4bf1-8f9a-a979878bc195"), // ITextProvider2
};
pub const iid_unknown: GUID = .parse("00000000-0000-0000-c000-000000000046");

/// The interface of a pattern identifier, if elements have it.
pub fn patternIface(pattern: i32) ?Iface {
    return switch (pattern) {
        10000 => .invoke,
        10001 => .selection,
        10002 => .value,
        10003 => .range_value,
        10005 => .expand_collapse,
        10010 => .selection_item,
        10015 => .toggle,
        10014 => .text,
        10017 => .scroll_item,
        10024 => .text2,
        else => null,
    };
}

pub const Prop = struct {
    pub const runtime_id = 30000;
    pub const bounding_rectangle = 30001;
    pub const control_type = 30003;
    pub const localized_control_type = 30004;
    pub const name = 30005;
    pub const has_keyboard_focus = 30008;
    pub const is_keyboard_focusable = 30009;
    pub const is_enabled = 30010;
    pub const automation_id = 30011;
    pub const help_text = 30013;
    pub const is_control_element = 30016;
    pub const is_content_element = 30017;
    pub const is_password = 30019;
    pub const is_offscreen = 30022;
    pub const orientation = 30023;
    pub const framework_id = 30024;
    pub const item_status = 30026;
    pub const value = 30045;
    pub const range_value = 30047;
    pub const expand_state = 30070;
    pub const is_selected = 30079;
    pub const toggle_state = 30086;
    pub const is_data_valid = 30103;
    pub const live_setting = 30135;
    pub const position_in_set = 30152;
    pub const size_of_set = 30153;
    pub const level = 30154;
    pub const full_description = 30159;
    pub const heading_level = 30173;
    pub const is_dialog = 30174;
};

pub const Event = struct {
    pub const focus_changed = 20005;
    pub const element_added_to_selection = 20010;
    pub const element_removed_from_selection = 20011;
    pub const element_selected = 20012;
    pub const text_selection_changed = 20014;
    pub const text_changed = 20015;
    pub const live_region_changed = 20024;
};

/// UI Automation's control type of a role.
pub fn controlType(r: Role) i32 {
    return switch (r) {
        .button, .switch_, .menu_button, .toggle_button, .disclosure, .color_well => 50000,
        .checkbox => 50002,
        .popup_button, .combo_box => 50003,
        .text_field => 50004,
        .link => 50005,
        .image => 50006,
        .list_item => 50007,
        .list => 50008,
        .menu => 50009,
        .menu_bar => 50010,
        .menu_item, .menu_item_checkbox, .menu_item_radio => 50011,
        .progress, .meter => 50012,
        .radio => 50013,
        .slider => 50015,
        .stepper => 50016,
        .status => 50017,
        .tab_list => 50018,
        .tab => 50019,
        .text, .heading => 50020,
        .toolbar => 50021,
        .tooltip => 50022,
        .tree => 50023,
        .tree_item => 50024,
        .cell => 50025,
        .row => 50029,
        .column_header => 50035,
        .table => 50036,
        .splitter => 50038,
        .scroll_area, .dialog, .alert_dialog, .popup, .tab_panel => 50033,
        .group, .radio_group, .auto, .none => 50026,
    };
}

pub const VT_EMPTY: u16 = 0;
pub const VT_I4: u16 = 3;
pub const VT_R8: u16 = 5;
pub const VT_BSTR: u16 = 8;
pub const VT_BOOL: u16 = 11;
pub const VT_UNKNOWN: u16 = 13;

/// The alignment of 8-byte fields in a struct passed by value. 32-bit
/// Windows puts such a struct in 4-byte stack slots, which LLVM matches
/// only when the struct is 4-aligned.
pub const by_value_align = if (@sizeOf(usize) == 4) 4 else 8;

pub const VARIANT = extern struct {
    vt: u16 = VT_EMPTY,
    reserved: [3]u16 = .{ 0, 0, 0 },
    /// The union: 16 bytes on 64-bit Windows, 8 on 32-bit.
    data: [@sizeOf(usize) / 4]u64 align(by_value_align) = @splat(0),

    /// A VARIANT of type `vt` whose first eight bytes are `x`.
    pub fn of(vt: u16, x: u64) VARIANT {
        var v: VARIANT = .{ .vt = vt };
        v.data[0] = x;
        return v;
    }

    pub fn int(v: i32) VARIANT {
        return .of(VT_I4, @as(u32, @bitCast(v)));
    }

    pub fn boolean(v: bool) VARIANT {
        return .of(VT_BOOL, if (v) 0xFFFF else 0);
    }

    pub fn double(v: f64) VARIANT {
        return .of(VT_R8, @bitCast(v));
    }

    /// A BSTR of `s` (the receiver frees it); empty without the API.
    pub fn string(s: []const u8) VARIANT {
        const b = bstr(s) orelse return .{};
        return .of(VT_BSTR, @intFromPtr(b));
    }
};

pub const UiaRect = extern struct { left: f64 = 0, top: f64 = 0, width: f64 = 0, height: f64 = 0 };

pub const Api = struct {
    UiaReturnRawElementProvider: *const fn (w.HWND, w.WPARAM, w.LPARAM, ?*anyopaque) callconv(.winapi) w.LRESULT,
    UiaHostProviderFromHwnd: *const fn (w.HWND, *?*anyopaque) callconv(.winapi) HRESULT,
    UiaRaiseAutomationEvent: *const fn (*anyopaque, i32) callconv(.winapi) HRESULT,
    UiaRaiseAutomationPropertyChangedEvent: *const fn (*anyopaque, i32, VARIANT, VARIANT) callconv(.winapi) HRESULT,
    UiaRaiseStructureChangedEvent: *const fn (*anyopaque, i32, ?[*]const i32, i32) callconv(.winapi) HRESULT,
    UiaClientsAreListening: *const fn () callconv(.winapi) i32,
    UiaDisconnectProvider: ?*const fn (*anyopaque) callconv(.winapi) HRESULT,
    UiaGetReservedNotSupportedValue: *const fn (*?*anyopaque) callconv(.winapi) HRESULT,
    SysAllocString: *const fn ([*:0]const u16) callconv(.winapi) ?*anyopaque,
    SysAllocStringLen: *const fn (?[*]const u16, u32) callconv(.winapi) ?*anyopaque,
    SysFreeString: *const fn (?*anyopaque) callconv(.winapi) void,
    SafeArrayCreateVector: *const fn (u16, i32, u32) callconv(.winapi) ?*anyopaque,
    SafeArrayPutElement: *const fn (*anyopaque, *const i32, *const anyopaque) callconv(.winapi) HRESULT,
    VariantClear: *const fn (*VARIANT) callconv(.winapi) HRESULT,
    NotifyWinEvent: *const fn (u32, w.HWND, i32, i32) callconv(.winapi) void,
};

extern "kernel32" fn LoadLibraryW(path: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

var api_storage: Api = undefined;
var api_state: enum { untried, loaded, missing } = .untried;

/// The functions, loaded once; null where UI Automation is missing.
pub fn api() ?*const Api {
    switch (api_state) {
        .loaded => return &api_storage,
        .missing => return null,
        .untried => {},
    }
    api_state = .missing;
    const uia = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("uiautomationcore.dll")) orelse return null;
    const ole = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("oleaut32.dll")) orelse return null;
    const user = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse return null;
    var a: Api = undefined;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        const lib = if (comptime std.mem.startsWith(u8, name, "Uia")) uia else if (comptime std.mem.eql(u8, name, "NotifyWinEvent")) user else ole;
        const z: [:0]const u8 = name ++ "";
        const p = GetProcAddress(lib, z.ptr);
        if (@typeInfo(T) == .optional) {
            @field(a, name) = @ptrCast(@alignCast(p));
        } else @field(a, name) = @ptrCast(@alignCast(p orelse return null));
    }
    api_storage = a;
    api_state = .loaded;
    return &api_storage;
}

/// A BSTR of `s`, or null.
pub fn bstr(s: []const u8) ?*anyopaque {
    const a = api() orelse return null;
    var buf: [2048]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s[0..@min(s.len, 1000)]) catch return a.SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral(""));
    buf[n] = 0;
    return a.SysAllocString(buf[0..n :0]);
}

/// A SAFEARRAY of 32-bit integers.
pub fn intArray(values: []const i32) ?*anyopaque {
    const a = api() orelse return null;
    const sa = a.SafeArrayCreateVector(VT_I4, 0, @intCast(values.len)) orelse return null;
    for (values, 0..) |*v, i| {
        const at: i32 = @intCast(i);
        _ = a.SafeArrayPutElement(sa, &at, v);
    }
    return sa;
}

/// A SAFEARRAY of interface pointers (each AddRef'd by the array).
pub fn unknownArray(values: []const *anyopaque) ?*anyopaque {
    const a = api() orelse return null;
    const sa = a.SafeArrayCreateVector(VT_UNKNOWN, 0, @intCast(values.len)) orelse return null;
    for (values, 0..) |v, i| {
        const at: i32 = @intCast(i);
        _ = a.SafeArrayPutElement(sa, &at, v);
    }
    return sa;
}

test "control types and patterns" {
    try std.testing.expectEqual(@as(i32, 50000), controlType(.button));
    try std.testing.expectEqual(@as(i32, 50004), controlType(.text_field));
    try std.testing.expectEqual(Iface.invoke, patternIface(10000).?);
    try std.testing.expect(patternIface(10030) == null);
    try std.testing.expectEqual(@as(usize, 8 + 2 * @sizeOf(usize)), @sizeOf(VARIANT));
}

/// A SAFEARRAY of doubles.
pub fn doubleArray(values: []const f64) ?*anyopaque {
    const a = api() orelse return null;
    const sa = a.SafeArrayCreateVector(VT_R8, 0, @intCast(values.len)) orelse return null;
    for (values, 0..) |*v, i| {
        const at: i32 = @intCast(i);
        _ = a.SafeArrayPutElement(sa, &at, v);
    }
    return sa;
}

/// A BSTR of `s` however long, cut at `max` UTF-16 code units (negative:
/// no limit); null without the API or the memory.
pub fn bstrLong(gpa: std.mem.Allocator, s: []const u8, max: i32) ?*anyopaque {
    const a = api() orelse return null;
    const units = std.unicode.calcUtf16LeLen(s) catch s.len;
    const buf = gpa.alloc(u16, units) catch return null;
    defer gpa.free(buf);
    const n = std.unicode.utf8ToUtf16Le(buf, s) catch 0;
    const len = if (max >= 0) @min(n, @as(usize, @intCast(max))) else n;
    return a.SysAllocStringLen(buf.ptr, @intCast(len));
}
