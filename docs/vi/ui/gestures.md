# Cuộn và pinch để thu phóng

`Div.handleInput(state, callback)` cho phép biểu đồ, canvas hay phần tử khác tự xử lý scroll và thu phóng bằng touchpad.

```zig
fn input(s: *State, e: ui.InputEvent) bool {
    switch (e.kind) {
        .zoom => s.zoom *= e.scale,
        .scroll => s.pan += e.dx,
    }
    return true;
}

// Trong view:
const plot = ui.div(c).size(400, 240).handleInput(s, input);
defer plot.end();
// Vẽ biểu đồ ở đây.
```

- Callback chạy trên main thread trước lần dựng view kế tiếp.
- Nó trả về việc nó có nhận event hay không.
- Giữ con trỏ state hợp lệ trong khi phần tử còn hiện.

| `ui.InputEvent` | |
|---|---|
| `kind` | `.scroll` hoặc `.zoom` |
| `x`, `y` | vị trí con trỏ, tính theo phần tử và transform của nó |
| `dx`, `dy` | lượng scroll theo điểm, dương là sang phải và xuống dưới |
| `precise` | touchpad chứ không phải nấc bánh xe chuột, ở nền tảng phân biệt được |
| `scale` | hệ số thu phóng: 2 là to gấp đôi |
| `ctrl`, `shift`, `cmd` | các phím bổ trợ đang giữ |

**Hoạt động**

- Input tới handler hiển thị nằm trong cùng dưới con trỏ.
- Trả về false thì input được chuyển cho handler của phần tử cha, rồi cho việc scroll thông thường.
- Scroll đã được xử lý thì không cuộn box bao quanh. Pinch thì không bao giờ cuộn.
- Hệ số scale không hữu hạn, không dương, hoặc bằng 1 thì bị bỏ qua.

**Nền tảng**

- **macOS**: event magnification.
- **Linux**: GTK 3 nhận ra pinch trên touchpad ở nơi desktop cung cấp, đáng kể là Wayland.
- **Windows**: delta bánh xe lẻ kèm Ctrl là thu phóng của precision touchpad. Nấc bánh xe nguyên kèm Ctrl vẫn là scroll.
- **Windows**: `WM_MOUSEHWHEEL` đi vào `dx` (dương là sang phải), kể cả khi giữ Ctrl. Scroll ngang không bao giờ thành pinch.
- **Trình duyệt**: Ctrl kèm delta bánh xe tính theo pixel là pinch, đúng như trình duyệt báo về. Thiết bị Ctrl-wheel gửi delta pixel cũng được tính.
- **Trình duyệt**: thu phóng mặc định của trình duyệt chỉ bị chặn khi view xử lý event.

**Test**

- `t.pinch(x, y, scale)` trả về việc có handler nhận nó hay không.
- `t.scroll(x, y, dy)` và `t.wheel(x, y, dy)` cũng đi qua handler. `dy` của chúng dương là lên trên; `InputEvent` nhận nó với dương là xuống dưới.
- `zig build test-web -j1` kiểm tra pinch và kéo ngang, dọc trong bản build WebAssembly chạy dưới Node, không mở cửa sổ trình duyệt.

Xem [ví dụ gestures](../../../examples/gestures/main.zig).

<details>
<summary>Event bánh xe thật của trình duyệt</summary>

Truyền `-Dweb-browser="/path/to/chrome-or-edge"` cho `zig build test-web` để test thêm `WheelEvent` thật của DOM trong một trình duyệt headless:

- delta theo pixel, dòng và trang;
- pinch bằng Ctrl;
- chỉ hủy event mặc định với các event đã được xử lý.

Nó không hiện cửa sổ nào và không giả lập input hệ thống.

</details>
