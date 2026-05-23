# Newt

Tiny macOS menu bar app that keeps your Mac awake — including when the lid is
closed — for a chosen duration, then restores normal sleep.

Apple Silicon, macOS 13+. Developer ID signed and notarized.

## Install

Grab the latest `.dmg` from
[Releases](https://github.com/acheris-labs/newt/releases) and drag `Newt.app`
into `/Applications`.

On first launch macOS will prompt you to approve Newt's background helper
under **System Settings ▸ General ▸ Login Items & Extensions**. Enable it —
this is a one-time approval that lets the helper toggle `pmset disablesleep`
as root, which is what stops the Mac from sleeping when the lid is closed.

Newt also sets itself as **Open at Login** by default; you can toggle that
off from the menu.

## Use

Click the menu bar icon.

- **Keep awake** slider — 11 positions: off, 1 min, 15 min, 30 min, 1 h, 2 h,
  4 h, 8 h, 16 h, 24 h, indefinite. Picking any non-zero position holds the
  Mac awake (display, idle, system, and lid-close). A live countdown ticks
  in the right-hand label while the menu is open.
- **Low battery cutoff** slider — 0–30%. While engaged and *on battery*, if
  the percentage falls to or below this floor, Newt auto-releases its
  claims so macOS can hibernate cleanly. 0 disables the cutoff (hold until
  the Mac dies). While below the cutoff and on battery the Keep-awake
  slider greys out so you can't accidentally re-arm.
- **Open at Login** — register Newt to launch at login.

## How it works

- `SleepManager.swift` — single source of truth for keep-awake state.
  While engaged it holds three IOKit power assertions:
  `PreventUserIdleSystemSleep`, `PreventUserIdleDisplaySleep`, and
  `PreventSystemSleep` (mirrors `caffeinate -dis`). Owns the expiry
  timer and the slider mapping.
- `HelperClient.swift` — registers the privileged daemon via
  `SMAppService.daemon` and talks to it over XPC. Identifier-pinned
  code-signing requirement on both ends.
- `NewtHelper/` — the launchd daemon that runs
  `/usr/bin/pmset -a disablesleep 0|1` as root. If Newt disconnects
  while sleep is disabled the helper restores it automatically.
- `BatteryMonitor.swift` — polls `IOPSCopyPowerSourcesInfo` every 15 s
  while engaged; trips disengage when on battery and percent ≤ threshold.
- `LoginItemController.swift` — `SMAppService.mainApp` for auto-launch.
- `StatusItemController.swift` — the `NSStatusItem`, the menu, and the
  custom slider views.

## Build from source

```
make build       # compile, assemble Newt.app, ad-hoc sign
make run         # build + install to /Applications + open
make rerun       # kill + run (handy during iteration)
make clean       # remove build/
```

SMAppService daemons require the app to be in `/Applications`, so `make run`
installs there rather than launching out of `build/`.

For signed/notarized distribution builds see [DISTRIBUTING.md](DISTRIBUTING.md).

## Troubleshooting

If sleep ever stays disabled (e.g. after a hard crash before the helper
could reset it), the helper restores it on its next connection drop. To
force it by hand:

```
make reset-sleep        # sudo pmset -a disablesleep 0
make helper-status      # show current SleepDisabled + active assertions
```

## Reference

The IOKit assertion list matches what `caffeinate -dimsu` creates, minus
`-m` (disk idle — no public IOKit assertion exists) and `-u` (declare
user active — irrelevant when the display is already on). The privileged
helper covers the lid-close case via `pmset -a disablesleep 1`.

## License

[MIT](LICENSE) © 2026 Chris Madden
