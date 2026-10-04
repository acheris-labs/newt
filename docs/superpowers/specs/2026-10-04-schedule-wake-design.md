# Waking for the schedule

## Problem

The weekly schedule can only *hold* a Mac awake. If the Mac is asleep when a
block starts, nothing happens until something else wakes it — the block then
applies from that moment, via the `didWakeNotification` reconcile. A 07:00
block on a Mac that slept overnight is a 07:00 block that never starts.

Separately, there's no way to say "the schedule is for when I'm at a desk".
The battery floor is a percentage safety net over every claim; "Pause display
on battery" only lets the screen go. Neither stops the schedule holding a
MacBook awake in a bag.

## Design

Three settings on the Schedule tab, all default off so an upgrade changes
nothing:

```
☐ Follow this schedule
☐ Pause the schedule on battery
☐ Wake the Mac when a block starts
    ☐ Even when on battery
```

- **Pause the schedule on battery** — while unplugged, the schedule raises no
  claim. Hidden on Macs without a battery.
- **Wake the Mac when a block starts** — Newt asks macOS to wake the Mac from
  sleep at the start of the next block. Wake only: a shut-down Mac stays off.
- **Even when on battery** — without it, no wake is armed while unplugged.
  Indented, disabled unless the wake box is on, disabled while the schedule is
  paused on battery (it would wake only to sleep again), hidden on Macs without
  a battery.

### Pausing on battery

A schedule paused on battery is no claim at all, not a veto — "the schedule
can't be true on battery". One guard in `scheduleClaimEnd`:

```swift
var scheduleClaimEnd: Date? {
    guard scheduleEnabled, !(pauseScheduleOnBattery && isOnBattery) else { return nil }
    return schedule.blockEnd(covering: Date())
}
```

Everything downstream follows from that property, so nothing else needs to
know:

- `hasAnyClaim` goes false, so the Hide-icon countdown can start — correct,
  nothing is claiming.
- `updateBatteryMonitor()` already polls whenever the schedule is enabled and
  non-empty, and `battery.onPowerChange` already reconciles, so plugging in
  restores the claim at once.
- `setSuppressed` and `performLeftClickToggle` read `scheduleClaimEnd`, so they
  see "no block in progress" while paused, which is what they should see.
- `scheduleSummary()` gets one new branch, after the suppressed check:
  `"paused on battery"`.

This also closes the one hole in battery-gated waking: a Mac that went to sleep
plugged in and was unplugged while asleep still wakes at block start, but with
the pause on, nothing claims, and it idles back to sleep.

### Waking

**Helper.** One new XPC method on the existing `HelperProtocol` — same daemon,
same registration:

```swift
/// Replace Newt's scheduled wake with one at `date`, or clear it when nil.
/// Only ever one is pending; events from other owners are never touched.
func setScheduledWake(_ date: Date?, reply: @escaping (Bool, String?) -> Void)
```

Implemented with the IOKit power API, not the `pmset` CLI:

- Clear: `IOPMCopyScheduledPowerEvents()`, and
  `IOPMCancelScheduledPowerEvent` every `kIOPMAutoWake` entry whose
  `kIOPMPowerEventAppNameKey` is `HelperConstants.appIdentifier`.
- Set: clear, then `IOPMSchedulePowerEvent(date, appIdentifier, kIOPMAutoWake)`.
- `connectionDropped()` also clears — the same crash-safety as `disablesleep`:
  an app that died can't hold the Mac awake after the wake, so the wake is
  pointless. That also makes "cancel on quit" automatic.
- Bump `HelperConstants.version` to `1.3`, so `verifyHelperVersion` re-registers
  a stale helper on upgrade. Both binaries ship together, as the protocol rule
  requires.

**App.** `reconcile()` calls a new `syncScheduledWake()` alongside
`scheduleBoundaryTimer()`. It calls the helper only when the target differs
from `heldWake`, the wake the helper is believed to hold:

- `heldWake` is recorded when *sent*, not when confirmed. Every helper call
  goes through `ensureRegistered()`, which can open System Settings, so a
  failing helper must not be retried on every battery poll — only when the
  target next changes.
- `HelperClient.onDisconnect` resets `heldWake` and reconciles, so a respawned
  helper (which cleared the wake on drop) is re-armed straight away. Only after
  the helper *confirmed* the wake: a helper that never answers would otherwise
  reconnect in a loop.
- Nothing is sent at launch while the wake is off. A leftover wake can only
  come from a helper that died without its disconnect running, and the next
  arm clears it anyway — not worth a helper call (and a possible System
  Settings prompt) for every user on every launch.

