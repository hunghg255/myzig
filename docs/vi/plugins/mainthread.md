# mainthread

Chuyển việc từ bất kỳ thread nào khác về main thread.

Trang web và view sống trên main thread, phương thức được bind và event của cửa sổ cũng vậy. Các thread của plugin chuyển kết quả về cho chúng qua package này: một response HTTP, một message WebSocket, một file vừa thay đổi. Các plugin fetch, websocket, watch, updater và terminal đều dùng nó.

Package nằm ở `plugins/mainthread` (module `mainthread`). Nó không phụ thuộc vào gì, kể cả myzig.

```zig
const mainthread = @import("mainthread");

const Job = struct {
    window: *myzig.Window,
    result: []u8,

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        // Trên main thread: phát event, đổi state của view, ...
        _ = job;
    }
};

try mainthread.init(); // một lần, trên main thread (service của các plugin tự gọi khi được tạo)
if (!mainthread.post(job, Job.run)) {
    // Không vào hàng đợi (chưa init, hoặc hết bộ nhớ): người gọi vẫn sở hữu `job`.
}
```

- `init()` chuẩn bị hàng đợi. Gọi lại lần nữa thì không làm gì.
- `post(ctx, func)` chạy `func(ctx)` trên main thread, trong thời gian ngắn tới.
  - Gọi từ thread nào cũng an toàn.
  - Các job chạy theo đúng thứ tự được post.
  - `func` là một `mainthread.Func`: `*const fn (?*anyopaque) callconv(.c) void`.
- `runUntil(&done)` chạy hàng đợi cho đến khi một cờ atomic được bật. Nó dành cho test và công cụ không có event loop riêng, và chỉ gọi trên main thread.

Mỗi nền tảng dùng chính hàng đợi của main thread, nên không có gì phải polling:

| Nền tảng | Hàng đợi |
|---|---|
| macOS | main queue của libdispatch (`dispatch_async_f`) |
| Linux | context mặc định của GLib (`g_idle_add`), do vòng lặp của GTK chạy |
| Windows | một cửa sổ chỉ nhận message (`PostMessageW`), do vòng lặp message của app chạy |

Trong trình duyệt (`wasm32-wasi`) không có thread nào khác, và package này không biên dịch được ở đó.

Bên trong myzig, việc được đưa về main thread qua `myzig.App.after` (một timer) và, trên macOS, qua `objc.dispatchMain`. Xem [hướng dẫn kiến trúc](../architecture.md) để biết mô hình thread.

```sh
cd plugins/mainthread
zig build test                              # trên máy này
zig build check -Dtarget=x86_64-linux-gnu   # kiểm tra kiểu cho nền tảng khác
```
