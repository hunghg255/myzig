# Vùng thả file

![Vùng nhận file và danh sách đường dẫn có thể xóa.](../../images/ui/file-drop.png)

`fileDropZone` dùng cơ chế target của `DragDrop` cho danh sách file cục bộ
và URI. `FileList` giữ bản sao đường dẫn, nên dữ liệu còn tồn tại sau khi
drop hết hiệu lực. Widget không đọc nội dung hay tải file lên mạng.

```zig
// Khởi tạo state một lần:
files: ui.FileList, // khởi tạo bằng .init(gpa)
drag: ui.DragDrop = .{},

// Trong view:
const result = ui.fileDropZone(c, &s.drag, &s.files, .{ .max_files = 8 });
if (result.browse) requestFileDialog();
if (result.err) |err| reportError(err);
// Cuối view, nếu controller này còn có nguồn kéo:
s.drag.preview(c);
```

Gọi `files.deinit()` và `drag.deinit()` khi hủy state. Với kết quả hộp thoại
chọn file của ứng dụng, thêm bằng `try files.add(path)` rồi yêu cầu vẽ lại.
`add` sao chép chuỗi, trả `false` khi đường dẫn rỗng hoặc trùng. Giới hạn
`max_files` chỉ áp dụng cho thao tác thả, không áp dụng khi ứng dụng gọi
`add` trực tiếp.

Kết quả gồm `changed`, `browse`, `over`, số đường dẫn bị từ chối do giới hạn
và `err` tùy chọn khi cấp phát hoặc giải mã thất bại. Những đường dẫn đã
nhận vẫn được giữ nếu mục sau gặp lỗi. Mục trùng không chiếm thêm chỗ.
Mỗi đường dẫn có nút Remove; `disabled` chặn chọn file, xóa và thả. Có thể
đổi `title`, `description`, `browse_label` và `width`.

Nút Browse trong Gallery thêm đường dẫn mẫu để ví dụ chạy xác định. Ứng
dụng thực tế tự xử lý sự kiện `browse`. Khả năng kéo từ bên ngoài phụ thuộc
backend hiện có; xem [kéo và thả](drag-and-drop.md).
