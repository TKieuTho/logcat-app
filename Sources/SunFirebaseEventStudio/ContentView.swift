import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: StudioModel
    @State private var showDeviceBufferWarning = false
    @AppStorage("appearance") private var appearance = "light"
    private var scheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            // Split view down to 640px wide (always there, placeholder until an event is picked).
            // Below that the details are a drawer that slides over the list and stays closed until opened.
            GeometryReader { geo in
                let wide = geo.size.width >= 640
                let showPanel = wide ? model.detailVisible : model.drawerOpen
                let panelW = wide ? min(420, max(250, geo.size.width * 0.38)) : min(420, geo.size.width * 0.92)
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        eventList.frame(maxWidth: .infinity)
                        if wide && showPanel {
                            Divider()
                            detailPanel.frame(width: panelW)
                                .overlay(alignment: .leading) { edgeHandle(open: false).offset(x: -14) }
                                .transition(.move(edge: .trailing))
                        }
                    }
                    if !wide && showPanel {
                        // Narrow window: the details take the whole area (list hidden) with a back button.
                        detailPage
                            .frame(width: geo.size.width, height: geo.size.height)
                            .background(Theme.bg)
                            .transition(.move(edge: .trailing))
                    }
                    if !showPanel && (wide || model.selectedEvent != nil) { edgeHandle(open: true) }
                }
                .animation(.easeInOut(duration: 0.2), value: showPanel)
                .onAppear { model.splitLayout = wide }
                .onChange(of: wide) { model.splitLayout = $0 }
            }
            footer
        }
        .background(Theme.bg)
        .background(SlimScrollers())
        .preferredColorScheme(scheme)
        .alert("Bật debug Firebase trên máy này?", isPresented: $model.showSetupConfirmation) {
            Button("Hủy", role: .cancel) {}
            Button("Bật và bắt đầu") { model.confirmSetup() }
        } message: {
            Text("\(model.pendingSetup.flatMap { p in model.devices.first { $0.serial == p.serial } }?.displayName ?? "Thiết bị đã chọn") → \((model.pendingSetup?.game ?? model.selectedGame).title)\n\nApp đổi thuộc tính debug Firebase trên máy (setprop), không tự đóng hay mở lại game. Chưa thấy event thì dùng Restart Game….")
        }
        .alert("Khởi động lại game?", isPresented: $model.showLaunchConfirmation) {
            Button("Hủy", role: .cancel) {}
            Button("Khởi động lại") { model.confirmLaunch() }
        } message: {
            Text("App sẽ đóng hẳn rồi mở lại \(model.selectedGame.title) trên \(model.selectedDevice?.displayName ?? "máy đã chọn") và ghi log từ lúc đó. Cần khi game chưa nhận debug mode.")
        }
        .alert("Xóa bộ nhớ log trên máy?", isPresented: $showDeviceBufferWarning) {
            Button("Hủy", role: .cancel) {}
            Button("Xóa log trên máy", role: .destructive) { model.clearDeviceBufferAfterConfirmation() }
        } message: {
            Text("Khác với Clear View: lệnh này chạy logcat -c trên máy đang chọn và xóa toàn bộ log hiện có của máy.")
        }
        .alert("Có bản cập nhật Logcat", isPresented: $model.showUpdateAlert) {
            Button("Để sau", role: .cancel) {}
            Button("Cập nhật ngay") { model.installUpdate() }
        } message: {
            Text("Bản \(model.updateInfo?.version ?? "") (đang dùng \(Updater.currentVersion)).\n\(model.updateInfo?.notes ?? "")\n\nApp sẽ tự tải, thay bản mới và mở lại.")
        }
        .alert("Logcat", isPresented: Binding(get: { model.updateMessage != nil }, set: { if !$0 { model.updateMessage = nil } })) {
            Button("OK") { model.updateMessage = nil }
        } message: { Text(model.updateMessage ?? "") }
        .alert("Cần scrcpy để chiếu màn hình", isPresented: $model.showScrcpyMissing) {
            if model.canInstallScrcpyWithBrew {
                Button("Cài tự động (Homebrew)") { model.installScrcpyAndMirror() }
            } else {
                Button("Mở hướng dẫn cài đặt") { model.openScrcpyInstallGuide() }
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text(model.canInstallScrcpyWithBrew
                 ? "Máy chưa có scrcpy (công cụ mã nguồn mở dùng để chiếu màn hình Android). App sẽ chạy \"brew install scrcpy\", mất vài phút."
                 : "Máy chưa có scrcpy và cũng chưa có Homebrew. Cài Homebrew (brew.sh) rồi chạy: brew install scrcpy. Bấm nút bên dưới để mở hướng dẫn.")
        }
        .sheet(isPresented: $model.showNotificationSchedule) { NotificationScheduleView().environmentObject(model) }
        .onAppear { model.checkForUpdates(manual: false) }
        .alert("Logcat", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        // (the pill animates in and out with the activity)
        ViewThatFits(in: .horizontal) {
            headerContent(wide: true)
            headerContent(wide: false)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.activity)
    }

    private func headerContent(wide: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let img = Bundle.main.image(forResource: "cat") ?? NSImage(contentsOfFile: "Resources/cat.png") {
                    Image(nsImage: img).resizable().scaledToFit()
                } else { Image(systemName: "cat") }
            }.frame(width: wide ? 44 : 32, height: wide ? 40 : 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Logcat").font(wide ? .title2.bold() : .title3.bold()) + Text("  v\(Updater.currentVersion)").font(.caption).foregroundColor(.secondary)
                if wide { Text("Sun Studio · Firebase events (FA / FA-SVC)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let a = model.activity {
                ActivityPill(activity: a, compact: !wide) { model.clearActivity() }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            Spacer(minLength: 8)
            Picker("", selection: $appearance) {
                Image(systemName: "circle.lefthalf.filled").tag("system")
                Image(systemName: "sun.max").tag("light")
                Image(systemName: "moon").tag("dark")
            }.pickerStyle(.segmented).frame(width: 110).labelsHidden().help("Giao diện: theo hệ thống / sáng / tối")
            let dot = Circle().fill(model.isStreaming ? Theme.green : .gray).frame(width: 8, height: 8)
            if !wide && model.isStreaming {
                // Narrow window has no room for the list; the dot opens it so any live phone can still be stopped.
                Menu {
                    ForEach(model.liveStreams, id: \.serial) { live in
                        Button("Dừng: \(live.text)", systemImage: "stop.circle") { model.stopStream(for: live.serial) }
                    }
                } label: {
                    Label("Đang ghi log", systemImage: "circle.fill").labelStyle(.iconOnly)
                        .font(.system(size: 9)).foregroundStyle(Theme.green)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(Theme.green)
                .help("Đang ghi log:\n" + model.liveSummary.joined(separator: "\n") + "\n(bấm để dừng)")
            } else {
                dot.help(model.isStreaming ? "Đang ghi log:\n" + model.liveSummary.joined(separator: "\n") : "Chưa ghi log")
            }
            if wide {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.isStreaming ? "LIVE" : "NOT STREAMING").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(model.liveStreams, id: \.serial) { live in
                        HStack(spacing: 4) {
                            Text(live.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Button { model.stopStream(for: live.serial) } label: {
                                Image(systemName: "stop.circle.fill").font(.caption2).foregroundStyle(.red.opacity(0.8))
                            }.buttonStyle(.plain).help("Dừng ghi log của \(live.text)")
                        }
                    }
                }
            }
        }
        .padding(wide ? 16 : 8)
    }

    private var deviceReady: Bool { model.selectedSerial != nil && model.selectedDevice?.state == "device" }

    /// Picks the roomiest layout that fits the current window width.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            fullBar.padding(14)
            mediumBar.padding(10)
            narrowBar.padding(10)
            narrowestBar.padding(8)
        }
    }

    private func devicePicker(compact: Bool) -> some View {
        Picker("Device", selection: Binding(get: { model.selectedSerial ?? "" }, set: { model.selectDevice($0.isEmpty ? nil : $0) })) {
            Text("Select device…").tag("")
            ForEach(model.devices) { device in
                Text((compact ? device.model.replacingOccurrences(of: "_", with: " ") : device.displayName) + (device.state == "unauthorized" ? " · UNAUTHORIZED" : "")).tag(device.serial)
            }
        }.labelsHidden().fixedSize().frame(minWidth: compact ? 150 : 290, alignment: .leading)
        .help("Chọn thiết bị Android đang cắm USB (danh sách tự làm mới mỗi 3 giây)")
    }
    private func gamePicker(compact: Bool) -> some View {
        Picker("Game", selection: $model.selectedGame) {
            ForEach(GamePackage.allCases) { game in Text(game.title).tag(game) }
        }.labelsHidden().fixedSize().frame(minWidth: compact ? 140 : 190, alignment: .leading)
        .help("Chọn game: dùng khi bật debug Firebase và Restart Game")
    }

    private var streamLabelIcon: String { model.isStreamingSelected ? "stop.fill" : "play.fill" }
    private var canStream: Bool { model.isStreamingSelected || model.devices.contains(where: { $0.state == "device" }) }

    private var moreMenu: some View {
        Menu {
            Button(model.isInstallingScrcpy ? "Đang cài scrcpy…" : model.isMirroringSelected ? "Stop Mirroring" : "Mirror Screen", systemImage: "iphone.gen3") { model.toggleMirror() }
                .disabled(!deviceReady || model.isInstallingScrcpy)
            Button("Notification Schedule…", systemImage: "bell.badge") { model.openNotificationSchedule() }
                .disabled(!deviceReady)
            Button("Restart Game…", systemImage: "arrow.clockwise") { model.showLaunchConfirmation = true }
                .disabled(!deviceReady)
            Divider()
            Button("Thư mục lưu ảnh/video: \(model.captureDirectoryName)…", systemImage: "folder") { model.chooseCaptureDirectory() }
                .help("Chọn thư mục lưu ảnh chụp và video quay màn hình")
            if model.usesCustomCaptureDirectory {
                Button("Dùng lại thư mục Downloads", systemImage: "arrow.uturn.backward") { model.resetCaptureDirectory() }
            }
            Divider()
            Button("Clear View Only", systemImage: "eraser") { model.clearVisibleEvents() }
                .help("Chỉ xóa danh sách trong app, không xóa log trên máy")
            Button("Clear Device Log Buffer…", systemImage: "trash", role: .destructive) { showDeviceBufferWarning = true }
                .help("Xóa log trong bộ nhớ của điện thoại (adb logcat -c), có cảnh báo")
            Divider()
            Button("Copy Visible Logs", systemImage: "doc.on.doc") { model.copyVisibleEvents() }
                .help("Copy các event đang hiển thị")
            Button("Export Visible Logs…", systemImage: "square.and.arrow.up") { model.exportVisibleEvents() }
                .help("Xuất các event đang hiển thị ra file")
            Divider()
            Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { model.checkForUpdates(manual: true) }
                .help("Kiểm tra bản mới; có bản mới thì bấm Cập nhật ngay để app tự thay")
        } label: { Image(systemName: "ellipsis.circle").font(.title3) }
        .help("Thêm: thư mục lưu ảnh/video, xóa log trên máy, kiểm tra cập nhật…")
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 26)
    }

    private func searchBar(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(compact ? "Search" : "Search: event name, parameter or value (e.g. shop level 3)", text: $model.searchText)
                .textFieldStyle(.plain)
                .help("Tìm theo tên event, tên tham số hoặc giá trị. Nhập nhiều từ cách nhau bằng dấu cách: event phải chứa tất cả (ví dụ: shop level 3)")
            if !model.searchText.isEmpty {
                Text("\(model.visibleEvents.count) found").font(.caption).foregroundStyle(.secondary)
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Divider().frame(height: 18)
            Toggle("Auto-scroll", isOn: $model.autoScroll).toggleStyle(.checkbox).font(.caption).help("Tự cuộn xuống event mới nhất khi có log mới")
        }
        .padding(compact ? 6 : 9).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Wide window: one row; the two main actions keep their text, everything else is an icon with a tooltip.
    private var fullBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ANDROID DEVICE").font(.caption2.bold()).foregroundStyle(.secondary)
                    devicePicker(compact: false)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("GAME PACKAGE").font(.caption2.bold()).foregroundStyle(.secondary)
                    gamePicker(compact: false)
                }
                HStack(spacing: 8) {
                    Button { model.isStreaming ? model.stopSession() : model.startSession() } label: {
                        Label(model.isStreaming ? "Dừng" : "Bắt đầu", systemImage: model.isStreaming ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(model.isStreaming ? .red : Theme.accent)
                    .help(model.isStreaming ? "Dừng ghi log" : "Bật debug Firebase cho máy và game đang chọn (hỏi một lần nếu cần) rồi ghi log từ lúc bấm")
                    .disabled(!model.isStreaming && !deviceReady)
                    Divider().frame(height: 18)
                    toolIcons
                    Divider().frame(height: 18)
                    logIcons
                    moreMenu
                }
                .frame(height: 26)
                Spacer(minLength: 0)
            }
            searchBar(compact: false)
        }
    }

    private var primaryIcons: some View {
        iconButton(model.isStreamingSelected ? "stop.fill" : "play.fill",
                   help: model.isStreamingSelected ? "Dừng ghi log" : "Bắt đầu: bật debug Firebase cho máy và game đang chọn rồi ghi log từ lúc bấm",
                   tint: model.isStreamingSelected ? .red : Theme.accent, enabled: model.isStreamingSelected || deviceReady) {
            model.isStreamingSelected ? model.stopSession() : model.startSession()
        }
    }

    private var toolIcons: some View {
        HStack(spacing: 8) {
            iconButton("camera", help: "Chụp màn hình → \(model.captureDirectoryName) (và copy vào clipboard)", enabled: deviceReady) { model.takeScreenshot() }
            iconButton(model.isRecordingSelected ? "stop.circle.fill" : "record.circle",
                       help: model.isRecordingSelected ? "Dừng quay và lưu video" : "Quay màn hình (tối đa 3 phút, không tiếng) → \(model.captureDirectoryName)",
                       tint: model.isRecordingSelected ? .red : nil, enabled: deviceReady) { model.toggleRecording() }
            iconButton("iphone.gen3", help: model.isMirroringSelected ? "Stop Mirroring" : "Mirror Screen: chiếu màn hình điện thoại lên Mac (scrcpy)",
                       tint: model.isMirroringSelected ? Theme.green : nil, enabled: deviceReady && !model.isInstallingScrcpy) { model.toggleMirror() }
            iconButton("bell.badge", help: "Notification Schedule: lịch thông báo game đã hẹn trên máy", enabled: deviceReady) { model.openNotificationSchedule() }
            iconButton("arrow.clockwise", help: "Restart Game: force-stop và mở lại game để nhận debug mode (có xác nhận)", enabled: deviceReady) { model.showLaunchConfirmation = true }
        }
    }

    private var logIcons: some View {
        HStack(spacing: 8) {
            iconButton("eraser", help: "Clear View: xóa danh sách trong app (⇧⌘K), không xóa log trên máy", enabled: true) { model.clearVisibleEvents() }
            iconButton("doc.on.doc", help: "Copy Logs: copy các event đang hiển thị", enabled: true) { model.copyVisibleEvents() }
            iconButton("square.and.arrow.up", help: "Export: xuất các event đang hiển thị ra file", enabled: true) { model.exportVisibleEvents() }
        }
    }

    private var actionIcons: some View {
        HStack(spacing: 8) {
            primaryIcons
            Divider().frame(height: 18)
            toolIcons
            Divider().frame(height: 18)
            logIcons
        }
    }

    /// Medium width: everything on one row, buttons reduced to icons (tooltips carry the names).
    private var mediumBar: some View {
        HStack(spacing: 8) {
            devicePicker(compact: true)
            gamePicker(compact: true)
            Divider().frame(height: 18)
            actionIcons
            searchBar(compact: true)
            moreMenu
        }
    }

    /// Narrow width: pickers on top, icons and search below.
    private var narrowBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                devicePicker(compact: true)
                gamePicker(compact: true)
                Spacer(minLength: 0)
                moreMenu
            }
            HStack(spacing: 8) {
                actionIcons
                searchBar(compact: true)
            }
        }
    }

    /// Very narrow: pickers, icons and search each get their own row.
    private var narrowestBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                devicePicker(compact: true)
                gamePicker(compact: true)
                Spacer(minLength: 0)
                moreMenu
            }
            actionIcons
            searchBar(compact: true)
        }
    }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 26, height: 22) }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(tint)
            .help(help)
            .disabled(!enabled)
    }

    private func listHeader(compact: Bool) -> some View {
        HStack {
                if !compact { Text("EVENTS").font(.caption.bold()).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
                Spacer()
                Picker("", selection: $model.kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220).help("Lọc danh sách: tất cả, chỉ event, hoặc chỉ user property")
                Picker("", selection: $model.detailedList) {
                    Image(systemName: "list.bullet").tag(false)
                    Image(systemName: "rectangle.grid.1x2").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 70).help("Compact / Detailed view")
                Text(compact ? "\(model.visibleEvents.count)" : "\(model.visibleEvents.count) items").font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Button { withAnimation(.easeInOut(duration: 0.2)) { model.toggleDetail() } } label: {
                    Image(systemName: "sidebar.right").font(.system(size: 14))
                        .foregroundStyle(model.detailShown ? Theme.accent : .secondary)
                }
                .buttonStyle(.borderless)
                .help(model.detailShown ? "Thu gọn khung chi tiết" : "Mở khung chi tiết")
            }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                listHeader(compact: false)
                listHeader(compact: true)
            }
            Divider()
            if model.kindFilter == .properties { PropertySnapshotSection() }   // pinned: only the history below scrolls
            ScrollViewReader { proxy in
                // Custom rows instead of List selection: the system highlight is saturated blue and recolors the text.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleEvents) { event in
                            let selected = model.selectedEventID == event.id
                            VStack(spacing: 0) {
                                Group {
                                    if model.detailedList { card(event) } else { compactRow(event) }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected ? Color.primary.opacity(0.03) : Color.clear)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Theme.accent).frame(width: 3).opacity(selected ? 1 : 0)
                                }
                                Divider().opacity(0.5)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedEventID = event.id; model.openDetail() }
                            .id(event.id)
                        }
                    }
                }
                .onChange(of: model.visibleEvents.last?.id) { id in
                    if model.autoScroll, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func compactRow(_ event: LogEvent) -> some View {
        HStack(spacing: 10) {
            Text(event.clock).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if event.kind == .userProperty { Image(systemName: "person.text.rectangle").font(.caption).foregroundStyle(Theme.accent) }
            Text(event.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            if event.kind == .userProperty {
                Text(event.params.first?.value ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("\(event.params.filter { !$0.isInternal }.count) params").font(.caption).foregroundStyle(.tertiary)
            }
            Button { copy(event.copyText) } label: { Image(systemName: "doc.on.doc").font(.caption) }
                .buttonStyle(.borderless).help("Copy event + all parameters")
        }
    }

    /// Detailed view: each event is a card with its parameters shown inline as key/value chips.
    private func card(_ event: LogEvent) -> some View {
        let isProp = event.kind == .userProperty
        let shown = event.params.filter { !$0.isInternal }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isProp ? "person.text.rectangle" : "bolt.fill").font(.caption).foregroundStyle(isProp ? Theme.accent : Theme.green)
                Text(event.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                if isProp { Text("USER PROPERTY").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.2), in: Capsule()) }
                Spacer()
                Text(event.clock).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button { copy(event.copyText) } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless).help("Copy event + all parameters")
            }
            if !shown.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(shown, id: \.self) { p in
                        HStack(spacing: 4) {
                            Text(p.key).foregroundStyle(.secondary)
                            Text(p.value).fontWeight(.semibold).lineLimit(1)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(p.key == "status" ? Color.red.opacity(0.12) : Theme.panel, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Same little tab to open (‹, window edge) and close (›, panel edge) the details.
    private func edgeHandle(open: Bool) -> some View {
        let shape = open
            ? UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6)
            : UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6)
        return Button { withAnimation(.easeInOut(duration: 0.2)) { open ? model.openDetail() : model.closeDetail() } } label: {
            Image(systemName: open ? "chevron.left" : "chevron.right").font(.system(size: 9, weight: .semibold))
                .frame(width: 14, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.06), in: shape)
        .keyboardShortcut(open ? nil : .cancelAction)
        .help(open ? "Mở khung chi tiết" : "Thu gọn khung chi tiết (Esc)")
    }

    private var detailPage: some View {
        VStack(spacing: 0) {
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.2)) { model.closeDetail() } } label: {
                    Label("Danh sách", systemImage: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .keyboardShortcut(.cancelAction)
                .help("Quay lại danh sách event (Esc)")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            detailPanel
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let event = model.selectedEvent {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.name).font(.title3.bold()).textSelection(.enabled)
                    Spacer()
                    Button { copy(event.copyText) } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                        .buttonStyle(.bordered).controlSize(.small).help("Copy tên event và toàn bộ tham số")
                }
                Text("\(event.clock) · \(event.deviceSerial)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(event.params, id: \.self) { p in
                            HStack(alignment: .top, spacing: 10) {
                                Text(p.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                    .frame(width: 162, alignment: .leading)
                                Text(p.value).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .opacity(p.isInternal ? 0.5 : 1)
                            .padding(.vertical, 5)
                            Divider()
                        }
                        if event.params.isEmpty { Text("No parameters").foregroundStyle(.secondary).padding(.top, 8) }
                        RawLogView(text: event.raw).id(event.id).padding(.top, 12)
                    }
                }
            } else {
                Spacer()
                Image(systemName: "hand.tap").font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                Text("Click an item to see its parameters.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(14)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerContent(showHint: true)
            footerContent(showHint: false)
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.panel)
    }

    private func footerContent(showHint: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text(model.statusText).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let f = model.lastSavedFile {
                Button { NSWorkspace.shared.activateFileViewerSelecting([f]) } label: { Label("Hiện trong Finder", systemImage: "folder") }
                    .buttonStyle(.link).help(f.path)
            }
            if model.skippedLines > 0 {
                Label("\(model.skippedLines) dòng log chưa đọc được", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).help(model.lastSkippedLine)
            }
            if showHint { Text("Clear View never clears device logs").foregroundStyle(.secondary) }
        }
    }
}


