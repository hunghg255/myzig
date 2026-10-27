# signals

Global state for myzig apps: signals, computeds and effects, a port of
[alien-signals](https://github.com/stackblitz/alien-signals) (3.2.1) to
Zig. It depends on nothing, not even myzig.

```zig
const signals = @import("signals");

var count = signals.Signal(i64).init(0);
var doubled = signals.Computed(i64).init(struct {
    fn get(_: ?i64) i64 {
        return count.get() * 2;
    }
}.get);

const e = signals.effect(struct {
    fn run() void {
        std.debug.print("{d}\n", .{doubled.get()});
    }
}.run); // prints 0
count.set(1); // prints 2
e.dispose();
```

`src/system.zig` is alien-signals' `system.ts` (the graph), `src/signals.zig`
its `index.ts` (the API and the global state), and `src/tests.zig` its
tests. The [documentation](../../docs/plugins/signals.md) covers the API;
`example/` is native UI on a global store, with an effect that draws the
window again when the store changes outside events.

```sh
zig build test                              # the tests, and the example rendered offscreen
zig build run                               # the example
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
