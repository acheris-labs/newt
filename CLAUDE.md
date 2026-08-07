# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Newt is

Tiny macOS menu bar app (AppKit, Swift, Apple Silicon / macOS 13+) that holds the Mac awake — including lid-closed — for a chosen duration. There is no Xcode project: everything is built with `swiftc` driven by the top-level `Makefile`.

## Build & run

The Makefile is the build system. All commands are run from the repo root.

```
make build         # swiftc → build/Newt.app, ad-hoc signed
make install       # build + copy to /Applications/Newt.app (kills running copy first)
make run           # install + open. Most common dev cycle entrypoint.
make rerun         # kill + run, for fast iteration
make clean         # remove build/
make helper-status # show current pmset SleepDisabled + active IOKit assertions
make reset-sleep   # sudo pmset -a disablesleep 0  (emergency unstick)
```

SMAppService daemons only register from `/Applications`, so dev builds must be installed there — running out of `build/` will leave the helper unregistered. `make run` handles this.

Sparkle 2.9.2 is downloaded once and cached in `build/sparkle/`. The version is pinned in the Makefile (`SPARKLE_VERSION`) and must match the value in `.github/workflows/release.yml` (used to fetch `sign_update`).

Distribution builds (Developer ID signed + notarized + DMG) require Apple Developer Program enrollment — see [DISTRIBUTING.md](DISTRIBUTING.md). Local ad-hoc builds work for everything except the lid-close path, which requires `SMAppService` to register the helper, which requires Developer ID.

## Architecture

Two binaries inside one `.app` bundle, plus a small shared protocol.

**`Newt/`** — the user-facing menu bar app (AppKit, not SwiftUI).
- `main.swift` → `AppDelegate.swift` constructs `StatusItemController` (and the Sparkle updater) on `applicationDidFinishLaunching`.
- `StatusItemController.swift` owns the `NSStatusItem`, the menu, the custom slider views (`DurationSliderView`, `BatterySliderView`), and the left/right click router. Calls into `SleepManager` for all state changes.
- `SleepManager.swift` is the **single source of truth** for keep-awake state. Holds the IOKit `IOPMAssertion` IDs, the slider position, the expiry `Timer`, and the user's per-mechanism `WakeMode` toggles + `LeftClickAction` preference. Surfaces changes back to the controller through `onChange` and `onHelperMessage` callbacks. Anywhere else in the code that "wants to engage" must go through `SleepManager.setSliderPosition(_:)` or `performLeftClickToggle()` — never call assertion APIs directly.
- `HelperClient.swift` registers the daemon via `SMAppService.daemon(plistName:)` and brokers XPC calls (`setDisableSleep`) over an `NSXPCConnection` with identifier-pinned code requirements on both ends.
- `BatteryMonitor.swift` polls `IOPSCopyPowerSourcesInfo` every 15s while engaged; trips disengage when on battery and percent ≤ user-configured threshold.
- `LoginItemController.swift` uses `SMAppService.mainApp` for auto-launch.

**`NewtHelper/`** — the privileged launchd daemon (separate binary in the same bundle).
- `HelperService.swift` runs `/usr/bin/pmset -a disablesleep 0|1` as root. Critical safety property: if the XPC connection from Newt drops while sleep is disabled, the helper restores `disablesleep 0` automatically on disconnect. Never disable that behavior.
- `net.acheris.newt.helper.plist` is the launchd manifest at the bundle root, embedded into `Contents/Library/LaunchDaemons/` by `make build`.

**`Shared/HelperProtocol.swift`** — the XPC interface contract. Any change to the protocol must be released to both binaries in the same version; mismatch would break the connection on upgrade.

### State model worth knowing

- The duration slider has 11 positions: 0=off, 1–9 = 1m…24h (geometric), 10 = indefinite. The table is `SleepManager.sliderDurations`.
- Engaging applies up to 4 mechanisms, each individually toggleable via the **Configuration ▸ Wake modes** submenu: `PreventUserIdleDisplaySleep`, `PreventUserIdleSystemSleep`, `PreventSystemSleep` (IOKit assertions, no helper needed), and `pmset disablesleep` (helper-only, lid-close case). Defaults to all four on.
- `SleepManager.engage()` is idempotent w.r.t. assertions — flipping a `WakeMode` toggle while engaged adds/drops just that assertion without bouncing the session.

