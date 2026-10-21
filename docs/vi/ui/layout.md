<a id="layout"></a>

# Bố cục

Bố cục là flexbox, như trong CSS: một hộp sắp xếp các phần tử con của nó thành một hàng hoặc một cột, định cỡ chúng theo nội dung của chúng, chia sẻ không gian trống giữa những phần phát triển và căn chỉnh chúng dọc theo cả hai trục. Mỗi hộp được mô tả bởi một `ui.Style`, được cấp cho `ui.row`, `ui.column` và các vùng chứa khác hoặc được đặt bằng các phương thức `ui.div`.

Bố cục chạy mọi frame, theo hai lần: `measure` kích thước các hộp từ nội dung của chúng, từ dưới lên; `arrange` đặt chúng từ trên xuống. Bố cục văn bản được lưu vào bộ nhớ đệm trên các khung, do đó, một khung không thay đổi gì trong hộp sẽ tốn ít chi phí bố trí lại.

<a id="containers"></a>

## Thùng chứa

| chức năng | nó mở ra cái gì |
|---|---|
| `ui.column(c, style)` | trẻ em từ trên xuống dưới |
| `ui.row(c, style)` | con từ trái sang phải (phải sang trái trong [RTL](right-to-left.md)) |
| `ui.card(c, style)` | một cột trên bề mặt có màu, làm tròn 12, đệm 16, có bóng mờ, trừ khi kiểu dáng có quy định khác |
| `ui.scroll(c, style)` | một cột có các con cuộn theo chiều dọc |
| `ui.pressable(c, style, hover)` | một hộp báo cáo con trỏ (xem [widget tùy chỉnh](custom-widgets.md)) |
| `ui.div(c)` | một cột được tạo kiểu theo một chuỗi các phương thức, xem bên dưới |

Mỗi cái được đóng bởi `ui.end(c)` (một `ui.Div` bởi `end` của chính nó). `ui.spacer(c)` lấy phòng trống dọc theo trục chính của cha mẹ, đẩy phần tiếp theo đến cuối và `ui.divider(c)` vẽ một đường một điểm ngang qua cha mẹ của nó bằng màu đường viền.

```zig
ui.row(c, .{ .width = .fill, .padding = .xy(16, 10), .gap = 8, .align_items = .center });
defer ui.end(c);
ui.text(c, "Inbox", .{ .weight = .semibold });
ui.spacer(c);
_ = ui.button(c, "Compose", .{ .variant = .primary });
```

<a id="sizes"></a>

## Kích cỡ

`width` và `height` là `ui.Length`:

- `.auto`, mặc định: lớn bằng nội dung (cộng với phần đệm).
- `.{ .px = 120 }`: chính xác là nhiều điểm đó.
- `.fill`: toàn bộ số tiền phòng phụ huynh cho. Dọc theo trục chính của cha mẹ, nó phát triển như `grow = 1` từ phần đệm của nó; ngang qua nó, nó trải dài.

`min_width`, `min_height`, `max_width` và `max_height` giới hạn kích thước. `max_width` giúp văn xuôi có thể đọc được trong một cửa sổ rộng; `max_height` trên hộp cuộn làm cho nó cao bằng nội dung của nó đến độ cao đó, sau đó cuộn (câu trả lời của cuộc trò chuyện, danh sách của cửa sổ bật lên).

`grow` là một phần của hộp phòng trống dọc theo trục chính của bố mẹ nó: hai anh chị em có `grow = 1` và `grow = 2` chiếm một phần ba và hai phần ba số đó. Phòng được chia sẻ khi CSS flexbox chia sẻ phòng đó và Chrome sắp xếp phòng đó: mỗi hộp tăng dần theo kích thước của nó (kích thước cơ sở linh hoạt, trước mức tối thiểu và tối đa), một hộp `max_width` hoặc `min_width` dừng giữ nguyên kích thước đó và những hộp khác chia sẻ những gì còn lại. Một chiếc hộp không bao giờ nhỏ hơn phần đệm của nó, bất kể kích thước của nó nói lên điều gì.

Khi một hàng có quá ít chỗ, các hộp chứa văn bản gói sẽ trả lại phần văn bản của chúng theo tỷ lệ chiều rộng trừ đi phần đệm, xuống `min_width` và văn bản của chúng sẽ bao bọc thành nhiều dòng hơn. Các hộp khác giữ nguyên kích thước của chúng. Hộp có chiều rộng cuối cùng khác với chiều rộng được đo sẽ được đo lại, do đó, văn bản được ngắt dòng luôn có số dòng phù hợp.

<a id="spacing"></a>

## Khoảng cách

`padding` là `ui.Edges` (`top`, `right`, `bottom`, `left`), với `ui.Edges.all(12)` và `ui.Edges.xy(16, 8)` (ngang, dọc) cho các trường hợp thông thường; theo nghĩa đen có cấu trúc, `.padding = .all(12)`. `gap` là phòng giữa các trẻ dọc theo trục chính. Không có lề: các hộp dấu cách có khoảng trống và phần đệm của phần tử cha hoặc `ui.spacer`.

