-include local.env
export

APPNAME    := DataHawk
BUNDLE_ID  := com.datahawk.app
VERSION    := 0.1.0

BUILD_DIR  := .build
APP_BUNDLE := $(BUILD_DIR)/$(APPNAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
MACOS_DIR  := $(CONTENTS)/MacOS
RES_DIR    := $(CONTENTS)/Resources

SIGN_ID    ?=

# Detect host architecture automatically
ARCH       := $(shell uname -m)
ifeq ($(ARCH),arm64)
  TARGET   := arm64-apple-macos13.0
else
  TARGET   := x86_64-apple-macos13.0
endif

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

.PHONY: all all-dev clean run

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES) Resources/Info.plist
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	$(SWIFT) $(SWIFT_FLAGS) -o "$(MACOS_DIR)/$(APPNAME)" $(SOURCES)
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
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
	@echo "Built $(APP_BUNDLE)"

all-dev: all
	@pkill -x "$(APPNAME)" 2>/dev/null || true
	@sleep 0.5
	@open "$(APP_BUNDLE)"
	@echo "Restarted $(APPNAME)"

run: all
	@open "$(APP_BUNDLE)"

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "Cleaned"
