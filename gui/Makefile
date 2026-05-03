# Makefile – OstlerInstaller.app build & ship pipeline
#
# Targets:
#   make debug     Debug build, opens .app from DerivedData
#   make release   Release build (Developer ID signed) -> dist/
#   make package   Builds DMG from Release .app -> dist/
#   make notarise  Submits DMG to notarytool, polls, staples on success
#   make staple    Staples a previously-notarised DMG (re-runnable)
#   make ship      release + package + notarise (notarise also staples)
#   make clean     Wipe build/ and dist/
#   make regen     Regenerate the .xcodeproj from project.yml (needs xcodegen)
#
# Required env vars:
#   NOTARY_PROFILE  keychain-profile alias for notarytool. Default: ostler-installer
#                   Set up once via:
#                     xcrun notarytool store-credentials <alias> \
#                         --apple-id <apple-id> --team-id V95N2B8X7A

SHELL        := /bin/bash
.SHELLFLAGS  := -euo pipefail -c

# ---------------------------------------------------------------------------
# Project parameters (rarely change)
# ---------------------------------------------------------------------------
PROJECT       := OstlerInstaller.xcodeproj
SCHEME        := OstlerInstaller
APP_NAME      := OstlerInstaller
INFO_PLIST    := OstlerInstaller/Info.plist
TEAM_ID       := V95N2B8X7A
CODESIGN_ID   := Developer ID Application: Creative Machines Limited ($(TEAM_ID))
EXPORT_OPTS   := ExportOptions.plist

NOTARY_PROFILE ?= ostler-installer

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
BUILD_DIR     := build
DERIVED_DATA  := $(BUILD_DIR)/DerivedData
ARCHIVE_PATH  := $(BUILD_DIR)/$(APP_NAME).xcarchive
DIST_DIR      := dist

