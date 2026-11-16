# Changelog

## 0.6.9 — 2026-11-16
- Lịch thông báo: cửa sổ tự làm mới mỗi 5 giây khi đang mở (có công tắc "Tự làm mới"), làm mới ngầm không hiện spinner và không nháy danh sách; đóng cửa sổ thì dừng. Đã kiểm trên SM-A055F: noti mới hiện sau ~5 giây không cần bấm.
- Thông báo: "đã xoá" chỉ ghi khi noti vắng mặt 2 lần quét liên tiếp (~10 giây), một lần đọc dump lỗi/rỗng không còn đánh dấu xoá cả loạt; noti hiện lại thì bỏ dấu. Loại noti của game đọc thêm từ `groupKey=` ở dòng đầu bản ghi (máy không có `|g:`). Dòng trong file `Notifications/` ghi theo thứ tự cũ → mới. Đã kiểm trên SM-A055F: đăng, ghi nhận, ẩn (snooze), đánh dấu xoá, hiện lại, đủ dòng trong file.
- Sửa: tab **Đang hiển thị / Đã ghi** trống trên máy có dump `mCreationTimeMs=...(ngày giờ)` (Samsung/Android 15): parser đọc nhầm cả phần ngày trong ngoặc thành số rồi bỏ mọi thông báo. Đã kiểm trên SM-A055F và SM-G610F (38 thông báo đọc được).
- Sửa: **Bộ nhớ game** hiện PSS = 0 trên Android cũ (máy không in dòng `TOTAL PSS:`); giờ đọc từ `TOTAL:` / bảng `TOTAL` và chịu được số có dấu phẩy. Đã kiểm trên Samsung SM-G610F.
- Chụp màn hình nhanh hơn: lấy ảnh raw từ máy rồi mã hoá PNG trên Mac (máy khỏi nén PNG), và kiểm tra màn hình sáng chạy song song với lúc chụp. Đo trên 2 máy thật: ~1,1–1,2 giây khi máy đang sáng; máy đang ngủ vẫn phải chờ bật sáng (~5–6 giây). Header lạ (HDR) tự quay về `screencap -p`.
- Quét crash cũ khi bấm Start gom theo lô (loại trùng một lần, sắp xếp một lần) thay vì quét cả danh sách 50.000 event cho từng crash, hết giật khi máy có log lớn. Event Firebase không bị ảnh hưởng.
- Thêm bộ test tự động (parse event, ghép dòng log, parser crash, đổi ảnh raw); chạy bằng `swift test` (với Command Line Tools cần thêm cờ swift-testing, xem README).
- Mới: ghi **crash / exception / fatal**. Luồng logcat riêng (`main,system,crash`) bắt Fatal, Native, ANR, Unity/IL2CPP, Died, OOM, Other; gom stacktrace nhiều dòng thành một mục (bỏ dòng lặp giữa buffer main và crash). Tab **Crashes** có chip lọc từng loại kèm số đếm; mặc định chỉ hiện crash của game đang ghi log, tick "All apps" để xem mọi app.
- Mỗi crash tự lưu một file `.txt` (loại, máy, package, PID, giờ, stacktrace) vào `<thư mục ảnh/video>/Crashes/<game>/`; có nút mở file ngay trên dòng crash. Menu ⋯: bật/tắt ghi crash, bật/tắt tự lưu, mở thư mục Crashes. Crash của game hiện thẻ cảnh báo đỏ ở header.
- Thanh chi tiết bên phải mặc định thu gọn, tự mở khi bấm vào một dòng (trước đây luôn chiếm chỗ với dòng "Click an item…").
- Hiệu năng: sửa giật khi chuyển sang app khác rồi quay lại. Dưới tải log dày CPU giảm từ ~83% xuống ~20% (số đo chi tiết trong README, mục Hiệu năng). Gồm: không vẽ lại cả cửa sổ mỗi 3 giây khi danh sách thiết bị không đổi; cache kết quả lọc 50.000 event; mỗi dòng là view Equatable; tính chuỗi giờ một lần; cập nhật danh sách chậm lại (1 giây) khi app ở nền; quét thanh cuộn thưa hơn.
- Đã kiểm trên Moto G06 Power: `am crash` cho ra đúng Fatal (13 dòng stacktrace) và Died, file lưu đúng chỗ; app mở 40 event giả lập đủ 40/40 dòng sau khi đổi cách vẽ danh sách. ANR, Native và Unity chỉ mới kiểm bằng log mẫu, chưa có crash thật.
- Lịch thông báo: thêm tab **Đang hiển thị** — các noti đang hiện trên máy kèm giờ bắn (giờ hệ thống ghi lúc đăng, theo đồng hồ và múi giờ điện thoại), "x trước", giờ cập nhật nếu app đăng lại, và **loại noti của game** (`campaignId` như `COMEBACK_2H`, `MORNING_ROUTINE`, `DAILY_EVENING`) cùng giờ hẹn nếu lệch giờ bắn. Mặc định chỉ game đang chọn, bỏ tick "Chỉ game này" để xem mọi app; có Copy. Chỉ thấy noti còn trong khay, noti đã vuốt bỏ thì không có.
- Crash: khi bấm Start, app đọc lại **crash cũ còn trên máy** (buffer crash của logcat + DropBox: Fatal, ANR, Native của game, có PID và giờ chính xác) rồi đưa vào tab Crashes, nên game crash trước rồi mới cắm USB vẫn xem được. Cùng một crash từ nhiều nguồn chỉ hiện một mục; file đã lưu từ lần trước được dùng lại. Menu ⋯ có "Quét crash cũ trên máy" để quét tay.
- Crash: file `.txt` tự lưu thêm phần **CONTEXT**: máy (hãng, model, Android), phiên bản app, RAM trống của máy, 250 dòng log cuối của process (crash đang xảy ra) và 12 event Firebase gần nhất trước crash.
- Lịch thông báo: thêm tab **Đã ghi** — khi đang Start, app quét danh sách noti trên máy mỗi 5 giây và nhớ từng noti mới, nên noti bị vuốt bỏ vẫn còn trong app (đánh dấu "đã xoá ~giờ"); đồng thời ghi vào `<thư mục lưu>/Notifications/<máy>_<ngày>.txt`. Máy không giữ lại noti đã xoá nên không lấy lại được noti trước lúc Start.
- Mới: **Bộ nhớ game (meminfo)** trong menu ⋯: `dumpsys meminfo` của game gồm TOTAL PSS / RSS / Swap, phân bổ Java Heap / Native Heap / Code / Graphics…, số Activity / View / Binder, RAM trống của máy, tự làm mới 3 giây với đường xu hướng (tăng đều là dấu hiệu leak) và dữ liệu gốc để copy.
- Mới: **Hiệu năng game** trong menu ⋯. Lấy mẫu mỗi ~2 giây khi cửa sổ mở: FPS và tỉ lệ frame giật (đo từ SurfaceFlinger nên đúng với game Unity; `gfxinfo` không dùng được cho Unity), CPU của game, RAM (RSS) và số luồng, nhiệt độ CPU và mức throttle, pin. Bốn biểu đồ cùng trục thời gian, **vạch đỏ đánh dấu crash và vạch xanh mờ đánh dấu event Firebase**, rê chuột để xem số tại thời điểm đó. Tạm dừng, xoá, xuất CSV. Chỉ lấy mẫu khi cửa sổ đang mở. Đã kiểm trên Moto G06 Power (Android 15) với Snake Escape: đọc ra 60 FPS, CPU, RSS, nhiệt độ; chưa kiểm trên máy khác.
- Giao diện: thanh công cụ chia nhóm có nhãn (GHI LOG · THEO DÕI GAME · MÁY · LOG). **Hiệu năng, Bộ nhớ, Thông báo** thành ba nút ngay trên thanh (cửa sổ hẹp chỉ còn icon). Cài đặt ghi crash, "Quét crash cũ" và mở thư mục Crashes chuyển sang thanh Crashes (hiện khi lọc Crashes). Menu ⋯ chỉ còn thư mục lưu, mở thư mục Crashes/Notifications, xoá log trên máy, kiểm tra cập nhật; bỏ các mục trùng với nút trên thanh.
- Đo ảnh hưởng lên game (Moto G06 Power, Snake Escape 60 FPS): lấy mẫu Hiệu năng và quét noti mỗi 5 giây không làm rớt frame; riêng đọc meminfo làm rớt khoảng 2 frame mỗi lần (khung 50 ms). Vì vậy meminfo tự làm mới mặc định **tắt** và đổi từ 3 giây sang 10 giây.
- Fix: luồng logcat crash bị bỏ mồ côi khi app bị kill (không tắt bằng Quit) — trước đây chỉ luồng Firebase được dọn khi mở lại. Thấy 6 tiến trình `adb logcat` mồ côi tích lại trên Mac và kéo theo logcat chạy mãi trên điện thoại. Nay mở app sẽ dọn cả luồng crash.
- Dọn tiến trình: app giờ bắt cả `kill`/`pkill`/Ctrl-C (SIGTERM, SIGHUP, SIGINT) để tắt hết adb con trước khi thoát; mỗi lần mở app và có máy cắm thì tự dọn `adb logcat` mồ côi trên Mac (mọi máy) và logcat còn chạy trên điện thoại không được app đọc. Menu ⋯ có **Dọn tiến trình cũ** (chạy tay, báo số đã dọn) và **Xoá toàn bộ dữ liệu phiên…** (event, crash, noti đã ghi, mẫu hiệu năng/bộ nhớ; không đụng log trên máy và file đã lưu).
- Giờ ghi log rõ ràng hơn: thanh **bắt đầu ghi** trên danh sách cho từng máy (máy · game · "bắt đầu ghi HH:mm:ss" · đã ghi bao lâu, nhảy theo giây), giờ lấy từ chính dòng marker app ghi vào log máy nên **cùng đồng hồ với giờ từng event**. Mất kết nối rồi tự nối lại thì có dòng cam ghi mất bao lâu và nối lại lúc nào (log trong lúc mất không có). Event/crash xảy ra **trước** giờ bắt đầu (đọc lại từ log cũ, DropBox) hiện thêm ngày và nhãn cam "trước Start".
- Giao diện (kiểm trên cửa sổ thật): thanh công cụ có kiểu **hai hàng** ở độ rộng vừa để ba nút Hiệu năng / Bộ nhớ / Thông báo vẫn có chữ (trước đó ở ~1170 px chúng thành ba icon giống nhau); danh sách rỗng có hướng dẫn (chưa ghi → "Cắm máy, chọn game, bấm Bắt đầu", đang chờ event, không có kết quả tìm kiếm, bộ lọc rỗng); cửa sổ phụ hiện **tên máy** thay vì số serial; Hiệu năng xếp 2×2 để thấy cả 4 biểu đồ không cần cuộn, có gợi ý khi chưa đo được FPS (game không ở foreground), trục thời gian bớt nhãn bị cắt.
- Fix: lỗi báo crash giả. Trên Android 15 mỗi tiến trình `adb shell` in một dòng `AconfigStorageReadException` (tag `FeatureFlagsImplExport`) và bị tính là crash "Other" của game (thấy 6 cái trong chưa đầy 1 phút, kèm thẻ đỏ 💥). Nay bỏ tag này, và crash loại Other chỉ vào danh sách, không bật thẻ cảnh báo đỏ.
- Fix: bớt báo crash nhiễu (thấy khi quét lại crash cũ của Blossom Master: 13 mục, 10 là "Died"). Không còn tính là crash: process bị dọn bình thường (`remove task` = vuốt khỏi recents, `empty #n` / `cached #n`, `has died: cch…` = process nền đã nghỉ). Crash loại "Other" chỉ tính khi chính process của game ném ra, không phải dòng log nào chỉ nhắc tên game (Play Store, PackageManager…).
- Fix: máy đang ghi log chớp tắt khỏi danh sách (rút/cắm USB, `adb reconnect`) làm ô chọn máy tự nhảy sang máy khác, danh sách event trống và nút Bắt đầu đổi trạng thái dù phiên ghi vẫn nối lại bình thường. Nay máy đang ghi giữ nguyên vị trí được chọn. File crash không còn dính dòng lỗi "Failed to write while dumping service" ở mục phiên bản app.
- Khi bấm Bắt đầu, thanh phiên hiện "Đang đọc crash cũ trên máy…" trong lúc đọc lại log (có thể mất 30-40 giây trên máy log lớn), trước đó danh sách trống không giải thích. Event vào trước khi biết giờ bắt đầu thật cũng được gắn nhãn "trước Start" sau đó.

