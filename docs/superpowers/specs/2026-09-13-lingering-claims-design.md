# Lingering claims

## Problem

Newt holds the Mac awake while an AI agent works — a *dynamic claim*, raised
over `newt://claim` by the agent's hooks and released at the end of the turn.
Between turns, while you read the diff and type the next prompt, nothing claims,
so the Mac is free to sleep. The only cover today is the Keep awake slider (a
manual guess at how long you'll be there) or the weekly schedule (calendar
hours, which don't know whether you're actually at the desk).

A lingering claim outlives the agent by a configurable spell and is re-armed
every time a turn ends. Work through the day and the Mac stays awake all day,
with no schedule and no slider. Walk away and the last linger lapses.

## Design

A fourth claim alongside the slider, the schedule and dynamic claims. It is one
`Date` on `SleepManager`, and it behaves like every other claim: `reconcile()`
decides, the vetoes still veto, nothing else touches assertions.

```swift
/// When the lingering claim lapses, or nil when none is held.
private(set) var lingerUntil: Date?
```

**Armed by any dynamic release**, in the `dynamicClaims.onChange` handler
`SleepManager` already owns:

```swift
dynamicClaims.onChange = { [weak self] in
    guard let self else { return }
    if self.dynamicClaims.isEmpty, !self.isSuppressed, let secs = self.lingerSeconds {
        self.lingerUntil = Date().addingTimeInterval(secs)
    }
    self.reconcile()
}
```

Three properties that follow, and are the agreed semantics:

- **It replaces, it does not accumulate.** Re-arming overwrites the end date
  with `now + duration`. A 1h linger with an agent turn ending 55 minutes in
  runs to 1h55m from the start, not 2h.
- **Only dynamic releases arm it.** A Keep awake slider session expiring, or a
  schedule block ending, arms nothing — the linger merely outlives them.
- **A revoke arms it too.** "Release all dynamic claims" is a claim finishing
  like any other; the Claims row is right there to let it go.

It is in-memory only, like `dynamicClaims` — a restart drops it, which fails
safe, and a live agent re-arms it on its next turn.

### Wiring

- `lingerClaimEnd: Date?` — `lingerUntil` when still in the future, else nil.
- `hasAnyClaim` gains `|| lingerClaimEnd != nil`. Assertions, the idle-hide
  countdown and the tooltip all fall out of that.
- `scheduleBoundaryTimer()` gains `lingerUntil` as a fire candidate. No new
  timer — this is already the "wake when the answer could change" timer, and it
  works only because `lingerUntil` is a *stored absolute* `Date`; recomputing it
  as `now + duration` would defeat the `fireDate == target` guard that stops it
  re-arming on every battery poll.
- `updateBatteryMonitor()`'s `claimPossible` gains `lingerClaimEnd != nil`, so
  the battery keeps being polled while a linger is the only claim.
- `reconcile()` gets `clearExpiredLinger()` beside `clearExpiredSuppression()`.
- `awakeReasons()` gains `"Lingering — 12m left, until 20:46"`.
- `releaseLinger()` — `lingerUntil = nil; reconcile()`.

### The traps

Each is one line, and each is why this isn't quite a five-minute change:

1. **`lingerUntil` is set *before* `reconcile()`, in the same handler.** Setting
   it after means every turn boundary releases the assertions and immediately
   re-acquires them — two privileged XPC round-trips per turn, with a window
   where `pmset disablesleep` is 0. Lid-close protection would blink off once
   per agent turn.
2. **`shutdown()` clears it.** It is documented as the only thing that releases
   unconditionally.
3. **No "indefinite" stop**, and clamp to `sliderDurations.count - 2`. Position
   15's value is `-1`, which `lingerSeconds` reads as "no duration" — so a
   hand-written `LingerPosition` of 15 would look set and do nothing. An
   indefinite linger would also mean the Mac never sleeps again after the first
   agent turn.
4. **Setting the slider to 0 calls `releaseLinger()`**, not just
   `lingerUntil = nil` — copying `hideIconAfterPosition`'s `didSet`, which only
   calls `onChange?()`, would clear the field but leave the assertions up.
