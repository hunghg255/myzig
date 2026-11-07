<a id="inspector"></a>

# Inspector

Một panel cho nhà phát triển, gắn ở bên phải cửa sổ giao diện native, giống developer tools của trình duyệt. Nó hiện cây box của view, box đang chọn hoặc dưới con trỏ, và thời gian của các frame gần nhất (`src/ui/inspector.zig`, theo bản của mygo).

```zig
const App = struct {
    count: i64 = 0,
    inspector: ui.Inspector = .{},

    fn view(s: *App, c: *ui.Context) void {
        {
            const col = ui.div(c).column().sizeFull().center().gap(12);
            defer col.end();
            ui.textf(c, .{ .size = 40, .weight = .bold }, "{d}", .{s.count});
            if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.count += 1;
        }
        ui.inspector(c, &s.inspector); // cuối cùng
    }
};
```

App phải tự bật nó: giữ state của inspector và dựng nó cuối cùng trong view, đè lên các box đã dựng trước đó.

<a id="opening-it"></a>

## Mở inspector

| Phím | Tác dụng |
|---|---|
| F12, hoặc Alt+Cmd+I trên macOS và Ctrl+Shift+I trên các hệ khác | mở và đóng panel |
| Shift+Cmd+C (Ctrl+Shift+C) | mở ở chế độ chọn box, hoặc thôi chọn |
| Escape | thôi chọn |

- Panel chiếm 340 điểm ở bên phải cửa sổ. Nội dung nhận phần còn lại, dưới dạng padding trên box gốc của cửa sổ.
- Khi giao diện viết từ phải sang trái, panel gắn bên trái, nơi nội dung đã lật chừa chỗ cho nó.
- Bản thân panel luôn đọc từ trái sang phải.

<a id="what-it-shows"></a>

## Inspector hiện gì

- **Thanh công cụ.** **Pick** chọn box dưới con trỏ. Một lớp phủ trên nội dung nhận cú bấm, nên cú bấm tới inspector chứ không tới box. **RTL** chuyển cửa sổ sang [phải sang trái](right-to-left.md) hoặc trở lại, để thử giao diện trước khi dịch. **Close**.
- **Hiệu năng.** Thời gian build, layout và paint của frame cuối, tính bằng mili giây, số box của nó, số instance của renderer, và số lần view được dựng (pass). Mỗi frame trong 60 frame gần nhất có một cột, so với tần số làm tươi 60 Hz (16,7 ms), màu đỏ khi chậm hơn. Đây là `FrameStats` của context (`c.stats`); xem [Hiệu năng](performance.md).
- **Cây.** Mọi box của frame, thụt lề theo độ sâu và đặt tên theo loại: `Text "…"`, `Icon name`, `Image`, hoặc `Row`, `Column`, `Scroll` và `Pressable` kèm số phần tử con. Đây là một [list](lists.md) ảo, nên hàng nghìn box vẫn nhanh. Rê chuột lên một dòng thì box của nó được viền; bấm thì chọn nó.
- **Chi tiết** của box đang rê chuột, nếu không có thì của box đang chọn:
  - hình chữ nhật, padding, gap, chiều rộng và chiều cao, grow, căn chỉnh;
  - hướng: hướng layout riêng và hướng đọc của nó;
  - nền, viền, bo góc, độ mờ và độ lệch;
  - cờ: `scroll`, `absolute`, `clip`, `follow_end`, `selectable`, `control`, tương tác được, đang có focus;
  - thứ nó chứa: chữ kèm font và màu, icon, hình ảnh;
  - id của nó.

Box đang rê chuột hoặc đang chọn được viền đè lên nội dung như trình duyệt vẫn làm: padding màu xanh lá, box nội dung màu xanh dương, kích thước ở bên cạnh.

<a id="in-builds"></a>

## Trong các bản build

Inspector chỉ có trong bản build debug. Ở bản release, `ui.Inspector` là một struct rỗng và `ui.inspector` không làm gì. Các lời gọi cứ để nguyên trong code, bản release không tốn gì. Tùy chọn build `inspector` của myzig ghi đè điều này theo cả hai chiều:

```sh
zig build -Doptimize=ReleaseFast -Dinspector=true   # trong các ví dụ của chính myzig
```

và trong `build.zig` của app, qua dependency:

```zig
const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize, .inspector = true }).module("myzig");
```

Code giữ state và gọi `ui.inspector` biên dịch như nhau ở mọi bản build: không cần bọc điều kiện gì.

<a id="pages"></a>

## Trang web

Cửa sổ chứa trang web dùng inspector riêng của webview:

- Web Inspector của Safari trên macOS;
- inspector của WebKitGTK trên Linux;
- developer tools của Edge trên Windows.

`PageOptions.inspectable` (bật mặc định) cho phép mở nó, và `openDevTools` của trang sẽ mở nó (xem [Trang web](../pages.md)).

`src/ui/tests_inspector.zig` test việc mở, pick, chọn và nút chuyển phải sang trái qua [`ui.Tester`](testing.md).
