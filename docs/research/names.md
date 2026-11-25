# Names, structure and wording: what was found, 25 November 2026

UNCONFIRMED marks are kept. Nothing here is a decision; the names in use are in the code.

Pulse naming, structure and wording research. Pulse strings were read from source at commit 9d214a8; no code was edited and nothing was rendered.

Source keys such as [A1] resolve at the end. Text in quotation marks was read raw unless marked *paraphrase*. Every line in the last table column was machine-counted under 60 characters.

## 1. Names

I recommend sentence case throughout. HIG only asks for one style per element type, applied consistently [H2].

| Feature: Pulse now | Apple | Others | Recommended | Line beneath |
|---|---|---|---|---|
| Tab **Now** | none | Device care [S1], Smart Care [C1], Dashboard (AlDente, Sensei, *paraphrase*) | **Overview** | What needs you now, and what is using this Mac |
| Score /100, body image | none | Samsung score out of 100 [S1]; CleanMyMac "Excellent" to "Critical" [C2] | **Health score** | Out of 100, from the last health check |
| **Needs you** | none | "Needs input" [V1]; "needs you" [G1] | keep | |
| **Not today** | none | Samsung thread asks for exactly this [U2] | **Hide until tomorrow** | Hidden until tomorrow, then shown if it still applies |
| **CPU** | CPU [A4] | CPU [T1] | keep | Share of all processor cores in use |
| **Memory**; "under pressure" | Memory Pressure [A1] | RAM [T1], Memory (RAM) [C3] | **Memory**; tooltip **Memory pressure** | How well memory is keeping up with demand |
| **Chip heat** / **Heat** | none confirmed | Temperatures [T2], Sensors [T1] | **Temperature** | Temperature of the chip, read from its sensors |
| **Disk free** | Storage [A7] | Disk [T1], Storage [C3] | **Free space** | Space left on the startup disk |
| **Using the most** | none | none | **Most CPU now** | Programs using the most processor time now |
| **Optimize** (button) | "Optimize Storage" means removing media and attachments [A7] | Optimise now [S1]; Run [C1]; Boost (*paraphrase*) [M1] | **Optimize…** | Shows what can be closed. You choose. |
| **What Optimize will do** | none | "Review" [C1] | **Choose what to close** | Nothing closes until you press the button below. |
| **By your rules** | none | "By default, CleanMyMac selects all" [C1] | **Selected for you** | Selected because of your settings |
| **Your choice** | none | Clear the checkmark [C1] | **Not selected** | Not selected. Choose any you no longer need. |
| Leftover processes | none | none | **Left by closed sessions** | Processes a closed session left running |
| Runtimes | none | OrbStack Stop/Restart [O1] | **Simulators and build tools** | Simulators, emulators and build tools still running |
| **Done** | HIG: use "Done" at the end of a flow [H2] | tiles [C1] | keep, add a count | What was closed, and what can be opened again |
| **Check now**, ring arrow | none | Scan / Start Over [C1]; Health checkup [M1] | **Check now** everywhere | |
| Tab **Activity** | Activity Monitor | Process Management [M1] | keep | Every app and process, sorted by what it uses |
| Live meters | CPU, GPU, Network are Activity Monitor pages [A4] | CPU, GPU, RAM, Net [T1] | keep | Live processor, memory, graphics and network use |
| **12 h** | "12 hr Power" is energy, so not this | none | **12 h**; heading **CPU time, last 12 hours** | CPU time, counted while Pulse was running |
| **Ports** | none confirmed | "port forwards" [O1] | **Ports**; heading **Listening ports** | Programs accepting connections, and from where |
| Program page | "View information about processes" [A4] | none | **Process details** | What it is, what it uses, and what closing loses |
| **When it was busy** | none | none | **CPU time** | Processor time over the last 12 hours |
| **Quit X** / **Stop it** / **Shut down** / **Stop session** | Quit, Force Quit [A2] | Process Management "quickly close" [M1] | **Quit** (apps), **Stop** (processes, sessions), **Shut down** (simulators) | |
| **Never close this** | none | "Always keep these sites active" [B1]; Excluded apps [S1] | **Never close** | Pulse will not offer or close this |
| Tab **Claude** | none | "Sessions" (Claude, Codex, Kith) [V1][X1][G2] | **Sessions** | Claude Code and Codex sessions on this Mac |
| waiting / working / idle | none | "Needs input, Working, or Completed" [V1] | **Needs input / Working / Idle / Status unknown** | Needs an answer or a permission from you |
| "Says idle, but…" | none | none | **Idle, still working** | Reported idle, but something under it still runs |
| **Open** (session) | none | jump back to the terminal [G1][G2] | **Open app** | Brings the app running this session to the front |
| Plan tile | none | "session, weekly, and monthly windows" [G3] | **Plan limits** | Limits already saved on this Mac, with their age |
| Tab **Care** | none | Device care [S1], Smart Care [C1] | keep | |
| **Health** | none | Mac health [C2], Health checkup [M1] | **Health check** | Backup, security, updates, hardware and crashes |
| Areas **Safety, Speed, Disk, Updates** | Storage, Battery | Protection, Performance [C1] | **Security, Performance, Storage, Updates**; Backup, Battery, Crashes keep | |
| **Could not check** | none | none | keep | Pulse could not read these, so they are not scored |
| **Ignored** / **Restore** | "Ignore" is a HIG example [H1] | Ignore list [C1] | **Ignored** / **Stop ignoring** | Left out of the score until you stop ignoring them |
| **I know it** | none | none | **Mark as known** | |
| **Open Safety/Login Items…** links | direct link, as HIG asks [H2] | none | **Open in System Settings** | |
| **Disk** | Storage [A7] | Storage [C3], Disk [T1] | **Storage** | Space used, disk wear and what can be cleared |
| Wear | none | Drive health (Sensei, *paraphrase*) | **SSD wear** | Share of the disk's rated writing life used |
| **Cleanup** / Move to Trash | Free up storage space [A8] | Cleanup [C1], Deep Cleanup [M1] | **Cleanup** / **Move to Trash** | Files that are rebuilt or downloaded again |
| **Largest folders in your Library** | large files [A8] | locating "space wasters" [D2] | **Largest Library folders** | Shown only. They may hold your work. |
| **Battery** "health N%" | **Maximum Capacity**; "Normal" / "Service recommended" [A6][A9] | battery health [K1] | **Battery**; row **Maximum capacity** | Capacity compared with new, and charge cycles |
| **Sleep** | sleep | Sleep Control (AlDente) [L1] | keep | What keeps this Mac awake, and how it last slept |
| **Keep awake** | none | "keep-awake session" [P1]; Awake [P2] | keep | Keeps the Mac awake. The display may turn off. |
| **Asks this Mac to stay awake** | **Preventing Sleep** [A3] | none | **Preventing sleep** | Programs asking this Mac not to sleep |
| **Last sleep** | none | "last shutdown or sleep" [T2] | keep | How long it slept and how much charge it used |
| **Drives in sleep** | Eject in Finder, but Pulse unmounts and never ejects | Jettison: "eject" and "remount" [J1] | **Unmount drives for sleep** | Unmounts chosen drives, then mounts them on wake |
| **Connect**, "Disconnected" | Mount/Unmount (Disk Utility; UNCONFIRMED wording) | "remount" [J1] | **Mount**, "Unmounted" | |
| **Startup** | **Login Items & Extensions**; "Open at Login"; "App Background Activity" [A5] | Startup Item Management [M1] | **Login items** | What starts with this Mac, and who signed it |
| **Loaded now / Set up, not loaded** | none | none | **Loaded now / Not loaded** | Installed, but not loaded now |
| **History** | none | none | keep | What Pulse did, and how to undo it |
| **Put back** / Open again / Resume | **Put Back** [A10] | "Cancel", 5 seconds [D1] | keep, plus **Copy resume command** | |
| Tab **Settings** | Settings | Settings | keep | Alerts, menu bar items and what may be closed |
| **Menu bar** / Beside the icon | Menu bar | Menu Bar Customization (AlDente, *paraphrase*) | keep | Readings shown beside the icon |
| **Alerts** | Notifications | Rules (iStat) [I1] | **Notifications** | Silent notifications for the things you choose |
| **Rules** | none | means notifications in iStat [I1] | **Closing** | Which rows Optimize selects for you |
| **Never touch** | none | Excluded apps [S1] | **Never close** | Names Pulse never offers and never closes |
| **Shortcut** | Keyboard shortcut | Hot key [P1] | **Keyboard shortcut** | Opens Pulse in a window from any app |
| **Open at login** | **Open at Login** [A5] | none | keep | |
| **Copy the command for Claude Code** | none | none | **Connect an agent (MCP)** | Lets an agent read these figures, and change nothing |
| Source and updates, Quit Pulse, Test | Quit | none | keep; **Send test notification** | |

