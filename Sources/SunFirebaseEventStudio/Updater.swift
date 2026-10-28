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

    enum InstallError: LocalizedError {
        case notAnAppBundle, notWritable(String), badArchive
        var errorDescription: String? {
            switch self {
            case .notAnAppBundle: return "Đang chạy ngoài file .app nên không tự cập nhật được."
            case .notWritable(let p): return "Không có quyền ghi vào \(p). Hãy tải thủ công."
            case .badArchive: return "File cập nhật tải về không hợp lệ."
            }
        }
    }

    /// Downloads the zip, unpacks it, then hands off to a detached shell that swaps the bundle after this process exits and relaunches it.
    static func install(_ info: UpdateInfo) async throws {
        let target = Bundle.main.bundlePath
        guard target.hasSuffix(".app") else { throw InstallError.notAnAppBundle }
        let parent = (target as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { throw InstallError.notWritable(parent) }
        guard let url = URL(string: info.url) else { throw URLError(.badURL) }

        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        let unpack = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path])
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: unpack.path))?.filter { $0.hasSuffix(".app") } ?? []
        guard let name = apps.first else { throw InstallError.badArchive }
        let newApp = unpack.appendingPathComponent(name).path
        guard FileManager.default.isExecutableFile(atPath: newApp + "/Contents/MacOS/SunFirebaseEventStudio") else { throw InstallError.badArchive }

        let script = work.appendingPathComponent("swap.sh")
        try """
        #!/bin/sh
        while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
        rm -rf "$3" && mv "$2" "$3" && xattr -dr com.apple.quarantine "$3" 2>/dev/null
        open "$3"
        rm -rf "$4"
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp, target, work.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    private static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw InstallError.badArchive }
    }
}
