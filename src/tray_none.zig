//! Tray icons where myzig has none (browsers).
pub const Options = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    symbol: []const u8 = "",
    tooltip: []const u8 = "",
};

pub const Tray = struct {
    pub fn destroy(_: *Tray) void {}
    pub fn setTitle(_: *Tray, _: []const u8) void {}
    pub fn setSymbol(_: *Tray, _: []const u8) void {}
    pub fn dark(_: *Tray) bool {
        return false;
    }
};
