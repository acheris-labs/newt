APP_NAME    := Newt
HELPER_NAME := net.acheris.newt.helper
BUNDLE_ID   := net.acheris.newt

BUILD       := build
APP         := $(BUILD)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
MACOS       := $(CONTENTS)/MacOS
DAEMONS     := $(CONTENTS)/Library/LaunchDaemons
INSTALLED   := /Applications/$(APP_NAME).app

TARGET      := arm64-apple-macos13.0
SWIFTFLAGS  := -O -target $(TARGET)

APP_SRC     := Newt/main.swift Newt/AppDelegate.swift \
               Newt/StatusItemController.swift Newt/SleepManager.swift \
               Newt/HelperClient.swift Newt/LoginItemController.swift \
               Newt/BatteryMonitor.swift Shared/HelperProtocol.swift
HELPER_SRC  := NewtHelper/main.swift NewtHelper/HelperService.swift \
               Shared/HelperProtocol.swift

# --- Code signing -----------------------------------------------------------
# SIGN_ID defaults to ad-hoc ("-"): builds and runs locally, but cannot
# register the SMAppService daemon and cannot be notarized. For distributable
# builds pass a Developer ID (see DISTRIBUTING.md):
#   make dmg SIGN_ID="Developer ID Application: Chris Madden (TEAMID)"
SIGN_ID        ?= -
NOTARY_PROFILE ?= newt-notary

# Hardened runtime + secure timestamp are required for notarization, but are
# rejected by ad-hoc signing — only add them with a real identity.
ifeq ($(SIGN_ID),-)
  HARDENED :=
else
  HARDENED := --options runtime --timestamp
endif

.PHONY: build install run rerun kill clean reset-sleep helper-status notarize dmg setup-notary setup-secrets icon

