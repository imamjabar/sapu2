import Foundation

/// A known location on macOS with an explanation of why it grows and how to clean it.
public struct Rule: Sendable {
    public var id: String
    public var title: String
    public var category: Category
    /// Paths with `~`. A trailing `/*` means "each child is its own item".
    public var paths: [String]
    public var safety: Safety
    public var reason: String
    public var usedFor: String
    public var owner: String
    public var rebuild: String?
    public var action: CleanAction
    /// Lock the item while one of these processes runs (matched against executable names).
    public var whileRunning: [String] = []
    /// Ignore items smaller than this.
    public var minBytes: Int64 = 1_000_000
}

public enum RuleBook {
    static let mb: Int64 = 1_000_000

    public static let all: [Rule] = [
        // MARK: Xcode & Simulators
        Rule(id: "xcode.deriveddata", title: "Xcode DerivedData", category: .xcode,
             paths: ["~/Library/Developer/Xcode/DerivedData"], safety: .safe,
             reason: "Every project Xcode opens gets its own build folder with indexes, intermediate objects and products. Old projects are never removed.",
             usedFor: "Incremental builds and code indexing in Xcode.", owner: "Xcode",
             rebuild: "Xcode rebuilds it on the next build (first build is slower).", action: .trash, whileRunning: ["Xcode"]),
        Rule(id: "xcode.devicesupport", title: "iOS DeviceSupport", category: .xcode,
             paths: ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport"], safety: .safe,
             reason: "Symbol files copied from every iPhone/Watch OS version you ever connected — several GB per version.",
             usedFor: "Debugging on a physical device.", owner: "Xcode",
             rebuild: "Re-copied when you connect the device again.", action: .trash, whileRunning: ["Xcode"]),
        Rule(id: "xcode.archives", title: "Xcode Archives", category: .xcode,
             paths: ["~/Library/Developer/Xcode/Archives"], safety: .check,
             reason: "Each App Store / TestFlight build you archived is kept with its dSYMs.",
             usedFor: "Symbolicating crash reports for shipped versions.", owner: "Xcode",
             rebuild: "Cannot be rebuilt exactly — keep archives of versions still in users' hands.", action: .trash),
        Rule(id: "xcode.previews", title: "SwiftUI Previews cache", category: .xcode,
             paths: ["~/Library/Developer/Xcode/UserData/Previews"], safety: .safe,
             reason: "Preview simulators and build products for SwiftUI canvas.", usedFor: "SwiftUI previews.", owner: "Xcode",
             rebuild: "Recreated when you open a preview.", action: .trash, whileRunning: ["Xcode"]),
        Rule(id: "sim.caches", title: "Simulator caches", category: .xcode,
             paths: ["~/Library/Developer/CoreSimulator/Caches"], safety: .safe,
             reason: "Dyld and runtime caches for simulators.", usedFor: "Faster simulator boot.", owner: "Simulator",
             rebuild: "Recreated automatically.", action: .trash, whileRunning: ["Simulator"]),
        Rule(id: "sim.devices", title: "Simulator devices", category: .xcode,
             paths: ["~/Library/Developer/CoreSimulator/Devices"], safety: .check,
             reason: "Every simulator keeps its own disk with installed apps and data; devices for removed runtimes stay behind.",
             usedFor: "Running apps in the iOS Simulator.", owner: "Simulator",
             rebuild: "Only unavailable devices are removed; others keep their data.",
             action: .command("xcrun simctl delete unavailable"), whileRunning: ["Simulator"]),

        // MARK: Package-manager caches
        Rule(id: "npm.cache", title: "npm cache", category: .devCaches, paths: ["~/.npm/_cacache"], safety: .safe,
             reason: "Every package tarball npm ever downloaded, for every project.", usedFor: "Offline/faster npm install.", owner: "npm",
             rebuild: "Re-downloaded on demand.", action: .command("npm cache clean --force")),
        Rule(id: "npm.npx", title: "npx cache", category: .devCaches, paths: ["~/.npm/_npx"], safety: .safe,
             reason: "Full installs of every CLI you ran with npx (each one a private node_modules).", usedFor: "Running npx commands quickly.", owner: "npx",
             rebuild: "Re-installed the next time you run that npx command.", action: .trash),
        Rule(id: "npm.prebuilds", title: "npm prebuilt binaries", category: .devCaches, paths: ["~/.npm/_prebuilds"], safety: .safe,
             reason: "Native add-on binaries (frida, sharp, sqlite3…) downloaded by prebuild-install, one per version you ever installed.",
             usedFor: "Installing native npm packages without compiling.", owner: "npm",
             rebuild: "Downloaded again the next time a package needs one.", action: .trash),
        Rule(id: "yarn.cache", title: "Yarn cache", category: .devCaches, paths: ["~/Library/Caches/Yarn"], safety: .safe,
             reason: "Yarn v1 global offline cache.", usedFor: "Faster yarn install.", owner: "Yarn",
             rebuild: "Re-downloaded on demand.", action: .command("yarn cache clean")),
        // pnpm store: DevExtras.pnpmStores (current store pruned, older layout versions listed apart).
        Rule(id: "bun.cache", title: "Bun install cache", category: .devCaches, paths: ["~/.bun/install/cache"], safety: .safe,
             reason: "Every package version Bun installed.", usedFor: "Fast bun install.", owner: "Bun",
             rebuild: "Re-downloaded on demand.", action: .trash),
        Rule(id: "pip.cache", title: "pip cache", category: .devCaches, paths: ["~/Library/Caches/pip"], safety: .safe,
             reason: "Downloaded wheels and HTTP cache from every pip install.", usedFor: "Faster pip install.", owner: "pip",
             rebuild: "Re-downloaded on demand.", action: .command("python3 -m pip cache purge")),
        Rule(id: "uv.cache", title: "uv cache", category: .devCaches, paths: ["~/.cache/uv"], safety: .safe,
             reason: "Wheels and source builds cached by uv.", usedFor: "Fast uv installs.", owner: "uv",
             rebuild: "Re-downloaded on demand.", action: .command("uv cache clean")),
        Rule(id: "conda.pkgs", title: "Conda package cache", category: .devCaches,
             paths: ["~/miniconda3/pkgs", "~/anaconda3/pkgs", "~/miniforge3/pkgs", "~/opt/anaconda3/pkgs"], safety: .safe,
             reason: "Tarballs and extracted copies of every conda package version ever installed.", usedFor: "Creating environments without re-downloading.", owner: "conda",
             rebuild: "conda keeps what installed environments still link to.", action: .command("conda clean --all -y")),
        Rule(id: "brew.cache", title: "Homebrew downloads", category: .devCaches, paths: ["~/Library/Caches/Homebrew"], safety: .safe,
             reason: "Bottles and source tarballs of every formula you installed or upgraded.", usedFor: "Reinstalling without downloading.", owner: "Homebrew",
             rebuild: "Re-downloaded on demand.", action: .command("brew cleanup --prune=all")),
        Rule(id: "composer.cache", title: "Composer cache", category: .devCaches,
             paths: ["~/Library/Caches/composer", "~/.composer/cache", "~/.cache/composer"], safety: .safe,
             reason: "Zip archives of every PHP package Composer downloaded.", usedFor: "Faster composer install.", owner: "Composer",
             rebuild: "Re-downloaded on demand.", action: .command("composer clear-cache")),
        Rule(id: "go.build", title: "Go build cache", category: .devCaches, paths: ["~/Library/Caches/go-build"], safety: .safe,
             reason: "Compiled packages for every Go build and test run.", usedFor: "Incremental Go builds.", owner: "Go",
             rebuild: "Rebuilt on the next go build.", action: .command("go clean -cache")),
        Rule(id: "go.mod", title: "Go module cache", category: .devCaches, paths: ["~/go/pkg/mod"], safety: .check,
             reason: "Source of every module version any Go project downloaded.", usedFor: "Building Go projects offline.", owner: "Go",
             rebuild: "Re-downloaded by go mod download.", action: .command("go clean -modcache")),
        Rule(id: "cargo.registry", title: "Cargo registry", category: .devCaches, paths: ["~/.cargo/registry"], safety: .check,
             reason: "Crate sources and index for every Rust dependency.", usedFor: "Building Rust projects.", owner: "Cargo",
             rebuild: "Re-downloaded by cargo build.", action: .trash),
        Rule(id: "gradle.caches", title: "Gradle caches", category: .devCaches, paths: ["~/.gradle/caches", "~/.gradle/wrapper/dists"], safety: .check,
             reason: "Dependency jars, transformed artifacts and every Gradle distribution a project wrapper requested.", usedFor: "Android/JVM builds.", owner: "Gradle",
             rebuild: "Re-downloaded on the next build (can be slow).", action: .trash, whileRunning: ["java", "studio"]),
        Rule(id: "maven.repo", title: "Maven repository", category: .devCaches, paths: ["~/.m2/repository"], safety: .check,
             reason: "Every jar Maven resolved.", usedFor: "JVM builds.", owner: "Maven", rebuild: "Re-downloaded on the next build.", action: .trash),
        Rule(id: "cocoapods.cache", title: "CocoaPods cache", category: .devCaches, paths: ["~/Library/Caches/CocoaPods"], safety: .safe,
             reason: "Downloaded pod sources.", usedFor: "pod install.", owner: "CocoaPods", rebuild: "Re-downloaded.", action: .command("pod cache clean --all")),
        Rule(id: "pub.cache", title: "Dart/Flutter pub cache", category: .devCaches, paths: ["~/.pub-cache"], safety: .check,
             reason: "Every Dart package version used by Flutter projects.", usedFor: "flutter pub get.", owner: "Flutter",
             rebuild: "Re-downloaded by flutter pub get.", action: .command("flutter pub cache clean -f")),
        Rule(id: "puppeteer", title: "Puppeteer browsers", category: .devCaches, paths: ["~/.cache/puppeteer"], safety: .safe,
             reason: "Full Chrome builds downloaded per Puppeteer version.", usedFor: "Headless browser automation.", owner: "Puppeteer",
             rebuild: "npx puppeteer browsers install chrome", action: .trash),
        Rule(id: "playwright", title: "Playwright browsers", category: .devCaches, paths: ["~/Library/Caches/ms-playwright"], safety: .check,
             reason: "Chromium, Firefox and WebKit builds per Playwright version.", usedFor: "Playwright tests and scrapers.", owner: "Playwright",
             rebuild: "npx playwright install (or python -m playwright install)", action: .trash),
        Rule(id: "node-gyp", title: "node-gyp headers", category: .devCaches, paths: ["~/Library/Caches/node-gyp", "~/.node-gyp"], safety: .safe,
             reason: "Node.js headers for compiling native addons.", usedFor: "npm install of native modules.", owner: "node-gyp", rebuild: "Re-downloaded.", action: .trash),
        Rule(id: "jetbrains", title: "JetBrains caches", category: .devCaches, paths: ["~/Library/Caches/JetBrains"], safety: .safe,
             reason: "Indexes and local history caches for every IDE version you installed.", usedFor: "IDE indexing.", owner: "JetBrains",
             rebuild: "Re-indexed on open.", action: .trash, whileRunning: ["idea", "pycharm", "webstorm", "phpstorm", "goland", "studio"]),

        // MARK: ML
        Rule(id: "hf.cache", title: "Hugging Face models", category: .ml, paths: ["~/.cache/huggingface"], safety: .check,
             reason: "Model weights and datasets downloaded by transformers/datasets — often GBs per model.", usedFor: "Loading models offline.", owner: "Hugging Face",
             rebuild: "Re-downloaded on next from_pretrained (slow for big models).", action: .trash),
        Rule(id: "torch.hub", title: "PyTorch hub cache", category: .ml, paths: ["~/.cache/torch"], safety: .check,
             reason: "Pretrained weights fetched by torch.hub/torchvision.", usedFor: "Loading pretrained models.", owner: "PyTorch",
             rebuild: "Re-downloaded on demand.", action: .trash),
        Rule(id: "ollama", title: "Ollama models", category: .ml, paths: ["~/.ollama/models"], safety: .yours,
             reason: "Local LLM weights pulled with ollama pull.", usedFor: "Running local models.", owner: "Ollama",
             rebuild: "ollama pull <model>", action: .command("ollama rm <model>")),

        // MARK: Containers & VMs
        Rule(id: "docker.desktop", title: "Docker Desktop disk", category: .containers, paths: ["~/Library/Containers/com.docker.docker"], safety: .check,
             reason: "One virtual disk holding every image, container, build cache and volume. It grows and does not shrink by itself.", usedFor: "Docker containers.", owner: "Docker Desktop",
             rebuild: "Prune keeps volumes (your databases). Images are re-pulled.", action: .command("docker system prune -f"), whileRunning: ["com.docker.backend"]),
        Rule(id: "colima", title: "Colima VM", category: .containers, paths: ["~/.colima", "~/.lima"], safety: .check,
             reason: "Linux VM disk used by Colima/Lima for Docker.", usedFor: "Docker without Docker Desktop.", owner: "Colima",
             rebuild: "Prune inside the VM keeps volumes.", action: .command("docker system prune -f"), whileRunning: ["limactl"]),
        Rule(id: "android.avd", title: "Android emulators", category: .containers, paths: ["~/.android/avd"], safety: .check,
             reason: "Disk images of every Android Virtual Device.", usedFor: "Android emulator.", owner: "Android Studio",
             rebuild: "Recreate in Device Manager.", action: .trash, whileRunning: ["qemu-system-aarch64"]),
        Rule(id: "android.sysimg", title: "Android system images", category: .containers, paths: ["~/Library/Android/sdk/system-images"], safety: .check,
             reason: "Emulator OS images per API level.", usedFor: "Creating emulators.", owner: "Android SDK",
             rebuild: "Re-download in SDK Manager.", action: .trash),

        // MARK: Logs
        Rule(id: "brew.logs", title: "Homebrew service logs", category: .logs, paths: ["/opt/homebrew/var/log/*"], safety: .safe,
             reason: "Logs from brew services (php-fpm, nginx, mysql, postgres…). A crash-looping service can write GBs.", usedFor: "Debugging local services.", owner: "Homebrew services",
             rebuild: "Not needed. Files are emptied in place so running services keep writing.", action: .truncateLogs, minBytes: 50 * mb),
        Rule(id: "mamp.logs", title: "MAMP logs", category: .logs, paths: ["/Applications/MAMP/logs"], safety: .safe,
             reason: "Apache, PHP and MySQL logs from MAMP. php_error.log grows forever with notices from local sites.", usedFor: "Debugging MAMP sites.", owner: "MAMP",
             rebuild: "Not needed.", action: .truncateLogs, minBytes: 50 * mb),
        Rule(id: "mamp.db", title: "MAMP databases", category: .appData, paths: ["/Applications/MAMP/db"], safety: .yours,
             reason: "MySQL data directories for your MAMP sites.", usedFor: "Local WordPress/Laravel databases.", owner: "MAMP",
             rebuild: "Export with mysqldump before removing anything.", action: .none),
        Rule(id: "user.logs", title: "App logs", category: .logs, paths: ["~/Library/Logs/*"], safety: .safe,
             reason: "Diagnostic logs written by apps; old ones are rarely rotated.", usedFor: "Troubleshooting.", owner: "Apps",
             rebuild: "Not needed.", action: .trash, minBytes: 50 * mb),

        // MARK: Other
        Rule(id: "ios.updates", title: "iOS update files", category: .appData,
             paths: ["~/Library/iTunes/iPhone Software Updates", "~/Library/iTunes/iPad Software Updates"], safety: .safe,
             reason: "Full iOS firmware downloaded by Finder for device updates.", usedFor: "Restoring/updating a device.", owner: "Finder",
             rebuild: "Re-downloaded when needed.", action: .trash),
        Rule(id: "ios.backups", title: "iPhone/iPad backups", category: .appData, paths: ["~/Library/Application Support/MobileSync/Backup/*"], safety: .yours,
             reason: "Local device backups made by Finder — often tens of GB each.", usedFor: "Restoring your phone.", owner: "Finder",
             rebuild: "Cannot be rebuilt. Manage in Finder → device → Manage Backups.", action: .none),
        Rule(id: "trash", title: "Trash", category: .trash, paths: ["~/.Trash"], safety: .check,
             reason: "Items you moved to the Trash still use space until it is emptied.", usedFor: "Undoing deletes.", owner: "Finder",
             rebuild: "Emptying the Trash is permanent.", action: .none),
    ]

    /// Folders under `~/Library/Caches` that rules above already cover.
    static let coveredCacheNames: Set<String> = [
        "Yarn", "pip", "Homebrew", "composer", "go-build", "CocoaPods", "ms-playwright", "node-gyp", "JetBrains",
    ]

    /// Expand rule paths (handles a trailing `/*`).
    public static func expand(_ pattern: String) -> [String] {
        let p = pattern.expandingTilde
        if p.hasSuffix("/*") {
            let dir = String(p.dropLast(2))
            return DiskSizer.children(dir).filter { !DiskSizer.isSymlink($0) }
        }
        return DiskSizer.exists(p) && !DiskSizer.isSymlink(p) ? [p] : []
    }
}
