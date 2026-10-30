import Foundation

/// Newer versions of installed apps, from the place each app updates itself: Homebrew's own records for casks,
/// the app's Sparkle feed (the address in its Info.plist), and Apple's public lookup for App Store apps.
/// Nothing is downloaded or installed while checking.
public struct AppUpdate: Sendable, Identifiable, Hashable {
    public enum Source: Sendable, Hashable {
        /// Homebrew cask token.
        case homebrew(String)
        /// The app's own updater (Sparkle) and its feed.
        case sparkle(URL)
        /// App Store item ID.
        case appStore(Int)
    }
    public var id: String { app.path }
    public let app: InstalledApp
    public let installed: String
    public let latest: String
    public let source: Source
    /// Release notes or the app's page, when the source gives one.
    public let notes: URL?

    public var sourceName: String {
        switch source {
        case .homebrew: "Homebrew"
        case .sparkle: "The app's own updater"
        case .appStore: "App Store"
        }
    }

    /// How the update is installed, in one line.
    public var howTo: String {
        switch source {
        case .homebrew(let t): "Sapu2 runs `brew upgrade --cask \(t)`. If it needs your password, finish it in Terminal."
        case .sparkle: "Open the app and choose Check for Updates; it downloads and installs the new version itself."
        case .appStore: "Opens the App Store's page for the app, where you choose Update."
        }
    }
}

