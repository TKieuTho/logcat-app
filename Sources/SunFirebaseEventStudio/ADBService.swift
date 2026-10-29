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

    private func run(_ arguments: [String]) async throws -> String {
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

    func startLogcat(serial: String, onLine: @escaping @Sendable (String) -> Void) throws -> Process {
        guard let adbPath else { throw NSError(domain: "ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: "ADB is not ready yet."]) }
        let p = Process()
        let pipe = Pipe()
        p.executableURL = adbPath
        p.arguments = ["-s", serial, "logcat", "-v", "time", "-s", "FA", "FA-SVC", "\(Self.markerTag):I"]
        p.standardOutput = pipe
        p.standardError = pipe
        // A read can end mid-line; keep the tail until its newline arrives so no event is split or lost.
        let pending = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; pending.flush().forEach(onLine); return }
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
            if let s = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .newlines), !s.isEmpty { lines.append(s) }
        }
        return lines
    }
    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        defer { tail.removeAll() }
        guard let s = String(data: tail, encoding: .utf8)?.trimmingCharacters(in: .newlines), !s.isEmpty else { return [] }
        return [s]
    }
}
