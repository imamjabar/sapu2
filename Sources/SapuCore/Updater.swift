import CryptoKit
import Foundation

/// New versions from the project's GitHub releases. Sapu2 only checks and downloads: the DMG's checksum is verified,
/// then it opens for you to drag in. Nothing replaces the app by itself (that needs a signed build).
public enum Updater {
    public struct Release: Sendable, Hashable {
        public let version: String
        public let page: URL
        public let dmg: URL
        public let checksum: URL?
        public let notes: String
    }

    public enum UpdateError: Error, LocalizedError {
        case noDMG, checksumMismatch, http(Int)
        public var errorDescription: String? {
            switch self {
            case .noDMG: "The latest release has no DMG."
            case .checksumMismatch: "The download doesn't match its published checksum, so it was not opened."
            case .http(let c): "GitHub answered \(c)."
            }
        }
    }

    public static let repo = "imamjabar/sapu2"
    /// Off while the repository is private: its releases can't be read without a token, and Sapu2 never ships one.
    public static let enabled = false
    public static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    public static func latest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw UpdateError.http(h.statusCode) }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Release {
        let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let assets = json["assets"] as? [[String: Any]] ?? []
        func url(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String ?? "").hasSuffix(suffix) }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }
        }
        guard let dmg = url(".dmg") else { throw UpdateError.noDMG }
        let tag = json["tag_name"] as? String ?? "0"
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       page: (json["html_url"] as? String).flatMap(URL.init) ?? URL(string: "https://github.com/\(repo)/releases")!,
                       dmg: dmg, checksum: url(".dmg.sha256"), notes: json["body"] as? String ?? "")
    }

    /// 0.10.0 is newer than 0.9.2 (numbers, not text).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Downloads the DMG to ~/Downloads/Sapu2-<version>/, checks it against the published SHA-256, and returns its path.
    public static func download(_ r: Release) async throws -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Sapu2-\(r.version)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (tmp, resp) = try await URLSession.shared.download(from: r.dmg)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw UpdateError.http(h.statusCode) }
        let data = try Data(contentsOf: tmp)
        if let c = r.checksum {
            let (sum, _) = try await URLSession.shared.data(from: c)
            let expected = String(decoding: sum, as: UTF8.self).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected == actual else { throw UpdateError.checksumMismatch }
        }
        let out = dir.appendingPathComponent(r.dmg.lastPathComponent)
        try? FileManager.default.removeItem(at: out)
        try data.write(to: out)
        return out
    }
}
