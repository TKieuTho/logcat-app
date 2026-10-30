import Foundation
import SwiftUI
import Combine
import AppKit

/// A log line that already went through filtering and parsing off the main thread.
enum Prepared {
    case event(raw: String, name: String, params: [EventParam], kind: LogKind, date: Date, tag: String)
    case unreadable(raw: String)
    case snapshot(app: String, props: [UserPropertyState])
}

/// Drops the history dump that logcat replays on start: nothing passes until our own marker line shows up.
final class StreamGate: @unchecked Sendable {
    private let token: String
    private var isOpen = false
    private var closed = false
    private let lock = NSLock()
    init(token: String) { self.token = token }
    func pass(_ line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isOpen { return true }
        if line.contains(token) { isOpen = true }
        return false
    }
    func openNow() { lock.lock(); if !closed { isOpen = true }; lock.unlock() }
    /// After Stop / disconnect: lines still sitting in the pipe must not show up as new events.
    func close() { lock.lock(); closed = true; isOpen = false; lock.unlock() }
    var opened: Bool { lock.lock(); defer { lock.unlock() }; return isOpen }
}

/// Newest upload dump per app seen in the replayed history, kept so the properties table is not empty at Start.
final class HistorySnapshots: @unchecked Sendable {
    var latest: [String: [UserPropertyState]] = [:]
}

/// Lines are parsed on the reader thread and queued here in arrival order; the main actor drains it in batches.
final class IngestQueue: @unchecked Sendable {
    private var items: [(serial: String, item: Prepared)] = []
    private let lock = NSLock()
    func push(_ serial: String, _ item: Prepared) { lock.lock(); items.append((serial, item)); lock.unlock() }
    func drain() -> [(serial: String, item: Prepared)] {
        lock.lock(); defer { lock.unlock() }
        let out = items; items.removeAll(keepingCapacity: true); return out
    }
}

/// What the app is doing / just finished, shown as a small pill in the header.
struct Activity: Identifiable, Equatable {
    enum Kind { case working, done, error }
    let id = UUID()
    var kind: Kind
    var emoji: String
    var title: String
    var detail: String?
    var startedAt: Date?
    var fileURL: URL?
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var devices: [ADBDevice] = []
    @Published var selectedSerial: String?
    @Published var selectedGame: GamePackage = .snakeEscape
    @Published var events: [LogEvent] = []
    @Published var searchText = ""
    @Published var statusText = "Starting…"
    @Published var isStreaming = false
    @Published var showSetupConfirmation = false
    @Published var showLaunchConfirmation = false
    /// Phone and game the setup dialog asked about; Confirm must act on these even if the dropdowns changed meanwhile.
    @Published private(set) var pendingSetup: (serial: String, game: GamePackage)?
    @Published var errorMessage: String?
    @Published var selectedEventID: UUID?
    /// Latest full user-property list per "serial|app", read from the SDK's upload dumps.
    @Published var propertySnapshots: [String: PropertySnapshot] = [:]
    /// Last value per property from live "Setting user property" lines (used when the SDK prints no upload dump).
    @Published var liveProperties: [String: [String: UserPropertyState]] = [:]
    @Published var activity: Activity?
    private var activityTask: Task<Void, Never>?
    @Published var detailVisible = true      // split layout (wide window)
    @Published var drawerOpen = false        // floating drawer (narrow window)
    @Published var splitLayout = true        // set by the view from the window width
    @Published var autoScroll = true
    @Published var kindFilter: KindFilter = .all
    @AppStorage("detailedList") var detailedList = true
    @AppStorage("appearance") var appearance = "light"
    @Published var selectedTags: Set<String> = ["FA", "FA-SVC"]

