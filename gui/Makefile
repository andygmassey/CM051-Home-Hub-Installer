# Makefile – OstlerInstaller.app build & ship pipeline
#
# Targets:
#   make debug     Debug build, opens .app from DerivedData
#   make release   Release build (Developer ID signed) -> $(DIST_DIR)/
#   make package   Builds DMG from Release .app -> $(DIST_DIR)/
#   make notarise  Submits DMG to notarytool, polls, staples on success
#   make staple    Staples a previously-notarised DMG (re-runnable)
#   make archive   Copies the shipped DMG to $(ARCHIVE_DIR) with a date-stamped name
#   make ship      release + package + notarise + archive (notarise also staples)
#   make clean     Wipe $(BUILD_DIR) and $(DIST_DIR)
#   make regen     Regenerate the .xcodeproj from project.yml (needs xcodegen)
#
# BUILD_DIR and DIST_DIR default to /tmp paths to avoid iCloud Drive xattr
# races; see comment near the variable definitions below.
#
# Required env vars:
#   NOTARY_PROFILE  keychain-profile alias for notarytool. Default: ostler-installer
#                   Set up once via:
#                     xcrun notarytool store-credentials <alias> \
#                         --apple-id <apple-id> --team-id V95N2B8X7A
#
# Optional env vars:
#   ARCHIVE_DIR     where `make archive` (and chained `make ship`) keeps a
#                   local copy of each notarised DMG, named
#                   $(APP_NAME)-$(VERSION)-YYYY-MM-DD.dmg. Default:
#                   $(HOME)/.ostler-release-artefacts. Symlink that path to
#                   your preferred location if you want a different home.
#                   Hosting on /tmp (the build dir) won't survive a reboot;
#                   the archive step exists so each shipped DMG has a
#                   persistent local copy alongside the GitHub-release upload.

SHELL        := /bin/bash
.SHELLFLAGS  := -euo pipefail -c

# ---------------------------------------------------------------------------
# Project parameters (rarely change)
# ---------------------------------------------------------------------------
# Export OSTLER_APP_PATH so xcodebuild's bundle phase (in
# gui/project.yml) sees it as an env var and copies Ostler.app into
# OstlerInstaller.app/Contents/Resources/ at archive time.
export OSTLER_APP_PATH

PROJECT       := OstlerInstaller.xcodeproj
SCHEME        := OstlerInstaller
APP_NAME      := OstlerInstaller
INFO_PLIST    := OstlerInstaller/Info.plist
TEAM_ID       := V95N2B8X7A
CODESIGN_ID   := Developer ID Application: Creative Machines Limited ($(TEAM_ID))
EXPORT_OPTS   := ExportOptions.plist

NOTARY_PROFILE ?= ostler-installer
ARCHIVE_DIR    ?= $(HOME)/.ostler-release-artefacts

# OSTLER_APP_PATH points at a pre-built Ostler.app (Tauri Hub desktop) that
# `make package` will drop into the DMG window beside the installer, and
# `make sparkle-embed` uses to locate the bundle that gets
# Sparkle.framework + SU* keys stamped in. Default resolves to the
# standard Tauri bundle path for Andy's local checkout of
# ostler-ai/ostler-assistant. Override at make time or in CI to point at
# the notarised bundle produced by a release workflow:
#     make OSTLER_APP_PATH=/path/to/Ostler.app ship
# Leaving it pointing at a missing path is non-fatal: the DMG cuts without
# Ostler.app and `make package` prints a warning. Customers who install
# from that DMG see install.sh's "Ostler.app not found" warning at run time.
OSTLER_APP_PATH ?= $(HOME)/Documents/Projects/ostler-assistant/target/release/bundle/macos/Ostler.app

# ---------------------------------------------------------------------------
# Derived paths
#
# BUILD_DIR and DIST_DIR default to /tmp so they sit OUTSIDE the iCloud-synced
# Projects tree. iCloud's FileProvider asynchronously tags freshly-built files
# with com.apple.FinderInfo + com.apple.fileprovider.fpfs#P xattrs AFTER the
# in-build "Strip xattrs" phase runs, which then causes codesign to reject the
# bundle with "resource fork, Finder information, or similar detritus not
# allowed". Building outside the iCloud-managed tree avoids the race entirely.
# Override either var at make-time if you want the old in-tree behaviour, e.g.
#     make BUILD_DIR=build DIST_DIR=dist ship
# (the $(USER) suffix keeps multiple accounts on the same machine from
# colliding in /tmp).
# ---------------------------------------------------------------------------
BUILD_DIR     ?= /tmp/ostler-installer-build-$(USER)
DERIVED_DATA  := $(BUILD_DIR)/DerivedData
ARCHIVE_PATH  := $(BUILD_DIR)/$(APP_NAME).xcarchive
DIST_DIR      ?= /tmp/ostler-installer-dist-$(USER)

