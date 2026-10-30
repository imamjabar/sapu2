import Foundation

/// Data a careful cleaner keeps by default, whatever rule found it. Cross-checked against a reference cleaner's
/// own protection check: anything it protects, Sapu2 never preselects, and where it is data, Sapu2 only shows it.
/// Applied to every finding as it is made, so no rule can get around it.
public enum Protection {
    public static func adjust(_ f: Finding, home: String = NSHomeDirectory()) -> Finding {
        guard f.action != .none else { return f }
        var g = f
        if let why = dataOnly(f.path, home: home) {
            g.safety = .yours; g.action = .none; g.rebuild = why
        } else if f.safety == .safe, let why = keepByDefault(f.path, home: home) {
            g.safety = .check; g.rebuild = [f.rebuild, why].compactMap { $0 }.joined(separator: " ")
        }
        return g
    }

    /// Shown only, never cleaned.
    public static func dataOnly(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let lib = home + "/Library"
        func under(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        // macOS's own caches: some hold sign-in or account state (akd, appleaccountd, iCloud), and macOS trims them itself.
        if path.hasPrefix(lib + "/Caches/com.apple.") || path.hasPrefix(lib + "/Containers/com.apple.") {
            return "macOS manages this and trims it when space runs low; some of these hold sign-in or account state. Sapu2 shows it only."
        }
        // Codex keeps conversation indexes and app state in cache-shaped folders.
        if under(lib + "/Application Support/Codex") || under(lib + "/Logs/com.openai.codex") || under(home + "/.cache/codex-runtimes")
            || under(home + "/.codex/sessions") || under(home + "/.codex/cache") {
            return "Codex keeps conversation indexes and app state here. Sapu2 shows it only; manage it in Codex."
        }
        if under(lib + "/Caches/Codex") {
            let ok = ["Default/Cache", "Default/Code Cache", "codex-browser-app/Cache", "codex-browser-app/Code Cache",
                      "Default/Partitions/codex-browser-app/Cache", "Default/Partitions/codex-browser-app/Code Cache"]
            if !ok.contains(where: { under(lib + "/Caches/Codex/" + $0) }) {
                return "Codex keeps app state next to its web cache here. Sapu2 shows it only."
            }
        }
        // Leftovers of virtual machine and mail apps can hold whole machines or your mail.
        let holders = ["com.utmapp.UTM", "com.parallels.", "com.vmware.", "com.microsoft.Outlook", "com.readdle.smartemail",
                       "it.bloop.airmail", "com.mimestream.", "com.freron.MailMate", "com.getcanary.", "org.virtualbox."]
        for root in [lib + "/Containers/", lib + "/Group Containers/", lib + "/Application Support/"] where path.hasPrefix(root) {
            let leaf = String(path.dropFirst(root.count).split(separator: "/").first ?? "")
            if holders.contains(where: { leaf.hasPrefix($0) || leaf.contains("." + $0) }) {
                return "Can hold virtual machines or your mail. Sapu2 shows it only; check it in Finder first."
            }
        }
        return nil
    }

    /// Never preselected: apps whose data careful cleaners leave alone by default. Fine to clean once the app is quit.
    public static func keepByDefault(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let lib = home + "/Library"
        let prefixes = ["com.microsoft.", "com.jetbrains.", "com.visualstudio.", "com.sublimetext.", "com.sublimehq.", "com.todesktop.",
                        "com.anthropic.", "com.openai.", "com.docker.", "com.getpostman.", "com.insomnia."]
        let names: Set<String> = ["Claude", "Cursor", "ChatGPT", "Ollama", "JetBrains"]
        for root in [lib + "/Caches/", lib + "/Containers/", lib + "/Application Support/", lib + "/Logs/"] where path.hasPrefix(root) {
            let leaf = String(path.dropFirst(root.count).split(separator: "/").first ?? "")
            if prefixes.contains(where: leaf.hasPrefix) || names.contains(leaf) {
                return "Not preselected: careful cleaners leave this app's files alone by default. Quit the app first if you clean it."
            }
        }
        return nil
    }
}
