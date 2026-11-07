<a id="testing"></a>

# Testing

myzig test UI native mà không cần cửa sổ, và test app mà không hiện cửa sổ nào. Không có gì chạm tới màn hình, chuột, bàn phím hay clipboard của hệ thống. Test không làm phiền người đang ngồi trước máy, và cho cùng kết quả dù máy đang bận hay rảnh.

- **View** chạy trong `ui.Tester`: cùng các frame mà cửa sổ chạy, input giả lập ngay trong process, thời gian do test tự cho chạy, frame được render offscreen ra file PNG.
- **App** chạy headless với các cờ `--myzig-*`: chụp cửa sổ native đầu tiên sau một kịch bản các bước, hoặc chạy JavaScript trong các trang của app.
- **Renderer** được test so với renderer CPU, khớp từng pixel trong phạm vi sai số làm tròn (xem [Rendering](rendering.md)).

<a id="ui-tester"></a>

## ui.Tester

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

`ui.Tester` được khởi tạo tại chỗ, vì context của nó trỏ vào bên trong nó. `init` chạy frame đầu tiên.

| `ui.TesterOptions` | Mặc định | |
|---|---|---|
| `width`, `height` | 480 × 360 | tính bằng điểm |
| `scale` | 2 | |
| `dark` | `false` | giao diện tối |
| `theme` | `null` | bộ màu riêng, như tùy chọn `theme` của cửa sổ |

<a id="input"></a>

### Input

| Lệnh gọi | Tác dụng |
|---|---|
| `click(x, y)`, `clickText(s)` | bấm và nhả tại một điểm, hoặc tại giữa chữ `s` (`error.TextNotFound` khi không có chữ nào là `s`) |
| `doubleClick(x, y)` | hai cú bấm, cú thứ hai được tính là double click |
| `rightClick(x, y)` | bấm nút phụ, thường mở context menu |
| `middleClick(x, y)` | bấm nút giữa (`c.input.middle_pressed`), thường đóng tab trình duyệt |
| `moveTo(x, y)` | di chuyển con trỏ: hover |
| `pinch(x, y, scale)` | đưa một mức zoom nhân cho handler dưới điểm đó; trả về việc nó có được nhận hay không |
| `drag(x1, y1, x2, y2)` | bấm, di chuyển qua tám bước, rồi nhả |
| `scroll(x, y, dy)` | scroll ngay box dưới điểm đó, như touchpad, hoặc chuyển bánh xe cho view nào nhận nó (`c.wants_wheel`) |
| `wheel(x, y, dy)` | một nấc bánh xe chuột: box trượt tới đó khi đồng hồ chạy (`advance`); khi box đã ở cuối, box bao ngoài nhận tiếp |
| `typeText(s)` | gõ chữ vào ô đang có focus |
| `textOps(ops)` | gửi các thao tác nhập chữ (`ui.TextOp`), như bộ gõ hoặc key binding của AppKit: chèn, lệnh, đoạn đang soạn |
| `key(k)` | nhấn một phím (`Key` của `ui.Context`: `.enter`, `.tab`, `.escape`, `.left`, `.f12`, ...) |
| `shortcut(s)` | đưa một tổ hợp phím (`ui.Shortcut{ .key = 's', .cmd = true }`), như cửa sổ làm trước khi soạn chữ; true nếu view nhận nó |
| `keyEdge(code, down)` | một phím được nhấn xuống hoặc nhả ra, cho view theo dõi phím (`c.wants_keys`): game |
| `resize(w, h)` | đổi kích thước cửa sổ và chạy một frame |

<a id="what-it-shows"></a>

### Những gì nó hiển thị

