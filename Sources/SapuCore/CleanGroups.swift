import Foundation

/// The groups the cleaner shows, each with one plain promise about what cleaning it does.
public enum CleanGroup: String, CaseIterable, Sendable {
    case appCache = "App cache"
    case unusedApps = "Unused apps"
    case systemCache = "System cache"
    case logs = "Diagnostic logs"
    case misc = "Misc"
    case developer = "Developer tools"
    case ai = "AI tools"
    case browser = "Browser"
    case trash = "Trash"

    public var promise: String {
        switch self {
        case .appCache: "App temporary files. Rebuilt the next time the app opens."
        case .unusedApps: "Apps you have not opened for a long time. They go to the Trash and can be installed again."
        case .systemCache: "Caches macOS manages and rebuilds by itself."
        case .logs: "Old logs go to the Trash; large logs still being written are emptied in place."
        case .misc: "One-off caches and downloads that don't fit elsewhere."
        case .developer: "Xcode, SwiftPM, Node and other tool caches. The first build afterwards is slower."
        case .ai: "Temporary AI app caches and old versions. Conversations, projects and local models stay."
        case .browser: "Browser caches. Cookies, sign-ins and history stay."
        case .trash: "What's in your Trash. Sapu2 never empties it for you."
        }
    }

    public var symbol: String {
        switch self {
        case .appCache: "app.badge"
        case .unusedApps: "app.dashed"
        case .systemCache: "gearshape.2"
        case .logs: "doc.text"
        case .misc: "square.grid.2x2"
        case .developer: "hammer"
        case .ai: "sparkles"
        case .browser: "globe"
        case .trash: "trash"
        }
    }

    static let aiWords = ["claude", "codex", "gemini", "cursor", "antigravity", "copilot", "ollama", "lm-studio", "lmstudio", "chatgpt",
                          "openai", "anthropic", "windsurf", "huggingface", "hyperframes", "perplexity", "comfyui", "draw-things", "/.cache/torch"]
    static let browserWords = ["google/chrome", "bravesoftware", "arc/user data", "microsoft edge", "vivaldi", "operasoftware", "firefox",
                               "/safari", "net.imput.helium", "dia/user data", "googleupdater", "com.google.chrome", "company.thebrowser",
                               "application support/chromium", "floorp", "librewolf", "waterfox", "mullvadbrowser", "torbrowser", "duckduckgo"]

    public static func of(_ f: Finding, home: String = NSHomeDirectory()) -> CleanGroup {
        let p = f.path.lowercased()
        if f.category == .trash { return .trash }
        if aiWords.contains(where: p.contains) { return .ai }
        if browserWords.contains(where: p.contains) { return .browser }
        if f.category == .logs { return .logs }
        // Apps live outside the home folder, so without this line they would fall into "System cache" below.
        if f.category == .apps { return .unusedApps }
        if [.devCaches, .xcode, .ml, .containers, .projects].contains(f.category) { return .developer }
        if p.contains("/library/caches/com.apple.") || p.contains("/library/containers/com.apple.") || !f.path.hasPrefix(home + "/") { return .systemCache }
        if f.category == .appCaches { return .appCache }
        return .misc
    }
}
