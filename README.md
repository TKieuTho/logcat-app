# Logcat — Sun Firebase Event Studio (macOS)

App macOS (SwiftUI, macOS 13+, Apple Silicon) giúp QA xem **event** và **user property** Firebase Analytics từ thiết bị Android qua ADB, kèm giờ gửi chính xác đến mili giây.

## Tính năng
- Tự nhận thiết bị Android đã bật USB debugging (làm mới mỗi 3 giây); chọn được nhiều thiết bị độc lập.
- Nếu máy chưa có `adb`, app tự tải Android Platform Tools của Google ở lần mở đầu (cần internet).
- Chỉ hiển thị log **từ lúc bấm nút bắt đầu** (Configure & Capture hoặc Stream All Devices). Log cũ trong bộ nhớ máy không hiện.
- Đọc log tag `FA` và `FA-SVC`, nhiều thiết bị cùng lúc, mỗi luồng gắn với serial ADB của nó. Ghi nhận cả event và **user property** (`Setting user property: name, value`).
- Hai chế độ xem (nút ở đầu danh sách, ghi nhớ lựa chọn): **Detailed** (mỗi event là một thẻ, tham số hiện ngay dạng chip key/value) và **Compact** (mỗi event một dòng). Tab lọc **All / Events / User Props**.
- Mỗi event có giờ gửi `HH:mm:ss.SSS` (lấy từ logcat). Bấm vào event để xem bảng tham số và log gốc ("Raw log").
- Search nhiều từ (AND) trên tên event, tên param, giá trị param. Copy từng event, copy / export các event đang hiển thị.
- Giao diện Hệ thống / Sáng / Tối.
- **Cập nhật ngay trong app:** menu ⋯ → Check for Updates…, có bản mới thì bấm "Cập nhật ngay", app tự tải, thay bản mới và mở lại.

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
- Danh sách chọn bằng chuột, chưa hỗ trợ phím mũi tên. Chưa có chế độ nhiều khung song song cho từng thiết bị.
- App chưa ký/notarize (xem phần Gatekeeper ở trên). Bản build chỉ chạy trên Apple Silicon; Mac Intel tự build từ source.
- Mới thử trên một số thiết bị Android; nên kiểm tra thực tế trước khi dùng cho báo cáo chính thức.

## Source của từng bản build
Mỗi bản phát hành có tag trùng số version. Source của bản `X.Y.Z` nằm ở `https://github.com/TKieuTho/logcat-app/tree/vX.Y.Z` (ví dụ [v0.5.3](https://github.com/TKieuTho/logcat-app/tree/v0.5.3)); file zip nằm ở [Releases](https://github.com/TKieuTho/logcat-app/releases). Số version của bản đang chạy hiển thị cạnh tên app.

Lịch sử thay đổi: xem [CHANGELOG.md](CHANGELOG.md).
