# Newt

Tiny macOS menu bar app that keeps your Mac awake — including when the lid is
closed — for a chosen duration, then restores normal sleep.

Apple Silicon, macOS 13+. Developer ID signed and notarized.

## Install

Grab the latest `.dmg` from
[Releases](https://github.com/acheris-labs/newt/releases) and drag `Newt.app`
into `/Applications`.

On first launch macOS will ask you to approve Newt's background helper under
**System Settings ▸ General ▸ Login Items & Extensions**. Enable it, then quit
Newt from the menu and reopen it — the helper is only re-checked at launch, so
the warning won't clear until you relaunch. This one-time approval is what
lets Newt keep the Mac awake with the lid closed; everything else works
without it.

Newt sets itself to **Open at Login** by default. You can turn that off from
the menu.

## At a glance

The menu bar icon tells you the current state:

| Icon | Meaning |
| --- | --- |
| Outline lizard | Newt is idle — your Mac sleeps normally |
| Filled lizard | Newt is holding your Mac awake |
| Filled lizard with a dot | Same, with the optional indicator dot turned on |

Hover the icon to see the time remaining. Click it to open the menu (you can
change what a left click does — see **Configuration** below).

## Use

Click the menu bar icon.

- **Keep awake** slider — 16 positions: off, 30 min, 1 h, then every 2 hours
  to 24 h, and indefinite. Picking any non-zero position holds the Mac awake.
  The right-hand label shows the duration and the time it runs to (`4h/21:30`),
  counting down while the menu is open; a `+1` marks an end time that lands
  tomorrow. Slide back to **off** to stop early.
- **Low battery cutoff** slider — 0–30%. While engaged *on battery*, if the
  charge falls to or below this floor, Newt lets go so macOS can sleep before
  the battery runs flat. 0 disables the cutoff. Below the floor the Keep awake
  slider greys out so you can't accidentally re-arm it.
- **Open at Login** — launch Newt automatically when you log in.
- **Resume last state at launch** — off by default. When on, if Newt was
  keeping your Mac awake when it last quit, it picks up where it left off next
  time it starts. The duration restarts from full.
- **Check for Updates…** / **Check Automatically** — Newt updates itself.
- **Quit Newt** — quitting always restores normal sleep behaviour.

### Configuration

- **Wake modes** — choose which parts of sleep to prevent: keep the display
  on, keep the system awake when idle, prevent system sleep, and stay awake
  with the lid closed. All four are on by default.
  - Under *Keep display on*: **Display hours** limits the display-on
    behaviour to a time of day (say 09:00–23:00 — outside it the screen may
    sleep while everything else stays awake), and **Pause on battery** lets
    the display sleep whenever you're unplugged.
- **Left click action** — what clicking the icon does: open the menu, toggle
  the last duration you used, or toggle a fixed duration you set here.
  Right-click always opens the menu.
- **Notifications**
  - **Indicator dot when engaged** — adds a dot to the menu bar icon so
    "awake" is obvious at a glance.
  - **Notify when keep-awake expires** — posts a notification when a timed
    session runs out on its own. It won't fire when you turn Newt off
    yourself.

## Automation (`newt://`)

Newt registers a `newt://` URL scheme, so anything that can open a URL —
Shortcuts, the `open` command, cron, Raycast, a Stream Deck — can drive it.

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

These follow the same rules as the menu — the low battery cutoff still
refuses to engage, and your chosen wake modes still decide what applies.
Opening a `newt://` URL launches Newt if it isn't already running.

> Any process on your Mac (or a link you click in a browser) can open these
> URLs, so treat the scheme as a convenience rather than a security boundary.
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
want to cut short sessions you started by hand.

## Troubleshooting

**The menu says "Helper not found".** Your browser probably quarantined the
download, which stops macOS from registering Newt's helper. Clear the flag and
reopen Newt:

```
sudo xattr -dr com.apple.quarantine /Applications/Newt.app
```

**The menu bar icon disappeared.** Open Newt again from `/Applications` (or
Spotlight) — it restores the icon rather than starting a second copy. If your
menu bar is crowded, ⌘-drag the icon somewhere with more room; Newt remembers
where you put it.

**My Mac still won't sleep after quitting Newt.** Newt restores normal sleep
when it quits, and its helper does the same if Newt stops unexpectedly. To
force it by hand:

```
sudo pmset -a disablesleep 0
```

To see the current state — `SleepDisabled` should be `0` when nothing is
holding your Mac awake:

```
pmset -g | grep SleepDisabled
pmset -g assertions
```

## License

[MIT](LICENSE) © 2026 Chris Madden

---

Building Newt from source: see [CLAUDE.md](CLAUDE.md).
Signed, notarized release builds: see [DISTRIBUTING.md](DISTRIBUTING.md).
