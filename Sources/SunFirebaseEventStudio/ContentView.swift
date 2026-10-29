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
            // Wide window: list and details side by side. Narrow: details drop below the list.
            GeometryReader { geo in
                if geo.size.width >= 940 {
                    HStack(spacing: 0) {
                        eventList.frame(minWidth: 480, maxWidth: .infinity)
                        Divider()
                        detailPanel.frame(width: min(420, max(340, geo.size.width * 0.36)))
                    }
                } else {
                    VStack(spacing: 0) {
                        eventList.frame(maxHeight: .infinity)
                        Divider()
                        detailPanel.frame(height: min(280, max(180, geo.size.height * 0.4)))
                    }
                }
            }
            footer
        }
        .background(Theme.bg)
        .background(SlimScrollers())
        .preferredColorScheme(scheme)
        .alert("Configure Firebase Analytics logging?", isPresented: $model.showSetupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Configure Device") { model.confirmSetup() }
        }
        .alert("Restart game to begin capture?", isPresented: $model.showLaunchConfirmation) {
            Button("Hủy", role: .cancel) {}
            Button("Restart & Stream") { model.confirmLaunch() }
        } message: {
            Text("The app will force-stop and relaunch \(model.selectedGame.title) on \(model.selectedSerial ?? "the selected device") and start its FA / FA-SVC log stream.")
        }
        .alert("Clear Android device log buffer?", isPresented: $showDeviceBufferWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Device Buffer", role: .destructive) { model.clearDeviceBufferAfterConfirmation() }
        } message: {
            Text("This is different from Clear View. It runs logcat -c on the selected device and deletes the current device log buffer.")
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
        ViewThatFits(in: .horizontal) {
            headerContent(wide: true)
            headerContent(wide: false)
        }
    }

    private func headerContent(wide: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let img = Bundle.main.image(forResource: "cat") ?? NSImage(contentsOfFile: "Resources/cat.png") {
                    Image(nsImage: img).resizable().scaledToFit()
                } else { Image(systemName: "cat") }
            }.frame(width: 44, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Logcat").font(.title2.bold()) + Text("  v\(Updater.currentVersion)").font(.caption).foregroundColor(.secondary)
                if wide { Text("Sun Studio · Firebase events (FA / FA-SVC)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Picker("", selection: $appearance) {
                Image(systemName: "circle.lefthalf.filled").tag("system")
                Image(systemName: "sun.max").tag("light")
                Image(systemName: "moon").tag("dark")
            }.pickerStyle(.segmented).frame(width: 110).labelsHidden().help("Appearance: System / Light / Dark")
            Circle().fill(model.isStreaming ? Theme.green : .gray).frame(width: 8, height: 8)
            if wide { Text(model.isStreaming ? "LIVE" : "NOT STREAMING").font(.caption.bold()).foregroundStyle(.secondary) }
        }
        .padding(wide ? 16 : 10)
    }

    private var deviceReady: Bool { model.selectedSerial != nil && model.selectedDevice?.state == "device" }

    /// Picks the roomiest layout that fits the current window width.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            fullBar.padding(14)
            mediumBar.padding(10)
            narrowBar.padding(10)
        }
    }

    private func devicePicker(compact: Bool) -> some View {
        Picker("Device", selection: Binding(get: { model.selectedSerial ?? "" }, set: { model.selectDevice($0.isEmpty ? nil : $0) })) {
            Text("Select device…").tag("")
            ForEach(model.devices) { device in
                Text((compact ? device.model.replacingOccurrences(of: "_", with: " ") : device.displayName) + (device.state == "unauthorized" ? " · UNAUTHORIZED" : "")).tag(device.serial)
            }
        }.labelsHidden().fixedSize().frame(minWidth: compact ? 150 : 290, alignment: .leading)
    }
    private func gamePicker(compact: Bool) -> some View {
        Picker("Game", selection: $model.selectedGame) {
            ForEach(GamePackage.allCases) { game in Text(game.title).tag(game) }
        }.labelsHidden().fixedSize().frame(minWidth: compact ? 140 : 190, alignment: .leading)
    }

    private var streamLabelIcon: String { model.isStreaming ? "stop.fill" : "play.fill" }
    private var canStream: Bool { model.isStreaming || model.devices.contains(where: { $0.state == "device" }) }

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
            if model.usesCustomCaptureDirectory {
                Button("Dùng lại thư mục Downloads", systemImage: "arrow.uturn.backward") { model.resetCaptureDirectory() }
            }
            Divider()
            Button("Clear View Only", systemImage: "eraser") { model.clearVisibleEvents() }
            Button("Clear Device Log Buffer…", systemImage: "trash", role: .destructive) { showDeviceBufferWarning = true }
            Divider()
            Button("Copy Visible Logs", systemImage: "doc.on.doc") { model.copyVisibleEvents() }
            Button("Export Visible Logs…", systemImage: "square.and.arrow.up") { model.exportVisibleEvents() }
            Divider()
            Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { model.checkForUpdates(manual: true) }
        } label: { Image(systemName: "ellipsis.circle").font(.title3) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 26)
    }

    private func searchBar(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(compact ? "Search" : "Search: event name, parameter or value (e.g. shop level 3)", text: $model.searchText)
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Text("\(model.visibleEvents.count) found").font(.caption).foregroundStyle(.secondary)
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Divider().frame(height: 18)
            Toggle("Auto-scroll", isOn: $model.autoScroll).toggleStyle(.checkbox).font(.caption)
        }
        .padding(compact ? 6 : 9).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private var fullBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ANDROID DEVICE").font(.caption2.bold()).foregroundStyle(.secondary)
                    devicePicker(compact: false)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("GAME PACKAGE").font(.caption2.bold()).foregroundStyle(.secondary)
                    gamePicker(compact: false)
                }
                Button { model.requestSetup() } label: {
                    Label("Configure & Capture", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(!deviceReady)
                Button { model.isStreaming ? model.stopAllStreams() : model.startAllStreams() } label: {
                    Label(model.isStreaming ? "Stop All" : "Stream All Devices", systemImage: streamLabelIcon)
                }.disabled(!canStream)
                Button { model.takeScreenshot() } label: { Label("Chụp", systemImage: "camera") }
                    .help("Chụp màn hình điện thoại, lưu vào \(model.captureDirectoryName)")
                    .disabled(!deviceReady)
                Button { model.toggleRecording() } label: {
                    Label(model.isRecordingSelected ? "Dừng quay" : "Quay", systemImage: model.isRecordingSelected ? "stop.circle.fill" : "record.circle")
                }
                .tint(model.isRecordingSelected ? .red : nil)
                .help("Quay màn hình điện thoại (tối đa 3 phút), lưu vào \(model.captureDirectoryName)")
                .disabled(!deviceReady)
                moreMenu
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            searchBar(compact: false)
        }
    }

    private var actionIcons: some View {
        HStack(spacing: 8) {
            iconButton("bolt.fill", help: "Configure & Capture", tint: Theme.accent, enabled: deviceReady) { model.requestSetup() }
            iconButton(streamLabelIcon, help: model.isStreaming ? "Stop All" : "Stream All Devices", enabled: canStream) {
                model.isStreaming ? model.stopAllStreams() : model.startAllStreams()
            }
            iconButton("camera", help: "Chụp màn hình → \(model.captureDirectoryName)", enabled: deviceReady) { model.takeScreenshot() }
            iconButton(model.isRecordingSelected ? "stop.circle.fill" : "record.circle",
                       help: model.isRecordingSelected ? "Dừng quay" : "Quay màn hình → \(model.captureDirectoryName)",
                       tint: model.isRecordingSelected ? .red : nil, enabled: deviceReady) { model.toggleRecording() }
            iconButton("iphone.gen3", help: model.isMirroringSelected ? "Stop Mirroring" : "Mirror Screen",
                       tint: model.isMirroringSelected ? Theme.green : nil, enabled: deviceReady && !model.isInstallingScrcpy) { model.toggleMirror() }
            iconButton("bell.badge", help: "Notification Schedule…", enabled: deviceReady) { model.openNotificationSchedule() }
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

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 26, height: 22) }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(tint)
            .help(help)
            .disabled(!enabled)
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("EVENTS").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Picker("", selection: $model.detailedList) {
                    Image(systemName: "list.bullet").tag(false)
                    Image(systemName: "rectangle.grid.1x2").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 70).help("Compact / Detailed view")
                Text("\(model.visibleEvents.count) items").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
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
                            .onTapGesture { model.selectedEventID = event.id }
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
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
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

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let event = model.selectedEvent {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.name).font(.title3.bold()).textSelection(.enabled)
                    Spacer()
                    Button { copy(event.copyText) } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                        .buttonStyle(.bordered).controlSize(.small).help("Copy event name + all parameters")
                }
                Text("\(event.clock) · \(event.deviceSerial)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(event.params, id: \.self) { p in
                            HStack(alignment: .top, spacing: 10) {
                                Text(p.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                    .frame(width: 130, alignment: .leading)
                                Text(p.value).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .opacity(p.isInternal ? 0.5 : 1)
                            .padding(.vertical, 5)
                            Divider()
                        }
                        if event.params.isEmpty { Text("No parameters").foregroundStyle(.secondary).padding(.top, 8) }
                        DisclosureGroup("Raw log") {
                            Text(event.raw).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.top, 12).font(.caption)
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
        let delta = d.timeIntervalSinceNow
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
                        let next = notifs.first(where: { $0.fireDate > Date() }) ?? notifs.first
                        Text("\(notifs.count) thông báo đã hẹn" + (next.map { " · tiếp theo \(ScheduledAlarm.fullFormatter.string(from: $0.fireDate)) (\(countdown($0.fireDate)))" } ?? ""))
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
            }
        }
        .padding(18)
        .frame(minWidth: 460, idealWidth: 640, maxWidth: 820, minHeight: 360, idealHeight: 460, maxHeight: 700, alignment: .topLeading)
        .background(Theme.bg)
    }

    private func row(_ a: ScheduledAlarm) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ScheduledAlarm.fullFormatter.string(from: a.fireDate)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(countdown(a.fireDate)).font(.caption).foregroundStyle(a.fireDate > Date() ? Theme.green : .secondary)
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
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(view.window?.contentView) }
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.apply(view.window?.contentView) }
        }
    }
    private static func apply(_ root: NSView?) {
        guard let root else { return }
        if let sv = root as? NSScrollView {
            sv.scrollerStyle = .overlay
            sv.verticalScroller?.controlSize = .mini
            sv.horizontalScroller?.controlSize = .mini
        }
        root.subviews.forEach(apply)
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
