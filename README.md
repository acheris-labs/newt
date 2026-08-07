# Newt

Tiny macOS menu bar app that keeps your Mac awake — including when the lid is
closed — for a chosen duration, then restores normal sleep.

Apple Silicon, macOS 13+. Developer ID signed and notarized.

## Install

Grab the latest `.dmg` from
[Releases](https://github.com/acheris-labs/newt/releases) and drag `Newt.app`
into `/Applications`.

On first launch macOS will prompt you to approve Newt's background helper
under **System Settings ▸ General ▸ Login Items & Extensions**. Enable it,
then quit Newt from the menu and reopen it — the helper status is only
re-checked at launch, so the warning won't clear until you relaunch. The
approval is one-time and lets the helper toggle `pmset disablesleep` as
root, which is what stops the Mac from sleeping when the lid is closed.

> **If the menu shows "Helper not found"** on Newt 0.1.2 or later, your
> browser likely quarantined the `.dmg` — `SMAppService` won't register a
> quarantined helper. Strip the flag and reopen Newt:
>
> ```
> sudo xattr -dr com.apple.quarantine /Applications/Newt.app
> ```
>
> Or re-download with `curl`, which avoids quarantine:
>
> ```
> curl -L -o Newt.dmg https://github.com/acheris-labs/newt/releases/latest/download/Newt-<version>.dmg
> ```
>
> Newt 0.1.0–0.1.1 had a separate bug producing the same message on fresh
> installs regardless of quarantine — upgrade to 0.1.2+ first.

Newt also sets itself as **Open at Login** by default; you can toggle that
off from the menu.

## Use

Click the menu bar icon.

- **Keep awake** slider — 16 positions: off, 30 min, 1 h, then every 2 hours
  to 24 h, and indefinite. Picking any non-zero position holds the Mac awake
  (display, idle, system, and lid-close). The right-hand label shows the
  duration and the wall-clock time it runs to (`4h/21:30`), ticking down live
  while the menu is open; a `+1` marks an end time that lands tomorrow.
- **Low battery cutoff** slider — 0–30%. While engaged and *on battery*, if
  the percentage falls to or below this floor, Newt auto-releases its
  claims so macOS can hibernate cleanly. 0 disables the cutoff (hold until
  the Mac dies). While below the cutoff and on battery the Keep-awake
  slider greys out so you can't accidentally re-arm.
- **Open at Login** — register Newt to launch at login.
- **Resume last state at launch** — off by default. When on, if Newt was
  engaged when it last quit (or crashed), it re-engages the same way on the
  next launch. Only the duration is remembered, not the time left, so an
  interrupted session restarts from full.
- **Configuration ▸** — per-mechanism **Wake modes** (each of the three IOKit
  assertions plus lid-close, with a time-of-day window and a "pause on
  battery" option under *Keep display on*), the **Left click action** for the
  menu bar icon, and **Notifications**: an indicator dot on the icon while
  engaged, and an alert when a timed session's clock runs out.

## Automation (`newt://`)

Newt registers a `newt://` URL scheme, so anything that can open a URL —
Shortcuts, `open(1)`, cron, Raycast, a Stream Deck — can drive it.

| URL | Effect |
| --- | --- |
| `newt://engage` | Engage at the last-used duration |
| `newt://engage?minutes=240` | Engage for exactly N minutes (1–1440) |
| `newt://engage?until=17:00` | Engage until the next occurrence of that time (24-hour `HH:MM`) |
| `newt://off` | Disengage |
| `newt://toggle` | Disengage if engaged, otherwise engage at the last-used duration |

From a terminal:

```
open "newt://engage?until=20:00"
```

These go through the same guards as the menu — the low-battery cutoff still
refuses to engage, and your enabled wake modes still decide which mechanisms
apply. Opening a `newt://` URL launches Newt if it isn't already running.

> Any process on your Mac (or a link you click in a browser) can open these
> URLs, so treat the scheme as convenience rather than a security boundary.
> The worst it can do is keep the Mac awake — visible from the menu bar icon,
> and undone from the menu or with `newt://off`.

### A weekday schedule with Shortcuts

Newt has no built-in scheduler, but a **Personal Automation** in the Shortcuts
app covers the common case:

1. New Automation → **Time of Day** → 08:00, Repeat **Weekly** on Mon–Fri
2. Action → **Open URL** → `newt://engage?until=20:00`
3. Turn off "Ask Before Running"

That single rule both starts and ends the session, since it engages with an
explicit end time. Add a matching 20:00 rule opening `newt://off` if you also
want to cut short any session you started by hand.

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
  Also raises an event-driven notification when the power source flips
  between AC and battery, which drives the "pause on battery" option.
- `NotificationManager.swift` — `UNUserNotificationCenter` wrapper for the
  timer-expiry alert.
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