<a id="alignment"></a>

## Căn chỉnh

`align_items` đặt các phần tử con trên trục chính: `.start` (mặc định), `.center`, `.end`, `.stretch`, làm cho các phần tử con có kích thước chéo là `.auto` rộng (trong một cột) hoặc cao (trong một hàng) bằng hộp, hoặc `.baseline`, xếp các dòng văn bản đầu tiên của phần tử con trong một hàng, dưới dạng một mức giá lớn bên cạnh đơn vị nhỏ của nó, hàng càng cao càng cần. Đường cơ sở của một hộp là đường cơ sở của thành phần con đầu tiên khi nó bắt đầu hộp (của một hàng xếp các con của nó, của dòng của chúng) và một thành phần con không có văn bản sẽ xếp hàng ở dưới cùng của nó, như trong CSS; trên một cột `.baseline` là `.start`:

```zig
ui.row(c, .{ .align_items = .baseline, .gap = 4 });
defer ui.end(c);
ui.text(c, "$42", .{ .size = 40, .weight = .bold });
ui.text(c, "/month", .{ .color = c.theme.muted });
```

Các hàng của biểu mẫu sắp xếp nhãn của chúng với văn bản của điều khiển theo `baselines = true` (xem [biểu mẫu](forms.md)).

`justify` đặt chúng dọc theo nó khi không có cái nào mọc lên: `.start`, `.center`, `.end`, hoặc `.space_between`, giúp phân bổ khoảng trống giữa chúng.

```zig
// Centered both ways in the window.
ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 12 });
defer ui.end(c);
```

<a id="scrolling"></a>

## Cuộn

