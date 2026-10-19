//! HTTP(S) requests for myzig apps, after mygo's fetch plugin: from Zig
//! with `perform`, and from pages with a standard `fetch` (`client_js`)
//! whose requests leave from Zig, so they are not subject to CORS, may set
//! any header, and stream their bodies as they arrive.
//!
//!     var service: fetch.Service = try .init(gpa, app.io, .{});
//!     defer service.deinit();
//!     try app.bind(&service);
//!     try app.registerEvent(fetch.PartEvent);
//!
//!     import { fetch } from "/plugins/fetch.js";
//!     const res = await fetch("https://api.example.com/items", { headers: { authorization } });
const std = @import("std");
const http = @import("http.zig");
const service = @import("service.zig");

pub const Request = http.Request;
pub const Header = http.Header;
pub const Head = http.Head;
pub const Redirect = http.Redirect;
pub const Sink = http.Sink;
pub const perform = http.perform;
pub const chunk_size = http.chunk_size;

pub const Service = service.Service;
pub const Options = service.Options;
pub const PageRequest = service.PageRequest;
pub const Part = service.Part;
pub const PartEvent = service.PartEvent;

/// The page's client, an ES module: add `asset` to a page's assets and
/// `import { fetch } from "/plugins/fetch.js"`.
pub const client_js = @embedFile("js/fetch.js");
pub const asset: @import("myzig").Asset = .{ .path = "/plugins/fetch.js", .data = client_js };

test {
    _ = service;
}
