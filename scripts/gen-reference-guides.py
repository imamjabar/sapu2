# Generate Sources/SapuCore/ReferenceGuides.swift and Tests/reference-guides-fixture.json from the reference tool's tested-app guides.
# Usage: gen-reference-guides.py <scraped guides dir> <repo> <date>
import json,re,sys,os,collections,html
S,REPO=sys.argv[1],sys.argv[2]
rows=json.load(open(S+"/guide-rows.json")); apps={a["slug"]:a for a in json.load(open(S+"/tested-apps.json"))}
# Only real bundle IDs: a recorded "IdeaIC2025.2" names a build, and would make IDEA's sub-ID rule claim CE.
fix={a["name"].lower():a["id"] for a in json.load(open(REPO+"/Tests/tested-apps-fixture.json"))["apps"]
     if re.match(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$",a["id"] or "")}
STATED=re.compile(r'(?:identifies itself as|bundle ID|bundle identifier|identifier) *(?:is )?<code>([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)</code>')
NOISE=re.compile(r"^~/(Library|Library/[^/]+|\.local|\.local/(bin|share|state)|\.config|\.cache|Applications|Library/Application Support/(Google|JetBrains|Adobe|Microsoft|Steam|Caches|FileProvider|CrashReporter)|Library/(Caches|Logs)/JetBrains|Library/Preferences/ByHost)/?$"
                 r"|^~/Library/(Mobile Documents|Safari|Mail|Messages|Keychains|Cookies/?$|Containers/com\.apple\.|Group Containers/group\.com\.apple\.|Accounts|Calendars|Photos|Application Support/(AddressBook|CallHistory|com\.apple\.|MobileSync|Knowledge))"
                 r"|^~/\.local/bin|^~/\.(zshrc|zprofile|zshenv|bashrc|bash_profile|profile|gitconfig|ssh|gnupg|aws|npmrc|vimrc|netrc|kube|docker)(/|$)|ApplicationRecentDocuments/?$|^~/Library/Application Support/com\.apple\.sharedfilelist")
# Folders many apps write into: only an app's own entry inside them is ever its leftover.
SHARED=re.compile(r"^~/Library/Caches/com\.plausiblelabs\.crashreporter\.data$|/NativeMessagingHosts$|^~/\.agents$|^~/\.agents/skills$"
                  r"|^~/Library/Application Support/FluidAudio(/|$)|^~/Library/Application Support/Google/Chrome(/|$)|^~/Library/Logs/AppAnalytics$|^~/Library/Google/GoogleSoftwareUpdate$"
                  r"|^~/\.config/(fish|zsh|bash|nushell|powershell|starship\.toml)(/|$)")
# Paths a guide names for another app or tool. Sapu2 leaves them, on purpose:
REVIEWED={
    ("Claude","~/.cache/claude"): "Claude Code (command-line tool) data, not the desktop app's",
    ("Claude","~/.config/claude"): "Claude Code (command-line tool) data, not the desktop app's",
    ("Claude","~/.claude.json"): "Claude Code (command-line tool) settings and sign-in",
    ("ClaudeBar","~/.codex"): "Codex command-line tool data that ClaudeBar only reads",
    ("Cursor","~/.cursor"): "shared with the cursor-agent command-line tool (extensions, MCP config)",
    ("OpenCode","~/.local/share/opencode"): "opencode command-line tool data",
    ("OpenCode","~/.cache/opencode"): "opencode command-line tool cache",
    ("Doubao Work","~/Library/Application Support/Doubao"): "the separate Doubao app's data",
    ("Dropzone","~/Library/Application Support/com.aptonic.Dropzone4"): "Dropzone 4, an earlier app with its own ID",
    ("Epic Games Launcher","~/Library/Application Support/Epic"): "shared by Epic's launcher, Unreal Engine and games",
    ("IntelliJ IDEA","~/Library/Caches/com.jetbrains.toolbox"): "JetBrains Toolbox, a separate app",
    ("Steam","~/Library/Application Support/Steam/Steam.AppBundle"): "Steam keeps games and their runtime here; only its caches go",
    ("Steam","~/Library/Application Support/Steam/SteamApps"): "your installed games",
    ("Ungoogled Chromium","~/Library/Application Support/Chromium"): "shared with Chromium",
    ("Ungoogled Chromium","~/Library/Preferences/org.chromium.Chromium.plist"): "shared with Chromium",
    ("Ungoogled Chromium","~/Library/Saved Application State/org.chromium.Chromium.savedState"): "shared with Chromium",
    ("IntelliJ IDEA","~/Library/Preferences/com.jetbrains.intellij.ce.plist"): "IntelliJ IDEA CE's settings",
    ("IntelliJ IDEA","~/Library/Saved Application State/com.jetbrains.intellij.ce.savedState"): "IntelliJ IDEA CE's window state",
    ("GitHub Copilot for Xcode","~/Library/Logs/GitHubCopilot"): "shared with the GitHub Copilot app",
    ("GitHub Copilot for Xcode","~/.config/github-copilot"): "the Copilot sign-in shared by every Copilot client",
    ("Topaz Photo","~/Library/Application Support/Affinity Photo 2/Plugins/TopazGigapixel.plugin"): "inside Affinity Photo's folder",
    ("DiskWise","~/.config/zed/settings.json"): "Zed's settings file",
    ("DiskWise","~/.zcode/cli/config.json"): "ZCode's settings file",
    ("SnippetsLab","~/.agents/skills/snippetslab"): "inside the shared agent skills folder",
    ("VoiceInk","~/Library/Application Support/FluidAudio/Models"): "speech models shared with FluidVoice",
    ("FluidVoice","~/Library/Application Support/FluidAudio"): "speech models shared with VoiceInk",
}
def ok(p,tier):
    if tier in("keep","keep-cred"): return False      # the reference says keep: never claimed from the guides
    if "*" in p or "<" in p or "{" in p or not p.startswith("~/"): return False
    if NOISE.search(p) or SHARED.search(p): return False
    top=p.split("/")[1]
    # Library and app-owned dot folders only; ~/Documents, ~/Music, ~/superwhisper are your files.
    return top=="Library" or top.startswith(".")
per=collections.OrderedDict(); ids={}; reviewed={}
for slug,a in apps.items():
    t=open(f"{S}/guides/{slug}.html",encoding="utf-8",errors="ignore").read()
    m=STATED.search(t); ids[slug]=(m.group(1) if m else None) or fix.get(a["name"].lower())
for r in rows:
    p=r["path"].rstrip("/").replace("$HOME","~")
    if (r["app"],p) in REVIEWED: reviewed.setdefault(r["slug"],{})[p]=REVIEWED[(r["app"],p)]; continue
    if ok(p,r["tier"]): per.setdefault(r["slug"],[]); p not in per[r["slug"]] and per[r["slug"]].append(p)
# Guess the ID from the app's own preference file when the guide doesn't state it.
for slug,ps in per.items():
    if ids[slug]: continue
    c=collections.Counter(m.group(1) for p in ps for m in [re.search(r"/Library/Preferences/([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,})\.plist$",p)] if m)
    for cand,_ in c.most_common():
        if sum(cand.lower() in q.lower() for q in ps)>=2: ids[slug]=cand; break
# A path more than one app lists is shared: no single uninstall may take it.
owners=collections.defaultdict(set)
for slug,ps in per.items():
    for p in ps: owners[p.lower()].add(slug)
shared={p for p,o in owners.items() if len(o)>1}
out=collections.OrderedDict()
for slug,ps in per.items():
    keep=[p for p in ps if p.lower() not in shared and not any(p.lower().startswith(q+"/") for q in shared)]
    # Drop a path inside another path of the same app: the parent already covers it.
    keep=[p for p in keep if not any(p!=q and p.lower().startswith(q.lower()+"/") for q in keep)]
    if keep: out[slug]=keep
def sw(s): return json.dumps(s,ensure_ascii=False)
lines=["import Foundation","","/// Leftovers a reference cleaner found by hand for the 851 apps on its tested list, where generic",
"/// name and bundle-ID matching can't reach them (Aliyun Drive's \"aDrive\", Calendar 366's older group IDs).",
"/// Generated by scripts/gen-reference-guides.py; only paths the guides say can go with the app, never ones they keep.",
"/// Shared stores two apps list are left out. Each path is still checked like any other leftover.",
"enum ReferenceGuides {","    struct Entry: Sendable { let name: String; let id: String?; let paths: [String] }",
"    static let entries: [Entry] = ["]
for slug,ps in out.items():
    a=apps[slug]; lines.append(f"        Entry(name: {sw(a['name'])}, id: {sw(ids[slug]) if ids[slug] else 'nil'}, paths: [{', '.join(sw(p) for p in ps)}]),")
lines+=["    ]","",
"    static let byID: [String: [Int]] = Dictionary(grouping: entries.indices.filter { entries[$0].id != nil }) { entries[$0].id!.lowercased() }",
"    static let byName: [String: [Int]] = Dictionary(grouping: entries.indices) { entries[$0].name.lowercased() }","",
"    /// The reference paths for this app, by bundle ID, or by name when the record has no ID.",
"    static func paths(for app: InstalledApp) -> [String] {",
"        var hits = Set(app.bundleID.flatMap { byID[$0.lowercased()] } ?? [])",
"        for i in byName[app.name.lowercased()] ?? [] where entries[i].id == nil || app.bundleID == nil { hits.insert(i) }",
"        return hits.sorted().flatMap { entries[$0].paths }.map { $0.expandingTilde }",
"    }","}",""]
open(REPO+"/Sources/SapuCore/ReferenceGuides.swift","w").write("\n".join(lines))
fx={"referenceVersion":"reference guides "+sys.argv[3],"apps":[{"name":apps[s]["name"],"id":ids[s] or "","zap":ps} for s,ps in out.items()],
    "reference":{apps[s]["name"]:ps+sorted(reviewed.get(s,{})) for s,ps in out.items()},
    "referenceMistakes":{apps[s]["name"]:{p:"Sapu2 keeps it: "+why for p,why in d.items()} for s,d in reviewed.items()}}
json.dump(fx,open(REPO+"/Tests/reference-guides-fixture.json","w"),indent=1,ensure_ascii=False,sort_keys=True)
print("apps",len(out),"paths",sum(map(len,out.values())),"withID",sum(1 for s in out if ids[s]),"shared-dropped",len(shared))
