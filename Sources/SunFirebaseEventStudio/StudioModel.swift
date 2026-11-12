import Foundation
import SwiftUI
import Combine
import AppKit

/// A log line that already went through filtering and parsing off the main thread.
enum Prepared {
    case event(raw: String, name: String, params: [EventParam], kind: LogKind, date: Date, tag: String)
    case unreadable(raw: String)
    case snapshot(app: String, props: [UserPropertyState])
    case crash(CrashReport)
}

/// Drops the history dump that logcat replays on start: nothing passes until our own marker line shows up.
final class StreamGate: @unchecked Sendable {
    private let token: String
    private var isOpen = false
    private var closed = false
    private let lock = NSLock()
    /// Called once, when recording really begins: the marker's own log time (the phone's clock), or nil if it never came back.
    private let onOpen: (@Sendable (Date?) -> Void)?
    init(token: String, onOpen: (@Sendable (Date?) -> Void)? = nil) { self.token = token; self.onOpen = onOpen }
    func pass(_ line: String) -> Bool {
        lock.lock()
        if isOpen { lock.unlock(); return true }
        let hit = line.contains(token)
        if hit { isOpen = true }
        lock.unlock()
        if hit { onOpen?(StudioModel.parseDate(line)) }
        return false
    }
    func openNow() {
        lock.lock()
        let already = isOpen || closed
        if !closed { isOpen = true }
        lock.unlock()
        if !already { onOpen?(nil) }
    }
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
    @Published var detailVisible = false     // split layout (wide window): closed until an event is clicked or the handle is used
    @Published var drawerOpen = false        // floating drawer (narrow window)
    @Published var splitLayout = true        // set by the view from the window width
    @Published var autoScroll = true
    @Published var kindFilter: KindFilter = .all
    @AppStorage("detailedList") var detailedList = true
    @AppStorage("appearance") var appearance = "light"
    @Published var crashKinds: Set<CrashKind> = []      // empty = every kind
    @AppStorage("crashCapture") var crashCapture = true
    @AppStorage("crashAllApps") var crashAllApps = false
    @AppStorage("crashAutoSave") var crashAutoSave = true
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
    @Published var activeNotifications: [ActiveNotification] = []
    @Published var notificationsError: String?
    /// Every notification seen while recording, kept after the user swipes it away.
    @Published var notificationLog: [LoggedNotification] = []
    private var notificationLogIDs = Set<String>()
    private var notifPollTask: Task<Void, Never>?
    /// One entry per phone that was started in this run of the app: when recording began, stopped or dropped.
    @Published var sessions: [String: RecordingSession] = [:]
    /// Phones whose old crashes are still being read back (can take 30+ seconds on a phone with a big log).
    @Published var crashHistoryLoading = Set<String>()
    @Published var showPerf = false
    @Published var perfSamples: [PerfSample] = []
    @Published var perfPaused = false
    @Published var perfError: String?
    private(set) var perfSerial: String?
    private var perfLayer = ""
    private var perfTask: Task<Void, Never>?
    @Published var showMeminfo = false
    @Published var meminfo: MemInfoSnapshot?
    @Published var meminfoLoading = false
    @Published var meminfoError: String?
    @Published var meminfoAuto = false
    /// (time, total PSS KB) samples while the memory window is open, for the trend line.
    @Published var meminfoHistory: [(date: Date, pssKB: Int)] = []
    private var meminfoTask: Task<Void, Never>?
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
    private var crashProcesses: [String: Process] = [:]
    private var crashParsers: [String: CrashParser] = [:]
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
    private var signalSources: [DispatchSourceSignal] = []
    private var didStartupCleanup = false

