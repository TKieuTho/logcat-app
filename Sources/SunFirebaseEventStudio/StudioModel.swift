import Foundation
import SwiftUI
import Combine
import AppKit

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
    @Published var errorMessage: String?
    @Published var selectedEventID: UUID?
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
    var lastSkippedLine = ""

    private let adb = ADBService()
    private var streamProcesses: [String: Process] = [:]
    private var streamingSerials = Set<String>()
    /// Per serial: marker token sent at Start; nil once the marker came back and live events may flow.
    private var pendingMarkers: [String: String] = [:]
    private var serviceObservation: Any?

    init() {
        adb.$devices.receive(on: RunLoop.main).sink { [weak self] in self?.devices = $0 }.store(in: &cancellables)
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
    func installUpdate() {
        guard let info = updateInfo, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        statusText = "Đang tải bản \(info.version)…"
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

    func requestSetup() { showSetupConfirmation = true }
    func confirmSetup() {
        guard let serial = selectedSerial else { return }
        Task {
            do {
                try await adb.configureFirebase(serial: serial, package: selectedGame)
                startStream(for: serial)
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
    func startAllStreams() {
        for device in devices where device.state == "device" {
            startStream(for: device.serial)
        }
    }
    func startStream(for serial: String) {
        guard !streamingSerials.contains(serial) else { return }
        do {
            let p = try adb.startLogcat(serial: serial) { [weak self] line in
                Task { @MainActor in self?.ingest(line, serial: serial) }
            }
            let token = "START_\(UUID().uuidString)"
            pendingMarkers[serial] = token
            streamProcesses[serial] = p
            streamingSerials.insert(serial)
            Task {
                do { try await adb.sendStartMarker(serial: serial, token: token) }
                catch { pendingMarkers[serial] = nil }
                try? await Task.sleep(for: .seconds(8))
                if pendingMarkers[serial] == token { pendingMarkers[serial] = nil }
            }
            isStreaming = !streamingSerials.isEmpty
            statusText = "Streaming FA / FA-SVC from \(streamingSerials.count) device(s)"
        } catch { errorMessage = error.localizedDescription }
    }
    func stopStream() {
        guard let serial = selectedSerial else { return }
        stopStream(for: serial)
    }
    func stopStream(for serial: String) {
        if let process = streamProcesses[serial] {
            process.terminate()
            streamProcesses.removeValue(forKey: serial)
        }
        streamingSerials.remove(serial)
        pendingMarkers[serial] = nil
        isStreaming = !streamingSerials.isEmpty
        statusText = isStreaming ? "Streaming FA / FA-SVC from \(streamingSerials.count) device(s)" : "Not streaming"
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
    private func ingest(_ line: String, serial: String) {
        if let token = pendingMarkers[serial] {
            if line.contains(token) { pendingMarkers[serial] = nil }
            return
        }
        if line.contains(ADBService.markerTag) { return }
        guard let parsed = LogEvent.parse(raw: line) else {
            let l = line.lowercased()
            if l.contains("logging event") || l.contains("user property") || l.contains("event recorded") {
                skippedLines += 1
                lastSkippedLine = line
            }
            return
        }
        let date = Self.parseDate(line) ?? Date()
        // FA logs one event in several flavours (Logging event / Event recorded); drop only those cross-flavour copies.
        // Identical repeats in the same flavour are genuine separate sends and are kept.
        let key = Self.sourceKey(line)
        let sig = Set(parsed.params.filter { !$0.isInternal }.map { "\($0.key)=\($0.value)" })
        if events.suffix(40).contains(where: { $0.deviceSerial == serial && $0.kind == parsed.kind && $0.name == parsed.name &&
            Self.sourceKey($0.raw) != key && abs($0.date.timeIntervalSince(date)) < 1 &&
            Set($0.params.filter { !$0.isInternal }.map { "\($0.key)=\($0.value)" }) == sig }) { return }
        let tag = line.contains("FA-SVC") ? "FA-SVC" : "FA"
        events.append(LogEvent(date: date, deviceSerial: serial, tag: tag, raw: line, name: parsed.name, params: parsed.params, kind: parsed.kind))
        if events.count > 50000 { events.removeFirst(events.count - 50000) }
    }
    private static func parseDate(_ line: String) -> Date? {
        // logcat -v time: MM-DD HH:mm:ss.SSS
        let pattern = #"^(\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2}\.\d{3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r1 = Range(match.range(at: 1), in: line),
              let r2 = Range(match.range(at: 2), in: line) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.date(from: "\(Calendar.current.component(.year, from: Date()))-\(line[r1]) \(line[r2])")
    }
}
