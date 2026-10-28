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

    /// Returns nil for log lines that are not an event (noise from FA / FA-SVC).
    static func parse(raw: String) -> (name: String, params: [EventParam], kind: LogKind)? {
        // "Setting user property (FE): level, 12" / "Setting user property: level, 12"
        if let re = try? NSRegularExpression(pattern: #"(?:Setting|Making) user property(?: \(FE\))?: ([A-Za-z0-9_]+), ?(.*)$"#),
           let mt = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let r1 = Range(mt.range(at: 1), in: raw), let r2 = Range(mt.range(at: 2), in: raw) {
            return (String(raw[r1]), [EventParam(key: "value", value: String(raw[r2]))], .userProperty)
        }
        let patterns = [
            #"Logging event(?: \(FE\))?: origin=[^,]*,name=([A-Za-z0-9_]+)(?:\([^)]*\))?,\s*params=(.*)$"#,
            #"Logging event(?: \(FE\))?: ([A-Za-z0-9_]+)(?:\([^)]*\))?, (.*)$"#,
            #"Event recorded: Event\{appId='[^']*', name='([^']+)', params=(.*)$"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let mt = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
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
        guard let keyRE = try? NSRegularExpression(pattern: #"(?:^|, )([A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)="#) else { return [] }
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
