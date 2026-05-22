# Newt

Tiny macOS menu bar app that keeps your Mac awake — including when the lid is
closed. A GUI sibling of the `lidawake` shell script: same effect, one click
away in the menu bar instead of a terminal and `sudo`.

Named after Rebecca "Newt" Jorden, who survived the colony by never sleeping.

Apple Silicon, macOS 13+.

## What it does

- **No sleep** — a checkbox that keeps the Mac awake indefinitely until you
  uncheck it.
- **Keep awake for** — a submenu of fixed durations (15 min … 8 hours); the Mac
  stays awake for that long, then sleep is restored automatically.

Both modes apply the full treatment:

- **Idle / display sleep** is blocked with the official `IOPMAssertion` API
  (no root, the same mechanism `caffeinate` uses).
- **Lid-close (clamshell) sleep** is blocked with `pmset -a disablesleep 1`,
  which requires root. A small privileged helper daemon does this; it is
  installed via `SMAppService` on first use.

When a timed session ends, the app quits, or the app crashes, normal sleep
behavior is always restored.

## First run

The first time you turn on keep-awake, macOS asks you to approve Newt's
background item under **System Settings ▸ General ▸ Login Items & Extensions**.
Enable it, then toggle keep-awake again. This is a one-time approval.

## Build

```
make build       # compile, assemble Newt.app, ad-hoc sign
make run         # build + open
make rerun       # kill + run (handy during iteration)
make clean       # remove build/
```

Builds land in `./build/Newt.app`.

## How it works

- `SleepManager.swift` — owns the keep-awake state (`off` / `indefinite` /
  `timed`). Creates IOKit power assertions and drives the helper.
- `HelperClient.swift` — registers the helper with `SMAppService` and talks to
  it over XPC.
- `NewtHelper/` — the privileged launchd daemon; runs `pmset disablesleep` as
  root and restores it if the app disconnects.
- `StatusItemController.swift` — the `NSStatusItem` and its menu.

## Troubleshooting

If sleep ever stays disabled (e.g. after a hard crash), the helper restores it
automatically when its connection drops. To force it by hand:

```
make reset-sleep        # sudo pmset -a disablesleep 0
```

## License

[MIT](LICENSE) © 2026 Chris Madden