public enum AppUpdates {
    /// Every app with a newer version, biggest version jump first is not meaningful, so by name.
    public static func check(_ apps: [InstalledApp], progress: @Sendable (String) -> Void = { _ in }) async -> [AppUpdate] {
        var found: [String: AppUpdate] = [:]
        progress("Reading Homebrew's records")
        for u in homebrew(apps) { found[u.app.path] = u }
        let rest = apps.filter { found[$0.path] == nil }
        progress("Checking each app's update feed")
        await withTaskGroup(of: AppUpdate?.self) { group in
            var it = rest.makeIterator()
            func next() -> Bool {
                guard let app = it.next() else { return false }
                group.addTask { await lookup(app) }
                return true
            }
            for _ in 0..<8 where next() {}
            while let r = await group.next() {
                if let r { found[r.app.path] = r }
                _ = next()
            }
        }
        return found.values.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    static func lookup(_ app: InstalledApp) async -> AppUpdate? {
        if app.fromAppStore, let id = app.bundleID { return await appStore(app, bundleID: id) }
        if let feed = feedURL(app) { return await sparkle(app, feed: feed) }
        return nil
    }

    // MARK: Homebrew

    /// Casks Homebrew knows a newer version of (as of its last `brew update`). Casks that update themselves are left to their own updater.
    static func homebrew(_ apps: [InstalledApp]) -> [AppUpdate] {
        guard let brew = Shell.which("brew"), apps.contains(where: { $0.caskToken != nil }) else { return [] }
        let r = Shell.run([brew, "outdated", "--cask", "--json=v2"], timeout: 60)
        return parseBrew(Data(r.out.utf8), apps: apps)
    }

    public static func parseBrew(_ data: Data, apps: [InstalledApp]) -> [AppUpdate] {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let casks = j["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { c in
            guard let token = c["name"] as? String, let latest = c["current_version"] as? String,
                  let app = apps.first(where: { $0.caskToken == token }) else { return nil }
            let installed = (c["installed_versions"] as? [String])?.last ?? app.version ?? "?"
            return AppUpdate(app: app, installed: installed, latest: latest, source: .homebrew(token),
                             notes: URL(string: "https://formulae.brew.sh/cask/\(token)"))
        }
    }

    // MARK: Sparkle

    static func feedURL(_ app: InstalledApp) -> URL? {
        guard let info = NSDictionary(contentsOfFile: app.path + "/Contents/Info.plist"),
              let s = info["SUFeedURL"] as? String, let u = URL(string: s), u.scheme == "https" else { return nil }
        return u
    }

    static func sparkle(_ app: InstalledApp, feed: URL) async -> AppUpdate? {
        guard let data = await fetch(feed) else { return nil }
        let info = NSDictionary(contentsOfFile: app.path + "/Contents/Info.plist")
        let short = info?["CFBundleShortVersionString"] as? String ?? app.version ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        guard let best = newest(parseAppcast(data), os: ProcessInfo.processInfo.operatingSystemVersion) else { return nil }
        let newer: Bool
        if let s = best.short, !short.isEmpty { newer = VersionAudit.compare(s, short) > 0 }
        else { newer = VersionAudit.compare(best.version, build) > 0 }
        guard newer else { return nil }
        return AppUpdate(app: app, installed: short.isEmpty ? build : short, latest: best.short ?? best.version, source: .sparkle(feed), notes: best.notes)
    }

    public struct AppcastItem: Sendable, Hashable {
        public var version = ""
        public var short: String?
        public var channel: String?
        public var minimumOS: String?
        public var notes: URL?
    }

    /// The newest release for everyone (no beta channel) that runs on this macOS.
    public static func newest(_ items: [AppcastItem], os: OperatingSystemVersion) -> AppcastItem? {
        let mine = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return items.filter { $0.channel == nil && !$0.version.isEmpty && ($0.minimumOS.map { VersionAudit.compare($0, mine) <= 0 } ?? true) }
            .max { VersionAudit.compare($0.short ?? $0.version, $1.short ?? $1.version) < 0 }
    }

    public static func parseAppcast(_ data: Data) -> [AppcastItem] {
        let p = AppcastParser()
        let x = XMLParser(data: data)
        x.shouldProcessNamespaces = false
        x.delegate = p
        x.parse()
        return p.items
    }

    final class AppcastParser: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        var current: AppcastItem?
        var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            text = ""
            if name == "item" { current = AppcastItem() }
            if name == "enclosure", current != nil {
                if let v = a["sparkle:version"] { current?.version = v }
                if let s = a["sparkle:shortVersionString"] { current?.short = s }
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "item": if let c = current { items.append(c) }; current = nil
            case "sparkle:version": if !t.isEmpty { current?.version = t }
            case "sparkle:shortVersionString": if !t.isEmpty { current?.short = t }
            case "sparkle:channel": current?.channel = t
            case "sparkle:minimumSystemVersion": current?.minimumOS = t
            case "sparkle:releaseNotesLink", "sparkle:fullReleaseNotesLink": if current?.notes == nil { current?.notes = URL(string: t) }
            case "link": if current != nil, current?.notes == nil, let u = URL(string: t), u.scheme == "https" { current?.notes = u }
            default: break
            }
            text = ""
        }
    }

    // MARK: App Store

    static func appStore(_ app: InstalledApp, bundleID: String) async -> AppUpdate? {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [URLQueryItem(name: "bundleId", value: bundleID), URLQueryItem(name: "entity", value: "macSoftware")]
        guard let url = c.url, let data = await fetch(url),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let r = (j["results"] as? [[String: Any]])?.first,
              let latest = r["version"] as? String, let id = r["trackId"] as? Int,
              let installed = app.version, VersionAudit.compare(latest, installed) > 0 else { return nil }
        return AppUpdate(app: app, installed: installed, latest: latest, source: .appStore(id),
                         notes: (r["trackViewUrl"] as? String).flatMap(URL.init))
    }

    public static func appStoreURL(_ id: Int) -> URL { URL(string: "macappstore://apps.apple.com/app/id\(id)")! }

    static func fetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Sapu2", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Runs Homebrew's own upgrade for one cask. Casks that install a package need a password Sapu2 can't give; those say so.
    public static func upgrade(_ u: AppUpdate) -> (ok: Bool, message: String) {
        guard case .homebrew(let token) = u.source, let brew = Shell.which("brew") else { return (false, "Not a Homebrew app.") }
        let r = Shell.run([brew, "upgrade", "--cask", token], timeout: 1800)
        if r.status == 0 { return (true, "\(u.app.name) is now \(u.latest).") }
        let err = (r.err + r.out)
        if err.contains("sudo") || err.contains("password") { return (false, "Needs your password. Run `brew upgrade --cask \(token)` in Terminal to finish.") }
        return (false, "Homebrew couldn't update it: \(err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))")
    }
}
