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

enum LogKind: String, Hashable { case event, userProperty }

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All", events = "Events", properties = "User Props"
    var id: String { rawValue }
    func allows(_ k: LogKind) -> Bool {
        switch self { case .all: return true; case .events: return k == .event; case .properties: return k == .userProperty }
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

    init(date: Date, deviceSerial: String, tag: String, raw: String, name: String, params: [EventParam], kind: LogKind = .event) {
        self.kind = kind
        self.date = date; self.deviceSerial = deviceSerial; self.tag = tag; self.raw = raw
        self.name = name; self.params = params
        self.blob = ([name] + params.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
    var clock: String { Self.clockFormatter.string(from: date) }
    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Plain text with event name and every parameter, for copy/paste into bug reports.
    var copyText: String {
        if kind == .userProperty { return "\(name) = \(params.first?.value ?? "")" }
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
    var modeText: String { exact ? "Chính xác" : "Trong khoảng \(Self.tidy(window))" }
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
