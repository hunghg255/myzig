# Bindings

A page calls Zig through services the app binds, hears it through typed
events, and streams values both ways through channels. myzig generates the
page's client from the Zig types at compile time: a JavaScript module the
app serves at `/myzig.js`, and its TypeScript declarations, `myzig.d.ts`.

```zig
const Greeter = struct {
    pub const myzig_params = .{ .greet = .{"name"} };

    pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{name});
    }
};

const Tick = myzig.Event("tick", struct { uptime: u64 });

// in main, before the windows:
var greeter: Greeter = .{};
try app.bind(&greeter);
try app.registerEvent(Tick);
```

```js
import { Greeter, onTick } from "/myzig.js";

document.body.textContent = await Greeter.greet("Ada");
onTick(({ uptime }) => console.log(uptime));
```

## Bind a service

`app.bind(&service)` binds a pointer to any struct. Pages call it by the
struct's name, the last part of its type name (`Greeter`), or by the name
it declares with `pub const myzig_name = "Name";`. The service must
outlive the windows calling it: it is usually a variable of `main`.

Its methods are its public functions whose first parameter is the service
(`Greeter`, `*Greeter` or `*const Greeter`), that are not generic, and
whose name doesn't start with `_`. Other declarations are not part of it.

```zig
const Todos = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Todo) = .empty,
    next_id: u32 = 1,

    pub const myzig_params = .{ .add = .{"title"}, .toggle = .{"id"}, .remove = .{"id"} };

    pub fn list(self: *Todos) []const Todo {
        return self.items.items;
    }

    pub fn add(self: *Todos, title: []const u8) !Todo {
        const t = std.mem.trim(u8, title, " ");
        if (t.len == 0) return error.EmptyTitle;
        const todo: Todo = .{ .id = self.next_id, .title = try self.gpa.dupe(u8, t), .done = false };
        try self.items.append(self.gpa, todo);
        self.next_id += 1;
        return todo;
    }

    pub fn toggle(self: *Todos, id: u32) !Todo {
        for (self.items.items) |*t| if (t.id == id) {
            t.done = !t.done;
            return t.*;
        };
        return error.NoSuchTodo;
    }
};
```

Zig keeps no parameter names in function types, so a service names them
in `myzig_params`, a struct of the methods' names, each a tuple of names in
order. They name the parameters of the generated client; without them the
client says `arg0`, `arg1`, ... The documentation comments of methods are
not kept in the client either: Zig doesn't give them to comptime code.

The arguments come from the page as JSON and are parsed into the
parameters' types (unknown fields of objects are ignored). A call with too
few arguments fails with `MissingArgument`, with too many with
`TooManyArguments`, and with one that doesn't parse with
`InvalidArgument`. The result is written back as JSON.

