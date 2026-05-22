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
               Newt/HelperClient.swift Shared/HelperProtocol.swift
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

.PHONY: build install run rerun kill clean reset-sleep helper-status notarize dmg

build:
	@mkdir -p $(MACOS) $(DAEMONS)
	swiftc $(SWIFTFLAGS) $(APP_SRC) -o $(MACOS)/$(APP_NAME)
	swiftc $(SWIFTFLAGS) \
	  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
	  -Xlinker NewtHelper/Info.plist \
	  $(HELPER_SRC) -o $(MACOS)/$(HELPER_NAME)
	cp Newt/Info.plist $(CONTENTS)/Info.plist
	cp $(HELPER_NAME).plist $(DAEMONS)/$(HELPER_NAME).plist
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

# Show whether the privileged helper is registered/enabled.
helper-status:
	-pmset -g | grep -i disablesleep || echo "(disablesleep not set)"