# --- Credential bootstrap ---------------------------------------------------
# Reusable shell snippets that read the Developer ID identity + Team ID from
# your keychain. Inlined into the recipes that need them so this only runs
# when invoked, not on every `make`.
define _devid_detect
DEVID_LINE=$$(security find-identity -v -p codesigning \
  | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"(.*)".*$$/\1/p' \
  | head -1); \
test -n "$$DEVID_LINE" || { echo "no Developer ID Application identity in keychain"; exit 1; }; \
DEVID_TEAM=$$(echo "$$DEVID_LINE" | sed -nE 's/.*\(([A-Z0-9]+)\).*/\1/p')
endef

# Store the notarytool keychain profile. Run once per machine.
#   1. Copy the 19-char app-specific password from appleid.apple.com to your clipboard.
#   2. make setup-notary APPLE_ID=you@example.com
setup-notary:
	@test -n "$(APPLE_ID)" || { \
	  echo "usage: make setup-notary APPLE_ID=you@example.com"; \
	  echo "(copy your 19-char app-specific password to the clipboard first)"; \
	  exit 1; }
	@bash -ec '$(_devid_detect); \
	  PW=$$(pbpaste); \
	  test $${#PW} -eq 19 || { echo "clipboard is $${#PW} chars, expected 19 (xxxx-xxxx-xxxx-xxxx)"; exit 1; }; \
	  xcrun notarytool store-credentials $(NOTARY_PROFILE) \
	    --apple-id "$(APPLE_ID)" --team-id "$$DEVID_TEAM" --password "$$PW"; \
	  echo "notarytool profile $(NOTARY_PROFILE) is ready (team $$DEVID_TEAM)"'

# Upload Developer ID + notary credentials to GitHub as org-level secrets
# scoped to the listed repos. Run once after exporting the cert as .p12.
#   1. Keychain Access → My Certificates → right-click Developer ID Application
#      → Export → save as devid.p12 with a strong password.
#   2. Copy your app-specific password to the clipboard.
#   3. make setup-secrets P12=path/to/devid.p12 APPLE_ID=you@example.com \
#                         ORG=acheris-labs REPOS=tracker,newt
setup-secrets:
	@test -f "$(P12)" || { echo "set P12=path/to/devid.p12"; exit 1; }
	@test -n "$(APPLE_ID)" || { echo "set APPLE_ID=you@example.com"; exit 1; }
	@test -n "$(ORG)"      || { echo "set ORG=acheris-labs"; exit 1; }
	@test -n "$(REPOS)"    || { echo "set REPOS=tracker,newt"; exit 1; }
	@bash -ec '$(_devid_detect); \
	  read -s -p ".p12 export password: " P12_PW; echo; \
	  APP_PW=$$(pbpaste); \
	  test $${#APP_PW} -eq 19 || { echo "clipboard not a 19-char app-specific password"; exit 1; }; \
	  echo "uploading to $(ORG) repos: $(REPOS)"; \
	  base64 -i "$(P12)"        | gh secret set DEVID_CERT_P12      --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$$P12_PW"    | gh secret set DEVID_CERT_PASSWORD --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$$DEVID_LINE"| gh secret set DEVID_IDENTITY      --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$(APPLE_ID)" | gh secret set APPLE_ID            --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$$DEVID_TEAM"| gh secret set APPLE_TEAM_ID       --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$$APP_PW"    | gh secret set APPLE_APP_PASSWORD  --org $(ORG) --repos $(REPOS); \
	  echo done'

build:
	@mkdir -p $(MACOS) $(DAEMONS)
	swiftc $(SWIFTFLAGS) $(APP_SRC) -o $(MACOS)/$(APP_NAME)
	swiftc $(SWIFTFLAGS) \
	  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
	  -Xlinker NewtHelper/Info.plist \
	  $(HELPER_SRC) -o $(MACOS)/$(HELPER_NAME)
	cp Newt/Info.plist $(CONTENTS)/Info.plist
	cp $(HELPER_NAME).plist $(DAEMONS)/$(HELPER_NAME).plist
	@mkdir -p $(CONTENTS)/Resources
	cp Newt/Newt.icns $(CONTENTS)/Resources/Newt.icns
	# Sign inside-out: nested helper first, then seal the bundle. The XPC
	# code-signing requirements match on bundle identifier, so keep it stable.
	codesign --force --sign "$(SIGN_ID)" $(HARDENED) \
	  --identifier $(HELPER_NAME) $(MACOS)/$(HELPER_NAME)
	codesign --force --sign "$(SIGN_ID)" $(HARDENED) \
	  --identifier $(BUNDLE_ID) $(APP)
	codesign --verify --verbose $(APP)
	@echo "built $(APP)  (signed: $(SIGN_ID))"

# SMAppService daemon registration only works from /Applications, so `run`
# installs there rather than launching from build/.
install: build kill
	rm -rf $(INSTALLED)
	cp -R $(APP) $(INSTALLED)

run: install
	open $(INSTALLED)

kill:
	-killall $(APP_NAME) 2>/dev/null || true

rerun: kill run

clean:
	rm -rf $(BUILD)

# --- Distribution -----------------------------------------------------------
# Notarize the signed app. Requires SIGN_ID set to a Developer ID and a
# notarytool keychain profile created once with:
#   xcrun notarytool store-credentials $(NOTARY_PROFILE) \
#     --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
notarize: build
	@test "$(SIGN_ID)" != "-" || { \
	  echo "error: set SIGN_ID to a Developer ID — see DISTRIBUTING.md"; exit 1; }
	rm -f $(BUILD)/$(APP_NAME).zip
	ditto -c -k --keepParent $(APP) $(BUILD)/$(APP_NAME).zip
	xcrun notarytool submit $(BUILD)/$(APP_NAME).zip \
	  --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(APP)
	xcrun stapler validate $(APP)
	@echo "notarized + stapled $(APP)"

# Notarized .dmg ready to ship.
dmg: notarize
	@command -v create-dmg >/dev/null || brew install create-dmg
	rm -rf $(BUILD)/staging && mkdir -p $(BUILD)/staging
	cp -R $(APP) $(BUILD)/staging/
	rm -f $(BUILD)/$(APP_NAME).dmg
	create-dmg \
	  --volname "$(APP_NAME)" \
	  --window-size 540 360 --icon-size 96 \
	  --icon "$(APP_NAME).app" 140 180 \
	  --hide-extension "$(APP_NAME).app" \
	  --app-drop-link 400 180 \
	  $(BUILD)/$(APP_NAME).dmg $(BUILD)/staging/
	@echo "built $(BUILD)/$(APP_NAME).dmg"

# Undo a stuck `pmset disablesleep` by hand (helper normally does this itself).
reset-sleep:
	sudo pmset -a disablesleep 0

# Regenerate the app icon (Newt/Newt.icns) from tools/gen-icon.swift.
icon:
	swift tools/gen-icon.swift Newt.iconset
	iconutil -c icns Newt.iconset -o Newt/Newt.icns
	rm -rf Newt.iconset
	@echo "wrote Newt/Newt.icns"

# Show whether sleep is currently disabled. `pmset -g` reports it as
# `SleepDisabled` (capital S), not `disablesleep`.
helper-status:
	@pmset -g | awk '/SleepDisabled/ { print "SleepDisabled =", $$2; found=1 } END { if (!found) print "(SleepDisabled not set)" }'
	@pmset -g assertions | grep -E 'Newt|^\s*(PreventUser)' || true
