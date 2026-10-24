import Foundation

/// Persists the last scan so the app opens instantly with known results instead of rescanning.
public enum Store {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sapu", isDirectory: true)
    }
    static var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }
    public static var receiptsDirectory: URL { directory.appendingPathComponent("Receipts", isDirectory: true) }

    public static func load() -> Snapshot? {
        guard let d = try? Data(contentsOf: snapshotURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Snapshot.self, from: d)
    }

    public static func save(_ s: Snapshot) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(s).write(to: snapshotURL, options: .atomic)
    }

    public static func receipts() -> [CleanReceipt] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: receiptsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(CleanReceipt.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
}
