<a id="shaders"></a>

# Trình đổ bóng

Một khung nhìn có thể lấp đầy một hộp bằng một shader của riêng nó: một hàm từ một điểm của hộp đến một màu, chạy cho mọi pixel. Bạn viết nó một lần, bằng ZSL, một ngôn ngữ nhỏ theo cú pháp của Zig và `ui.shader.compile` biên dịch nó tại thời điểm biên dịch thành HLSL (Direct3D 11), GLSL (OpenGL 3.3, OpenGL ES 3.0 và WebGL 2), Metal và một bản đối chiếu CPU của Zig mã vẽ các pixel giống nhau, trong phạm vi làm tròn, nơi không có GPU vẽ: bộ kết xuất CPU và `ui.Tester`. Vì vậy, shader hoạt động trên mọi nền tảng và trong các kiểm thử, và lỗi trong đó là lỗi biên dịch của ứng dụng.

```zig
const waves = ui.shader.compile("waves",
    \\uniform time: f32;
    \\pub fn fragment(pos: vec2) vec4 {
    \\    const v = 0.5 + 0.5 * sin(pos.x / 20 + time);
    \\    return vec4(v * 0.2, v * 0.4, v, 1);
    \\}
);

fn view(_: *State, c: *ui.Context) void {
    _ = ui.shaderBox(c, &waves, .{}, .{ .width = .fill, .height = .{ .px = 120 }, .radius = 12 });
    c.end();
}
```

Các shader dài hơn tồn tại trong các tệp riêng của chúng, `.zsl`, được nhúng:

```zig
pub const shader = ui.shader.compile("wind", @embedFile("wind.zsl"));
```

Các ví dụ được tạo từ các shader: `blackhole` (ánh sáng truyền qua trọng lực, lực cản quay quanh máy ảnh), `wind` (kết cấu các ký tự bị gió khuấy động), `chat-glow` (quả cầu, vòng tròn, ánh sáng ở cạnh và ánh sáng lung linh, chia sẻ bảng màu), `effort-slider`, `mayoi` và thư viện. Chạy chúng với `zig build run-blackhole`, v.v.

<a id="shader-boxes"></a>

## Hộp đổ bóng

`ui.shaderBox(c, &shader, values, style)` mở một hộp được tạo kiểu bởi `style`, được đổ bóng lấp đầy; con của nó theo sau cho đến `c.end()`. Trình đổ bóng thay thế nền của hộp và được cắt bớt các góc tròn của hộp. `values` là một cấu trúc có các trường đặt đồng phục của shader (bên dưới). `ui.shaderBoxWith(c, &shader, values, style, options)` lấy `ui.ShaderBoxOptions`, có `blur` làm mờ nội dung bên dưới hộp trước khi shader đọc nó bằng `backdrop(p)`.

