import Foundation

enum CrashKind: String, CaseIterable, Identifiable, Hashable {
    case fatal = "Fatal", native = "Native", anr = "ANR", unity = "Unity", died = "Died", oom = "OOM", other = "Other"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .fatal: return "exclamationmark.octagon.fill"
        case .native: return "cpu"
        case .anr: return "hourglass"
        case .unity: return "cube.fill"
        case .died: return "xmark.circle.fill"
        case .oom: return "memorychip"
        case .other: return "exclamationmark.triangle.fill"
        }
    }
    var hint: String {
        switch self {
        case .fatal: return "FATAL EXCEPTION (Java/Kotlin crash)"
        case .native: return "Native crash: SIGSEGV, SIGABRT, tombstone"
        case .anr: return "ANR: app không phản hồi"
        case .unity: return "Unity / IL2CPP exception"
        case .died: return "Process bị kill / died"
        case .oom: return "Hết RAM: OutOfMemoryError, lmkd kill"
        case .other: return "Exception khác (System.err, StrictMode…)"
        }
    }
}

struct CrashInfo: Hashable {
    let kind: CrashKind
    let package: String?
    let pid: String?
    /// Belongs to the game the phone is set up for (or its process); the rest is only shown with "All apps".
    let isGame: Bool
    var file: URL?
}

/// One finished crash block, produced on the reader thread.
struct CrashReport {
    let kind: CrashKind
    let date: Date
    let title: String
    let package: String?
    let pid: String
    let isGame: Bool
    let lines: [String]
    /// Read from the phone's old log / DropBox when Start was pressed, not seen live.
    var fromHistory = false
}

/// Groups the multi-line crash output of `adb logcat -v threadtime` (stack traces, tombstones, ANR dumps) into one report each.
final class CrashParser: @unchecked Sendable {
    private struct Header { let date: Date; let pid: String; let level: Character; let tag: String; let msg: String }
    private struct Block {
        var kind: CrashKind; var pid: String; var date: Date; var title: String
        var lines: [String]; var last: Date; var titleLocked = false
    }

    /// Native crash lines come from several processes/tags (libc, crash_dump, DEBUG) and share one block.
    private static let nativeTags: Set<String> = ["DEBUG", "libc", "crash_dump64", "crash_dump32", "tombstoned"]
    private static let maxLines = 300
    private static let idle: TimeInterval = 1.2

    private let package: String
    private let emit: @Sendable (CrashReport) -> Void
    private var pids = Set<String>()
    private var open: [String: Block] = [:]
    private var recent: [(sig: String, at: Date)] = []
    private let lock = NSLock()

    init(package: String, emit: @escaping @Sendable (CrashReport) -> Void) {
        self.package = package; self.emit = emit
    }

    func addPids(_ list: [String]) { lock.lock(); pids.formUnion(list); lock.unlock() }