Searched without adding a name: Edge Sleeping tabs and Task Manager Efficiency mode slow or pause things, Docker Resource Saver stops an idle VM, App Tamer throttles apps. Pulse closes, so none of these terms apply.

## 2. Structure

**What exists**
- **One check, then modules:** CleanMyMac runs Cleanup, Protection, Performance, Applications, My Clutter. Main action is Scan, then review, then Run [C1]. Samsung opens on a score with one button [S1].
- **One section per resource:** Activity Monitor, Stats [T1], and the CleanMyMac Menu in the order health, protection, storage, memory, battery, CPU, network, devices [C3].
- **Attention first:** Kith puts sessions "that need input" first [G2]; CodeStatus shows free / busy / needs you [G1].

Pulse combines the first and third, so its current order is right. HIG asks for single-word tab labels, tabs for navigation rather than actions, and badges only for critical information [H4].

**Recommended tabs: Overview, Activity, Sessions, Care, Settings**
1. **Claude becomes Sessions.** Claude's docs, Codex's docs navigation and the menu bar tools all use the word. "Agents" is ambiguous, because Claude's extension also shows a subagent count as "2 agents" [V1]. The Codex *desktop app's* own noun is UNCONFIRMED.
   - Sort by state (Needs input, Working, Idle, Status unknown), with Claude or Codex as a small label on each row.
   - Codex may have to show **Status unknown**. CodeStatus reports that "waiting for you to answer a question" is "not observable through any official channel", though approval requests are [G1]. Never map unknown to Idle, because idle rows can be closed.
   - Knock-ons:
     - `hasClaude` hides the tab, so a Codex-only Mac would lose it.
     - The "Claude sessions" header and the "On the Claude page" heading.
     - The `claude --resume` command in Receipts.
     - The "working session is never closed" sentence.
   - The MCP tool `claude_sessions` may sit in users' configurations. Add a new name and keep the old one.
