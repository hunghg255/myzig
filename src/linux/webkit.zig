//! WebKitGTK (the API of webkit2gtk-4.1, or 4.0, for GTK 3), loaded the
//! first time a window shows a page: apps of native UI never load it.
//! Each function is looked up by the name of its field, as in gtk.zig:
//! those of `Api` every version has; those of `Newer` (answering schemes
//! with a status and headers, cookies through libsoup 3) may be missing,
//! and the features that need them say so.
const std = @import("std");

pub const WebView = anyopaque;
pub const SchemeFn = *const fn (request: *anyopaque, data: ?*anyopaque) callconv(.c) void;
/// GAsyncReadyCallback.
pub const AsyncFn = *const fn (source: ?*anyopaque, res: *anyopaque, data: ?*anyopaque) callconv(.c) void;
const Obj = *anyopaque;
const Str = [*:0]const u8;

pub const Api = struct {
    webkit_web_context_get_default: *const fn () callconv(.c) Obj,
    webkit_web_context_register_uri_scheme: *const fn (ctx: Obj, scheme: Str, cb: SchemeFn, data: ?*anyopaque, destroy: ?*anyopaque) callconv(.c) void,
    webkit_web_context_get_security_manager: *const fn (ctx: Obj) callconv(.c) Obj,
    webkit_web_context_get_cookie_manager: *const fn (ctx: Obj) callconv(.c) Obj,
    webkit_web_context_get_website_data_manager: *const fn (ctx: Obj) callconv(.c) Obj,
    webkit_website_data_manager_clear: *const fn (m: Obj, types: c_uint, timespan: i64, cancel: ?Obj, cb: AsyncFn, data: ?*anyopaque) callconv(.c) void,
    webkit_website_data_manager_clear_finish: *const fn (m: Obj, res: Obj, err: ?*?*anyopaque) callconv(.c) c_int,
    webkit_security_manager_register_uri_scheme_as_secure: *const fn (sm: Obj, scheme: Str) callconv(.c) void,
    webkit_security_manager_register_uri_scheme_as_cors_enabled: *const fn (sm: Obj, scheme: Str) callconv(.c) void,
    webkit_user_content_manager_new: *const fn () callconv(.c) Obj,
    webkit_user_content_manager_register_script_message_handler: *const fn (ucm: Obj, name: Str) callconv(.c) c_int,
    webkit_user_content_manager_add_script: *const fn (ucm: Obj, script: Obj) callconv(.c) void,
    webkit_user_content_manager_remove_all_scripts: *const fn (ucm: Obj) callconv(.c) void,
    webkit_user_script_new: *const fn (source: Str, frames: c_int, time: c_int, allow: ?*anyopaque, block: ?*anyopaque) callconv(.c) Obj,
    webkit_user_script_unref: *const fn (script: Obj) callconv(.c) void,
    webkit_web_view_new_with_user_content_manager: *const fn (ucm: Obj) callconv(.c) *WebView,
    webkit_web_view_get_user_content_manager: *const fn (wv: *WebView) callconv(.c) Obj,
    webkit_web_view_load_uri: *const fn (wv: *WebView, uri: Str) callconv(.c) void,
    webkit_web_view_load_html: *const fn (wv: *WebView, html: Str, base: ?Str) callconv(.c) void,
    webkit_web_view_reload: *const fn (wv: *WebView) callconv(.c) void,
    webkit_web_view_stop_loading: *const fn (wv: *WebView) callconv(.c) void,
    webkit_web_view_go_back: *const fn (wv: *WebView) callconv(.c) void,
    webkit_web_view_go_forward: *const fn (wv: *WebView) callconv(.c) void,
    webkit_web_view_can_go_back: *const fn (wv: *WebView) callconv(.c) c_int,
    webkit_web_view_can_go_forward: *const fn (wv: *WebView) callconv(.c) c_int,
    webkit_web_view_is_loading: *const fn (wv: *WebView) callconv(.c) c_int,
    webkit_web_view_get_uri: *const fn (wv: *WebView) callconv(.c) ?Str,
    webkit_web_view_get_title: *const fn (wv: *WebView) callconv(.c) ?Str,
    webkit_web_view_set_zoom_level: *const fn (wv: *WebView, zoom: f64) callconv(.c) void,
    webkit_web_view_get_zoom_level: *const fn (wv: *WebView) callconv(.c) f64,
    webkit_web_view_run_javascript: *const fn (wv: *WebView, script: Str, cancel: ?*anyopaque, cb: ?*anyopaque, data: ?*anyopaque) callconv(.c) void,
    webkit_web_view_get_settings: *const fn (wv: *WebView) callconv(.c) Obj,
    webkit_web_view_get_inspector: *const fn (wv: *WebView) callconv(.c) Obj,
    webkit_web_inspector_show: *const fn (i: Obj) callconv(.c) void,
    webkit_settings_set_enable_developer_extras: *const fn (s: Obj, on: c_int) callconv(.c) void,
    webkit_settings_set_javascript_can_open_windows_automatically: *const fn (s: Obj, on: c_int) callconv(.c) void,
    webkit_settings_set_user_agent: *const fn (s: Obj, ua: ?Str) callconv(.c) void,
    webkit_settings_get_user_agent: *const fn (s: Obj) callconv(.c) Str,
    webkit_settings_set_user_agent_with_application_details: *const fn (s: Obj, name: ?Str, version: ?Str) callconv(.c) void,
    webkit_settings_get_print_backgrounds: *const fn (s: Obj) callconv(.c) c_int,
    webkit_settings_set_print_backgrounds: *const fn (s: Obj, on: c_int) callconv(.c) void,
    webkit_javascript_result_get_js_value: *const fn (result: Obj) callconv(.c) Obj,
    webkit_uri_scheme_request_get_uri: *const fn (req: Obj) callconv(.c) Str,
    webkit_uri_scheme_request_get_scheme: *const fn (req: Obj) callconv(.c) Str,
    webkit_uri_scheme_request_get_path: *const fn (req: Obj) callconv(.c) Str,
    webkit_uri_scheme_request_get_web_view: *const fn (req: Obj) callconv(.c) *WebView,
    webkit_uri_scheme_request_finish: *const fn (req: Obj, stream: Obj, len: i64, mime: Str) callconv(.c) void,
    webkit_navigation_policy_decision_get_navigation_action: *const fn (d: Obj) callconv(.c) Obj,
    webkit_navigation_action_get_request: *const fn (a: Obj) callconv(.c) Obj,
    webkit_navigation_action_is_user_gesture: *const fn (a: Obj) callconv(.c) c_int,
    webkit_uri_request_get_uri: *const fn (r: Obj) callconv(.c) Str,
    webkit_policy_decision_use: *const fn (d: Obj) callconv(.c) void,
    webkit_policy_decision_ignore: *const fn (d: Obj) callconv(.c) void,
    webkit_policy_decision_download: *const fn (d: Obj) callconv(.c) void,
    webkit_response_policy_decision_get_response: *const fn (d: Obj) callconv(.c) Obj,
    webkit_response_policy_decision_is_mime_type_supported: *const fn (d: Obj) callconv(.c) c_int,
    webkit_uri_response_get_uri: *const fn (r: Obj) callconv(.c) Str,
    webkit_uri_response_get_http_headers: *const fn (r: Obj) callconv(.c) ?Obj,
    webkit_uri_response_get_content_length: *const fn (r: Obj) callconv(.c) u64,
    webkit_user_media_permission_request_get_type: *const fn () callconv(.c) usize,
    webkit_geolocation_permission_request_get_type: *const fn () callconv(.c) usize,
    webkit_notification_permission_request_get_type: *const fn () callconv(.c) usize,
    webkit_user_media_permission_is_for_audio_device: *const fn (r: Obj) callconv(.c) c_int,
    webkit_user_media_permission_is_for_video_device: *const fn (r: Obj) callconv(.c) c_int,
    webkit_permission_request_allow: *const fn (r: Obj) callconv(.c) void,
    webkit_permission_request_deny: *const fn (r: Obj) callconv(.c) void,
    webkit_download_get_request: *const fn (d: Obj) callconv(.c) Obj,
    webkit_download_get_web_view: *const fn (d: Obj) callconv(.c) ?*WebView,
    webkit_download_get_response: *const fn (d: Obj) callconv(.c) ?Obj,
    webkit_download_set_destination: *const fn (d: Obj, uri: Str) callconv(.c) void,
    webkit_download_set_allow_overwrite: *const fn (d: Obj, on: c_int) callconv(.c) void,
    webkit_download_get_received_data_length: *const fn (d: Obj) callconv(.c) u64,
    webkit_download_cancel: *const fn (d: Obj) callconv(.c) void,
    webkit_print_operation_new: *const fn (wv: *WebView) callconv(.c) Obj,
    webkit_print_operation_set_print_settings: *const fn (op: Obj, s: Obj) callconv(.c) void,
    webkit_print_operation_set_page_setup: *const fn (op: Obj, s: Obj) callconv(.c) void,
    webkit_print_operation_print: *const fn (op: Obj) callconv(.c) void,
    jsc_value_is_string: *const fn (v: Obj) callconv(.c) c_int,
    jsc_value_to_string: *const fn (v: Obj) callconv(.c) [*:0]u8,
    soup_message_headers_get_one: *const fn (h: Obj, name: Str) callconv(.c) ?Str,
    g_memory_input_stream_new_from_data: *const fn (data: [*]const u8, len: isize, destroy: ?*const anyopaque) callconv(.c) Obj,
    g_input_stream_read: *const fn (s: Obj, buf: [*]u8, count: usize, cancel: ?Obj, err: ?*?*anyopaque) callconv(.c) isize,
    g_malloc: *const fn (n: usize) callconv(.c) ?[*]u8,
    g_free: *const anyopaque,
    g_object_ref: *const fn (o: Obj) callconv(.c) Obj,
    g_list_free: *const fn (l: ?*anyopaque) callconv(.c) void,
    g_type_check_instance_is_a: *const fn (inst: Obj, t: usize) callconv(.c) c_int,
    gtk_window_begin_move_drag: *const fn (w: Obj, button: c_int, x: c_int, y: c_int, time: u32) callconv(.c) void,
    gdk_event_get_root_coords: *const fn (e: Obj, x: *f64, y: *f64) callconv(.c) c_int,
    gdk_event_get_time: *const fn (e: Obj) callconv(.c) u32,
    gtk_print_settings_new: *const fn () callconv(.c) Obj,
    gtk_print_settings_set: *const fn (s: Obj, k: Str, v: Str) callconv(.c) void,
    gtk_page_setup_new: *const fn () callconv(.c) Obj,
    gtk_paper_size_new_custom: *const fn (name: Str, display: Str, w: f64, h: f64, unit: c_int) callconv(.c) Obj,
    gtk_paper_size_free: *const fn (p: Obj) callconv(.c) void,
    gtk_page_setup_set_paper_size: *const fn (s: Obj, p: Obj) callconv(.c) void,
    gtk_page_setup_set_orientation: *const fn (s: Obj, o: c_int) callconv(.c) void,
    gtk_page_setup_set_top_margin: *const fn (s: Obj, m: f64, unit: c_int) callconv(.c) void,
    gtk_page_setup_set_right_margin: *const fn (s: Obj, m: f64, unit: c_int) callconv(.c) void,
    gtk_page_setup_set_bottom_margin: *const fn (s: Obj, m: f64, unit: c_int) callconv(.c) void,
    gtk_page_setup_set_left_margin: *const fn (s: Obj, m: f64, unit: c_int) callconv(.c) void,
};

