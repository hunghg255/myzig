//! Whether the computer is online, the same on every platform: what the
//! app is told (`AppOptions.on_network`, `App.networkStatus`), and only
//! when it changed, since the systems report changes of routes and
//! interfaces that leave it as it was.
const std = @import("std");

pub const Status = struct {
    /// A connection to a network beyond the computer: a route out
    /// (macOS's satisfied path, Linux's GNetworkMonitor), on Windows a
    /// local network's or the internet's connectivity. A captive portal
    /// counts, as it does for browsers' navigator.onLine.
    online: bool = true,
    /// The connection costs by the amount of data, or is limited: send
    /// less, and ask before downloading much (a cellular or hotspot path,
    /// Low Data Mode, a metered connection, a roaming or capped cost).
    metered: bool = false,
};

/// The status listeners last saw.
pub const Tracker = struct {
    last: ?Status = null,

    /// `now`, if it differs from what was last seen.
    pub fn changed(t: *Tracker, now: Status) ?Status {
        if (t.last) |l| if (l.online == now.online and l.metered == now.metered) return null;
        const first = t.last == null;
        t.last = now;
        // The first status is the one the app starts with, not a change.
        return if (first) null else now;
    }
};

test "only changes of the network's status are told" {
    var t: Tracker = .{};
    try std.testing.expect(t.changed(.{ .online = true }) == null);
    try std.testing.expect(t.changed(.{ .online = true }) == null);
    try std.testing.expectEqual(false, t.changed(.{ .online = false }).?.online);
    try std.testing.expect(t.changed(.{ .online = false }) == null);
    try std.testing.expectEqual(true, t.changed(.{ .online = false, .metered = true }).?.metered);
}
