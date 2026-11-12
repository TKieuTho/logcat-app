import Foundation
import SwiftUI

struct ADBDevice: Identifiable, Hashable {
    var id: String { serial }
    let serial: String
    var state: String
    var model: String
    var displayName: String {
        let cleaned = model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: " ")
        return "\(cleaned)  ·  \(serial)"
    }
}

struct EventParam: Hashable {
    let key: String
    let value: String
    var isInternal: Bool { key.hasPrefix("ga_") || key.hasPrefix("firebase_event_origin") || key.hasPrefix("firebase_screen") || key.hasPrefix("firebase_previous") }
}

enum LogKind: String, Hashable { case event, userProperty, crash }

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All", events = "Events", properties = "User Props", crashes = "Crashes"
    var id: String { rawValue }
    func allows(_ k: LogKind) -> Bool {
        switch self { case .all: return true; case .events: return k == .event; case .properties: return k == .userProperty; case .crashes: return k == .crash }
    }
}

struct LogEvent: Identifiable, Hashable {
    let id = UUID()
    let kind: LogKind
    let date: Date
    let deviceSerial: String
    let tag: String
    let raw: String
    let name: String
    let params: [EventParam]
    /// Lowercased "name key=value ..." used by search.
    let blob: String
    var crash: CrashInfo?
    /// Happened before the recording started (read back from the phone's old log / DropBox), not seen live.
    var beforeStart = false

