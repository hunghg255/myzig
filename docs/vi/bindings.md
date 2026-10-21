<a id="bindings"></a>

# Liên kết Zig và JavaScript

Một trang gọi Zig thông qua các dịch vụ mà ứng dụng liên kết, nghe nó thông qua các sự kiện đã nhập và truyền các giá trị theo cả hai cách thông qua các kênh. myzig tạo client của trang từ các kiểu Zig tại thời điểm biên dịch: mô-đun JavaScript mà ứng dụng phục vụ tại `/myzig.js` và các khai báo TypeScript của nó, `myzig.d.ts`.

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

<a id="bind-a-service"></a>

## Ràng buộc một dịch vụ

`app.bind(&service)` liên kết một con trỏ với bất kỳ cấu trúc nào. Các trang gọi nó bằng tên của cấu trúc, phần cuối cùng của tên loại của nó (`Greeter`) hoặc theo tên mà nó khai báo bằng `pub const myzig_name = "Name";`. Dịch vụ phải tồn tại lâu hơn các cửa sổ gọi nó: nó thường là một biến `main`.

Các phương thức của nó là các hàm công khai có tham số đầu tiên là dịch vụ (`Greeter`, `*Greeter` hoặc `*const Greeter`), không chung chung và có tên không bắt đầu bằng `_`. Các tuyên bố khác không phải là một phần của nó.

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

Zig không giữ tên tham số trong các loại hàm, do đó, dịch vụ sẽ đặt tên chúng theo `myzig_params`, một cấu trúc gồm các tên của phương thức, mỗi tên là một bộ tên theo thứ tự. Họ đặt tên cho các tham số của client được tạo; không có chúng, khách hàng sẽ nói `arg0`, `arg1`, ... Các nhận xét tài liệu về các phương thức cũng không được lưu giữ trong client: Zig không cung cấp chúng cho mã thời gian tính toán.

Các đối số đến từ trang dưới dạng JSON và được phân tích cú pháp thành các loại tham số (các trường đối tượng không xác định sẽ bị bỏ qua). Cuộc gọi có quá ít đối số không thành công với `MissingArgument`, với quá nhiều đối số với `TooManyArguments` và với một cuộc gọi không phân tích cú pháp bằng `InvalidArgument`. Kết quả được viết lại dưới dạng JSON.

