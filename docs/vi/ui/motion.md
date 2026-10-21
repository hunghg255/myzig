<a id="motion"></a>

# Chuyển động

Cái nhìn cho biết mọi thứ ở đâu; chuyển động tìm đường đến đó. Giá trị được cấp cho `ui.motion` sẽ hoạt hình hướng tới mục tiêu mà view cung cấp cho nó trên mọi frame, với một lò xo giữ vận tốc hoặc đường cong trong một khoảng thời gian. Các hộp cũng có thể di chuyển trơn tru ở nơi bố trí đặt chúng và đến và đi (`motion.transition`). Mọi thứ chạy trên đồng hồ của ngữ cảnh (`c.time`, `ui.Tester` tiến lên) và các khung chỉ được vẽ khi có thứ gì đó di chuyển: một ứng dụng ở trạng thái nghỉ không vẽ gì cả.

```zig
const motion = myzig.ui.motion;

fn view(s: *State, c: *ui.Context) void {
    const id = c.peekId("card");
    const x = motion.animateTo(c, id, "x", if (s.open) 200 else 0, .snappy);
    _ = c.open(.{ .width = .{ .px = 80 }, .height = .{ .px = 80 }, .radius = 12,
        .background = c.theme.accent, .transform = .translation(x, 0) }, "card");
    c.end();
}
```

`s.open` thay đổi; ở các khung tiếp theo, thẻ sẽ trượt đến vị trí mới. Ví dụ `zig build run-gallery` hiển thị mọi hoạt ảnh trên trang Chuyển động của nó (`examples/gallery/motion.zig`).

<a id="values-and-their-ids"></a>

## Giá trị và id của chúng

Một giá trị thuộc về id của hộp và một khóa phân biệt các giá trị của hộp (`"x"`, `"scale"`, ...). Lấy id của hộp bạn sắp mở bằng `c.peekId(key)` hoặc của hộp đã mở bằng `c.node(index).id`; `motion.to(c, key, target, a)` sử dụng ngay hộp đã mở.

Một giá trị bắt đầu ở mục tiêu đầu tiên của nó, do đó, view được hiển thị lần đầu tiên sẽ không có chuyển động. Một mục tiêu mới trên đường đi sẽ tiếp quản vị trí có giá trị: một lò xo giữ nguyên vận tốc của nó, do đó, một lá bài quay lại giữa chuyến bay sẽ chậm lại và quay trở lại, thay vì nhảy.

<a id="animations"></a>

## Hoạt hình

`motion.Animation` cho biết cách một giá trị đi đến mục tiêu mới:

| lĩnh vực | ý nghĩa |
|---|---|
| `duration` | giây của một đường cong; 0 (mặc định) sử dụng `spring` |
| `ease` | `motion.Easing` của đường cong (`.ease_out` theo mặc định) |
| `spring` | `motion.Spring` được sử dụng khi `duration` bằng 0 |
| `delay` | giây giá trị vẫn tiếp tục như trước khi nó di chuyển |

Ba lò xo đã sẵn sàng, sau SwiftUI: `.smooth` (không nảy), `.snappy` (một chút) và `.bouncy` (có thể nhìn thấy). `motion.Animation.curve(seconds, ease)` tạo một đường cong:

```zig
const a: motion.Animation = .curve(0.3, .ease_in_out);
const b: motion.Animation = .{ .spring = .{ .duration = 0.4, .bounce = 0.2 } };
```

`motion.animate(c, id, key, target, seconds)` là `animateTo` với đường cong `seconds` nới lỏng.

<a id="easing"></a>

### Nới lỏng

