import Foundation
import CoreGraphics
import ImageIO

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
            if devices != next { devices = next }
            let text = next.isEmpty ? "Connect an Android device with USB debugging enabled" : "\(next.count) device(s) detected"
            if status != text { status = text }
        } catch { if status != error.localizedDescription { status = error.localizedDescription } }
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

extension ADBService {
    /// Separate stream for crashes: Java fatals, native tombstones, ANRs, Unity exceptions, process kills.
    /// Only the tags that can carry them are opened below warning level, so the volume stays small.
    func startCrashLogcat(serial: String, onLine: @escaping @Sendable (String) -> Void) throws -> Process {
        guard let adbPath else { throw NSError(domain: "ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: "ADB is not ready yet."]) }
        let p = Process()
        let pipe = Pipe()
        p.executableURL = adbPath
        p.arguments = ["-s", serial, "logcat", "-T", "1", "-v", "threadtime", "-b", "main,system,crash",
                       "*:W", "DEBUG:I", "libc:I", "ActivityManager:I", "lmkd:I", "AndroidRuntime:I"]
        p.standardOutput = pipe
        p.standardError = pipe
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

    /// Raw `screencap` (no `-p`) skips the slow on-phone PNG compression: the phone just streams RGBA over USB and the Mac encodes the PNG.
    /// Falls back to `screencap -p` when the raw header is not a plain RGBA_8888 frame (HDR / wide-colour panels).
    func screenshot(serial: String, to url: URL) async throws {
        guard let adbPath else { throw NSError(domain: "ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: "ADB is not ready yet."]) }
        try await Task.detached {
            func capture(_ args: [String]) throws -> Data {
                let p = Process()
                let out = Pipe()
                p.executableURL = adbPath
                p.arguments = ["-s", serial, "exec-out"] + args
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0, data.count > 100 else {
                    throw NSError(domain: "ADB", code: 3, userInfo: [NSLocalizedDescriptionKey: "Không chụp được màn hình (máy có thể đang khóa hoặc app chặn chụp)."])
                }
                return data
            }
            if let raw = try? capture(["screencap"]), let png = Self.pngFromRawScreencap(raw) {
                try png.write(to: url)
            } else {
                try capture(["screencap", "-p"]).write(to: url)
            }
        }.value
    }

    /// Header is width, height, format (+ colour space on Android 10+) as little-endian UInt32; the rest is the pixels.
    nonisolated static func pngFromRawScreencap(_ data: Data) -> Data? {
        guard data.count > 16 else { return nil }
        func u32(_ i: Int) -> Int { data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: i, as: UInt32.self)) } }
        let w = u32(0), h = u32(4), format = u32(8)
        guard format == 1, w > 0, h > 0, w < 10_000, h < 10_000 else { return nil }   // 1 = RGBA_8888
        let header = data.count - w * h * 4
        guard header == 12 || header == 16 else { return nil }
        let pixels = data.subdata(in: header..<data.count)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
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

    /// Alarms plus the phone's own clock: QA phones are often set to another date/time zone, and every
    /// countdown has to be measured against the phone's "now", not the Mac's.
    func fetchAlarms(serial: String, package: String) async throws -> (alarms: [ScheduledAlarm], deviceNow: Date, timeZone: TimeZone) {
        let (deviceNow, tz) = try await deviceClock(serial: serial)
        let dump = try await run(["-s", serial, "shell", "dumpsys", "alarm"])
        let alarms = await Task.detached { AlarmParser.parse(dump: dump, package: package, now: deviceNow) }.value
        return (alarms, deviceNow, tz)
    }

    /// Notifications currently shown on the phone, with when each was first posted, plus the phone's own "now".
    func fetchActiveNotifications(serial: String) async throws -> (list: [ActiveNotification], deviceNow: Date) {
        let out = try await run(["-s", serial, "shell", "date +%s; dumpsys notification --noredact"])
        let now = out.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        let deviceNow = TimeInterval(now).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let list = await Task.detached { ActiveNotificationParser.parse(dump: out) }.value
        return (list, deviceNow)
    }

    /// `dumpsys meminfo` of one app plus the phone's total / free RAM lines.
    func fetchMeminfo(serial: String, package: String) async throws -> MemInfoSnapshot {
        let app = try await run(["-s", serial, "shell", "dumpsys meminfo \(package); exit 0"])
        let device = (try? await run(["-s", serial, "shell", "dumpsys meminfo | grep -E 'Total RAM|Free RAM|Used RAM|Lost RAM|ZRAM'; exit 0"])) ?? ""
        return await Task.detached { MemInfoParser.parse(package: package, app: app, device: device) }.value
    }

    /// Everything the phone still remembers about old crashes: the crash/main/system logcat buffers and DropBox.
    func fetchCrashHistory(serial: String) async -> (logcat: String, dropbox: String) {
        let log = (try? await run(["-s", serial, "logcat", "-d", "-v", "threadtime", "-b", "main,system,crash",
                                   "*:W", "DEBUG:I", "libc:I", "ActivityManager:I", "lmkd:I", "AndroidRuntime:I"])) ?? ""
        let box = (try? await run(["-s", serial, "shell",
            "for t in data_app_crash data_app_anr data_app_native_crash system_app_crash SYSTEM_TOMBSTONE; do dumpsys dropbox --print $t; done; exit 0"])) ?? ""
        return (log, box)
    }

    /// Facts worth having next to a crash: phone, app version, free RAM and (for a live crash) the process's last log lines.
    func crashContext(serial: String, package: String, pid: String?) async -> String {
        func sh(_ c: String) async -> String { ((try? await run(["-s", serial, "shell", c + "; exit 0"])) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = ""
        let p = await sh("getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk").components(separatedBy: "\n")
        if p.count >= 4 { out += "Phone:   \(p[0]) \(p[1]) · Android \(p[2]) (SDK \(p[3]))\n" }
        if !package.isEmpty {
            let v = await sh("dumpsys package \(package) 2>/dev/null | grep -E 'versionName|versionCode' | head -2").components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "  ")
            if !v.isEmpty { out += "App:     \(package)  \(v)  (phiên bản đang cài lúc đọc)\n" }
        }
        let mem = await sh("dumpsys meminfo | grep -E 'Total RAM|Free RAM|Used RAM|Lost RAM'")
        if !mem.isEmpty { out += "RAM của máy (lúc đọc):\n" + mem.components(separatedBy: "\n").map { "  " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") + "\n" }
        if let pid, !pid.isEmpty, pid != "?" {
            let log = await sh("logcat -d -v threadtime --pid=\(pid) -t 250")
            if !log.isEmpty { out += "\n-- 250 dòng log cuối của process \(pid) --\n" + log + "\n" }
        }
        return out
    }

    /// One round trip for everything the Performance window shows. `layer` is the SurfaceFlinger layer found last time ("" = look it up).
    func fetchPerf(serial: String, package: String, layer: String) async throws -> String {
        let script = """
        P=\(package); LAYER='\(layer)'; PID=$(pidof $P | cut -d' ' -f1); echo "---PID"; echo "$PID"
        if [ -n "$PID" ]; then
          echo "---TOP"; top -b -n 1 -p $PID 2>&1 | head -12
          echo "---STATUS"; grep -E "VmRSS|Threads" /proc/$PID/status
          if [ -z "$LAYER" ]; then
            LAYER=$(dumpsys SurfaceFlinger --list | grep -oE "SurfaceView\\[$P/[^]]*\\]\\(BLAST\\)#[0-9]+" | head -1)
            [ -z "$LAYER" ] && LAYER=$(dumpsys SurfaceFlinger --list | grep -oE "$P/[A-Za-z0-9_.]*#[0-9]+" | head -1)
          fi
          echo "---LAYER"; echo "$LAYER"
          echo "---LAT"; [ -n "$LAYER" ] && dumpsys SurfaceFlinger --latency "$LAYER"
        fi
        echo "---THERMAL"; dumpsys thermalservice | grep -E "Thermal Status|mName=(CPU|GPU|SKIN)" | head -4
        echo "---BATT"; dumpsys battery | grep -E "level|temperature"
        exit 0
        """
        return try await run(["-s", serial, "shell", script])
    }

    /// Kills logcat processes this app started on the phone that nobody is reading any more (the Mac side died without cleaning up).
    /// Only call for a phone the app is not streaming from. The `[C]` / `[h]` brackets keep the shell from matching itself.
    func killStaleOnDevice(serial: String) async -> Int {
        let script = """
        n=0; for pid in $(ps -A -o PID,ARGS | grep -E "logcat -T 1 -v time -s FA FA-SV[C]|logcat -T 1 -v threadtime -b main,system,cras[h]" | grep -v grep | sed 's/^ *//' | cut -d' ' -f1); do kill $pid && n=$((n+1)); done; echo $n; exit 0
        """
        let out = (try? await run(["-s", serial, "shell", script])) ?? ""
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last ?? "0") ?? 0
    }

    private func deviceClock(serial: String) async throws -> (now: Date, timeZone: TimeZone) {
        let clock = try await run(["-s", serial, "shell", "date +%s; getprop persist.sys.timezone"])
        let lines = clock.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let now = lines.first.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let tz = lines.dropFirst().first.flatMap { TimeZone(identifier: $0) } ?? .current
        return (now, tz)
    }
}