Một hộp có `scroll = true` (như `ui.scroll` tạo ra) kẹp các phần tử con của nó và cuộn chúng theo chiều dọc bằng bánh xe và bàn di chuột; một thanh cuộn mỏng hiển thị ở bên phải trong khi nội dung của nó tràn ra. Một khía của bánh xe chuột lướt qua đó một cách dễ dàng trong một thời gian ngắn, khi các trình duyệt cuộn nó, các khía liên tiếp cộng lại và một hộp ở cuối của nó để chúng vào hộp xung quanh nó; bàn di chuột di chuyển theo các ngón tay và với ít chuyển động hơn, một notch sẽ cuộn cùng một lúc. Hộp cuộn chiếm không gian được cung cấp, chứ không phải chiều cao nội dung của nó (như CSS's `min-height: 0`), vì vậy hãy đặt kích thước cho nó hoặc để nó phát triển:

```zig
ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .all(16), .gap = 8 });
defer ui.end(c);
for (s.messages) |m| messageRow(c, m);
```

Thay vào đó, một hàng có `scroll = true` cuộn sang một bên, dưới dạng một dải tab: nó lấy chiều rộng được cung cấp thay vì nội dung của nó, bánh xe sẽ di chuyển dọc theo và một thanh mỏng hiển thị dọc theo đáy của nó trong khi nội dung của nó tràn ra. Đặt `c.scroll` cho id của nó để hiển thị trẻ em. `c.scroll_limit.get(id)` là khoảng cách mà mỗi hộp cuộn được bố trí trong khung cuối cùng có thể cuộn (0 nơi nội dung của nó phù hợp hoặc nó trống), liệu bố cục có đo lại văn bản của nó hay giữ chúng; `c.scroll_max` chỉ được giữ lại cho các hộp tiếp theo phần cuối của chúng (bên dưới), vì vậy hãy đọc `scroll_limit` để biết các hộp khác. `c.glideBy(id, dy)` lướt hộp `id` bằng `dy` điểm (tăng tích cực), như một điểm nhấn so với nó, đối với những gì cuộn một hộp từ nơi khác: một bản đồ nhỏ, một cái nhìn tổng quan.

Với `follow_end = true`, hộp cuộn vẫn ở cuối khi nội dung của nó tăng lên, trong khi người đọc để nó ở đó: nhật ký, trò chuyện và terminal. Cuộn lên, nó vẫn ở nguyên vị trí; cuộn xuống, nó lại theo sau. `c.capScroll(id, offset)` chỉ cho phép nó theo sau một phần bù cho một khung và `c.scrollMoved(id)` cho biết liệu trình đọc hoặc ứng dụng có di chuyển nó thay vì theo sau hay không.

`follow_glide` làm cho nó lướt đến phần cuối khi nội dung của nó phát triển, như một hình ảnh động nói, thay vì hiển thị phần cuối cùng một lúc: những gì được thêm vào sẽ xuất hiện từ bên dưới, khi các ứng dụng trò chuyện cuộn. Trên khung nội dung thay đổi, các em ở lại chiếu chỗ nào thì về chỗ; một cú lướt trên đường đi tiếp tục từ nơi nó đến khi càng nhiều, người đọc sẽ dừng cuộn và với ít chuyển động hơn thì phần cuối sẽ hiển thị cùng một lúc. Nội dung vừa với hộp có `justify = .start` không di chuyển được gì, cũng như hộp cao bằng nội dung của nó (`max_height`); một chiếc hộp có chiều cao tự thay đổi (một cửa sổ đã được thay đổi kích thước, một nhà soạn nhạc bên dưới đã lớn lên) di chuyển các phần tử con của nó cùng một lúc.

```zig
const glide: ui.FollowGlide = .of(.smooth);
ui.column(c, .{ .scroll = true, .follow_end = true, .follow_glide = &glide, .grow = 1, .gap = 8 });
```

Đối với hàng nghìn hàng, hãy sử dụng danh sách ảo `ui.list`, danh sách này chỉ tạo các hàng trong view; xem [danh sách](lists.md).

<a id="positioning"></a>

## Định vị

`offset` di chuyển một hộp sau khi bố trí mà không di chuyển các hộp anh chị em của nó: một cú huých, một cú nhấn làm chìm một nút xuống nửa điểm, một cú kéo.

`absolute = true` lấy một hộp ra khỏi luồng: nó được đặt ở nguồn gốc nội dung của cha mẹ (cộng với `offset`), ở kích thước của chính nó (`.fill` lấp đầy hộp nội dung của cha mẹ), trên hoặc dưới các anh chị em của nó theo thứ tự được xây dựng. Huy hiệu trên biểu tượng và ô điều khiển trên ảnh là các hộp tuyệt đối:

```zig
ui.column(c, .{ .width = .{ .px = 48 }, .height = .{ .px = 48 } });
defer ui.end(c);
ui.icon(c, "folder", .{ .size = 40 });
{
    ui.row(c, .{ .absolute = true, .offset = .{ .x = 30, .y = -4 } });
    defer ui.end(c);
    ui.badge(c, "3", c.theme.danger);
}
```

Những thứ nổi trên mọi thứ (cửa sổ bật lên, menu, thông báo toast) là các lớp phủ, được bố trí phía trên view; xem [lớp phủ](overlays.md).

`transform` di chuyển, chia tỷ lệ và xoay một hộp như đã vẽ, khoảng `transform_origin`, sau khi bố trí: vị trí của nó trong luồng vẫn giữ nguyên. Xem [biến đổi](transforms.md).

<a id="clipping-and-opacity"></a>

## Cắt và độ mờ

`clip = true` kẹp các phần tử con của hộp vào đó, theo các góc tròn của hộp. `opacity` làm mờ một chiếc hộp và mọi thứ trong đó cùng nhau.

<a id="the-chain-of-ui-div"></a>

## Chuỗi `ui.div`

`ui.div(c)` mở một cột và trả về `ui.Div`, mỗi phương thức của nó đặt một trường theo kiểu của nó và trả về nó, để chúng xâu chuỗi, giống như các phần tử của GPUI thực hiện. Các phương thức kiểu được ưu tiên trước, sau đó là các phương thức con, sau đó là `end`:

```zig
const item = ui.div(c).row().wFull().px(10).py(6).gap(8).itemsCenter().rounded(7).hover(c.theme.surface_hover);
defer item.end();
if (item.clicked()) s.page = .settings;
ui.icon(c, "wrench.and.screwdriver", .{ .size = 14 });
ui.text(c, "Settings", .{ .weight = .medium });
```

| phương pháp | phong cách |
|---|---|
| `row()`, `column()` | `direction` |
| `gap(v)` | `gap` |
| `p(v)`, `px(v)`, `py(v)`, `pt(v)`, `pr(v)`, `pb(v)`, `pl(v)` | `padding`: tất cả, ngang, dọc, một bên |
| `w(v)`, `h(v)`, `size(w, h)` | `width`, `height` tính bằng điểm |
| `wFull()`, `hFull()`, `sizeFull()` | `.fill` |
| `grow()` | `grow = 1` |
| `minW(v)`, `maxW(v)`, `maxH(v)` | giới hạn |
| `itemsStart()`, `itemsCenter()`, `itemsEnd()`, `itemsStretch()` | `align_items` |
| `justifyCenter()`, `justifyEnd()`, `justifyBetween()` | `justify` |
| `center()` | cả hai, tập trung |
| `bg(color)`, `border(color)`, `borderW(v)` | nền, đường viền |
| `rounded(v)`, `roundedFull()` | `radius` |
| `shadow(s)`, `shadowSm()`, `shadowMd()`, `shadowLg()` | `shadow` |
| `opacity(v)` | `opacity` |
| `clip()`, `scrollY()`, `absolute()`, `offset(x, y)` | tràn và vị trí |
| `control()` | `control`: văn bản của nó không được chọn |
| `hover(color)` | nền giảm xuống `color` dưới con trỏ |

`interaction()`, `clicked()` và `hovered()` đọc cách con trỏ liên quan đến hộp, từ bố cục cuối cùng; `clicked()` cũng đặt `c.changed`, vì vậy những thay đổi khi nhấp chuột sẽ hiển thị trong khung này.

<a id="grids"></a>

## Lưới

Các hàng và cột xếp chồng lên nhau (một dạng nhãn và trường, bảng điều khiển gồm các thẻ) là một mạng lưới các bản nhạc; xem [bố cục lưới](grid.md).
