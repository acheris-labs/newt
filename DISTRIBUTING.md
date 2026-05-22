# Distributing Newt

Newt's privileged helper is an `SMAppService` daemon. macOS will **only**
register such a daemon when the app is signed with a **Developer ID
Application** certificate — ad-hoc and self-signed builds fail with status
`.notFound`. So a distributable Newt requires Apple Developer Program
membership ($99/yr). Until then, `make build` still produces a locally
runnable, ad-hoc-signed app (idle-sleep prevention works; lid-close does not).

## One-time setup

1. **Enroll** in the Apple Developer Program (Individual is fine):
   <https://developer.apple.com/programs/> — $99/yr.
2. **Create a Developer ID Application certificate.** Easiest via
   Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ ＋ ▸
   *Developer ID Application*. It lands in your login keychain.
3. **Confirm the identity:**
   ```
   security find-identity -v -p codesigning
   ```
   Note the full string, e.g.
   `Developer ID Application: Chris Madden (AB12CD34EF)`.
4. **Store notarization credentials** once (uses an app-specific password
   from <https://appleid.apple.com> ▸ Sign-In & Security, or an App Store
   Connect API key):
   ```
   xcrun notarytool store-credentials newt-notary \
     --apple-id you@example.com --team-id AB12CD34EF --password <app-specific-pw>
   ```

## Build & ship

```
make dmg SIGN_ID="Developer ID Application: Chris Madden (AB12CD34EF)"
```

That signs the app + helper with hardened runtime, notarizes via the
`newt-notary` profile, staples the ticket, and produces
`build/Newt.dmg`. Intermediate targets `make build` / `make notarize` are
available too. Override the notary profile name with `NOTARY_PROFILE=...`.

## Notes

- The helper is signed with the same Developer ID, so it shares your Team ID —
  which is what `SMAppService` daemon registration validates.
- The XPC code-signing requirements (`HelperProtocol.swift` constants) match on
  bundle identifier; with a real Team ID they could be tightened to also pin
  the team, but identifier matching is sufficient.
- No entitlements file is needed: neither the app nor the helper uses a
  hardened-runtime-restricted capability (spawning `pmset` is allowed).

## CI (not yet wired up)

Producing notarized builds from GitHub Actions additionally needs the
Developer ID cert exported as a base64 `.p12` and the notary credentials added
as repository secrets, then imported into a temporary keychain in the workflow.
Add this once the certificate exists.