`shutdown()` sends `setScheduledWake(nil)` explicitly, belt and braces over the
connection-drop clear.

**Target.** The next block start, or nil (= clear), from these rules in order:

| Condition | Target |
|:----------|:-------|
| Schedule off, wake box off, or no blocks | nil |
| Suppressed indefinitely | nil |
| Suppressed until *T* | first block start at or after *T* |
| Otherwise | `schedule.nextStart(after: now)` |
| …and on battery, unless *Even when on battery* is on, the schedule isn't paused on battery, and `blockedByBattery == nil` | nil |

A Mac with no battery counts as on AC. The target is re-evaluated on every
reconcile, so plug/unplug, schedule edits, wake, clock and time-zone changes,
block edges and suppression all re-arm it for free.

**Errors.** Helper failures go through `onHelperMessage`, exactly as the
lid-close mode does today. No greyed-out state for a missing helper — the same
treatment lid-close gets.

### Settings and keys

`SettingsWindowController.scheduleView()` gets the three boxes above the grid;
each writes through a `SleepManager` setter that persists and reconciles, same
shape as `setScheduleEnabled`. The grid moves down to make room.

| Key | Type | Absent means |
|:----|:-----|:-------------|
| `PauseScheduleOnBattery` | `Bool` | off |
| `WakeAtScheduleStart` | `Bool` | off |
| `WakeAtScheduleStartOnBattery` | `Bool` | off |

## Documentation

- README ▸ Setting a schedule — the three boxes, in plain language; wake works
  from sleep, not from shut down.
- README ▸ Settings ▸ Schedule line — mention the new boxes.
- README ▸ Use ▸ Use schedule — the *paused on battery* status.
- CLAUDE.md ▸ `HelperService` — it now also schedules wakes, and clears them on
  disconnect. ▸ UserDefaults keys — the three above. ▸ State model — the
  schedule claim is gated on power source when paused.
- CHANGELOG ▸ Unreleased.

## Verification

**Probe first**, before building UI — each is a hypothesis the design leans on:

1. `IOPMSchedulePowerEvent` refuses non-root callers (why it's in the helper).
2. A scheduled wake survives the helper process exiting.
3. A scheduled wake fires with the lid closed and no external display.
4. A scheduled wake fires on battery.

If 3 or 4 fail, the feature still works for the cases that remain; the README
says which.

No test target exists, so the rest is a manual matrix, checked with
`pmset -g sched` and `make helper-status`.

| # | Steps | Expected |
|:--|:------|:---------|
| 1 | Wake off | `pmset -g sched` shows no Newt event |
| 2 | Wake on, on AC, block at +3 min; sleep the Mac | Wakes at block start; schedule holds it |
| 3 | As 2, lid closed | Wakes and holds (pending probe 3) |
| 4 | Wake on, unplugged, *Even on battery* off | No Newt event |
| 5 | As 4; plug in | Event appears |
| 6 | Wake on, *Even on battery* on, unplugged | Event present |
| 7 | As 6; drain below the battery floor | Event cleared |
| 8 | Pause on battery on | *Even on battery* disabled; no event while unplugged |
| 9 | Pause on battery, unplugged, during a block | Menu says *paused on battery*; assertions released |
| 10 | As 9; plug in | Block claim returns at once |
| 11 | Armed; plugged in asleep, unplugged asleep, pause on | Wakes, nothing claims, idles back to sleep |
| 12 | Armed; edit the next block's start | Event moves to the new time |
| 13 | Armed; Suppress until next block | Event still at that block's start |
| 14 | Armed; Suppress indefinitely | Event cleared |
| 15 | Armed; quit Newt | Event cleared |
| 16 | Armed; `kill -9` Newt | Event cleared (helper drop) |
| 17 | Wake off; relaunch | No helper call (Console: no XPC traffic) |
| 18 | Block already running when wake fires | No change; still held |
| 19 | Desktop Mac | Battery boxes hidden; wake arms as on AC |

## Rejected

- **`pmset schedule wake` from the helper.** Matches the existing `pmset`
  call, but clearing our own events means parsing `pmset -g sched` text and
  cancelling by exact date and owner. The IOKit calls list and cancel by owner
  directly.
- **Power on from shutdown.** Unsupported on Apple Silicon laptops (unverified),
  and Newt can't hold anything until someone logs in past FileVault.
- **Detecting "our" wake and sending the Mac back to sleep.** Pause on battery
  covers the same case with a setting that's useful on its own.
- **Arming every block start for the week.** One pending event, re-armed on
  every reconcile, is simpler to clear and can't drift from the schedule.
- **A separate helper.** One daemon, one registration; this is one more method
  on it.