- `findText(s)` trả về hình chữ nhật của chữ `s` trong frame vừa rồi.
- `hasText(s)` cho biết chữ đó có ở đó không.
- `containsText(s)` cho biết có đoạn chữ nào được vẽ chứa `s` không, như một hàng của terminal hay một đoạn văn.
- `t.ctx` là `ui.Context` của view, cho những gì test cần đọc: focus, các box và hình chữ nhật của chúng (`t.ctx.nodes`, `t.ctx.rects`), thống kê của frame.
- Những gì copy và cut đã ghi nằm trong `t.clipboard`. Test không bao giờ đụng tới clipboard của hệ thống.
- Những gì công nghệ hỗ trợ thấy cũng được test qua `ui.Tester`: xem [Accessibility](accessibility.md#testing-it).

<a id="time"></a>

### Thời gian

```zig
try t.clickText("More");
t.advance(0.1);   // một phần mười giây frame: giữa chừng một animation
t.settle(2);      // chạy frame cho tới khi không còn gì chuyển động, tối đa hai giây
try std.testing.expect(!t.ctx.animating);
```

`ui.Tester` có đồng hồ riêng, `t.time`, tăng thêm `t.dt` (1/60 giây) mỗi frame. Animation, double click, con trỏ soạn thảo nhấp nháy, tooltip, toast và `c.time` đều theo đồng hồ này, không bao giờ theo giờ thật.

| Lệnh gọi | Chạy |
|---|---|
| `t.frame()` | một frame, cho những gì thay đổi bên ngoài view |
| `t.advance(seconds)` | số frame ứng với khoảng thời gian đó |
| `t.settle(max)` | các frame cho tới khi animation dừng hẳn |

Đừng bao giờ sleep trong test để chờ việc gì xảy ra: hãy cho đồng hồ chạy tới.

Cử chỉ:

- `t.pinch(x, y, scale)` đưa một cú zoom touchpad cho [callback `handleInput`](gestures.md), và trả về việc nó có được nhận hay không.
- `t.scroll` và `t.wheel` đưa event scroll cho các handler đó trước khi scroll các container bao quanh.

<a id="pictures"></a>

### Ảnh

```zig
const px = try t.render(std.testing.allocator);
defer px.deinit(std.testing.allocator);
// px.bytes[(y * px.width + x) * 4 ..][0..4] là B, G, R, A
```

- `t.screenshot(path)` render frame vừa rồi offscreen và ghi ra PNG. Trên macOS nó dùng Metal. Nó dùng renderer CPU ở nơi chữ do myzig tự vẽ: Linux, Windows, trình duyệt, và macOS khi build với `-Dportable=true`.
- `t.render(gpa)` trả về pixel thay vì ghi file, để so sánh. Đó là `gpu.Pixels`: BGRA, premultiplied; giải phóng bằng `deinit`.
- `t.rasterize(bytes)` vẽ vào vùng nhớ kích thước `t.pixelSize()` bằng renderer CPU.

<a id="scripts"></a>

### Kịch bản

`t.runScript(steps)` chạy các bước cách nhau bởi `;`. Sau mỗi bước là các frame cho tới khi animation dừng.

| Bước | Tác dụng |
|---|---|
| `click:TEXT`, `move:TEXT` | bấm hoặc hover vào giữa một đoạn chữ |
| `visible:TEXT` | thất bại nếu đoạn chữ không hiện trọn trong cửa sổ (`move:` tìm được cả chữ nằm ngoài) |
| `rclick:TEXT` | bấm chuột phải vào giữa đoạn chữ (hoặc `X,Y` tính bằng điểm), như để mở context menu |
| `type:TEXT` | gõ chữ |
| `key:NAME` | nhấn một phím: `enter`, `backspace`, `tab`, `escape`, `left`, `right`, `up`, `down`, ... |
| `shortcut:KEYS` | một tổ hợp phím như `ctrl+shift+p` (`cmd`, `ctrl`, `alt`, `shift`, rồi một ký tự, phím mũi tên, `enter`, `tab`, `escape` hoặc `f1` đến `f12`) |
| `scroll:DY` | scroll tại vị trí con trỏ |
| `wheel:DY` | scroll tại con trỏ như các nấc bánh xe chuột, có trượt (`frames:N` để xem) |
| `drag:FROM>TO` | kéo từ một đoạn chữ (hoặc `X,Y`) tới đoạn khác |
| `wait:SECONDS` | cho đồng hồ giả lập chạy tới |
| `frames:N` | chạy N frame, rồi không chờ dừng: chụp giữa chừng animation |
| `live:SECONDS` | chạy event loop thật trong khoảng đó: phản hồi, process, timer |
| `resize:WxH` | đổi kích thước cửa sổ |

Kịch bản chính là thứ `--myzig-script` chạy trong một app thật.

<a id="apps-headless"></a>

## App, chạy headless

Mọi app tạo bằng `myzig.App` đều đọc các cờ sau (`src/dev.zig`):

| Cờ | Tác dụng |
|---|---|
| `--myzig-snapshot=PNG` | render cửa sổ UI native đầu tiên offscreen ra PNG, rồi thoát |
| `--myzig-script=STEPS` | đi kèm snapshot: chạy các bước trước, như `runScript` |
| `--myzig-dark` | đi kèm snapshot: giao diện tối |
| `--myzig-wait=SECONDS` | đi kèm snapshot: chạy event loop chừng ấy thời gian trước, để process, timer và phản hồi mà app chờ kịp tới |
| `--myzig-eval=JS` | chạy JavaScript trong mỗi trang khi DOM sẵn sàng; trang báo kết quả bằng `myzig.log()` và kết thúc bằng `myzig.window.close()` |
| `--myzig-hidden` | không bao giờ hiện cửa sổ; các thư mục của app là thư mục tạm (headless) |
| `--myzig-generate=DIR` | ghi ra client sinh tự động (`myzig.js`, `myzig.d.ts`) rồi thoát |

Snapshot, eval hoặc generate đều ngầm hiểu là ẩn cửa sổ.

```sh
zig-out/bin/gallery --myzig-snapshot=/tmp/g.png --myzig-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
```

<a id="pages"></a>

## Trang web

`zig build test-pages` chạy các trang ở chế độ ẩn, qua webview và bridge thật của nền tảng:

- ví dụ hello gọi Zig: lệnh gọi, lỗi, một event, client sinh tự động;
- ví dụ pages (`examples/pages`), nơi một trang ẩn và Zig kiểm tra lẫn nhau: scheme, channel, event, quyền, tải xuống, eval, tìm kiếm, PDF, cookie và trust.

Mỗi phần đạt khi trang log ra `page: ok`.

<a id="examples-with-tests"></a>

## Ví dụ có test

Một ví dụ có thể chứa các khối `test` riêng, chạy bởi `zig build test`. Đó là danh sách `tested_examples` trong `build.zig`: blackhole, chat-glow, wind, effort-slider, mayoi và loading.

- View của chúng chạy qua `ui.Tester`.
- Shader của chúng được vẽ trên CPU và kiểm tra xem có vẽ đúng thứ cần vẽ không.

`zig build test-loading -j1` chỉ chạy plugin loading và gallery. Nó kiểm tra thời lượng, các đồng hồ độc lập, build lặp lại và giảm chuyển động.

<a id="browsers"></a>

## Trình duyệt

`zig build test-web` build counter, gallery và gestures cho trình duyệt. Nó chạy chúng headless dưới Node (`src/web/test_node.mjs`), và cần `node`. Nó kiểm tra:

- một frame được vẽ, và không vẽ gì khi rảnh;
- bấm vào một đoạn chữ thì hiện đoạn khác;
- pinch và pan làm thay đổi ví dụ gesture.

Các runner khác:

- `src/web/test_browser_run.mjs` chạy cùng phép kiểm tra trong Chromium headless (Chrome hoặc Edge, ẩn). Nó so WebGL 2 với pixel của renderer CPU.
- `src/web/test_wasm.mjs` chạy unit test của myzig biên dịch cho wasm32-wasi.

Xem [Browsers](../browsers.md).

Để kiểm tra thêm listener `WheelEvent` thật của DOM trên host:

```sh
zig build test-web -j1 -Dweb-browser="/path/to/chrome-or-edge"
```

Ví dụ trên Windows, dùng `-Dweb-browser="C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"`. Trình duyệt chạy headless. Các test này bao gồm delta theo pixel, dòng và trang, Ctrl-pinch, và việc chỉ chặn hành vi mặc định khi view xử lý event.

<a id="other-platforms"></a>

## Nền tảng khác

Linux và Windows build được từ máy bất kỳ. Test của Linux chạy trong một container có GTK 3, WebKitGTK, font, Mesa và màn hình ảo (`tools/linux.Dockerfile`):

```sh
zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux
docker build -t myzig-linux -f tools/linux.Dockerfile tools
docker run --rm -v "$PWD/zig-out/linux:/work" myzig-linux xvfb-run ./bin/myzig-tests
```

- Chương trình Windows chạy dưới Wine trên màn hình ảo: `tools/wine.Dockerfile` cho bản build arm64, `tools/wine-amd64.Dockerfile` cho bản build x86_64 trên máy Mac arm64.
- `zig build test -Dportable=true` chạy, trên Mac, phần chữ và renderer CPU của Linux và Windows.

<a id="documentation-images"></a>

## Ảnh trong tài liệu

Các hướng dẫn UI dùng ảnh PNG của widget đang chạy, render offscreen bằng `ui.Tester`. Từ thư mục gốc của repository, tạo lại chúng bằng:

```sh
cd docs
npm run images:ui
npm run build
```

- `images:ui` chạy `zig build docs-ui -Doptimize=ReleaseFast -j1`.
- Sau đó nó nén không mất dữ liệu các PNG vào `docs/images/ui/`.
- Nó cần Zig 0.17 và Node, không cần công cụ xử lý ảnh nào khác.
- Trang tiếng Anh và tiếng Việt dùng chung ảnh. Chữ trên ảnh theo ví dụ Gallery tiếng Anh.

Để chỉ cập nhật một số ảnh sau khi render, chạy từ thư mục gốc của repository:

```sh
node docs/scripts/ui-images.mjs items.png input-groups.png pagination.png
```

Ảnh được tạo ra thế nào:

- [Snapshot runner](../../../examples/gallery/snapshots.zig) dùng lại các view của Gallery. Nó cắt khung từng thẻ theo layout đã tính, và mở menu, dialog bằng input giả lập của `ui.Tester` ngay trong process.
- [Các cảnh nền tảng](../../../examples/gallery/snapshot_foundations.zig) minh họa layout, grid, hướng chữ và shader của hướng dẫn.
- Không cửa sổ nào hiện ra và không pixel nào của desktop bị chụp.
- Ảnh đã commit được tạo trên Windows bằng renderer CPU và font hệ thống. Thông số font có thể khác trên nền tảng khác.
- Ảnh chuyển động chỉ là khung hình tĩnh. Công cụ này không chụp được webview hệ thống nhúng trong app.

Sau khi đổi một widget có ảnh minh họa:

1. tạo lại ảnh;
2. xem ảnh có bị cắt nội dung không;
3. commit ảnh cùng với tài liệu.

`npm run build` kiểm tra xem ảnh có tìm thấy được trên trang tài liệu không.

<a id="rules"></a>

## Quy tắc

- Test không bao giờ đạt hay trượt vì giờ thật. Hãy cho đồng hồ của `ui.Tester` chạy tới, chờ điều kiện bằng event loop (`myzig.runFor`), đo công việc bằng số đếm.
- Test không bao giờ đụng tới state của người dùng: không clipboard hệ thống, không file ngoài thư mục tạm, không defaults.
- Mọi hành vi của widget đều có test (`src/ui/tests*.zig`); xem [hướng dẫn kiến trúc](../architecture-testing.md).
