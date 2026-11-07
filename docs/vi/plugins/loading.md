# Loading

Package `loading` vẽ 29 indicator của loading.dev trong native UI trên macOS, Linux, Windows và trình duyệt. Nó dùng canvas của myzig: không có service nào phải bind, không phụ thuộc JavaScript.

<a id="setup"></a>

## Cài đặt

Thêm `.loading = .{ .path = "path/to/myzig/plugins/loading" }` vào dependencies trong `build.zig.zon`. Trong `build.zig`, dùng cùng dependency myzig và cùng tùy chọn target như phần còn lại của app:

```zig
const loading = b.dependency("loading", .{
    .target = target, .optimize = optimize,
}).module("loading");
exe.root_module.addImport("loading", loading);
```

Giữ một `loading.Indicator` trong state của app cho mỗi indicator:

- Gọi `show` một lần cho mỗi indicator trong mỗi lần dựng view.
- Nó trả về chỉ số node. Truyền chỉ số này cho `c.interact` hoặc chỉnh style qua `c.node`.
- Mỗi indicator có đồng hồ riêng. Tạm dừng cái này không làm dừng cái khác.
- Dựng view nhiều lần trong cùng một frame không làm thời gian chạy thêm.
- Tăng `duration` gấp đôi thì mất gấp đôi thời gian để tới cùng một pha.

```zig
const loading = @import("loading");

const State = struct {
    saving: loading.Indicator = .{},

    fn view(s: *State, c: *ui.Context) void {
        _ = s.saving.show(c, .ring, .{
            .size = 32, .color = c.theme.accent, .label = "Saving",
        });
    }
};
```

<a id="designs-and-options"></a>

## Mẫu và tùy chọn

`Kind` gồm `arc`, `atom`, `blocks`, `bouncing_dots`, `cascade`, `circular_dots`, `classic`, `classic_v2`, `clock`, `comet`, `compass`, `dual`, `eclipse`, `flip`, `gather`, `leap`, `linear_dots`, `loading`, `morph`, `orbit`, `pulse`, `radar`, `ring`, `ripple`, `slide`, `snake`, `swirl`, `trace` và `wave`, theo đúng thứ tự của `loading.names`.

| Tùy chọn | Ý nghĩa |
| --- | --- |
| `size` | Chiều cao tính bằng điểm, mặc định 20; chiều rộng theo tỉ lệ của mẫu. Phải hữu hạn và dương. |
| `color` | Mặc định là màu chữ của theme. |
| `duration` | Số giây mỗi chu kỳ, không bắt buộc; hữu hạn và dương. Mặc định theo nhịp riêng của từng mẫu. |
| `paused` | Giữ nguyên thời gian đã chạy; chạy tiếp thì đi tiếp từ đó. |
| `easing` | `.linear`, `.ease_in_out` hoặc `.stacked`, cho các mẫu xoay. |
| `cap` | `.round` hoặc `.flat`, cho các mẫu vẽ bằng nét. |
| `sweep` | Blocks: `.diagonal`, `.rows` hoặc `.columns`. |
| `direction` | Ripple: `.out` hoặc `.in`. |
| `origin` | Wave: `.center` hoặc `.bottom`. |
| `label` | Tên cho trình đọc màn hình; mặc định là tên mẫu. |

**Hành vi**

- Khi bật giảm chuyển động trên desktop, nó vẽ một tư thế đứng yên và không xin frame animation nào.
- Khi bị cắt ra ngoài tầm nhìn, nó thôi xin frame. Việc nó có hiện hay không được lấy từ lần vẽ trước.
- Trình đọc màn hình nhận nó là một progress indicator không xác định tiến độ.

[Gallery](../../../examples/loading/README.md) dùng package này.

<details>
<summary>Test và khác biệt so với mygo</summary>

Chạy `zig build test-loading -j1` ở gốc repo, hoặc `zig build test -j1` trong `plugins/loading`. Các test offscreen kiểm tra pixel, đồng hồ và khả năng truy cập:

- các pha đã render với những `duration` khác nhau;
- đồng hồ độc lập và việc dựng view nhiều lần;
- tạm dừng/chạy tiếp và hành vi khi ở ngoài tầm nhìn.

Mask của canvas có thể bị rasterize lại khi hình chuyển động. Bản port này không hứa cho ra đúng pixel hay chi phí render như plugin đã tối ưu của mygo.

</details>
