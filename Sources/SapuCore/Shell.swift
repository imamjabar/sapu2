import Foundation

public enum Shell {
    public struct Result: Sendable { public var status: Int32; public var out: String; public var err: String; public var timedOut: Bool }

    /// Search path for developer tools: GUI apps do not inherit the shell PATH.
    public static let searchPath = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        "~/.bun/bin", "~/.cargo/bin", "~/go/bin", "~/.local/bin", "~/miniconda3/bin", "~/anaconda3/bin", "~/miniforge3/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
    ].map(\.expandingTilde)

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPath + [env["PATH"] ?? ""]).joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    public static func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        for dir in searchPath {
            let p = (dir as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Run a tool with a hard timeout. Never uses a shell, so arguments are not interpreted.
    @discardableResult
    public static func run(_ args: [String], cwd: String? = nil, timeout: TimeInterval = 10) -> Result {
        guard let first = args.first, let exe = which(first) else {
            return Result(status: 127, out: "", err: "\(args.first ?? "") not found", timedOut: false)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(args.dropFirst())
        p.environment = environment
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); group.enter()
        DispatchQueue.global(qos: .utility).async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global(qos: .utility).async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do { try p.run() } catch {
            return Result(status: 126, out: "", err: error.localizedDescription, timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        var timedOut = false
        if p.isRunning { timedOut = true; p.terminate() }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return Result(status: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self),
                      timedOut: timedOut)
    }

    /// Split a command line on spaces (rule commands never need quoting).
    public static func split(_ command: String) -> [String] {
        command.split(separator: " ").map(String.init)
    }
}
