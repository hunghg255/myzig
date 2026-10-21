<a id="grid"></a>

# Lưới

`ui.grid` sắp xếp các phần tử con của nó theo hàng và cột, sau lưới CSS và mygo của `ui.Grid`: phần tử con điền vào các ô của nó theo hàng hoặc đi đến nơi chúng được đặt, bao trùm các cột và hàng. Sử dụng nó cho các biểu mẫu (nhãn trong một cột, các trường trong cột kia), bảng thông tin và ngăn cài đặt. Một lưới xây dựng tất cả các con của nó; đối với nhiều mục chỉ được tạo khi chúng hiển thị, hãy sử dụng [`ui.gridView`](lists.md#grid-views).

```zig
var g = ui.grid(c, .{ .columns = &.{ .fit, .{ .fr = 1 } }, .gap_x = 16, .gap_y = 8 });
g.cell(.{ .col_span = -1 }); // across every column
ui.text(c, "Profile", .{ .weight = .bold });
ui.end(c);
ui.text(c, "Name", .{}); // a child outside a cell takes the next one
_ = ui.textField(c, &s.name, .{});
ui.text(c, "Email", .{});
_ = ui.textField(c, &s.email, .{});
g.end();
```

`ui.grid(c, opts)` mở lưới; con của nó theo sau thì `end()`.

<a id="tracks"></a>

## Bài hát

Cột và hàng là `ui.GridTrack`s:

| Theo dõi | Kích thước |
|---|---|
| `.fit` | lớn như nội dung của nó |
| `.{ .px = 220 }` | chính xác là nhiều điểm |
| `.{ .fr = 1 }` | một phần phòng mà các bài hát khác để lại (CSS's `minmax(0, 1fr)`); trong đó kích thước của lưới không được đặt, lớn bằng nội dung của nó |

`.{ .fr = 2 }` chiếm gấp đôi số phòng của `.{ .fr = 1 }`. `rows` đưa ra các hàng đầu tiên; những cái sau chúng phù hợp với nội dung của chúng, vì vậy hầu hết các lưới chỉ cung cấp `columns`. Một lưới có tối đa 32 cột và 32 hàng nhất định.

`ui.GridOptions`:

| trường | Mặc định | |
|---|---|---|
| `columns` | `&.{.{ .fr = 1 }}` | bài hát cột |
| `rows` | `&.{}` | bài hát của hàng đầu tiên |
| `gap_x`, `gap_y` | 0 | giữa các cột, giữa các hàng |
| `justify_items` | `.stretch` | nơi trẻ đi qua các ô của mình: `.stretch`, `.start`, `.center` hoặc `.end` |
| `align_items` | `.stretch` | nơi trẻ đi xuống các ô của mình hoặc `.baseline`: các dòng văn bản đầu tiên của các mục trong mỗi hàng xếp thành hàng, như trong một [hàng](layout.md#alignment), hàng cao nhất có thể |
| `style` | `.{ .width = .fill }` | hộp riêng của lưới: phần đệm, nền, kích thước |

<a id="cells"></a>

## Tế bào

Một đứa trẻ được xây dựng thẳng trong lưới sẽ lấy ô trống tiếp theo. Để đặt một ô con, kéo dài các rãnh hoặc tự căn chỉnh nó, hãy mở một ô có `Grid.cell(opts)`: các ô con của ô đó theo sau, sau đó là `ui.end(c)`. Ô là một hộp cột lấp đầy vị trí của nó khi lưới của nó căn chỉnh nó.

`ui.GridCell`:

| trường | Mặc định | |
|---|---|---|
| `col`, `row` | 0 | cột và hàng nó bắt đầu, từ 1; 0 đặt nó vào ô trống tiếp theo |
| `col_span`, `row_span` | 1 | nó trải dài bao nhiêu cột và hàng; trải dài âm đến cột cuối cùng (hoặc hàng cuối cùng mà lưới đưa ra) |
| `justify`, `align` | null | căn chỉnh riêng của nó, trên `justify_items` và `align_items` của lưới |
| `style` | không có | hộp của tế bào |

```zig
var g = ui.grid(c, .{ .columns = &.{ .fit, .{ .px = 50 }, .{ .fr = 1 } }, .gap_x = 4 });
g.cell(.{ .col_span = -1 }); // a header across the three columns
ui.text(c, "Totals", .{ .weight = .bold });
ui.end(c);
ui.text(c, "Apples", .{});
ui.text(c, "12", .{});
g.cell(.{ .justify = .end, .@"align" = .center }); // pushed to its cell's end
ui.text(c, "$4.80", .{ .mono = true });
ui.end(c);
g.cell(.{ .col = 3, .row = 3, .row_span = 2 }); // given a place, two rows tall
ui.text(c, "Notes", .{});
ui.end(c);
g.end();
```

Các ô được đặt với `col` và `row` giữ nguyên vị trí của chúng và các ô con sau chúng sẽ di chuyển xung quanh các ô mà chúng chiếm giữ.

<a id="sizing"></a>

## Định cỡ

Lưới rộng như `style` cho biết (`.fill` theo mặc định) và cao bằng các hàng của nó: những gì theo sau nó trong cột sẽ theo sau. Các cột của `.fit` có chiều rộng bằng cột con rộng nhất của chúng, các cột `px` được cố định và các cột `fr` chia sẻ những gì còn lại. Một đứa trẻ trải dài trên nhiều bản nhạc sẽ lan truyền những gì nó thiếu trên các bản nhạc phù hợp mà nó trải dài (hoặc, khi nó trải dài `fr` các bản nhạc, trên phần chia sẻ của chúng). Trong trường hợp không xác định được kích thước của lưới, các bản nhạc `fr` sẽ phù hợp với nội dung của chúng, tương ứng với tỷ lệ chia sẻ của chúng. Chỉ những cột con được đọc mới được đo theo chiều rộng của lưới: những cột trong cột cố định hoặc trong `fr` cột có chiều rộng đã biết (như CSS's `minmax(0, 1fr)`), được đo một lần, ở chiều rộng mà ô của chúng cung cấp.

Từ phải sang trái, các cột của lưới đi từ bên phải (xem [Phải sang trái](right-to-left.md)).

<a id="flexbox-or-grid"></a>

## Flexbox hoặc lưới

Các hàng và cột của [layout](layout.md) là một chiều: mỗi hàng có kích thước riêng cho các hàng con của nó, do đó các nhãn trong các hàng riêng biệt không xếp hàng trừ khi mỗi hàng có chiều rộng cố định. Lưới có kích thước các ô của mỗi hàng theo cùng một rãnh: cột `.fit` có chiều rộng bằng nhãn dài nhất trong mỗi hàng.
