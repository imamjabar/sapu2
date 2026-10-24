# Sapu

**A careful disk cleaner for developers on macOS.** Sapu (Indonesian for *broom*) finds what is eating your disk, explains *why* each item takes space and *which project or app* owns it, and cleans only what comes back by itself, without touching the projects you're working on.

- Native SwiftUI, about 1.5 MB download, around 30 MB of memory while scanning
- Apple Silicon, macOS 14 Sonoma or later
- No accounts, no telemetry. The only network call is the optional version check against [endoflife.date](https://endoflife.date)

## Install

1. Download `Sapu-macOS-arm64.dmg` from [Releases](../../releases).
2. Open it and drag **Sapu** to **Applications**.
3. On first launch, if macOS says it cannot verify the app, open **System Settings → Privacy & Security** and choose **Open Anyway**. Sapu is ad-hoc signed, not notarized.
4. Optional: grant **Full Disk Access** in the same settings pane, so app containers can be measured too.

## What it does

### Layered scanning, built not to hang your Mac
Sapu never walks your whole disk on every launch. It scans in three layers, each cached and refreshable on its own:

| Layer | What | Typical time |
|---|---|---|
| **Quick** | ~200 known locations: package-manager caches, Xcode, simulators, Docker/Colima, browser and Electron caches, Homebrew/MAMP logs, ML model caches | seconds |
| **Projects** | Finds every repo under your home folder, sizes `node_modules`, `.venv`, `vendor`, `target`, `.next`, `Pods`, `build`… and reads git state and last activity | under a minute |
| **Full map** | Every home and `~/Library` folder, apps with last-opened date, files over 1 GB, Downloads untouched for 6+ months, so the totals add up | a few minutes |

The engine streams folders with `fts(3)` and keeps memory constant (no per-file lists). At most two folders are measured at once, at utility priority. It never follows symlinks, never crosses into other volumes, and never opens iCloud/CloudStorage folders, because reading them can trigger downloads.

**Real time estimates.** Progress is weighted by how big each location was in your last scan, so "about 12 s left" reflects bytes still to read, not a count of folders. On a first scan the estimate is labelled as rough.

### Explains every item
Each item shows:
- **why it takes space**, e.g. "Duplicate Homebrew services fight for 127.0.0.1:9000; the loser restarts forever and fills `php-fpm.log`"
- **what it is used for**
- **who owns it**: the project, app or tool
- **how it comes back**: `npm install`, `composer install`, "Xcode rebuilds it", or "cannot be rebuilt, keep it"

Items are labelled **Safe** (rebuilds itself), **Check first** (slow re-download, no lockfile, recently touched), **Your files** (never pre-selected) or **Protected** (shown, never touched).

### Protects the projects you're working on
A project edited in the last 14 days (configurable) is **Active**. Its `node_modules`, venvs and build folders are locked, so you keep developing fast. Projects with uncommitted changes are never marked Safe, and the app warns about repos with commits that exist on no remote before you move anything.

### Security and versions (CVE warnings)
Sapu checks installed runtimes (PHP from Homebrew and MAMP, Node via nvm, Python and conda envs, Go, Ruby) and the versions your projects declare (`composer.json`, `composer.lock` Laravel, `package.json` engines, `.nvmrc`, `.python-version`, `go.mod`) against endoflife.date:

- ⛔ **End-of-life**: e.g. *PHP 7.4 is end-of-life since 2022-11-28. It gets no security (CVE) fixes.*
- ⚠️ **Behind the latest patch**: e.g. *PHP 8.2.0 is behind 8.2.35. Patch releases carry the security fixes.*
- A per-project **dependency audit** runs `npm audit` or `composer audit` on demand.

### Cleans safely, with receipts
- You always see a dry-run review first.
- Folders go to the **Trash**, so they can be restored.
- Caches are cleaned with the tool's own command (`npm cache clean --force`, `brew cleanup`, `conda clean --all`, `go clean -cache`…).
- Logs are **emptied in place**, so running services keep writing.
- Virtualenvs without a lockfile get a `requirements-freeze-<date>.txt` saved before they go.
- Each cleanup writes a receipt (Markdown + JSON) listing where every item went.
- A final safety guard refuses home folders, `~/Library` roots, Keychains, iCloud, Mail, Messages, Photos, `~/.ssh`, `~/.aws`, `.env*`, keys and certificates, symlinks, and the files of running apps, whatever the UI allowed.

Sapu never empties your Trash, never uses `sudo`, and never runs `docker volume prune`.

## CLI

The app bundle includes `sapu-cli`, which uses the same engine and shares the same scan cache:

```bash
/Applications/Sapu.app/Contents/Resources/sapu-cli scan quick      # or: projects | full | all
/Applications/Sapu.app/Contents/Resources/sapu-cli report
/Applications/Sapu.app/Contents/Resources/sapu-cli versions
/Applications/Sapu.app/Contents/Resources/sapu-cli selftest
```

The CLI never deletes anything.

## Build from source

Needs only the Xcode **Command Line Tools** (Swift 6). Full Xcode is not required.

```bash
scripts/build.sh            # build/Sapu and build/sapu-cli
build/sapu-cli selftest     # engine checks
scripts/package.sh 0.1.0    # build/Sapu.app + build/Sapu-macOS-arm64.dmg
```

`scripts/build.sh` uses plain `swiftc`. It also works around a Command Line Tools 16 bug (a duplicate `usr/include/swift/module.modulemap` that breaks every `import Foundation`) with a VFS overlay, so nothing outside the repo is changed. With full Xcode, `swift build` works too.

## Project layout

```
Sources/SapuCore   engine: DiskSizer (fts), ScanEngine (layers, ETA), ProjectScanner,
                   RuleBook (known locations + reasons), VersionAudit, Insights, Cleaner, SafetyGuard
Sources/SapuApp    SwiftUI app
Sources/SapuCLI    sapu-cli
scripts/           build, package (DMG), icon
```

## Credits

Inspired by [Shedi](https://shedi.app), [diskreceipt](https://github.com/abdiraimov-otabek/diskreceipt), [TidyDisk](https://github.com/prateekcode/tidydisk) and [PandaCode](https://github.com/aicodeking/pandacode).

MIT License.
