//! The handler of a macOS page: the WKWebView's script message handler,
//! scheme handler, navigation, UI and download delegate, and observer of
//! its title. Each method finds its page through the handler's Zig pointer,
//! which the page clears as it goes.
const std = @import("std");
const objc = @import("objc.zig");
const types = @import("page_types.zig");
const extra = @import("page_mac_extra.zig");
const Page = @import("page.zig").Page;

pub fn handlerClass() objc.Class {
    return objc.defineClass(.{
        .name = "MyZigPageHandler",
        .protocols = &.{ "WKScriptMessageHandler", "WKURLSchemeHandler", "WKNavigationDelegate", "WKUIDelegate", "WKDownloadDelegate" },
        .methods = &.{
            .{ .name = "userContentController:didReceiveScriptMessage:", .imp = &didReceiveScriptMessage, .types = "v@:@@" },
            .{ .name = "webView:startURLSchemeTask:", .imp = &extra.startTask, .types = "v@:@@" },
            .{ .name = "webView:stopURLSchemeTask:", .imp = &extra.stopTask, .types = "v@:@@" },
            .{ .name = "webView:didStartProvisionalNavigation:", .imp = &didStart, .types = "v@:@@" },
            .{ .name = "webView:didCommitNavigation:", .imp = &didCommit, .types = "v@:@@" },
            .{ .name = "webView:didFinishNavigation:", .imp = &didFinish, .types = "v@:@@" },
            .{ .name = "webView:didFailNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
            .{ .name = "webView:didFailProvisionalNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
            .{ .name = "webView:decidePolicyForNavigationAction:decisionHandler:", .imp = &decideAction, .types = "v@:@@@?" },
            .{ .name = "webView:decidePolicyForNavigationResponse:decisionHandler:", .imp = &decideResponse, .types = "v@:@@@?" },
            .{ .name = "webView:navigationAction:didBecomeDownload:", .imp = &extra.becameDownload, .types = "v@:@@@" },
            .{ .name = "webView:navigationResponse:didBecomeDownload:", .imp = &extra.becameDownload, .types = "v@:@@@" },
            .{ .name = "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:", .imp = &extra.decideDestination, .types = "v@:@@@@?" },
            .{ .name = "downloadDidFinish:", .imp = &extra.downloadFinished, .types = "v@:@" },
            .{ .name = "download:didFailWithError:resumeData:", .imp = &extra.downloadFailed, .types = "v@:@@@" },
            .{ .name = "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", .imp = &createWebView, .types = "@@:@@@@" },
            .{ .name = "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:", .imp = &mediaPermission, .types = "v@:@@@q@?" },
            .{ .name = "observeValueForKeyPath:ofObject:change:context:", .imp = &observe, .types = "v@:@@@^v" },
        },
    });
}

/// Calls a block WebKit passed with its one argument.
pub fn callBlock(block: *anyopaque, arg: anytype) void {
    const Header = extern struct { isa: *anyopaque, flags: i32, reserved: i32, invoke: *const anyopaque };
    const h: *const Header = @ptrCast(@alignCast(block));
    const F = fn (*anyopaque, @TypeOf(arg)) callconv(.c) void;
    const f: *const F = @ptrCast(@alignCast(h.invoke));
    f(block, arg);
}

fn pageOf(handler: objc.Object) ?*Page {
    const page = objc.getZig(Page, handler) orelse return null;
    return if (page.dead) null else page;
}

fn didReceiveScriptMessage(self_obj: objc.Object, _: objc.SEL, _: objc.Object, message: objc.Object) callconv(.c) void {
    const page = pageOf(self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const body = objc.msg(?objc.Object, message, "body", .{}) orelse return;
    if (!objc.msg(objc.BOOL, body, "isKindOfClass:", .{objc.class("NSString")})) return;
    // The message may close the window, and free the page.
    page.received(objc.fromNSString(body));
}

/// An NSURL's absolute string, while the pool lives.
fn urlString(nsurl: ?objc.Object) []const u8 {
    return objc.fromNSString(objc.msg(?objc.Object, nsurl orelse return "", "absoluteString", .{}));
}

fn didStart(self_obj: objc.Object, _: objc.SEL, webview: objc.Object, _: ?objc.Object) callconv(.c) void {
    const page = pageOf(self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    page.navigated();
    page.core.fire(.{ .load_started = urlString(objc.msg(?objc.Object, webview, "URL", .{})) });
}

fn didCommit(self_obj: objc.Object, _: objc.SEL, webview: objc.Object, _: ?objc.Object) callconv(.c) void {
    const page = pageOf(self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    page.core.fire(.{ .committed = urlString(objc.msg(?objc.Object, webview, "URL", .{})) });
}

fn didFinish(self_obj: objc.Object, _: objc.SEL, webview: objc.Object, _: ?objc.Object) callconv(.c) void {
    const page = pageOf(self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    page.core.fire(.{ .load_finished = urlString(objc.msg(?objc.Object, webview, "URL", .{})) });
}

fn didFail(self_obj: objc.Object, _: objc.SEL, webview: objc.Object, _: ?objc.Object, err: objc.Object) callconv(.c) void {
    const page = pageOf(self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const code = objc.msg(objc.NSInteger, err, "code", .{});
    if (code == -999) return; // NSURLErrorCancelled: another navigation
    page.core.fire(.{ .load_failed = .{
        .url = urlString(objc.msg(?objc.Object, webview, "URL", .{})),
        .code = @intCast(std.math.clamp(code, std.math.minInt(i32), std.math.maxInt(i32))),
        .description = objc.fromNSString(objc.msg(?objc.Object, err, "localizedDescription", .{})),
    } });
}

// WKNavigationActionPolicy and WKNavigationResponsePolicy.
const policy_cancel: objc.NSInteger = 0;
const policy_allow: objc.NSInteger = 1;
const policy_download: objc.NSInteger = 2;

fn decideAction(self_obj: objc.Object, _: objc.SEL, _: objc.Object, action: objc.Object, handler: *anyopaque) callconv(.c) void {
    const page = pageOf(self_obj) orelse return callBlock(handler, policy_allow);
    const pool = objc.Pool.push();
    defer pool.pop();
    if (objc.msg(objc.BOOL, action, "respondsToSelector:", .{objc.sel("shouldPerformDownload")}) and objc.msg(objc.BOOL, action, "shouldPerformDownload", .{}))
        return callBlock(handler, policy_download);
    const frame = objc.msg(?objc.Object, action, "targetFrame", .{});
    const main = if (frame) |f| objc.msg(objc.BOOL, f, "isMainFrame", .{}) else false;
    if (!main) return callBlock(handler, policy_allow);
    const request = objc.msg(objc.Object, action, "request", .{});
    const url = urlString(objc.msg(?objc.Object, request, "URL", .{}));
    const user = objc.msg(objc.NSInteger, action, "navigationType", .{}) == 0; // a link activated
    callBlock(handler, if (page.core.willNavigate(url, user)) policy_allow else policy_cancel);
}

fn decideResponse(_: objc.Object, _: objc.SEL, _: objc.Object, response: objc.Object, handler: *anyopaque) callconv(.c) void {
    const show = objc.msg(objc.BOOL, response, "canShowMIMEType", .{});
    callBlock(handler, if (show) policy_allow else policy_download);
}

/// `window.open` and `target=_blank`: no web view of WebKit's; the app hears of it.
fn createWebView(self_obj: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, action: objc.Object, _: objc.Object) callconv(.c) ?objc.Object {
    const page = pageOf(self_obj) orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const request = objc.msg(objc.Object, action, "request", .{});
    page.core.newWindow(urlString(objc.msg(?objc.Object, request, "URL", .{})));
    return null;
}

/// Camera and microphone (macOS 12+); WKWebView has no geolocation or
/// notifications to ask about.
fn mediaPermission(self_obj: objc.Object, _: objc.SEL, _: objc.Object, origin: objc.Object, _: objc.Object, kind: objc.NSInteger, handler: *anyopaque) callconv(.c) void {
    const grant: objc.NSInteger = 1;
    const deny: objc.NSInteger = 2;
    const page = pageOf(self_obj) orelse return callBlock(handler, deny);
    const pool = objc.Pool.push();
    defer pool.pop();
    var buf: [256]u8 = undefined;
    const proto = objc.fromNSString(objc.msg(?objc.Object, origin, "protocol", .{}));
    const host = objc.fromNSString(objc.msg(?objc.Object, origin, "host", .{}));
    const port = objc.msg(objc.NSInteger, origin, "port", .{});
    const o = (if (port > 0) std.fmt.bufPrint(&buf, "{s}://{s}:{d}", .{ proto, host, port }) else std.fmt.bufPrint(&buf, "{s}://{s}", .{ proto, host })) catch "";
    const kinds: []const types.Permission = switch (kind) {
        0 => &.{.camera},
        1 => &.{.microphone},
        else => &.{ .camera, .microphone },
    };
    callBlock(handler, if (page.core.permission(kinds, o)) grant else deny);
}

fn observe(self_obj: objc.Object, _: objc.SEL, key: objc.Object, object: objc.Object, _: ?objc.Object, _: ?*anyopaque) callconv(.c) void {
    const page = pageOf(self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (!std.mem.eql(u8, objc.fromNSString(key), "title")) return;
    const t = objc.fromNSString(objc.msg(?objc.Object, object, "title", .{}));
    if (t.len > 0) page.core.fire(.{ .title_changed = t });
}
