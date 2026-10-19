# mainthread

Work handed to the main thread from any other, for myzig's plugins: their
threads (an HTTP response, a WebSocket message, a file changed) give their
results to pages and views, which live on the main thread.

```zig
const mainthread = @import("mainthread");

try mainthread.init(); // once, on the main thread
_ = mainthread.post(job, Job.run); // from any thread: Job.run(job) runs on the main thread
```

It is the main thread's own queue on each platform, so nothing polls:

| platform | queue |
|---|---|
| macOS | libdispatch's main queue (`dispatch_async_f`) |
| Linux | GLib's default context (`g_idle_add`), which GTK's loop runs |
| Windows | a message-only window (`PostMessageW`), which the app's message loop runs |

Jobs run in the order they were posted. `runUntil(&flag)` runs the queue
until a flag is set, for tests and tools without an event loop of their
own.

```sh
zig build test                              # on this machine
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
