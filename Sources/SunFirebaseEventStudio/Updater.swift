import Foundation
import AppKit

/// Shape of latest.json: {"version":"0.3.1","url":"https://...zip","notes":"...","date":"2026-10-27"}
struct UpdateInfo: Decodable {
    let version: String
    let url: String
    let notes: String?
    let date: String?
}

enum Updater {
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/TKieuTho/logcat-app/main/latest.json")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func fetchLatest() async throws -> UpdateInfo {
        var req = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(UpdateInfo.self, from: data)
    }

    /// Numeric dotted comparison: "0.10.0" > "0.9.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
