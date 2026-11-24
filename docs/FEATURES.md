# Features worth building

**State, 25 November 2026:** all eight under "Build now" are built. From "Later": open ports, keeping awake, a charger
that is too weak, what a process is, network and graphics load, and a shortcut key. The rest of "Later" is not built.

Research of 24 November 2026. No app code was changed for it.

**Where things were tried:** one Apple silicon MacBook Pro on macOS 26.4, as an ordinary user without
sudo and without Full Disk Access, by small programs and commands that only read. The one exception is a
`caffeinate` of three seconds, to see its assertion appear. Everything ran from a terminal, not from a signed and notarized Pulse.

**NOT VERIFIED anywhere below:** Intel Macs, macOS 14 and 15, a Mac without a battery, the notarized app.
Every new reading therefore needs a nil path that shows `unknown` or hides the row.

**Sources:** GitHub through its API, App Store reviews through Apple's review feed, Hacker News, and product
pages that were opened. Reddit refuses automated reading, and the Apple Discussions and MacRumors forum threads
could not be opened, so nothing here rests on them. Star and reaction counts are from the day of the research.

Sizes: S is under half a day, M is about a day.

---

## Build now

### 1. Sessions that wait for you (S)

**Problem.** A Claude session that asked a question or wants permission stands still until someone looks.
Today Pulse shows it as working: `PanelView.swift:1315` and `:584` treat everything that is not idle as
"working". For anyone who runs more than one session.

