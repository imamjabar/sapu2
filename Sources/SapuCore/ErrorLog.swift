import Foundation

/// A small log of things that went wrong, kept on this Mac only. Nothing is sent anywhere: when a problem needs
/// reporting, the person attaches this file to an issue, and can read it first. Home folder paths are written as "~".
public enum ErrorLog {
    public static var url: URL { Store.directory.appendingPathComponent("errors.log") }
    /// The file never grows past about this size; the older half is dropped when it does.
    static let limit = 256 * 1024
    private static let lock = NSLock()

    public static func record(_ context: String, _ message: String, now: Date = Date()) {
        let line = "\(now.ISO8601Format()) [\(context)] \(message.replacingOccurrences(of: NSHomeDirectory(), with: "~").replacingOccurrences(of: "\n", with: " "))\n"
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += line
        if text.utf8.count > limit {
            // Cut on a line boundary so no half line is left at the top.
            let tail = String(text.suffix(limit / 2))
            text = tail.firstIndex(of: "\n").map { String(tail[tail.index(after: $0)...]) } ?? tail
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    public static func clear() { try? FileManager.default.removeItem(at: url) }
}
