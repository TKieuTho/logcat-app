# Changelog

## 0.4.0 — 2026-10-27
- Thêm "Check for Updates…" (menu ⋯ và menu app): đọc latest.json, báo khi có bản mới và mở link tải. Tự kiểm tra âm thầm khi mở app (chỉ báo khi có bản mới).
- Hiển thị số version cạnh tên app.

## 0.3.0 — 2026-10-27
- Đổi tên app thành **Logcat** (Logcat.app).
- Giao diện mới theo mascot mèo: icon app, logo ở header (nền trong suốt), nền app màu trắng (chế độ tối vẫn nền nâu), mặc định chế độ sáng.

## 0.2.0 — 2026-10-27
- UI: danh sách chỉ hiển thị event (giờ, tên event, số param); bấm vào event để xem bảng key/value của tham số.
- Nút Copy nhỏ (trên từng dòng và trong panel chi tiết) copy tên event + toàn bộ tham số. Log gốc nằm trong mục "Raw log".
- Tự ẩn dòng log không phải event; gộp dòng trùng (Logging event / Event recorded).
- Search theo nhiều từ (AND) trên tên event, tên param, giá trị param; hiện số kết quả và nút xóa.
- Thanh cuộn mỏng (overlay).
- Nút chuyển giao diện Hệ thống / Sáng / Tối (ghi nhớ lựa chọn).
- Copy Visible / Export xuất dạng event + tham số.
- Fix: build lỗi do `@main` trong main.swift (đổi thành App.swift).
- Fix: dòng trạng thái hiển thị nguyên văn `\(streamingSerials.count)`.
- Thêm `Build and Install.command`; version đọc từ file VERSION.

## 0.1.0 — Source starter ban đầu
- Phát hiện thiết bị ADB, chọn game, cấu hình Firebase debug (có xác nhận), restart game (có xác nhận), stream logcat FA / FA-SVC, Clear View, Clear Device Log Buffer (có xác nhận), export.