struct NotificationScheduleView: View {
    @EnvironmentObject private var model: StudioModel
    @Environment(\.dismiss) private var dismiss

    private func countdown(_ d: Date) -> String {
        let delta = d.timeIntervalSince(model.alarmsDeviceNow)
        return delta >= 0 ? "sau \(ScheduledAlarm.duration(delta))" : "đã qua \(ScheduledAlarm.duration(delta))"
    }

    var body: some View {
        let notifs = model.alarms.filter(\.isNotification)
        let others = model.alarms.filter { !$0.isNotification }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bell.badge").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lịch thông báo").font(.title3.bold())
                    Text("\(model.selectedGame.title) · \(model.selectedSerial ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refreshAlarms() } label: { Label("Làm mới", systemImage: "arrow.clockwise") }
                    .disabled(model.alarmsLoading)
                Button { copyAll(notifs + others) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(model.alarms.isEmpty)
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 10) {
                if model.alarmsLoading { ProgressView().controlSize(.small) }
                if let e = model.alarmsError { Text(e).foregroundStyle(.red).font(.callout) }
                if !model.alarmsLoading, model.alarmsError == nil {
                    if model.alarms.isEmpty {
                        Text("Không có thông báo nào được hẹn trên máy cho game này. Mở game để game hẹn lịch, rồi bấm Làm mới.")
                            .foregroundStyle(.secondary).padding(.vertical, 20)
                    } else {
                        let next = notifs.first(where: { $0.fireDate > model.alarmsDeviceNow }) ?? notifs.first
                        Text("\(notifs.count) thông báo đã hẹn" + (next.map { " · tiếp theo \(model.alarmTime($0.fireDate)) (\(countdown($0.fireDate)))" } ?? ""))
                            .font(.callout.weight(.medium))
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(notifs) { row($0) }
                                if !others.isEmpty {
                                    Text("ALARM KHÁC CỦA APP (\(others.count))").font(.caption2.bold()).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14).padding(.bottom, 4)
                                    ForEach(others) { row($0) }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text("Chỉ đọc được lịch hẹn (giờ, kiểu, chu kỳ) từ AlarmManager của Android. Tiêu đề và nội dung thông báo được lưu trong app nên không xem được ở đây.")
                .font(.caption).foregroundStyle(.secondary)
            if let t = model.alarmsCheckedAt {
                Text("Kiểm tra lúc \(t.formatted(date: .omitted, time: .standard)) theo giờ trên máy tính.").font(.caption2).foregroundStyle(.tertiary)
                if abs(model.alarmsClockOffset) > 60 {
                    Text("⚠️ Đồng hồ điện thoại đang là \(model.alarmTime(model.alarmsDeviceNow)), lệch \(ScheduledAlarm.duration(model.alarmsClockOffset)) \(model.alarmsClockOffset > 0 ? "nhanh" : "chậm") so với máy tính. Giờ hẹn và \"sau …\" ở đây tính theo đồng hồ điện thoại.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 460, idealWidth: 640, maxWidth: 820, minHeight: 360, idealHeight: 460, maxHeight: 700, alignment: .topLeading)
        .background(Theme.bg)
    }

    private func row(_ a: ScheduledAlarm) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.alarmTime(a.fireDate)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(countdown(a.fireDate)).font(.caption).foregroundStyle(a.fireDate > model.alarmsDeviceNow ? Theme.green : .secondary)
            }.frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(a.modeText) · \(a.repeatText)").font(.system(size: 12))
                Text(a.type).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func copyAll(_ list: [ScheduledAlarm]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(list.map(\.copyText).joined(separator: "\n"), forType: .string)
    }
}

/// "Current user properties": the full list the SDK holds for the app, like Firebase's own view.
struct PropertySnapshotSection: View {
    @EnvironmentObject private var model: StudioModel
    @AppStorage("propsCollapsed") private var collapsed = false
    @AppStorage("propsExpanded") private var expanded = false
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd/MM HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let current = model.currentPropertySnapshot
            HStack(spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .bold))
                        Text("THUỘC TÍNH HIỆN TẠI").font(.caption.bold())
                        if let c = current {
                            Text("\(c.snapshot.props.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                            Text("· cập nhật \(c.snapshot.updatedAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Danh sách đầy đủ user property mà SDK đang giữ (đọc từ bản kê SDK in ra mỗi lần upload), giống phần User properties của Firebase")
                if !collapsed, (current?.snapshot.props.count ?? 0) > 6 {
                    barButton(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              help: expanded ? "Thu nhỏ bảng về cỡ mặc định" : "Mở rộng bảng để xem nhiều thuộc tính hơn") {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }
                }
                barButton(collapsed ? "chevron.down" : "chevron.up",
                          help: collapsed ? "Mở bảng thuộc tính" : "Thu gọn bảng thuộc tính (chỉ còn lịch sử)") {
                    withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            if !collapsed {
                if let c = current {
                    ScrollView { VStack(spacing: 0) { ForEach(c.snapshot.props) { p in row(p) } } }
                        .frame(height: min(CGFloat(c.snapshot.props.count) * 27, expanded ? 300 : 180))
                    Text(c.app).font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 6)
                } else {
                    Text("Chưa có dữ liệu thuộc tính. Game chỉ đặt property lúc khởi động hoặc khi giá trị đổi, nên hãy bấm bắt đầu rồi Restart Game… để game đặt lại toàn bộ.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
                }
            }
            Divider()
            HStack {
                Text("LỊCH SỬ ĐẶT (Setting user property)").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 9)
            Divider().opacity(0.5)
        }
        .background(Theme.panel.opacity(0.5))
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 20)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .help(help)
    }

    private func row(_ p: UserPropertyState) -> some View {
        let recent = p.changedAt.map { Date().timeIntervalSince($0) < 120 } ?? false
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(recent ? Theme.green : .clear).frame(width: 6, height: 6)
                    .help(recent ? "Mới xuất hiện hoặc vừa đổi giá trị" : "")
                Text(p.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .frame(width: 170, alignment: .leading).help(p.rawName)
                Text(p.value.isEmpty ? "—" : p.value).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.timeFormatter.string(from: p.setAt)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .help("Thời điểm game đặt giá trị này")
            }
            .opacity(p.isInternal ? 0.5 : 1)
            .padding(.horizontal, 14).padding(.vertical, 5)
            Divider().opacity(0.4)
        }
    }
}

/// "Raw log" toggle whose whole label is clickable (DisclosureGroup only reacts to its tiny arrow).
struct RawLogView: View {
    let text: String
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text("Raw log").font(.caption)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dòng log gốc của SDK")
            if open {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Cute status pill: what the app is doing right now, or what it just finished.
struct ActivityPill: View {
    let activity: Activity
    var compact: Bool
    var dismiss: () -> Void
    @State private var pulse = false

    private var tint: Color {
        switch activity.kind {
        case .working: return Theme.accent
        case .done: return Theme.green
        case .error: return .red
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 28, height: 28)
                if activity.kind == .working && activity.startedAt == nil {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Text(activity.emoji).font(.system(size: 15))
                        .scaleEffect(activity.kind == .working && pulse ? 1.15 : 1)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(activity.title).font(.system(size: 12, weight: .bold)).lineLimit(1)
                    if let start = activity.startedAt {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            let s = max(0, Int(ctx.date.timeIntervalSince(start)))
                            Text(String(format: "%d:%02d", s / 60, s % 60))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
                        }
                    }
                }
                if !compact, let d = activity.detail {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if activity.fileURL != nil {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(tint)
            }
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 6)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture {
            if let f = activity.fileURL { NSWorkspace.shared.activateFileViewerSelecting([f]) } else if activity.kind != .working { dismiss() }
        }
        .help(activity.fileURL != nil ? "Bấm để hiện file trong Finder" : (activity.detail ?? activity.title))
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true } }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: activity.id)
    }
}

/// Wraps children onto new lines when they run out of horizontal space.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 400, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews: subviews)
        for (i, f) in r.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var frames: [CGRect] = []
        for sv in subviews {
            var sz = sv.sizeThatFits(.unspecified)
            sz.width = min(sz.width, width)
            if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), frames)
    }
}

