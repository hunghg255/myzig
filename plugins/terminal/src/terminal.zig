//! A terminal for myzig's native UI, after mygo's terminal plugin: a view
//! that runs the user's shell, or any program, in a pseudo-terminal
//! (ConPTY on Windows, /dev/ptmx elsewhere), with Ghostty's terminal
//! emulator, libghostty-vt, loaded at run time (no C is compiled, nothing
//! is linked).
//!
//!     const term = try terminal.Terminal.create(gpa, io, .{});
//!     defer term.destroy();
//!     fn view(s: *State, c: *ui.Context) void { terminal.view(c, s.term, &s.view); }
const std = @import("std");

pub const library = @import("library.zig");
pub const download = @import("download.zig");
pub const vt = @import("vt.zig");
pub const encode = @import("encode.zig");
pub const pty = @import("pty.zig");
pub const links = @import("links.zig");
pub const keys = @import("keys.zig");
const theme_mod = @import("theme.zig");
const session = @import("session.zig");
const view_mod = @import("view.zig");

pub const Terminal = session.Terminal;
pub const Options = session.Options;
pub const Event = session.Event;
pub const EventHandler = session.EventHandler;
pub const Theme = theme_mod.Theme;
pub const CursorStyle = vt.CursorStyle;
/// The theme Ghostty ships by name ("Catppuccin Mocha"), or null.
pub const ghosttyTheme = theme_mod.ghostty;
pub const ghosttyThemeCount = theme_mod.ghosttyCount;
pub const ghosttyThemeName = theme_mod.ghosttyName;

pub const view = view_mod.view;
pub const ViewState = view_mod.ViewState;

test {
    _ = library;
    _ = @import("layouts.zig");
    _ = @import("notify.zig");
    _ = vt;
    _ = encode;
    _ = pty;
    _ = links;
    _ = keys;
    _ = theme_mod;
    _ = session;
    _ = view_mod;
}
