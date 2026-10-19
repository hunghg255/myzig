//! Programs in pseudo-terminals: ConPTY on Windows (`pty_windows.zig`),
//! /dev/ptmx through libc on macOS and Linux (`pty_posix.zig`). `read`
//! blocks until output comes, so a thread of its own reads.
const std = @import("std");
const builtin = @import("builtin");

/// A program to start in a pseudo-terminal.
pub const Options = struct {
    /// The program and its arguments: `argv[0]` is looked for on the PATH.
    argv: []const []const u8,
    /// The working directory: this process's when null.
    dir: ?[]const u8 = null,
    /// Variables set over this process's environment ("KEY=value").
    env: []const []const u8 = &.{},
    cols: u16 = 80,
    rows: u16 = 24,
    /// The size in pixels (for TIOCSWINSZ).
    width: u16 = 0,
    height: u16 = 0,
};

const impl = if (builtin.os.tag == .windows) @import("pty_windows.zig") else @import("pty_posix.zig");

/// A program running in a pseudo-terminal: `start`, then `read` its
/// output and `write` what is typed; `wait` for its exit, `hangUp` to end
/// it, and `deinit` once `read` returned 0.
pub const Pty = impl.Pty;

/// The user's shell, allocated with `gpa`.
pub const defaultShell = impl.defaultShell;

test {
    _ = impl;
}
