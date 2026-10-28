# Changelog

## 0.5.1 — 2026-10-28
- Cập nhật ngay trong app: khi có bản mới, bấm "Cập nhật ngay" để app tự tải, thay bản mới và mở lại (không cần kéo thả thủ công). Nếu không ghi được vào thư mục cài app thì mở trang tải về.
- Log đủ event, kèm giờ gửi (HH:mm:ss.SSS lấy từ logcat):
  - Fix: dòng log bị cắt đôi giữa hai lần đọc làm mất event.
  - Fix: chỉ gộp bản sao cùng event giữa các kiểu log (Logging event / Event recorded); event gửi lặp liên tiếp giống hệt nhau giờ được giữ lại, không bị nuốt.
  - Fix: param của dòng "Event recorded" bị dính `}]`.
  - Cảnh báo ở thanh dưới khi có dòng log event/property mà app chưa đọc được (rê chuột để xem dòng đó).
  - Tăng giới hạn lưu từ 12.000 lên 50.000 dòng.

## 0.5.0 — 2026-10-28
- Ghi nhận cả **User Properties** (`Setting user property: name, value`), hiển thị cùng danh sách, có tab lọc All / Events / User Props.
- Thêm chế độ xem **Detailed** (mặc định): mỗi event là một thẻ, tham số hiện ngay dạng chip key/value; chuyển qua lại với chế độ Compact bằng nút ở đầu danh sách (ghi nhớ lựa chọn).

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
