//! libghostty-vt's C API, the terminal emulator of Ghostty: its structs
//! as the library lays them out, and its functions, looked up by name when
//! the library is loaded at run time (dlopen, LoadLibrary): nothing is
//! linked, no C is compiled. `layouts.zig` checks these structs against
//! the layouts the library describes (`ghostty_type_json`) as it loads,
//! so that a library of another version fails to load instead of
//! corrupting memory.
const std = @import("std");
const builtin = @import("builtin");

pub const Terminal = opaque {};
pub const RenderState = opaque {};
pub const RowIterator = opaque {};
pub const RowCells = opaque {};
pub const KeyEncoder = opaque {};
pub const KeyEvent = opaque {};
pub const MouseEncoder = opaque {};
pub const MouseEvent = opaque {};
pub const Formatter = opaque {};

/// A GhosttyResult: 0 is success.
pub const Result = c_int;
pub const success: Result = 0;
pub const out_of_space: Result = -3;

pub const Rgb = extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 };

/// A GhosttyStyleColor: none, a palette index (value[0]) or RGB.
pub const StyleColor = extern struct {
    tag: i32 = 0,
    _pad: u32 = 0,
    value: [8]u8 align(8) = @splat(0),

    pub const none = 0;
    pub const palette = 1;
    pub const rgb = 2;
};

pub const Style = extern struct {
    size: u64 = @sizeOf(Style),
    fg_color: StyleColor = .{},
    bg_color: StyleColor = .{},
    underline_color: StyleColor = .{},
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: i32 = 0,
};

pub const RenderCursor = extern struct {
    size: u64 = @sizeOf(RenderCursor),
    viewport_has_value: bool = false,
    viewport_x: u16 = 0,
    viewport_y: u16 = 0,
    wide_tail: bool = false,
    visible: bool = false,
    blinking: bool = false,
    password_input: bool = false,
    visual_style: i32 = 0,
};

pub const RenderColors = extern struct {
    size: u64 = @sizeOf(RenderColors),
    background: Rgb = .{},
    foreground: Rgb = .{},
    cursor: Rgb = .{},
    cursor_has_value: bool = false,
    palette: [256]Rgb = @splat(.{}),
};

pub const RowSelection = extern struct {
    size: u64 = @sizeOf(RowSelection),
    start_x: u16 = 0,
    end_x: u16 = 0,
};

pub const CellsView = extern struct { ptr: ?[*]const u64 = null, len: u64 = 0 };
pub const String = extern struct { ptr: ?[*]const u8 = null, len: u64 = 0 };

pub const Scrollbar = extern struct { total: u64 = 0, offset: u64 = 0, len: u64 = 0 };

pub const ScrollViewport = extern struct {
    tag: i32,
    _pad: u32 = 0,
    value: [2]u64 = .{ 0, 0 },

    pub const top = 0;
    pub const bottom = 1;
    pub const delta = 2;
    pub const row = 3;
};

pub const ModeConfig = extern struct { mode: u16, value: bool = false };

/// A cell of the terminal, valid until the terminal next changes.
pub const GridRef = extern struct {
    size: u64 = @sizeOf(GridRef),
    node: ?*anyopaque = null,
    x: u16 = 0,
    y: u16 = 0,
};

pub const PointCoordinate = extern struct { x: u16 = 0, _pad: u16 = 0, y: u32 = 0 };

pub const Point = extern struct {
    tag: i32,
    _pad: u32 = 0,
    value: PointCoordinate = .{},
    _pad2: u64 = 0,

    pub const active = 0;
    pub const viewport = 1;
    /// The screen and its scrollback, from the top of the scrollback.
    pub const screen = 2;
};

pub const Selection = extern struct {
    size: u64 = @sizeOf(Selection),
    start: GridRef = .{},
    end: GridRef = .{},
    rectangle: bool = false,
};

pub const SelectionFormatOptions = extern struct {
    size: u64 = @sizeOf(SelectionFormatOptions),
    emit: i32 = 0,
    unwrap: bool = false,
    trim: bool = false,
    selection: ?*const Selection = null,
};

pub const FormatterScreenExtra = extern struct {
    size: u64 = @sizeOf(FormatterScreenExtra),
    cursor: bool = false,
    style: bool = false,
    hyperlink: bool = false,
    protection: bool = false,
    kitty_keyboard: bool = false,
    charsets: bool = false,
};