5. **The Claims row goes before `guard !dynamic.isEmpty`** in `refreshClaims()`.
   A linger is shown only when no agent claim is up, so a row added after that
   guard is dead code in the one state it can occur in.
6. **`performLeftClickToggle()` releases it** in its `isActive` branch, or
   clicking a lit icon does nothing visible.

### Setting

A "Linger" duration slider in Settings ▸ General, between "Claim limit" and
"Hide icon". `lingerPosition: Int`, default 0, persisted as `LingerPosition` —
absent means 0 means off, so an upgrade changes nothing. It must be added to
`SettingsWindowController.refresh()` with the other sliders or it will visibly
desync; that method runs at 1 Hz while the menu is open.

`DurationSliderView` gains `maxPosition:`, defaulting to today's value. Note
`maxValue` and `numberOfTickMarks` are *different* expressions — `count - 1` and
`count` — so the parameter must set `maxPosition` and `maxPosition + 1`
respectively, or the thumb snaps to positions the caller never asked for.

### Badge

A linger badges blue only when it is the sole claim:

```swift
let dynamic = !sleep.dynamicClaims.isEmpty
    || (sleep.lingerClaimEnd != nil && !scheduled)
```

Letting it contribute to `.both` would start the repeating spin timer for the
linger's whole duration. That change also requires dropping the two
cache-clearing lines from `updateBadgeSpin`'s `guard spinning else` block:
otherwise the badge flipping at each turn boundary destroys the frame cache and
re-renders all 36 frames, once per turn. The key check already handles staleness.

## Documentation

- README ▸ Use — the new Claims row.
- README ▸ Settings — the Linger slider.
- README ▸ Keeping the Mac awake while an AI agent works — a paragraph, plus two
  sentences **rewritten**: "An agent session left sitting idle at the prompt
  holds nothing, so your Mac still sleeps when you walk away" is contradicted by
  this feature, and "a third way"/"all three" become four.
- CLAUDE.md ▸ State model — three claims become four. Also fix the stale "the
  duration slider has 11 positions"; it has had 16 since v0.2.7.
- `SleepManager.swift` header comment — same "three claims" drift.
- CHANGELOG ▸ Unreleased.

## Verification

No test target exists, so this is a manual matrix via `open 'newt://…'` and
`make helper-status`.

| # | Steps | Expected |
|:--|:------|:---------|
| 1 | Linger 0; claim then release | Assertions drop at once — behaviour unchanged |
| 2 | Linger 30m; claim, release | Blue dot, "Lingering — 30m left", assertions held |
| 3 | As 2, wait it out | Released; Hide-icon countdown starts then |
| 4 | Claim A + B; release both | One linger, armed from the second release |
| 5 | Linger running; agent claims and releases again | End date replaced, measured from the new release |
| 6 | Linger running; release it from Claims | Assertions drop at once |
| 7 | Linger running; left-click icon in toggle mode | Assertions drop at once |
| 8 | Suppress on; claim; release | No linger armed |
| 9 | Linger armed; then Suppress | Assertions drop; it expires silently during suppression |
| 10 | Battery below floor; claim; release | Linger armed but vetoed; no assertions |
| 11 | Linger armed; set slider to 0 | Cleared **and** assertions drop |
| 12 | Linger + Keep awake slider together | Green dot, no spin timer |
| 13 | Linger running; quit and relaunch | No linger — fails safe |
| 14 | Linger running; sleep the Mac, wake past the end | Reconcile on wake releases cleanly |
| 15 | Turn boundary with lid-close on | `SleepDisabled 1` continuously — no blink (trap 1) |

## Rejected

- **A synthetic `DynamicClaim` in the registry.** Inherits the badge, Claims row
  and battery term for free, but collides with `maxLifetime` (which would expire
  the linger on the agent's ladder) and makes the arming logic ignore one of its
  own entries. The separate `Date` is simpler.
- **Cause-aware arming** (`ReleaseCause`, an `onProcessExited` callback, and a
  clear at every non-agent removal path) so that revokes and process deaths
  don't arm. Rejected as over-built for a two-click annoyance, against a
  decision already made twice.
