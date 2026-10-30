<div align="center">

# Sapu2

**Get your disk back without losing anything that matters.**

A careful disk cleaner for developers on macOS. It finds what is eating your disk, tells you why each item is there and what removing it costs, and moves only what rebuilds itself to the Trash, with a receipt and a way back.

[Download](../../releases/latest) · [How it works](#how-it-works) · [Safety](#safety-you-can-check) · [Command line](#command-line) · [Build](#build-from-source)

Free and open source (GPL-3.0) · Native SwiftUI · Apple Silicon, macOS 14+ · About 4 MB

</div>

---

## Why Sapu2

Most cleaners show you a big number and a button. Sapu2 is built around a different question: *what exactly is this, and what happens if it goes?*

- **Every item explains itself.** What it is, which project or app owns it, what removing it costs, the right way to free it, and whether it comes back.
- **Nothing is lost on the first try.** Cleaned items go to the Trash. Each cleanup writes a receipt, and **Undo sweep** or **Put back** returns anything to where it was.
- **Made for developer machines.** It knows where Xcode, Docker, package managers, build folders and AI tools hide gigabytes, and it leaves the projects you are working on alone.
- **Light and native.** About 4 MB, around 35 MB of memory, no Electron, no background daemon.
- **Private.** No accounts and no telemetry. Scan results, receipts and the error log stay on your Mac.

## Install

1. Download `Sapu2-macOS-arm64.dmg` from [Releases](../../releases/latest).
2. Drag **Sapu2** to **Applications** and open it.
3. If macOS says it cannot verify the app, open **System Settings → Privacy & Security** and choose **Open Anyway**. Sapu2 is signed with its own certificate and is not notarized by Apple yet.
4. Optional: give it **Full Disk Access** so it can measure app containers. The app walks you through it. Every release uses the same certificate, so the switch stays on across updates.

## How it works

One button, **Sort & sweep**, scans your Mac and sorts every item it finds into exactly one of four bins *before anything moves*.

| Bin | Meaning | Ticked for you? |
|---|---|---|
| **Sweep** | Rebuilds itself. Package caches, app caches, build output, old logs. | Yes |
| **Your call** | Rebuilds, but costs a download or a wait. | No |
| **Your files** | Your own data. Old downloads, big files you may still want. | Never |
| **Stays** | In use, protected, or only its own app should remove it. | Locked |

Then you review, bin by bin. Items of one app or project sit together under its name. Every row shows its path, what will happen to it, and a details panel. When you press Sweep, what moved goes to the Trash and a receipt records where each item went.

### Every item explains itself

Open any row and you get four answers, written in plain language, with the exact command when the owning tool has one:

> **~/.npm/_cacache** · 762 MB · *Sweep*
> **What it is:** every package npm downloaded, kept so the next install can skip the download.
> **If you remove it:** small. The next `npm install` is slower while it downloads again.
> **Best way:** `npm cache clean --force`
> **Comes back:** as you install packages again.

Sapu2 also adds facts from your own projects: which of them use Docker or Colima, which project a build folder belongs to, and the reinstall command from its lockfile.

## What it finds

| | |
|---|---|
| **Developer tools** | Xcode DerivedData, archives and simulators, `node_modules`, `.venv`, `target`, `.next`, Pods, pnpm, npm, Cargo, Gradle, CocoaPods, Poetry, Deno, Bazel, ccache, Homebrew, Conda, Docker and Colima disks, Android emulators |
| **AI tools** | Update downloads, old versions, job scratch files and agent worktrees of Claude Code, Codex, Cursor and others. Chat history and local models (Ollama, Hugging Face, PyTorch) are shown and explained, never removed |
| **Apps** | Unused apps by last-opened date, leftovers of removed apps, installers in Downloads, newer versions from Homebrew, Sparkle feeds and the App Store |
| **Browsers** | Named cache folders per profile for Chrome, Arc, Brave, Edge, Vivaldi, Opera and more. Logins, history and bookmarks are never touched |
| **System** | Logs, caches, Trash, startup items, and about 400 known app and tool locations |

Projects are found by scanning your home folder. A project touched in the last 30 days is **Active** and its build folders are locked, so you keep developing fast. You can unlock one on purpose, and Sapu2 first shows what that costs.

## Safety you can check

Safety is the product, so it is checked by the engine itself, not only by the interface.

- **Preview first.** You always review before anything moves.
- **Trash, not delete.** Folders go to the Trash. Caches use the tool's own command (`npm cache clean --force`, `brew cleanup`, `go clean -cache`). Logs still being written are emptied in place so services keep running.
- **A last guard on every path.** Whatever the interface allowed, the engine refuses your home folder itself, `~/Library` roots, Keychains, iCloud, Mail, Messages, Photos, `~/.ssh`, `~/.aws`, `.env` files, keys and certificates, symlinks, and files of running apps.
- **Never touched:** credentials, AI conversations, local models, Mail, Messages and Photos. Sapu2 never empties your Trash and never runs `docker volume prune`. The few tune-ups that need administrator access show their exact command first, and macOS asks for your password; Cancel changes nothing.
- **Your protect list.** Right-click anything and choose **Never clean this**. It stays off every scan, the disk map and uninstalls.
- **Receipts.** Every cleanup writes a Markdown and JSON receipt. **Put back** returns an item from the Trash to its place.

The engine ships with a self-test (`sapu2-cli selftest`) that checks these rules on a temporary folder and runs in CI on every push.

## More than cleaning

| | |
|---|---|
| **Uninstall** | Pick an app and see it plus everything it keeps in your Library before anything moves. Several apps at once, each with a safe default plan |
| **Optimize** | One button runs every harmless tune-up that has something to do: icon and thumbnail refresh, Open With rebuild, idle disk images ejected, broken lists fixed. No password, nothing restarted |
| **Health** | Memory pressure, swap, processor, disk, battery wear, temperature, and forgotten developer processes still running after their terminal closed |
| **Disk map** | Map the whole disk, biggest first, and open any folder. Largest files are listed as the walk finds them |
| **Projects** | Every project on the Mac with git state, runtimes, build-folder sizes and last activity |
| **Security** | Secrets committed to your projects (`.env` files, API keys, tokens in remote URLs), dependency audits, and end-of-life or outdated runtimes checked against endoflife.date |
| **Startup items** | An on/off switch for every launch agent that survives restarts, without deleting anything |

## Command line

The app bundle includes `sapu2-cli`, which uses the same engine and the same scan cache.

```bash
alias sapu2=/Applications/Sapu2.app/Contents/Resources/sapu2-cli

sapu2 scan quick            # or: projects | full | all
sapu2 clean                 # dry run: what a sweep would do. Changes nothing
sapu2 clean --json          # the same, for scripts and CI
sapu2 clean --yes           # move the Sweep bin to the Trash, with a receipt
sapu2 explain ~/.colima     # what a path is and what removing it means
sapu2 du ~/Library          # a folder's children, biggest first
sapu2 report                # the saved scan
sapu2 log                   # local error log, to attach to an issue
```

`clean` is a dry run unless you add `--yes`.

## Under the hood

Sapu2 never walks your whole disk on every launch. It scans in three cached layers:

| Layer | What it reads | Typical time |
|---|---|---|
| **Quick** | About 200 known locations: package caches, Xcode, simulators, Docker, browsers, ML caches | seconds |
| **Projects** | Every repo under home, with git state and build-folder sizes | under a minute |
| **Full map** | Every folder in home and `~/Library`, apps, big files, old downloads | a few minutes |

- **Gentle on the Mac.** Folders are streamed with `fts(3)` and `getattrlistbulk(2)` at utility priority, two at a time, with constant memory. It never follows symlinks, never crosses into other volumes, and never opens iCloud folders, because reading them can trigger downloads.
- **Rescans re-read only what changed.** macOS keeps a per-volume change journal (FSEvents). Sapu2 asks it which folders changed since the last scan and reuses the cached size of the rest. If the journal cannot vouch for the gap, it measures everything.
- **Honest progress.** Estimates are weighted by how big each location was last time, and a first scan is labelled as rough.

## Build from source

Needs only the Xcode **Command Line Tools** (Swift 6). Full Xcode is not required.

```bash
scripts/build.sh            # build/Sapu2 and build/sapu2-cli
build/sapu2-cli selftest    # engine checks
scripts/package.sh 0.1.0    # build/Sapu2.app and build/Sapu2-macOS-arm64.dmg
```

`scripts/build.sh` uses plain `swiftc`. It works around a Command Line Tools 16 bug (a duplicate `usr/include/swift/module.modulemap` that breaks every `import Foundation`) with a VFS overlay, so nothing outside the repo changes.

```
Sources/SapuCore   engine: sizing, scan layers, project scanner, rule book, cleaner, safety guard
Sources/SapuApp    the SwiftUI app
Sources/SapuCLI    sapu2-cli and the self-test
scripts/           build, package (DMG), signing
```

## Status

Sapu2 is in its first public releases (v0.1.x).

- Apple Silicon and macOS 14 or later. English only.
- Signed with its own certificate, not yet notarized by Apple.
- Planned: notarization, automatic updates, an Intel build.

Bug reports and ideas are welcome in [Issues](../../issues). For a bug, `sapu2 log` prints a local log you can read and attach.

## License

Sapu2 is free software under the [GNU General Public License v3.0](LICENSE), or at your option any later version. You may use, study, change and share it. If you share a changed version, you share its source under the same license. It comes with no warranty.