pub const FormatterTerminalExtra = extern struct {
    size: u64 = @sizeOf(FormatterTerminalExtra),
    palette: bool = false,
    modes: bool = false,
    scrolling_region: bool = false,
    tabstops: bool = false,
    pwd: bool = false,
    keyboard: bool = false,
    screen: FormatterScreenExtra = .{},
};

pub const FormatterTerminalOptions = extern struct {
    size: u64 = @sizeOf(FormatterTerminalOptions),
    emit: i32 = 0,
    unwrap: bool = false,
    trim: bool = false,
    extra: FormatterTerminalExtra = .{},
    selection: ?*const Selection = null,
};

pub const MouseEncoderSize = extern struct {
    size: u64 = @sizeOf(MouseEncoderSize),
    screen_width: u32 = 1,
    screen_height: u32 = 1,
    cell_width: u32 = 1,
    cell_height: u32 = 1,
    padding_top: u32 = 0,
    padding_bottom: u32 = 0,
    padding_right: u32 = 0,
    padding_left: u32 = 0,
};

pub const MousePosition = extern struct { x: f32, y: f32 };

pub const SizeReportSize = extern struct { rows: u16, columns: u16, cell_width: u32, cell_height: u32 };

pub const DeviceAttributesPrimary = extern struct {
    conformance_level: u16 = 0,
    features: [64]u16 = @splat(0),
    num_features: u64 = 0,
};
pub const DeviceAttributesSecondary = extern struct { device_type: u16 = 0, firmware_version: u16 = 0, rom_cartridge: u16 = 0 };
pub const DeviceAttributesTertiary = extern struct { unit_id: u32 = 0 };
pub const DeviceAttributes = extern struct {
    primary: DeviceAttributesPrimary = .{},
    secondary: DeviceAttributesSecondary = .{},
    tertiary: DeviceAttributesTertiary = .{},
};

/// GhosttyTerminalOption.
pub const Opt = enum(c_int) {
    userdata = 0,
    write_pty = 1,
    bell = 2,
    title_changed = 5,
    size = 6,
    device_attributes = 8,
    color_foreground = 11,
    color_background = 12,
    color_cursor = 13,
    color_palette = 14,
    kitty_image_storage_limit = 15,
    selection = 21,
    default_cursor_style = 22,
    default_cursor_blink = 23,
    scrollback_max_bytes = 27,
    mode_default = 33,
    mode = 34,
    terminfo_name = 37,
    resize_pull_scrollback = 40,
};

/// GhosttyTerminalData.
pub const Data = enum(c_int) {
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    active_screen = 6,
    scrollbar = 9,
    mouse_tracking = 11,
    title = 12,
    pwd = 13,
    viewport_active = 32,
    mode = 37,
};

/// GhosttyRenderStateData, GhosttyRenderStateRowData, GhosttyRenderStateRowCellsData.
pub const rs_dirty = 3;
pub const rs_row_iterator = 4;
pub const rs_cursor = 18;
pub const rs_colors = 19;
pub const row_dirty = 1;
pub const row_cells = 3;
pub const row_selection = 4;
pub const row_cells_raw = 5;
pub const cell_style = 2;
pub const cell_graphemes_len = 3;
pub const cell_graphemes_buf = 4;