2. **Now becomes Overview.** "Now" is a time, not a kind of content, and Activity is live too.
3. **Keep Care, shrink it from 8 rows to 6:** Health check, Storage (Disk plus Cleanup, as Apple puts storage recommendations inside Storage [A7]), Battery, Sleep (plus Unmount drives), Login items, History. Show "1 drive still unmounted" on the Sleep row.
4. **Battery needs its own section.** Today its row opens Health.
5. **Main action stays on Overview only.** Let findings say **Review** instead of a second "Optimize". Add the ellipsis, since HIG uses it when a button opens another view [H6].
6. **History** stays last in Care and stays linked from Done. Add a "See history" link to the notice line on Overview.
7. HIG prefers a menu over a popover for a menu bar extra, unless the functionality is too complex for a menu [H3]. Pulse qualifies. HIG also says not to rely on the extra being visible; reopening Pulse from Applications already covers that.

## 3. Explanation patterns

**a. Why it is suggested**
- Best models:
  - Little Snitch: "What the app does, why it needs that connection and what would happen if you denied it." [F1]
  - Chrome: "This notification appears when you experience poor browsing performance." [B1]
  - NN/g: naming "the specific source of data" let users understand why they were shown something [N2].
- Proposed pattern, evidence then rule:
  - "Idle for {time}. Your limit is {n} hours."
  - "The session that started this has closed."
  - "Up for {time}. No build is using it."
  - Finding: "{name} is using {n}% of the CPU."

**b. What will happen**
- Models:
  - Apple Quit: "The process quits when it's safe to do so." [A2]
  - Chrome: "When you access an inactive tab, it automatically reloads." [B1]
  - NN/g: do not ask "Are you sure"; explain the effect [N1].
