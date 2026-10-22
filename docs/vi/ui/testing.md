<a id="testing"></a>

# Kiểm tra

myzig kiểm tra giao diện native không có cửa sổ và các ứng dụng không hiển thị cửa sổ. Không có gì chạm tới màn hình, chuột, bàn phím hoặc khay nhớ tạm của hệ thống: bài kiểm tra không thể làm phiền người ở máy tính và đọc kết quả tương tự trên máy bận cũng như trên máy không hoạt động.

- **View** chạy trong `ui.Tester`: cùng các khung mà cửa sổ chạy, dữ liệu đầu vào được mô phỏng trong quá trình, thời gian được nâng cao bằng tay, các khung được hiển thị ngoài màn hình thành tệp PNG.
- **Ứng dụng** chạy headless với cờ `--myzig-*`: ảnh chụp nhanh của cửa sổ gốc đầu tiên sau tập lệnh gồm các bước hoặc JavaScript được đánh giá trong trang của chúng.
- **Trình kết xuất** được kiểm tra dựa trên bộ kết xuất CPU, từ pixel đến pixel đến làm tròn (xem [Kết xuất](rendering.md)).

## ui.Tester

`t.pinch(x, y, scale)` gửi pinch tới callback `handleInput` và trả về việc
sự kiện có được nhận hay không. `t.scroll` và `t.wheel` cũng gửi sự kiện
qua handler trước khi cuộn container. Xem [Cuộn và thu phóng](gestures.md).

```zig
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const Counter = struct {
    n: i64 = 0,
    fn view(s: *Counter, c: *ui.Context) void {
        const col = ui.div(c).column().sizeFull().center().gap(16);
        defer col.end();
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.n += 1;
    }
};

test "the counter counts" {
    var state: Counter = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, Counter.view), .{ .width = 320, .height = 240 });
    defer t.deinit();
    try t.clickText("Increment");
    try std.testing.expectEqual(@as(i64, 1), state.n);
    try std.testing.expect(t.hasText("1"));
}
```

Trình kiểm tra được khởi tạo tại chỗ (ngữ cảnh của nó trỏ vào đó) và chạy khung đầu tiên. `ui.TesterOptions` có `width` và `height` theo điểm (480 × 360 theo mặc định), `scale` (2), `dark` và `theme`, các màu riêng do tùy chọn `theme` của cửa sổ cung cấp.

<a id="input"></a>

### Đầu vào