**Evidence.** Whole apps exist for this alone: [vibe-notch](https://github.com/farouqaldori/vibe-notch)
(2,533 stars) and [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) (741 stars, "a yellow dot when
it's awaiting your permission"; it installs hooks into `settings.json`, which Pulse does not need to).
The complaint to avoid is noise: a notification when a subagent finishes
([vibe-notch #36](https://github.com/farouqaldori/vibe-notch/issues/36)).

**API and what it gave.** The session record Pulse already reads. A poll every two seconds saw
`status` = `idle`, `busy` and, in 48 readings from one kind of host (likely one session, for about a minute and a half), `waiting` with `waitingFor: "input needed"`.
The Claude Code 2.1.327 program also contains `permission prompt`, `sandbox request`, `dialog open`, `goal proposal`
and `worker request`; those five were found in the program, not seen live. The record format is undocumented, so an unknown
status must stay "working" and an unknown `waitingFor` must read "Waiting for you".

**Where.** Sessions page: waiting rows first, a filled urgent dot, "Waiting for you: permission" in place of
"working". Overview: the Sessions figure becomes "1 waits" (it replaces, adds nothing), and the sentence line names it.
Alerts page: "When a session waits for you", silent, after it has waited 30 seconds, once per wait.
A press on the row brings the app that hosts the session to the front: `Snapshot` already finds hosts but keeps
only a set, so keep the host per session; then `NSRunningApplication.activate()` (not tried, it raises a window; since macOS 14 activation is a request the system may refuse, so test it behind the window flag and say "Could not open it" when it fails). App level only: choosing the terminal tab needs an
Automation permission. Add `waitingFor` to `claude_sessions` in the MCP. A waiting session is never idle, so it is never offered for closing; keep that with a test.

**Check.** Unit: a made-up record with `waiting` sorts first, is not `isIdle`, is not closable; mutate the status
string and watch it fail. `AlertEngine`: 29 s nothing, 31 s one alert, still waiting 10 minutes later no second one, answered and
waiting again one more. Render `sessions` and `overview` with a waiting demo session.
Real: `Pulse --snapshot` while a session asks something.

### 2. The memory an app really holds (S)

**Problem.** Rows, the plan and "frees 623 MB" add up resident memory (`ps rss`). What macOS compressed or
swapped is missing from it, and pages shared between processes are counted several times. So the biggest offender
can look small and the one button promises a wrong number. For everyone.

**Evidence.** Apple lists [compressed memory and swap](https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac)
apart from what stays in RAM. A user found a screen saver [holding 40 GB](https://news.ycombinator.com/item?id=42882525) only after
installing a monitor, and another says ["something eats my ram and it starts swapping and I do not even notice"](https://news.ycombinator.com/item?id=42883390).

**API and what it gave.** `proc_pid_rusage(pid, RUSAGE_INFO_V4, …)`, field `ri_phys_footprint` (public header
`sys/resource.h`, both architectures). One process: 795 MB resident, **6,418 MB footprint**. In the twelve
largest groups the ratio of the two ran from 0.12 to 1.49. All readable processes: 28.9 GB against 36.3 GB.
Cost 1.5 ms for the whole table. It answers for the user's own processes (596) and refuses the rest (305), which belong
to root or other users: those keep their `rss`.

**Where.** No new screen. Fill it in `ProcTable.live()` beside `ps`; every row, the plan, the headline, the heavy app rule
and the MCP follow. Say "In use" and never "will be freed" for an estimate: what closing gives back is at most the footprint.

**Check.** Unit: a parsed table with a footprint for one pid and none for another uses 6,418 and falls back to rss.
Real: the MEM column of `top -l 1 -stats pid,mem` is the same figure. Tried on the five largest processes:
8748 MB against 8748M, 6412 against 6412M, 2670 against 2740M (it was growing), 1542 against 1543M, 1321 against 1321M. Rows of `--snapshot` must match it as closely.

### 3. What keeps this Mac awake, and what sleep cost (M)

**Problem.** The Mac does not sleep, or loses charge overnight, and nothing says why. Activity Monitor hides
it in a Yes/No column. It also decides whether Pulse's own drive feature ever runs. For every laptop owner, and anyone with drives ticked.

**Evidence.** Apple has a help page for it: ["Processes running in the background can prevent your Mac from sleeping"](https://support.apple.com/guide/mac-help/mchlp2995/mac).
[Sleep Aid](https://ohanaware.com/sleepaid/) is a paid app for exactly this (a check of what prevents sleep, and a history of when the Mac did not sleep).
[Jettison](https://www.stclairsoft.com/Jettison/) sells what Pulse's drives feature does, and that feature only runs when the Mac really sleeps. On Hacker News the usual answer is the [`pmset -g assertions` command](https://news.ycombinator.com/item?id=31129709).

**API and what it gave.**
- `IOPMCopyAssertionsByProcess` (public, macOS 10.7): 4.9 ms, 9 processes holding assertions, among them apps holding one for days.
  Use `AssertionTrueType`, not `AssertType` (one app reported the old name `NoIdleSleepAssertion`). `AssertionOnBehalfOfPID` names the real app
  behind the audio daemon. Keep `PreventUserIdleSystemSleep` and `PreventSystemSleep`; drop `UserIsActive`,
  `ExternalMedia`, the power daemon's own and `runningboardd` (it renews one every few seconds). Age never hides a row; only the health finding needs an hour.
  A `caffeinate` is named by its parent, so one started by a Claude session reads as that session.
- Sleep cost: the charge from `IOPSCopyPowerSourcesInfo` (0.7 ms) and "Dark Wake Count" from `pmset -g stats`
  (7 ms; 220 sleeps, 216 dark wakes, 12 wakes by the user since the last start). `DriveGuard` already receives the kernel's will-sleep
  and full-wake messages: store charge, time, power source and count at the first will-sleep, compare at the full wake.
- Do not use `pmset -g log`: 2.5 s and 14 MB here. `kern.sleeptime` is reset by each dark wake, so it only covers the last nap.

**Where.** The drives page with five drives already fills 440 points, so it stays. A new page "Sleep", reached by one
row at the top of the drives page ("Awake because of 2 apps") and from Health: the list, and one line "Last sleep: 8 h, lost 4%, woke by itself 3 times" (hidden on a desktop Mac).
Explanation on the page: "What asks this Mac to stay awake. Pulse stops nothing here; the row opens its process." No new icon in the footer. Health, Battery area: attention when a sleep of over
four hours on battery lost more than 10%. MCP: a read-only `sleep_blockers`. Nothing is ended from here: the
row only leads to the process row, where the two presses already are.

**Check.** Unit: a made-up assertions dictionary in, names out, with the traps above each a case.
Event list will-sleep, dark wake, will-sleep, full wake gives one sleep, not two; on AC gives no loss. Real: `--snapshot` lists the same
pids as `pmset -g assertions`. Start `caffeinate -t 5` by hand, see its row appear and leave. NOT VERIFIED: a real night.

### 4. What takes the space (M)

**Problem.** Every place in `Cleanup.places` is a developer cache, so on an ordinary Mac the page is empty, and
macOS calls the rest "System Data". "Any Mac, with or without developer tools" is not met here.

**Evidence.** What reviews of [DaisyDisk](https://apps.apple.com/us/app/daisydisk/id411643860) praise is seeing big forgotten folders inside Library: 60 GB of mail of an app not used for years, a screen recording of almost 300 GB, 138 GB of caches
(that last one with its administrator scan, which Pulse cannot do). A [maker of another cleaner](https://news.ycombinator.com/item?id=46574450) tells of 300 GB of System Data.
A 10 GB bundle in Claude Desktop's own folder has [281 reactions](https://github.com/anthropics/claude-code/issues/22543). What goes wrong when a cleaner also deletes: Mole (76,082 stars for cleaning, uninstalling and monitoring) [wiped `~/.claude/projects` memory](https://github.com/tw93/Mole/issues/823).

**API and what it gave.** `du -xk -d 1` on four folders of `~/Library`, 9.3 s together, one at a time off the main thread: Application Support 28.5 GB (four folders over 1 GB, the largest 18.8; 11 refused), Developer 30.8 GB (30.4 of it simulators; 0 refused), Caches 4.5 GB (8 refused), Logs 0.1 GB. Six folders over 1 GB hold about 59 GB, none of which the cleanup page shows.
Refused folders are counted and shown ("19 folders macOS keeps closed"), never as zero. Do not enter `Containers`, `Group Containers`, `Mobile Documents`, Desktop, Documents or Downloads: they can raise a permission dialog.
**Tried and weak:** offering the caches of closed apps. Seven cache folders were over 100 MB and none belonged to an installed, closed app (the one large one was in use, 2.3 GB, two were Apple's, three had no bundle name, one was a developer place). Left out.

**Where.** A second block on the cleanup page, under what can be cleared: "Largest folders in your Library", at most eight, over 1 GB, with the size and the app's name when the folder is a bundle id. A press shows it in Finder. No tick, no Trash: Pulse does not know what these are.
Explanation: "Pulse only shows these. They may hold your work." Measured when the page opens and kept for an hour; not part of the six-hour check.
Add to `Cleanup.places`, as they are downloaded again: `Library/Caches/ms-playwright`, `Library/Caches/org.swift.swiftpm`, `.gradle/wrapper` (seen readable, 0.7 GB together). Never add anything under `~/.claude`, `~/.codex`, `Application Support` or Xcode Archives.

**Check.** Unit in a temp home: sizes sorted, under 1 GB hidden, a refused folder counted and not zero, a link not followed, a guarded name never entered. Watch each fail once. Real: the same sizes as `du`; NOT VERIFIED: that the notarized app raises no dialog (open the page once with a fresh user before release). The press into Finder was not tried.

### 5. Wear and real faults of the SSD (S)

**Problem.** The Storage area reads one word from `diskutil` ("Verified"), which says nothing until the disk is failing.
Apple solders the SSD, so wear is the number that matters when keeping or buying a Mac.

**Evidence.** Two paid apps sell it: [Sensei](https://cindori.com/sensei) ("a S.M.A.R.T analysis of your storage") and [coconutBattery Plus](https://www.coconut-flavour.com/coconutbattery/) ("SSD stats").

**API and what it gave.** `IOCreatePlugInInterfaceForService` with `kIONVMeSMARTUserClientTypeID` on each `IOBlockStorageDevice` that has the
property "NVMe SMART Capable", then `SMARTReadData` (header `IOKit/storage/nvme/NVMeSMARTLibExternal.h`, in the public SDK). 6.4 ms, no
sudo, for the internal disk and an external one: percent used, terabytes written, media errors, unsafe shutdowns, hours, temperature.
**Trap:** the internal Apple disk reports available spare 99% with a threshold of 99%. A rule "spare at or under the
threshold is bad" would alarm on a new Mac. Use the critical-warning bits, media errors, and percent used (attention at 80, urgent at 100).
Hard disks, SATA disks and many USB enclosures have no such interface: keep the `diskutil` answer for those.

**Where.** Health, Storage area, in place of "Disk hardware is fine": "Disk wear 0%", "9.1 TB written". Store percent used in `HealthDay` for a trend
later. `HealthStore.currentRules` goes up. `import IOKit.storage.nvme` does not compile in Swift and other ways were not tried; the sure way is a C target of about thirty lines in `Package.swift`, which is what the probe was. Explanation: "How much of the disk's writing life is used."

**Check.** Unit: made-up values to states, with 99/99 spare as ok. Real: the same numbers as `smartctl -a disk0` where that happens to be installed;
otherwise the read code is 0 and percent used is under 101. NOT VERIFIED: a worn disk, an Intel Mac.

### 6. How much of the plan is left, without a network (S, off until ticked)

**Problem.** The most wanted fact about Claude and Codex in a menu bar is the used share of the limit and when it resets.
The tools that show it ask for the keychain, cookies or a token, and go to the network.

**Evidence.** [CodexBar](https://github.com/steipete/CodexBar) 23,320 stars, [ccusage](https://github.com/ccusage/ccusage) 19,579,
[Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) 3,832; asked of Stats in
[#3449](https://github.com/exelban/stats/issues/3449). What people hate in CodexBar: keychain prompts ([#340](https://github.com/steipete/CodexBar/issues/340)), [lag](https://github.com/steipete/CodexBar/issues/1274), [power use](https://github.com/steipete/CodexBar/issues/139), and ["We don't care for pretty, we care for functional"](https://github.com/steipete/CodexBar/issues/1364). So: two lines, two files, no graph.

**API and what it gave.**
- Claude: `~/.claude.json`, key `cachedUsageUtilization`: `fetchedAtMs`, and `utilization.limits[]` with `kind`, `percent`, `severity`, `resets_at`, `scope`. Parsed in
  1.4 ms. Inferred, not proven: Claude Code writes it when it asks for usage itself. Here it was 47 minutes old and only had weekly limits (the five-hour one was null). Undocumented.
- Codex: the last `rate_limits` in the newest `~/.codex/sessions/**/*.jsonl`: `primary.used_percent`, `window_minutes`, `resets_at`. Null in some files, so look back; the newest
  real one here was five days old.
- Rules: always show the age; hide a limit whose `resets_at` has passed, or a reading older than six hours; hide everything when a key is missing. Never compute a percentage from tokens.

**Privacy.** `~/.claude.json` also holds the account and may hold keys of MCP servers. Read it only after the tick in Settings, decode
only this key, keep nothing else, log nothing, and say so beside the tick. In `~/.codex/sessions` read only lines that contain `rate_limits`.

**Where.** The tick in Settings with the explanation "Reads the limits Claude Code and Codex already saved on this Mac. Nothing is sent." Two lines at the top of the sessions page ("Claude week 62%, resets Thursday, 47 min ago"). Read when the page opens and every five minutes
while it stays open. MCP: a read-only `plan_usage`, present only when ticked.

**Check.** Unit: made-up files for fresh, stale, reset passed, null five-hour, missing key, broken JSON. A fixture with a fake account and key proves neither reaches the output of `--snapshot` or the MCP.
Real: the same percent as `/usage` in Claude Code at the same minute. NOT VERIFIED: that comparison was not made, and a Mac with only an API key was not seen.

### 7. The last twelve hours (M)

**Problem.** Pulse shows this moment and two minutes back. The question people bring is "why was it hot and slow this morning".

**Evidence.** The open Stats issue with the most reactions asks for a history view: [#1194](https://github.com/exelban/stats/issues/1194) (13 reactions). "I am now only monitoring [12 hour energy consumption](https://news.ycombinator.com/item?id=42882847)". An [iStat Menus 7 review](https://apps.apple.com/us/app/istat-menus-7/id6499559693) misses a memory history. Growth nobody sees is real: a Claude Code process [growing to 120 GB](https://github.com/anthropics/claude-code/issues/4953) (on Linux) has 80 reactions.

**API and what it gave.** `ps -axo pid=,time=` is cumulative CPU time for all 961 processes, root's included, in 16 ms; as one more column of the `ps` that already runs every 20 seconds it costs nothing.
Differences per pid and start time, added per row name into five-minute buckets: 144 buckets, the top eight names each, in memory, written every ten minutes to Application Support.
**Do not call it energy:** `ri_energy_nj` (Apple silicon only) added up to 1.9 W across the user's processes while the Mac drew 111 W, because the GPU and the system are outside it.

**Where.** Processes page: the CPU and Memory switch gains "12 h", same rows, value "1.4 h of CPU", with the peak memory under it. Explanation: "CPU time since 10:00, counted while Pulse was running." Rows past the buckets fall off. One alert, off by default: "keeps growing", when a footprint (feature 2)
has at least doubled over an hour, gained 4 GB, and never dropped by a tenth on the way. MCP: `recent_load`.

**Check.** Unit: three tables with fixed times give exact sums; a reused pid (other start time) starts at zero; a clock that jumps after sleep adds no more than real CPU time. A saw-tooth memory series never alerts, a steady one does.
Idle CPU of Pulse before and after with `ps -o time` over ten minutes: no visible change. Render with demo data.

### 8. Startup items that live inside apps (M)

**Problem.** The Startup area reads three folders. Apps now register their login items from inside their own bundle (`SMAppService`, which Pulse uses itself), and those are in none of the three.
So "Startup items unchanged" can be said while a new one was added, and the rule here is that what was not read is never healthy.

**Evidence.** [BlockBlock](https://github.com/objective-see/BlockBlock) and [KnockKnock](https://github.com/objective-see/KnockKnock) (886 and 843 stars) exist for this; one reviewer found [adware through a cleaner](https://apps.apple.com/us/app/cleanmymac-by-macpaw/id1339170533);
a cleaner that judged such items wrongly [removed valid ones](https://github.com/tw93/Mole/issues/204), so Pulse only reports.

**API and what it gave.** Two lists, joined, 47 ms together. `launchctl list` (which Pulse already runs) has the loaded labels: 13 that are neither Apple's nor plain running apps.
The bundles in `/Applications` and `~/Applications` hold what they can register, in `Contents/Library/LaunchAgents`, `LaunchDaemons` (plist `Label`) and `LoginItems` (the helper's bundle id): 4 here.
8 of the 13 were in the three folders, 1 only inside an app (the one Pulse misses today), 4 in neither (one-off updaters and jobs submitted by an app).
Who signed it: `SecStaticCodeCheckValidity` and `SecCodeCopySigningInformation`, up to 2.2 ms a file. Of 14 startup files 10 were signed with a certificate, 2 were ad hoc, 2 could not be resolved.
**Do not use** `launchctl print`: it answered, but its manual says the output "is NOT API in any sense at all".
**Not possible without admin rights:** the list behind System Settings (`sfltool dumpbtm` asks for an administrator; not run), so items that are registered and not loaded stay invisible. The area should say "loaded now".

**Where.** Health, Startup area: the list gains the items loaded from inside apps ("What starts with this Mac and is loaded now"), with the app's name and "Signed by <team>" or "Not signed by a known developer" (a fact, no points off: Homebrew tools are ad hoc).
**Trap:** existing users have a `knownStartup` from the folders only; on the first run take the new labels as known, or everyone gets an alarm. Leave out labels found in neither place, or every updater is news.

**Check.** Unit: `launchctl list` text and a temp folder of made-up bundles; a label inside an app and loaded is listed, not loaded is not, loaded and in neither place is not. Upgrade from an old `health.json` announces nothing; one added label announces once. Real: every label shown is in `launchctl list`.

---

## Later

- **Open ports and who can reach them:** [port-killer](https://github.com/productdevbook/port-killer) 5,180 stars; `lsof -nP -iTCP -sTCP:LISTEN` took 63 ms and showed 25 of the user's processes (root's own are missing). First in line after the eight; it was left out for a page of its own.
- **Keep awake for one or four hours:** [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704) and [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) (7,058 stars) do it free; `IOPMAssertionCreateWithName` with a timeout is simple, not tried because this research changed nothing. Goes on the sleep page of feature 3.
- **Heat on Intel, and fans everywhere:** the sensors Pulse reads are compiled for arm64 only in [Stats](https://github.com/exelban/stats/blob/master/Modules/Sensors/readers.swift) too, so on Intel Heat is probably absent and its alert never fires. Reading `AppleSMC` worked here without sudo (two fans, speeds and limits); the Intel keys (`TC0P`, `TC0D`) are absent on this Mac, so it needs an Intel tester first. [TG Pro](https://www.tunabellysoftware.com/tgpro/) sells both, on Intel and Apple silicon. Until then the alerts page should hide Heat when there is no reading.
- **Charger too weak:** `IOPSCopyExternalPowerAdapterDetails` gave 140 W; plugged in with a negative current means it drains. [WhatCable](https://github.com/darrylmorley/whatcable) (9,163 stars, Apple silicon only) shows the demand.
- **What is this process:** one plain sentence for `kernel_task`, `mds_stores`, `WindowServer` and thirty more, from a list in the app. [Apple explains kernel_task](https://support.apple.com/en-us/HT207359) as heat control. Cheap, but thirty true sentences need care.
- **Battery and disk trend:** `HealthDay` keeps 90 days already; add capacity and wear (feature 5), draw it once there are months to draw.
- **Simulators nobody opened for months:** feature 4 shows their size (30 GB here); removing them needs `simctl` and they hold test data.
- **Network totals:** `getifaddrs` in 0.04 ms, but VPN interfaces count the same bytes twice. Per app, `nettop` needed five seconds.
- **Uninstaller with leftovers:** leftovers live in `Library/Containers`, behind a permission dialog.
- **System checks:** XProtect date (`InstallHistory.plist`), configuration profiles (`profiles list`), automatic login. All readable, rarely wrong.
- **GPU load:** `IOAccelerator` "Device Utilization %" in 0.1 ms; matters to few until local models are common. Intel keys not checked.
- **Shortcut key to open the panel:** Carbon hot keys need no permission; no demand found.

## Not worth it

- **Intel-only apps before macOS 28:** macOS 27 [lists them itself](https://macrumors.com/2026/06/12/macos-golden-gate-rosetta-support); the check took 27 ms and would be obsolete in a year.
- **Desktop widgets:** Stats' [widgets showing no data](https://github.com/exelban/stats/issues/2115) are a steady complaint, and a widget needs an extension target.
- **Bluetooth batteries:** the same module took [bluetoothd to 40% CPU](https://news.ycombinator.com/item?id=42883117) in Stats.
- **Per-core graphs, weather, clocks, many menu bar items:** one view in the bar instead of many is what Stats users asked for in [#1084](https://github.com/exelban/stats/issues/1084).
- **A "free memory" button:** needs `purge`; macOS takes the memory back at once.
- **Maintenance scripts, database rebuilds, cache flushes** ([OnyX](https://www.titanium-software.fr/en/onyx.html)): admin rights, one build per macOS version, risk without a finding.
- **More alert types for CPU:** Stats users still ask for ["more than x seconds"](https://github.com/exelban/stats/issues/2436); Pulse has it.
- **Meters in the bar like MenuMeters:** its own [README](https://github.com/yujitach/MenuMeters) sends people to newer monitors.
- **More modules in general:** the top issue in CodexBar is ["becoming bloated"](https://github.com/steipete/CodexBar/issues/1364), and reviews of [iStat Menus 7](https://apps.apple.com/us/app/istat-menus-7/id6499559693) are mostly about bugs in options.

## Owner's decision

Each is only worth having by breaking, or stretching, a rule.

- **Optional Full Disk Access.** Without it, the date of the last Time Machine backup may stay `unknown` (the plist is refused here; no backup disk was set, so `tmutil latestbackup` could not be tried), the Trash cannot be measured, and a map of what fills the disk cannot be complete. Rule stretched: how little Pulse asks for.
- **Live plan limits.** The documented source is [`rate_limits` in the status line](https://code.claude.com/docs/en/statusline), which means Pulse adds a command to the user's Claude settings. Calling Anthropic needs network code and a token.
- **Reading conversation files** for tokens per day or how full a session's context is. The files are the user's conversations and can be tens of GB.
- **A hook in Claude Code** for permission prompts the moment they appear (feature 1 reads the record and needs no hook). Edits the user's settings.
- **Fan and charge control.** Needs a helper with root; AlDente's was reported as [exposing the SMC](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/674), and Stats [left fans at full speed after sleep](https://github.com/exelban/stats/issues/2977).
- **A firewall or blocking connections** as in [Little Snitch](https://obdev.at/products/littlesnitch/index.html) and [LuLu](https://github.com/objective-see/LuLu). Needs a system extension and an entitlement Apple grants.
- **Update check.** An open source app outside the App Store cannot say it is old without one request to the network.
- **A sound when a session waits.** Alerts are silent by rule; the request exists ([vibe-notch #50](https://github.com/farouqaldori/vibe-notch/issues/50)).
