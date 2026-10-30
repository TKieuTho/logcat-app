import Foundation

@MainActor
final class ADBService: ObservableObject {
    @Published private(set) var devices: [ADBDevice] = []
    @Published private(set) var status = "Checking Android Platform Tools…"
    @Published private(set) var adbPath: URL?
    @Published private(set) var isBootstrapping = false

    private var pollTask: Task<Void, Never>?

    init() {
        Task { await prepareADB(); await refreshDevices() }
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await refreshDevices()
            }
        }
    }

    deinit { pollTask?.cancel() }

    func prepareADB() async {
        isBootstrapping = true
        defer { isBootstrapping = false }
        if let found = findADB() {
            adbPath = found
            status = "Android Platform Tools ready"
            return
        }

        // No Terminal needed: fetch Google's official macOS Platform Tools on first launch.
        status = "Downloading Android Platform Tools…"
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SunFirebaseEventStudio/ platform-tools".replacingOccurrences(of: "/ ", with: "/"), isDirectory: true)
            try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            let zipURL = base.deletingLastPathComponent().appendingPathComponent("platform-tools.zip")
            let source = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
            let (temporary, response) = try await URLSession.shared.download(from: source)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "ADBBootstrap", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))."])
            }
            try? FileManager.default.removeItem(at: zipURL)
            try FileManager.default.moveItem(at: temporary, to: zipURL)
            try? FileManager.default.removeItem(at: base)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zipURL.path, base.deletingLastPathComponent().path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let found = findADB() else {
                throw NSError(domain: "ADBBootstrap", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not unpack Android Platform Tools."])
            }
            adbPath = found
            status = "Android Platform Tools ready"
            try? FileManager.default.removeItem(at: zipURL)
        } catch {
            status = "ADB setup failed: \(error.localizedDescription)"
        }
    }

    private func findADB() -> URL? {
        let fm = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("platform-tools/adb")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SunFirebaseEventStudio/platform-tools/adb")
        let candidates = [bundled, appSupport, URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
                          URL(fileURLWithPath: "/usr/local/bin/adb")]
        return candidates.compactMap { $0 }.first { fm.isExecutableFile(atPath: $0.path) }
    }

    func run(_ arguments: [String]) async throws -> String {
        guard let adbPath else { throw NSError(domain: "ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: "ADB is not ready yet."]) }
        return try await Task.detached(priority: .userInitiated) {
            let p = Process()
            let output = Pipe()
            p.executableURL = adbPath
            p.arguments = arguments
            p.standardOutput = output
            p.standardError = output
            try p.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let result = String(data: data, encoding: .utf8) ?? ""
            if p.terminationStatus != 0 {
                throw NSError(domain: "ADB", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: result.isEmpty ? "ADB command failed." : result])
            }
            return result
        }.value
    }

    func refreshDevices() async {
        guard adbPath != nil else { return }
        do {
            let output = try await run(["devices", "-l"])
            let lines = output.components(separatedBy: .newlines).dropFirst()
            var next: [ADBDevice] = []
            for line in lines {
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 2, parts[0] != "List", parts[1] == "device" || parts[1] == "unauthorized" else { continue }
                let modelPart = parts.first(where: { $0.hasPrefix("model:") })?.replacingOccurrences(of: "model:", with: "") ?? ""
                next.append(ADBDevice(serial: parts[0], state: parts[1], model: modelPart))
            }
            devices = next
            status = next.isEmpty ? "Connect an Android device with USB debugging enabled" : "\(next.count) device(s) detected"
        } catch { status = error.localizedDescription }
    }

    /// Which game the device is set up to debug, and whether FA / FA-SVC logging is already verbose.
    func debugSetup(serial: String) async -> (app: String, verbose: Bool) {
        func prop(_ n: String) async -> String {
            ((try? await run(["-s", serial, "shell", "getprop", n])) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let app = await prop("debug.firebase.analytics.app")
        let fa = await prop("log.tag.FA"), svc = await prop("log.tag.FA-SVC")
        return (app, fa == "VERBOSE" && svc == "VERBOSE")
    }

    func configureFirebase(serial: String, package: GamePackage) async throws {
        _ = try await run(["-s", serial, "shell", "setprop", "debug.firebase.analytics.app", package.rawValue])
        _ = try await run(["-s", serial, "shell", "setprop", "log.tag.FA", "VERBOSE"])
        _ = try await run(["-s", serial, "shell", "setprop", "log.tag.FA-SVC", "VERBOSE"])
    }

    func launchGame(serial: String, package: GamePackage) async throws {
        _ = try await run(["-s", serial, "shell", "am", "force-stop", package.rawValue])
        _ = try await run(["-s", serial, "shell", "monkey", "-p", package.rawValue, "-c", "android.intent.category.LAUNCHER", "1"])
    }

    func clearDeviceLogBuffer(serial: String) async throws {
        _ = try await run(["-s", serial, "logcat", "-c"])
    }

    static let markerTag = "LOGCATAPP"

    /// Writes a marker line into the device log; the app ignores everything before it so only post-Start events show.
    func sendStartMarker(serial: String, token: String) async throws {
        _ = try await run(["-s", serial, "shell", "log", "-t", Self.markerTag, "-p", "i", token])
    }

    /// Live stream: `-T 1` starts at the newest entry instead of replaying the whole buffer (hundreds of thousands of lines on some phones).
    /// With `history: true` it instead dumps the buffer once (`-d`) and ends; `onEnd` fires after the last line was delivered.
    func startLogcat(serial: String, history: Bool = false, onLine: @escaping @Sendable (String) -> Void,
                     onExit: @escaping @Sendable () -> Void = {}, onEnd: (@Sendable () -> Void)? = nil) throws -> Process {
        guard let adbPath else { throw NSError(domain: "ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: "ADB is not ready yet."]) }
        let p = Process()
        let pipe = Pipe()
        p.executableURL = adbPath
        p.arguments = history
            ? ["-s", serial, "logcat", "-d", "-v", "time", "-s", "FA", "FA-SVC"]
            : ["-s", serial, "logcat", "-T", "1", "-v", "time", "-s", "FA", "FA-SVC", "\(Self.markerTag):I"]
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { _ in onExit() }
        // A read can end mid-line; keep the tail until its newline arrives so no event is split or lost.
        let pending = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; pending.flush().forEach(onLine); onEnd?(); return }
            pending.append(data).forEach(onLine)
        }
        try p.run()
        return p
    }
}

final class LineBuffer: @unchecked Sendable {
    private var tail = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        tail.append(data)
        var lines: [String] = []
        while let nl = tail.firstIndex(of: 0x0A) {
            let line = tail[tail.startIndex..<nl]
            tail.removeSubrange(tail.startIndex...nl)
            // Lossy decode: one bad byte must not make an event line vanish.
            let s = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
            if !s.isEmpty { lines.append(s) }
        }
        return lines
    }
    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        defer { tail.removeAll() }
        let s = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .newlines)
        return s.isEmpty ? [] : [s]
    }
}