/// Makes every scroll view in the window use thin overlay scrollbars.
struct SlimScrollers: NSViewRepresentable {
    final class Coordinator {
        var timer: Timer?
        deinit { timer?.invalidate() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // Scroll views are created later too (e.g. when the details page opens), so keep checking.
        context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak v] _ in
            Self.apply(v?.window?.contentView)
        }
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(view.window?.contentView) }
    }
    private static func apply(_ root: NSView?) {
        guard let root else { return }
        if let sv = root as? NSScrollView {
            sv.scrollerStyle = .overlay
            if !(sv.verticalScroller is ThinScroller) { sv.verticalScroller = ThinScroller() }
            if !(sv.horizontalScroller is ThinScroller) { sv.horizontalScroller = ThinScroller() }
        }
        root.subviews.forEach(apply)
    }
}

/// Overlay scroller drawn as a thin rounded line instead of AppKit's fat knob.
final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let r = rect(for: .knob)
        let thickness: CGFloat = 4
        let knob: NSRect = bounds.height > bounds.width
            ? NSRect(x: r.maxX - thickness - 3, y: r.minY + 2, width: thickness, height: max(8, r.height - 4))
            : NSRect(x: r.minX + 2, y: r.maxY - thickness - 3, width: max(8, r.width - 4), height: thickness)
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: knob, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}


/// Palette taken from the cat mascot: cream, dark brown, dusty pink, leaf green.
enum Theme {
    static let accent = Color(red: 0.68, green: 0.48, blue: 0.48)       // #AD7B7B
    static let green = Color(red: 0.58, green: 0.69, blue: 0.35)        // #94B058
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let bg = dyn(NSColor.white, NSColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1))
    static let panel = dyn(NSColor(red: 0.975, green: 0.975, blue: 0.975, alpha: 1), NSColor(red: 0.15, green: 0.16, blue: 0.19, alpha: 1))
}