### UserDefaults keys (all in standard defaults)

`BatteryThresholdPercent`, `WakeMode.<rawValue>` (one per case), `LeftClickAction`, `LastUsedSliderPosition`, `FixedClickSliderPosition`. All have sensible defaults for fresh installs — never add a migration that breaks an upgrade.

## Release flow

1. Bump entry in `CHANGELOG.md`: rename `## [Unreleased]` to `## [x.y.z] - YYYY-MM-DD`, add a fresh empty `[Unreleased]` block, and add a compare-link in the footer.
2. Commit, tag `vX.Y.Z`, push tag.
3. `.github/workflows/release.yml` runs on `push: tags: ['v*']` — stamps `Info.plist`, builds, notarizes, ed25519-signs the DMG for Sparkle, creates the GitHub release using the matching CHANGELOG section as `--notes-file` (falls back to `--generate-notes` if absent), and regenerates `appcast.xml` on the `gh-pages` branch.
4. Sparkle clients pick up the new version on their next scheduled check (~24h) or manual "Check for Updates…".

Existing installs poll `https://acheris-labs.github.io/newt/appcast.xml`. Don't rename or relocate that URL — it's compiled into shipped binaries.

## Documentation split

`README.md` is **for people who use Newt, not people who work on it.** It
covers installing, what the menu does, the `newt://` scheme, and recovering
when something goes wrong. Assume the reader downloaded a `.dmg` and has no
source checkout.

Keep out of the README:
- Source file names, type names, and code references.
- API names (`SMAppService`, IOKit assertion constants, `UNUserNotificationCenter`, XPC).
- `make` targets — a `.dmg` user has no Makefile, so troubleshooting steps must
  be real commands (`sudo pmset -a disablesleep 0`), never `make reset-sleep`.
- Build instructions, architecture notes, release process.
- Version archaeology ("fixed in 0.1.2") once the version is a few releases old.

Developer material belongs here (build, architecture, release flow) or in
[DISTRIBUTING.md](DISTRIBUTING.md) (signing, notarization). When a feature adds
a user-visible control, update the README's **Use** section in the same change,
in the same plain-language register — name the menu item, say what it does for
the user, and skip how it's implemented.

## Conventions

- The Wake modes / `LeftClickAction` enums in `SleepManager.swift` are the canonical place for any new toggleable setting. Both have a `menuTitle` property used by the controller — keep the case names short and the titles user-facing.
- `DurationSliderView` is reusable: pass a `title:` parameter (e.g. "Keep awake", "On for") and the appropriate `onChange`. Slider commits on mouse-up; if you add another instance, remember that abandoned drags (mouse leaves menu) need a `menuDidClose` commit — see the existing pattern in `StatusItemController.menuDidClose`.
- **Comments are the exception, not the habit.** The bar: would a developer with 5+ years' experience be stuck without it? If not, delete it — clear names and small functions carry the meaning. Never restate what the code plainly does.
  - Worth a comment: a platform quirk or API constraint you can't see locally, an invariant enforced somewhere else, a non-obvious ordering requirement, or a bug the line exists to prevent from returning.
  - Not worth a comment: paraphrasing the next line, narrating an obvious guard, or explaining a well-known API.
  - Keep them to a line or two. Needing a paragraph usually means the code should be restructured or given a better name.
- **Doc comments (`///`) on a type or function describe intent, not mechanics** — what it is for, what it guarantees, and what a caller has to know (side effects, preconditions, what a return value means). Leave the *how* to the body: an implementation walkthrough duplicates the code and goes stale the first time it changes.
  - Good: "Single source of truth for keep-awake state." / "Returns nil when engaging is allowed, otherwise a user-facing refusal."
  - Bad: "Loops over the enabled modes and calls `applyAssertion` for each."
  - A declaration that needs its mechanics explained to be usable is usually doing too much — split it.
- Swift imports stay at file top; no per-function imports.