/// Functions of newer WebKitGTK (2.36+) and of libsoup 3 (webkit2gtk-4.1).
pub const Newer = struct {
    webkit_uri_scheme_request_get_http_method: ?*const fn (req: Obj) callconv(.c) ?Str = null,
    webkit_uri_scheme_request_get_http_body: ?*const fn (req: Obj) callconv(.c) ?Obj = null,
    webkit_uri_scheme_request_finish_with_response: ?*const fn (req: Obj, resp: Obj) callconv(.c) void = null,
    webkit_uri_scheme_response_new: ?*const fn (stream: Obj, len: i64) callconv(.c) Obj = null,
    webkit_uri_scheme_response_set_status: ?*const fn (resp: Obj, status: c_uint, reason: ?Str) callconv(.c) void = null,
    webkit_uri_scheme_response_set_content_type: ?*const fn (resp: Obj, ct: Str) callconv(.c) void = null,
    webkit_uri_scheme_response_set_http_headers: ?*const fn (resp: Obj, h: Obj) callconv(.c) void = null,
    soup_message_headers_new: ?*const fn (kind: c_int) callconv(.c) Obj = null,
    soup_message_headers_append: ?*const fn (h: Obj, name: Str, value: Str) callconv(.c) void = null,
    webkit_cookie_manager_get_all_cookies: ?*const fn (cm: Obj, cancel: ?Obj, cb: AsyncFn, data: ?*anyopaque) callconv(.c) void = null,
    webkit_cookie_manager_get_all_cookies_finish: ?*const fn (cm: Obj, res: Obj, err: ?*?*anyopaque) callconv(.c) ?*List = null,
    webkit_cookie_manager_get_cookies: ?*const fn (cm: Obj, uri: Str, cancel: ?Obj, cb: AsyncFn, data: ?*anyopaque) callconv(.c) void = null,
    webkit_cookie_manager_get_cookies_finish: ?*const fn (cm: Obj, res: Obj, err: ?*?*anyopaque) callconv(.c) ?*List = null,
    webkit_cookie_manager_add_cookie: ?*const fn (cm: Obj, c: Obj, cancel: ?Obj, cb: AsyncFn, data: ?*anyopaque) callconv(.c) void = null,
    webkit_cookie_manager_add_cookie_finish: ?*const fn (cm: Obj, res: Obj, err: ?*?*anyopaque) callconv(.c) c_int = null,
    webkit_cookie_manager_delete_cookie: ?*const fn (cm: Obj, c: Obj, cancel: ?Obj, cb: AsyncFn, data: ?*anyopaque) callconv(.c) void = null,
    webkit_cookie_manager_delete_cookie_finish: ?*const fn (cm: Obj, res: Obj, err: ?*?*anyopaque) callconv(.c) c_int = null,
    soup_cookie_new: ?*const fn (name: Str, value: Str, domain: Str, path: Str, max_age: c_int) callconv(.c) Obj = null,
    soup_cookie_free: ?*const fn (c: Obj) callconv(.c) void = null,
    soup_cookie_get_name: ?*const fn (c: Obj) callconv(.c) Str = null,
    soup_cookie_get_value: ?*const fn (c: Obj) callconv(.c) Str = null,
    soup_cookie_get_domain: ?*const fn (c: Obj) callconv(.c) Str = null,
    soup_cookie_get_path: ?*const fn (c: Obj) callconv(.c) Str = null,
    soup_cookie_get_expires: ?*const fn (c: Obj) callconv(.c) ?Obj = null,
    soup_cookie_get_secure: ?*const fn (c: Obj) callconv(.c) c_int = null,
    soup_cookie_get_http_only: ?*const fn (c: Obj) callconv(.c) c_int = null,
    soup_cookie_get_same_site_policy: ?*const fn (c: Obj) callconv(.c) c_int = null,
    soup_cookie_set_expires: ?*const fn (c: Obj, dt: Obj) callconv(.c) void = null,
    soup_cookie_set_secure: ?*const fn (c: Obj, on: c_int) callconv(.c) void = null,
    soup_cookie_set_http_only: ?*const fn (c: Obj, on: c_int) callconv(.c) void = null,
    soup_cookie_set_same_site_policy: ?*const fn (c: Obj, p: c_int) callconv(.c) void = null,
    g_date_time_new_from_unix_utc: ?*const fn (t: i64) callconv(.c) ?Obj = null,
    g_date_time_to_unix: ?*const fn (dt: Obj) callconv(.c) i64 = null,
    g_date_time_unref: ?*const fn (dt: Obj) callconv(.c) void = null,
};

