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
- `Schedule.swift` is the weekly-schedule model: `ScheduleBlock` / `WeeklySchedule`, the coverage and boundary date maths, and JSON persistence. Pure logic, no AppKit — keep it that way, it's the part worth testing standalone.
- `IntegrationInstaller.swift` installs Newt into an AI agent, by one of two `Method`s. Both identify our own entries by the `newt://claim?` marker and touch nothing else.
  - `.jsonHooks` (Claude Code) merges into `~/.claude/settings.json`, which other tools also write to: back up first, add only our entries, never rewrite a key we didn't add. The hooks are self-contained shell one-liners — `sed` pulls `session_id` off stdin, and `$PPID` **is** the agent process (a `command` hook runs as its direct child), which is where the pid to watch and the tty to label with come from. No jq/python dependency.
  - `.pluginFile` (opencode) writes `Newt/Resources/newt-opencode.js` to `~/.config/opencode/plugin/`, a file Newt owns outright — so no merge, no backup, and uninstall is a delete. It refuses to overwrite or delete a file at that path without our marker. opencode has **no** hook that fires when a turn starts (its only shell hooks are `experimental.hook.file_edited` and `session_completed`), so a plugin is the sole way to raise a claim; it globs `{plugin,plugins}/*.{ts,js}` in its config dirs at startup, and `opencode.json` is never read. A path-loaded plugin **must** export `id` as well as `server` or it fails to load — the published types mark `id` optional because npm plugins take theirs from `package.json`, and the failure is only a log line. The plugin claims on `session.status` → `busy` and releases on `idle`; `retry` holds, since that's a stalled request still working. `refreshInstalledPlugins()` rewrites a stale plugin at launch, since a Newt upgrade otherwise leaves the old file in place.
- `SettingsWindowController.swift` is the app's only `NSWindow`: an `NSTabView` of General / Wake Modes / Icon / Schedule / Left Click / Integrations. Every control writes straight through to `SleepManager` on change — no OK or Apply. `SPUUpdaterProviding` is a one-property protocol so this file doesn't import Sparkle and can be exercised in a harness with a stub.
- `ScheduleGridView.swift` is the custom weekly grid (drag to add/move/resize, overnight wrap). It's hosted by the Schedule tab, but knows nothing about it — it just reports a `WeeklySchedule` through `onChange`.
- `HelperClient.swift` registers the daemon via `SMAppService.daemon(plistName:)` and brokers XPC calls (`setDisableSleep`) over an `NSXPCConnection` with identifier-pinned code requirements on both ends.
- `BatteryMonitor.swift` polls `IOPSCopyPowerSourcesInfo` every 15s while engaged; trips disengage when on battery and percent ≤ user-configured threshold.
- `LoginItemController.swift` uses `SMAppService.mainApp` for auto-launch.

**`NewtHelper/`** — the privileged launchd daemon (separate binary in the same bundle).
- `HelperService.swift` runs `/usr/bin/pmset -a disablesleep 0|1` as root. Critical safety property: if the XPC connection from Newt drops while sleep is disabled, the helper restores `disablesleep 0` automatically on disconnect. Never disable that behavior.
- `net.acheris.newt.helper.plist` is the launchd manifest at the bundle root, embedded into `Contents/Library/LaunchDaemons/` by `make build`.

**`Shared/HelperProtocol.swift`** — the XPC interface contract. Any change to the protocol must be released to both binaries in the same version; mismatch would break the connection on upgrade.

### State model worth knowing

