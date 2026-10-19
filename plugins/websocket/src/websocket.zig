//! A WebSocket client for myzig apps, after mygo's websocket plugin: from
//! Zig with `Conn` (RFC 6455 over std.http.Client's connections, so wss:
//! is TLS), and from pages with a browser-like `WebSocket` (`client_js`)
//! whose connections Zig makes, with any header on the handshake.
//!
//!     var service: websocket.Service = try .init(gpa, app.io, .{});
//!     defer service.deinit();
//!     try app.bind(&service);
//!     try app.registerEvent(websocket.PartEvent);
//!
//!     import { WebSocket } from "/plugins/websocket.js";
//!     const ws = new WebSocket("wss://example.com/live", ["v1"], { headers: { authorization } });
const std = @import("std");
pub const frame = @import("frame.zig");
const conn = @import("conn.zig");
const service = @import("service.zig");

pub const Conn = conn.Conn;
pub const Options = conn.Options;
pub const Header = conn.Header;
pub const Message = conn.Message;
pub const Kind = conn.Kind;
pub const Code = frame.Code;

pub const Service = service.Service;
pub const ServiceOptions = service.Options;
pub const ConnectRequest = service.ConnectRequest;
pub const Part = service.Part;
pub const PartEvent = service.PartEvent;

/// The page's client, an ES module: add `asset` to a page's assets and
/// `import { WebSocket } from "/plugins/websocket.js"`.
pub const client_js = @embedFile("js/websocket.js");
pub const asset: @import("myzig").Asset = .{ .path = "/plugins/websocket.js", .data = client_js };

test {
    _ = frame;
    _ = conn;
    _ = service;
}