Methods run on the main thread, one call at a time, so they may use the
app's state and windows freely, and a slow method holds up the app: start
long work on a thread of your own and answer later, through an
[event](#events) or a [channel](#channels).

### The call

A method may take a `*myzig.Call` after the service. It is not an argument
of the page's: the client leaves it out.

```zig
pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
    call.window.setTitle(name);
    return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{name});
}
```

- `call.arena` is freed once the reply is sent: allocate results in it,
  as well as anything the method needs only while it runs. Arguments
  (strings, slices) live in it too, so copy what you keep
  (`self.gpa.dupe`).
- `call.window` is the window whose page called. A method may close it;
  the reply is then dropped.

## Errors

A method returning an error union may fail. The page's promise rejects
with an `Error` whose message is the method and the error's name:

```js
try {
  await Todos.add(" ");
} catch (e) {
  e.message; // "Todos.add: EmptyTitle"
}
```

What the bridge itself refuses fails the same way: `UnknownService`,
`UnknownMethod`, the argument errors above, and `Untrusted` for a page the
app doesn't [trust](pages.md#trust).

## The generated client

The client is made of comptime declarations of the services and events,
and needs no build step: the app serves it at `/myzig.js`, so a page of
the app's frontend imports it as a module.

```js
import { Greeter, Todos, onTick, Channel } from "/myzig.js";
```

For TypeScript and editors, write `myzig.d.ts` (and a copy of `myzig.js`,
for bundlers that want the file) next to the frontend:

```sh
zig-out/bin/hello --myzig-generate=examples/hello/frontend   # any app: write the client and exit
zig build gen                                               # this repository's hello example
myzig generate                                              # an app made with `myzig init`
```

`--myzig-generate=DIR` makes `App.run` write `DIR/myzig.js` and
`DIR/myzig.d.ts` and return, without a window. The CLI's `myzig dev` and
`myzig build` write it too ([CLI](cli.md)). Regenerate it when services
change; `myzig.d.ts` is worth committing, so the frontend typechecks
without building the app.

```ts
// Generated by myzig. Do not edit.
export interface Todo {
  id: number;
  title: string;
  done: boolean;
}

export interface TickPayload {
  uptime: number;
  todos: number;
}

export declare const Greeter: {
  greet(name: string): Promise<string>;
};

export declare const Todos: {
  list(): Promise<Todo[]>;
  add(title: string): Promise<Todo>;
  toggle(id: number): Promise<Todo>;
  remove(id: number): Promise<void>;
};

export declare function onTick(listener: (payload: TickPayload) => void): () => void;
```

Services are sorted by name, so the output is stable, and their methods
keep the order of their declarations. Every method returns a promise.

### Types

| Zig | TypeScript |
|---|---|
| `bool` | `boolean` |
| integers and floats | `number` |
| `[]const u8`, `[N]u8` | `string` |
| `[]const T`, `[N]T` | `T[]` |
| `?T` | `T \| null`; a struct field of it is optional (`note?: string \| null`) |
| `*T`, `*const T` | `T` |
| an enum | `type Name = "a" \| "b"` (enums are sent as their tag names) |
| a struct | `interface Name { ... }`, named after the struct |
| `std.json.Value` | `unknown` |
| `void` | `void` |
| `E!T` | `T` (the error rejects the promise) |
| `myzig.Channel(T)` | `Channel<T>` |

Named types are declared once, even when several services use them, and
recursive structs work. Tuples, unions and other types are a compile error
that names the type, so a service can't bind what the page can't read.
Integers bigger than 2^53 lose precision in JavaScript, as with any JSON.

## Events

An event is a type: a name and a payload.

```zig
const TickPayload = struct { uptime: u64, todos: usize };
const Tick = myzig.Event("tick", TickPayload);

try app.registerEvent(Tick); // declares onTick in the client

Tick.emit(window, .{ .uptime = 3, .todos = 2 });   // one window's page; safe from any thread
Tick.broadcast(app, .{ .uptime = 3, .todos = 2 }); // every window's page; main thread
```

The client has `on` and the event's name in Pascal case
(`"tick"` → `onTick`, `"build-logs"` → `onBuildLogs`), which returns a
function that stops listening:

```js
const off = onTick(({ uptime, todos }) => render(uptime, todos));
off();
```

Events sent before the page is ready wait for it (its `dom_ready`), up to
1024 of them, and those of a document the page left are dropped. Messages
to a page are batched: everything sent in one turn of the main loop goes
in one evaluation.

A timer that broadcasts, as `examples/hello` does:

```zig
fn tick(ctx: ?*anyopaque) callconv(.c) void {
    const app: *myzig.App = @ptrCast(@alignCast(ctx));
    uptime += 1;
    Tick.broadcast(app, .{ .uptime = uptime, .todos = todos_ptr.items.items.len });
    myzig.App.after(1000, app, tick);
}
```

## Channels

A channel is a stream of typed values between Zig and one page, both ways,
in order, until either side closes it. Use it for what a call can't
return at once: lines of a process, progress, uploads.

### Channels the page makes

A bound method takes a `myzig.Channel(T)` parameter; the page passes a
`Channel` it made:

```zig
const Shell = struct {
    pub const myzig_params = .{ .count = .{ "n", "into" }, .upload = .{"from"} };

    /// Sends 0..n-1, then closes the channel.
    pub fn count(_: *Shell, n: u32, into: myzig.Channel(u32)) !void {
        for (0..n) |i| try into.send(@intCast(i));
        into.close();
    }

    /// Takes what the page sends.
    pub fn upload(self: *Shell, from: myzig.Channel([]const u8)) void {
        from.onMessage(self, got);
    }

    fn got(self: *Shell, _: myzig.Channel([]const u8), v: []const u8) void {
        self.append(v);
    }
};
```

```js
import { Shell, Channel } from "/myzig.js";

const numbers = new Channel();
Shell.count(5, numbers);
for await (const n of numbers) console.log(n); // 0 1 2 3 4, then the loop ends

const up = new Channel();
await Shell.upload(up);
for (const v of ["a", "b", "c"]) await up.send(v);
up.close();
```

The `Channel(T)` value is small: keep it (in the service's state) to send
later, as values come. A method may return before the channel is used.

### Channels Zig opens

A kind of channel declares its name and type, and the page listens for
channels of that kind:

```zig
const Line = struct { text: []const u8 };
const Logs = myzig.ChannelKind("logs", Line);

try app.registerEvent(Logs); // declares onLogsChannel in the client

const ch = try Logs.open(window);
try ch.send(.{ .text = "hello" });
ch.close();
```

```js
import { onLogsChannel } from "/myzig.js";

onLogsChannel(async (logs) => {
  for await (const line of logs) output.append(line.text);
});
```

Channels opened before the page listens wait for a listener (up to 1024
of a kind). Without the kind, `myzig.Channel(T).open(window, "logs")` opens
one by name, which the page gets with `myzig.onChannel("logs", fn)`.

### Both sides

In Zig, a `myzig.Channel(T)`:

| | |
|---|---|
| `send(value)` | sends a value; fails with `error.ChannelClosed` once it closed, and `error.ChannelFull` while the page has a window of values yet to take |
| `close()` | closes it; the page's iteration ends after the values sent |
| `isOpen()` | |
| `onMessage(ptr, func)` | `func(ptr, channel, value)` for each value of the page's, parsed into `T` |
| `onClose(ptr, func)` | `func(ptr, channel, reason)` once it closes; `reason` is `.zig`, `.page` or `.lost` (the page navigated away or closed) |
| `onDrain(ptr, func)` | `func(ptr, channel)` once a send that failed with `ChannelFull` would succeed |

In the page, a `Channel<T>` is an async iterable, and has `onmessage` (set
it to take values as they come instead of iterating; values wait for one
or the other), `onclose`, `closed`, `send(value)` and `close()`. Breaking
out of a `for await` closes it.

Backpressure goes both ways with a window of 1 MiB: values from Zig wait
in the page until it takes them, and once more than the window waits,
`send` fails with `ChannelFull` until the page takes enough (`onDrain`
says when). The page's `send` resolves at once while Zig has room, and
later once Zig acknowledged enough. Navigating away closes the page's
channels with `.lost`, and a `Channel(T)` of an earlier document is
closed for good, even if the window shows a new page. Channels are main
thread only.

## Without the generated client

The client is a thin layer over `window.myzig`, which the bridge puts in
every page of the app:

```js
await myzig.call("Greeter.greet", "Ada");
const off = myzig.on("tick", (payload) => {});
myzig.once("tick", (payload) => {});
myzig.onChannel("logs", (channel) => {});
const ch = new myzig.Channel();
```

That is what pages that don't import modules (an inline script, a page
loaded with `loadHtml`) use. The whole runtime is in
[The frontend](frontend.md#the-page-runtime), and the wire protocol under
it in [the architecture guide](architecture-ipc.md).

## From Zig to the page

Besides events and channels, Zig can run scripts in a page: `win.eval(js)`
and `win.evalResult(js, cb)`, which awaits the value
([Pages](pages.md#evaluating-scripts)).

## Testing

A service is a struct: test its methods directly, with
`std.testing.allocator` as the arena. Through the page, run the app with
`--myzig-eval` ([Pages](pages.md#testing-pages)); `zig build test-pages`
calls `examples/hello`'s services, their errors and an event, and runs
`examples/pages`, whose channels cover both directions, kinds and
backpressure. The type mapping is tested in `src/tsgen.zig`.
