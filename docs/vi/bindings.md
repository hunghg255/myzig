<a id="bindings"></a>

# Bindings

Trang web nói chuyện với Zig theo ba cách:

- gọi Zig qua các **service** mà app bind;
- nghe Zig qua các **event** có kiểu;
- truyền dòng giá trị hai chiều qua các **channel**.

myzig sinh client cho trang từ các kiểu Zig lúc compile time. Client là một module JavaScript mà app phục vụ tại `/myzig.js`, kèm khai báo TypeScript của nó, `myzig.d.ts`.

```zig
const Greeter = struct {
    pub const myzig_params = .{ .greet = .{"name"} };

    pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{name});
    }
};

const Tick = myzig.Event("tick", struct { uptime: u64 });

// trong main, trước khi mở cửa sổ:
var greeter: Greeter = .{};
try app.bind(&greeter);
try app.registerEvent(Tick);
```

```js
import { Greeter, onTick } from "/myzig.js";

document.body.textContent = await Greeter.greet("Ada");
onTick(({ uptime }) => console.log(uptime));
```

<a id="bind-a-service"></a>

## Bind một service

`app.bind(&service)` bind một con trỏ tới bất kỳ struct nào.

- Trang gọi nó bằng tên struct: phần cuối của tên kiểu (`Greeter`).
- Hoặc bằng tên mà nó khai báo qua `pub const myzig_name = "Name";`.
- Service phải sống lâu hơn các cửa sổ gọi nó. Thường nó là một biến trong `main`.

Method của nó là các hàm public:

- nhận service làm tham số đầu tiên (`Greeter`, `*Greeter` hoặc `*const Greeter`);
- không generic;
- có tên không bắt đầu bằng `_`.

Các khai báo khác không thuộc về service.

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

**Tên tham số.** Kiểu hàm trong Zig không giữ tên tham số. Vì vậy service đặt tên chúng trong `myzig_params`: một struct theo tên các method, mỗi method là một tuple các tên theo thứ tự.

- Chúng là tên tham số trong client được sinh ra.
- Không có chúng, client ghi `arg0`, `arg1`, ...
- Comment tài liệu của method cũng không có trong client. Zig không đưa chúng cho mã comptime.

**Đối số.** Chúng đến từ trang dưới dạng JSON và được parse thành kiểu của tham số. Trường lạ trong object bị bỏ qua. Kết quả được ghi lại dưới dạng JSON.

| lời gọi có | lỗi trả về |
|---|---|
| thiếu đối số | `MissingArgument` |
| thừa đối số | `TooManyArguments` |
| một đối số không parse được | `InvalidArgument` |

**Thread.** Method chạy trên main thread, mỗi lần một lời gọi.

