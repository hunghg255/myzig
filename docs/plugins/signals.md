# signals

Global state for an app: signals hold values, computeds derive values from
them on demand and cache them, and effects run again when what they read
changes. It is a port of
[alien-signals](https://github.com/stackblitz/alien-signals) (3.2.1) to
Zig, keeping its algorithm (a push-pull graph of nodes joined by links,
with no allocation on a read that finds nothing changed) and its tests.

The package is `plugins/signals` (module `signals`); it depends on nothing,
not even myzig, so it serves native UI, pages' bound services and plain
Zig alike.

```zig
const signals = @import("signals");

const store = struct {
    var count = signals.Signal(i64).init(0);
    var doubled = signals.Computed(i64).init(struct {
        fn get(_: ?i64) i64 {
            return count.get() * 2;
        }
    }.get);
};

fn log() void {
    std.debug.print("{d}\n", .{store.doubled.get()});
}

const e = signals.effect(log); // prints 0
store.count.set(1); // prints 2
e.dispose();
```

## Signals

- `Signal(T).init(value)` makes one; it is the caller's value (a global, or
  a field of state that outlives its effects) and must not move while
  anything reads it.
- `get()` returns the value and makes the running effect or computed
  depend on it; `peek()` returns it without that.
- `set(value)` changes it. Values are compared with `std.meta.eql`, so a
  slice or pointer changes when its address does, as an object does in
  JavaScript; a `set` to an equal value does nothing.
- `mutate()` returns a pointer to change the value in place (append to a
  list it holds, change a field), and `trigger()` then runs what reads it
  again.

## Computeds

- `Computed(T).init(getter)` takes `fn (previous: ?T) T` (null the first
  time); `Computed(T).initWith(ctx, getter)` takes `fn (@TypeOf(ctx), ?T) T`
  for a pointer `ctx`.
- `get()` brings the value up to date and caches it: the getter runs only
  when something it read changed, and only when read. `peek()` reads it
  without depending on it.
- A computed read by effects lets go of what it read when they stop; one
  read outside any effect keeps its links until `deinit()`.
- `withOptions(.{ .eql = ..., .free = ... })` makes a computed own its
  value, such as text it allocates. `eql` decides whether a new value is
  the same as the previous one, so what reads it doesn't run again
  (`std.meta.eql`, slices by address, unless given). `free` frees each
  value once it is replaced (by anything but the previous value itself)
  and the last one at `deinit()`. The getter must not free its previous
  value.

```zig
fn sameText(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn freeText(s: []const u8) void {
    signals.allocator.free(s);
}

var label = signals.Computed([]const u8).init(struct {
    fn get(_: ?[]const u8) []const u8 {
        return std.fmt.allocPrint(signals.allocator, "Count: {d}", .{count.get()}) catch @panic("OOM");
    }
}.get).withOptions(.{ .eql = sameText, .free = freeText });
```

- A replaced value is freed only once no signal call is under way and no
  batch is open, so a value read stays valid until the write that changes
  it has returned: an effect holding it while its own write makes another
  effect compute the next value still reads the old one. Keep it past that
  and copy it. A view can show it as it is: native UI copies a text into
  the frame's memory.

## Effects and scopes

- `effect(f)` (`fn () void`) or `effectWith(ctx, f)` (`fn (@TypeOf(ctx))
  void`) runs `f` now and again after each change to what it read. It
  returns an `*Effect`; `dispose()` stops it.
- `onCleanup(f)` / `onCleanupWith(ctx, f)`, called in an effect's
  function, gives it a cleanup that runs before its next run and when it
  is disposed (the function an alien-signals effect returns).
- Effects and scopes made while an effect runs belong to it: they are
  disposed, innermost and latest first, when it runs again or is
  disposed. Don't dispose them yourself after that.
- Each effect and scope is disposed once, by the caller or by its own
  function (a child also by its parent, unless the caller disposed it
  first). Without a garbage collector, its pointer is not to be used after
  that, where alien-signals lets a dispose be called again.
- `effectScope(f)` / `effectScopeWith(ctx, f)` runs `f` once and collects
  the effects it makes; disposing the scope disposes them.

## Batches, triggers, untracked reads

- `startBatch()` and `endBatch()` hold effects back until the outermost
  batch ends, so that several writes run each effect once.
- `trigger(f)` / `triggerWith(ctx, f)` runs `f`, then runs what reads the
  signals and computeds `f` read, as if they had changed.
- `setActiveSub(null)` reads untracked until the node it returned is put
  back; `getActiveSub()` and `getBatchDepth()` are alien-signals' own.

## Memory and threads

The graph is global, as alien-signals' is, and belongs to one thread: in
an app, the main thread (work from other threads reaches it through
[mainthread](mainthread.md)). In Debug and ReleaseSafe builds, a call from
another thread than the one that first used it panics; `signals.deinit()`
lets go of that thread. Effects, scopes and the links between nodes come
from `signals.allocator` (the SMP allocator, or the WebAssembly one); set
it before the first read. A read can't fail, so running out of memory
panics. What is disposed, unlinked or replaced in a computed that owns its
value is freed once no signal call is under way and no batch is open (a
disposed effect also waits until no effect is queued to run);
`signals.deinit()` drops the queue and frees the rest, for leak checks in
tests.

## With native UI

A view runs on every event, so it reads the store like any state. State
that changes outside events (a timer, a thread's result) needs the window
drawn again: an effect that reads what the view shows calls
`window.redraw()`, and only when it changes. The example keeps the
window's title in step the same way:

```zig
fn follow(win: *myzig.Window) void {
    var buf: [64]u8 = undefined;
    win.setTitle(std.fmt.bufPrint(&buf, "Signals: {d}", .{store.count.get()}) catch "Signals");
    win.redraw();
}

const win = try app.newWindow(.{ .content = .{ .view = .init(&state, view) } });
const e = signals.effectWith(win, follow);
defer e.dispose();
```

```sh
cd plugins/signals
zig build test                              # the tests, and the example rendered offscreen
zig build run                               # the example
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
