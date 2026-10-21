# game

Những gì trò chơi cần ngoài những gì ứng dụng làm, hãy chọn tham gia và tránh xa `ui` của myzig: vòng lặp trò chơi theo các bước cố định với đầu vào, máy ảnh, tỷ lệ pixel hoàn hảo (mô-đun `game`) và gamepad trong một bố cục tiêu chuẩn (mô-đun `gamepad`, không cần ui).

Gói hàng là `plugins/game`. `examples/farm` là một trò chơi được xây dựng trên đó, một gói riêng của nó (`cd examples/farm && zig build run`); `build.zig.zon` của nó hiển thị cách ứng dụng phụ thuộc vào plugin:

```zig
.dependencies = .{
    .myzig = .{ .path = "../.." },
    .myzig_game = .{ .path = "../../plugins/game" },
},
```

```zig
const plugin = b.dependency("myzig_game", .{ .target = target, .optimize = optimize });
// imports: .{ .name = "game", .module = plugin.module("game") }, .{ .name = "gamepad", .module = plugin.module("gamepad") }
```

<a id="the-game-loop"></a>

## Vòng lặp trò chơi

```zig
const game = @import("game");

const Farm = struct {
    x: f32 = 0,
    px: f32 = 0, // where it was a step before

    pub fn update(f: *Farm, in: *game.Input) void {
        f.px = f.x;
        if (in.down(.d) or in.down(.right)) f.x += 2;
        if (in.pressed(.space)) f.jump();
    }

    pub fn draw(f: *Farm, c: *ui.Context, size: ui.Size, alpha: f32) void {
        _ = size;
        const x = f.px + (f.x - f.px) * alpha; // between its last two steps
        game.fill(c, .{ .x = x, .y = 40, .w = 16, .h = 16 }, .hex(0x4caf50));
    }

    fn jump(f: *Farm) void {
        _ = f;
    }
};

const State = struct {
    farm: Farm = .{},
    runner: game.Runner = .{},

    fn view(s: *State, c: *ui.Context) void {
        game.view(c, &s.farm, &s.runner); // fills its parent
    }
};
```

`game.view(c, &g, &runner)` chạy một trò chơi, bất kỳ cấu trúc nào có `update(*G, *game.Input)` và `draw(*G, *ui.Context, ui.Size, alpha: f32)`, trong một hộp có thể đặt tiêu điểm, lấp đầy phần tử mẹ của nó, được cắt bớt vào đó:

- Các bước được cố định, 60 giây một giây (`game.default_rate`; `pub const rate = 30;` trong trò chơi dành cho người khác), bất kể tốc độ của màn hình. Sau khi tạm dừng, họ bắt kịp nhiều nhất là một phần tư giây. Một khung xây dựng view của nó hai bước một lần.
- `draw` chạy mọi frame với `alpha`, khoảng cách giữa frame ở bước tiếp theo, để vẽ giữa hai bước cuối cùng.
- View yêu cầu frame tiếp theo (`c.animationFrame()`): trò chơi hòa liên tục trong khi nó được hiển thị.
- `game.fill(c, rect, color)` và `game.rounded(c, rect, color, radius)` vẽ các hộp được định vị trong khung nhìn (0, 0 ở góc của nó).
- `Runner` giữ đồng hồ, đầu vào và số lượng `steps`.

<a id="input"></a>

### Đầu vào

`game.Input` nắm giữ những gì bước này nhìn thấy:

- phím theo vị trí (`game.Key`: `.w` là vị trí của W và `.up`, `.space`, `.shift`...): `down(k)`, `pressed(k)`, `released(k)`;
- con trỏ: `pointer` (trong view), `over`, `pointerDown(b)`, `pointerPressed(b)`, `pointerReleased(b)`; `wheel`; view `size`; `focused`;
- `releaseAll()` buông bỏ mọi thứ (khi cửa sổ mất tiêu điểm).

View đặt `c.wants_keys`, do đó, các khóa sẽ di chuyển xuống nơi nền tảng báo cáo chúng (Windows, Linux và các trình duyệt cũng vậy). Cho đến khi cạnh đầu tiên xuất hiện, các ký tự đã nhập và phím điều hướng sẽ xuất hiện dưới dạng nhấn, xuống một bước. Các phím Command hoặc Control được để lại trong menu. `runner.input.keyDown(k)` và `keyUp(k)` khóa cấp dữ liệu từ nơi khác (các kiểm thử sử dụng chúng).

