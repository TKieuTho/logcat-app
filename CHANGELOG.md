# Changelog

## 0.6.5 — 2026-10-30
- Fix: bấm vào chữ "Raw log" không mở được (trước đây phải bấm đúng mũi tên nhỏ); giờ bấm cả dòng.
- Fix: quay màn hình có thể ra file video rỗng (~1 KB) mà app vẫn báo "Quay xong"; giờ app kiểm tra, file rỗng thì xóa và báo "Quay không thành công".
- Hộp thoại "Khởi động lại game" và "Xóa bộ nhớ log trên máy" viết lại bằng tiếng Việt.
- Lịch thông báo: khoảng thời gian hiển thị gọn hơn ("Trong khoảng 1h", "1m 7s" thay cho "1h0m0s0ms").
- Đã kiểm trên máy thật: chụp/quay, mirror, lịch thông báo (khớp 100% với dumpsys alarm), tìm kiếm, copy, export, Clear View, bảng thuộc tính, các hộp xác nhận.

## 0.6.4 — 2026-10-30
- **Một nút Bắt đầu / Dừng** thay cho hai nút Configure & Capture và Stream All (hay bị nhầm). Bấm Bắt đầu: nếu máy chưa bật debug Firebase cho đúng game đang chọn thì hỏi một lần rồi bật; máy đã bật sẵn thì ghi log ngay. Dừng thì dừng ghi log.
- App tự chọn máy đầu tiên đang kết nối, nên chỉ có một máy thì không cần chọn tay.
- **Fix: tràn event cũ sau khi bấm Bắt đầu** trên máy có bộ nhớ log lớn (có máy chứa hơn 380.000 dòng): logcat dội lại lịch sử lâu hơn thời gian chờ, và hàng trăm event cũ hiện như event mới. Giờ app đọc từ dòng mới nhất, không dội lịch sử nữa (từ ~389.000 dòng xuống 2 dòng khi bắt đầu).
- Bảng "Thuộc tính hiện tại" vẫn được nạp lúc bấm Bắt đầu nhờ một tiến trình đọc lịch sử property riêng chạy ngầm (event vẫn chỉ hiện từ lúc bấm).
- Kiểm trên game thật (Snake Escape, vừa thao tác vừa đối chiếu log gốc): 54/54 dòng đủ, tham số đọc đúng 54/54, đúng thứ tự, độ trễ trung vị khoảng 100 ms, tối đa khoảng 420 ms.

## 0.6.3 — 2026-10-30
- **Bảng "Thuộc tính hiện tại"** ở tab User Props: danh sách đầy đủ user property mà SDK đang giữ (tên, giá trị, thời điểm đặt), đọc từ bản kê SDK in ra mỗi lần upload. Property mới hoặc vừa đổi có chấm xanh; thuộc tính nội bộ bị làm mờ. Bảng được ghim cố định ở trên, chỉ phần "Lịch sử đặt" bên dưới cuộn; có nút mở rộng và thu gọn (nhớ trạng thái).
- Bảng được nạp ngay lúc bấm bắt đầu từ bản kê gần nhất trong log máy; nếu máy không in bản kê thì tổng hợp từ các dòng "Setting user property" live. Event vẫn chỉ hiện từ lúc bấm.
- **Tự nối lại khi mất luồng log** (rút cáp, adb khởi động lại): app hiện thẻ "Mất kết nối", tự nối lại khi máy trở lại, và nhận máy mới cắm thêm khi đang ở chế độ Stream All. Trước đây app vẫn báo LIVE nhưng không còn ghi gì.
- **Log realtime ổn định hơn:** lọc và đọc dòng log ở luồng nền, giữ đúng thứ tự, bỏ nhanh phần lịch sử logcat dội về lúc bắt đầu. Đo trên máy thật: 600/600 event giả đủ và đúng thứ tự, độ trễ trung vị 5 ms, tối đa 113 ms, kể cả khi đang chụp và quay màn hình.
- Fix: không còn để lại tiến trình `adb logcat` / scrcpy mồ côi khi thoát app; dọn tiến trình mồ côi của lần chạy trước khi mở lại.

