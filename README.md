# Logcat — Sun Firebase Event Studio (macOS)

App macOS (SwiftUI, macOS 13+, Apple Silicon) giúp QA xem **event** và **user property** Firebase Analytics từ thiết bị Android qua ADB, kèm giờ gửi chính xác đến mili giây.

## Bảng tính năng

| Nhóm | Tính năng | Mô tả | Truy cập |
| --- | --- | --- | --- |
| Log | Nhận thiết bị | Tự phát hiện máy Android (làm mới 3 giây), chọn nhiều máy độc lập; tự tải `adb` nếu máy chưa có | Ô Device |
| Log | Stream log Firebase | Đọc tag `FA`, `FA-SVC` từ nhiều máy cùng lúc; chỉ hiện log từ lúc bấm bắt đầu | Configure & Capture, Stream All Devices |
| Log | Event và User Property | Ghi nhận cả event và `Setting user property`; lọc All / Events / User Props | Tab ở đầu danh sách |
| Log | Giờ gửi | Hiển thị `HH:mm:ss.SSS` lấy từ logcat; giữ event gửi lặp, chỉ gộp bản sao giữa các kiểu log | Mỗi dòng/thẻ event |
| Log | Hai chế độ xem | Detailed (thẻ, tham số dạng chip) và Compact (một dòng) | Nút cạnh tab lọc |
| Log | Chi tiết event | Bảng key/value của tham số, log gốc (Raw log) | Bấm vào event |
| Log | Search | Nhiều từ (AND) trên tên event, tên và giá trị param | Ô Search |
| Log | Copy / Export | Copy từng event; copy hoặc export các event đang hiển thị | Nút Copy, menu ⋯ |
| Log | Cảnh báo | Báo khi có dòng log event/property chưa đọc được | Thanh dưới cùng |
| Log | Clear View / Clear Device Buffer | Xóa danh sách trong app (⇧⌘K) / xóa log trên máy (`adb logcat -c`, có xác nhận) | Menu ⋯ |
| Thiết bị | Configure & Capture | Bật thuộc tính debug Firebase (`setprop`) rồi bắt đầu ghi; không tự restart game | Nút Configure & Capture |
| Thiết bị | Restart Game | Force-stop và mở lại game để nhận debug mode (có xác nhận) | Menu ⋯ |
| Thiết bị | Notification Schedule | Lịch thông báo local game đã hẹn: giờ nổ, đếm ngược, kiểu hẹn, chu kỳ lặp (không có nội dung) | Menu ⋯ |
| Thiết bị | Mirror Screen | Chiếu màn hình điện thoại lên Mac bằng scrcpy; tự cài qua Homebrew nếu chưa có | Menu ⋯ |
| Thiết bị | Chụp / Quay màn hình | Lưu PNG / MP4 (tối đa 3 phút, không có tiếng), copy vào clipboard; chọn thư mục lưu | Nút Chụp, Quay; menu ⋯ |
| App | Giao diện | Hệ thống / Sáng / Tối; tự co theo cỡ cửa sổ | Góc phải trên |
| App | Tự cập nhật | Kiểm tra bản mới khi mở app; bấm "Cập nhật ngay" để tự tải, thay bản và mở lại | Menu ⋯ → Check for Updates… |

## Dùng
1. Chọn **Device** và **Game**.
2. **Configure & Capture** (lần đầu với mỗi máy/game): xác nhận để bật thuộc tính debug Firebase (`setprop`), app bắt đầu ghi log ngay. App **không** tự đóng hay mở lại game.
3. Debug mode chỉ có hiệu lực khi game khởi động. Nếu game đang chạy mà event chưa hiện, dùng menu ⋯ → **Restart Game…** (có xác nhận).
4. Máy đã setup rồi hoặc muốn theo dõi nhiều máy: **Stream All Devices**.
5. **Clear View Only** (⇧⌘K) chỉ xóa danh sách trong app. **Clear Device Log Buffer…** (có cảnh báo) mới chạy `adb logcat -c` trên máy.

Firebase DebugView vẫn là nguồn đối chiếu chính; Logcat chỉ là bằng chứng phụ. App không tạo event giả.

## Cài bản tải về (.zip) và xử lý khi macOS chặn
App chưa được Apple ký/notarize, nên lần đầu mở macOS có thể báo **"Logcat can't be opened"** hoặc **"Logcat is damaged"**. Đây là Gatekeeper, không phải lỗi app.

1. Giải nén zip, kéo **Logcat.app** vào **Applications** (khi cập nhật chọn Replace).
2. Mở Terminal, chạy lệnh sau để bỏ cờ quarantine rồi mở lại app:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Logcat.app
   ```
   Nếu để app ở `~/Applications` thì đổi đường dẫn tương ứng.
3. Hoặc không dùng Terminal: bấm chuột phải vào Logcat.app → **Open** → **Open**; hoặc vào **System Settings → Privacy & Security**, kéo xuống bấm **Open Anyway**.

Chỉ cần làm một lần cho mỗi bản tải mới. Build bằng `Build and Install.command` thì không bị chặn vì script đã tự gỡ quarantine.

## Tự build từ source
1. Cài Xcode Command Line Tools (`xcode-select --install`).
2. Double-click `Build and Install.command`. App được build, ký ad-hoc và cài vào `~/Applications`.

## Giới hạn
- Chỉ đọc tag `FA` và `FA-SVC`. Event ở tag khác sẽ không hiện.
- Giờ hiển thị là giờ SDK ghi log trên máy, không phải giờ server nhận.
- Nếu có dòng log event/property mà app chưa đọc được, thanh dưới cùng hiện cảnh báo màu cam (rê chuột để xem dòng đó).
- Chỉ giữ 50.000 dòng gần nhất trong bộ nhớ.
- Quay màn hình dùng `adb screenrecord` nên không có tiếng; một số app (thanh toán, ngân hàng) chặn chụp/quay.
- Mirror Screen cần scrcpy (không đóng gói kèm app).
- Danh sách chọn bằng chuột, chưa hỗ trợ phím mũi tên. Chưa có chế độ nhiều khung song song cho từng thiết bị.
- App chưa ký/notarize (xem phần Gatekeeper ở trên). Bản build chỉ chạy trên Apple Silicon; Mac Intel tự build từ source.
- Mới thử trên một số thiết bị Android; nên kiểm tra thực tế trước khi dùng cho báo cáo chính thức.

## Source của từng bản build
Mỗi bản phát hành có tag trùng số version. Source của bản `X.Y.Z` nằm ở `https://github.com/TKieuTho/logcat-app/tree/vX.Y.Z` (ví dụ [v0.5.3](https://github.com/TKieuTho/logcat-app/tree/v0.5.3)); file zip nằm ở [Releases](https://github.com/TKieuTho/logcat-app/releases). Số version của bản đang chạy hiển thị cạnh tên app.

Lịch sử thay đổi: xem [CHANGELOG.md](CHANGELOG.md).