    private static let headerRE = try! NSRegularExpression(pattern: #"^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+(\d+)\s+\d+\s+([VDIWEFA])\s+(.+?)\s*: ?(.*)$"#)
    private static let unityRE = try! NSRegularExpression(pattern: #"^[\w.]*(Exception|Error)\b|Unhandled Exception|il2cpp"#, options: [.caseInsensitive])
    private static let genericRE = try! NSRegularExpression(pattern: #"^[\w.$]+(Exception|Error)\b"#)
    private static let pkgRE = try! NSRegularExpression(pattern: #"(?:Process:|Cmdline:|ANR in|Process|Kill '|>>>)\s*([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)"#)
    private static let diedPidRE = try! NSRegularExpression(pattern: #"\(pid (\d+)\)|Killing (\d+):"#)

    private static func parse(_ line: String) -> Header? {
        let ns = line as NSString
        guard let m = headerRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let lv = ns.substring(with: m.range(at: 3)).first ?? "I"
        return Header(date: StudioModel.parseDate(line) ?? Date(), pid: ns.substring(with: m.range(at: 2)), level: lv,
                      tag: ns.substring(with: m.range(at: 4)), msg: ns.substring(with: m.range(at: 5)))
    }
    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
    private static func capture(_ re: NSRegularExpression, _ s: String) -> String? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound { return ns.substring(with: m.range(at: i)) }
        return nil
    }

    /// A line that opens a new block (kind, block key, title, single-line?).
    /// Tags that print exception-looking lines during normal operation (e.g. every `adb shell` process on newer Android logs an
    /// AconfigStorageReadException from FeatureFlagsImplExport); never a crash.
    private static let noiseTags: Set<String> = ["FeatureFlagsImplExport"]

    private func start(_ h: Header) -> (kind: CrashKind, key: String, title: String, single: Bool)? {
        if Self.noiseTags.contains(h.tag) { return nil }
        let m = h.msg
        let hard = h.level == "E" || h.level == "F"
        switch h.tag {
        case "AndroidRuntime":
            if m.hasPrefix("FATAL EXCEPTION") { return (.fatal, "\(h.pid)|AndroidRuntime", m, false) }
        case "libc":
            if m.hasPrefix("Fatal signal") { return (.native, "native", "Native crash: " + m, false) }
        case "DEBUG":
            if m.hasPrefix("*** *** ***") { return (.native, "native", "Native crash", false) }
        case "ActivityManager":
            if m.hasPrefix("ANR in ") { return (.anr, "\(h.pid)|ActivityManager", m, false) }
            // Routine process cleanup is not a crash: ": stop" = user force-stop, "remove task" = swiped from recents,
            // ": empty #n" / "cached #n" = background trimming, "has died: cch…" = a cached (idle) process went away.
            let routine = m.contains(": stop ") || m.contains("remove task") || m.contains(": empty #") || m.contains(": cached #") || m.contains("has died: cch")
            if !routine, (m.hasPrefix("Process ") && m.contains(") has died")) || m.hasPrefix("Killing ") { return (.died, "", m, true) }
        case "lmkd":
            if m.hasPrefix("Kill '") { return (.oom, "", "Low memory kill: " + m, true) }
        case "Unity":
            if hard || h.level == "W", Self.matches(Self.unityRE, m) { return (.unity, "\(h.pid)|Unity", m, false) }
        case "System.err", "StrictMode":
            if h.tag == "StrictMode" ? m.contains("violation") : Self.matches(Self.genericRE, m) { return (.other, "\(h.pid)|\(h.tag)", m, false) }
        default:
            if hard, m.contains("OutOfMemoryError") || m.contains("Out of memory") { return (.oom, "\(h.pid)|\(h.tag)", m, false) }
            if hard, Self.matches(Self.genericRE, m) { return (.other, "\(h.pid)|\(h.tag)", m, false) }
        }
        return nil
    }

    func feed(_ line: String) {
        guard let h = Self.parse(line) else { return }
        lock.lock(); defer { lock.unlock() }
        let now = Date()

        // Learn which pids belong to the game, so Unity/OOM lines (which never name the package) can be matched.
        if h.tag == "ActivityManager", h.msg.hasPrefix("Start proc "), h.msg.contains(package) {
            let digits = h.msg.dropFirst("Start proc ".count).prefix { $0.isNumber }
            if !digits.isEmpty { pids.insert(String(digits)) }
        }

        if let s = start(h) {
            if s.single {
                let pid = Self.capture(Self.diedPidRE, h.msg) ?? h.pid
                finish(Block(kind: s.kind, pid: pid, date: h.date, title: s.title, lines: [line], last: now), now: now)
                return
            }
            // Native lines from libc and DEBUG describe the same crash.
            if s.kind == .native, var b = open[s.key], now.timeIntervalSince(b.last) < 5 {
                b.lines.append(line); b.last = now; open[s.key] = b
                return
            }
            if let old = open[s.key] {
                if old.lines.suffix(2).contains(line) { return }   // same start line repeated by the crash buffer
                open[s.key] = nil; finish(old, now: now)
            }
            open[s.key] = Block(kind: s.kind, pid: h.pid, date: h.date, title: s.title, lines: [line], last: now)
            return
        }

        let key = Self.nativeTags.contains(h.tag) && open["native"] != nil ? "native" : "\(h.pid)|\(h.tag)"
        guard var b = open[key], now.timeIntervalSince(b.last) < 2, b.lines.count < Self.maxLines else { return }
        if b.lines.suffix(2).contains(line) { return }   // the crash buffer repeats main-buffer lines
        b.lines.append(line); b.last = now
        if b.kind == .fatal, !b.titleLocked, !h.msg.hasPrefix("Process:"), !h.msg.hasPrefix("FATAL"), !h.msg.isEmpty {
            b.title = "FATAL: " + h.msg; b.titleLocked = true
        }
        if b.kind == .native, b.title == "Native crash", h.msg.contains("signal ") { b.title = "Native crash: " + h.msg }
        open[key] = b
    }

    /// Called every few hundred ms by the model: a block with no new line for a moment is complete.
    func flushIdle() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        for (k, b) in open where now.timeIntervalSince(b.last) > Self.idle { open[k] = nil; finish(b, now: now) }
    }

    func flushAll() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        for (_, b) in open { finish(b, now: now) }
        open.removeAll()
    }

    private func finish(_ b: Block, now: Date) {
        recent.removeAll { now.timeIntervalSince($0.at) > 3 }
        let sig = "\(b.kind.rawValue)|\(b.pid)|\(b.kind == .died ? "" : String(b.title.prefix(60)))"
        if recent.contains(where: { $0.sig == sig }) { return }
        // A fatal OOM is already a Fatal; skip the separate OOM block of the same process.
        if b.kind == .oom, recent.contains(where: { $0.sig.hasPrefix("Fatal|\(b.pid)|") }) { return }
        recent.append((sig, now))

        let text = b.lines.joined(separator: "\n")
        // Stray "Other" exceptions often just mention the game (Play Store, PackageManager…): only count them when the game's own process threw them.
        let isGame = b.kind == .other ? pids.contains(b.pid) : (text.contains(package) || pids.contains(b.pid))
        if isGame { pids.insert(b.pid) }
        let pkg = isGame ? package : Self.capture(Self.pkgRE, text)
        emit(CrashReport(kind: b.kind, date: b.date, title: b.title, package: pkg, pid: b.pid, isGame: isGame, lines: b.lines))
    }
}


/// Reads `dumpsys dropbox --print <tag>`: the system keeps every app crash / ANR / native crash for days, even if
/// nobody was recording. Each entry has the full stack trace plus pid, package version and a precise timestamp.
enum DropboxParser {
    static func parse(dump: String, package: String) -> [CrashReport] {
        let headRE = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (\w+) \(text, \d+ bytes\)"#)
        let stampRE = try! NSRegularExpression(pattern: #"Timestamp: (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{4})"#)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out: [CrashReport] = []
        for block in dump.components(separatedBy: "========================================\n").dropFirst() {
            var lines = block.components(separatedBy: "\n")
            guard let head = lines.first, let m = headRE.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
                  let dRange = Range(m.range(at: 1), in: head), let tRange = Range(m.range(at: 2), in: head) else { continue }
            lines.removeFirst()
            while lines.last?.isEmpty == true { lines.removeLast() }
            let body = lines.joined(separator: "\n")
            guard body.contains(package) else { continue }
            let tag = String(head[tRange]).lowercased()
            let kind: CrashKind = tag.contains("anr") ? .anr : tag.contains("native") || tag.contains("tombstone") ? .native
                                 : body.contains("OutOfMemoryError") ? .oom : .fatal
            var date = local.date(from: String(head[dRange])) ?? Date()
            if let s = stampRE.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)), let r = Range(s.range(at: 1), in: body),
               let d = f.date(from: String(body[r])) { date = d }
            let pid = body.components(separatedBy: "\n").first { $0.hasPrefix("PID:") }.map { $0.dropFirst(4).trimmingCharacters(in: .whitespaces) } ?? "?"
            // Title: the root cause ("Caused by:") if there is one, else the first line after the header block (which ends at the first blank line).
            let afterHeader = body.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n").components(separatedBy: "\n")
            let cause = afterHeader.last { $0.hasPrefix("Caused by:") }.map { String($0.dropFirst("Caused by:".count)).trimmingCharacters(in: .whitespaces) }
            let title = cause ?? afterHeader.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? tag
            out.append(CrashReport(kind: kind, date: date, title: kind == .fatal ? "FATAL: " + title : title, package: package,
                                   pid: pid, isGame: true, lines: ["[DropBox \(tag)]"] + lines, fromHistory: true))
        }
        return out
    }
}
