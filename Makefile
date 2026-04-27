-include local.env
export

APPNAME    := DataHawk
BUNDLE_ID  := com.datahawk.app

# Derive version from the latest git tag (format: v0.1.0 → 0.1.0).
# Falls back to 0.1.0 if no tag exists yet.
VERSION    := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
VERSION    := $(if $(VERSION),$(VERSION),0.1.0)

BUILD_DIR  := .build
APP_BUNDLE := $(BUILD_DIR)/$(APPNAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
MACOS_DIR  := $(CONTENTS)/MacOS
RES_DIR    := $(CONTENTS)/Resources

DIST_APP   := $(APPNAME).app
DMG_NAME   := $(APPNAME).dmg
DMG_PATH   := $(BUILD_DIR)/$(DMG_NAME)
DMG_STAGE  := $(BUILD_DIR)/dmg-stage

SIGN_ID    ?=

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

.PHONY: all all-dev dmg release clean run

all: $(DIST_APP)

$(DIST_APP): $(SOURCES) Resources/Info.plist
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	$(SWIFT) $(SWIFT_FLAGS) -o "$(MACOS_DIR)/$(APPNAME)" $(SOURCES)
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
	@mv "$(APP_BUNDLE)" "$(DIST_APP)"
	@echo "Built $(DIST_APP) ($(VERSION))"

all-dev: all
	@pkill -x "$(APPNAME)" 2>/dev/null || true
	@sleep 0.5
	@open "$(DIST_APP)"
	@echo "Restarted $(APPNAME)"

# Packages the built .app into a distributable DMG.
# Requires the .app to already be built (and signed for distribution).
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

# Full release flow: requires SIGN_ID. Builds, signs, and packages a DMG.
# Usage: make release SIGN_ID="Developer ID Application: ..."
release:
	@if [ -z "$(SIGN_ID)" ]; then \
	  echo "Error: SIGN_ID is required for release."; \
	  echo "Usage: make release SIGN_ID=\"Developer ID Application: Your Name (TEAMID)\""; \
	  exit 1; \
	fi
	@$(MAKE) --no-print-directory dmg SIGN_ID="$(SIGN_ID)"

run: all
	@open "$(DIST_APP)"

clean:
	@rm -rf "$(BUILD_DIR)" "$(DIST_APP)" "$(DMG_NAME)"
	@echo "Cleaned"
