# game

Những thứ game cần mà app thường không cần, phải tự bật và nằm ngoài `ui` của myzig:

- module `game`: vòng lặp game theo bước cố định kèm input, camera, phóng to giữ nét từng pixel;
- module `gamepad`: gamepad theo một bố cục chuẩn. Module này không cần ui.

Package nằm ở `plugins/game`. `examples/farm` là một game dựng trên nó, là một package riêng (`cd examples/farm && zig build run`). File `build.zig.zon` của nó cho thấy cách một app phụ thuộc vào plugin:

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

## Vòng lặp game

```zig
const game = @import("game");

const Farm = struct {
    x: f32 = 0,
    px: f32 = 0, // vị trí ở bước trước

    pub fn update(f: *Farm, in: *game.Input) void {
        f.px = f.x;
        if (in.down(.d) or in.down(.right)) f.x += 2;
        if (in.pressed(.space)) f.jump();
    }

    pub fn draw(f: *Farm, c: *ui.Context, size: ui.Size, alpha: f32) void {
        _ = size;
        const x = f.px + (f.x - f.px) * alpha; // nằm giữa hai bước cuối
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
        game.view(c, &s.farm, &s.runner); // lấp đầy phần tử cha
    }
};
```

`game.view(c, &g, &runner)` chạy một game: bất kỳ struct nào có `update(*G, *game.Input)` và `draw(*G, *ui.Context, ui.Size, alpha: f32)`. Game chạy trong một box nhận được focus, lấp đầy phần tử cha và bị cắt theo nó.

- Bước cố định, 60 bước mỗi giây (`game.default_rate`), bất kể tần số của màn hình. Muốn khác thì đặt `pub const rate = 30;` trong game.
- Sau một lần tạm dừng, các bước chạy bù tối đa một phần tư giây.
- Một frame dựng view hai lần thì chỉ chạy một bước.
- `draw` chạy mỗi frame kèm `alpha`: frame đã đi được bao xa vào bước kế tiếp, để vẽ ở giữa hai bước cuối.
- View xin frame kế tiếp (`c.animationFrame()`): game vẽ liên tục khi đang hiện.
- `game.fill(c, rect, color)` và `game.rounded(c, rect, color, radius)` vẽ các box định vị trong view (0, 0 ở góc của nó).
- `Runner` giữ đồng hồ, input và số `steps`.

<a id="input"></a>

### Input

`game.Input` chứa những gì một bước nhìn thấy:

- phím theo vị trí (`game.Key`: `.w` là chỗ của phím W, và `.up`, `.space`, `.shift`...): `down(k)`, `pressed(k)`, `released(k)`;
- con trỏ: `pointer` (trong view), `over`, `pointerDown(b)`, `pointerPressed(b)`, `pointerReleased(b)`; `wheel`; `size` của view; `focused`;
- `releaseAll()` nhả hết mọi thứ (khi cửa sổ mất focus).

Phím đến như thế nào:

- View đặt `c.wants_keys`, nên phím đến cả lúc nhấn xuống lẫn lúc nhả ra, trên nền tảng nào báo về điều đó (Windows, Linux và trình duyệt đều báo).
- Cho đến khi cạnh nhấn/nhả đầu tiên tới, ký tự gõ vào và phím điều hướng đến dưới dạng một cú chạm, giữ xuống trong một bước.
- Phím đi kèm Command hoặc Control được để lại cho menu.
- `runner.input.keyDown(k)` và `keyUp(k)` đưa phím từ nơi khác vào (test dùng chúng).

<a id="the-camera"></a>

## Camera

```zig
const cam: game.Camera = .{ .x = player.x, .y = player.y, .zoom = 3 };
if (cam.rect(view_rect, c.scale, tile_rect)) |r| game.fill(c, r, color); // null khi nằm ngoài view
const world = cam.toWorld(view_rect, c.scale, px, py); // con trỏ, trong thế giới game
const seen = cam.visible(view_rect, c.scale); // phần thế giới đang thấy, để bỏ bớt thứ không cần vẽ
```