/// GList.
pub const List = extern struct { data: ?*anyopaque, next: ?*List, prev: ?*List };

pub var api: Api = undefined;
pub var newer: Newer = .{};
/// webkit2gtk-4.1, whose cookies are libsoup 3's (4.0 has libsoup 2's).
pub var soup3 = false;
var state: enum { unknown, loaded, missing } = .unknown;

const libraries = [_][:0]const u8{ "libwebkit2gtk-4.1.so.0", "libwebkit2gtk-4.0.so.37" };

/// Loads WebKitGTK; false when neither version is installed.
pub fn load() bool {
    switch (state) {
        .loaded => return true,
        .missing => return false,
        .unknown => {},
    }
    @setEvalBranchQuota(20_000);
    state = .missing;
    const lib = for (libraries, 0..) |name, i| {
        if (std.c.dlopen(name, .{ .NOW = true, .GLOBAL = true })) |l| {
            soup3 = i == 0;
            break l;
        }
    } else {
        std.log.err("myzig: pages need WebKitGTK (libwebkit2gtk-4.1 or 4.0), which is not installed", .{});
        return false;
    };
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse {
            std.log.err("myzig: WebKitGTK lacks {s}", .{name});
            return false;
        };
        @field(api, name) = @ptrCast(@alignCast(sym));
    }
    inline for (@typeInfo(Newer).@"struct".field_names) |name| {
        // libsoup 2's cookies take other arguments: no cookies with it.
        const cookies = comptime std.mem.indexOf(u8, name, "cookie") != null;
        if (soup3 or !cookies) if (std.c.dlsym(lib, name)) |sym| {
            @field(newer, name) = @ptrCast(@alignCast(sym));
        };
    }
    state = .loaded;
    return true;
}

/// Formats into `buf`, NUL-terminated; null when it does not fit.
pub fn printZ(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return null;
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// A NUL-terminated copy of `s`, in `gpa`.
pub fn dupeZ(gpa: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const z = try gpa.alloc(u8, s.len + 1);
    @memcpy(z[0..s.len], s);
    z[s.len] = 0;
    return z[0..s.len :0];
}

pub fn span(s: ?Str) []const u8 {
    return if (s) |p| std.mem.span(p) else "";
}