**Claims and vetoes.** Three claims can ask for the Mac to stay awake — the
duration slider (`state: AwakeState`), the weekly schedule, and *dynamic claims*
raised over `newt://claim` (`dynamicClaims`, typically an AI agent's hooks) — and
two vetoes can refuse — the low battery floor (`blockedByBattery`) and manual
suppression (`suppressedUntil`). Assertions apply when at least one claim is up
and neither veto is. `SleepManager.reconcile()` is the **only** function that applies or
releases anything; `engage`/`disengage`/`setSchedule`/`setSuppressed` all just
change state and call it. Consequences worth remembering:

- `isActive` means "assertions are applied right now", not "the slider is set".
  Use `hasSliderClaim` for the latter.
- `disengage()` drops only the *slider* claim. It is not a global off switch —
  `shutdown()` is, and it's the only thing that releases unconditionally.
- A veto never destroys a claim. When the battery recovers, the session resumes
  with whatever time is left on its absolute end date. So `BatteryMonitor` has
  to keep polling whenever a claim exists, not only while engaged.
- `canEngage()` still *refuses* an explicit user request under a veto (snapping
  the slider back to 0 with a message). Mid-session vetoes only pause. That
  asymmetry is deliberate: a click deserves an answer.

Dynamic claims are held only for the duration of an agent's turn and live in
memory only — a Newt restart drops them, which fails safe, and the agent
re-claims next turn.
Each one with a resolved pid gets a `DispatchSourceProcess` exit watcher, since
an agent that is killed never runs its release hook (`SessionEnd` is explicitly
not guaranteed to fire). Neither helps when the agent is alive but never
releases — a subagent, or waiting on the user — so `DynamicClaimRegistry
.maxLifetime` (Settings ▸ General, `DynamicClaimMaxPosition`) is a fifth net
that lets go after a set time. It's armed off the claim's `since`, so
re-raising the same id doesn't buy more time; that's what makes it a maximum
rather than an idle timeout.

**Hiding the icon.** `StatusItemController` runs an idle countdown
(`updateIdleHide()`, `HideIconAfterPosition`) that takes the status item out of
the menu bar once `hasAnyClaim` has been false for the configured spell. A veto
doesn't start it — a refused claim is still a claim, and that's when the tooltip
saying why is worth reading. `hiddenByIdle` has to be checked in
`restoreStatusItemIfNeeded()`: a hidden item and one macOS reaped both have a
button with no window, so without the guard the next wake drags the icon back
out. Getting it back is `revealStatusItem()`, which is already wired to
re-opening the app.

**Drawing the icon.** `StatusItemController.statusImage` is the only renderer.
It picks one `IconLook` — `active ? style.awake : style.idle` — and every
decision follows from it, so the two states can't drift apart. A *template*
image (which AppKit auto-tints) survives only when nothing needs colour: no
badge, no chosen glyph colour, no backdrop. A nil colour in an `IconLook` means
"work it out" and is resolved **inside the drawing block**, where it picks up
the menu bar's own appearance — which is why the automatic backdrop inverts
between light and dark, and why it follows the *menu bar*, not the system
setting (a dark wallpaper keeps the bar dark in Light Mode). `.circle` uses SF
Symbols' `lizard.circle.fill`, whose artwork is a disc with the lizard as a
*hole*: `paletteColors` fills that hole to give a solid lizard, and a flat tint
leaves it open, which is exactly what `IconLook.cutsOut` wants. `cutsOut` is
gated on `.circle` because it's the only backdrop opaque enough to cut out of. A backdrop enlarges the canvas,
so the claim and caution badges size themselves from the *glyph* height, not
`rect.height`, or they'd inflate with it.

The schedule's `boundaryTimer` is a one-shot armed at the next edge, not a
poll. Wall-clock jumps it can't see — sleep/wake, clock set, time zone — are
covered by three notification observers that just call `reconcile()`.

- The duration slider has 11 positions: 0=off, 1–9 = 1m…24h (geometric), 10 = indefinite. The table is `SleepManager.sliderDurations`.
- Engaging applies up to 4 mechanisms, each individually toggleable in **Settings ▸ Wake Modes**: `PreventUserIdleDisplaySleep`, `PreventUserIdleSystemSleep`, `PreventSystemSleep` (IOKit assertions, no helper needed), and `pmset disablesleep` (helper-only, lid-close case). Defaults to all four on.
- `SleepManager.engage()` is idempotent w.r.t. assertions — flipping a `WakeMode` toggle while engaged adds/drops just that assertion without bouncing the session.

### UserDefaults keys (all in standard defaults)

`BatteryThresholdPercent`, `WakeMode.<rawValue>` (one per case), `LeftClickAction`, `LastUsedSliderPosition`, `FixedClickSliderPosition`, `ScheduleEnabled`, `ScheduleBlocks` (JSON `Data`), `SuppressedUntil` (`Double`, absent = not suppressed), `BadgeSizeScale` (`Double`), `BadgeOutline` (`Bool`), `BadgeSpin` (`Bool`), `HideIconAfterPosition` (`Int`, **absent = the top stop, i.e. never hide**), `IconBackdropIdle` / `IconBackdropAwake` (`String`, an `IconBackdrop` rawValue, **absent = `.none`**), `IconCutoutIdle` / `IconCutoutAwake` (`Bool`), `BadgeColorScheduled` / `BadgeColorDynamic` / `IconColorGlyphIdle` / `IconColorAwake` / `IconColorBackdropIdle` / `IconColorBackdropAwake` (`[Double]` sRGB components; **absent means "use the system colour"**, which keeps the default dynamic across light/dark — don't write the system colour's components into them). All have sensible defaults for fresh installs — never add a migration that breaks an upgrade.

AppKit also persists the status item's visibility itself, as `NSStatusItem
VisibleCC NewtStatusItem`. Newt never writes that key — `configureStatusItem()`
forces `isVisible = true` at launch so an icon hidden by the idle timeout can't
come back hidden, which would strip the only recovery path.

Two things to know when writing these by hand. `defaults write … -float` is **single precision**, which rounds a seconds-since-2001 timestamp to the nearest ~26 s — write `SuppressedUntil` with `-date` or from code, or you'll chase a timer bug that isn't there. And `defaults write … -array 1.0 0.45 0 1` stores **strings**, which `array(forKey:) as? [Double]` reads back as nil, so a colour set that way silently does nothing; set the colour wells from the UI or write the key from code.

## Distribution

Two channels, and they must not fight:

- **Homebrew installs**, via the `newt` cask in `acheris-labs/homebrew-tools`.
  `packaging/newt-cask.rb.tmpl` is the source of truth; the release workflow's
  `brew` job renders it with `envsubst` (`VERSION`, `SHA_DMG` from the DMG's
  `.sha256` sidecar) and pushes it to the tap over SSH, using the
  `HOMEBREW_TAP_SSH_KEY` deploy key. A missing key warns rather than fails.
- **Sparkle updates.** The cask carries `auto_updates true`, which is what stops
  `brew upgrade` reinstalling over a copy Sparkle has already moved past.

Two things in the cask are load-bearing:

- `uninstall quit:` — the helper only restores `pmset disablesleep 0` when the
  running app's XPC connection drops, so quitting is what stops an uninstall
  leaving a Mac that won't sleep. There is no `launchctl` stanza because the
  daemon is registered from inside the bundle by `SMAppService`, not from
  `/Library/LaunchDaemons`.
- `uninstall_preflight` runs `Newt --uninstall-integrations`, which unwinds the
  hooks and plugin files Newt wrote into *other* tools' config while the bundle
  still exists. It is guarded on `File.executable?` and `must_succeed: false`:
  a failing preflight aborts the entire uninstall, which would leave an app that
  can't be removed — worse than leftover hooks. That flag is handled in
  `main.swift` before `NSApplication` starts, and is not a CLI: nothing is
  symlinked onto PATH.

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

Settings live in one of two places, and the split is deliberate: the **menu**
keeps what's worth changing on the spot (the Keep awake slider, the schedule
switch, Suppress, Claims), and the **Settings window** takes what you set once —
the battery floor, wake modes, icon appearance, schedule hours, left-click
action and integrations. Both read through `SleepManager` and are redrawn by
`StatusItemController.refresh()` — a view must never read or write UserDefaults
directly, or the two surfaces drift.

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