`motion.Easing` là các chức năng định giờ của CSS: `.linear`, `.ease_in`, `.ease_out`, `.ease_in_out`, `.cubic` (được tạo bằng `Easing.cubicBezier(x1, y1, x2, y2)`, như CSS's `cubic-bezier()`) và `.custom`, một chức năng của riêng bạn tại thời điểm đó (0 đến 1) theo tiến độ.

<a id="springs"></a>

### Lò xo

`motion.Spring` được đặt khi người ta cảm nhận được nó, bởi `duration` (khoảng thời gian cần thiết để đến nơi, 0,5 giây theo mặc định) và `bounce` (từ 0, không vượt quá, hướng tới 1). Thay vào đó, cài đặt `stiffness` hoặc `damping` sẽ biến nó thành vật lý (mặc định là 170 và 26 của lò xo phản ứng), với `mass`. `precision` cho biết mức độ gần với mục tiêu của nó, theo đơn vị của giá trị, nó được tính là đã đến và `velocity` cung cấp cho giá trị vận tốc khi mục tiêu của nó thay đổi (một cú ném). Lò xo được giải chính xác chứ không phải bậc nên trông giống nhau ở mọi tốc độ frame.

<a id="colors"></a>

## Màu sắc

`motion.animateColor(c, id, key, target, a)` di chuyển một màu về phía `target`. Màu sắc được trộn với alpha được nhân trước (`motion.mixPremultiplied`), do đó, màu nhạt dần từ trong suốt sẽ giữ nguyên sắc độ thay vì chuyển sang màu xám.

<a id="poses-that-only-paint"></a>

## Những tư thế chỉ vẽ

`motion.pose(c, index, p, a)` tạo hiệu ứng cho hộp `index` (mở hoặc tạo khung này) về phía `motion.Pose`: được di chuyển bởi `x` và `y`, được chia tỷ lệ bởi `scale` (0 giữ nguyên kích thước), xoay `rotate` độ và mờ dần `fade` (0 mờ, biến mất 1). Tư thế hoạt động theo sự biến đổi của chính chiếc hộp và nhân độ mờ của nó lên. Nó chỉ thay đổi cách vẽ hộp; bố cục vẫn giữ nguyên.

```zig
const card = c.open(.{ .padding = .all(16), .radius = 12, .background = c.theme.surface }, "card");
ui.text(c, "Hello", .{});
motion.pose(c, card, .{ .scale = if (s.pressed) 0.96 else 1, .fade = if (s.hidden) 1 else 0 }, .snappy);
c.end();
```

<a id="when-it-is-done"></a>

## Khi nó được thực hiện

- `motion.settled(c, id, key)`: giá trị nằm ở mục tiêu của nó.
- `motion.arrived(c, id, key)`: true trong một frame, nó dừng lại sau khi di chuyển, để view tiếp tục (xóa những gì bị mờ đi, bắt đầu bước tiếp theo).
- `motion.velocity(c, id, key)`: tốc độ của nó tính bằng đơn vị một giây.

<a id="gestures"></a>

## Cử chỉ

Trong khi ngón tay hoặc con trỏ kéo thứ gì đó, hãy đặt giá trị của nó bằng `motion.jump(c, id, key, value)`: nó theo sau ngay lập tức và chuyển động sẽ theo dõi tốc độ của nó. Khi lực kéo kết thúc, `animateTo` có lò xo tiếp tục vận tốc đó nên vật đó tiếp tục chuyển động như cách nó được ném. Hai người trợ giúp, sau iOS:

- `motion.project(value, velocity)`: trong đó một lần ném mang một giá trị, để chọn nơi nó đến (trang gần nhất, một điểm bắt nhanh).
- `motion.rubberband(value, lo, hi, dimension)`: một giá trị được giữ trong phạm vi `lo` và `hi` khi nội dung được kéo qua các cạnh của nó, càng được kéo càng xa thì càng đi ít hơn.

<a id="keyframes"></a>

## Khung hình chính

`motion.keyframes(c, id, key, frames, options)` phát một chuỗi `motion.Keyframe`s (`at` trong vài giây kể từ khi bắt đầu, `value` và `ease` của phân đoạn đến đó), sau đó giữ giá trị cuối cùng. Thay đổi `options.run` để phát lại: từ giá trị được hiển thị, do đó thao tác lắc bắt đầu trong khi lắc sẽ không nhảy.

```zig
const dx = motion.keyframes(c, c.peekId("shake"), "dx", &.{
    .{ .value = 0 },
    .{ .at = 0.08, .value = -12 },
    .{ .at = 0.16, .value = 12 },
    .{ .at = 0.24, .value = -8 },
    .{ .at = 0.32, .value = 8 },
    .{ .at = 0.4, .value = 0, .ease = .ease_out },
}, .{ .run = s.shakes });
_ = c.open(.{ .padding = .xy(14, 10), .transform = .translation(dx, 0) }, "shake");
```

`motion.KeyframeOptions` cũng có `repeat` (bao nhiêu lần nữa; `-1` phát mãi mãi), `alternate` (mỗi lần lùi lại), `delay` và `repeat_delay`.

<a id="timelines"></a>

## Dòng thời gian

Dòng thời gian đặt các thanh thiếu niên lần lượt, cùng nhau hoặc đôi khi, giống như cách làm của GSAP. `motion.timeline(c, id, key, options)` đưa ra `Timeline` mà `tween` trả về giá trị của mỗi tween ngay bây giờ:

```zig
var tl = motion.timeline(c, c.peekId("intro"), "intro", .{ .run = s.intro });
const slide = tl.tween(.{ .from = -60, .to = 0, .duration = 0.4 }, .{});
const fade = tl.tween(.{ .from = 0, .to = 1, .duration = 0.3, .ease = .linear }, .with(0.1));
const grow = tl.tween(.{ .from = 0.8, .to = 1, .duration = 0.3 }, .after(-0.1));
_ = c.open(.{ .opacity = fade,
    .transform = ui.Affine.scaling(grow, grow).then(.translation(slide, 0)) }, "intro");
```

`motion.Placement` cho biết nơi tuổi mười hai bắt đầu:

- `.after(offset)` (mặc định, offset 0): sau tween trước khi kết thúc; một phần bù âm sẽ chồng lên nó.
- `.with(offset)`: sau mười hai giờ trước khi bắt đầu.
- `.at(seconds)`: tại một thời điểm trong dòng thời gian.
- `.atLabel(name, offset)`: sau một nhãn được đặt với `tl.label(name, placement)`.

`motion.TimelineOptions` phát nó: `run` (đổi thành phát lại), `repeat`, `alternate`, `delay`, `repeat_delay`, `paused`, `reverse` và `seek` (giữ đầu phát cùng một lúc) hoặc `progress` (ở một phần thời lượng, trong một khoảng thời gian máy chà sàn). Dòng thời gian cho biết `duration()`, `time()`, `progress()`, `settled()` và `arrived()`.

<a id="transitions"></a>

## Chuyển tiếp

`motion.transition(c, index, t)` cung cấp cho hộp một quá trình chuyển đổi: nó di chuyển mượt mà ở nơi bố cục thay đổi nó, từ nơi frame cuối cùng hiển thị nó, xuất phát từ `enter` khi nó xuất hiện và chuyển đến `exit` khi nó rời đi. Gọi nó sau khi các phần tử con của hộp được tạo (sự sụp đổ đo chúng), trước khi đóng nó:

```zig
for (s.items[0..s.count]) |n| {
    const box = c.open(.{ .width = .{ .px = 70 }, .height = .{ .px = 50 }, .radius = 10,
        .background = c.theme.surface_hover }, c.print("item-{d}", .{n}));
    ui.text(c, c.print("{d}", .{n}), .{ .weight = .bold });
    motion.transition(c, box, .{
        .animation = .snappy,
        .enter = .{ .opacity = 0, .scale = 0.6, .y = 12 },
        .exit = .{ .opacity = 0, .scale = 0.6, .collapse = true },
    });
    c.end();
}
```

Cung cấp cho các hộp như vậy các khóa ổn định (`c.print("item-{d}", .{n})`, `ui.key`), để hộp giữ id của nó khi danh sách được sắp xếp lại.

Các trường của `motion.Transition`:

| lĩnh vực | ý nghĩa |
|---|---|
| `animation` | nó di chuyển như thế nào; mặt khác, một đường cong `duration` (0,2 s) dọc theo `ease` |
| `position` | làm sinh động vị trí của nó trong cha mẹ của nó |
| `size` | làm sinh động kích thước của nó (kích thước tính bằng điểm) |
| `colors` | làm sinh động nền và đường viền của nó |
| `enter` | `motion.Motion` nó xuất phát từ khi nó xuất hiện |
| `exit` | `motion.Motion` nó đi tới khi nó rời đi |

Khi không có `position`, `size` và `colors` nào được đặt, cả ba đều hoạt hình. `motion.Motion` là một tư thế tương ứng với vị trí của hộp: `x`, `y`, `opacity`, `scale` (0 giữ nguyên kích thước của nó), `rotate` (độ về tâm của nó) và `collapse`, lấy chiều cao của nó trong một cột (chiều rộng của nó trong một hàng), cắt bớt nội dung của nó, để các anh chị em của nó đóng lại.

Một chiếc hộp rời đi được vẽ khi frame cuối cùng vẽ nó, bên dưới những anh chị em của nó, không chiếm chỗ cho đến khi lối ra của nó kết thúc. Một hộp chỉ xuất hiện với `enter` trong trang mẹ có khung trước đó, do đó, một trang được hiển thị cùng một lúc sẽ không tạo hoạt ảnh cho mọi hộp trong đó. `motion.transitioning(c, id)` cho biết hộp `id` có còn được vận chuyển hay không. Con trỏ đi theo các hộp nơi hoạt ảnh của chúng vẽ chúng.

<a id="without-animation"></a>

## Không có hình ảnh động

`motion.disableAnimations(c)` làm cho các giá trị, màu sắc, tư thế và chuyển tiếp của khung này đi đến mục tiêu của chúng cùng một lúc, như `disablesAnimations` của SwiftUI: cho một thay đổi không hiển thị dưới dạng chuyển động (một cửa sổ đã được thay đổi kích thước, một tài liệu đã được chuyển đổi). Khung hình chính và dòng thời gian tiếp tục phát.

<a id="less-motion"></a>

## Ít chuyển động hơn

Khi máy tính để bàn yêu cầu giảm chuyển động, `motion.reduced(c)` là true và các giá trị sẽ chuyển đến mục tiêu của chúng cùng một lúc; màu sắc và độ mờ vẫn thay đổi mượt mà, và lối vào hoặc lối ra mờ dần mà không bị sập, mờ dần tại chỗ. `motion.setReducedMotion(c, true)` ghi đè lên màn hình nền (`null` theo dõi lại). Các bài kiểm tra không bao giờ yêu cầu máy tính để bàn: chuyển động giảm sẽ tắt ở đó trừ khi bài kiểm tra thiết lập nó.

<a id="loops-and-your-own-motion"></a>

## Vòng lặp và chuyển động của riêng bạn

`motion.loop(c, seconds)` là nơi đồng hồ ở trong một khoảng thời gian, từ 0 đến 1, đối với con quay và xung; nó yêu cầu khung. Một view hoạt hình từ `c.time` tự gọi `c.animationFrame()` để yêu cầu khung tiếp theo hoặc `c.frameIn(seconds)` cho nội dung nào đó thỉnh thoảng thay đổi (một giây) mà không vẽ mỗi lần làm mới ở giữa. `c.animate(id, salt, target, speed)` là cách tiếp cận theo cấp số nhân đơn giản hơn mà các widget tích hợp sẵn sử dụng để di chuột và nhấn.

<a id="testing-motion"></a>

## Kiểm tra chuyển động

Đồng hồ của Người kiểm tra chỉ di chuyển khi quá trình kiểm tra thông báo, vì vậy các hoạt ảnh sẽ được kiểm tra mà không cần chờ đợi:

```zig
s.target = 200;
t.frame();
t.advance(0.1); // a tenth of a second later
try std.testing.expect(s.shown > 20 and s.shown < 200);
t.settle(3);    // frames until nothing moves (at most 3 s)
try std.testing.expectEqual(@as(f32, 200), s.shown);
try std.testing.expect(!t.ctx.animating);
```

Xem [Kiểm tra](testing.md) và [Biến đổi](transforms.md) để biết giá trị có thể di chuyển.