extension ADBService {
    /// A sleeping screen records nothing (screenrecord fails) and screenshots come out black; wake it first.
    /// Returns true when it had to be woken. WAKEUP is ignored by some phones (Motorola), so fall back to POWER, which is only safe because we know it is off.
    @discardableResult
    func wakeScreenIfNeeded(serial: String) async -> Bool {
        func awake() async -> Bool {
            ((try? await run(["-s", serial, "shell", "dumpsys power | grep -m1 mWakefulness="])) ?? "").contains("Awake")
        }
        if await awake() { return false }
        _ = try? await run(["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        try? await Task.sleep(for: .seconds(1))
        if !(await awake()) {
            _ = try? await run(["-s", serial, "shell", "input", "keyevent", "KEYCODE_POWER"])
            try? await Task.sleep(for: .seconds(1))
        }
        // The panel needs a moment after waking before frames are real (screenshots are black until then).
        try? await Task.sleep(for: .seconds(2))
        return true
    }

    /// `exec-out screencap -p` streams a PNG over stdout; written straight to `url`.
    func screenshot(serial: String, to url: URL) async throws {
        guard let adbPath else { throw NSError(domain: "ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: "ADB is not ready yet."]) }
        try await Task.detached {
            let p = Process()
            let out = Pipe()
            p.executableURL = adbPath
            p.arguments = ["-s", serial, "exec-out", "screencap", "-p"]
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, data.count > 100 else {
                throw NSError(domain: "ADB", code: 3, userInfo: [NSLocalizedDescriptionKey: "Không chụp được màn hình (máy có thể đang khóa hoặc app chặn chụp)."])
            }
            try data.write(to: url)
        }.value
    }

    /// Recording runs on the device (Android caps one segment at 3 minutes); `onExit` fires when it ends for any reason.
    func startRecording(serial: String, remote: String, onExit: @escaping @Sendable (Int32, String) -> Void) throws -> Process {
        guard let adbPath else { throw NSError(domain: "ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: "ADB is not ready yet."]) }
        let p = Process()
        let pipe = Pipe()
        p.executableURL = adbPath
        p.arguments = ["-s", serial, "shell", "screenrecord", "--time-limit", "180", remote]
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { proc in
            let text = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            onExit(proc.terminationStatus, text)
        }
        try p.run()
        return p
    }

    /// SIGINT lets screenrecord finalize the mp4; killing the adb client instead would leave a broken file.
    func stopRecording(serial: String) async {
        _ = try? await run(["-s", serial, "shell", "kill -2 $(pidof screenrecord)"])
    }

    func pullAndRemove(serial: String, remote: String, to url: URL) async throws {
        _ = try await run(["-s", serial, "pull", remote, url.path])
        _ = try? await run(["-s", serial, "shell", "rm", remote])
    }

    func fetchAlarms(serial: String, package: String) async throws -> [ScheduledAlarm] {
        let dump = try await run(["-s", serial, "shell", "dumpsys", "alarm"])
        return await Task.detached { AlarmParser.parse(dump: dump, package: package) }.value
    }
}