## 0.6.7 — 2026-10-30
- Header: mỗi máy đang ghi log có nút dừng riêng, dừng được bất kể đang chọn máy nào trong dropdown (cửa sổ hẹp: bấm chấm xanh để chọn máy cần dừng).
- Lịch thông báo: đếm ngược và giờ báo tính theo đồng hồ và múi giờ của điện thoại (trước đây dùng đồng hồ Mac nên lệch khi máy sai giờ); cảnh báo cam khi máy lệch quá 1 phút so với Mac.

## 0.6.6 — 2026-10-30
- Fix: nút Bắt đầu / Dừng giờ theo **máy đang chọn**. Trước đây khi máy A đang ghi log, chọn máy B vẫn thấy "Dừng" nên không Start được B và event của B không vào app.
- Header ghi rõ máy nào đang ghi log game nào ("LIVE · SM A055F · Snake Escape", mỗi máy một dòng); thông báo và thanh trạng thái cũng nêu tên máy và game.
- Fix: hộp thoại "Bật debug Firebase" luôn thực hiện cho đúng máy và game đã hỏi, kể cả khi đổi dropdown ngay sau khi bấm Bắt đầu (trước đây có thể bật nhầm sang máy khác).
- Chụp / quay màn hình: nếu máy đang tắt màn hình, app tự bật sáng và đợi sáng hẳn rồi mới chụp/quay (trước đây ảnh ra đen mà vẫn báo "Chụp xong", quay thì báo lỗi).
- Quay màn hình: bấm Dừng ngay sau khi Quay không còn bị treo ở "Đang lưu video…" (app gửi lại lệnh dừng, cuối cùng ngắt hẳn nếu cần); thoát app khi đang quay thì dừng và chốt file video; video chạm giới hạn 3 phút có ghi chú "Đã tự dừng ở giới hạn 3 phút".
- Log: dòng chứa byte UTF-8 lỗi không còn bị bỏ mất; bấm Dừng xong không còn event rơi thêm vào danh sách; danh sách đầy 50.000 event không còn giật.
- Đã kiểm trên 2 máy thật (Samsung A05, Moto G06 Power): số event trong app khớp log thô (A05 11/11; Moto 81 item so với 82 dòng log, chênh 1 do bộ lọc trùng), quay/chụp khi máy tắt màn hình, 2 máy cùng ghi log.

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
