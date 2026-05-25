# Changelog

All notable changes to Newt are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The CI release workflow extracts the matching `## [x.y.z]` section as the
GitHub release body and as the link target for Sparkle's release notes,
so write each entry as if it were the changelog the user reads in the
auto-update prompt.

## [Unreleased]

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

[Unreleased]: https://github.com/acheris-labs/newt/compare/v0.2.3...HEAD
[0.2.3]: https://github.com/acheris-labs/newt/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/acheris-labs/newt/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/acheris-labs/newt/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/acheris-labs/newt/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/acheris-labs/newt/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/acheris-labs/newt/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/acheris-labs/newt/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/acheris-labs/newt/releases/tag/v0.1.0
