-include local.env
export

APPNAME    := DataHawk
BUNDLE_ID  := com.datahawk.app

# Derive version from the latest git tag (format: v0.1.0 → 0.1.0).
# Falls back to 0.0.0 if no tag exists yet.
VERSION    := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
VERSION    := $(if $(VERSION),$(VERSION),0.0.0)

BUILD_DIR  := .build
APP_BUNDLE := $(BUILD_DIR)/$(APPNAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
MACOS_DIR  := $(CONTENTS)/MacOS
RES_DIR    := $(CONTENTS)/Resources

DIST_APP   := $(APPNAME).app
DMG_NAME   := $(APPNAME).dmg
DMG_PATH   := $(BUILD_DIR)/$(DMG_NAME)
DMG_STAGE  := $(BUILD_DIR)/dmg-stage
Q_DMG      := "$(DMG_NAME)"
ICNS       := Icon/AppIcon.icns

SIGN_ID             ?=
APPLE_ID            ?=
APPLE_TEAM_ID       ?=
APPLE_APP_PASSWORD  ?=

TARGET     := arm64-apple-macos26.0

SWIFT      := xcrun swiftc
SWIFT_FLAGS := \
  -O \
  -target $(TARGET) \
  -framework AppKit \
  -framework Foundation \
  -framework CoreWLAN \
  -framework SystemConfiguration \
  -framework Network \
  -framework ServiceManagement \
  -framework Combine \
  -framework SwiftUI \
  -framework CoreLocation

# All Swift sources, sorted for deterministic compilation order
SOURCES    := $(shell find Sources -name "*.swift" | sort)

.PHONY: app app-dev dmg icon notarize release clean

$(ICNS): Icon/CreateIcon.swift
	@echo "==> Generating $(ICNS)..."
	@swift Icon/CreateIcon.swift
	@mv AppIcon.icns $(ICNS)
	@echo "==> Generated $(ICNS)"

icon: $(ICNS)

app: $(SOURCES) $(ICNS) Resources/Info.plist
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	$(SWIFT) $(SWIFT_FLAGS) -o "$(MACOS_DIR)/$(APPNAME)" $(SOURCES)
	@cp $(ICNS) $(CONTENTS)/Resources/AppIcon.icns
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" "$(CONTENTS)/Info.plist"
	@sign_id="$(SIGN_ID)"; \
	if [ -z "$$sign_id" ]; then \
	  printf "==> Enter signing identity (SIGN_ID) [ENTER to skip]: "; \
	  read sign_id; \
	fi; \
	if [ -z "$$sign_id" ]; then \
	  echo "==> WARNING: No signing identity provided, skipping code signing."; \
	else \
	  codesign --force --deep --options runtime --sign "$$sign_id" $(APP_BUNDLE); \
	fi
	@rm -rf "$(DIST_APP)"
	@mv "$(APP_BUNDLE)" "$(DIST_APP)"
	@echo "Built $(DIST_APP) ($(VERSION))"

app-dev: app
	@pkill -x "$(APPNAME)" 2>/dev/null || true
	@sleep 0.5
	@open "$(DIST_APP)"
	@echo "Restarted $(APPNAME)"

dmg: $(DIST_APP)
	@echo "==> Packaging $(DMG_NAME)"
	@rm -rf "$(DMG_STAGE)" "$(DMG_PATH)"
	@mkdir -p "$(DMG_STAGE)"
	@mv "$(DIST_APP)" "$(DMG_STAGE)/"
	@ln -s /Applications "$(DMG_STAGE)/Applications"
	@hdiutil create \
	  -volname "$(APPNAME) $(VERSION)" \
	  -srcfolder "$(DMG_STAGE)" \
	  -ov \
	  -format UDZO \
	  -quiet \
	  "$(DMG_PATH)"
	@rm -rf "$(DMG_STAGE)"
	@mv "$(DMG_PATH)" "$(DMG_NAME)"
	@echo "Created $(DMG_NAME)"

notarize:
	@echo "==> Notarizing $(DMG_NAME)..."
	@apple_id="$(APPLE_ID)"; \
	apple_team_id="$(APPLE_TEAM_ID)"; \
	apple_app_password="$(APPLE_APP_PASSWORD)"; \
	if [ -z "$$apple_id" ]; then \
	  printf "==> Enter Apple ID (email): "; \
	  read apple_id; \
	fi; \
	if [ -z "$$apple_team_id" ]; then \
	  printf "==> Enter Apple Team ID: "; \
	  read apple_team_id; \
	fi; \
	if [ -z "$$apple_app_password" ]; then \
	  printf "==> Enter Apple app-specific password: "; \
	  read -s apple_app_password; \
	  echo; \
	fi; \
	xcrun notarytool submit $(Q_DMG) \
	    --apple-id "$$apple_id" \
	    --team-id "$$apple_team_id" \
	    --password "$$apple_app_password" \
	    --wait
	@echo "==> Stapling notarization ticket..."
	@xcrun stapler staple $(Q_DMG)
	@echo "==> Notarized and stapled $(DMG_NAME)"

release: dmg notarize

clean:
	@rm -rf "$(BUILD_DIR)" "$(DIST_APP)" "$(DMG_NAME)" $(ICNS) AppIcon.iconset
	@echo "Cleaned"