- Proposed:
  - App: "Asks {app} to quit. It may ask you to save."
  - Session: "Stops the session. The conversation stays on this Mac."
  - Simulator: "Shuts it down with its own tool. Its data stays."
  - Final button: "Close {n} items". Beside it: "These use {size} now. Closing may free less."

**c. What is lost**
- Models:
  - Apple Force Quit: "If the process has files open, you may lose data." [A2]
  - iOS: offloading "frees up storage used by the app, but keeps its documents and data." [A11]
  - DaisyDisk says plainly its files "cannot be 'undeleted'" [D1].
- Proposed:
  - Process: "Unsaved work in it is lost. Pulse cannot start it again."
  - Cleanup: "{Tool} downloads this again. The next build takes longer."
  - Second press: "Stop {name}" with "{Warning}. Press again to stop."

**d. What was done, and the way back**
- Models:
  - Apple: "select the item, then choose File > Put Back" [A10].
  - DaisyDisk: "5 seconds to change your mind and press Cancel" [D1].
  - HIG: help people predict an undo and show its result [H5].
- Proposed:
  - "{n} of {m} closed. {k} skipped."
  - Skipped row: "Not closed: it started working again."
  - "Memory used: {before} before, {after} now. Other apps may have changed this."
  - "Moved {size} to the Trash. Space is free after you empty it." [Put back]
  - After undo: "Put back in {folder}." or "Not put back: {reason}."
  - Process: "Closed. Pulse cannot start it again."

**e. First run and permission**
- HIG: postpone nonessential setup [H7]; request permission "only when your app clearly needs access" [H8].
- Counter-example: CleanMyMac says that without Full Disk Access "your Mac may have reduced storage space and could run slower" [C4].
- Proposed first run:
  - "Pulse shows what needs you on this Mac."
  - "It closes nothing until you choose it and confirm."
  - "It has no network code. What it reads stays on this Mac."
  - [Open at login] [Silent notifications] **Start**
- Consider asking for notifications when the first one is switched on, instead of ticking it in advance.
- Plan limits: "Reads limits that Claude Code and Codex saved on this Mac. One file also holds your account. Pulse keeps only the limits."

**Replace existing strings**

| Now | Proposed |
|---|---|
| "Memory is critical" | "Memory pressure is high" |
| "{n} things cannot wait" | "{n} need you now" |
| "Back up now." | "Back up before using it further." |
| "All good" | "Nothing needs you" |
| "Nothing to close. Everything is in use." | "Nothing to close right now." |
| "Disk hardware is fine" | "The disk reports no failure" |
| "{size} can be cleared" | "{size} in caches that can be rebuilt" |

Keep the caution triangle rare; HIG says frequent use "diminishes its significance" [H1].

## 4. What users criticise

- **Findings regardless of condition:** the FTC charged Restoro and Reimage over scans that typically reported serious problems whatever the computer's actual health; $26 million settlement (*paraphrase*) [U1]. MacKeeper's $2 million class settlement alleged the same (secondary source, UNCONFIRMED against court papers).
- **Alarm followed by a paywall:** a CleanMyMac App Store review describes "gigabytes of 'junk' and alarming security warnings, and then hitting a brick wall", and calls it "aggressive freemium anxiety marketing" [U3].
- **A prompt that never ends:** "constantly tells me to OPTIMIZE NOW. … I can clear it and then go right back to it" [U2]. Pulse should show "Nothing to close" and stay quiet.
- **Freed RAM:** CleanMyMac's Menu offers to free memory "instantly" [C3], while its own blog says "'free RAM' is not the goal on Apple silicon. Unused memory is wasted memory." [C5] Apple says cached files stay in unused memory to improve performance [A1]. Pulse's before and after figures are honest, so never call the difference "freed".
- **Cache cleaning oversold:** DaisyDisk, a competitor, says "Cache files reappear soon" and "macOS can clean itself very well" [D2].
- **Self-interest dressed as repair:** press reports say PC Manager listed not using Bing under repair tips (secondary).
- **Cleaner damage and bloat:** Mole #823 and #204, CodexBar #1364, as already cited in FEATURES.md (not reopened here).

