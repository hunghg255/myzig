# mainthread

Work handed to the main thread from any other. Pages and views live on the
main thread, and so do bound methods and window events; a plugin's threads
(an HTTP response, a WebSocket message, a file changed) give their results
to them through this package. The fetch, websocket, watch, updater and
terminal plugins depend on it.

The package is `plugins/mainthread` (module `mainthread`); it depends on
nothing, not even myzig.

```zig
const mainthread = @import("mainthread");

const Job = struct {
    window: *myzig.Window,
    result: []u8,

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        // On the main thread: emit an event, change a view's state, ...
        _ = job;
    }
};

try mainthread.init(); // once, on the main thread (plugins' services do it when created)
if (!mainthread.post(job, Job.run)) {
    // Not queued (no init, or out of memory): the caller still owns `job`.
}
```

- `init()` prepares the queue; calling it again does nothing.
- `post(ctx, func)` runs `func(ctx)` on the main thread, soon. It is safe
  from any thread; jobs run in the order they were posted. `func` is a
  `mainthread.Func`, `*const fn (?*anyopaque) callconv(.c) void`.
- `runUntil(&done)` runs the queue until an atomic flag is set, for tests
  and tools that have no event loop of their own (main thread only).

It is the main thread's own queue on each platform, so nothing polls:

| platform | queue |
|---|---|
| macOS | libdispatch's main queue (`dispatch_async_f`) |
| Linux | GLib's default context (`g_idle_add`), which GTK's loop runs |
| Windows | a message-only window (`PostMessageW`), which the app's message loop runs |

In browsers (`wasm32-wasi`) there is no other thread, and the package does
not compile there.

Within myzig itself, work reaches the main thread through
`myzig.App.after` (a timer) and, on macOS, `objc.dispatchMain`; see the
[architecture guide](../architecture.md) for the threading model.

```sh
cd plugins/mainthread
zig build test                              # on this machine
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