| Gọi | Nó làm gì |
|---|---|
| `click(x, y)`, `clickText(s)` | nhấn và nhả tại một điểm hoặc ở giữa văn bản `s` (`error.TextNotFound` khi không có văn bản nào là `s`) |
| `doubleClick(x, y)` | hai lần nhấp chuột, lần thứ hai được tính là một lần nhấp đúp |
| `rightClick(x, y)` | nhấn nút phụ, sẽ mở menu ngữ cảnh |
| `middleClick(x, y)` | nhấn nút giữa (`c.input.middle_pressed`), để đóng tab của trình duyệt |
| `moveTo(x, y)` | di chuyển con trỏ: di chuột |
| `pinch(x, y, scale)` | gửi hệ số zoom tới handler dưới điểm đó; trả về việc sự kiện có được nhận hay không |
| `drag(x1, y1, x2, y2)` | nhấn, di chuyển theo tám bước, thả ra |
| `scroll(x, y, dy)` | cuộn hộp bên dưới điểm cùng một lúc, giống như bàn di chuột, hoặc đưa bánh xe tới view đưa nó (`c.wants_wheel`) |
| `wheel(x, y, dy)` | một khía của bánh xe chuột: hộp lướt tới đó khi đồng hồ tiến lên (`advance`), hộp bao quanh một cái ở đầu của nó lấy nó |
| `typeText(s)` | nhập văn bản vào trường tập trung |
| `textOps(ops)` | gửi các thao tác nhập văn bản (`ui.TextOp`), dưới dạng phương thức nhập hoặc các liên kết khóa của AppKit sẽ: phần chèn, lệnh, thành phần |
| `key(k)` | nhấn một phím (`ui.Context`'s `Key`: `.enter`, `.tab`, `.escape`, `.left`, `.f12`, ...) |
| `shortcut(s)` | cung cấp tổ hợp phím (`ui.Shortcut{ .key = 's', .cmd = true }`), giống như cửa sổ thực hiện trước khi chỉnh sửa văn bản; true nếu lượt xem chấp nhận |
| `keyEdge(code, down)` | phím đi xuống hoặc lên, dành cho các view theo sau phím (`c.wants_keys`): trò chơi |
| `resize(w, h)` | thay đổi kích thước cửa sổ và chạy một khung |

<a id="what-it-shows"></a>

### Những gì nó cho thấy

`findText(s)` trả về hình chữ nhật của văn bản `s` trong khung cuối cùng, `hasText(s)` liệu nó có ở đó không và `containsText(s)` liệu văn bản được vẽ có chứa `s` (hàng của terminal, một đoạn văn) hay không. `t.ctx` là `ui.Context` của view, dành cho nội dung mà bài kiểm tra đọc về nó: tiêu điểm, các hộp và hình chữ nhật của chúng (`t.ctx.nodes`, `t.ctx.rects`), số liệu thống kê của khung. Nội dung sao chép và cắt được viết trong `t.clipboard`: các bài kiểm tra không bao giờ chạm vào hệ thống.

Những gì công nghệ hỗ trợ nhìn thấy cũng được kiểm tra thông qua Trình kiểm tra: xem [Khả năng tiếp cận](accessibility.md#testing-it).

<a id="time"></a>

### Thời gian

Người kiểm tra có đồng hồ riêng, `t.time`, tăng thêm `t.dt` (1/60 giây) mỗi frame. Hoạt ảnh, nhấp đúp, dấu mũ nhấp nháy, chú giải công cụ, chúc mừng và `c.time` theo sau nó, không bao giờ là đồng hồ treo tường.

```zig
try t.clickText("More");
t.advance(0.1);   // a tenth of a second of frames: half way through an animation
t.settle(2);      // frames until nothing animates, at most two seconds of them
try std.testing.expect(!t.ctx.animating);
```

`t.frame()` chạy một frame cho những gì đã thay đổi bên ngoài view; `t.advance(seconds)` chạy các frame bấy lâu nay; `t.settle(max)` chạy các frame cho đến khi hoạt ảnh ổn định. Đừng bao giờ ngủ quên trong bài kiểm tra để để điều gì đó xảy ra: tăng tốc đồng hồ.

<a id="pictures"></a>

### Hình Ảnh

`t.screenshot(path)` hiển thị khung cuối cùng ngoài màn hình và ghi PNG: với Metal trên macOS, với bộ kết xuất CPU trong đó văn bản là của chính myzig (Linux, Windows, trình duyệt và macOS được xây dựng bằng `-Dportable=true`). `t.render(gpa)` trả về các pixel thay thế (`gpu.Pixels`: BGRA, được nhân trước; miễn phí với `deinit`) để so sánh chúng và `t.rasterize(bytes)` đưa vào bộ nhớ của `t.pixelSize()` bằng bộ kết xuất CPU.

```zig
const px = try t.render(std.testing.allocator);
defer px.deinit(std.testing.allocator);
// px.bytes[(y * px.width + x) * 4 ..][0..4] is B, G, R, A
```

<a id="scripts"></a>

### Tập lệnh

`t.runScript(steps)` chạy các bước được phân tách bằng `;`, theo sau là các khung cho đến khi hoạt ảnh ổn định:

| Bước | Nó làm gì |
|---|---|
| `click:TEXT`, `move:TEXT` | nhấp chuột hoặc di chuột vào giữa văn bản |
| `visible:TEXT` | không thành công trừ khi văn bản hiển thị toàn bộ trong cửa sổ (`move:` cũng tìm thấy nó ở bên ngoài) |
| `rclick:TEXT` | nhấp chuột phải vào giữa văn bản (hoặc `X,Y` theo điểm), giống như đối với menu ngữ cảnh của nó |
| `type:TEXT` | các loại văn bản |
| `key:NAME` | nhấn phím: `enter`, `backspace`, `tab`, `escape`, `left`, `right`, `up`, `down`, ... |
| `shortcut:KEYS` | một tổ hợp phím chẳng hạn như `ctrl+shift+p` (`cmd`, `ctrl`, `alt`, `shift`, sau đó là một ký tự, một mũi tên, `enter`, `tab`, `escape` hoặc `f1` tới `f12`) |
| `scroll:DY` | cuộn tại con trỏ |
| `wheel:DY` | cuộn con trỏ giống như các rãnh của bánh xe chuột, lướt nhẹ (`frames:N` để xem) |
| `drag:FROM>TO` | kéo từ một văn bản (hoặc `X,Y`) sang văn bản khác |
| `wait:SECONDS` | tiến bộ đồng hồ mô phỏng |
| `frames:N` | chạy N frame, sau đó không xử lý: ảnh chụp nhanh ở giữa hoạt ảnh |
| `live:SECONDS` | trong khi đó chạy vòng lặp sự kiện thực: trả lời, xử lý, tính giờ |
| `resize:WxH` | thay đổi kích thước cửa sổ |

Tập lệnh là thứ `--myzig-script` chạy trong ứng dụng thực.

<a id="apps-headless"></a>

## Ứng dụng, headless

Mọi ứng dụng được tạo bằng `myzig.App` đều đọc các cờ này (`src/dev.zig`):

| Cờ | Nó làm gì |
|---|---|
| `--myzig-snapshot=PNG` | hiển thị cửa sổ đầu tiên của giao diện native ngoài màn hình thành PNG và thoát |
| `--myzig-script=STEPS` | với ảnh chụp nhanh: các bước chạy trước, dưới dạng `runScript` |
| `--myzig-dark` | với một ảnh chụp nhanh: vẻ ngoài tối tăm |
| `--myzig-wait=SECONDS` | với ảnh chụp nhanh: chạy vòng lặp sự kiện với thời gian dài trước tiên để các quy trình, bộ tính giờ và phản hồi mà ứng dụng chờ đến |
| `--myzig-eval=JS` | đánh giá JavaScript trong mỗi trang khi DOM của nó đã sẵn sàng; các trang báo cáo với `myzig.log()` và kết thúc bằng `myzig.window.close()` |
| `--myzig-hidden` | không bao giờ hiển thị cửa sổ; thư mục của app là thư mục tạm (headless) |
| `--myzig-generate=DIR` | ghi client được tạo (`myzig.js`, `myzig.d.ts`) và thoát |

Một ảnh chụp nhanh, một đánh giá hoặc một thế hệ ngụ ý các cửa sổ ẩn.

```sh
zig-out/bin/gallery --myzig-snapshot=/tmp/g.png --myzig-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
```

<a id="pages"></a>

## Trang web

`zig build test-pages` chạy các trang ẩn, thông qua webview thực và cầu nối của nền tảng: ví dụ xin chào gọi Zig (cuộc gọi, lỗi, sự kiện, client được tạo) và ví dụ về trang (`examples/pages`), trong đó trang ẩn và Zig kiểm tra lẫn nhau: lược đồ, kênh, sự kiện, quyền, tải xuống, eval, tìm, PDF, cookie và tin cậy. Mỗi lần trôi qua khi trang ghi nhật ký `page: ok`.

<a id="examples-with-tests"></a>

## Ví dụ với các bài kiểm tra

Các ví dụ blackhole, chat-glow, wind, effort-slider, mayoi và loading có
test riêng, chạy bởi `zig build test`: view được dựng qua Tester, shader
được vẽ trên CPU và so với kết quả mong đợi. `zig build test-loading -j1`
chạy riêng plugin và gallery loading, gồm thời lượng, đồng hồ độc lập,
rebuild cùng frame và giảm chuyển động.

<a id="browsers"></a>

## Trình duyệt

`zig build test-web` build counter, gallery và gestures cho trình duyệt,
rồi chạy headless dưới Node (`src/web/test_node.mjs`). Test kiểm tra frame,
trạng thái idle, nhấp chuột, pinch và pan. Lệnh này cần `node`.
`src/web/test_browser_run.mjs` kiểm tra trang trong Chrome/Edge headless,
bao gồm so sánh pixel WebGL 2 với CPU; `src/web/test_wasm.mjs` chạy unit
test biên dịch cho wasm32-wasi. Xem [Trình duyệt](../browsers.md).

Để kiểm tra cả listener `WheelEvent` DOM thật của host:

```sh
zig build test-web -j1 -Dweb-browser="/path/to/chrome-or-edge"
```

Ví dụ trên Windows:
`-Dweb-browser="C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"`.
Trình duyệt chạy headless. Test kiểm tra delta theo pixel/dòng/trang,
Ctrl-pinch và chỉ chặn hành vi mặc định khi view nhận sự kiện.

<a id="other-platforms"></a>

## Nền tảng khác

Linux và Windows xây dựng từ bất kỳ máy nào. Các kiểm thử của Linux chạy trong vùng chứa GTK 3, WebKitGTK, phông chữ, Mesa và màn hình ảo (`tools/linux.Dockerfile`):

```sh
zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux
docker build -t myzig-linux -f tools/linux.Dockerfile tools
docker run --rm -v "$PWD/zig-out/linux:/work" myzig-linux xvfb-run ./bin/myzig-tests
```

Windows chương trình chạy trong Wine trên màn hình ảo (`tools/wine.Dockerfile` cho bản dựng arm64, `tools/wine-amd64.Dockerfile` cho bản dựng x86_64 trên máy Mac arm64). `zig build test -Dportable=true` chạy trên máy Mac, bộ kết xuất văn bản và CPU của Linux và Windows.

<a id="rules"></a>

## Quy tắc

- Các kiểm thử không bao giờ đạt hoặc không đạt theo thời gian trên đồng hồ treo tường: tăng đồng hồ của Người kiểm tra, chờ điều kiện bằng vòng lặp sự kiện (`myzig.runFor`), đo công việc theo số lượng.
- Các cuộc kiểm tra không bao giờ chạm đến trạng thái của người dùng: không có bảng tạm hệ thống, không có tệp bên ngoài thư mục tạm thời, không có giá trị mặc định.
- Mọi hành vi của widget đều được kiểm tra (`src/ui/tests*.zig`); xem [hướng dẫn kiến ​​trúc](../architecture-testing.md).