    @Published var updateInfo: UpdateInfo?
    @Published var showUpdateAlert = false
    @Published var updateMessage: String?
    @Published var isInstallingUpdate = false
    @Published var skippedLines = 0
    @Published var mirroringSerials = Set<String>()
    @Published var recordingSerials = Set<String>()
    @AppStorage("captureDir") var captureDirPath = ""
    @Published var lastSavedFile: URL?
    private var recordProcesses: [String: Process] = [:]
    @Published var showScrcpyMissing = false
    @Published var isInstallingScrcpy = false
    private var mirrorProcesses: [String: Process] = [:]
    @Published var showNotificationSchedule = false
    @Published var alarms: [ScheduledAlarm] = []
    @Published var alarmsLoading = false
    @Published var alarmsError: String?
    @Published var alarmsCheckedAt: Date?
    /// Phone clock minus Mac clock when the list was read, and the phone's time zone.
    @Published var alarmsClockOffset: TimeInterval = 0
    @Published var alarmsTimeZone: TimeZone = .current
    /// "Now" on the phone being inspected.
    func alarmTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = ScheduledAlarm.fullFormatter.dateFormat; f.timeZone = alarmsTimeZone
        return f.string(from: d)
    }
    var alarmsDeviceNow: Date { Date().addingTimeInterval(alarmsClockOffset) }
    var lastSkippedLine = ""

    private let adb = ADBService()
    private var streamProcesses: [String: Process] = [:]
    private var historyProcesses: [Process] = []
    @Published private(set) var streamingSerials = Set<String>()
    /// Game each live stream was started for (the game the phone is set to debug); stays put if the dropdown changes later.
    @Published private(set) var streamGames: [String: GamePackage] = [:]
    /// Streams the user asked for; if one dies (unplug, adb restart) it is reconnected when the device is back.
    private var wantedSerials = Set<String>()
    private var manuallyStopped = Set<String>()
    private var streamGen: [String: UUID] = [:]
    private var streamGates: [String: StreamGate] = [:]
    private var recordStarts: [String: Date] = [:]
    private let ingestQueue = IngestQueue()
    private var serviceObservation: Any?

    init() {
        Task { @MainActor [weak self] in
            while let self { self.drainIngestQueue(); try? await Task.sleep(for: .milliseconds(100)) }
        }
        Self.killStaleLogcat()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateChildren() }
        }
        adb.$devices.receive(on: RunLoop.main).sink { [weak self] list in
            guard let self else { return }
            self.devices = list
            // Nothing chosen yet (or the chosen one is gone): pick the first connected phone so Start works right away.
            if self.selectedSerial == nil || !list.contains(where: { $0.serial == self.selectedSerial }) {
                self.selectedSerial = (list.first { $0.state == "device" } ?? list.first)?.serial ?? self.selectedSerial
            }
            self.reconnectStreams()
        }.store(in: &cancellables)
        adb.$status.receive(on: RunLoop.main).sink { [weak self] in self?.statusText = $0 }.store(in: &cancellables)
    }
    private var cancellables = Set<AnyCancellable>()

    var selectedDevice: ADBDevice? { devices.first(where: { $0.serial == selectedSerial }) }
    var visibleEvents: [LogEvent] {
        events.filter { event in
            (selectedSerial == nil || event.deviceSerial == selectedSerial) &&
            kindFilter.allows(event.kind) &&
            Self.matches(event, tokens: searchTokens)
        }
    }
    private var searchTokens: [String] {
        searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }
    /// Every space-separated term must appear in the event name or any "key=value".
    private static func matches(_ event: LogEvent, tokens: [String]) -> Bool {
        tokens.allSatisfy { event.blob.contains($0) }
    }
    func setActivity(_ kind: Activity.Kind, _ emoji: String, _ title: String, detail: String? = nil,
                     since: Date? = nil, file: URL? = nil, clearAfter: TimeInterval? = nil) {
        activityTask?.cancel()
        let a = Activity(kind: kind, emoji: emoji, title: title, detail: detail, startedAt: since, fileURL: file)
        activity = a
        let delay = clearAfter ?? (kind == .working ? nil : (kind == .error ? 9 : 7))
        guard let delay else { return }
        activityTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled, activity?.id == a.id { activity = nil }
        }
    }
    func clearActivity() { activityTask?.cancel(); activity = nil }

    /// The list for the selected device and game (falls back to the device's most recent one).
    var currentPropertySnapshot: (app: String, snapshot: PropertySnapshot)? {
        let wanted = selectedGame.rawValue
        let candidates = propertySnapshots.compactMap { (k, v) -> (String, String, PropertySnapshot)? in
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, selectedSerial == nil || parts[0] == selectedSerial else { return nil }
            return (parts[0], parts[1], v)
        }
        if let hit = candidates.first(where: { $0.1 == wanted }) { return (hit.1, hit.2) }
        if let latest = candidates.max(by: { $0.2.updatedAt < $1.2.updatedAt }) { return (latest.1, latest.2) }
        // No SDK dump: rebuild from the property-set lines seen since Start (cannot tell which app, so label it as such).
        let serial = selectedSerial ?? liveProperties.keys.first
        if let serial, let table = liveProperties[serial], !table.isEmpty {
            let props = table.values.sorted { $0.setAt < $1.setAt }
            return ("Tổng hợp từ các dòng “Setting user property” (máy chưa in bản kê của SDK)", PropertySnapshot(props: props, updatedAt: props.map(\.setAt).max() ?? Date()))
        }
        return nil
    }

    func openDetail() { detailVisible = true; drawerOpen = true }
    func closeDetail() { if splitLayout { detailVisible = false } else { drawerOpen = false } }
    func toggleDetail() { if splitLayout { detailVisible.toggle() } else { drawerOpen.toggle() } }
    var detailShown: Bool { splitLayout ? detailVisible : drawerOpen }
    var selectedEvent: LogEvent? { visibleEvents.first(where: { $0.id == selectedEventID }) }

    /// manual = user pressed the button (always report the result); otherwise only speak up when a newer version exists.
    func checkForUpdates(manual: Bool) {
        Task {
            do {
                let info = try await Updater.fetchLatest()
                if Updater.isNewer(info.version, than: Updater.currentVersion) {
                    updateInfo = info; showUpdateAlert = true
                } else if manual {
                    updateMessage = "Bạn đang dùng bản mới nhất (\(Updater.currentVersion))."
                }
            } catch {
                if manual { updateMessage = "Không kiểm tra được bản cập nhật: \(error.localizedDescription)" }
            }
        }
    }
    /// Start/Stop acts on the chosen phone only; the header LIVE light (`isStreaming`) stays "any phone".
    /// One entry per live phone, e.g. "SM A055F · Snake Escape", for the header.
    var liveStreams: [(serial: String, text: String)] {
        streamingSerials.sorted().map { ($0, "\(deviceName($0)) · \((streamGames[$0] ?? selectedGame).title)") }
    }
    var liveSummary: [String] { liveStreams.map(\.text) }
    var isStreamingSelected: Bool { selectedSerial.map(streamingSerials.contains) ?? false }
    var isRecordingSelected: Bool { selectedSerial.map(recordingSerials.contains) ?? false }

    private var downloadsDirectory: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    /// Where screenshots and recordings go; falls back to Downloads if the chosen folder disappeared.
    var captureDirectory: URL {
        var isDir: ObjCBool = false
        if !captureDirPath.isEmpty, FileManager.default.fileExists(atPath: captureDirPath, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: captureDirPath, isDirectory: true)
        }
        return downloadsDirectory
    }
    var captureDirectoryName: String { captureDirectory.lastPathComponent }
    var usesCustomCaptureDirectory: Bool { captureDirectory != downloadsDirectory }
    func chooseCaptureDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = captureDirectory
        panel.prompt = "Chọn thư mục"
        panel.message = "Chọn nơi lưu ảnh chụp và video quay màn hình"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        captureDirPath = url.path
        objectWillChange.send()
    }
    func resetCaptureDirectory() { captureDirPath = ""; objectWillChange.send() }

    private func captureURL(serial: String, ext: String) -> (url: URL, stamp: String) {
        let dir = captureDirectory
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = f.string(from: Date())
        let device = (devices.first { $0.serial == serial }?.model ?? serial).replacingOccurrences(of: " ", with: "_")
        return (dir.appendingPathComponent("Logcat_\(device)_\(stamp).\(ext)"), stamp)
    }

    func takeScreenshot() {
        guard let serial = selectedSerial else { return }
        let url = captureURL(serial: serial, ext: "png").url
        setActivity(.working, "📸", "Đang chụp màn hình…")
        Task {
            do {
                if await adb.wakeScreenIfNeeded(serial: serial) { setActivity(.working, "📸", "Máy đang tắt màn hình, đã bật sáng lại…") }
                try await adb.screenshot(serial: serial, to: url)
                lastSavedFile = url
                let pb = NSPasteboard.general
                pb.clearContents()
                if let img = NSImage(contentsOf: url) { pb.writeObjects([img]) }
                statusText = "Đã lưu ảnh vào \(captureDirectoryName) và copy vào clipboard (⌘V để dán): \(url.lastPathComponent)"
                setActivity(.done, "📸", "Chụp xong rồi!", detail: "Ảnh đã copy, dán ngay được (⌘V) · lưu ở \(captureDirectoryName)", file: url, clearAfter: 9)
            } catch {
                errorMessage = error.localizedDescription
                setActivity(.error, "😿", "Chụp không được", detail: error.localizedDescription)
            }
        }
    }

    func toggleRecording() {
        guard let serial = selectedSerial else { return }
        if recordingSerials.contains(serial) {
            if recordProcesses[serial] == nil {   // still waking the screen: nothing is recording yet, just cancel
                recordingSerials.remove(serial); clearActivity(); return
            }
            setActivity(.working, "💾", "Đang lưu video…")
            Task {
                // The stop signal can miss (screenrecord not up yet right after Start), so repeat until it really ended.
                for _ in 0..<5 {
                    await adb.stopRecording(serial: serial)
                    try? await Task.sleep(for: .seconds(2))
                    if !recordingSerials.contains(serial) { return }
                }
                recordProcesses[serial]?.terminate()
            }
            return
        }
        let (url, stamp) = captureURL(serial: serial, ext: "mp4")
        let remote = "/sdcard/logcat_rec_\(stamp).mp4"
        recordingSerials.insert(serial)   // set at once so a second click during the wake-up wait is a Stop, not a second recording
        Task {
            if await adb.wakeScreenIfNeeded(serial: serial) { setActivity(.working, "🎬", "Máy đang tắt màn hình, đã bật sáng lại…") }
            guard recordingSerials.contains(serial) else { return }
            do {
                let p = try adb.startRecording(serial: serial, remote: remote) { [weak self] status, output in
                    Task { @MainActor in await self?.finishRecording(serial: serial, remote: remote, local: url, status: status, output: output) }
                }
                recordProcesses[serial] = p
                recordStarts[serial] = Date()
                statusText = "Đang quay màn hình (tối đa 3 phút, bấm Dừng để lưu)…"
                setActivity(.working, "🎬", "Đang quay màn hình", detail: "Bấm Dừng quay để lưu (tối đa 3 phút)", since: Date())
            } catch { recordingSerials.remove(serial); errorMessage = error.localizedDescription }
        }
    }

    private func finishRecording(serial: String, remote: String, local: URL, status: Int32, output: String) async {
        recordProcesses[serial] = nil
        recordingSerials.remove(serial)
        let hitLimit = recordStarts.removeValue(forKey: serial).map { Date().timeIntervalSince($0) >= 175 } ?? false
        do {
            try await adb.pullAndRemove(serial: serial, remote: remote, to: local)
            // screenrecord can end at once and leave a ~1 KB shell of a file; do not report that as a recording.
            let size = ((try? FileManager.default.attributesOfItem(atPath: local.path))?[.size] as? NSNumber)?.intValue ?? 0
            if size < 20_000 {
                try? FileManager.default.removeItem(at: local)
                setActivity(.error, "😿", "Quay không thành công", detail: output.isEmpty ? "Video rỗng (máy dừng quay ngay). Thử quay lại." : String(output.suffix(120)))
                return
            }
            lastSavedFile = local
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([local as NSURL])
            statusText = "Đã lưu video vào \(captureDirectoryName) và copy file vào clipboard (⌘V dán vào Finder/Slack/Notion): \(local.lastPathComponent)"
            setActivity(.done, "🎬", "Quay xong rồi!", detail: (hitLimit ? "Đã tự dừng ở giới hạn 3 phút · " : "") + "Video đã copy, dán được (⌘V) · lưu ở \(captureDirectoryName)", file: local, clearAfter: 10)
        } catch {
            setActivity(.error, "😿", "Lưu video không được", detail: error.localizedDescription)
            errorMessage = "Không lưu được video: \(error.localizedDescription)" + (output.isEmpty ? "" : "\n\(String(output.suffix(300)))")
        }
    }

    var isMirroringSelected: Bool { selectedSerial.map(mirroringSerials.contains) ?? false }

    /// Screen mirroring is delegated to scrcpy (open source, talks to the device over the same adb).
    func toggleMirror() {
        guard let serial = selectedSerial else { return }
        if let p = mirrorProcesses[serial] { p.terminate(); return }
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy", "/opt/local/bin/scrcpy"]
        guard let exe = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            showScrcpyMissing = true
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-s", serial, "--window-title", "Logcat · \(selectedDevice?.model.replacingOccurrences(of: "_", with: " ") ?? serial)"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        if let adb = adb.adbPath { env["ADB"] = adb.path }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.terminationHandler = { [weak self] proc in
            let out = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in
                self?.mirrorProcesses[serial] = nil
                self?.mirroringSerials.remove(serial)
                if proc.terminationStatus != 0 && proc.terminationReason == .exit {
                    self?.errorMessage = "scrcpy dừng với lỗi:\n" + String(out.suffix(400))
                }
            }
        }
        do {
            try p.run()
            mirrorProcesses[serial] = p
            mirroringSerials.insert(serial)
            setActivity(.done, "📱", "Đang chiếu màn hình", detail: "Cửa sổ scrcpy đã mở", clearAfter: 4)
        } catch { errorMessage = error.localizedDescription }
    }

    private var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var canInstallScrcpyWithBrew: Bool { brewPath != nil }

    /// Installs scrcpy through Homebrew (only reachable after the user confirms), then starts mirroring.
    func installScrcpyAndMirror() {
        guard let brew = brewPath, !isInstallingScrcpy else { return }
        isInstallingScrcpy = true
        statusText = "Đang cài scrcpy bằng Homebrew (vài phút)…"
        setActivity(.working, "📦", "Đang cài scrcpy", detail: "Bằng Homebrew, mất vài phút", since: Date())
        Task {
            let result: (Int32, String) = await Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brew)
                p.arguments = ["install", "scrcpy"]
                var env = ProcessInfo.processInfo.environment
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"; env["HOMEBREW_NO_ENV_HINTS"] = "1"
                p.environment = env
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { return (-1, error.localizedDescription) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
            }.value
            isInstallingScrcpy = false
            if result.0 == 0 { statusText = "Đã cài scrcpy"; setActivity(.done, "📦", "Đã cài scrcpy xong"); toggleMirror() }
            else { statusText = "Cài scrcpy thất bại"; setActivity(.error, "😿", "Cài scrcpy không được"); errorMessage = "Không cài được scrcpy:\n" + String(result.1.suffix(500)) }
        }
    }
    func openScrcpyInstallGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Genymobile/scrcpy/blob/master/doc/macos.md")!)
    }

    func refreshAlarms() {
        guard let serial = selectedSerial, !alarmsLoading else { return }
        alarmsLoading = true; alarmsError = nil
        let package = selectedGame.rawValue
        Task {
            do {
                let r = try await adb.fetchAlarms(serial: serial, package: package)
                alarms = r.alarms; alarmsClockOffset = r.deviceNow.timeIntervalSinceNow; alarmsTimeZone = r.timeZone; alarmsCheckedAt = Date()
            }
            catch { alarmsError = error.localizedDescription }
            alarmsLoading = false
        }
    }
    func openNotificationSchedule() {
        alarms = []; alarmsCheckedAt = nil
        showNotificationSchedule = true
        refreshAlarms()
    }
    func installUpdate() {
        guard let info = updateInfo, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        statusText = "Đang tải bản \(info.version)…"
        setActivity(.working, "🚀", "Đang tải bản \(info.version)", detail: "App sẽ tự mở lại sau khi cập nhật", since: Date())
        Task {
            do {
                try await Updater.install(info)
                NSApp.terminate(nil)
            } catch {
                isInstallingUpdate = false
                updateMessage = "Không tự cập nhật được: \(error.localizedDescription)\nMở trang tải về để cập nhật thủ công."
                openUpdateDownload()
            }
        }
    }
    func openUpdateDownload() {
        if let s = updateInfo?.url, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    /// One button: ask to turn on Firebase debug only when this device is not already set up for the chosen game, then stream it.
    func startSession() {
        guard let serial = selectedSerial, selectedDevice?.state == "device" else {
            errorMessage = "Chọn một thiết bị đang kết nối (đã bấm Allow USB debugging) trước."
            return
        }
        manuallyStopped.remove(serial)
        let game = selectedGame
        Task {
            let st = await adb.debugSetup(serial: serial)
            if st.app != game.rawValue || !st.verbose { pendingSetup = (serial, game); showSetupConfirmation = true }
            else { startStream(for: serial, game: game) }
        }
    }
    func stopSession() { stopStream() }

    func confirmSetup() {
        guard let (serial, game) = pendingSetup else { return }
        pendingSetup = nil
        Task {
            do {
                try await adb.configureFirebase(serial: serial, package: game)
                startStream(for: serial, game: game)
                setActivity(.done, "✨", "Đã bật debug Firebase", detail: "Đang ghi log từ bây giờ")
                statusText = "Đang ghi log từ bây giờ. Nếu event chưa hiện, mở lại game (Menu ⋯ → Restart Game…) để bật debug mode."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func confirmLaunch() {
        guard let serial = selectedSerial else { return }
        Task {
            do {
                try await adb.launchGame(serial: serial, package: selectedGame)
                startStream()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func startStream() {
        guard let serial = selectedSerial else { return }
        startStream(for: serial)
    }
    func startStream(for serial: String, auto: Bool = false, game: GamePackage? = nil) {
        guard !streamingSerials.contains(serial) else { return }
        if !auto { manuallyStopped.remove(serial) }
        wantedSerials.insert(serial)
        let gen = UUID()
        do {
            let token = "START_\(UUID().uuidString)"
            let gate = StreamGate(token: token)
            let queue = ingestQueue
            let dump = UploadDumpParser()
            let p = try adb.startLogcat(serial: serial, onLine: { line in
                guard gate.pass(line) else { return }
                if let snap = dump.feed(line) { queue.push(serial, .snapshot(app: snap.app, props: snap.props)) }
                if let item = StudioModel.prepare(line) { queue.push(serial, item) }
            }, onExit: { [weak self] in
                Task { @MainActor in self?.streamEnded(serial, gen: gen) }
            })
            streamGen[serial] = gen
            streamGates[serial] = gate
            streamProcesses[serial] = p
            streamingSerials.insert(serial)
            streamGames[serial] = game ?? (auto ? (streamGames[serial] ?? selectedGame) : selectedGame)
            loadPropertyHistory(serial)
            Task {
                do { try await adb.sendStartMarker(serial: serial, token: token) }
                catch { gate.openNow() }
                // If the marker never comes back, stop waiting: only the replayed history before it is lost.
                try? await Task.sleep(for: .seconds(8))
                gate.openNow()
            }
            isStreaming = !streamingSerials.isEmpty
            statusText = "Đang ghi log: " + liveSummary.joined(separator: "  |  ")
            if auto {
                setActivity(.done, "🔄", "Đã nối lại \(deviceName(serial))", detail: "Ghi log tiếp từ lúc này", clearAfter: 6)
            } else {
                setActivity(.done, "🐾", "Đang ghi log", detail: "\(deviceName(serial)) · \((streamGames[serial] ?? selectedGame).title) · chỉ hiện log từ lúc này", clearAfter: 5)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Reads the device's old log once, in the background, only to find the newest property list per app (events stay hidden).
    private func loadPropertyHistory(_ serial: String) {
        let dump = UploadDumpParser()
        let latest = HistorySnapshots()
        let queue = ingestQueue
        if let p = try? adb.startLogcat(serial: serial, history: true, onLine: { line in
            if let snap = dump.feed(line) { latest.latest[snap.app] = snap.props }
        }, onEnd: {
            for (app, props) in latest.latest { queue.push(serial, .snapshot(app: app, props: props)) }
        }) { historyProcesses.append(p) }
    }

    /// Children are not killed when the app exits, so stop them ourselves (otherwise `adb logcat` / scrcpy pile up).
    private func terminateChildren() {
        for p in streamProcesses.values { p.terminationHandler = nil; p.terminate() }
        for p in mirrorProcesses.values { p.terminate() }
        for p in historyProcesses { p.terminate() }
        // screenrecord keeps running on the phone after we quit; finalize the mp4 instead of leaving it recording.
        if let adbURL = adb.adbPath {
            for serial in recordingSerials {
                let k = Process()
                k.executableURL = adbURL
                k.arguments = ["-s", serial, "shell", "kill -2 $(pidof screenrecord)"]
                try? k.run(); k.waitUntilExit()
            }
        }
    }

    /// Cleans up `adb logcat` streams left behind by a previous run that crashed or was killed (they are re-parented to launchd).
    private static func killStaleLogcat() {
        let ps = Process()
        let out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, parts[1] == "1", (parts[2].contains(" logcat -T 1 -v time -s FA FA-SVC \(ADBService.markerTag):I") || parts[2].contains(" logcat -v time -s FA FA-SVC \(ADBService.markerTag):I")),
                  let pid = Int32(parts[0]) else { continue }
            kill(pid, SIGTERM)
        }
    }

    private func deviceName(_ serial: String) -> String {
        let model = devices.first { $0.serial == serial }?.model.replacingOccurrences(of: "_", with: " ") ?? ""
        return model.isEmpty ? serial : model
    }

    /// The adb logcat process ended on its own (device unplugged, adb restarted…); ignore ends we caused ourselves.
    private func streamEnded(_ serial: String, gen: UUID) {
        guard streamGen[serial] == gen else { return }
        streamGen[serial] = nil
        streamGates[serial]?.close(); streamGates[serial] = nil
        streamProcesses[serial] = nil
        streamingSerials.remove(serial)
        isStreaming = !streamingSerials.isEmpty
        statusText = "Mất kết nối \(deviceName(serial)); sẽ tự nối lại khi máy trở lại"
        setActivity(.error, "🔌", "Mất kết nối \(deviceName(serial))", detail: "Tự nối lại khi máy trở lại", clearAfter: 10)
    }

    /// Runs on every device refresh (3 s): restart wanted streams that died (unplugged and plugged back, adb restarted…).
    private func reconnectStreams() {
        for d in devices where d.state == "device" && !streamingSerials.contains(d.serial) && !manuallyStopped.contains(d.serial)
            && wantedSerials.contains(d.serial) {
            startStream(for: d.serial, auto: true)
        }
    }
    func stopStream() {
        guard let serial = selectedSerial else { return }
        stopStream(for: serial)
    }
    func stopStream(for serial: String) {
        streamGen[serial] = nil
        streamGates[serial]?.close(); streamGates[serial] = nil
        wantedSerials.remove(serial)
        manuallyStopped.insert(serial)
        if let process = streamProcesses[serial] {
            process.terminate()
            streamProcesses.removeValue(forKey: serial)
        }
        streamingSerials.remove(serial)
        streamGames[serial] = nil
        isStreaming = !streamingSerials.isEmpty
        statusText = isStreaming ? "Đang ghi log: " + liveSummary.joined(separator: "  |  ") : "Chưa ghi log"
        if !isStreaming { setActivity(.done, "💤", "Đã dừng ghi log", clearAfter: 4) }
    }
    func stopAllStreams() {
        for serial in Array(streamingSerials) { stopStream(for: serial) }
    }
    func selectDevice(_ serial: String?) {
        selectedSerial = serial
    }
    func clearVisibleEvents() {
        // Intentionally UI-only: does not run `adb logcat -c` and does not clear device logs.
        let visibleIDs = Set(visibleEvents.map(\.id))
        events.removeAll { visibleIDs.contains($0.id) }
        selectedEventID = nil
        setActivity(.done, "🧹", "Đã xóa danh sách trong app", detail: "Log trên máy vẫn còn nguyên", clearAfter: 4)
    }
    func clearDeviceBufferAfterConfirmation() {
        guard let serial = selectedSerial else { return }
        Task {
            do { try await adb.clearDeviceLogBuffer(serial: serial); statusText = "Device log buffer cleared on \(serial)" }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func copySelectedEvent() {
        guard let event = selectedEvent else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.copyText, forType: .string)
    }
    func copyVisibleEvents() {
        let text = visibleEvents.map(\.copyText).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setActivity(.done, "📋", "Đã copy \(visibleEvents.count) event", detail: "Dán được ngay (⌘V)", clearAfter: 4)
    }
    func exportVisibleEvents() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "firebase-events-\(Date.now.formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try visibleEvents.map(\.copyText).joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }
    /// Which log flavour a line came from; the same event is logged once per flavour, never twice within one.
    private static func sourceKey(_ line: String) -> String {
        line.contains("Event recorded") ? "recorded" : line.contains("(FE)") ? "fe" : "plain"
    }
    /// Runs on the reader thread: cheap filter first, then parse.
    nonisolated static func prepare(_ line: String) -> Prepared? {
        guard LogEvent.looksRelevant(line) else { return nil }
        guard let parsed = LogEvent.parse(raw: line) else {
            let l = line.lowercased()
            return (l.contains("logging event") || l.contains("setting user property") || l.contains("event recorded")) ? .unreadable(raw: line) : nil
        }
        return .event(raw: line, name: parsed.name, params: parsed.params, kind: parsed.kind,
                      date: parseDate(line) ?? Date(), tag: line.contains("FA-SVC") ? "FA-SVC" : "FA")
    }

    private func drainIngestQueue() {
        for (serial, item) in ingestQueue.drain() { ingest(item, serial: serial) }
    }

    private func ingest(_ item: Prepared, serial: String) {
        switch item {
        case .unreadable(let raw):
            skippedLines += 1
            lastSkippedLine = raw
        case .snapshot(let app, var props):
            let key = "\(serial)|\(app)"
            let prev = Dictionary((propertySnapshots[key]?.props ?? []).map { ($0.rawName, $0) }, uniquingKeysWith: { a, _ in a })
            let first = propertySnapshots[key] == nil
            for i in props.indices {
                if let old = prev[props[i].rawName] {
                    props[i].changedAt = (old.value != props[i].value || old.setAt != props[i].setAt) ? Date() : old.changedAt
                } else if !first { props[i].changedAt = Date() }
            }
            propertySnapshots[key] = PropertySnapshot(props: props, updatedAt: Date())
        case .event(let raw, let name, let params, let kind, let date, let tag):
            if kind == .userProperty, !params.contains(where: { $0.key == "status" }), let value = params.first?.value {
                var table = liveProperties[serial] ?? [:]
                let changed = table[name].map { $0.value != value } ?? !table.isEmpty
                table[name] = UserPropertyState(rawName: name, value: value, setAt: date, changedAt: changed ? Date() : table[name]?.changedAt)
                liveProperties[serial] = table
            }
            // The "too many properties" warning repeats on every upload cycle; once per property is enough.
            if params.contains(where: { $0.key == "status" }),
               events.suffix(400).contains(where: { $0.deviceSerial == serial && $0.kind == .userProperty && $0.name == name &&
                   $0.params.contains(where: { $0.key == "status" }) }) { return }
            // FA logs one event in several flavours (Logging event / Event recorded); drop only those cross-flavour copies.
            // Identical repeats in the same flavour are genuine separate sends and are kept.
            let key = Self.sourceKey(raw)
            let sig = Set(params.filter { !$0.isInternal }.map { "\($0.key)=\($0.value)" })
            if events.suffix(40).contains(where: { $0.deviceSerial == serial && $0.kind == kind && $0.name == name &&
                Self.sourceKey($0.raw) != key && abs($0.date.timeIntervalSince(date)) < 1 &&
                Set($0.params.filter { !$0.isInternal }.map { "\($0.key)=\($0.value)" }) == sig }) { return }
            events.append(LogEvent(date: date, deviceSerial: serial, tag: tag, raw: raw, name: name, params: params, kind: kind))
            if events.count > 51000 { events.removeFirst(events.count - 50000) }
        }
    }
    nonisolated private static let dateRE = try! NSRegularExpression(pattern: #"^(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.(\d{3})"#)
    nonisolated private static func parseDate(_ line: String) -> Date? {
        // logcat -v time: MM-DD HH:mm:ss.SSS
        guard let mt = dateRE.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func n(_ i: Int) -> Int? { Range(mt.range(at: i), in: line).flatMap { Int(line[$0]) } }
        guard let mo = n(1), let d = n(2), let h = n(3), let mi = n(4), let s = n(5), let ms = n(6) else { return nil }
        var c = DateComponents()
        c.year = Calendar.current.component(.year, from: Date()); c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return Calendar.current.date(from: c).map { $0.addingTimeInterval(Double(ms) / 1000) }
    }
}