VERSION       := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(INFO_PLIST) 2>/dev/null || echo unknown)
DMG_NAME      := $(APP_NAME)-$(VERSION).dmg
DMG_PATH      := $(DIST_DIR)/$(DMG_NAME)
APP_PATH      := $(DIST_DIR)/$(APP_NAME).app
DEBUG_APP     := $(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app

STEP          := @printf '\n[STEP] %s\n'

.PHONY: all debug release package notarise staple ship clean regen \
        check-tools check-identity print-version

all: debug

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
check-tools:
	@command -v xcodebuild >/dev/null || { echo "ERROR: xcodebuild not found. Install Xcode (not just Command Line Tools)." >&2; exit 1; }
	@command -v xcrun      >/dev/null || { echo "ERROR: xcrun not found." >&2; exit 1; }

check-identity:
	@if ! security find-identity -p codesigning -v | grep -F "$(CODESIGN_ID)" >/dev/null; then \
	    echo "" >&2; \
	    echo "ERROR: Code signing identity not found in any keychain:" >&2; \
	    echo "  $(CODESIGN_ID)" >&2; \
	    echo "" >&2; \
	    echo "Available codesigning identities:" >&2; \
	    security find-identity -p codesigning -v >&2 || true; \
	    exit 1; \
	fi

print-version:
	@echo "version: $(VERSION)"

# ---------------------------------------------------------------------------
# Debug build – fast, ad-hoc signed, opens the .app
# ---------------------------------------------------------------------------
debug: check-tools
	$(STEP) "Debug build → $(DEBUG_APP)"
	xcodebuild \
	    -project $(PROJECT) \
	    -scheme $(SCHEME) \
	    -configuration Debug \
	    -derivedDataPath $(DERIVED_DATA) \
	    build
	$(STEP) "Opening Debug .app"
	open "$(DEBUG_APP)"

# ---------------------------------------------------------------------------
# Release build – Developer ID signed, exported to dist/
# ---------------------------------------------------------------------------
release: check-tools check-identity
	$(STEP) "Release archive → $(ARCHIVE_PATH)"
	rm -rf "$(ARCHIVE_PATH)" "$(APP_PATH)"
	mkdir -p "$(DIST_DIR)"
	xcodebuild \
	    -project $(PROJECT) \
	    -scheme $(SCHEME) \
	    -configuration Release \
	    -archivePath "$(ARCHIVE_PATH)" \
	    -derivedDataPath $(DERIVED_DATA) \
	    DEVELOPMENT_TEAM=$(TEAM_ID) \
	    CODE_SIGN_STYLE=Manual \
	    CODE_SIGN_IDENTITY="$(CODESIGN_ID)" \
	    archive
	$(STEP) "Exporting Developer ID archive → $(DIST_DIR)/"
	xcodebuild \
	    -exportArchive \
	    -archivePath "$(ARCHIVE_PATH)" \
	    -exportPath "$(DIST_DIR)" \
	    -exportOptionsPlist "$(EXPORT_OPTS)"
	$(STEP) "Verifying signature"
	codesign --verify --deep --strict --verbose=2 "$(APP_PATH)"
	@echo ""
	@echo "Release .app: $(APP_PATH)"
	@echo "Version:      $(VERSION)"

# ---------------------------------------------------------------------------
# DMG package – Developer ID signed
# ---------------------------------------------------------------------------
package: check-tools check-identity
	@if [ ! -d "$(APP_PATH)" ]; then \
	    echo "ERROR: $(APP_PATH) not found. Run 'make release' first." >&2; \
	    exit 1; \
	fi
	$(STEP) "Building DMG → $(DMG_PATH)"
	rm -f "$(DMG_PATH)"
	hdiutil create \
	    -volname "Ostler Installer $(VERSION)" \
	    -srcfolder "$(APP_PATH)" \
	    -ov -format UDZO \
	    "$(DMG_PATH)"
	$(STEP) "Signing DMG with $(CODESIGN_ID)"
	codesign --sign "$(CODESIGN_ID)" --timestamp --force "$(DMG_PATH)"
	codesign --verify --verbose=2 "$(DMG_PATH)"
	@echo ""
	@echo "DMG: $(DMG_PATH)"

# ---------------------------------------------------------------------------
# Notarisation – submits, waits, then staples
# ---------------------------------------------------------------------------
notarise: check-tools
	@if [ ! -f "$(DMG_PATH)" ]; then \
	    echo "ERROR: $(DMG_PATH) not found. Run 'make package' first." >&2; \
	    exit 1; \
	fi
	$(STEP) "Submitting $(DMG_NAME) to notarytool (profile: $(NOTARY_PROFILE))"
	@if ! xcrun notarytool submit "$(DMG_PATH)" \
	        --keychain-profile "$(NOTARY_PROFILE)" \
	        --wait; then \
	    echo "" >&2; \
	    echo "Notarisation failed. Find the submission ID above and run:" >&2; \
	    echo "  xcrun notarytool log <submission-id> --keychain-profile $(NOTARY_PROFILE)" >&2; \
	    exit 1; \
	fi
	@$(MAKE) --no-print-directory staple

staple: check-tools
	@if [ ! -f "$(DMG_PATH)" ]; then \
	    echo "ERROR: $(DMG_PATH) not found." >&2; \
	    exit 1; \
	fi
	$(STEP) "Stapling notarisation ticket → $(DMG_NAME)"
	xcrun stapler staple "$(DMG_PATH)"
	$(STEP) "Verifying with spctl"
	spctl -a -vvv -t install "$(DMG_PATH)"
	@echo ""
	@echo "Notarised + stapled: $(DMG_PATH)"

# ---------------------------------------------------------------------------
# One-shot: build → DMG → notarise → staple
# ---------------------------------------------------------------------------
ship: release package notarise
	@echo ""
	@echo "Shipped: $(DMG_PATH)"

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------
clean:
	$(STEP) "Wiping $(BUILD_DIR)/ and $(DIST_DIR)/"
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"

regen:
	@command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not installed (brew install xcodegen)." >&2; exit 1; }
	$(STEP) "Regenerating $(PROJECT) from project.yml"
	xcodegen generate