    init() {
        Task { @MainActor [weak self] in
            while let self {
                self.drainIngestQueue()
                // In the background nobody watches the list: batch up to a second of lines per refresh instead of ten.
                try? await Task.sleep(for: .milliseconds(NSApp?.isActive == false ? 1000 : 100))
            }
        }
        Self.killStaleLogcat()
        // `kill` / `pkill` / Ctrl-C skip the normal Quit path: catch them so adb children never become orphans.
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.terminateChildren() }; exit(0) }
            src.resume()
            signalSources.append(src)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateChildren() }
        }
        adb.$devices.receive(on: RunLoop.main).sink { [weak self] list in
            guard let self else { return }
            self.devices = list
            if !self.didStartupCleanup, list.contains(where: { $0.state == "device" }) {
                self.didStartupCleanup = true
                self.cleanupStaleProcesses()
            }
            // Nothing chosen yet (or the chosen one is gone): pick the first connected phone so Start works right away.
            // A phone that blinked off the list (USB hiccup, adb reconnect) while we are recording from it keeps its place in the picker.
            let keepSelection = self.selectedSerial.map { self.wantedSerials.contains($0) || self.streamingSerials.contains($0) } ?? false
            if self.selectedSerial == nil || (!keepSelection && !list.contains(where: { $0.serial == self.selectedSerial })) {
                self.selectedSerial = (list.first { $0.state == "device" } ?? list.first)?.serial ?? self.selectedSerial
            }
            self.reconnectStreams()
        }.store(in: &cancellables)
        adb.$status.receive(on: RunLoop.main).sink { [weak self] in self?.statusText = $0 }.store(in: &cancellables)
    }
    private var cancellables = Set<AnyCancellable>()

    var selectedDevice: ADBDevice? { devices.first(where: { $0.serial == selectedSerial }) }
    private struct VisibleKey: Equatable {
        var count: Int; var last: UUID?; var first: UUID?; var serial: String?; var kind: KindFilter
        var search: String; var crashKinds: Set<CrashKind>; var allApps: Bool
    }
    private var visibleCache: (key: VisibleKey, list: [LogEvent])?
    /// Filtering 50k events is costly and the views ask for it many times per render, so reuse the result until an input changes.
    var visibleEvents: [LogEvent] {
        let key = VisibleKey(count: events.count, last: events.last?.id, first: events.first?.id, serial: selectedSerial,
                             kind: kindFilter, search: searchText, crashKinds: crashKinds, allApps: crashAllApps)
        if let c = visibleCache, c.key == key { return c.list }
        let list = computeVisibleEvents()
        visibleCache = (key, list)
        return list
    }
    private func computeVisibleEvents() -> [LogEvent] {
        let tokens = searchTokens
        return events.filter { event in
            (selectedSerial == nil || event.deviceSerial == selectedSerial) &&
            kindFilter.allows(event.kind) &&
            (event.crash.map { (crashAllApps || $0.isGame) && (crashKinds.isEmpty || crashKinds.contains($0.kind)) } ?? true) &&
            Self.matches(event, tokens: tokens)
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
    var selectedEvent: LogEvent? {
        guard let id = selectedEventID else { return nil }
        return visibleEvents.last(where: { $0.id == id })
    }

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
                // Capture and the "is the screen on?" check run together; only a phone that had to be woken pays for a second capture.
                async let woke = adb.wakeScreenIfNeeded(serial: serial)
                async let first: Void = adb.screenshot(serial: serial, to: url)
                let wasAsleep = await woke
                if wasAsleep {
                    setActivity(.working, "📸", "Máy đang tắt màn hình, đã bật sáng lại…")
                    _ = try? await first
                    try await adb.screenshot(serial: serial, to: url)
                } else {
                    try await first
                }
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
                do { activeNotifications = try await adb.fetchActiveNotifications(serial: serial).list; notificationsError = nil }
                catch { notificationsError = error.localizedDescription }
                alarms = r.alarms; alarmsClockOffset = r.deviceNow.timeIntervalSinceNow; alarmsTimeZone = r.timeZone; alarmsCheckedAt = Date()
            }
            catch { alarmsError = error.localizedDescription }
            alarmsLoading = false
        }
    }
    func openNotificationSchedule() {
        alarms = []; activeNotifications = []; alarmsCheckedAt = nil
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
            let gate = StreamGate(token: token) { [weak self] date in
                Task { @MainActor in self?.recordingOpened(serial, at: date) }
            }
            let queue = ingestQueue
            let dump = UploadDumpParser()
            let p = try adb.startLogcat(serial: serial, onLine: { line in
                guard gate.pass(line) else { return }
                if let snap = dump.feed(line) { queue.push(serial, .snapshot(app: snap.app, props: snap.props)) }
                if let item = StudioModel.prepare(line) { queue.push(serial, item) }
            }, onExit: { [weak self] in
                Task { @MainActor in self?.streamEnded(serial, gen: gen) }
            })
            let game = game ?? (auto ? (streamGames[serial] ?? selectedGame) : selectedGame)
            if auto, let old = sessions[serial], old.stoppedMac == nil, old.lostMac != nil { /* resumed: keep the original start */ }
            else { sessions[serial] = RecordingSession(serial: serial, game: game, startLog: Date(), startMac: Date()) }
            streamGen[serial] = gen
            streamGates[serial] = gate
            streamProcesses[serial] = p
            streamingSerials.insert(serial)
            streamGames[serial] = game ?? (auto ? (streamGames[serial] ?? selectedGame) : selectedGame)
            loadPropertyHistory(serial)
            if crashCapture {
                startCrashStream(serial, game: streamGames[serial] ?? selectedGame)
                loadCrashHistory(serial, game: streamGames[serial] ?? selectedGame)
            }
            startNotificationPolling()
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

    private func startCrashStream(_ serial: String, game: GamePackage) {
        stopCrashStream(serial)
        let queue = ingestQueue
        let parser = CrashParser(package: game.rawValue) { queue.push(serial, .crash($0)) }
        do {
            crashProcesses[serial] = try adb.startCrashLogcat(serial: serial) { parser.feed($0) }
            crashParsers[serial] = parser
            Task {
                if let out = try? await adb.run(["-s", serial, "shell", "pidof", game.rawValue]) {
                    parser.addPids(out.split(whereSeparator: \.isWhitespace).map(String.init))
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func stopCrashStream(_ serial: String) {
        crashProcesses.removeValue(forKey: serial)?.terminate()
        crashParsers.removeValue(forKey: serial)?.flushAll()
    }

    /// Crashes that happened before Start (game crashed, phone plugged in afterwards): old crash buffer + DropBox.
    func loadCrashHistory(_ serial: String, game: GamePackage, manual: Bool = false) {
        let queue = ingestQueue
        crashHistoryLoading.insert(serial)
        Task {
            defer { crashHistoryLoading.remove(serial) }
            let h = await adb.fetchCrashHistory(serial: serial)
            await Task.detached {
                let parser = CrashParser(package: game.rawValue) { var r = $0; r.fromHistory = true; queue.push(serial, .crash(r)) }
                for line in h.logcat.split(whereSeparator: \.isNewline) { parser.feed(String(line)) }
                parser.flushAll()
                for r in DropboxParser.parse(dump: h.dropbox, package: game.rawValue) { queue.push(serial, .crash(r)) }
            }.value
            if manual { setActivity(.done, "🔎", "Đã quét crash cũ", detail: "\(deviceName(serial)) · crash tìm thấy hiện ở tab Crashes", clearAfter: 6) }
        }
    }

    // MARK: Notification recorder
    /// While recording, look at the phone's notification list every few seconds and remember each new one,
    /// so a notification stays in the app (and in a text file) after the user swipes it away.
    private func startNotificationPolling() {
        guard notifPollTask == nil else { return }
        notifPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.streamingSerials.isEmpty else { break }
                for serial in self.streamingSerials { await self.pollNotifications(serial) }
                try? await Task.sleep(for: .seconds(5))
            }
            self?.notifPollTask = nil
        }
    }
    private func pollNotifications(_ serial: String) async {
        guard let r = try? await adb.fetchActiveNotifications(serial: serial) else { return }
        let nowIDs = Set(r.list.map { serial + "|" + $0.logID })
        var fresh: [LoggedNotification] = []
        for n in r.list.reversed() where !notificationLogIDs.contains(serial + "|" + n.logID) {
            let l = LoggedNotification(serial: serial, notification: n, goneAt: nil)
            notificationLogIDs.insert(l.id); fresh.append(l)
        }
        for i in notificationLog.indices where notificationLog[i].serial == serial && notificationLog[i].goneAt == nil && !nowIDs.contains(notificationLog[i].id) {
            notificationLog[i].goneAt = r.deviceNow
        }
        guard !fresh.isEmpty else { return }
        notificationLog.insert(contentsOf: fresh.reversed(), at: 0)
        if notificationLog.count > 2000 { notificationLog.removeLast(notificationLog.count - 2000) }
        appendNotificationFile(fresh, serial: serial)
    }
    /// <capture dir>/Notifications/<phone>_<day>.txt, one line per notification.
    private func appendNotificationFile(_ list: [LoggedNotification], serial: String) {
        let dir = captureDirectory.appendingPathComponent("Notifications", isDirectory: true)
        let day = DateFormatter(); day.dateFormat = "yyyyMMdd"
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let safe = deviceName(serial).map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        let url = dir.appendingPathComponent("\(safe)_\(day.string(from: Date())).txt")
        let text = list.map { l -> String in
            let n = l.notification
            return "\(stamp.string(from: n.posted))\t\(n.campaign.isEmpty ? "-" : n.campaign)\t\(n.package)\t\(n.title)\t\(n.text)"
        }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
    func revealNotificationFolder() {
        let dir = captureDirectory.appendingPathComponent("Notifications", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: Performance (FPS, CPU, RAM, temperature)
    /// Samples only while the Performance window is open, so a phone nobody is looking at is not polled.
    func openPerformance() {
        if perfSerial != selectedSerial { perfSamples = []; perfLayer = "" }
        perfSerial = selectedSerial; perfError = nil; perfPaused = false
        showPerf = true
        perfTask?.cancel()
        perfTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.showPerf else { break }
                if !self.perfPaused, let serial = self.selectedSerial { await self.samplePerf(serial) }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
    func closePerformance() { showPerf = false; perfTask?.cancel(); perfTask = nil }
    func clearPerf() { perfSamples = [] }
    private func samplePerf(_ serial: String) async {
        do {
            let out = try await adb.fetchPerf(serial: serial, package: selectedGame.rawValue, layer: perfLayer)
            guard showPerf, serial == selectedSerial else { return }
            let parsed = PerfParser.parse(out)
            var sample = parsed.sample
            perfLayer = sample.running ? (parsed.layer ?? "") : ""
            // The frame list keeps old frames when the game stops drawing: same newest frame as last time = 0 FPS.
            if let prev = perfSamples.last, sample.lastFrameNs != nil, prev.lastFrameNs == sample.lastFrameNs {
                sample.fps = 0; sample.jankPct = nil; sample.maxFrameMs = nil
            }
            perfSamples.append(sample)
            if perfSamples.count > 2400 { perfSamples.removeFirst(perfSamples.count - 2000) }
            perfError = nil
        } catch { perfError = error.localizedDescription }
    }
    func exportPerfCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "performance-\(selectedGame.title.replacingOccurrences(of: " ", with: "-"))-\(Date.now.formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func n(_ v: Double?, _ d: Int = 1) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }
        var rows = ["time,running,fps,jank_pct,max_frame_ms,cpu_pct_of_one_core,cores,rss_mb,threads,cpu_temp_c,battery_temp_c,battery_pct,thermal_status"]
        for s in perfSamples {
            rows.append([f.string(from: s.date), s.running ? "1" : "0", n(s.fps), n(s.jankPct), n(s.maxFrameMs), n(s.cpu), "\(s.cores)", n(s.rssMB),
                         s.threads.map(String.init) ?? "", n(s.cpuTemp), n(s.batteryTemp), s.battery.map(String.init) ?? "", s.thermalStatus.map(String.init) ?? ""].joined(separator: ","))
        }
        do { try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: Memory (dumpsys meminfo)
    func openMeminfo() {
        meminfo = nil; meminfoError = nil; meminfoHistory = []
        showMeminfo = true
        refreshMeminfo()
        meminfoTask?.cancel()
        meminfoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.showMeminfo else { break }
                if self.meminfoAuto { self.refreshMeminfo() }
            }
        }
    }
    func closeMeminfo() { showMeminfo = false; meminfoTask?.cancel(); meminfoTask = nil }
    func refreshMeminfo() {
        guard let serial = selectedSerial, !meminfoLoading else { return }
        meminfoLoading = true
        let package = selectedGame.rawValue
        Task {
            do {
                let m = try await adb.fetchMeminfo(serial: serial, package: package)
                meminfo = m; meminfoError = nil
                if m.running { meminfoHistory.append((m.date, m.totalPSS)); if meminfoHistory.count > 600 { meminfoHistory.removeFirst() } }
            } catch { meminfoError = error.localizedDescription }
            meminfoLoading = false
        }
    }
    func copyMeminfo() {
        guard let m = meminfo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(m.raw + "\n" + m.deviceLines.joined(separator: "\n"), forType: .string)
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
        for p in crashProcesses.values { p.terminate() }
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
    @discardableResult
    private static func killStaleLogcat() -> Int {
        let ps = Process()
        let out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        var killed = 0
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, parts[1] == "1", (parts[2].contains(" logcat -T 1 -v time -s FA FA-SVC \(ADBService.markerTag):I") || parts[2].contains(" logcat -v time -s FA FA-SVC \(ADBService.markerTag):I")
                            || parts[2].contains(" logcat -T 1 -v threadtime -b main,system,crash ")),
                  let pid = Int32(parts[0]) else { continue }
            if kill(pid, SIGTERM) == 0 { killed += 1 }
        }
        return killed
    }

    /// Cleans every leftover this app can leave: orphaned `adb logcat` clients on the Mac (any phone) and logcat processes
    /// still running on connected phones that this app is not streaming from right now.
    func cleanupStaleProcesses(manual: Bool = false) {
        let mac = Self.killStaleLogcat()
        let idle = devices.filter { $0.state == "device" && !streamingSerials.contains($0.serial) }.map(\.serial)
        Task {
            var phone = 0
            for serial in idle { phone += await adb.killStaleOnDevice(serial: serial) }
            if manual || mac + phone > 0 {
                setActivity(.done, "🧹", mac + phone == 0 ? "Không có tiến trình cũ nào" : "Đã dọn \(mac + phone) tiến trình cũ",
                            detail: "Trên Mac: \(mac) · trên điện thoại: \(phone)", clearAfter: 6)
            }
        }
    }

    /// Wipes everything this session collected in the app (events, crashes, recorded notifications, performance and memory
    /// samples). Phone logs are untouched.
    func resetSession() {
        events.removeAll(); selectedEventID = nil
        sessions = sessions.filter { streamingSerials.contains($0.key) }
        notificationLog = []; notificationLogIDs = []; activeNotifications = []
        perfSamples = []; meminfoHistory = []; meminfo = nil
        skippedLines = 0
        setActivity(.done, "🧹", "Đã xoá toàn bộ dữ liệu phiên trong app", detail: "Log trên máy vẫn còn nguyên; file đã lưu không bị xoá", clearAfter: 5)
    }

    func deviceLabel(_ serial: String) -> String { deviceName(serial) }
    private func deviceName(_ serial: String) -> String {
        let model = devices.first { $0.serial == serial }?.model.replacingOccurrences(of: "_", with: " ") ?? ""
        return model.isEmpty ? serial : model
    }

    /// The adb logcat process ended on its own (device unplugged, adb restarted…); ignore ends we caused ourselves.
    /// The start marker came back from the phone: recording really began at `date` (phone clock, same as event times).
    private func recordingOpened(_ serial: String, at date: Date?) {
        guard var s = sessions[serial], s.stoppedMac == nil else { return }
        let t = date ?? Date()
        if let lost = s.lostMac {
            let gap = ScheduledAlarm.duration(Date().timeIntervalSince(lost))
            s.gapText = "↻ Mất kết nối \(gap), nối lại lúc \(LogEvent.clockFormatter.string(from: t).dropLast(4)); log trong lúc mất kết nối không có"
            s.lostMac = nil
        } else {
            s.startLog = t
            // Anything that slipped in before the real start time was known (the live stream replays one old line) gets the tag too.
            for i in events.indices where events[i].deviceSerial == serial && !events[i].beforeStart && events[i].date < t.addingTimeInterval(-1) { events[i].beforeStart = true }
        }
        sessions[serial] = s
    }

    private func streamEnded(_ serial: String, gen: UUID) {
        guard streamGen[serial] == gen else { return }
        sessions[serial]?.lostMac = Date()
        streamGen[serial] = nil
        streamGates[serial]?.close(); streamGates[serial] = nil
        streamProcesses[serial] = nil
        stopCrashStream(serial)
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
        sessions[serial]?.stoppedMac = Date()
        streamGen[serial] = nil
        streamGates[serial]?.close(); streamGates[serial] = nil
        wantedSerials.remove(serial)
        manuallyStopped.insert(serial)
        stopCrashStream(serial)
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
        for p in crashParsers.values { p.flushIdle() }
        var history: [(serial: String, report: CrashReport)] = []
        for (serial, item) in ingestQueue.drain() {
            if case .crash(let r) = item, r.fromHistory { history.append((serial, r)) } else { ingest(item, serial: serial) }
        }
        if !history.isEmpty { ingestHistoryCrashes(history) }
    }

    /// Old crashes arrive in bulk (a big log can hold hundreds): dedupe against an index built once and merge with one sort,
    /// instead of scanning and inserting into the 50k-event list per crash.
    private func ingestHistoryCrashes(_ items: [(serial: String, report: CrashReport)]) {
        var seen: [String: [(kind: CrashKind, isGame: Bool, date: Date)]] = [:]
        for e in events where e.kind == .crash {
            if let c = e.crash { seen[e.deviceSerial, default: []].append((c.kind, c.isGame, e.date)) }
        }
        var fresh: [LogEvent] = []
        for (serial, r) in items where r.isGame || crashAllApps {
            if seen[serial]?.contains(where: { $0.kind == r.kind && $0.isGame == r.isGame && abs($0.date.timeIntervalSince(r.date)) < 10 }) == true { continue }
            seen[serial, default: []].append((r.kind, r.isGame, r.date))
            fresh.append(makeCrashEvent(r, serial: serial))
        }
        guard !fresh.isEmpty else { return }
        events.append(contentsOf: fresh)
        events.sort { $0.date < $1.date }   // stable enough: same-date order is irrelevant here
        if events.count > 51000 { events.removeFirst(events.count - 50000) }
    }

    private func ingest(_ item: Prepared, serial: String) {
        switch item {
        case .unreadable(let raw):
            skippedLines += 1
            lastSkippedLine = raw
        case .crash(let r):
            ingestCrash(r, serial: serial)
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
            var ev = LogEvent(date: date, deviceSerial: serial, tag: tag, raw: raw, name: name, params: params, kind: kind)
            if let start = sessions[serial]?.startLog, date < start.addingTimeInterval(-1) { ev.beforeStart = true }
            events.append(ev)
            if events.count > 51000 { events.removeFirst(events.count - 50000) }
        }
    }
    private func ingestCrash(_ r: CrashReport, serial: String) {
        guard r.isGame || crashAllApps else { return }
        let ev = makeCrashEvent(r, serial: serial)
        let info = ev.crash
        if let idx = events.lastIndex(where: { $0.date <= r.date }) { events.insert(ev, at: idx + 1) } else { events.insert(ev, at: 0) }
        if events.count > 51000 { events.removeFirst(events.count - 50000) }
        if r.isGame, !r.fromHistory, r.kind != .other {   // "Other" (stray exception lines) is listed but does not raise the red alert
            setActivity(.error, "💥", "\(r.kind.rawValue): \(String(r.title.prefix(70)))",
                        detail: "\(deviceName(serial))" + (info?.file.map { " · đã lưu \($0.lastPathComponent)" } ?? ""),
                        file: info?.file, clearAfter: 14)
        }
    }

    private func makeCrashEvent(_ r: CrashReport, serial: String) -> LogEvent {
        var info = CrashInfo(kind: r.kind, package: r.package, pid: r.pid, isGame: r.isGame, file: nil)
        let raw = r.lines.joined(separator: "\n")
        if crashAutoSave, let saved = saveCrash(r, raw: raw, serial: serial) {
            info.file = saved.url
            if saved.isNew { appendCrashContext(to: saved.url, report: r, serial: serial) }
        }
        var params = [EventParam(key: "type", value: r.kind.rawValue)]
        if let p = r.package { params.append(EventParam(key: "package", value: p)) }
        params.append(EventParam(key: "pid", value: r.pid))
        if r.fromHistory { params.append(EventParam(key: "source", value: "đọc lại từ máy")) }
        var ev = LogEvent(date: r.date, deviceSerial: serial, tag: r.kind.rawValue, raw: raw, name: r.title,
                          params: params, kind: .crash, crash: info)
        if let start = sessions[serial]?.startLog, r.date < start.addingTimeInterval(-1) { ev.beforeStart = true }
        return ev
    }

    /// After the crash file is written: add the phone, app version, free RAM, the process's last log lines and the Firebase events before it.
    private func appendCrashContext(to url: URL, report r: CrashReport, serial: String) {
        let before = events.filter { $0.deviceSerial == serial && $0.kind != .crash && $0.date <= r.date }.suffix(12).map { e in
            "\(e.date.formatted(date: .omitted, time: .standard))  \(e.name)  " + e.params.filter { !$0.isInternal }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        let package = r.package ?? ""
        Task {
            if !r.fromHistory { try? await Task.sleep(for: .seconds(1.5)) }   // let the crash finish writing its last lines
            var ctx = await adb.crashContext(serial: serial, package: package, pid: r.fromHistory ? nil : r.pid)
            if !before.isEmpty { ctx += "\n-- Event Firebase trước crash (app đã ghi) --\n" + before.joined(separator: "\n") + "\n" }
            let text = "\n======== CONTEXT ========\n" + ctx
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        }
    }

    /// <capture dir>/Crashes/<game>/<phone>_<time>_<kind>.txt, one file per crash.
    private func saveCrash(_ r: CrashReport, raw: String, serial: String) -> (url: URL, isNew: Bool)? {
        let game = GamePackage(rawValue: r.package ?? "")?.title ?? (r.package ?? "Other apps")
        let dir = captureDirectory.appendingPathComponent("Crashes", isDirectory: true).appendingPathComponent(game, isDirectory: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let safe = serial.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        let base = "\(safe)_\(f.string(from: r.date))_\(r.kind.rawValue)"
        let header = """
        Type:    \(r.kind.rawValue)
        Summary: \(r.title)
        Device:  \(deviceName(serial)) (\(serial))
        Package: \(r.package ?? "unknown")
        PID:     \(r.pid)
        Time:    \(r.date.formatted(date: .abbreviated, time: .standard))
        ----------------------------------------

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir.appendingPathComponent(base + ".txt"), n = 2
            // A crash read back from the phone may already have been saved by an earlier Start: reuse that file.
            if r.fromHistory, FileManager.default.fileExists(atPath: url.path) { return (url, false) }
            while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(base)-\(n).txt"); n += 1 }
            try (header + raw + "\n").write(to: url, atomically: true, encoding: .utf8)
            return (url, true)
        } catch { return nil }
    }

    /// Crashes of the chosen phone per kind (honours the "All apps" switch), for the filter chips.
    var crashCounts: [CrashKind: Int] {
        let key = "\(events.count)|\(events.last?.id.uuidString ?? "")|\(events.first?.id.uuidString ?? "")|\(selectedSerial ?? "")|\(crashAllApps)"
        if let c = crashCountsCache, c.key == key { return c.counts }
        var out: [CrashKind: Int] = [:]
        for e in events { if let c = e.crash, selectedSerial == nil || e.deviceSerial == selectedSerial, crashAllApps || c.isGame { out[c.kind, default: 0] += 1 } }
        crashCountsCache = (key, out)
        return out
    }
    private var crashCountsCache: (key: String, counts: [CrashKind: Int])?
    func revealCrashFolder() {
        let dir = captureDirectory.appendingPathComponent("Crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    nonisolated private static let dateRE = try! NSRegularExpression(pattern: #"^(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.(\d{3})"#)
    nonisolated static func parseDate(_ line: String) -> Date? {
        // logcat -v time: MM-DD HH:mm:ss.SSS
        guard let mt = dateRE.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func n(_ i: Int) -> Int? { Range(mt.range(at: i), in: line).flatMap { Int(line[$0]) } }
        guard let mo = n(1), let d = n(2), let h = n(3), let mi = n(4), let s = n(5), let ms = n(6) else { return nil }
        var c = DateComponents()
        c.year = Calendar.current.component(.year, from: Date()); c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return Calendar.current.date(from: c).map { $0.addingTimeInterval(Double(ms) / 1000) }
    }
}