<a id="the-camera"></a>

## Máy ảnh

```zig
const cam: game.Camera = .{ .x = player.x, .y = player.y, .zoom = 3 };
if (cam.rect(view_rect, c.scale, tile_rect)) |r| game.fill(c, r, color); // null when out of view
const world = cam.toWorld(view_rect, c.scale, px, py); // the pointer, in the world
const seen = cam.visible(view_rect, c.scale); // the world's part in view, for culling
```

`Camera` nhìn vào `x, y` của thế giới ở giữa view, `zoom` lớn gấp lần, xoay `rotation` độ theo chiều kim đồng hồ (các hộp luôn căn chỉnh theo trục: xoay, `rect` là hướng thẳng xung quanh). Khi được lật lại, thế giới sẽ di chuyển theo toàn bộ pixel của màn hình, do đó, các ô được vẽ ở toàn bộ đơn vị sẽ giữ các cạnh của chúng nằm trên các pixel. `transform` cho affine `game.Transform` (`apply`, `invert`), `toScreen` theo cách khác từ `toWorld`, và `game.integerFit(w, h, view_rect)` bội số nguyên lớn nhất của kích thước logic phù hợp, được đóng hộp thư, với tỷ lệ của nó.

<a id="gamepads"></a>

## Tay cầm chơi game

```zig
const gamepad = @import("gamepad");

var pads: gamepad.Pads = .{};
defer pads.deinit();
var last: gamepad.State = .{};

// once a frame: reads the pads, and looks for new ones once a second
pads.update(now_seconds);
for (pads.list()) |p| {
    const x, const y = p.state.leftStick(); // -1..1, right and down, radial dead zone 0.15
    if (p.state.justPressed(last, .south)) jump(); // pressed: a quarter of the way
    last = p.state;
}
```

- Các nút theo vị trí, theo bố cục tiêu chuẩn của W3C (`gamepad.Button`): `south east west north`, `left_shoulder right_shoulder left_trigger right_trigger` (0 đến 1), `back start left_stick right_stick`, `up down left right`, `guide`.
- Trục (`gamepad.Axis`): `left_x left_y right_x right_y`.
- `State`: `value(b)`, `pressed(b)`, `justPressed(last, b)`, `justReleased(last, b)`, `axis(a)`, `leftStick()`, `rightStick()`.
- `Pad` có `id` (duy nhất khi ứng dụng chạy: được cắm lại, bảng đệm là bảng mới), `name`, `state` và `connected`. Lên đến 8.

| nền tảng | từ |
|---|---|
| Windows | XInput (`xinput1_4`, được tải với LoadLibrary; Hướng dẫn qua `XInputGetStateEx`, thứ tự 100) |
| Linux | evdev, `/dev/input/event*` bằng nút gamepad, đọc mà không chặn |
| macOS, trình duyệt | chưa có (không có miếng đệm nào được liệt kê) |

<a id="not-yet"></a>

## Chưa hỗ trợ

- macOS gamepad (GameController.framework thông qua thời gian chạy Objective-C) và API Gamepad của trình duyệt.
- Các phần của hình ảnh và canvas ngoài màn hình (mygo's `ImageRegion`): hộp vẽ trò chơi, [canvases](../ui/drawing.md) và `ui.image`.

<a id="example-and-tests"></a>

## Ví dụ và kiểm thử

`example/` là một trò chơi nhỏ: đi tới các đồng xu với D và A, mũi tên hoặc gamepad, camera theo sau. `zig build run` hiển thị nó.

```sh
cd plugins/game
zig build test       # loop, input, camera and pads; the view in a ui.Tester; the example rendered offscreen
zig build snapshot   # the example's first frame as a PNG (--myzig-snapshot), no window
zig build check -Dtarget=x86_64-linux-gnu
```

Các kiểm thử của view nâng cao đồng hồ của Người kiểm tra, không bao giờ là của bức tường: 60 frame là 60 bước (30 đối với trò chơi có tốc độ 30).
