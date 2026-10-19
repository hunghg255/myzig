//! File watching for myzig apps, after mygo's watch plugin and
//! `mygo.WatchFiles`: from Zig with `Watcher`, and from pages with
//! `watch(name)` (`client_js`) on the roots the app names, never paths.
//!
//!     const w = try watch.Watcher.init(gpa, io, dir, .{ .recursive = true });
//!     defer w.deinit();
//!     const events = try w.next(arena); // a batch: create, write, remove, rename
const std = @import("std");
const snapshot = @import("snapshot.zig");
const watcher = @import("watcher.zig");
const service = @import("service.zig");

pub const Watcher = watcher.Watcher;
pub const Options = watcher.Options;
pub const Event = snapshot.Event;
pub const Op = snapshot.Op;
pub const scan = snapshot.scan;
pub const diff = snapshot.diff;

pub const Service = service.Service;
pub const ServiceOptions = service.Options;
pub const Root = service.Root;
pub const Batch = service.Batch;
pub const BatchEvent = service.BatchEvent;

/// The page's client, an ES module: add `asset` to a page's assets and
/// `import { watch } from "/plugins/watch.js"`.
pub const client_js = @embedFile("js/watch.js");
pub const asset: @import("myzig").Asset = .{ .path = "/plugins/watch.js", .data = client_js };

test {
    _ = snapshot;
    _ = watcher;
    _ = service;
}
