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
| Lizard with a yellow warning badge | **Suppress all claims** is on — Newt won't hold your Mac awake at all |

The dot's colour says *what* is holding your Mac awake. Out of the box that's
green for the Keep awake slider or the schedule and blue for a dynamic claim,
with the dot split down the middle when both are holding at once; you can pick
your own colours in Settings.

Hover the icon to see everything currently holding your Mac awake — the Keep
awake slider with its time remaining, the schedule, and any dynamic claims — or
why it isn't, when Suppress or the battery cutoff is refusing. Click it to open
the menu (you can change what a left click does in **Settings**).

## Use

Click the menu bar icon.

- **Keep awake** slider — 16 positions: off, 30 min, 1 h, then every 2 hours
  to 24 h, and indefinite. Picking any non-zero position holds the Mac awake.
  The right-hand label shows the duration and the time it runs to (`4h/21:30`),
  counting down while the menu is open; a `+1` marks an end time that lands
  tomorrow. Slide back to **off** to stop early.
- **Use schedule** — hold your Mac awake on a repeating weekly timetable, say
  Mon–Fri 08:00–20:00 and never at weekends. Tick this to switch the timetable
  on. The item itself tells you what the schedule is doing — *awake until 20:00*,
  *next Mon 08:00*, *suppressed until 20:00*, or *no hours set*. You set the
  hours themselves in *Settings ▸ Schedule*.
- **Suppress all claims** — "not right now". While it's ticked, nothing keeps
  your Mac awake: not the schedule, not the Keep awake slider, not a dynamic claim.
  The menu bar icon gets a yellow warning badge so you can't leave it on by
  accident, and hovering tells you when it lifts. Ticking it during a scheduled
  block only skips the rest of *that* block — it clears itself when the block
  would have ended, so tomorrow still works. With no schedule running it simply
  stays on until you untick it.
