<a id="styling-and-themes"></a>

# Kiểu dáng và chủ đề

Hình thức của hộp là một phần của `ui.Style`, bên cạnh bố cục của nó: nền, đường viền, các góc tròn, bóng, độ mờ. Các widget lấy màu từ chủ đề của khung, `c.theme`, theo giao diện sáng hoặc tối của hệ thống trừ khi ứng dụng sửa lỗi đó.

```zig
ui.column(c, .{
    .padding = .all(16),
    .gap = 8,
    .background = c.theme.surface,
    .border = c.theme.border,
    .radius = 12,
    .shadow = .{ .color = c.theme.shadow, .blur = 16, .y = 4 },
});
defer ui.end(c);
```

<a id="the-look-of-a-box"></a>

## Vẻ ngoài của một chiếc hộp

| lĩnh vực | nó vẽ cái gì |
|---|---|
| `background: ?Color` | điền vào, bên trong các góc tròn |
| `border: ?Color`, `border_width` (1) | một đường viền bên trong cạnh của hộp |
| `radius` | bán kính các góc, tính bằng điểm; `1e4` (`roundedFull()`) tạo thành một viên thuốc hoặc một vòng tròn |
| `corners` | cách chúng uốn cong: `.circular` (CSS's) hoặc `.continuous` (`continuous()`), như macOS và iOS uốn cong chúng |
| `shadow: ?Shadow` | bóng Gaussian: `color`, `blur` (độ lệch chuẩn, 12 theo mặc định) và `y` (giảm, 4) |
| `opacity` | hộp và nội dung của nó cùng nhau, 0 đến 1 |
| `gradient: ?*const Gradient` | màu tuyến tính, xuyên tâm hoặc hình nón trên nền |
| `blur` | làm mờ hộp và các phần tử con của nó như được vẽ (CSS's `filter: blur()`) |
| `effect: ?*const Effect` | kéo chiếc hộp từ những gì bên dưới nó (kính mờ) |

Các góc liên tục ("hình tròn", đường cong góc liên tục của Core Animation và hình chữ nhật bo tròn của SwiftUI) để các cạnh ở xa góc hơn, khoảng 1,53 lần bán kính và uốn cong dần dần, do đó, thẻ hoặc nút trông giống như hệ thống. Chúng định hình nền và đường viền của hộp, bóng của hộp, hình ảnh của hộp (`ui.image`'s `corners`), độ dốc của hộp và những gì nó cắt ra, đồng thời mọi bộ kết xuất đều vẽ chúng giống nhau (CPU và GPU). Hiệu ứng phông nền giữ các góc tròn.

```zig
ui.card(c, .{ .radius = 18, .corners = .continuous, .shadow = .{ .blur = 18, .y = 6 } });
const tile = ui.div(c).w(64).h(64).rounded(14).continuous().bg(th.accent);
```

Chuyển màu, làm mờ, hiệu ứng phông nền và chuyển đổi đều có một trang riêng: [chuyển đổi và hiệu ứng](transforms.md). Độ dốc được giữ cho đến khi khung được vẽ, vì vậy hãy truyền một hằng số, bộ nhớ của ứng dụng hoặc khung (`c.alloc().create(ui.Gradient)`).

<a id="colors"></a>

## Màu sắc

`ui.Color` là sRGB với alpha thẳng, mỗi kênh từ 0 đến 1:

```zig
const blue: ui.Color = .hex(0x0a84ff);
const faint = blue.alpha(0.15);                 // multiplies its opacity
const between = c.theme.surface.mix(blue, 0.3); // 30% of the way to blue
const ink: ui.Color = .{ .r = 0.1, .g = 0.1, .b = 0.12 };
```

`ui.Color.white`, `.black` và `.transparent` là các hằng số.

Đối với bảng màu, `ui.oklch(l, c, h)` tạo màu trong Oklch, giống như CSS của `oklch()`: độ sáng từ 0 đến 1, sắc độ từ khoảng 0 đến 0,4 và màu sắc tính theo độ. Màu sắc của một độ sáng trông sáng như nhau, do đó, bảng màu ở cùng một độ sáng và sắc độ vẫn đồng đều và vùng nhấn của điểm nhấn cũng có màu sắc tối hơn một chút. Màu sRGB không thể hiển thị bị mất sắc độ, giữ được độ sáng và màu sắc. `ui.toOklch(color)` quay lại là `[3]f32`.

```zig
const accent = ui.oklch(0.62, 0.19, 255);
const hover = ui.oklch(0.55, 0.19, 255);
```

<a id="state-not-selectors"></a>

## Trạng thái, không phải bộ chọn

Không có bộ chọn và không có lớp giả: khung nhìn biết trạng thái và các hộp kiểu từ nó. Di chuột, nhấn và lấy nét đến từ sự tương tác của hộp; `c.animate` giảm bớt giá trị hướng tới mục tiêu, do đó, sự thay đổi về giao diện sẽ diễn ra sinh động thay vì đột ngột:

```zig
const i = c.open(.{ .padding = .xy(12, 6), .radius = 6 }, null);
defer c.end();
const it = c.interact(i, .{});
const t = c.animate(it.id, 0, if (it.hovered) 1 else 0, 18);
c.node(i).style.background = c.theme.surface.mix(c.theme.surface_hover, t);
```

`ui.div(...).hover(color)` thực hiện việc này làm nền. Xem [widget tùy chỉnh](custom-widgets.md) để biết các tương tác và [chuyển động](motion.md) để biết các lò xo, khung hình chính và chuyển tiếp.

Di chuột theo tổ tiên, như `:hover` của CSS thực hiện: một hàng được di chuột trong khi con trỏ ở trên một nút bên trong nó, do đó, một hàng hiển thị các nút của nó khi di chuột sẽ giữ chúng trong khi con trỏ đi tới chúng.

<a id="the-theme"></a>

## Chủ đề

`ui.Theme` chứa các màu mà mọi widget sử dụng và phông chữ:

| lĩnh vực | dùng cho |
|---|---|
| `dark` | cho dù đó là một chủ đề tối |
| `background` | cửa sổ |
| `surface`, `surface_hover` | thẻ, trường, nút phụ và di chuột của chúng |
| `text`, `muted` | văn bản và văn bản phụ (nhãn, phần giữ chỗ) |
| `border` | ranh giới, dải phân cách |
| `accent`, `accent_hover`, `accent_text` | các nút chính, lựa chọn, vòng lấy nét và văn bản trên dấu |
| `track`, `knob` | các rãnh và nút bấm của thanh trượt, công tắc và thanh tiến trình |
| `danger`, `success` | hành động phá hoại và sai sót; xong và tiếp tục |
| `shadow` | màu sắc của bóng tối |
| `font`, `mono_font` | họ phông chữ, null cho ([text](text.md)) của hệ thống |

`ui.Theme.light` và `ui.Theme.dark_theme` là của myzig, sau màu của macOS. Một cửa sổ sử dụng cái này hoặc cái kia làm giao diện của hệ thống, chuyển đổi khi nó thay đổi. Để sửa màu của cửa sổ, hãy đặt chủ đề cho cửa sổ:

```zig
var mine = ui.Theme.dark_theme;
mine.accent = .hex(0xff9f0a);
mine.font = "Inter";
_ = try app.newWindow(.{ .title = "Player", .theme = mine, .content = .{ .view = .init(&state, State.view) } });
```

Trong view, `ui.themes.apply(c, theme)` tạo chủ đề cho khung (những widget nào được tạo sau khi đọc và nền của cửa sổ); gọi nó đầu tiên. `myzig.isDark()` và `myzig.accentColor()` đọc diện mạo và giọng nói của hệ thống bên ngoài view.

<a id="named-themes"></a>

## Chủ đề được đặt tên

`ui.themes.builtins` liệt kê các chủ đề của myzig theo tên: `light`, `dark`, `light-high-contrast` và `dark-high-contrast`. `ui.themes.find(list, name)` trước tiên tìm tên trong danh sách riêng của ứng dụng, sau đó trong myzig, đối với chủ đề được lưu trong cài đặt theo tên:

```zig
const app_themes = [_]ui.themes.Named{
    .{ .name = "solarized", .theme = solarized },
};

fn view(s: *State, c: *ui.Context) void {
    if (ui.themes.find(&app_themes, s.theme_name)) |t| ui.themes.apply(c, t);
    // ...
}
```

`ui.themes.forAppearance(dark, light_theme, dark_theme)` chọn màu sáng hoặc tối trong một cặp, `ui.themes.withAccent(theme, color)` tạo điểm nhấn khác cho chủ đề (với con trỏ và văn bản màu đen trên đó ở nơi màu trắng sẽ không nổi bật, như màu vàng) và `ui.themes.mix(a, b, t)` pha trộn mọi màu của hai chủ đề.

<a id="switching-themes-animated"></a>

## Chuyển đổi chủ đề, hoạt hình

`ui.ThemeSwitcher` (`ui.themes.Switcher`) thay đổi từ chủ đề này sang chủ đề khác với mỗi lần giảm màu, giống như hệ thống thực hiện khi hình thức của nó thay đổi. Giữ nó ở trạng thái, thay đổi nó bằng `switchTo` và `apply` trước tiên trong view:

```zig
const State = struct {
    dark: bool = false,
    theme: ui.ThemeSwitcher = .{},

    fn view(s: *State, c: *ui.Context) void {
        s.theme.apply(c);
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (ui.toggle(c, "Dark", &s.dark))
            s.theme.switchTo(if (s.dark) ui.Theme.dark_theme else ui.Theme.light);
    }
};
```

Trước `switchTo` đầu tiên, chủ đề riêng của cửa sổ sẽ hiển thị. `duration` theo mặc định là 0,3 giây; `changing()` cho biết liệu một thay đổi có đang diễn ra hay không và `current()` chủ đề được hiển thị ngay bây giờ. Màu sắc không chuyển động nên chủ đề thay đổi mượt mà ngay cả khi người dùng yêu cầu ít chuyển động hơn.

<a id="the-desktop-s-preferences"></a>

## Tùy chọn của máy tính để bàn

`ui.preferences.apply(c)`, được gọi đầu tiên trong view, làm cho khung tuân theo cài đặt của người dùng và trả về chúng dưới dạng `ui.Preferences`:

| lĩnh vực | từ |
|---|---|
| `accent` | màu nhấn mà người dùng đã chọn, null trong đó màn hình không có |
| `high_contrast` | macOS's Tăng độ tương phản, chủ đề tương phản của Windows', chủ đề tương phản cao GTK |
| `text_scale` | Windows' kích thước văn bản, độ phân giải phông chữ của GTK, thông thường là 1 |
| `reduce_motion` | cài đặt chuyển động giảm thiểu của hệ thống (xem [chuyển động](motion.md)) |

Chủ đề lấy điểm nhấn và với độ tương phản cao, đường viền và văn bản phụ gần với màu của văn bản hơn (`ui.preferences.highContrast(theme)`); văn bản được chia tỷ lệ từ `text_scale` đến `c.setZoom`. Máy tính để bàn được hỏi một lần cho mỗi quá trình; `ui.preferences.refresh()` hỏi lại khi nào nó cho biết cài đặt của nó đã thay đổi.

Cài đặt riêng của ứng dụng sẽ ghi đè cài đặt của máy tính để bàn đối với ngữ cảnh: `ui.preferences.setHighContrast(c, on)`, `setTextScale(c, scale)` và `setAccent(c, color)`, mỗi cài đặt sẽ lấy null để theo dõi lại máy tính để bàn. `ui.preferences.get(c)` đọc nội dung của khung mà không áp dụng khung đó.

```zig
fn view(s: *State, c: *ui.Context) void {
    if (s.big_text_changed) ui.preferences.setTextScale(c, if (s.big_text) 1.3 else null);
    const prefs = ui.preferences.apply(c);
    _ = prefs;
    // ...
}
```