    init(date: Date, deviceSerial: String, tag: String, raw: String, name: String, params: [EventParam], kind: LogKind = .event, crash: CrashInfo? = nil) {
        self.kind = kind
        self.crash = crash
        self.clock = Self.clockFormatter.string(from: date)
        self.date = date; self.deviceSerial = deviceSerial; self.tag = tag; self.raw = raw
        self.name = name; self.params = params
        self.blob = ([name] + params.map { "\($0.key)=\($0.value)" } + (crash == nil ? [] : [raw])).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
    /// Formatted once at creation; formatting a date per row per render was a large share of the UI cost.
    let clock: String
    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Plain text with event name and every parameter, for copy/paste into bug reports.
    var copyText: String {
        if kind == .userProperty { return "\(name) = \(params.first?.value ?? "")" }
        if kind == .crash { return raw }
        return ([name] + params.map { "\($0.key) = \($0.value)" }).joined(separator: "\n")
    }

    private static let propertyRE = try! NSRegularExpression(pattern: #"(?:Setting|Making) user property\s*(?:\(FE\))?: ([A-Za-z0-9_]+)(?:\([^)]*\))?, ?(.*)$"#)
    private static let ignoredPropertyRE = try! NSRegularExpression(pattern: #"Too many unique user properties are set\. Ignoring user property: ([A-Za-z0-9_]+)(?:\([^)]*\))?, ?(.*)$"#)
    private static let eventREs: [NSRegularExpression] = [
        #"Logging event(?: \(FE\))?: origin=[^,]*,name=([A-Za-z0-9_]+)(?:\([^)]*\))?,\s*params=(.*)$"#,
        #"Logging event(?: \(FE\))?: ([A-Za-z0-9_]+)(?:\([^)]*\))?, (.*)$"#,
        #"Event recorded: Event\{appId='[^']*', name='([^']+)', params=(.*)$"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let keyRE = try! NSRegularExpression(pattern: #"(?:^|, )([A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)="#)

    /// FA writes ~100 unrelated lines per event; this cheap check keeps them away from the regexes.
    static func looksRelevant(_ raw: String) -> Bool {
        raw.contains("Logging event") || raw.contains("Event recorded") || raw.contains("user property")
    }

    /// Returns nil for log lines that are not an event (noise from FA / FA-SVC).
    static func parse(raw: String) -> (name: String, params: [EventParam], kind: LogKind)? {
        guard looksRelevant(raw) else { return nil }
        let whole = NSRange(raw.startIndex..., in: raw)
        if let mt = propertyRE.firstMatch(in: raw, range: whole),
           let r1 = Range(mt.range(at: 1), in: raw), let r2 = Range(mt.range(at: 2), in: raw) {
            return (String(raw[r1]), [EventParam(key: "value", value: String(raw[r2]))], .userProperty)
        }
        // The SDK drops properties beyond its limit of 25 distinct names; QA needs to see which ones.
        if let mt = ignoredPropertyRE.firstMatch(in: raw, range: whole),
           let r1 = Range(mt.range(at: 1), in: raw), let r2 = Range(mt.range(at: 2), in: raw) {
            return (String(raw[r1]), [EventParam(key: "value", value: String(raw[r2])),
                                      EventParam(key: "status", value: "Bị SDK bỏ qua: quá 25 property")], .userProperty)
        }
        for re in eventREs {
            guard let mt = re.firstMatch(in: raw, range: whole),
                  let r1 = Range(mt.range(at: 1), in: raw), let r2 = Range(mt.range(at: 2), in: raw) else { continue }
            return (String(raw[r1]), parseParams(String(raw[r2])), .event)
        }
        return nil
    }

    private static func parseParams(_ s: String) -> [EventParam] {
        var body = s
        if let open = body.firstIndex(of: "{") { body = String(body[body.index(after: open)...]) }
        // "Event recorded" ends with "}]}" (Bundle + Event), the other flavours with "}]" or "}".
        if let suffix = ["}]}", "}]", "}"].first(where: { body.hasSuffix($0) }) { body.removeLast(suffix.count) }
        else if let close = body.lastIndex(of: "}") { body = String(body[..<close]) }
        let ns = body as NSString
        let matches = keyRE.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var out: [EventParam] = []
        for (i, m) in matches.enumerated() {
            let valueStart = m.range.location + m.range.length
            let valueEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            out.append(EventParam(key: ns.substring(with: m.range(at: 1)),
                                  value: ns.substring(with: NSRange(location: valueStart, length: valueEnd - valueStart))))
        }
        return out
    }
}

enum GamePackage: String, CaseIterable, Identifiable {
    case mahjong = "studio.sun.mahjong.classic.casual.tile.matching"
    case tileAdventure = "studio.sun.tileadventure"
    case snakeEscape = "studio.sun.snake.escape.puzzle"
    case blossomMaster = "com.blossom.tile.match.puzzle"
    case solitaire = "studio.sun.solitaire.classic.card.klondike.patience"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mahjong: return "Mahjong Classic"
        case .tileAdventure: return "Tile Adventure"
        case .snakeEscape: return "Snake Escape"
        case .blossomMaster: return "Blossom Master"
        case .solitaire: return "Solitaire Classic"
        }
    }
}

/// One pending AlarmManager entry of the game; Unity local notifications are scheduled this way.
struct ScheduledAlarm: Identifiable, Hashable {
    let id = UUID()
    let fireDate: Date
    let type: String
    let exact: Bool
    let window: String
    let repeatInterval: TimeInterval
    let tag: String

    var isNotification: Bool { tag.contains("androidnotifications") || tag.lowercased().contains("notif") }
    var modeText: String {
        if exact { return "Chính xác" }
        if let s = AlarmParser.parseRelative(window.hasPrefix("+") || window.hasPrefix("-") ? window : "+" + window), s > 0 {
            return "Trong khoảng \(Self.duration(s).replacingOccurrences(of: #" 0[ms]$"#, with: "", options: .regularExpression))"
        }
        return "Trong khoảng \(Self.tidy(window))"
    }
    var repeatText: String {
        guard repeatInterval > 0 else { return "Một lần" }
        return "Lặp mỗi \(Self.duration(repeatInterval))"
    }
    var copyText: String { "\(Self.fullFormatter.string(from: fireDate))  \(type)  \(modeText)  \(repeatText)  \(tag)" }

    static let fullFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE dd/MM HH:mm:ss"; return f
    }()
    /// "+1h0m0s0ms" → "1h"
    static func tidy(_ w: String) -> String {
        let t = w.replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: #"(?<![0-9])0(ms|d|h|m|s)"#, with: "", options: .regularExpression)
        return t.isEmpty ? "0" : t
    }
    static func duration(_ s: TimeInterval) -> String {
        let t = Int(abs(s)); let d = t / 86400, h = t % 86400 / 3600, m = t % 3600 / 60, sec = t % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}

enum AlarmParser {
    /// Parses `adb shell dumpsys alarm` and keeps the pending alarms owned by `package`.
    static func parse(dump: String, package: String, now: Date = Date()) -> [ScheduledAlarm] {
        guard let header = try? NSRegularExpression(pattern: #"^\s+([A-Z_]+) #\d+: Alarm\{\S+ type (\d+) origWhen (\d+) whenElapsed \d+ (\S+)\}"#) else { return [] }
        let lines = dump.components(separatedBy: "\n")
        var out: [ScheduledAlarm] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let m = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let pkg = Range(m.range(at: 4), in: line), line[pkg] == package,
                  let kind = Range(m.range(at: 1), in: line), let orig = Range(m.range(at: 3), in: line) else { i += 1; continue }
            var tag = "", window = "0", repeatMs = 0.0, relative: TimeInterval?
            var j = i + 1
            while j < lines.count, !(header.firstMatch(in: lines[j], range: NSRange(lines[j].startIndex..., in: lines[j])) != nil),
                  lines[j].hasPrefix("      ") {
                let l = lines[j].trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("tag=") { tag = String(l.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
                if let r = l.range(of: "window=") { window = String(l[r.upperBound...].prefix { !$0.isWhitespace }) }
                if let r = l.range(of: "repeatInterval=") { repeatMs = Double(l[r.upperBound...].prefix { $0.isNumber }) ?? 0 }
                if l.hasPrefix("whenElapsed=") { relative = parseRelative(String(l.dropFirst(12).prefix { !$0.isWhitespace })) }
                j += 1
            }
            let type = String(line[kind])
            let date: Date
            if type.hasPrefix("RTC"), let ms = Double(line[orig]) { date = Date(timeIntervalSince1970: ms / 1000) }
            else if let rel = relative { date = now.addingTimeInterval(rel) }
            else { i = j; continue }
            out.append(ScheduledAlarm(fireDate: date, type: type, exact: window == "0", window: window,
                                      repeatInterval: repeatMs / 1000, tag: tag.replacingOccurrences(of: "*walarm*:", with: "").replacingOccurrences(of: "*alarm*:", with: "")))
            i = j
        }
        return out.sorted { $0.fireDate < $1.fireDate }
    }

    /// "+1d17h54m19s610ms" / "-3h51m55s257ms" → seconds.
    static func parseRelative(_ s: String) -> TimeInterval? {
        guard let first = s.first, first == "+" || first == "-" else { return nil }
        let sign: Double = first == "-" ? -1 : 1
        var total = 0.0, num = ""
        var chars = Array(s.dropFirst())[...]
        while let c = chars.first {
            if c.isNumber { num.append(c); chars = chars.dropFirst(); continue }
            var unit = String(c); chars = chars.dropFirst()
            if c == "m", chars.first == "s" { unit = "ms"; chars = chars.dropFirst() }
            let v = Double(num) ?? 0; num = ""
            switch unit { case "d": total += v * 86400; case "h": total += v * 3600; case "m": total += v * 60
                          case "s": total += v; case "ms": total += v / 1000; default: break }
        }
        return sign * total
    }
}


/// One user property as listed in the SDK's upload dump (the same list Firebase itself sends).
struct UserPropertyState: Identifiable, Hashable {
    var id: String { rawName }
    let rawName: String          // e.g. "non_personalized_ads(_npa)"
    let value: String
    let setAt: Date
    var changedAt: Date?         // when this app last saw it appear or change
    var name: String { rawName.replacingOccurrences(of: #"\(_[^)]*\)$"#, with: "", options: .regularExpression) }
    /// Reserved/engagement properties the SDK manages itself; shown dimmed.
    var isInternal: Bool { (rawName.contains("(_") && name != "user_id") || name.hasPrefix("ga_") || name.hasSuffix("_user_engagement") || name.hasPrefix("first_open") }
}

struct PropertySnapshot {
    var props: [UserPropertyState]
    var updatedAt: Date
}

/// Reads the multi-line `batch { bundle { … user_property { … } … } }` dump FA prints on every upload.
/// One instance per logcat stream; fed from that stream's single reader thread, so no locking.
final class UploadDumpParser: @unchecked Sendable {
    private var app: String?
    private var props: [UserPropertyState] = []
    private var cur: (name: String?, string: String, int: String?, double: String?, setAt: Double?)?

    private static func body(_ line: String) -> Substring? {
        guard let r = line.range(of: "): ") else { return nil }
        return line[r.upperBound...]
    }

    /// Returns a finished snapshot when the dump's closing brace arrives.
    func feed(_ line: String) -> (app: String, props: [UserPropertyState])? {
        if app == nil {
            guard let r = line.range(of: "Uploading data. app, uncompressed size, data: ") else { return nil }
            let rest = line[r.upperBound...]
            app = rest.prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
            props = []; cur = nil
            return nil
        }
        guard let body = Self.body(line) else { return nil }
        if body.hasPrefix("Uploading data. app, uncompressed size") {   // a new dump started without the old one closing
            app = nil; props = []; cur = nil
            return feed(line)
        }
        let t = body.trimmingCharacters(in: .whitespaces)
        if cur != nil {
            if t == "}" {
                if let c = cur, let name = c.name {
                    let value = c.int ?? c.double ?? c.string
                    props.append(UserPropertyState(rawName: name, value: value,
                                                   setAt: Date(timeIntervalSince1970: (c.setAt ?? 0) / 1000), changedAt: nil))
                }
                cur = nil
            } else if t.hasPrefix("name: ") { cur?.name = String(t.dropFirst(6)) }
            else if t.hasPrefix("string_value:") { cur?.string = String(t.dropFirst(13)).trimmingCharacters(in: .whitespaces) }
            else if t.hasPrefix("int_value: ") { cur?.int = String(t.dropFirst(11)) }
            else if t.hasPrefix("double_value: ") { cur?.double = String(t.dropFirst(14)) }
            else if t.hasPrefix("set_timestamp_millis: ") { cur?.setAt = Double(t.dropFirst(22)) }
            return nil
        }
        if t == "user_property {" { cur = (nil, "", nil, nil, nil); return nil }
        // The dump's own closing brace sits at column 0; everything nested is indented.
        if body == "}" || body.hasPrefix("} //") {
            defer { app = nil; props = []; cur = nil }
            return props.isEmpty ? nil : (app ?? "", props)
        }
        // Any other unindented line means the dump ended without us seeing the brace.
        if let f = body.first, f != " ", body != "batch {" { app = nil; props = []; cur = nil }
        return nil
    }
}

/// One notification currently shown on the phone (from `dumpsys notification`).
struct ActiveNotification: Identifiable, Hashable {
    let id = UUID()
    let package: String
    let channel: String
    let title: String
    let text: String
    /// When it was first posted, and when it was last updated (the app may keep refreshing it).
    let posted: Date
    let updated: Date
    let ongoing: Bool
    /// Game campaign that scheduled it (e.g. COMEBACK_2H, MORNING_ROUTINE), and the time it was meant to fire.
    let campaign: String
    let scheduledFire: Date?
    /// System notification key (package, id, tag, uid); with `posted` it identifies one post across polls.
    let key: String
    var logID: String { "\(key)|\(Int(posted.timeIntervalSince1970 * 1000))" }

    var wasUpdated: Bool { updated.timeIntervalSince(posted) > 2 }
    var copyText: String {
        "\(ScheduledAlarm.fullFormatter.string(from: posted))  \(campaign.isEmpty ? package : campaign)  \(title)  \(text)" + (wasUpdated ? "  (cập nhật \(ScheduledAlarm.fullFormatter.string(from: updated)))" : "")
    }
}

enum ActiveNotificationParser {
    /// Parses `adb shell dumpsys notification --noredact`; newest first.
    static func parse(dump: String) -> [ActiveNotification] {
        guard let start = dump.range(of: "Notification List:") else { return [] }
        var section = dump[start.upperBound...]
        if let end = section.range(of: "Snoozed notifications") { section = section[..<end.lowerBound] }
        let records = section.components(separatedBy: "NotificationRecord(").dropFirst()
        func field(_ r: String, _ key: String) -> String? {
            guard let k = r.range(of: key) else { return nil }
            return String(r[k.upperBound...].prefix { !$0.isWhitespace && $0 != ")" })
        }
        func text(_ r: String, _ key: String) -> String {
            guard let line = r.components(separatedBy: "\n").first(where: { $0.contains(key + "=") }),
                  let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return "" }
            return String(line[line.index(after: open)..<close])
        }
        func date(_ r: String, _ key: String) -> Date? {
            field(r, key + "=").flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        return records.compactMap { r in
            guard let pkg = field(r, "pkg="), let posted = date(r, "mCreationTimeMs") else { return nil }
            let flags = r.components(separatedBy: "flags=").dropFirst().first?.prefix { !$0.isWhitespace } ?? ""
            var campaign = field(r, "\"campaignId\":\"").map { String($0.prefix { $0 != "\"" }) } ?? ""
            if campaign.isEmpty, let g = r.range(of: "|g:") {
                let key = String(r[g.upperBound...].prefix { !$0.isWhitespace })
                if key != "ranker_group", !key.hasPrefix("Aggregate") { campaign = key }
            }
            let fire = field(r, "fireTime=Long (").flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            return ActiveNotification(package: pkg, channel: field(r, "channel=") ?? "",
                                      title: text(r, "android.title"), text: text(r, "android.text"),
                                      posted: posted, updated: date(r, "mUpdateTimeMs") ?? posted,
                                      ongoing: flags.contains("ONGOING_EVENT"), campaign: campaign, scheduledFire: fire,
                                      key: r.components(separatedBy: "\n").first { $0.hasPrefix("      key=") }.map { String($0.dropFirst(10)) } ?? "\(pkg)|\(posted.timeIntervalSince1970)")
        }
        .sorted { $0.posted > $1.posted }
    }
}


/// A notification the app saw on the phone while recording; it stays here after the user swipes it away.
struct LoggedNotification: Identifiable, Hashable {
    var id: String { serial + "|" + notification.logID }
    let serial: String
    let notification: ActiveNotification
    var goneAt: Date?
}

/// `dumpsys meminfo <package>` boiled down to the numbers that matter for a leak / OOM check.
struct MemInfoSnapshot {
    struct Row: Identifiable { let name: String; let pssKB: Int; var id: String { name } }
    var package = ""
    var running = false
    var pid = ""
    var rows: [Row] = []
    var totalPSS = 0, totalRSS = 0, swapPSS = 0
    var objects: [(name: String, count: Int)] = []
    var deviceLines: [String] = []
    var raw = ""
    var date = Date()
}

enum MemInfoParser {
    static func parse(package: String, app: String, device: String) -> MemInfoSnapshot {
        var m = MemInfoSnapshot(); m.package = package; m.raw = app
        m.deviceLines = device.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !app.contains("No process found"), app.contains("MEMINFO in pid") else { return m }
        m.running = true
        func int(_ s: String) -> Int { Int(s.replacingOccurrences(of: ",", with: "")) ?? 0 }
        func first(_ pattern: String, in s: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern), let r = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  r.numberOfRanges > 1, let g = Range(r.range(at: 1), in: s) else { return nil }
            return String(s[g])
        }
        m.pid = first(#"MEMINFO in pid (\d+)"#, in: app) ?? ""
        // Newer Android prints "TOTAL PSS:"; older ones only have "TOTAL:" in App Summary or "TOTAL  <pss> ..." in the table.
        m.totalPSS = int(first(#"TOTAL PSS:\s+([\d,]+)"#, in: app) ?? first(#"(?m)^\s*TOTAL:\s+([\d,]+)"#, in: app) ?? first(#"(?m)^\s*TOTAL\s+(\d+)"#, in: app) ?? "0")
        m.totalRSS = int(first(#"TOTAL RSS:\s+(\d+)"#, in: app) ?? "0")
        m.swapPSS = int(first(#"TOTAL SWAP PSS:\s+(\d+)"#, in: app) ?? "0")
        let rowRE = try? NSRegularExpression(pattern: #"^\s*([A-Za-z][A-Za-z ]*?):\s+(\d+)(?:\s+\d+)?\s*$"#)
        let pairRE = try? NSRegularExpression(pattern: #"([A-Za-z][A-Za-z ]*?):\s+(\d+)"#)
        var section = ""
        for line in app.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "App Summary" || t == "Objects" || t.hasPrefix("SQL") || t.hasPrefix("DATABASES") || t.hasPrefix("Unreachable") { section = t; continue }
            if section == "App Summary", let re = rowRE, let r = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let a = Range(r.range(at: 1), in: line), let b = Range(r.range(at: 2), in: line) {
                m.rows.append(.init(name: String(line[a]), pssKB: int(String(line[b]))))
            }
            if section == "Objects", let re = pairRE {
                for r in re.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    if let a = Range(r.range(at: 1), in: line), let b = Range(r.range(at: 2), in: line) {
                        m.objects.append((String(line[a]).trimmingCharacters(in: .whitespaces), int(String(line[b]))))
                    }
                }
            }
        }
        return m
    }
}


/// One reading of the running game: frame rate, CPU, RAM, temperature, battery.
struct PerfSample: Identifiable {
    let id = UUID()
    let date: Date
    var running = false
    var fps: Double?
    /// Share of frames that took longer than 1.5 refresh periods, and the slowest frame.
    var jankPct: Double?
    var maxFrameMs: Double?
    /// Timestamp (phone monotonic clock, ns) of the newest frame; equal to the previous sample's means nothing new was drawn.
    var lastFrameNs: Double?
    /// % of ONE core (100 = one core fully busy; the phone has `cores` of them).
    var cpu: Double?
    var cores = 8
    var rssMB: Double?
    var threads: Int?
    var cpuTemp: Double?
    var batteryTemp: Double?
    var battery: Int?
    var thermalStatus: Int?
}

enum PerfParser {
    /// Parses the output of `ADBService.fetchPerf`. Returns the sample and the SurfaceFlinger layer to reuse next time.
    static func parse(_ out: String, date: Date = Date()) -> (sample: PerfSample, layer: String?) {
        var sections: [String: [String]] = [:]
        var cur = ""
        for line in out.components(separatedBy: "\n") {
            if line.hasPrefix("---") { cur = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); sections[cur] = []; continue }
            sections[cur, default: []].append(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        var s = PerfSample(date: date)
        func num(_ pattern: String, in text: String) -> Double? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return Double(text[r])
        }
        // --- phone-wide
        let thermal = (sections["THERMAL"] ?? []).joined(separator: "\n")
        s.thermalStatus = num(#"Thermal Status: (\d+)"#, in: thermal).map(Int.init)
        s.cpuTemp = num(#"mValue=([\d.]+), mType=\d+, mName=CPU"#, in: thermal)
        let batt = (sections["BATT"] ?? []).joined(separator: "\n")
        s.battery = num(#"level: (\d+)"#, in: batt).map(Int.init)
        s.batteryTemp = num(#"temperature: (\d+)"#, in: batt).map { $0 / 10 }

        let pid = (sections["PID"] ?? []).first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !pid.isEmpty else { return (s, nil) }
        s.running = true
        // --- process
        let top = (sections["TOP"] ?? []).joined(separator: "\n")
        if let c = num(#"(\d+)%cpu"#, in: top) { s.cores = max(1, Int(c) / 100) }
        for line in (sections["TOP"] ?? []) {
            let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if f.first == pid, let i = f.firstIndex(where: { $0.count == 1 && $0.first!.isLetter && $0.first!.isUppercase }), i + 1 < f.count {
                s.cpu = Double(f[i + 1].replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""))
            }
        }
        let status = (sections["STATUS"] ?? []).joined(separator: "\n")
        s.rssMB = num(#"VmRSS:\s+(\d+)"#, in: status).map { $0 / 1024 }
        s.threads = num(#"Threads:\s+(\d+)"#, in: status).map(Int.init)
        // --- frames
        let layer = (sections["LAYER"] ?? []).first?.trimmingCharacters(in: .whitespaces)
        let lat = sections["LAT"] ?? []
        if let period = lat.first.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), period > 0 {
            let t = lat.dropFirst().compactMap { l -> Double? in
                let f = l.split(whereSeparator: \.isWhitespace)
                guard f.count == 3, let v = Double(f[1]), v > 0, v < 9e18 else { return nil }
                return v
            }
            if t.count > 2 {
                let span = (t.last! - t.first!) / 1e9
                let gaps = zip(t, t.dropFirst()).map { ($1 - $0) / 1e6 }
                s.lastFrameNs = t.last
                if span > 0.2 {
                    s.fps = Double(t.count - 1) / span
                    s.jankPct = Double(gaps.filter { $0 > period * 1.5 / 1e6 }.count) / Double(gaps.count) * 100
                    s.maxFrameMs = gaps.max()
                }
            } else if layer?.isEmpty == false { s.fps = 0 }
        }
        return (s, (layer?.isEmpty ?? true) ? nil : layer)
    }
}


/// When recording on one phone began (on the same clock the log lines use), and what interrupted it.
struct RecordingSession {
    let serial: String
    let game: GamePackage
    /// First line of the recording, taken from the marker the app writes into the phone's log: same clock as every event time.
    var startLog: Date
    let startMac: Date
    var stoppedMac: Date?
    var lostMac: Date?
    var gapText: String?
}