Các phương thức chạy trên luồng chính, mỗi lần gọi một cuộc gọi, do đó, chúng có thể tự do sử dụng trạng thái và cửa sổ của ứng dụng, còn phương thức chậm sẽ duy trì ứng dụng: bắt đầu công việc lâu dài trên chuỗi của riêng bạn và trả lời sau, thông qua [sự kiện](#events) hoặc [kênh](#channels).

<a id="the-call"></a>

### Cuộc gọi

Một phương thức có thể mất `*myzig.Call` sau dịch vụ. Nó không phải là một đối số của trang: khách hàng sẽ bỏ nó đi.

```zig
pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
    call.window.setTitle(name);
    return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{name});
}
```

- `call.arena` được giải phóng sau khi trả lời được gửi: phân bổ kết quả trong đó, cũng như mọi thứ mà phương thức chỉ cần khi nó chạy. Các đối số (chuỗi, lát) cũng nằm trong đó, vì vậy hãy sao chép những gì bạn giữ lại (`self.gpa.dupe`).
- `call.window` là cửa sổ có trang được gọi. Một phương thức có thể đóng nó lại; câu trả lời sau đó sẽ bị loại bỏ.

<a id="errors"></a>

## Lỗi

Một phương thức trả về liên kết lỗi có thể thất bại. Lời hứa của trang bị từ chối với `Error` có thông báo là phương thức và tên lỗi:

```js
try {
  await Todos.add(" ");
} catch (e) {
  e.message; // "Todos.add: EmptyTitle"
}
```

Những gì bản thân cây cầu từ chối cũng thất bại theo cách tương tự: `UnknownService`, `UnknownMethod`, các lỗi đối số ở trên và `Untrusted` đối với một trang mà ứng dụng không [tin cậy](pages.md#trust).

<a id="the-generated-client"></a>

## Khách hàng được tạo

Ứng dụng khách được tạo từ các khai báo thời gian tính toán của các dịch vụ và sự kiện và không cần bước xây dựng: ứng dụng phục vụ nó tại `/myzig.js`, vì vậy một trang trong frontend của ứng dụng sẽ nhập nó dưới dạng mô-đun.

```js
import { Greeter, Todos, onTick, Channel } from "/myzig.js";
```

Đối với TypeScript và người chỉnh sửa, hãy viết `myzig.d.ts` (và một bản sao của `myzig.js`, dành cho các gói muốn có tệp) bên cạnh frontend:

```sh
zig-out/bin/hello --myzig-generate=examples/hello/frontend   # any app: write the client and exit
zig build gen                                               # this repository's hello example
myzig generate                                              # an app made with `myzig init`
```

`--myzig-generate=DIR` làm cho `App.run` viết `DIR/myzig.js` và `DIR/myzig.d.ts` rồi quay lại mà không có cửa sổ. `myzig dev` và `myzig build` của CLI cũng viết nó ([CLI](cli.md)). Tạo lại nó khi dịch vụ thay đổi; `myzig.d.ts` đáng được cam kết, do đó, frontend sẽ kiểm tra lỗi đánh máy mà không cần xây dựng ứng dụng.

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

Các dịch vụ được sắp xếp theo tên, do đó đầu ra ổn định và các phương thức của chúng giữ nguyên thứ tự khai báo. Mọi phương thức đều trả về một lời hứa.

<a id="types"></a>

### Các loại

| Zig | TypeScript |
|---|---|
| `bool` | `boolean` |
| số nguyên và số float | `number` |
| `[]const u8`, `[N]u8` | `string` |
| `[]const T`, `[N]T` | `T[]` |
| `?T` | `T \| null`; trường cấu trúc của nó là tùy chọn (`note?: string \| null`) |
| `*T`, `*const T` | `T` |
| một enum | `type Name = "a" \| "b"` (enum được gửi dưới dạng tên thẻ của chúng) |
| một cấu trúc | `interface Name { ... }`, được đặt tên theo cấu trúc |
| `std.json.Value` | `unknown` |
| `void` | `void` |
| `E!T` | `T` (lỗi từ chối lời hứa) |
| `myzig.Channel(T)` | `Channel<T>` |

Các kiểu được đặt tên được khai báo một lần, ngay cả khi một số dịch vụ sử dụng chúng và các cấu trúc đệ quy vẫn hoạt động. Bộ dữ liệu, kết hợp và các loại khác là lỗi biên dịch đặt tên cho loại đó, do đó dịch vụ không thể liên kết những gì trang không thể đọc. Các số nguyên lớn hơn 2^53 sẽ mất độ chính xác trong JavaScript, như với bất kỳ JSON nào.

<a id="events"></a>

## Sự kiện

Một sự kiện là một loại: tên và tải trọng.

```zig
const TickPayload = struct { uptime: u64, todos: usize };
const Tick = myzig.Event("tick", TickPayload);

try app.registerEvent(Tick); // declares onTick in the client

Tick.emit(window, .{ .uptime = 3, .todos = 2 });   // one window's page; safe from any thread
Tick.broadcast(app, .{ .uptime = 3, .todos = 2 }); // every window's page; main thread
```

Máy khách có `on` và tên sự kiện theo kiểu Pascal (`"tick"` → `onTick`, `"build-logs"` → `onBuildLogs`), trả về một hàm dừng nghe:

```js
const off = onTick(({ uptime, todos }) => render(uptime, todos));
off();
```

Các sự kiện được gửi trước khi trang sẵn sàng chờ nó (`dom_ready`), tối đa 1024 sự kiện trong số đó và các sự kiện của tài liệu mà trang còn lại sẽ bị loại bỏ. Tin nhắn tới một trang được gửi theo nhóm: mọi thứ được gửi trong một lượt của vòng lặp chính sẽ được đánh giá trong một lần đánh giá.

Đồng hồ hẹn giờ phát sóng, như `examples/hello` thực hiện:

```zig
fn tick(ctx: ?*anyopaque) callconv(.c) void {
    const app: *myzig.App = @ptrCast(@alignCast(ctx));
    uptime += 1;
    Tick.broadcast(app, .{ .uptime = uptime, .todos = todos_ptr.items.items.len });
    myzig.App.after(1000, app, tick);
}
```

<a id="channels"></a>

## Kênh

Kênh là một luồng các giá trị được nhập giữa Zig và một trang, theo cả hai cách, theo thứ tự, cho đến khi một trong hai bên đóng nó lại. Hãy sử dụng nó cho những việc mà cuộc gọi không thể quay lại ngay lập tức: dòng quy trình, tiến trình, nội dung tải lên.

<a id="channels-the-page-makes"></a>

### Các kênh mà trang tạo ra

Một phương thức bị ràng buộc có tham số `myzig.Channel(T)`; trang đó vượt qua `Channel` mà nó đã tạo:

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

Giá trị `Channel(T)` nhỏ: giữ nó (ở trạng thái dịch vụ) để gửi sau khi có giá trị. Một phương thức có thể trả về trước khi kênh được sử dụng.

<a id="channels-zig-opens"></a>

### Kênh Zig mở

Một loại kênh khai báo tên và loại của nó và trang sẽ lắng nghe các kênh thuộc loại đó:

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

Các kênh được mở trước khi trang nghe chờ người nghe (tối đa 1024 loại). Nếu không có loại này, `myzig.Channel(T).open(window, "logs")` sẽ mở một tên theo tên, trang này sẽ có `myzig.onChannel("logs", fn)`.

<a id="both-sides"></a>

### Cả hai bên

Trong Zig, `myzig.Channel(T)`:

| | |
|---|---|
| `send(value)` | gửi một giá trị; không thành công với `error.ChannelClosed` sau khi nó đóng và `error.ChannelFull` trong khi trang vẫn chưa nhận được một cửa sổ giá trị |
| `close()` | đóng nó lại; quá trình lặp lại của trang kết thúc sau khi các giá trị được gửi |
| `isOpen()` | |
| `onMessage(ptr, func)` | `func(ptr, channel, value)` cho mỗi giá trị của trang, được phân tích thành `T` |
| `onClose(ptr, func)` | `func(ptr, channel, reason)` khi nó đóng; `reason` là `.zig`, `.page` hoặc `.lost` (trang đã được điều hướng đi hoặc bị đóng) |
| `onDrain(ptr, func)` | `func(ptr, channel)` một lần gửi không thành công với `ChannelFull` sẽ thành công |

Trong trang, `Channel<T>` là một biến lặp không đồng bộ và có `onmessage` (đặt nó để nhận các giá trị khi chúng xuất hiện thay vì lặp lại; các giá trị chờ cái này hoặc cái kia), `onclose`, `closed`, `send(value)` và `close()`. Thoát ra khỏi `for await` sẽ đóng nó lại.

Áp suất ngược hoạt động theo cả hai cách với cửa sổ 1 MiB: các giá trị từ Zig đợi trong trang cho đến khi nó nhận được chúng và một khi nhiều hơn cửa sổ chờ, `send` sẽ không thành công với `ChannelFull` cho đến khi trang đủ (`onDrain` cho biết khi nào). `send` của trang được giải quyết ngay lập tức khi Zig còn chỗ và sau đó khi Zig được thừa nhận đủ. Điều hướng đi sẽ đóng các kênh của trang bằng `.lost` và `Channel(T)` của tài liệu trước đó sẽ bị đóng vĩnh viễn, ngay cả khi cửa sổ hiển thị một trang mới. Các kênh chỉ có luồng chính.

<a id="without-the-generated-client"></a>

## Không có khách hàng được tạo

Ứng dụng khách là một lớp mỏng trên `window.myzig` mà cây cầu đặt vào mỗi trang của ứng dụng:

```js
await myzig.call("Greeter.greet", "Ada");
const off = myzig.on("tick", (payload) => {});
myzig.once("tick", (payload) => {});
myzig.onChannel("logs", (channel) => {});
const ch = new myzig.Channel();
```

Đó là những trang không nhập mô-đun (tập lệnh nội tuyến, trang được tải bằng `loadHtml`) sử dụng. Toàn bộ thời gian chạy nằm trong [Giao diện người dùng](frontend.md#the-page-runtime) và giao thức dây bên dưới nó trong [hướng dẫn kiến ​​trúc](architecture-ipc.md).

<a id="from-zig-to-the-page"></a>

## Từ Zig đến trang

Ngoài các sự kiện và kênh, Zig có thể chạy các tập lệnh trong một trang: `win.eval(js)` và `win.evalResult(js, cb)`, đang chờ giá trị ([Trang](pages.md#evaluating-scripts)).

<a id="testing"></a>

## Kiểm tra

Một dịch vụ là một cấu trúc: kiểm tra các phương thức của nó một cách trực tiếp, với `std.testing.allocator` làm arena. Thông qua trang, hãy chạy ứng dụng với `--myzig-eval` ([Pages](pages.md#testing-pages)); `zig build test-pages` gọi các dịch vụ của `examples/hello`, lỗi và sự kiện của chúng, đồng thời chạy `examples/pages`, có các kênh bao gồm cả hướng, loại và áp suất ngược. Ánh xạ kiểu được kiểm thử trong `src/tsgen.zig`.
