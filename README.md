# Pulse

A menu bar item for this Mac: CPU and memory in the bar, and a panel with the live
Claude Code sessions, what can be freed, and the heaviest apps.

- Build and install: `./build.sh --install`
- Tests: `swift test`
- Draw the panel to a PNG without opening a window: `Pulse --render out.png [--page plan|done|sessions|processes|rules|alerts|display] [--demo] [--dark]`
- One JSON reading: `Pulse --snapshot`

## MCP

`/Applications/Pulse.app/Contents/MacOS/Pulse --mcp` is a stdio MCP server with seven
read-only tools: `system_usage`, `claude_sessions`, `top_cpu`, `top_memory`, `dev_runtimes`, `optimize_suggestions`, `health_report`.
Agents can read; only a click in the panel closes anything.

## Rules the code keeps

- A session is live only if its pid is running **and** started at the recorded `procStart`
  (UTC). Pids are reused.
- Only sessions whose own record says `idle` are ever closed, with SIGTERM.
- An app that launched a live session is never offered for quitting.
- The `.key` files in `~/.claude/sessions` are never read.

## Drives in sleep

The drives page lists external drives; a ticked one is unmounted before the Mac sleeps and mounted
after a full wake. Nothing is ticked at first. Volumes are kept by UUID, disk images are left out.

- Unmounted, never ejected and never forced. A drive in use stays, with a notification naming the holder.
- The trigger is the kernel's sleep message, not the lid: a shut lid with a display attached is a Mac in use.
- A dark wake, or a wake with the lid shut, connects nothing. What is owed is in `drives.json`, events in `drives.log`.
- Real unmount and mount on a throwaway image: `PULSE_DISK_TEST=1 swift test --filter testUnmountsAndMountsARealVolume`.

## What it recognises

- Claude sessions, each with its process tree. An idle session whose own processes still use over 25% of a core is marked as still working and is never ticked by the rules.
- Booted iOS simulators, Android emulators and Gradle or Kotlin daemons, each as one row. Offered after an hour, never ticked by the rules. Shut down with `simctl shutdown` or `adb emu kill`; a daemon gets SIGTERM.
- The real shutdown is tested on a throwaway simulator: `PULSE_SIM_TEST=1 swift test --filter testShutsDownARealSimulator`.

## Health

`HealthProbe` reads eight areas (backup, protection, updates, storage, battery, stability,
performance, startup items) every six hours and on a press of the body. `HealthRules` turns
each tool's text into `ok`, `attention`, `urgent` or `unknown`; a failed reading is `unknown`,
never healthy. The app stores the result in `~/Library/Application Support/Pulse/health.json`;
the MCP server only reads that file.

- Nothing on the Mac is changed: a fix opens the right page of System Settings.
- Cleanup offers a fixed list of caches and stale folders that carry cargo's own cache tag.
  Nothing is ticked in advance, what is in use is locked, and everything goes to the Trash.
- Crashes inside the iOS simulator and a daemon passing its own memory limit do not count.
- A finding is announced once, then at most every two weeks. A solved one that returns is news.

`Pulse --health` prints one check without storing it. `Pulse --body out.png` and
`Pulse --film dir` draw the body's movements without a window.

The body is drawn with Metal on its own thread (`BodyMetal.swift`), at the display rate, only while its
window is on screen. `PULSE_WINDOW_BENCH=1 Pulse --bench-window` opens a window and prints frame times.
