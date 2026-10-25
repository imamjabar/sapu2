import Darwin
import Foundation

/// A developer tool still running long after whatever started it is gone: a dev server whose terminal closed,
/// a language server whose editor quit. They hold memory and keep writing logs.
public struct DevProcess: Codable, Sendable, Identifiable, Hashable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var command: String
    public var elapsed: TimeInterval
    public var memory: Int64
    /// Why it looks forgotten.
    public var reason: String
}

/// Finds forgotten developer processes. Never stops anything by itself: Quit asks one process to stop, politely.
public enum DevProcesses {
    /// Executables that are developer tools.
    static let tools: Set<String> = ["node", "python", "python3", "Python", "ruby", "java", "deno", "bun", "php", "go", "dart", "beam.smp",
                                     "gopls", "rust-analyzer", "sourcekit-lsp", "clangd", "esbuild", "uvicorn", "gunicorn", "jupyter-lab",
                                     "jupyter-notebook", "kotlin-language-server", "lua-language-server"]
    /// Language servers: an editor starts them, so with no editor open they are leftovers.
    static let languageServers = ["gopls", "rust-analyzer", "sourcekit-lsp", "clangd", "tsserver", "pyright", "pylance", "jdtls",
                                  "kotlin-language-server", "lua-language-server", "intelephense", "vscode-eslint", "typescript-language-server"]
    static let editors: Set<String> = ["Code", "Electron", "Cursor", "Windsurf", "Zed", "Xcode", "idea", "pycharm", "goland", "webstorm",
                                       "phpstorm", "rubymine", "clion", "rider", "datagrip", "studio", "Sublime Text", "nvim", "vim", "Antigravity"]

    public static func find(minAge: TimeInterval = 12 * 3600) -> [DevProcess] {
        // comm last, so a path with spaces stays whole; args read separately and joined by PID.
        let stat = Shell.run(["ps", "-x", "-o", "pid=,ppid=,etime=,rss=,comm="], timeout: 10).out
        let args = Shell.run(["ps", "-x", "-o", "pid=,args="], timeout: 10).out
        let jobs = launchdPIDs(Shell.run(["launchctl", "list"], timeout: 10).out)
        return parse(stat: stat, args: args, launchdJobs: jobs, minAge: minAge, me: getpid())
    }

    /// PIDs launchd runs on purpose (agents, `brew services`): never flagged.
    static func launchdPIDs(_ out: String) -> Set<Int32> {
        Set(out.split(separator: "\n").dropFirst().compactMap { Int32($0.split(separator: "\t").first ?? "") })
    }

    public static func parse(stat: String, args argsOut: String, launchdJobs: Set<Int32>, minAge: TimeInterval, me: Int32) -> [DevProcess] {
        struct Row { let pid, ppid: Int32; let elapsed: TimeInterval; let rss: Int64; let exe, args: String }
        var argsByPID: [Int32: String] = [:]
        for line in argsOut.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if f.count == 2, let pid = Int32(f[0]) { argsByPID[pid] = String(f[1]) }
        }
        let rows: [Row] = stat.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int32(f[0]), let ppid = Int32(f[1]), let rss = Int64(f[3]) else { return nil }
            let exe = String(f[4])
            var args = argsByPID[pid] ?? ""
            if args.hasPrefix(exe) { args = String(args.dropFirst(exe.count)) }
            return Row(pid: pid, ppid: ppid, elapsed: etime(String(f[2])), rss: rss * 1024, exe: exe, args: args.trimmingCharacters(in: .whitespaces))
        }
        let editorOpen = rows.contains { r in
            let n = r.exe.lastComponent
            return editors.contains(n) || r.exe.contains("/Visual Studio Code.app/") || r.exe.contains("/Cursor.app/") || r.exe.contains("/Xcode.app/Contents/MacOS/")
        }
        var out: [DevProcess] = []
        for r in rows where r.pid != me && r.elapsed >= minAge && !launchdJobs.contains(r.pid) {
            let name = r.exe.lastComponent
            let server = languageServers.first { name.contains($0) || r.args.contains($0) }
            guard tools.contains(name) || server != nil else { continue }
            let age = long(r.elapsed)
            var reason: String?
            if let server, !editorOpen { reason = "\(server) language server running for \(age) with no editor open." }
            else if r.ppid == 1 { reason = "Its launcher quit; still running after \(age)." }
            guard let reason else { continue }
            out.append(DevProcess(pid: r.pid, name: server ?? name, command: (r.exe + " " + r.args).trimmingCharacters(in: .whitespaces),
                                  elapsed: r.elapsed, memory: r.rss, reason: reason))
        }
        return out.sorted { $0.memory > $1.memory }
    }

    /// "2 days", "13 hours".
    static func long(_ s: TimeInterval) -> String {
        let h = Int(s / 3600)
        return h >= 48 ? "\(h / 24) days" : "\(h) hours"
    }

    /// `ps` elapsed time: [[dd-]hh:]mm:ss.
    public static func etime(_ s: String) -> TimeInterval {
        let dayParts = s.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let hms = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
        var secs = 0.0
        for v in hms { secs = secs * 60 + v }
        return days * 86_400 + secs
    }

    /// Asks one process to stop (SIGTERM), after checking it is still the same program. Never force-quits.
    public static func quit(_ p: DevProcess) -> (ok: Bool, message: String) {
        let now = Shell.run(["ps", "-p", "\(p.pid)", "-o", "comm="], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !now.isEmpty else { return (true, "Already stopped.") }
        guard p.command.hasPrefix(now) else { return (false, "That process ID now belongs to another program; nothing was stopped.") }
        guard kill(p.pid, SIGTERM) == 0 else { return (false, "macOS didn't allow stopping it (\(String(cString: strerror(errno)))).") }
        return (true, "Asked \(p.name) to stop.")
    }
}
