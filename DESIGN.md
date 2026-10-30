# Design

Recorded from the built app (v0.12). This file describes what exists, not an aspiration.

## World: the sorting depot

Sapu2 sorts every item a scan finds into one of four bins before anything moves. The whole app wears that idea.

- **Floor.** Always dark: depot floor `#12161C`, lighter at the top `#181D25`; raised bays `#1A2029` (radius 16, 1 px
  white 8 % hairline) hold every group of rows. `ContentView` forces `.preferredColorScheme(.dark)`.
- **Bins (`Bin`, `Depot.swift`).** Colour only ever means a bin:
  Sweep green `#3DD68C` (rebuilds itself, ticked), Your call amber `#FFB547` (rebuilds at a cost, unticked),
  Your files cobalt `#5B9BFF` (never ticked), Stays graphite `#8B95A5` (locked, protected, or its own app's job).
  `Safety.color` maps onto the same four. Red `#FF6B6B` only for alerts (security, health).
- **Ink.** `#EDF0F5` primary, `#9EA8B8` secondary, `#6B7585` tertiary.
- **Type.** SF Pro Rounded heavy for numbers and headings (`Depot.sign`), SF Pro for body. Small caps labels are
  11 pt bold with 1.2 tracking. Numbers are monospaced digits.
- **Controls.** Capsules: `SignButtonStyle` (filled green, dark label, soft green glow) for the one action that matters;
  `GhostButtonStyle` for secondary actions; `Tick` round tick boxes in the bin's colour, with a mixed state.

## Structure

- No sidebar. A floating pill rail (`PlaceRail`) holds six places: Sweep, Cleanup, Apps, Optimize, Explore, History;
  the selected place is a light capsule that slides (matched geometry). Badges: updates (cobalt), tune-ups (amber),
  security (red).
- `SubBar` under it: the place's panes as chips, a capsule filter field where items can be filtered, and Scan.
- `PaneHeader`: rounded heavy title, one-line purpose, the one number, actions on the right.

## Sweep (Smart Clean)

1. **Start.** Big free-space number, slim disk bar (green slice = ready to sweep), the four bins filled from the last
   scan on a square-root scale, one "Sort & sweep" capsule, then up to four "Also worth a look" cards.
2. **Sorting.** Coloured specks fall into four empty bins (`DustFall`, 30 fps Canvas, paused under Reduce Motion),
   status line, Cancel.
3. **Review.** The bins become tabs: click one to open its panel. Each panel says what the bin means, has Tick all, and
   lists groups; the whole group row opens it (chevron turns), the tick on its left ticks the group. Item rows show
   title, `~/path → what happens`, size, Show in Finder, info popover; clicking the row ticks it. Items of one app or
   project sit under its header, which has one tick for all of them. Tune-ups that run
   with the sweep sit at the top of the Sweep panel. Bottom bar: Back, plain-language count, "Sweep 8.6 GB".
4. **Done.** A one-shot burst of bin-coloured specks, the swept total counting up, Done / Empty Trash… / Receipt, and
   the full result list.

## Transparency rules

- Every item says where it lives and what happens to it (Trash, emptied in place, runs a command, stays), and offers
  Show in Finder and the details popover (why, what for, suggestion, how it comes back, protect).
- Optimize tasks that change files list them; administrator tasks show their exact command.
- Irreversible actions (Empty Trash) need a sheet with an "I understand" checkbox.

## Performance rules

- `AppModel` uses Observation (`@Observable`): a view redraws only for what it reads.
- Derived lists (bins, per-pane findings, id lookup) are computed once per change of results, never while drawing.
- Scan progress reaches the screen at most ten times a second (`Throttle`).
- Long lists are lazy; groups open as flat rows, never nested disclosure groups. Cleanup and the Sweep review are one
  flat `LazyVStack` each (`CleanRow`, `SweepRow`): headers, rows and opened items are separate entries drawn on slices
  of their bay, so opening a group of 80 items builds only the rows on screen.
- A button never disappears while it works: its spinner and progress ("Checking 12 of 21…") go inside it. A focused
  control that vanishes hands focus to one further down, and the page scrolls there.
- Optimize's checks run side by side (`Maintenance.check(progress:)`), about 2.5 s instead of 4.5 s.

## Motion

- Rail capsule: spring 0.3 s. Groups: 0.18 s ease-out. Bin fill: spring 0.7 s. Specks and burst stop under Reduce Motion.

## Each place

- **Cleanup.** Hero with the total and one ribbon split by safety (Safe, Check first, Yours, Protected) and "Tick safe".
  One bay per cleaning group. Every row shares the same columns (tick · opener slot · name · size bar · size · verdict),
  so single items and apps line up. An app with several items opens on click anywhere; its items appear inside it on a
  darker inset with a coloured rail and a dot per item, never as siblings. When every item would repeat the same
  sentence, each shows its path instead. Clicking an item opens the details column.
- **Optimize.** "Tune up" hero: a ring of how much is already fine, the number of harmless tune-ups ready, and one
  button. The button opens a sheet listing each tune-up, what it changes, with ticks; only `AppModel.smartTaskIDs`
  with a `.run` fix and something to do are ever offered (no password, nothing restarted, removals go to the Trash).
  The hero counts every check (fine, in one click, yours to choose); the sheet lists what is already fine and what is
  left out of one click with the reason (password, Terminal, your history, package versions). A sweep runs the same
  tune-ups except the slow Open With rebuild.
- **Health.** Six ring gauges (memory, swap, processor, disk, battery, temperature), amber when they need attention.
- **Uninstall.** The chosen app at the centre of a constellation: every file it keeps orbits it, sized by space and
  coloured green (goes), blue (your data, kept) or grey (kept for safety). Hover a dot for its path.
- **Updates.** A shelf of the waiting apps' icons, then rows with `old → new` version capsules and a coloured action.
- **Projects.** Status chips (Active cobalt, Recent amber, Idle graphite) over one bay of rows that share columns
  (project · status · last edit · stack · git · build folders with a size bar). Clicking a row slides its details in on
  the right: git state, runtimes, build folders with "Unlock project", secrets check and dependency audit.
- **Disk map.** Starts at the top of the startup disk (Macintosh HD) and maps everything: every top-level folder plus
  macOS's own APFS volumes (startup & update files, Recovery, memory swap) from `diskutil`. `/System/Volumes`,
  `/Volumes` and `/dev` are never entered (`DiskSizer.neverEnterPaths`): on APFS firmlinks share one device, so
  entering them would count the disk twice. A "Startup disk" bay adds up: mapped + system and hidden areas +
  purgeable + free = the disk. Used and available are the figures System Settings and Finder show
  (`volumeAvailableCapacityForImportantUsage`): purgeable space counts as available, not used. The capacity is reread
  when measuring starts and ends, and one running total (`totalSoFar`) feeds the header, the bar and the progress line.
  If folders add up to more than used (APFS clones share blocks), a note says used is the real figure. A house button jumps to your home folder. Outside your home Sapu2 only measures: the row menu offers
  Show in Finder and Copy Path, never Move to Trash. A hint appears when no size has arrived for 8 s (usually a macOS
  permission dialog). Rows are a lazy stack. While measuring, a progress bay shows items done, files counted, bytes so far, seconds and each
  folder being measured with its running size; rows still measuring count up ("3.4 GB · 57,463 files so far"). A skyline strip of the folder's biggest items, wide as their space,
  clickable to open. **One walk for both tabs:** each folder is walked once. `DiskSizer.size(onDir:)` reports every
  folder of 4 MB or more as the walk finishes it (post-order; the bulk walker recurses after closing each descriptor),
  and files of 200 MB or more in the home folder, into locked caches. Opening a folder takes its items' sizes from that
  cache; only small or unvisited ones get a walk. A folder with its own walk is `claimed`: walks of folders above it
  step around it (`skipDir`) and add its size when it's done (`settle`), and a folder whose total is short because of
  that is never cached. Leaving a folder doesn't stop its walks. Largest files has no search of its own: it lists the
  big files the walks found (private folders filtered out) and shows the progress of the walks through home; Search
  again re-walks home only. Selftest checks per-folder sizes against walking each folder alone, for both walkers.
- **History.** Receipts as a timeline, one stop per cleanup, opening in place. Trash shows a graphite bin filled by size.

## Explanations and locks

- Every item's details explain it in four parts from `Explainer` (SapuCore/Explainer.swift): what it is, what removing
  it costs (an impact meter: none, small, medium, high), the best way to free the space with copyable commands, and
  whether it comes back. The rules for writing one sit at the top of that file.
- "On your Mac" (`YourContext`) adds facts from the person's own projects: which projects use Docker for a VM disk,
  which project a build folder belongs to and the exact reinstall command from its lockfile, which projects load
  Hugging Face models, which package managers the projects use. `sapu2-cli explain <path>` prints the same.
- Active projects' build folders are locked. The amber lock on a row (or "Unlock project" on a project) explains the
  cost first, then unlocks and ticks. Unlocks last until Sapu2 quits. There is no global switch.
- Items of one app or project are grouped under its name everywhere: Cleanup (including Build folders) and the bins.

## Signing and Full Disk Access

macOS ties Full Disk Access to an app's code identity. An ad-hoc signature's identity is the hash of the binary, so
every build looked like a new app: the switch in System Settings stayed on but no longer applied, and Sapu2 showed the
access banner again. `scripts/sign.sh` signs with Sapu2's own self-signed certificate (kept in `~/.sapu-signing/`
on the release machine, or in the `SAPU_SIGN_P12` / `SAPU_SIGN_PASS` secrets for the release workflow), so the
designated requirement is `identifier "app.sapu2.Sapu2" and certificate root = H"…"` and stays the same across releases.
Without the certificate it falls back to ad-hoc. When the workflow has no certificate and the release already exists
(published from a machine that has it), it keeps that DMG instead of replacing it with an ad-hoc one.
