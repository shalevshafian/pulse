# Contributing

## Layout

- `Sources/PulseSMART`: a few lines of C, for a disk interface Swift cannot import.
- `Sources/PulseCore`: readings and rules. No UI. This is where the tests are.
- `Sources/Pulse`: the menu bar app, the panel, and the body of dots (`BodyMetal.swift`, on its own thread).
- `Pulse --mcp` is the MCP server, `--snapshot` prints one reading, `--health` one health check.

- The panel: `PanelView.swift` is the shell, the tabs and the one way forward and back (`PanelState`). A file per place,
  `Pieces.swift` for what they share. `Needs.swift` in the core decides what is on the first page and in what order.

## Rules the code keeps

- A process is closed only after its start time is checked again. Pids are reused.
- A session is live only if its pid is running and started at the recorded `procStart` (UTC).
- Optimize closes only sessions whose own record says `idle`, with SIGTERM.
- The `.key` files in `~/.claude/sessions` are never read.
- A reading that failed is `unknown`, never healthy. `HealthRules` is pure: a tool's text in, a check out.
- Cleanup takes a fixed list, and old build folders that carry cargo's own cache tag, inside the usual code folders.
- Drives: unmounted, never ejected, never forced. Volumes are kept by UUID; disk images and network volumes are left out.
  A dark wake, or a wake with the lid shut, connects nothing.
- The first page only leads to things. Nothing is closed, moved or changed from its list.
- What Pulse did is a receipt. Putting back never overwrites.
- MCP tools are read-only. No network code, no administrator rights, no dependencies.
- No emoji in the interface. The panel is 320 by 440 and does not resize.

## Tests

`swift test` opens no window and closes nothing but processes it started. Watch a new guard fail once
before trusting it. Two tests touch real things and run only when asked:

```sh
PULSE_DISK_TEST=1 swift test --filter testUnmountsAndMountsARealVolume    # a throwaway disk image
PULSE_SIM_TEST=1 swift test --filter testShutsDownARealSimulator          # a throwaway simulator
```

Look at what you changed: `Pulse --render out.png --page <name> --demo`. With `--demo` everything in
the picture is made up (`Demo.swift`; `--12h` shows the processes page at its third view), so it can be attached to a pull request. Without it, the
picture shows your own sessions and drives.

## A release

Set `VERSION`, add it to `CHANGELOG.md`, commit, and run `scripts/release.sh`. It needs a Developer ID
certificate and a notary profile; the top of the file says how to make one.
The bundle identifier `io.github.shalevshafian.pulse` stays as it is: macOS keeps notification
permission and the login item under it. A fork should use its own.

## Security

Report a vulnerability through GitHub's private reporting, on the Security page of the repository.