- Chúng được tự do dùng state và cửa sổ của app.
- Method chậm sẽ làm cả app đứng. Hãy chạy việc lâu trên thread riêng và trả lời sau, qua một [event](#events) hoặc một [channel](#channels).

<a id="the-call"></a>

### Lời gọi

Method có thể nhận một `*myzig.Call` ngay sau service. Đây không phải đối số của trang: client bỏ nó ra.

```zig
pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
    call.window.setTitle(name);
    return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{name});
}
```

- `call.arena` được giải phóng sau khi gửi trả lời. Cấp phát kết quả trong đó, cùng mọi thứ method chỉ cần khi đang chạy.
- Đối số (chuỗi, slice) cũng nằm trong đó, nên hãy copy những gì cần giữ (`self.gpa.dupe`).
- `call.window` là cửa sổ có trang đã gọi. Method có thể đóng nó; khi đó trả lời bị bỏ.

<a id="errors"></a>

## Lỗi

Method trả về error union thì có thể lỗi. Promise của trang bị reject với một `Error` có message là tên method và tên lỗi:

```js
try {
  await Todos.add(" ");
} catch (e) {
  e.message; // "Todos.add: EmptyTitle"
}
```

Những gì chính bridge từ chối cũng lỗi theo cách đó:

- `UnknownService`, `UnknownMethod`;
- các lỗi đối số ở trên;
- `Untrusted`, cho trang mà app không [tin cậy](pages.md#trust).

<a id="the-generated-client"></a>

## Client được sinh ra

Client được tạo từ khai báo comptime của các service và event. Nó không cần bước build nào. App phục vụ nó tại `/myzig.js`, nên trang trong frontend của app import nó như một module.

```js
import { Greeter, Todos, onTick, Channel } from "/myzig.js";
```

Cho TypeScript và editor, hãy ghi `myzig.d.ts` cạnh frontend. Thêm một bản `myzig.js` cho các bundler cần file thật.

```sh
zig-out/bin/hello --myzig-generate=examples/hello/frontend   # any app: write the client and exit
zig build gen                                               # this repository's hello example
myzig generate                                              # an app made with `myzig init`
```

- `--myzig-generate=DIR` khiến `App.run` ghi `DIR/myzig.js` và `DIR/myzig.d.ts` rồi return, không mở cửa sổ.
- `myzig dev` và `myzig build` của CLI cũng ghi nó ([CLI](cli.md)).
- Sinh lại khi service thay đổi.
- Hãy commit `myzig.d.ts`, để frontend typecheck được mà không cần build app.

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

Service được sắp theo tên, nên output ổn định. Method giữ thứ tự khai báo. Mọi method đều trả về promise.

<a id="types"></a>

### Kiểu

| Zig | TypeScript |
|---|---|
| `bool` | `boolean` |
| số nguyên và số thực | `number` |
| `[]const u8`, `[N]u8` | `string` |
| `[]const T`, `[N]T` | `T[]` |
| `?T` | `T \| null`; trường struct có kiểu này là tùy chọn (`note?: string \| null`) |
| `*T`, `*const T` | `T` |
| enum | `type Name = "a" \| "b"` (enum được gửi bằng tên tag) |
| struct | `interface Name { ... }`, đặt theo tên struct |
| `std.json.Value` | `unknown` |
| `void` | `void` |
| `E!T` | `T` (lỗi sẽ reject promise) |
| `myzig.Channel(T)` | `Channel<T>` |

- Kiểu có tên chỉ được khai báo một lần, kể cả khi nhiều service dùng.
- Struct đệ quy dùng được.
- Tuple, union và các kiểu khác gây lỗi compile có ghi tên kiểu. Nhờ vậy service không thể bind thứ mà trang không đọc được.
- Số nguyên lớn hơn 2^53 mất độ chính xác trong JavaScript, như với mọi JSON.

<a id="events"></a>

## Event

Một event là một kiểu: gồm tên và payload.

```zig
const TickPayload = struct { uptime: u64, todos: usize };
const Tick = myzig.Event("tick", TickPayload);

try app.registerEvent(Tick); // declares onTick in the client

Tick.emit(window, .{ .uptime = 3, .todos = 2 });   // one window's page; safe from any thread
Tick.broadcast(app, .{ .uptime = 3, .todos = 2 }); // every window's page; main thread
```

Client có hàm `on` cộng tên event viết kiểu Pascal case: `"tick"` → `onTick`, `"build-logs"` → `onBuildLogs`. Hàm này trả về một hàm để ngừng nghe:

```js
const off = onTick(({ uptime, todos }) => render(uptime, todos));
off();
```

- Event gửi trước khi trang sẵn sàng sẽ chờ trang (`dom_ready` của nó), tối đa 1024 event.
- Event cho một document mà trang đã rời bị bỏ.
- Tin nhắn tới trang được gom lại. Mọi thứ gửi trong một vòng của main loop đi trong một lần evaluate.

Một timer broadcast, như `examples/hello` làm:

```zig
fn tick(ctx: ?*anyopaque) callconv(.c) void {
    const app: *myzig.App = @ptrCast(@alignCast(ctx));
    uptime += 1;
    Tick.broadcast(app, .{ .uptime = uptime, .todos = todos_ptr.items.items.len });
    myzig.App.after(1000, app, tick);
}
```

<a id="channels"></a>

## Channel

Channel là một dòng giá trị có kiểu giữa Zig và một trang. Nó đi cả hai chiều, theo thứ tự, cho đến khi một bên đóng. Dùng nó cho những gì một lời gọi không trả về ngay được: các dòng output của process, tiến độ, upload.

<a id="channels-the-page-makes"></a>

### Channel do trang tạo

Method được bind nhận một tham số `myzig.Channel(T)`. Trang truyền vào một `Channel` nó tự tạo:

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

Giá trị `Channel(T)` rất nhỏ. Giữ nó trong state của service để gửi sau, khi có giá trị. Method có thể return trước khi channel được dùng.

<a id="channels-zig-opens"></a>

### Channel do Zig mở

Một loại channel khai báo tên và kiểu. Trang nghe các channel thuộc loại đó:

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

- Channel mở trước khi trang nghe sẽ chờ listener, tối đa 1024 channel mỗi loại.
- Không cần loại, `myzig.Channel(T).open(window, "logs")` mở channel theo tên. Trang nhận nó bằng `myzig.onChannel("logs", fn)`.

<a id="both-sides"></a>

### Hai phía

Trong Zig, một `myzig.Channel(T)`:

| | |
|---|---|
| `send(value)` | gửi một giá trị; lỗi `error.ChannelClosed` khi đã đóng, và `error.ChannelFull` khi trang còn cả một cửa sổ giá trị chưa nhận |
| `close()` | đóng nó; vòng lặp ở trang kết thúc sau các giá trị đã gửi |
| `isOpen()` | |
| `onMessage(ptr, func)` | `func(ptr, channel, value)` cho mỗi giá trị từ trang, đã parse thành `T` |
| `onClose(ptr, func)` | `func(ptr, channel, reason)` khi nó đóng; `reason` là `.zig`, `.page` hoặc `.lost` (trang đã chuyển đi hoặc đóng) |
| `onDrain(ptr, func)` | `func(ptr, channel)` khi một lần send từng lỗi `ChannelFull` giờ sẽ thành công |

Ở trang, một `Channel<T>` là async iterable. Nó có:

- `onmessage`: đặt nó để nhận giá trị khi chúng đến, thay vì lặp. Giá trị chờ một trong hai cách.
- `onclose`, `closed`, `send(value)` và `close()`.
- Thoát khỏi `for await` bằng `break` sẽ đóng nó.

**Backpressure** áp dụng cả hai chiều, với cửa sổ 1 MiB:

- Giá trị từ Zig chờ trong trang đến khi trang nhận.
- Khi số đang chờ vượt cửa sổ, `send` lỗi `ChannelFull` đến khi trang nhận đủ. `onDrain` báo lúc nào.
- `send` của trang resolve ngay khi Zig còn chỗ. Nếu không, nó resolve khi Zig đã xác nhận đủ.

Chuyển trang sẽ đóng các channel của trang với `.lost`. `Channel(T)` của một document cũ bị đóng vĩnh viễn, kể cả khi cửa sổ hiện trang mới. Channel chỉ dùng trên main thread.

<a id="without-the-generated-client"></a>

## Không dùng client được sinh

Client là một lớp mỏng trên `window.myzig`, thứ mà bridge đặt vào mọi trang của app:

```js
await myzig.call("Greeter.greet", "Ada");
const off = myzig.on("tick", (payload) => {});
myzig.once("tick", (payload) => {});
myzig.onChannel("logs", (channel) => {});
const ch = new myzig.Channel();
```

Trang không import module sẽ dùng nó: một script inline, một trang nạp bằng `loadHtml`. Toàn bộ runtime có trong [The frontend](frontend.md#the-page-runtime). Giao thức truyền bên dưới có trong [hướng dẫn kiến trúc](architecture-ipc.md).

<a id="from-zig-to-the-page"></a>

## Từ Zig tới trang

Ngoài event và channel, Zig có thể chạy script trong trang:

- `win.eval(js)`;
- `win.evalResult(js, cb)`, chờ lấy giá trị ([Pages](pages.md#evaluating-scripts)).

<a id="testing"></a>

## Test

- Service là một struct: test trực tiếp các method của nó, dùng `std.testing.allocator` làm arena.
- Qua trang, chạy app với `--myzig-eval` ([Pages](pages.md#testing-pages)).
- `zig build test-pages` gọi các service của `examples/hello`, lỗi của chúng và một event. Nó cũng chạy `examples/pages`, nơi các channel bao quát cả hai chiều, các loại channel và backpressure.
- Phần ánh xạ kiểu được test trong `src/tsgen.zig`.