- **Claims** — everything currently holding your Mac awake, in one place. Greyed
  out when that's nothing. The Keep awake slider and the schedule are listed but
  greyed, since you turn those off with their own controls; claims raised by AI
  agents — *dynamic claims* — can be inspected and revoked here (see
  [below](#keeping-the-mac-awake-while-an-ai-agent-works)).
- **Settings…** (⌘,) — everything you set once and forget. See
  [Settings](#settings).
- **Check for Updates…** — Newt updates itself.
- **Quit Newt** — quitting always restores normal sleep behaviour.

## Settings

**Settings…** in the menu (or ⌘,) opens a window with six tabs, listed here in
the order they appear.

**General**

- **Open at login** — launch Newt when you log in.
- **Resume last state at launch** — off by default. When on, if Newt was keeping
  your Mac awake when it last quit, it picks up where it left off; the duration
  restarts from full.
- **Check for updates automatically** — Newt updates itself.
- **Low battery cutoff** (0–30%) — while Newt is holding your Mac awake *on
  battery*, if the charge falls to or below this floor Newt lets go so macOS can
  sleep before the battery runs flat, then picks up again once you plug in. 0
  disables it. Below the floor the Keep awake slider greys out so you can't
  accidentally re-arm it.
- **Claim limit** — the longest a dynamic claim may be held before Newt lets go
  of it, whatever the agent says. A backstop: agents normally release their own
  claims, and Newt drops one whose process dies, but neither helps if the agent
  is alive and simply never releases. Off means no limit.

**Wake Modes** — which parts of sleep to prevent: keep the display on, keep the
system awake when idle, prevent system sleep, and stay awake with the lid
closed. All four are on by default. Under *Keep display on*, **Display hours**
limits that behaviour to a time of day (say 09:00–23:00 — outside it the screen
may sleep while everything else stays awake) and **Pause on battery** lets the
display sleep whenever you're unplugged.

**Schedule** — *Follow this schedule* plus the weekly grid. See
[Setting a schedule](#setting-a-schedule).

**Left Click** — what clicking the menu bar icon does: open the menu, toggle the
last duration you used, or toggle a fixed duration you set here. Right-clicking
always opens the menu.

**Integrations** — register dynamic claims with the coding tools you use, so
they can hold your Mac awake while they work. Claude Code is supported today;
others are listed greyed out until they are. See
[below](#keeping-the-mac-awake-while-an-ai-agent-works).

**Notifications** — *Notify when keep-awake expires*, plus the indicator dot:
whether to show it, how big it is, whether to outline it, whether it spins while
both kinds of claim are holding, and a colour for each. The outline is what
keeps the dot readable when a bright wallpaper shows through the menu bar, so
leave it on unless you have a reason not to. *Use Default Colours* puts the
colours back. A live preview shows all three states as you adjust them.

## Setting a schedule

**Settings ▸ Schedule** shows a week at a glance: seven rows, midnight to midnight left to right, with your awake hours drawn as blue
bars.

- **Add hours** — drag across an empty stretch of a day. A single click drops
  in a one-hour block you can then adjust.
- **Change hours** — drag a bar's middle to slide it, or either end to stretch
  it. Everything snaps to the half hour, and the times are written on the bar.
- **Overnight** — drag a bar's right-hand end down into the row below. The bar
  runs to midnight on its own day and reappears, faded, at the start of the
  next — that faded part is a reminder, not a separate bar, so edit it from the
  day it belongs to.
- **Remove hours** — click a bar to select it and press Delete, or right-click
  it and choose Delete.
- **Follow this schedule** at the top is the same switch as **Use schedule** in
  the menu.

Changes save as you make them; there's no Save button. Overlapping bars on the
same day merge into one.

The schedule and the **Keep awake** slider are independent — if either one
says stay awake, your Mac stays awake. So you can sit inside your 08:00–20:00
block and still slide **Keep awake** to 4 h to cover the evening. Turning the
slider back to off doesn't cut the scheduled hours short; **Suppress all
claims** is the switch for that.

## Automation (`newt://`)

Newt registers a `newt://` URL scheme, so anything that can open a URL —
Shortcuts, the `open` command, cron, Raycast, a Stream Deck — can drive it.

| URL | Effect |
| --- | --- |
| `newt://engage` | Engage at the last-used duration |
| `newt://engage?minutes=240` | Engage for exactly N minutes (1–1440) |
| `newt://engage?until=17:00` | Engage until the next occurrence of that time (24-hour `HH:MM`) |
| `newt://off` | End the session the slider is running |
| `newt://toggle` | End it if one is running, otherwise engage at the last-used duration |
| `newt://suppress` | Turn Suppress on — nothing keeps the Mac awake, schedule included |
| `newt://suppress?toggle` | Flip Suppress, for a single hotkey or Stream Deck key |
| `newt://unsuppress` | Turn Suppress off |
| `newt://claim?acquire=true&id=X` | Hold the Mac awake under the name `X` (see below) |
| `newt://claim?acquire=false&id=X` | Let that one go |

From a terminal:

```
open "newt://engage?until=20:00"
```

These follow the same rules as the menu — the low battery cutoff and Suppress
still refuse to engage, and your chosen wake modes still decide what applies.
`newt://off` ends the session the slider is running and nothing more: if a
scheduled block is in progress, your Mac stays awake for the rest of it.
Opening a `newt://` URL launches Newt if it isn't already running.

> Any process on your Mac (or a link you click in a browser) can open these
> URLs, so treat the scheme as a convenience rather than a security boundary.
> The worst it can do is keep the Mac awake — visible from the menu bar icon,
> and undone from the menu or with `newt://off`.

## Keeping the Mac awake while an AI agent works

A long agentic run looks exactly like an idle machine: no keyboard, no mouse,
just a coding agent grinding through tool calls. Newt can notice that and hold
your Mac awake for as long as the agent is actually working — and let it sleep
normally the moment it stops.

Turn it on by ticking **Claude Code** in *Settings ▸ Integrations*.
Newt adds three hooks to `~/.claude/settings.json`, merging with what's there
and backing the file up first. Claude usually picks the hooks up straight away;
if a session you already have open doesn't start claiming, restart it.
Unticking it removes only what Newt added.

From then on, Newt holds your Mac awake from the moment you send a prompt until
the agent finishes replying. An agent session left sitting idle at the prompt
holds nothing, so your Mac still sleeps when you walk away.

This is a third way of holding the Mac awake, independent of the Keep awake
slider and the schedule — any one of them is enough. **Suppress all claims** and
the low battery cutoff still override all three.

### When something gets stuck

There's a **Claims** item near the bottom of the menu. It's greyed out when
nothing is holding your Mac awake, and becomes available when something is.
Claims raised from outside Newt — by an agent, or by anything else using
`newt://claim` — are called **dynamic claims**, and are listed by project and
terminal:

```
claude — newt (ttys002)
claude — agent-scoreboard (ttys014)
```

Click a dynamic claim and Newt tells you exactly what it is — which agent,
which project,
which terminal, the process it belongs to, when it started and how long it's
been held, and the agent's session id — with a **Revoke** button to let it go.
There's also **Release all dynamic claims** if you'd rather not pick. The Keep
awake slider and the schedule appear in the same list but greyed, since you turn
those off with their own controls.

You shouldn't normally need any of it: an agent releases its own claim when it
finishes, and if it's killed outright Newt notices the process is gone and
releases on its behalf. The list is there for the case where neither happened —
and a claim showing *(owner unknown)* is one Newt couldn't tie to a process, so
the dialog says so, because that's the one with nothing else to catch it.

Newt watches the agent's process too, so if it's killed outright the claim is
released even though no hook ran.


## Troubleshooting

**The menu says "Helper not found".** Your browser probably quarantined the
download, which stops macOS from registering Newt's helper. Clear the flag and
reopen Newt:

```
sudo xattr -dr com.apple.quarantine /Applications/Newt.app
```

**The menu says the helper is out of date.** A leftover piece of the previous
version is still running. Clear it with:

```
sudo launchctl kickstart -k system/net.acheris.newt.helper
```

Then reopen Newt. That fixes it for good — it only ever happens once, when
updating from 0.4.1 or earlier.

Quitting and reopening Newt will *not* help: the leftover piece runs separately
from the menu bar app, so only the command above (or a restart, if you'd rather)
clears it.

**The menu says the helper can't be registered, or asks you to turn Newt on
under "Allow in the Background".** Open System Settings ▸ General ▸ Login Items
& Extensions and switch **Newt** on under *Allow in the Background*, then quit
and reopen Newt. If Newt isn't listed there, or switching it on doesn't stick,
quit Newt, drag `/Applications/Newt.app` to the Trash, empty it, and reinstall
from the disk image — that clears the stale record macOS is holding.

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