VERSION       := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(INFO_PLIST) 2>/dev/null || echo unknown)
DMG_NAME      := $(APP_NAME)-$(VERSION).dmg
DMG_PATH      := $(DIST_DIR)/$(DMG_NAME)
APP_PATH      := $(DIST_DIR)/$(APP_NAME).app
DEBUG_APP     := $(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app

STEP          := @printf '\n[STEP] %s\n'

.PHONY: all debug release package notarise staple archive ship clean regen \
        check-tools check-identity check-create-dmg print-version dmg-bg \
        sparkle-embed

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

check-create-dmg:
	@command -v create-dmg >/dev/null || { \
	    echo "" >&2; \
	    echo "ERROR: create-dmg not installed." >&2; \
	    echo "Install via: brew install create-dmg" >&2; \
	    exit 1; \
	}

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
	$(STEP) "Stripping xattrs from source tree (codesign hygiene)"
	# Sonoma+ silently attaches com.apple.provenance / com.apple.macl /
	# com.apple.FinderInfo to recently-edited or downloaded files. These
	# xattrs make it through the build into the staged .app and break
	# CodeSign with "resource fork, Finder information, or similar
	# detritus not allowed". Strip them from inputs before archive.
	/usr/bin/xattr -cr "OstlerInstaller" "OstlerInstaller.xcodeproj" || true
	/usr/bin/xattr -cr "../install.sh" "../lib/progress_emitter.sh" || true
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
	$(STEP) "Stripping xattrs from exported .app (post-export hygiene)"
	/usr/bin/xattr -cr "$(APP_PATH)" || true
	$(STEP) "Verifying signature"
	codesign --verify --deep --strict --verbose=2 "$(APP_PATH)"
	@echo ""
	@echo "Release .app: $(APP_PATH)"
	@echo "Version:      $(VERSION)"

# ---------------------------------------------------------------------------
# Sparkle embed (Ostler.app only)
#
# Post-processes a pre-built Ostler.app to embed Sparkle.framework
# and the SU* Info.plist keys (feed URL + EdDSA public key + auto
# check policy). Designed to run after `cargo tauri build` but
# before `make package`, so the DMG payload picks up the
# Sparkle-embedded variant. Invoked automatically by `make ship`
# when OSTLER_APP_PATH points at a real bundle. Safe to run by
# hand against any bundle, idempotent on re-run.
#
# OSTLER_APP_PATH must point at a Tauri-built Ostler.app at the
# top-level Cargo bundle output (e.g.,
# ~/Documents/Projects/ostler-assistant/target/release/bundle/macos/
# Ostler.app). The script verifies the bundle is present before
# any modification.
#
# Override Sparkle source / Info.plist values via the script's
# environment variables: SPARKLE_VERSION, SPARKLE_SHA256,
# SU_FEED_URL, SU_PUBLIC_ED_KEY, SU_ENABLE_AUTO_CHECKS,
# SU_AUTOMATICALLY_UPDATE, CODESIGN_ID. Defaults match the v1.0
# launch posture (appcast.ostler.ai, hub_signing_public_2026-05-16,
# automatic-check ON, auto-install OFF).
# ---------------------------------------------------------------------------
sparkle-embed:
	@if [ ! -d "$(OSTLER_APP_PATH)" ]; then \
	    echo "WARNING: OSTLER_APP_PATH=$(OSTLER_APP_PATH) not found; skipping Sparkle embed." >&2; \
	else \
	    $(STEP_INLINE) "Embedding Sparkle into $(OSTLER_APP_PATH)"; \
	    "$(CURDIR)/scripts/embed-sparkle.sh" "$(OSTLER_APP_PATH)"; \
	fi

# Inline form of $(STEP) usable inside a shell conditional. $(STEP) is
# @-prefixed which breaks the `if ...; then \` pipeline above on macOS bash.
STEP_INLINE := printf '\n[STEP] %s\n'

# ---------------------------------------------------------------------------
# DMG package – Developer ID signed
#
# Uses create-dmg (https://github.com/create-dmg/create-dmg) for the
# drag-to-Applications window layout: fixed window size, custom
# background image, icon positions, /Applications symlink. Replaces
# the bare hdiutil call shipped before 2026-05-13 -- per the DMG UX
# brief, the v0.2.1 customer DMG looked like a folder listing rather
# than a consumer Mac app installer.
#
# Background image lives at gui/assets/dmg-background.png (committed).
# Regenerate with 'make dmg-bg' if the placeholder needs refreshing.
# Icon positions here MUST match the icon centres baked into
# scripts/generate_dmg_background.py so the arrow lines up.
# ---------------------------------------------------------------------------
package: check-tools check-identity check-create-dmg
	@if [ ! -d "$(APP_PATH)" ]; then \
	    echo "ERROR: $(APP_PATH) not found. Run 'make release' first." >&2; \
	    exit 1; \
	fi
	@if [ ! -f "assets/dmg-background.png" ]; then \
	    echo "ERROR: assets/dmg-background.png missing. Run 'make dmg-bg' first." >&2; \
	    exit 1; \
	fi
	# Stage the DMG payload in a dedicated subdir so create-dmg's
	# "give it a directory" form picks up exactly the apps we want
	# in the DMG window. Single-app layout: OstlerInstaller.app +
	# /Applications drop-link only. Ostler.app (Hub desktop) is
	# bundled INSIDE OstlerInstaller.app/Contents/Resources/ by
	# gui/project.yml's bundle phase, so install.sh's source-
	# preference path 2 (${SCRIPT_DIR}/Ostler.app) finds it at
	# customer-install time -- no need to surface Ostler.app as a
	# second draggable icon in the DMG window (was the v0.2.1 two-
	# app layout that confused customers per Andy's 2026-05-20
	# Studio retest #3 review).
	@DMG_STAGE="$(BUILD_DIR)/dmg-payload"; \
	rm -rf "$$DMG_STAGE"; \
	mkdir -p "$$DMG_STAGE"; \
	cp -R "$(APP_PATH)" "$$DMG_STAGE/"; \
	echo "[STEP] Building DMG -> $(DMG_PATH)"; \
	rm -f "$(DMG_PATH)"; \
	create-dmg \
	    --volname "Install Ostler" \
	    --window-pos 200 120 \
	    --window-size 660 400 \
	    --background "assets/dmg-background.png" \
	    --icon-size 128 \
	    --icon "$(APP_NAME).app" 165 200 \
	    --hide-extension "$(APP_NAME).app" \
	    --app-drop-link 495 200 \
	    --no-internet-enable \
	    "$(DMG_PATH)" \
	    "$$DMG_STAGE"
	$(STEP) "Signing DMG with $(CODESIGN_ID)"
	codesign --sign "$(CODESIGN_ID)" --timestamp --force "$(DMG_PATH)"
	codesign --verify --verbose=2 "$(DMG_PATH)"
	@echo ""
	@echo "DMG: $(DMG_PATH)"

# Regenerate the DMG background placeholder PNG. The asset is
# committed at gui/assets/dmg-background.png so the build itself
# never depends on Python being available at release time; this
# target exists so the script or asset can be refreshed by hand.
dmg-bg:
	@command -v python3 >/dev/null || { echo "ERROR: python3 not found." >&2; exit 1; }
	@python3 -c "from PIL import Image" 2>/dev/null || { \
	    echo "ERROR: Pillow not installed. Run: python3 -m pip install Pillow" >&2; \
	    exit 1; \
	}
	$(STEP) "Generating DMG background → assets/dmg-background.png"
	python3 scripts/generate_dmg_background.py

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
# Archive: keep a local persistent copy of the shipped DMG.
# Runs after notarise + staple so the archived bytes have the notary ticket
# embedded. Date-stamped filename so successive ships don't overwrite each
# other. Idempotent on the same day (cp -f).
# ---------------------------------------------------------------------------
archive:
	@if [ ! -f "$(DMG_PATH)" ]; then \
	    echo "ERROR: $(DMG_PATH) not found. Run \`make ship\` first." >&2; \
	    exit 1; \
	fi
	$(STEP) "Archiving $(DMG_NAME) → $(ARCHIVE_DIR)/"
	@mkdir -p "$(ARCHIVE_DIR)"
	@ARCHIVE_NAME="$(APP_NAME)-$(VERSION)-$$(date +%Y-%m-%d).dmg" && \
	    cp -f "$(DMG_PATH)" "$(ARCHIVE_DIR)/$$ARCHIVE_NAME" && \
	    echo "Archived: $(ARCHIVE_DIR)/$$ARCHIVE_NAME"

# ---------------------------------------------------------------------------
# One-shot: build → DMG → notarise → staple → archive
# ---------------------------------------------------------------------------
ship: sparkle-embed release package notarise archive
	@echo ""
	@echo "Shipped:  $(DMG_PATH)"
	@echo "Archived: $(ARCHIVE_DIR)/"

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
