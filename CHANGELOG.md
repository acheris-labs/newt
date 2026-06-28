# Changelog

All notable changes to Newt are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The CI release workflow extracts the matching `## [x.y.z]` section as the
GitHub release body and as the link target for Sparkle's release notes,
so write each entry as if it were the changelog the user reads in the
auto-update prompt.

## [Unreleased]

## [0.3.1] - 2026-06-28

### Added
- **"Pause on battery" for "Keep display on".** A new checkbox under that wake
  mode (on Macs with a battery, shown while the mode is enabled) lets the
  display idle-off whenever you're running on battery, then resume holding it
  on the moment you plug back in. Off by default, so nothing changes unless you
  turn it on — and it gates only the display; the other wake modes keep the
  system awake regardless.

### Fixed
- **Menu bar icon no longer disappears for good after sleep.** macOS can reap
  Newt's status item on wake and never restore it — the app keeps running and
  holding the Mac awake, but the icon vanishes with no way to reach the menu.
  Newt now detects this on wake and recreates the icon, leaving the current
  keep-awake session untouched.

## [0.3.0] - 2026-06-17

### Added
- **Time-of-day window for "Keep display on".** A dual slider under that wake
  mode (shown only while it's enabled) sets the hours the display is held on,
  in half-hour steps; the default is all day, so nothing changes unless you
  narrow it. Outside the window the display is free to idle-off while the other
  wake modes keep the system awake.

### Security
- **The app⇄helper connection logs an unexpected auth downgrade instead of
  taking it silently.** If either side can't read its own code signature
  (and so can't enforce the Team-ID-pinned requirement), it now logs the
  fallback to identifier-only validation. Normal ad-hoc dev builds are
  unaffected and stay quiet.
- **Hardened the helper's `pmset` call against a pipe-buffer deadlock.** The
  root daemon now drains the command's error output before waiting for it to
  exit, so a full output buffer can't hang the helper.

## [0.2.9] - 2026-06-09

### Added
- **About Newt** menu item (above Quit) opens the standard macOS About
  panel — app icon, version, copyright, and an MIT-license / no-warranty
  note — so you can tell at a glance which version you're running.

## [0.2.8] - 2026-06-09

### Security
- **Hardened the XPC peer validation between the app and the privileged
  helper.** The connection requirement is now derived from the running
  binary's own signature: signed builds pin the Apple anchor, bundle
  identifier, and Team ID, so only the genuine, team-signed peer is
  accepted in either direction. Ad-hoc local builds fall back to the prior
  identifier-only match, so development is unaffected.

### Changed
- **The release DMG is now signed, notarized, and stapled itself** (in
  addition to the app inside it). A DMG downloaded directly from the
  GitHub release now passes Gatekeeper on mount without a prompt.

## [0.2.7] - 2026-06-02

### Changed
- **Duration slider is now a 16-stop, mostly-linear 2-hour ladder.** The
  old 11-stop geometric ladder (`1m, 15m, 30m, 1h, 2h, 4h, 8h, 16h, 24h`)
  made it impossible to pick anything between, say, 4h and 8h. The new
  ladder is `off, 30m, 1h, 2h, 4h, 6h, 8h, 10h, 12h, 14h, 16h, 18h, 20h,
  22h, 24h, indefinite` — short-nap durations stay accessible at the left
  end, then uniform 2-hour steps to 24h. Tick spacing on the existing
  slider width is comfortable, and the v0.2.6 live preview makes landing
  on any specific tick easy.

### Migrated
- **Existing `LastUsedSliderPosition` / `FixedClickSliderPosition` are
  remapped on first launch.** Stored positions point at integers in the
  table, so a raw upgrade would silently shift their meaning (old
  position 6 = 4h would become 8h in the new table). On first launch
  Newt now reads the old positions, looks them up in the legacy table to
  recover the intended seconds, and writes back the corresponding new
  position. Legacy 1m / 15m collapse to the new 30m minimum; every
  other legacy stop maps exactly. Gated by a `SliderTableVersion`
  UserDefaults key so the migration runs at most once per machine.

## [0.2.6] - 2026-05-29

### Changed
- **Duration sliders preview the value live while dragging.** The
  "Keep awake" and "On for" sliders have geometric stops (`off`, `1m`,
  `15m`, `30m`, `1h`, `2h`, `4h`, `8h`, `16h`, `24h`, `indefinite`), so
  the position under the thumb mid-drag didn't tell you which value
  you were about to land on — the label only updated once you released.
  Now the value label updates as you cross each tick, showing what the
  position represents. The expensive commit path (helper XPC,
  IOPMAssertions, `pmset`) still runs exactly once per drag, on
  mouse-up — dragging across positions does not churn assertions.

## [0.2.5] - 2026-05-26

### Fixed
- **Hover tooltip from v0.2.4 didn't actually appear.** The tooltip
  rectangle was registered before the menu bar icon was set, so
  `button.bounds` was `.zero` and the mouse never landed inside the
  registered hit region. Registration now happens after the first
  refresh, when the icon (and therefore the button's bounds) is in
  place.

## [0.2.4] - 2026-05-26

### Added
- **Hover tooltip showing remaining time.** While keep-awake is engaged,
  hovering the menu bar icon now reveals the current remaining time
  (`1h 23m`, `45m 12s`, or `indefinite`) without having to open the
  menu. The tooltip is computed at hover time, so it always reflects
  the live remaining duration. When keep-awake is off, no tooltip
  appears.

## [0.2.3] - 2026-05-25

### Fixed
- **"Helper connection error: Couldn't communicate with a helper
  application."** after a Sparkle auto-update. `launchd` keeps the
  privileged helper daemon alive across app-bundle replacement, so the
  newly-installed app would end up talking to a helper process whose
  backing binary had been swapped underneath it; subsequent XPC code-
  signature validation against that stale process fails with
  `NSXPCConnectionInvalid`. Newt now performs a version handshake with
  the helper at launch and, on mismatch or any XPC error, bounces the
  daemon via `SMAppService` unregister+register so it respawns from the
  current on-disk binary. Recovery is silent — users no longer see the
  error message.

## [0.2.2] - 2026-05-24

### Added
- **Configurable left-click action.** Right-click (and Control-click) on
  the menu bar icon always opens the menu; left-click is now a setting:
  - *Open menu* (default — preserves prior behavior)
  - *Toggle last duration* — re-engages keep-awake at the most recently
    used slider position, or disengages if active. The remembered
    duration is shown in the menu item title, e.g. `Toggle last
    duration (4h)`.
  - *Toggle on for fixed duration* — engages at a user-configured
    duration set by a second slider in the menu, or disengages if
    active.
- Top-level menu reorganized: the former *Wake modes* submenu is now
  **Configuration**, containing two grouped sections (*Wake modes* and
  *Left click action*).

### Changed
- `DurationSliderView` is now reusable with a custom title; the existing
  "Keep awake" slider is unchanged.

### Persistence
- New `UserDefaults` keys: `LeftClickAction`, `LastUsedSliderPosition`,
  `FixedClickSliderPosition`. All default to safe values — existing
  installs see no behavior change until the user opts in.

## [0.2.1] - 2026-05-24

### Added
- **Per-mechanism Wake modes submenu.** Choose individually which
  keep-awake mechanisms apply:
  - *Keep display on* (`PreventUserIdleDisplaySleep`)
  - *Keep system awake when idle* (`PreventUserIdleSystemSleep`)
  - *Prevent system sleep* (`PreventSystemSleep`, AC only)
  - *Stay awake with lid closed* (helper-driven `pmset disablesleep`)
  
  Toggles persist and apply live while keep-awake is engaged — flipping
  a toggle adds or drops just that assertion without bouncing the
  session. Defaults to all-on to preserve prior behavior.

### Fixed
- **Duration slider no longer snaps back when a drag exits the menu.**
  The slider is configured to commit on mouse-up so dragging across
  ticks doesn't churn IOKit assertions; previously, if the menu closed
  before mouse-up the commit was lost. The slider's last visible
  position is now captured on menu close.

## [0.2.0] - 2026-05-23

### Added
- **Sparkle auto-update.** Newt now checks for new releases on a
  schedule and offers in-app updates. The appcast lives at
  `https://acheris-labs.github.io/newt/appcast.xml`; release builds are
  Developer-ID signed, notarized, and ed25519-signed for Sparkle.
- `Check for Updates…` and `Check Automatically` menu items.

## [0.1.3] - 2026-05-23

### Changed
- After approving the privileged helper in System Settings, Newt now
  tells the user to relaunch — the existing app process can't observe
  the approval and continued to show "Helper not found" otherwise.
- README: tightened "Helper not found" troubleshooting.

## [0.1.2] - 2026-05-23

### Fixed
- **"Helper not found" on fresh install.** On first launch the helper
  registration could land in `.notFound` state without prompting; Newt
  now calls `register()` from that state too, surfacing the System
  Settings approval prompt as intended.
- README documents the macOS quarantine flag (`com.apple.quarantine`)
  as a cause of the same error and the `xattr -dr` workaround.

## [0.1.1] - 2026-05-23

### Added
- Application icon: green squircle with the lizard SF Symbol (rendered
  via `tools/gen-icon.swift`).

### Changed
- Trimmed unused references from the README.

## [0.1.0] - 2026-05-23

Initial public release.

### Added
- Menu bar app that holds the four sleep-prevention mechanisms while
  engaged:
  - `PreventUserIdleDisplaySleep`
  - `PreventUserIdleSystemSleep`
  - `PreventSystemSleep`
  - `pmset -a disablesleep 1` via a privileged helper
- **Duration slider** with 11 stops: off, 1m, 15m, 30m, 1h, 2h, 4h, 8h,
  16h, 24h, indefinite. Snap-to-tick, commits on release.
- **Low battery cutoff slider** (0–30%). Newt automatically releases
  keep-awake when battery drops to the configured threshold and is on
  battery power; the duration slider is also disabled below the floor.
- **Open at Login** toggle (`SMAppService`).
- Privileged helper for `pmset disablesleep`, registered via
  `SMAppService.daemon(plistName:)`.
- Lizard menu bar icon (filled when engaged, outline when idle).

[Unreleased]: https://github.com/acheris-labs/newt/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/acheris-labs/newt/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/acheris-labs/newt/compare/v0.2.9...v0.3.0
[0.2.9]: https://github.com/acheris-labs/newt/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/acheris-labs/newt/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/acheris-labs/newt/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/acheris-labs/newt/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/acheris-labs/newt/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/acheris-labs/newt/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/acheris-labs/newt/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/acheris-labs/newt/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/acheris-labs/newt/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/acheris-labs/newt/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/acheris-labs/newt/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/acheris-labs/newt/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/acheris-labs/newt/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/acheris-labs/newt/releases/tag/v0.1.0