## 0.6.2 — 2026-10-30
- Fix: sót user property. Đọc được dòng có mã rút gọn trong tên (`non_personalized_ads(_npa)`, `user_id(_id)`, `ga_session_id(_sid)`…) và dạng `Setting user property(FE):`. Kiểm trên log thật (~510.000 dòng, 2 máy): thêm 568 property được ghi nhận, 0 dòng còn bị bỏ sót; số event không đổi (đủ).
- Hiển thị cảnh báo của SDK "Too many unique user properties are set" (quá 25 loại property): property bị Firebase bỏ qua hiện kèm chip đỏ "Bị SDK bỏ qua", mỗi property chỉ một lần.
- Cảnh báo "dòng log chưa đọc được" chỉ đếm dòng event/property thật, không đếm dòng nội bộ của SDK (ví dụ "Updated engagement user property").

## 0.6.1 — 2026-10-30
- **Thẻ trạng thái** ở phần đầu app: báo đang làm gì (đang chụp, đang quay kèm đồng hồ, đang cài scrcpy, đang tải bản cập nhật…) và đã xong gì (chụp/quay xong, file đã copy sẵn để dán ⌘V; bấm vào thẻ để mở file trong Finder), kèm thẻ lỗi khi thất bại. Tự biến mất sau vài giây.
- **Thanh công cụ một hàng:** cửa sổ rộng hiện đủ mọi chức năng trên một hàng (Configure & Capture, Stream giữ chữ, còn lại là icon); cửa sổ nhỏ dần thì tự chuyển sang hai hoặc ba hàng, không bị cắt.
- **Tooltip** cho mọi nút, ô chọn, ô search và từng mục menu: rê chuột vào là hiện chú thích ngắn.
- **Khung chi tiết event:** từ 640px trở lên luôn nằm bên phải, chia đôi với danh sách; có tab nhỏ ‹ / › ở mép để mở và thu gọn (Esc cũng thu được), cộng nút ở đầu danh sách. Cửa sổ nhỏ hơn 640px: bấm event thì chi tiết hiện thành một trang riêng với nút "‹ Danh sách" để quay lại, không còn đè nửa danh sách.
- Thanh cuộn mảnh hơn (tự vẽ, ~4px); đầu danh sách tự gọn khi hẹp; cột tên tham số rộng hơn để không bị ngắt dòng.

## 0.6.0 — 2026-10-29
- **Notification Schedule…** (menu ⋯): xem lịch thông báo local game đã hẹn trên máy (giờ nổ, đếm ngược, chính xác/trong khoảng, một lần/lặp), đọc từ AlarmManager qua `dumpsys alarm`. Chỉ xem được lịch, không xem được nội dung thông báo.
- **Mirror Screen**: chiếu màn hình điện thoại lên Mac bằng scrcpy. Máy chưa có scrcpy thì app đề nghị cài tự động qua Homebrew (có xác nhận), hoặc mở hướng dẫn nếu chưa có Homebrew.
- **Chụp / Quay màn hình**: lưu ảnh PNG và video MP4 (tối đa 3 phút mỗi lần, không có tiếng); đồng thời copy vào clipboard để dán (⌘V). Chọn thư mục lưu ở menu ⋯ (mặc định Downloads); nút "Hiện trong Finder" ở thanh dưới.
- Giao diện **tự co theo cỡ cửa sổ**: cửa sổ nhỏ lại thì nút thành icon, ô chọn xếp hai hàng, chi tiết event chuyển xuống dưới danh sách; cửa sổ thu nhỏ được tới ~520x460.
- Sửa căn lề: ô chọn Device/Game thẳng hàng với nhãn và ô search; nút ⋯ cùng độ cao với các nút.

## 0.5.3 — 2026-10-29
- Giao diện: dòng event được chọn có nền nhạt và thanh hồng ở mép trái (thay màu xanh dương mặc định, chữ không bị đổi màu). Lưu ý: không còn chọn bằng phím mũi tên.
- Nền phụ chế độ sáng chuyển sang trắng nhẹ (bớt ngả vàng); chế độ tối đổi từ nâu sang xanh đen trung tính.
- Bỏ dòng mô tả trong hộp xác nhận Configure.

## 0.5.2 — 2026-10-29
- Hiển thị log **từ lúc bấm nút bắt đầu** (Configure & Capture / Stream All Devices); log cũ trong bộ nhớ máy không hiện nữa. Cách làm: ghi một dòng mốc vào log thiết bị rồi bỏ qua mọi thứ trước mốc, không phụ thuộc đồng hồ máy.
- **Không tự force-stop / mở lại game nữa.** Configure & Capture chỉ bật thuộc tính debug rồi bắt đầu ghi. Cần khởi động lại game (debug mode chỉ nhận khi game khởi động) thì dùng menu ⋯ → Restart Game….

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
