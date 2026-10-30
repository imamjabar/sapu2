import Foundation

/// Plain-language explanations for what a scan finds: what it is, what removing it costs, the right way to free the
/// space, and whether it comes back. One rule per kind of thing; the first rule whose fragments match the path wins.
///
/// Rules for writing an explanation (keep every new rule to these):
/// 1. `plain`: one or two sentences a non-developer understands. Name the tool, say what it keeps and why it grows.
/// 2. `impact`: what the person loses or waits for after removing it, in time or effort, never "may cause issues".
/// 3. `bestWay`: the right way to free the space. If the owning tool has its own command, name it and put it in
///    `commands` exactly as typed; deleting by hand is the fallback, not the advice.
/// 4. `comesBack`: whether and when it refills, so people know a clean is not permanent.
/// 5. Never alarm, never sell. Facts the person can check.
public enum Explainer {
    public enum Impact: Int, Sendable, Comparable {
        /// Nothing noticeable.
        case none
        /// A slower first launch or build.
        case low
        /// A re-download or reinstall that takes minutes.
        case medium
        /// Data or work that can't simply be rebuilt.
        case high
        public static func < (a: Impact, b: Impact) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .none: "No impact"
            case .low: "Small: a slower first run"
            case .medium: "Medium: a re-download or reinstall"
            case .high: "High: may lose data"
            }
        }
    }

    public struct Explanation: Sendable {
        public let plain: String
        public let impact: Impact
        public let impactText: String
        public let bestWay: String
        public let commands: [String]
        public let comesBack: String
    }

    struct Rule {
        /// Any of these matches, lowercased: "=name" is the item's own folder or file name, "~.ext" its ending,
        /// anything else a piece of its path or title.
        let fragments: [String]
        let e: Explanation
    }

    /// Rows ask on every redraw, so answers are kept per path and title.
    nonisolated(unsafe) private static var memo: [String: Explanation?] = [:]
    private static let lock = NSLock()

    public static func explain(_ f: Finding) -> Explanation? {
        let key = f.path + "\u{0}" + f.title
        lock.lock(); defer { lock.unlock() }
        if let hit = memo[key] { return hit }
        let e = match(f)
        memo[key] = e
        return e
    }

    private static func match(_ f: Finding) -> Explanation? {
        let p = f.path.lowercased(), t = f.title.lowercased(), name = (p as NSString).lastPathComponent
        func hit(_ x: String) -> Bool {
            if x.hasPrefix("=") { return name == x.dropFirst() }
            if x.hasPrefix("~") { return name.hasSuffix(x.dropFirst()) }
            return p.contains(x) || t.contains(x)
        }
        return rules.first { $0.fragments.contains(where: hit) }?.e
    }

    /// Every fragment, for the uniqueness selftest.
    public static var allFragments: [String] { rules.flatMap(\.fragments) }

    private static func r(_ fragments: [String], plain: String, impact: Impact, _ impactText: String, best: String, _ commands: [String] = [],
                          back: String) -> Rule {
        Rule(fragments: fragments, e: Explanation(plain: plain, impact: impact, impactText: impactText, bestWay: best, commands: commands, comesBack: back))
    }

    static let rules: [Rule] = [
        // MARK: Virtual machines and containers
        r(["/.colima"],
          plain: "Colima runs Docker on your Mac inside a small Linux virtual machine. This file is that machine's hard disk: every Docker image, container and volume you've used lives inside it.",
          impact: .high, "Deleting the file by hand breaks Colima and loses every image, container and volume in it, including any database data stored in volumes.",
          best: "Free space from inside Docker first; it shrinks what's stored but the disk file may stay large. To start over completely, delete the machine with Colima itself.",
          ["docker system df", "docker system prune", "colima delete"],
          back: "Grows again as you pull images and build containers."),
        r(["/library/containers/com.docker.docker/", "docker.raw"],
          plain: "Docker Desktop keeps all your images, containers, volumes and build cache in one big disk file.",
          impact: .high, "Removing the file by hand loses every image, container and volume. Databases in volumes are gone.",
          best: "Let Docker clean itself: prune unused images and build cache, or lower the disk limit in Docker Desktop › Settings › Resources.",
          ["docker system df", "docker system prune -a", "docker builder prune"],
          back: "Grows as you pull and build."),
        r(["/.orbstack", "/group.dev.orbstack/"],
          plain: "OrbStack's Linux machine and Docker data: images, containers, volumes.",
          impact: .high, "Deleting by hand loses containers and volumes.",
          best: "Prune from Docker, or remove machines in OrbStack's own window.",
          ["docker system prune", "orb list"],
          back: "Grows as you use containers."),
        r(["/.lima"],
          plain: "Lima virtual machines (used by Colima, Rancher and others). Each has its own disk.",
          impact: .high, "Deleting by hand breaks the machine and loses what's inside.",
          best: "Remove machines you no longer need with Lima.",
          ["limactl list", "limactl delete <name>"],
          back: "Only if you create the machine again."),
        r(["/parallels/", ".pvm"], plain: "A Parallels virtual machine: a whole computer stored as a file.",
          impact: .high, "Removing it deletes that virtual computer and everything on it.",
          best: "Delete unused machines from Parallels' Control Center, which also cleans its snapshots.", back: "Never, unless you reinstall it."),
        r(["/utm/", ".utm"], plain: "A UTM virtual machine: a whole computer stored as a file.",
          impact: .high, "Removing it deletes that virtual computer and everything on it.",
          best: "Delete unused machines from UTM's window.", back: "Never, unless you reinstall it."),

        // MARK: ML
        r(["/.cache/huggingface"],
          plain: "Models and datasets downloaded by Hugging Face libraries (transformers, datasets, diffusers). One model is often several gigabytes.",
          impact: .medium, "The next run that needs a removed model downloads it again, which can take minutes to hours on a slow connection.",
          best: "Remove only the models you no longer use, with Hugging Face's own tool.",
          ["huggingface-cli scan-cache", "huggingface-cli delete-cache"],
          back: "Each model returns the next time code asks for it."),
        r(["/.ollama"],
          plain: "Ollama's local language models. Each model is a few gigabytes.",
          impact: .medium, "Removed models must be pulled again before you can chat with them.",
          best: "List and remove models with Ollama.", ["ollama list", "ollama rm <model>"],
          back: "Only when you pull a model again."),
        r(["/.lmstudio", "/lm studio/"],
          plain: "LM Studio's downloaded models.", impact: .medium, "Removed models must be downloaded again.",
          best: "Delete models from LM Studio's My Models page.", back: "Only when you download again."),
        r(["/anaconda3", "/miniconda3", "/miniforge3", "/.conda"],
          plain: "A conda installation: Python, its environments, and a cache of every package version it downloaded.",
          impact: .medium, "Removing environments breaks projects that use them until you recreate them. The package cache only costs re-downloads.",
          best: "Clean conda's cache first; it's often several gigabytes and safe. Remove environments you don't use by name.",
          ["conda clean --all", "conda env list", "conda env remove -n <name>"],
          back: "The cache refills as you install packages."),
        r(["/.cache/torch", "/.keras"],
          plain: "Pretrained model weights downloaded by PyTorch or Keras.", impact: .medium, "Downloaded again the next time code loads them.",
          best: "Safe to remove models you no longer use.", back: "When code needs them again."),

        // MARK: Project build output
        r(["=node_modules"],
          plain: "The packages this JavaScript project installed (npm, pnpm, Yarn or Bun). Every project keeps its own full copy, which is why they add up.",
          impact: .medium, "You run an install before the next build or dev server; usually under two minutes with a warm cache.",
          best: "Safe to remove for projects you're not working on. With a lockfile, a reinstall gets exactly the same versions.",
          ["npm install", "pnpm install", "npx npkill"],
          back: "When you run install in the project again."),
        r(["=.venv", "=venv", "=env"],
          plain: "This Python project's virtual environment: its own copy of Python and every package it installed.",
          impact: .medium, "You recreate it and reinstall packages before running the project again.",
          best: "Remove it for idle projects; recreate from requirements.txt, pyproject.toml or uv.lock.",
          ["python3 -m venv .venv && .venv/bin/pip install -r requirements.txt", "uv sync"],
          back: "When you recreate it."),
        r(["=target"],
          plain: "Rust (or Maven) build output: compiled code for every build profile. Rust projects reach several gigabytes quickly.",
          impact: .low, "The next build compiles from scratch, which takes longer once.",
          best: "Let the build tool clean it.", ["cargo clean", "mvn clean"],
          back: "On the next build."),
        r(["=.next", "=.nuxt", "=.svelte-kit", "=.turbo", "=.parcel-cache", "/.angular/cache"],
          plain: "A web framework's build cache (Next.js, Nuxt, SvelteKit, Turborepo…). It only speeds up rebuilds.",
          impact: .low, "The next dev start or build is slower once.",
          best: "Safe to remove at any time when the dev server isn't running.", back: "On the next build or dev start."),
        r(["=dist", "=build", "=out"],
          plain: "Files a build produced from your source code. The source itself is not here.",
          impact: .low, "Rebuilt by your build command. Check first if this project ships this folder in git or deploys from it.",
          best: "Safe for idle projects; rebuild with the project's build command.", back: "On the next build."),
        r(["=pods"],
          plain: "CocoaPods dependencies for an iOS or macOS project.", impact: .medium, "Run pod install before building again.",
          best: "Remove for idle projects.", ["pod install"], back: "When you run pod install."),
        r(["=vendor"],
          plain: "Third-party packages copied into the project (PHP Composer, Go, Ruby).", impact: .medium,
          "Reinstall before running. If vendor is committed to git, removing it shows as a change.",
          best: "Reinstall with the project's package manager.", ["composer install", "go mod vendor", "bundle install"], back: "When you reinstall."),

        // MARK: Package caches
        r(["/.npm/", "=.npm"], plain: "npm's download cache: a copy of every package version npm fetched, shared by all projects.",
          impact: .low, "Installs download packages again, a bit slower once.", best: "Let npm verify and trim it, or remove it.", ["npm cache clean --force"],
          back: "As you install packages."),
        r(["/library/pnpm/", "/.pnpm-store", "/.local/share/pnpm"], plain: "pnpm's content store: one copy of each package version, linked into every project.",
          impact: .low, "Packages download again on the next install.", best: "Prune versions no project uses.", ["pnpm store prune"], back: "As you install."),
        r(["/library/caches/yarn", "/.yarn/berry/cache", "/.yarn/cache"], plain: "Yarn's download cache.", impact: .low, "Packages download again on install.",
          best: "Let Yarn clean it.", ["yarn cache clean"], back: "As you install."),
        r(["/.bun/install/cache"], plain: "Bun's package cache.", impact: .low, "Packages download again on install.", best: "Clear with Bun.", ["bun pm cache rm"], back: "As you install."),
        r(["/library/caches/pip", "/.cache/pip"], plain: "pip's download and wheel cache.", impact: .low, "Packages download again on install.",
          best: "Let pip clear it.", ["pip cache purge"], back: "As you install."),
        r(["/.cache/uv", "/library/caches/uv"], plain: "uv's package cache, shared by all your Python projects.", impact: .low, "Packages download again on the next sync.",
          best: "Let uv prune it.", ["uv cache prune", "uv cache clean"], back: "As you install."),
        r(["/.cargo/registry", "/.cargo/git"], plain: "Cargo's downloaded crate sources and git dependencies.", impact: .low, "Crates download again on the next build.",
          best: "Trim with cargo-cache, or remove.", ["cargo install cargo-cache && cargo cache --autoclean"], back: "On the next build."),
        r(["/go/pkg/mod", "/library/caches/go-build"], plain: "Go's module download cache and build cache.", impact: .low, "Modules download and packages compile again once.",
          best: "Let Go clean it.", ["go clean -modcache", "go clean -cache"], back: "On the next build."),
        r(["/.gradle"], plain: "Gradle's caches and downloaded wrappers for Android and Java builds. Old versions pile up.", impact: .low,
          "The next build downloads dependencies again and is slower once.", best: "Stop the daemons, then remove the caches.", ["./gradlew --stop"], back: "On the next build."),
        r(["/.m2/repository"], plain: "Maven's local repository: every Java dependency ever downloaded.", impact: .low, "Dependencies download again on the next build.",
          best: "Safe to remove; Maven fetches what it needs.", back: "On the next build."),
        r(["/library/caches/homebrew", "/homebrew/cache"], plain: "Homebrew's downloads: installers and bottles of packages you already installed.", impact: .none,
          "Nothing; installed software keeps working.", best: "Let Homebrew clean old downloads.", ["brew cleanup --prune=all"], back: "When you install or upgrade."),
        r(["/library/caches/cocoapods"], plain: "CocoaPods' download cache.", impact: .low, "Pods download again.", best: "Clear with CocoaPods.", ["pod cache clean --all"], back: "On pod install."),
        r(["/.pub-cache"], plain: "Dart and Flutter's package cache.", impact: .low, "Packages download again on the next pub get.", best: "Let Flutter clean it.",
          ["flutter pub cache clean"], back: "On the next pub get."),

        // MARK: Xcode
        r(["/deriveddata"], plain: "Xcode's build products and indexes for every project you've opened. Often the largest Xcode folder.",
          impact: .low, "The next build and indexing of each project take longer once.", best: "Safe to remove with Xcode closed.", back: "When you build again."),
        r(["/coresimulator/devices"], plain: "iOS, watchOS and other simulators, each with its own apps and data.",
          impact: .medium, "Apps and data inside removed simulators are lost; you create simulators again in Xcode.",
          best: "Remove simulators for old runtimes with Xcode's tool.", ["xcrun simctl delete unavailable", "xcrun simctl list"], back: "When you create or boot simulators."),
        r(["/ios devicesupport", "/watchos devicesupport"], plain: "Debug symbols Xcode copied from each iPhone or Watch version you connected.",
          impact: .low, "Connecting that device again makes Xcode copy them again, a few minutes.", best: "Safe to remove versions you no longer test on.", back: "When you connect the device."),
        r(["/xcode/archives"], plain: "App archives you built for release, with their debug symbols.", impact: .high,
          "You can't symbolicate crash reports from a removed release.", best: "Keep archives of versions still in users' hands.", back: "Never."),

        // MARK: Editors and AI tools
        r(["/.cache/codex-runtimes"], plain: "Runtimes the Codex CLI downloaded to run code for you (Node, Python and similar).",
          impact: .low, "Codex downloads what it needs again the next time it runs code.", best: "Safe when Codex isn't running.", back: "When Codex needs a runtime."),
        r(["/.gemini"], plain: "Gemini CLI's settings, saved chats and per-project checkpoints.", impact: .high,
          "Chats and checkpoints are gone; settings reset.", best: "Remove only old checkpoints you don't need, from Gemini CLI.", back: "New chats are saved as you use it."),
        r(["/.claude"], plain: "Claude Code's settings, memory and conversation history.", impact: .high,
          "Conversation history and memory are lost.", best: "Leave it unless you mean to reset Claude Code.", back: "As you use it."),
        r(["/.cursor", "/library/application support/cursor/"], plain: "Cursor's extensions, settings and editor state.", impact: .medium,
          "Extensions and workspace state are reinstalled or reset.", best: "Clear caches from inside Cursor; keep settings.", back: "As you use Cursor."),
        r(["/library/application support/code/"], plain: "VS Code's caches, workspace state and extension data.", impact: .low,
          "Caches rebuild on launch; workspace state (open tabs, history) can reset.", best: "Quit VS Code first.", back: "As you use VS Code."),

        // MARK: Apps and macOS
        r(["mediaanalysisd"], plain: "macOS's photo and video analysis cache (faces, objects, text in images) used by Photos and Spotlight.",
          impact: .low, "macOS analyses your library again in the background, using some battery for a while.", best: "Leave it to macOS; it trims this itself.",
          back: "macOS rebuilds it in the background."),
        r(["(previous version)", "/old_versions", "/.old"], plain: "A previous version an app kept after updating itself, so it can roll back.",
          impact: .none, "You can't roll back to that version.", best: "Safe to remove once the new version works.", back: "After the next update."),
        r(["/library/caches/"], plain: "An app's cache: things it downloaded or computed so it opens and loads faster.",
          impact: .low, "The app is a little slower the first time and refills what it needs.", best: "Quit the app first, then clean.", back: "As you use the app."),
        r(["/library/logs/", "~.log"], plain: "Log files: records apps write about what they did, mostly for troubleshooting.",
          impact: .none, "Only lost if you were about to send them to support.", best: "Old logs can go; active ones are emptied in place.", back: "As apps keep logging."),
        // MARK: More tool caches, emulators and logs
        r(["/xcode/userdata/previews"], plain: "SwiftUI preview helpers: the simulators and build output Xcode uses to draw the canvas next to your code.",
          impact: .low, "The next preview in Xcode takes longer to start while it builds again.", best: "Quit Xcode, then clean.", back: "When you open a preview."),
        r(["/coresimulator/caches"], plain: "Runtime caches the iOS Simulator keeps so its devices start faster.",
          impact: .low, "The first simulator launch afterwards is slower.", best: "Quit Simulator, then clean.", back: "Rebuilt on the next launch."),
        r(["/xcode/sourcepackages"], plain: "Swift packages that Xcode downloaded for your projects, one checkout per version.",
          impact: .low, "Xcode downloads the packages again on the next build, which needs internet.", best: "In Xcode use File › Packages › Reset Package Caches, or delete the folder with Xcode closed.", back: "On the next build of a project that uses packages."),
        r(["/xctestdevices"], plain: "Copies of simulators that Xcode made for parallel test runs and did not remove.",
          impact: .none, "Xcode makes new copies for the next parallel test run.", best: "Safe to clean with Xcode closed.", back: "After the next parallel test run."),
        r(["/coresimulator/images/inbox"], plain: "Simulator runtimes that were downloaded and are waiting to be installed, or that a failed install left behind.",
          impact: .medium, "A runtime you still wanted to install has to download again (several GB).", best: "Check Xcode › Settings › Components first. Clean only if nothing is installing.", back: "When you add a runtime."),
        r(["/.nuget/packages"], plain: "Every .NET package version that any of your projects restored.",
          impact: .medium, "dotnet restore downloads the packages again; large solutions can take minutes.", best: "dotnet can clear it itself.", ["dotnet nuget locals all --clear"],
          back: "On the next restore or build."),
        r(["/.cache/puppeteer"], plain: "Full Chrome builds that Puppeteer downloads, one for each version it needs.",
          impact: .low, "Scripts that use Puppeteer download Chrome again on their next run.", best: "Delete the folder, or install the version you need again.", ["npx puppeteer browsers install chrome"],
          back: "On the next run of a Puppeteer script."),
        r(["/.cache/bazel", "/library/caches/bazel"], plain: "Bazel's output folders and download cache for every workspace you built.",
          impact: .medium, "The next build of each workspace starts from zero and can take a long time.", best: "Let Bazel remove what it owns.", ["bazel clean --expunge"],
          back: "On the next Bazel build."),
        r(["/.terraform.d/plugin-cache"], plain: "Provider downloads that Terraform shares between projects.",
          impact: .low, "terraform init downloads the providers again.", best: "Delete the folder when no terraform command is running.", back: "On the next terraform init."),
        r(["/.cache/zig"], plain: "Zig's compiled output and package downloads.",
          impact: .low, "The next Zig build compiles everything again.", best: "Delete the folder when no build is running.", back: "On the next build."),
        r(["/.android/avd"], plain: "The virtual disks of your Android emulators, with the apps and data you put on them.",
          impact: .high, "An emulator you delete loses its apps and data. You can create it again in Device Manager.", best: "Delete emulators you no longer use in Android Studio › Device Manager.", back: "Only if you create the emulator again."),
        r(["/android/sdk/system-images"], plain: "Android operating system images that the emulator needs, one for each API level.",
          impact: .medium, "Emulators on that API level stop starting until you download the image again.", best: "Remove old API levels in Android Studio › SDK Manager.", back: "When you download an image again."),
        r(["/.tart/cache"], plain: "VM images that Tart pulled from a registry. Your own VMs are kept apart in ~/.tart/vms.",
          impact: .medium, "Creating the next VM from that image downloads it again (several GB).", best: "Remove images you no longer use with Tart.", ["tart list", "tart delete <name>"],
          back: "When you create a VM from the image."),
        r(["/opt/homebrew/var/log", "/mamp/logs"], plain: "Logs of local services (nginx, PHP, MySQL, Postgres, MAMP). A service that keeps failing can write several GB.",
          impact: .none, "You lose the history that helps debug an error. The service keeps working.", best: "Sapu2 empties the file in place, so the running service keeps writing.", back: "As the service writes again."),
        r(["/claude/crashpad"], plain: "Crash reports that the Claude app has already sent.",
          impact: .none, "Nothing. They were sent.", best: "Safe to clean.", back: "If the app crashes again."),
        r(["uuremote.updater"], plain: "Installers that an updater downloaded and kept after the update.",
          impact: .none, "Nothing, the update is done.", best: "Safe to clean.", back: "At the next update."),
        r(["/itunes/iphone software updates", "/itunes/ipad software updates", "/itunes/ipod software updates"], plain: "iOS firmware files that Finder downloaded to update or restore a device.",
          impact: .low, "Finder downloads the firmware again the next time you update or restore the device.", best: "Safe to clean when no update is running.", back: "At the next device update."),
        r(["/downloads/"], plain: "A file you downloaded. Sapu2 can't know if you still need it.",
          impact: .high, "If you need it again you must find and download it again, or it may be gone for good.",
          best: "Open it or Show in Finder and decide. Move keepers to iCloud or an external drive.", back: "Never."),
    ]
}