// Callbacks the terminal calls, with the userdata it was given.
pub const WritePtyFn = *const fn (t: *Terminal, ud: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void;
pub const NotifyFn = *const fn (t: *Terminal, ud: ?*anyopaque) callconv(.c) void;
pub const SizeFn = *const fn (t: *Terminal, ud: ?*anyopaque, out: *SizeReportSize) callconv(.c) bool;
pub const AttributesFn = *const fn (t: *Terminal, ud: ?*anyopaque, out: *DeviceAttributes) callconv(.c) bool;

const A = ?*const anyopaque; // an allocator: null for the library's own

/// The functions myzig calls, looked up by name.
pub const Api = struct {
    ghostty_type_json: *const fn () callconv(.c) ?[*:0]const u8,
    ghostty_terminal_new: *const fn (alloc: A, out: *?*Terminal, cols: usize, rows: usize) callconv(.c) Result,
    ghostty_terminal_free: *const fn (t: *Terminal) callconv(.c) void,
    ghostty_terminal_reset: *const fn (t: *Terminal) callconv(.c) void,
    ghostty_terminal_resize: *const fn (t: *Terminal, cols: usize, rows: usize, cw: usize, ch: usize) callconv(.c) Result,
    ghostty_terminal_set: *const fn (t: *Terminal, opt: Opt, value: ?*const anyopaque) callconv(.c) Result,
    ghostty_terminal_get: *const fn (t: *Terminal, data: Data, out: *anyopaque) callconv(.c) Result,
    ghostty_terminal_vt_write: *const fn (t: *Terminal, data: [*]const u8, len: usize) callconv(.c) void,
    ghostty_terminal_scroll_viewport: *const fn (t: *Terminal, v: ScrollViewport) callconv(.c) void,
    ghostty_terminal_grid_ref: *const fn (t: *Terminal, p: Point, out: *GridRef) callconv(.c) Result,
    ghostty_terminal_selection_format_alloc: *const fn (t: *Terminal, alloc: A, opts: SelectionFormatOptions, out: *?[*]u8, len: *usize) callconv(.c) Result,
    ghostty_formatter_terminal_new: *const fn (alloc: A, out: *?*Formatter, t: *Terminal, opts: FormatterTerminalOptions) callconv(.c) Result,
    ghostty_formatter_format_alloc: *const fn (f: *Formatter, alloc: A, out: *?[*]u8, len: *usize) callconv(.c) Result,
    ghostty_formatter_free: *const fn (f: *Formatter) callconv(.c) void,
    ghostty_free: *const fn (alloc: A, ptr: [*]u8, len: usize) callconv(.c) void,
    ghostty_grid_ref_hyperlink_uri: *const fn (ref: *const GridRef, buf: [*]u8, len: usize, n: *usize) callconv(.c) Result,
    ghostty_grid_ref_graphemes: *const fn (ref: *const GridRef, buf: [*]u32, len: usize, n: *usize) callconv(.c) Result,
    ghostty_grid_ref_cell: *const fn (ref: *const GridRef, out: *u64) callconv(.c) Result,

    ghostty_render_state_new: *const fn (alloc: A, out: *?*RenderState) callconv(.c) Result,
    ghostty_render_state_free: *const fn (rs: *RenderState) callconv(.c) void,
    ghostty_render_state_begin_update: *const fn (rs: *RenderState, t: *Terminal) callconv(.c) Result,
    ghostty_render_state_end_update: *const fn (rs: *RenderState) callconv(.c) void,
    ghostty_render_state_clean: *const fn (rs: *RenderState) callconv(.c) void,
    ghostty_render_state_get: *const fn (rs: *RenderState, data: c_int, out: *anyopaque) callconv(.c) Result,
    ghostty_render_state_row_iterator_new: *const fn (alloc: A, out: *?*RowIterator) callconv(.c) Result,
    ghostty_render_state_row_iterator_free: *const fn (it: *RowIterator) callconv(.c) void,
    ghostty_render_state_row_iterator_next: *const fn (it: *RowIterator) callconv(.c) bool,
    ghostty_render_state_row_get: *const fn (it: *RowIterator, data: c_int, out: *anyopaque) callconv(.c) Result,
    ghostty_render_state_row_cells_new: *const fn (alloc: A, out: *?*RowCells) callconv(.c) Result,
    ghostty_render_state_row_cells_free: *const fn (cells: *RowCells) callconv(.c) void,
    ghostty_render_state_row_cells_select: *const fn (cells: *RowCells, x: usize) callconv(.c) Result,
    ghostty_render_state_row_cells_get: *const fn (cells: *RowCells, data: c_int, out: *anyopaque) callconv(.c) Result,

    ghostty_key_encoder_new: *const fn (alloc: A, out: *?*KeyEncoder) callconv(.c) Result,
    ghostty_key_encoder_free: *const fn (e: *KeyEncoder) callconv(.c) void,
    ghostty_key_encoder_setopt: *const fn (e: *KeyEncoder, opt: c_int, value: *const anyopaque) callconv(.c) void,
    ghostty_key_encoder_setopt_from_terminal: *const fn (e: *KeyEncoder, t: *Terminal) callconv(.c) void,
    ghostty_key_encoder_encode: *const fn (e: *KeyEncoder, ev: *KeyEvent, buf: [*]u8, len: usize, n: *usize) callconv(.c) Result,
    ghostty_key_event_new: *const fn (alloc: A, out: *?*KeyEvent) callconv(.c) Result,
    ghostty_key_event_free: *const fn (ev: *KeyEvent) callconv(.c) void,
    ghostty_key_event_set_action: *const fn (ev: *KeyEvent, action: c_int) callconv(.c) void,
    ghostty_key_event_set_key: *const fn (ev: *KeyEvent, key: c_int) callconv(.c) void,
    ghostty_key_event_set_mods: *const fn (ev: *KeyEvent, mods: u16) callconv(.c) void,
    ghostty_key_event_set_consumed_mods: *const fn (ev: *KeyEvent, mods: u16) callconv(.c) void,
    ghostty_key_event_set_composing: *const fn (ev: *KeyEvent, on: bool) callconv(.c) void,
    ghostty_key_event_set_utf8: *const fn (ev: *KeyEvent, text: ?[*]const u8, len: usize) callconv(.c) void,
    ghostty_key_event_set_unshifted_codepoint: *const fn (ev: *KeyEvent, cp: u32) callconv(.c) void,

    ghostty_mouse_encoder_new: *const fn (alloc: A, out: *?*MouseEncoder) callconv(.c) Result,
    ghostty_mouse_encoder_free: *const fn (e: *MouseEncoder) callconv(.c) void,
    ghostty_mouse_encoder_setopt: *const fn (e: *MouseEncoder, opt: c_int, value: *const anyopaque) callconv(.c) void,
    ghostty_mouse_encoder_setopt_from_terminal: *const fn (e: *MouseEncoder, t: *Terminal) callconv(.c) void,
    ghostty_mouse_encoder_encode: *const fn (e: *MouseEncoder, ev: *MouseEvent, buf: [*]u8, len: usize, n: *usize) callconv(.c) Result,
    ghostty_mouse_event_new: *const fn (alloc: A, out: *?*MouseEvent) callconv(.c) Result,
    ghostty_mouse_event_free: *const fn (ev: *MouseEvent) callconv(.c) void,
    ghostty_mouse_event_set_action: *const fn (ev: *MouseEvent, action: c_int) callconv(.c) void,
    ghostty_mouse_event_set_button: *const fn (ev: *MouseEvent, button: c_int) callconv(.c) void,
    ghostty_mouse_event_clear_button: *const fn (ev: *MouseEvent) callconv(.c) void,
    ghostty_mouse_event_set_mods: *const fn (ev: *MouseEvent, mods: u16) callconv(.c) void,
    ghostty_mouse_event_set_position: *const fn (ev: *MouseEvent, pos: MousePosition) callconv(.c) void,

    ghostty_focus_encode: *const fn (event: c_int, buf: [*]u8, len: usize, n: *usize) callconv(.c) Result,
    ghostty_paste_encode: *const fn (data: [*]u8, len: usize, bracketed: bool, buf: [*]u8, buf_len: usize, n: *usize) callconv(.c) Result,
    ghostty_paste_is_safe: *const fn (data: [*]const u8, len: usize) callconv(.c) bool,
};

pub var api: Api = undefined;
var state: std.atomic.Value(u8) = .init(0); // 0 not loaded, 1 loading, 2 loaded, 3 failed
var failure: anyerror = error.GhosttyMissing;

/// Whether `load` succeeded.
pub fn loaded() bool {
    return state.load(.acquire) == 2;
}

/// Loads the library at `path` once, checking its layouts; later calls
/// report how it went, whatever their path. Safe from any thread.
pub fn load(path: [:0]const u8) !void {
    while (true) switch (state.load(.acquire)) {
        2 => return,
        3 => return failure,
        0 => if (state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            loadOnce(path) catch |err| {
                failure = err;
                state.store(3, .release);
                return err;
            };
            state.store(2, .release);
            return;
        },
        else => std.atomic.spinLoopHint(),
    };
}

fn loadOnce(path: [:0]const u8) !void {
    const lib = dl.open(path) orelse return error.GhosttyMissing;
    inline for (@typeInfo(Api).@"struct".field_names) |f| {
        const sym = dl.sym(lib, f) orelse return error.GhosttyIncompatible;
        @field(api, f) = @ptrCast(@alignCast(sym));
    }
    const manifest = api.ghostty_type_json() orelse return error.GhosttyIncompatible;
    try @import("layouts.zig").check(std.mem.span(manifest));
}

pub const dl = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(lib: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

    pub fn open(name: [:0]const u8) ?*anyopaque {
        var wide: [1024:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, name) catch return null;
        wide[n] = 0;
        return LoadLibraryW(wide[0..n :0]);
    }

    pub fn sym(lib: *anyopaque, name: [:0]const u8) ?*anyopaque {
        return GetProcAddress(lib, name);
    }
} else struct {
    pub fn open(name: [:0]const u8) ?*anyopaque {
        return std.c.dlopen(name, .{ .NOW = true });
    }

    pub fn sym(lib: *anyopaque, name: [:0]const u8) ?*anyopaque {
        return std.c.dlsym(lib, name);
    }
};
