//! Signals, computeds and effects, a port of
//! [alien-signals](https://github.com/stackblitz/alien-signals) (3.2.1):
//! state an app keeps in one place, values derived from it on demand and
//! cached, and work that runs again when what it read changes.
//!
//!     var count = signals.Signal(i32).init(0);
//!     var doubled = signals.Computed(i32).init(struct {
//!         fn get(_: ?i32) i32 { return count.get() * 2; }
//!     }.get);
//!
//!     const e = signals.effect(struct {
//!         fn run() void { std.debug.print("{d}\n", .{doubled.get()}); }
//!     }.run); // prints 0
//!     count.set(1); // prints 2
//!     e.dispose();
//!
//! The graph is global, as alien-signals' is, and belongs to one thread
//! (the main thread, in an app; safe builds panic on a call from another).
//! Signals and computeds are the caller's values, which must stay put
//! while anything reads them (globals, or fields of state that outlives
//! its effects); effects, scopes and the links between nodes come from
//! `allocator`. A computed can own its value (text it allocates) and free
//! it once replaced (`Computed.withOptions`). A read can't fail, so
//! running out of memory panics.
//!
//! `system.zig` is alien-signals' `system.ts` (the graph); `values.zig`
//! and `core.zig` are its `index.ts` (the values, and the global state
//! that runs effects).
const std = @import("std");
const builtin = @import("builtin");
const system = @import("system.zig");
const core = @import("core.zig");
const values = @import("values.zig");

pub const Node = system.Node;
pub const Link = system.Link;
pub const Kind = system.Kind;
pub const flags = system.flags;
pub const Signal = values.Signal;
pub const Computed = values.Computed;
pub const Effect = core.Effect;

/// Where effects, scopes and links come from. Set it before the first
/// signal is read or effect made.
pub var allocator: std.mem.Allocator = if (builtin.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.smp_allocator;

pub fn effect(comptime f: fn () void) *Effect {
    return core.startEffect(.plain(f));
}

/// An effect of `ctx` (a pointer): `f(ctx)`.
pub fn effectWith(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) *Effect {
    return core.startEffect(.with(ctx, f));
}

pub fn effectScope(comptime f: fn () void) *Effect {
    return core.startScope(.plain(f));
}

pub fn effectScopeWith(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) *Effect {
    return core.startScope(.with(ctx, f));
}

/// Gives the effect running now a cleanup, called before it runs again
/// and when it is disposed (alien-signals' effect returning a function).
/// One per run; outside an effect's own function it does nothing.
pub fn onCleanup(comptime f: fn () void) void {
    core.setCleanup(.plain(f));
}

pub fn onCleanupWith(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) void {
    core.setCleanup(.with(ctx, f));
}

/// Runs `f`, then runs again what reads the signals and computeds it
/// read, as if they had changed (for values changed in place).
pub fn trigger(comptime f: fn () void) void {
    core.triggerCallback(.plain(f));
}

pub fn triggerWith(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) void {
    core.triggerCallback(.with(ctx, f));
}

/// Holds effects back until the matching `endBatch`, so that several
/// writes run them once.
pub fn startBatch() void {
    core.checkThread();
    core.batch_depth += 1;
}

pub fn endBatch() void {
    core.enter();
    defer core.leave();
    core.batch_depth -= 1;
    if (core.batch_depth == 0) core.flush();
}

pub fn getBatchDepth() u32 {
    return core.batch_depth;
}

/// The node reads are linked to; `setActiveSub(null)` reads untracked,
/// and returns the previous one to put back.
pub fn getActiveSub() ?*Node {
    return core.active_sub;
}

pub fn setActiveSub(sub: ?*Node) ?*Node {
    return core.setActiveSub(sub);
}

/// Drops the effects waiting to run and frees the queue and what was
/// disposed, which are otherwise kept for the next write (for leak checks
/// in tests). No effect may be running.
pub fn deinit() void {
    core.deinit();
}

test {
    _ = @import("tests.zig");
    _ = @import("tests_owned.zig");
}