`ui.shaderEffect(c, &shader, values, last_rect, options)` tạo hiệu ứng đổ bóng cho `Style.effect` của bất kỳ hộp nào, được phân bổ cho khung này: một hộp được vẽ từ những gì bên dưới nó, giống như kính mờ ([Biến đổi và hiệu ứng](transforms.md#backdrop-effects)). `last_rect` là hình vuông của hộp trong bố cục cuối cùng, dành cho đồng phục `pointer`.

```zig
const id = c.peekId("lens");
const fx = ui.shaderEffect(c, &lens, .{ .strength = 0.4 }, c.rects.get(id), .{ .blur = 2 });
_ = c.open(.{ .width = .{ .px = 200 }, .height = .{ .px = 120 }, .radius = 16, .effect = fx }, "lens");
c.end();
```

<a id="the-fragment-function"></a>

## Chức năng phân đoạn

```zig
pub fn fragment(pos: vec2) vec4 { ... }
```

`pos` là điểm trong hộp, tính theo số điểm tính từ góc trên cùng bên trái của nó. Hàm trả về màu của pixel, được nhân trước (`vec4(r * a, g * a, b * a, a)`), được vẽ trên phần bên dưới hộp: alpha 0 giữ nguyên màu đó.

<a id="uniforms"></a>

## Đồng phục

`uniform name: type;` ở trên cùng khai báo giá trị mà view cung cấp cho mỗi frame:

```zig
const root = ui.shaderBox(c, &shader, .{
    .seed = w.seed,                               // u32
    .time = t,                                    // f32
    .heading = [2]f32{ @cos(w.heading), @sin(w.heading) }, // vec2
    .tap = s.tap,                                 // vec3, as [3]f32
}, .{ .width = .fill, .height = .fill });
defer c.end();
```

Các trường là số cho `f32`, `i32` và `u32`, `bool`s và mảng hoặc vectơ số float cho vectơ; a `ui.Color` đặt `vec3` hoặc `vec4`, `ui.Point` a `vec2`. Trường đặt tên không đồng nhất là lỗi biên dịch; một bộ đồng phục bị bỏ đi là con số 0, với hai trường hợp ngoại lệ:

- `time`, một `f32` bị bỏ lại, là đồng hồ của ngữ cảnh (`c.time`) và hộp sẽ vẽ mọi frame. Hãy tự mình cung cấp `time` để đóng băng nó (như các bài kiểm tra thực hiện) hoặc bắt đầu ở mức 0.
- `pointer`, một `vec2` bị bỏ sót, là vị trí của con trỏ, trong các điểm của hộp. Đặt `c.wants_moves = true` cho các khung khi con trỏ di chuyển.

Đồng phục chia sẻ mười sáu điểm nổi của hiệu ứng: mười lăm điểm nổi là của họ (`vec3` mất ba điểm) và điểm cuối cùng giữ các pixel tại một điểm. `ui.shader.params(&shader, values, scale)` gói các giá trị vào các tham số của hiệu ứng, cho `ui.Effect` được tạo thủ công.

<a id="the-language"></a>

## Ngôn ngữ

ZSL là cú pháp của Zig cho những gì shader cần:

- Ở trên cùng: `uniform name: type;`, `const name = value;` và các hàm (`fn name(a: f32, b: vec2) f32 { ... }`, nhiều nhất là tám tham số), trong đó có `pub fn fragment`. Các hàm có thể gọi nhau theo bất kỳ thứ tự nào, nhưng không gọi chính chúng: shader không lặp lại.
- Các loại: `bool`, `i32`, `u32`, `f32`, `vec2`, `vec3`, `vec4`.
- Câu lệnh: `const` và `var` địa phương, bài tập (`=`, `+=` và các phần khác, các thành phần như `v.xy = ...`), `if` / `else`, `while (c) : (i += 1)`, `for (0..n) |i|`, `break`, `continue`, `return`.
- Các số không có loại sẽ chọn loại mà chúng cần sử dụng, chẳng hạn như Zig. Chuyển đổi là `f32(x)`, `i32(x)`, `u32(x)`.
- Các vectơ được tạo dưới dạng `vec3(v.xy, 1)` hoặc `vec3(0)`; một vô hướng float trộn với các vectơ (`v * 0.5`); `.xyzw` và `.rgba` xèo xèo.
- Bọc số nguyên; `<<`, `>>`, `&`, `|`, `^`, `~` và `%` là của họ, và `mod()` phao'. Băm của `u32`s (PCG và tương tự) hoạt động giống nhau trên mọi chương trình phụ trợ.
- Bình luận là `//`.

Nội dung tích hợp: `sin` của GLSL, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `exp`, `exp2`, `log`, `log2`, `pow`, `sqrt`, `inversesqrt`, `abs`, `sign`, `floor`, `ceil`, `fract`, `round`, `trunc`, `mod`, `min`, `max`, `clamp`, `mix`, `step`, `smoothstep`, `length`, `distance`, `dot`, `cross`, `normalize`, `reflect`; và của myzig:

| dựng sẵn | là |
|---|---|
| `size()` | kích thước của hộp, tính bằng điểm |
| `pixel_scale()` | các pixel trong một điểm |
| `pixel()` | tâm của pixel, trong pixel của cửa sổ |
| `backdrop(p)` | những gì được vẽ bên dưới hộp tại điểm của nó `p`, bị làm mờ bởi `blur` của hộp, được nhân trước |

Một ví dụ ngắn về hầu hết nó, từ phần đầu của ví dụ về gió:

```zig
uniform seed: u32;
uniform time: f32;
uniform pointer: vec2;

const cell_w = 9.0;
const tau = 6.2831853;

fn pcg(v: u32) u32 {
    const s = v * 747796405 + 2891336453;
    const w = ((s >> ((s >> 28) + 4)) ^ s) * 277803737;
    return (w >> 22) ^ w;
}

pub fn fragment(pos: vec2) vec4 {
    const cell = floor(pos / vec2(cell_w, 18));
    const h = f32(pcg(u32(cell.x) * 7919 + u32(cell.y) + seed) & 1023) / 1023;
    const glow = 1 - smoothstep(0, 120, distance(pos, pointer));
    const v = 0.5 + 0.5 * sin(h * tau + time);
    return vec4(vec3(v * 0.3 + glow * 0.5), 1);
}
```

Tiền tố là một cách để chia sẻ mã: `chat-glow` biên dịch từng shader của nó từ `palette ++ @embedFile("orb.zsl")`, một tệp chứa các chức năng mà tất cả chúng đều sử dụng.

<a id="errors"></a>

## Lỗi

Lỗi là lỗi biên dịch của ứng dụng, với tên, dòng và cột của shader:

```
shader 'waves':3:24: mismatched types i32 and f32
```

Các loại được kiểm tra khi Zig kiểm tra chúng (không có chuyển đổi ngầm giữa `i32`, `u32` và `f32`, ngoài các số chưa được nhập), tên phải được khai báo, shader quá dài cho các bảng của nó là lỗi (`shader 'x' is too long`) và đệ quy cũng vậy. `ui.shader.checkSource(&program, src, msg)` biên dịch trong thời gian chạy, để kiểm tra trình biên dịch.

<a id="how-it-is-drawn"></a>

## Nó được vẽ như thế nào

Hộp đổ bóng là một hiệu ứng phông nền ([Biến đổi và hiệu ứng](transforms.md)): sơn đánh dấu nó theo thứ tự sơn và mỗi bộ kết xuất, tại điểm đánh dấu, sẽ đọc những gì nó đã vẽ cho đến nay xung quanh hộp (được làm mờ nếu được yêu cầu) và vẽ hộp bằng bóng đổ trước khi vẽ tiếp. Direct3D, OpenGL, WebGL và Metal biên dịch nguồn được tạo một lần cho mỗi shader, lần đầu tiên họ vẽ nó; bộ kết xuất CPU chạy song song, một hàm được tạo từ cùng một chương trình tại thời điểm biên dịch. Các nguồn được tạo nằm ở `shader.effect` (`hlsl`, `glsl`, `msl`) và bố cục của đồng phục ở `shader.uniforms`.

Một hộp đổ bóng có `time` được để lại cho đồng hồ sẽ yêu cầu mọi frame, do đó, hộp đổ bóng này sẽ tiếp tục vẽ ứng dụng trong khi hiển thị; một cái không có nó sẽ được vẽ bằng các khung mà phần còn lại của view yêu cầu, giống như bất kỳ hộp nào.

<a id="testing-shaders"></a>

## Kiểm tra shader

Bộ đôi CPU thu hút Trình kiểm tra, do đó, quá trình kiểm tra sẽ hiển thị view và xem xét các pixel của nó; đóng băng `time` bằng cách cho nó:

```zig
var s: Pane = .{ .frozen = 4 }; // its view passes .time = s.frozen
var t: ui.Tester = undefined;
try t.init(gpa, .init(&s, Pane.view), .{ .width = 240, .height = 160, .scale = 1 });
defer t.deinit();
t.settle(1);
const px = try t.render(gpa);
defer px.deinit(gpa);
// px.bytes: BGRA, px.width × px.height
```

View của các ví dụ được kiểm tra theo cách này (`zig build test` chạy kiểm thử trong `examples/blackhole`, `wind`, `chat-glow`, `effort-slider` và `mayoi`). `src/ui/shader/tests_gpu.zig` vẽ các shader sử dụng mọi phần của ngôn ngữ với Direct3D 11 (trên Windows) và OpenGL (thông qua EGL, trên Linux) và kiểm tra xem chúng có khớp với bản đối chiếu CPU trong một hoặc hai cấp độ hay không; `ui.gpu_testing` đưa ra sự so sánh tương tự với các kiểm thử của plugin.
