<a id="ranges"></a>

# Điều khiển giá trị trong khoảng

Điều khiển một số: thanh trượt và thanh trượt phạm vi đặt một số, bước và đầu vào số điều chỉnh số đó, đồng hồ đo, thanh tiến trình và vòng quay hiển thị một số (hoặc hiển thị rằng công việc đang tiếp tục).

<a id="sliders"></a>

![Hai thanh trượt hiển thị giá trị và một thanh tiến trình.](../../images/ui/sliders.png)

*Hai thanh trượt hiển thị giá trị và một thanh tiến trình.*

## Thanh trượt

`ui.slider(c, &value, options)` đặt `f32` giữa các giới hạn bằng cách kéo núm hoặc nhấn vào rãnh của nó. Nó trả về true trong khi thay đổi giá trị:

```zig
ui.row(c, .{ .gap = 12, .align_items = .center });
defer ui.end(c);
ui.text(c, "Volume", .{ .color = c.theme.muted });
_ = ui.slider(c, &s.volume, .{ .width = .{ .px = 240 }, .label = "Volume" });
ui.textf(c, .{ .mono = true, .size = 12 }, "{d:.0}%", .{s.volume * 100});
```

`ui.SliderOptions`:

| lĩnh vực | mặc định | nó làm gì |
|---|---|---|
| `min`, `max` | 0, 1 | giới hạn |
| `width` | 200 điểm | a `ui.Length` |
| `label` | `""` | đặt tên cho công nghệ hỗ trợ |

Núm xoay lấy tiêu điểm bàn phím; trong khi lấy nét, Trái và Phải di chuyển nó đi một phần hai mươi phạm vi của nó. Công nghệ hỗ trợ đọc nó dưới dạng một thanh trượt với giá trị và giới hạn của nó, đồng thời có thể đẩy nó.

<a id="range-sliders"></a>

## Thanh trượt phạm vi

![Khoảng giá, nút tăng giảm, ô nhập số, thước đo và chỉ báo đang tải.](../../images/ui/ranges.png)

*Khoảng giá, nút tăng giảm, ô nhập số, thước đo và chỉ báo đang tải.*

`ui.rangeSlider(c, &low, &high, options)` đặt hai `f64` với hai núm làm phạm vi giá. Mỗi núm lấy tiêu điểm bàn phím và các mũi tên, Home và End di chuyển nó; nhấn vào đường đua sẽ di chuyển núm gần nó nhất. Các núm không bao giờ vượt qua. Nó trả về true khi giá trị thay đổi:

```zig
_ = ui.rangeSlider(c, &s.low, &s.high, .{ .min = 0, .max = 1000, .step = 10, .width = 240 });
ui.text(c, c.print("${d:.0} – ${d:.0}", .{ s.low, s.high }), .{ .mono = true, .size = 12 });
```

`ui.RangeSliderOptions`: `min` và `max` (0 và 1), `width` (200 điểm, `f32`) và `step`: trên 0, các giá trị chuyển thành `min` cộng với bội số của nó và bản nhạc hiển thị dấu kiểm.

<a id="steppers"></a>

## Bước

`ui.stepper(c, &value, options)` là một cặp mũi tên thay đổi `f64` theo từng bước, giống như bước của AppKit bên cạnh một trường. Các bước nhấp chuột, giữ mũi tên sẽ tiếp tục bước (nhanh hơn sau một thời gian) và các bước Lên, Xuống, Home và End bằng tiêu điểm bàn phím. Nó trả về true khi giá trị thay đổi:

```zig
_ = ui.stepper(c, &s.copies, .{ .min = 1, .max = 20 });
```

`ui.StepperOptions`: `min` (0), `max` (100) và `step` (1).

<a id="number-inputs"></a>

## Đầu vào số

`ui.numberInput(c, &value, &text, options)` là trường văn bản chỉnh sửa `f64` giữa các giới hạn, với các nút − và + bên cạnh. Up và Down và các nút, thay đổi theo từng bước. Nội dung được nhập sẽ áp dụng ngay khi đó là số trong phạm vi và hiển thị được làm tròn đến số thập phân của bước sau khi trường mất tiêu điểm. `text` là `ui.TextBuffer` của trường, được giữ ở trạng thái của bạn bên cạnh giá trị:

```zig
const State = struct {
    copies: f64 = 2,
    copies_text: ui.TextBuffer = .{},
};

_ = ui.stepper(c, &s.copies, .{ .min = 1, .max = 20 });
_ = ui.numberInput(c, &s.copies, &s.copies_text, .{ .min = 1, .max = 20 });
```

Một bước và một số đầu vào có cùng giá trị sẽ giữ nguyên bước, như trên. `ui.NumberInputOptions`: `min` (0), `max` (100), `step` (1) và `width` (80 điểm, a `ui.Length`). Nó trả về true khi giá trị thay đổi.

<a id="meters"></a>

## Mét

`ui.meter(c, value, options)` hiển thị giá trị giữa các giới hạn, dưới dạng chỉ báo cấp độ của AppKit và `<meter>` của web: ở màu thành công hoặc màu cảnh báo (màu cam) và màu nguy hiểm từ các cấp độ đã cho:

```zig
ui.meter(c, s.disk_used, .{ .warning = 0.7, .critical = 0.9, .width = .{ .px = 240 } });
// A battery: low values are the bad ones, since critical is below warning.
ui.meter(c, s.battery, .{ .warning = 0.2, .critical = 0.1 });
```

`ui.MeterOptions`: `min` và `max` (0 và 1), `warning` và `critical` (null: không có), và `width` (160 điểm). `critical` bên dưới `warning` làm cho giá trị thấp trở thành giá trị xấu.

<a id="progress-bars"></a>

## Thanh tiến trình

`ui.progress(c, value, width)` là một thanh được lấp đầy tới `value`, từ 0 đến 1, giảm dần về phía nó khi nó thay đổi:

```zig
ui.progress(c, s.downloaded, .{ .px = 340 });
ui.progress(c, s.done, .fill);
```

Công nghệ hỗ trợ đọc nó như một chỉ báo tiến trình với giá trị của nó. Để biết tiến trình của cửa sổ trên nút thanh tác vụ (Windows và Linux trình khởi chạy hiển thị cửa sổ đó), hãy xem [`Window.setProgress`](../windows.md).

<a id="spinners"></a>

## Máy kéo sợi

`ui.spinner(c, options)` hiển thị tác phẩm có độ dài không xác định, dưới dạng chỉ báo quay của AppKit: các dấu chấm quanh một vòng tròn, mờ dần sau dấu chấm dẫn đầu, bước một phần mười hai lượt mỗi phần mười hai trong số 0,9 giây trên đồng hồ của ngữ cảnh:

```zig
ui.row(c, .{ .gap = 8, .align_items = .center });
defer ui.end(c);
ui.spinner(c, .{});
ui.text(c, "Loading…", .{ .size = 12, .color = c.theme.muted });
```

`ui.SpinnerOptions`: `size` (18 điểm) và `color` (màu văn bản bị tắt theo mặc định). Công cụ quay vòng chỉ yêu cầu một frame ở mỗi bước (`c.frameIn`), chứ không phải ở mỗi lần làm mới, do đó, một cửa sổ hiển thị một frame gần như không hoạt động. Trong các kiểm thử, hãy nâng cao đồng hồ của Người kiểm tra để tăng tốc độ.
