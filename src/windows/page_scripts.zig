//! The scripts a WebView2 page runs in every document's main frame: the
//! bridge, then the user scripts, each known to WebView2 by the id it
//! gave, so that later documents can go without one removed.
const std = @import("std");
const com = @import("com.zig");
const Page = @import("page.zig").Page;

const bridge_js = @embedFile("../bridge.js");
const wv_add_script = 27;
const wv_remove_script = 28;

/// The bridge, then the user scripts.
pub fn addAll(page: *Page) void {
    add(page, bridge_js, false);
    for (page.core.scripts.items) |s| add(page, s.source, s.all_frames);
}

/// WebView2 runs a script in every frame: one for the top frame only
/// checks that it is in it.
pub fn add(page: *Page, source: []const u8, all_frames: bool) void {
    const wv = page.webview orelse return;
    const wrapped = if (all_frames) page.gpa.dupe(u8, source) catch return else std.fmt.allocPrint(page.gpa, "if(window===window.top){{\n{s}\n}}", .{source}) catch return;
    defer page.gpa.free(wrapped);
    const script = com.wide(page.gpa, wrapped) catch return;
    defer page.gpa.free(script);
    _ = com.withHandler(page, added, addCall, .{ wv, script.ptr });
}

fn addCall(wv: com.Object, script: [*:0]const u16, handler: com.Object) com.HRESULT {
    return com.call(wv, wv_add_script, .{ script, handler });
}

/// WebView2 tells the id of a script it added.
fn added(ctx: ?*anyopaque, hr: usize, id: usize) void {
    const page = Page.alive(ctx) orelse return;
    if (com.failed(@bitCast(@as(u32, @truncate(hr)))) or id == 0) return;
    const p: [*:0]const u16 = @ptrFromInt(id);
    const span = std.mem.span(p);
    const copy = page.gpa.allocSentinel(u16, span.len, 0) catch return;
    @memcpy(copy, span);
    page.script_ids.append(page.gpa, copy) catch page.gpa.free(copy);
}

/// Replaces the scripts of later documents with the bridge and the user
/// scripts as they are now.
pub fn replace(page: *Page) void {
    const wv = page.webview orelse return;
    for (page.script_ids.items) |id| {
        _ = com.call(wv, wv_remove_script, .{id.ptr});
        page.gpa.free(id);
    }
    page.script_ids.clearRetainingCapacity();
    addAll(page);
}