## Not confirmed
- UNCONFIRMED: Apple "Eject" and Disk Utility wording; Task Manager's dialog beyond Microsoft's support text; iStat Menus labels beyond its product page summary; AlDente, Sensei and the PC Manager product page (summaries only); Android menu paths on specific phones; Apple Community complaints (not opened).
- NOT VERIFIED: whether the proposed strings fit the 320-point panel. "Optimize…" beside a size and "Unmount drives for sleep" are the ones to check first.

## Sources
- **Apple:**
  - A1 https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac
  - A2 https://support.apple.com/guide/activity-monitor/quit-a-process-actmntr1002/mac
  - A3 https://support.apple.com/guide/activity-monitor/view-energy-consumption-actmntr43697/mac
  - A4 https://support.apple.com/guide/activity-monitor/welcome/mac
  - A5 https://support.apple.com/guide/mac-help/mtusr003/mac
  - A6 https://support.apple.com/guide/mac-help/mchlfc3b7879/mac
  - A7 https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac
  - A8 https://support.apple.com/en-us/102624 (*paraphrase*)
  - A9 https://support.apple.com/guide/mac-help/mh20865/mac
  - A10 https://support.apple.com/guide/mac-help/mchlp1093/mac
  - A11 https://support.apple.com/en-us/108429
- **HIG** (https://developer.apple.com/design/human-interface-guidelines/…): H1 alerts, H2 writing, H3 the-menu-bar, H4 tab-bars, H5 undo-and-redo, H6 buttons, H7 onboarding, H8 privacy
- **CleanMyMac** (https://macpaw.com/support/cleanmymac/knowledgebase/…): C1 smart-care, C2 mac-health, C3 cleanmymac-menu, C4 full-disk-access; C5 https://cleanmymac.com/blog/mac-memory-cleaner
- **Monitors and battery:** T1 https://github.com/exelban/stats (module names), T2 https://www.tunabellysoftware.com/tgpro/, I1 https://bjango.com/help/istatmenus7/rules/ (*paraphrase*), K1 https://www.coconut-flavour.com/coconutbattery/, L1 https://apphousekitchen.com/aldente/features/
- **Disk and drives:** D1 https://daisydiskapp.com/guide/4/en/DeletingFiles/, D2 https://www.daisydiskapp.com/, J1 https://www.stclairsoft.com/Jettison/
- **Awake:** P1 https://apps.apple.com/us/app/amphetamine/id937984704, P2 https://learn.microsoft.com/en-us/windows/powertoys/awake
- **Windows, phone, browser:** M1 https://pcmanager.microsoft.com/en-us/termsofservice, S1 https://www.samsung.com/uk/support/mobile-devices/how-do-i-use-device-care/, B1 https://support.google.com/chrome/answer/12929150
- **Dev:** F1 https://help.obdev.at/littlesnitch5/ra-overview, O1 https://docs.orbstack.dev/menu-bar, V1 https://code.claude.com/docs/en/vs-code, X1 https://developers.openai.com/codex/cli/features, G1 https://github.com/henriquegpb/codestatus, G2 https://github.com/whysosaket/kith, G3 https://github.com/steipete/CodexBar
- **NN/g:** N1 https://www.nngroup.com/articles/confirmation-dialog/, N2 https://www.nngroup.com/articles/recommendation-guidelines/
- **Criticism:**
  - U1 https://www.ftc.gov/news-events/news/press-releases/2024/03/tech-support-firms-will-pay-26-million-settle-ftc-charges-they-deceived-consumers-buying-repair
  - U2 https://us.community.samsung.com/t5/Galaxy-S25/Device-Care-constantly-asks-me-to-quot-OPTIMIZE-NOW-quot-how-can/m-p/3345862
  - U3 https://apps.apple.com/us/app/cleanmymac-by-macpaw/id1339170533
  - MacKeeper: https://www.computerworld.com/article/1372335/mackeeper-celebrates-a-difficult-birthday.html
  - PC Manager: https://www.theregister.com/2024/05/16/microsoft_pc_manager_bing/