`Camera` đặt điểm `x, y` của thế giới vào giữa view:

| Trường | |
|---|---|
| `x`, `y` | điểm của thế giới nằm giữa view |
| `zoom` | phóng to bao nhiêu lần |
| `rotation` | độ, theo chiều kim đồng hồ |

- Box luôn thẳng theo trục: khi xoay, `rect` là hình chữ nhật bao quanh.
- Khi không xoay, thế giới dịch theo từng pixel nguyên của màn hình. Tile vẽ ở tọa độ nguyên thì mép luôn nằm đúng pixel.
- `transform` cho phép biến đổi affine `game.Transform` (`apply`, `invert`).
- `toScreen` làm chiều ngược lại của `toWorld`.
- `game.integerFit(w, h, view_rect)` cho bội số nguyên lớn nhất của một kích thước logic mà vẫn vừa view, có viền đen hai bên, kèm tỉ lệ của nó.

<a id="gamepads"></a>

## Gamepad

```zig
const gamepad = @import("gamepad");

var pads: gamepad.Pads = .{};
defer pads.deinit();
var last: gamepad.State = .{};

// mỗi frame một lần: đọc các tay cầm, và mỗi giây tìm tay cầm mới một lần
pads.update(now_seconds);
for (pads.list()) |p| {
    const x, const y = p.state.leftStick(); // -1..1, phải và xuống, vùng chết hình tròn 0.15
    if (p.state.justPressed(last, .south)) jump(); // tính là nhấn khi đi được một phần tư hành trình
    last = p.state;
}
```

- Nút theo vị trí, như bố cục chuẩn của W3C (`gamepad.Button`): `south east west north`, `left_shoulder right_shoulder left_trigger right_trigger` (0 đến 1), `back start left_stick right_stick`, `up down left right`, `guide`.
- Trục (`gamepad.Axis`): `left_x left_y right_x right_y`.
- `State`: `value(b)`, `pressed(b)`, `justPressed(last, b)`, `justReleased(last, b)`, `axis(a)`, `leftStick()`, `rightStick()`.
- Một `Pad` có `id`, `name`, `state` và `connected`. `id` là duy nhất khi app đang chạy: cắm lại thì tay cầm được tính là cái mới.
- Tối đa 8 tay cầm.

| Nền tảng | Nguồn |
|---|---|
| Windows | XInput (`xinput1_4`, nạp bằng LoadLibrary; nút Guide qua `XInputGetStateEx`, ordinal 100) |
| Linux | evdev, các `/dev/input/event*` có nút gamepad, đọc không chặn |
| macOS, trình duyệt | chưa có (không liệt kê tay cầm nào) |

<a id="not-yet"></a>

## Chưa có

- Gamepad trên macOS (GameController.framework qua runtime Objective-C), và Gamepad API của trình duyệt.
- Vẽ một phần ảnh và canvas ngoài màn hình (`ImageRegion` của mygo): game vẽ bằng box, [canvas](../ui/drawing.md) và `ui.image`.

<a id="example-and-tests"></a>

## Ví dụ và test

`example/` là một game nhỏ: đi tới các đồng xu bằng D và A, phím mũi tên hoặc gamepad, camera đi theo. `zig build run` chạy nó.

```sh
cd plugins/game
zig build test       # vòng lặp, input, camera và tay cầm; view trong ui.Tester; ví dụ render ngoài màn hình
zig build snapshot   # frame đầu của ví dụ thành file PNG (--myzig-snapshot), không mở cửa sổ
zig build check -Dtarget=x86_64-linux-gnu
```

Test của view cho đồng hồ của `ui.Tester` chạy tới, không bao giờ dùng đồng hồ thật: 60 frame là 60 bước (30 với game có rate 30).
