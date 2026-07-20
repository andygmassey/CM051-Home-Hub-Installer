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

# ---------------------------------------------------------------------------
# CX-19 (launch blocker, 2026-05-23): python-build-standalone bundling.
#
# Studio retest #14 (DMG #16) caught a phase-ordering bug that lands on
# every fresh customer Mac. install.sh runs `python3 --version` early in
# the QUESTIONS phase; on a stock macOS 15 install (no Command Line Tools,
# no Homebrew) that hits the /usr/bin/python3 Apple stub which fires the
# "Install Command Line Tools" GUI dialog and returns non-zero. The script
# then falls through to `brew install python@3.11` which itself fails with
# exit 127 because Homebrew has not been installed yet -- that step is in
# the INSTALL phase (~line 3264) which runs AFTER the Python check at
# ~line 1999.
#
# Architectural fix: bundle Python 3.11 inside the .app via
# python-build-standalone (https://github.com/astral-sh/python-build-standalone).
# These are portable statically-linked CPython builds designed for embedding
# in distributable tools -- uv, ruff, mise, Posit all use them. install.sh
# uses the bundled Python for every venv it creates, so the customer never
# triggers the CLT dialog and the install does not depend on Homebrew
# existing yet.
#
# Apple Silicon only for v1.0 (the aarch64-apple-darwin install_only flavor).
# Intel Mac support is deferred to v1.0.1 -- the same upstream releases ship
# x86_64-apple-darwin builds so the lift is straightforward, but Intel Macs
# were never a primary launch target.
#
# Pinned version: cpython-3.11.15+20260510-aarch64-apple-darwin-install_only.tar.gz
# SHA-256:        03bcedae9b19a48888d7dc8ba064f73f6efaaf2b13f6a8e1a1bcc062df13e855
#
# To bump: pick a newer cpython-3.11.X+YYYYMMDD release from
# https://github.com/astral-sh/python-build-standalone/releases, update
# PYTHON_BUNDLE_VERSION + PYTHON_BUNDLE_SHA256 below, run
# `make download-python` and confirm the verify step still passes.
# ---------------------------------------------------------------------------
PYTHON_BUNDLE_VERSION  ?= 3.11.15+20260510
PYTHON_BUNDLE_SHA256   ?= 03bcedae9b19a48888d7dc8ba064f73f6efaaf2b13f6a8e1a1bcc062df13e855
PYTHON_BUNDLE_PLATFORM ?= aarch64-apple-darwin-install_only
PYTHON_BUNDLE_URL      := https://github.com/astral-sh/python-build-standalone/releases/download/$(word 2,$(subst +, ,$(PYTHON_BUNDLE_VERSION)))/cpython-$(PYTHON_BUNDLE_VERSION)-$(PYTHON_BUNDLE_PLATFORM).tar.gz
PYTHON_BUNDLE_TARBALL  := $(BUILD_DIR)/python-bundle.tar.gz

# ---------------------------------------------------------------------------
# CX-88 (DMG #48g, 2026-05-29): bundled ostler-assistant daemon tarball.
#
# install.sh's daemon-install path tries the bundled DMG payload first
# (Contents/Resources/assistant-agent/OstlerAssistant.app/) and only
# falls back to a GitHub fetch when the bundled artefact is missing.
# Customer-shipping releases live at ostler-ai/ostler-releases with the
# component-prefixed tag `hub-vX.Y.Z` (locked 2026-05-29 02:45 HKT). The
# source repo ostler-ai/ostler-assistant is private + must never appear
# in a public-curl release URL. The bundled path is the load-bearing
# one for v1.0 and this target ships the v0.4.4 daemon inside the DMG.
#
# Local-archive fallback: this target prefers a pre-staged tarball at
# $$HOME/.ostler-release-artefacts/$(DAEMON_TARBALL_NAME) before any
# network fetch. The signing operator caches verified release builds
# there manually (rotation: keep the last two), so a `make ship` run
# does not strand on the public release being unpublished yet.
#
# Auth fallback (only reached if local cache + release-artefacts dir
# are both empty): `gh release download` if available, else curl with
# $GH_TOKEN. Once the hub-v0.4.4 release is public + readable without
# auth (token refresh pending), the gh/curl paths are no-auth fetches.
#
# Pinned version: tracks DAEMON_VERSION below. To bump, change
# DAEMON_VERSION + DAEMON_SHA256 and run `make download-daemon` to
# verify the fetch + checksum still pass.
# ---------------------------------------------------------------------------
DAEMON_VERSION       ?= 0.4.32
# SHA-256 of the published hub-v$(DAEMON_VERSION) tarball
# (ostler-assistant-aarch64-apple-darwin-v$(DAEMON_VERSION).tar.gz). Verified
# fail-closed in download-daemon: a mismatch deletes the file + aborts the cut,
# so an unverified / wrong-version daemon can never reach the DMG. Bump in
# lockstep with DAEMON_VERSION from the release's published .sha256 sidecar.
DAEMON_SHA256        ?= 3d520ab1fc9cb8fc2642db31fe7ab7f12e4a56e96a178c1fb806b85de9686dc1
DAEMON_REPO          ?= ostler-ai/ostler-releases
DAEMON_TARGET        ?= aarch64-apple-darwin
DAEMON_TARBALL_NAME  := ostler-assistant-$(DAEMON_TARGET)-v$(DAEMON_VERSION).tar.gz
DAEMON_TARBALL_CACHE := $(BUILD_DIR)/$(DAEMON_TARBALL_NAME)
# Component-prefixed tag: hub-vX.Y.Z, NOT bare vX.Y.Z. The release repo
# hosts multiple component streams (hub, remote-capture, iOS, etc.)
# under one repository, so the prefix is load-bearing.
DAEMON_RELEASE_TAG   := hub-v$(DAEMON_VERSION)
DAEMON_RELEASE_URL   := https://github.com/$(DAEMON_REPO)/releases/download/$(DAEMON_RELEASE_TAG)/$(DAEMON_TARBALL_NAME)
# Local-archive fallback location: the signing operator keeps verified
# release builds in $$HOME/.ostler-release-artefacts/ so `make ship`
# can complete without the public release being live yet. Path is
# evaluated at recipe-run time so $$HOME expands correctly.
DAEMON_LOCAL_CACHE_DIR := $$HOME/.ostler-release-artefacts

STEP          := @printf '\n[STEP] %s\n'

.PHONY: all debug release package notarise staple archive ship clean regen \
        check-tools check-identity check-create-dmg check-ostler-app \
        print-version dmg-bg sparkle-embed verify-dmg-contents download-python \
        sign-python-bundle download-daemon stage-daemon check-provenance \
        check-freshness

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
# Download + verify python-build-standalone tarball.
#
# Cached: re-runnable, skips network when $(PYTHON_BUNDLE_TARBALL) already
# exists with the right SHA-256. SHA-256 mismatch deletes the file and
# refuses to proceed -- never ship from an unverified download.
#
# The tarball lives in $(BUILD_DIR) (default /tmp) so `make clean` wipes it.
# It is consumed by the gui/project.yml postBuildScript that extracts into
# OstlerInstaller.app/Contents/Resources/python/ at xcodebuild time.
# ---------------------------------------------------------------------------
download-python:
	@mkdir -p "$(BUILD_DIR)"; \
	EXPECTED="$(PYTHON_BUNDLE_SHA256)"; \
	if [ -f "$(PYTHON_BUNDLE_TARBALL)" ]; then \
	    ACTUAL="$$(shasum -a 256 "$(PYTHON_BUNDLE_TARBALL)" | awk '{print $$1}')"; \
	    if [ "$$ACTUAL" = "$$EXPECTED" ]; then \
	        printf '[STEP] python-build-standalone cache hit: %s\n' "$(PYTHON_BUNDLE_TARBALL)"; \
	        exit 0; \
	    fi; \
	    printf '[STEP] python-build-standalone cache present but SHA-256 differs -- redownloading\n'; \
	    rm -f "$(PYTHON_BUNDLE_TARBALL)"; \
	fi; \
	printf '\n[STEP] Downloading python-build-standalone %s -> %s\n' "$(PYTHON_BUNDLE_VERSION)" "$(PYTHON_BUNDLE_TARBALL)"; \
	if ! curl -fsSL -o "$(PYTHON_BUNDLE_TARBALL)" "$(PYTHON_BUNDLE_URL)"; then \
	    echo "ERROR: download failed: $(PYTHON_BUNDLE_URL)" >&2; \
	    rm -f "$(PYTHON_BUNDLE_TARBALL)"; \
	    exit 1; \
	fi; \
	ACTUAL="$$(shasum -a 256 "$(PYTHON_BUNDLE_TARBALL)" | awk '{print $$1}')"; \
	if [ "$$ACTUAL" != "$$EXPECTED" ]; then \
	    echo "" >&2; \
	    echo "ERROR: python-build-standalone SHA-256 mismatch." >&2; \
	    echo "  expected: $$EXPECTED" >&2; \
	    echo "  actual:   $$ACTUAL" >&2; \
	    echo "  file:     $(PYTHON_BUNDLE_TARBALL)" >&2; \
	    rm -f "$(PYTHON_BUNDLE_TARBALL)"; \
	    exit 1; \
	fi; \
	printf '[OK] python-build-standalone verified: %s\n' "$$ACTUAL"

# ---------------------------------------------------------------------------
# CX-88 (DMG #48g): obtain the ostler-assistant daemon tarball and cache
# it under $(BUILD_DIR). Idempotent: re-runs skip work when the cached
# tarball is present (we trust the GitHub release artefact as source of
# truth + verify the version-string fingerprint at stage-daemon time).
#
# Lookup order:
#   1. $(DAEMON_TARBALL_CACHE) -- already cached in this BUILD_DIR
#   2. $(DAEMON_LOCAL_CACHE_DIR) -- operator-staged verified releases
#      at $$HOME/.ostler-release-artefacts/. Lets `make ship` complete
#      even when the public release at $(DAEMON_REPO)/$(DAEMON_RELEASE_TAG)
#      is not yet published (typical on signing-day before the release
#      workflow has finished).
#   3. `gh release download` -- uses active gh-auth account
#   4. curl + $$GH_TOKEN -- CI / scripted path
# ---------------------------------------------------------------------------
download-daemon:
	@mkdir -p "$(BUILD_DIR)"; \
	if [ -f "$(DAEMON_TARBALL_CACHE)" ]; then \
	    printf '[STEP] ostler-assistant cache hit: %s\n' "$(DAEMON_TARBALL_CACHE)"; \
	elif [ -f "$(DAEMON_LOCAL_CACHE_DIR)/$(DAEMON_TARBALL_NAME)" ]; then \
	    printf '[STEP] ostler-assistant local-cache hit: %s\n' "$(DAEMON_LOCAL_CACHE_DIR)/$(DAEMON_TARBALL_NAME)"; \
	    cp "$(DAEMON_LOCAL_CACHE_DIR)/$(DAEMON_TARBALL_NAME)" "$(DAEMON_TARBALL_CACHE)"; \
	    if [ -f "$(DAEMON_LOCAL_CACHE_DIR)/$(DAEMON_TARBALL_NAME).sha256" ]; then \
	        cp "$(DAEMON_LOCAL_CACHE_DIR)/$(DAEMON_TARBALL_NAME).sha256" "$(DAEMON_TARBALL_CACHE).sha256"; \
	    fi; \
	else \
	    printf '\n[STEP] Fetching ostler-assistant %s from %s\n' "$(DAEMON_RELEASE_TAG)" "$(DAEMON_REPO)"; \
	    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then \
	        if ! gh release download "$(DAEMON_RELEASE_TAG)" \
	                --repo "$(DAEMON_REPO)" \
	                --pattern "$(DAEMON_TARBALL_NAME)" \
	                --dir "$(BUILD_DIR)" \
	                --clobber; then \
	            echo "ERROR: gh release download failed for $(DAEMON_RELEASE_TAG)." >&2; \
	            echo "  Confirm the release is published at:" >&2; \
	            echo "    https://github.com/$(DAEMON_REPO)/releases/tag/$(DAEMON_RELEASE_TAG)" >&2; \
	            echo "  Or stage a verified tarball at:" >&2; \
	            echo "    $(DAEMON_LOCAL_CACHE_DIR)/$(DAEMON_TARBALL_NAME)" >&2; \
	            exit 1; \
	        fi; \
	    elif [ -n "$$GH_TOKEN" ]; then \
	        ASSET_API="https://api.github.com/repos/$(DAEMON_REPO)/releases/tags/$(DAEMON_RELEASE_TAG)"; \
	        ASSET_ID="$$(curl -fsSL -H "Authorization: Bearer $$GH_TOKEN" -H "Accept: application/vnd.github+json" "$$ASSET_API" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(a["id"] for a in d["assets"] if a["name"]=="$(DAEMON_TARBALL_NAME)"))')"; \
	        if [ -z "$$ASSET_ID" ]; then \
	            echo "ERROR: could not resolve asset id for $(DAEMON_TARBALL_NAME) in $(DAEMON_RELEASE_TAG)." >&2; \
	            exit 1; \
	        fi; \
	        curl -fsSL -H "Authorization: Bearer $$GH_TOKEN" -H "Accept: application/octet-stream" \
	             -o "$(DAEMON_TARBALL_CACHE)" \
	             "https://api.github.com/repos/$(DAEMON_REPO)/releases/assets/$$ASSET_ID"; \
	    else \
	        echo "ERROR: no daemon tarball available." >&2; \
	        echo "  Stage a verified tarball at $(DAEMON_LOCAL_CACHE_DIR)/$(DAEMON_TARBALL_NAME)" >&2; \
	        echo "  or install gh + run \`gh auth login\`," >&2; \
	        echo "  or export GH_TOKEN=<token-with-repo-scope> and retry." >&2; \
	        exit 1; \
	    fi; \
	fi; \
	if [ ! -s "$(DAEMON_TARBALL_CACHE)" ]; then \
	    echo "ERROR: $(DAEMON_TARBALL_CACHE) is missing or empty after download." >&2; \
	    rm -f "$(DAEMON_TARBALL_CACHE)"; \
	    exit 1; \
	fi; \
	EXPECTED="$(DAEMON_SHA256)"; \
	ACTUAL="$$(shasum -a 256 "$(DAEMON_TARBALL_CACHE)" | awk '{print $$1}')"; \
	if [ "$$ACTUAL" != "$$EXPECTED" ]; then \
	    echo "" >&2; \
	    echo "ERROR: ostler-assistant daemon SHA-256 mismatch (fail-closed)." >&2; \
	    echo "  expected: $$EXPECTED" >&2; \
	    echo "  actual:   $$ACTUAL" >&2; \
	    echo "  file:     $(DAEMON_TARBALL_CACHE)" >&2; \
	    echo "  This blocks shipping an unverified or wrong-version daemon. If you" >&2; \
	    echo "  intentionally bumped DAEMON_VERSION, update DAEMON_SHA256 to the new" >&2; \
	    echo "  hub-v$(DAEMON_VERSION) tarball's published .sha256 and retry." >&2; \
	    rm -f "$(DAEMON_TARBALL_CACHE)"; \
	    exit 1; \
	fi; \
	printf '[OK] ostler-assistant v%s cached + SHA-256 verified at %s\n' "$(DAEMON_VERSION)" "$(DAEMON_TARBALL_CACHE)"

# ---------------------------------------------------------------------------
# CX-88 (DMG #48g): extract the cached daemon tarball into
# ../assistant-agent/OstlerAssistant.app/ so the project.yml bundle phase
# picks it up at xcodebuild time and copies it into
# OstlerInstaller.app/Contents/Resources/assistant-agent/OstlerAssistant.app/.
#
# install.sh probes that path at section 3.10 (ASSISTANT_BUNDLED_APP) and
# prefers it over the GitHub curl fallback. With this step wired into
# the ship target, every DMG carries the daemon and no customer install
# falls through to the (private-repo, public-fetch-404) recovery path.
#
# Fingerprint check: greps the inner Mach-O for the v0.4.4 marker
# strings (OSTLER_IMESSAGE_BRIDGE_INBOX_ENABLE,
# OSTLER_IMESSAGE_SELF_HANDLES). If either is missing the wrong
# tarball is cached + the build fails loudly here rather than on the
# customer's Mac.
# ---------------------------------------------------------------------------
stage-daemon: download-daemon
	@SRC_DIR="$(CURDIR)/../assistant-agent"; \
	if [ ! -d "$$SRC_DIR" ]; then \
	    echo "ERROR: $$SRC_DIR not found." >&2; \
	    exit 1; \
	fi; \
	STAGE_TMP="$(BUILD_DIR)/daemon-extract"; \
	rm -rf "$$STAGE_TMP"; \
	mkdir -p "$$STAGE_TMP"; \
	printf '[STEP] Extracting %s into %s\n' "$(DAEMON_TARBALL_NAME)" "$$STAGE_TMP"; \
	tar xzf "$(DAEMON_TARBALL_CACHE)" -C "$$STAGE_TMP"; \
	if [ -d "$$STAGE_TMP/OstlerAssistant.app" ]; then \
	    DAEMON_PAYLOAD_SRC="$$STAGE_TMP/OstlerAssistant.app"; \
	    DAEMON_PAYLOAD_DEST="$$SRC_DIR/OstlerAssistant.app"; \
	    DAEMON_INNER_BIN="$$DAEMON_PAYLOAD_SRC/Contents/MacOS/ostler-assistant"; \
	elif [ -x "$$STAGE_TMP/ostler-assistant" ]; then \
	    DAEMON_PAYLOAD_SRC="$$STAGE_TMP/ostler-assistant"; \
	    DAEMON_PAYLOAD_DEST="$$SRC_DIR/bin/ostler-assistant"; \
	    mkdir -p "$$SRC_DIR/bin"; \
	    DAEMON_INNER_BIN="$$DAEMON_PAYLOAD_SRC"; \
	else \
	    echo "ERROR: daemon tarball at $(DAEMON_TARBALL_CACHE) contains neither" >&2; \
	    echo "  OstlerAssistant.app nor a bare ostler-assistant binary at the root." >&2; \
	    ls -la "$$STAGE_TMP" >&2; \
	    exit 1; \
	fi; \
	if [ ! -x "$$DAEMON_INNER_BIN" ]; then \
	    echo "ERROR: inner Mach-O missing or non-executable at $$DAEMON_INNER_BIN" >&2; \
	    exit 1; \
	fi; \
	printf '[STEP] Verifying v0.4.4 fingerprint strings in inner Mach-O\n'; \
	MISSING_STRINGS=""; \
	for marker in OSTLER_IMESSAGE_BRIDGE_INBOX_ENABLE OSTLER_IMESSAGE_SELF_HANDLES; do \
	    if ! strings "$$DAEMON_INNER_BIN" 2>/dev/null | grep -q "$$marker"; then \
	        MISSING_STRINGS="$$MISSING_STRINGS $$marker"; \
	    fi; \
	done; \
	if [ -n "$$MISSING_STRINGS" ]; then \
	    echo "" >&2; \
	    echo "ERROR: daemon tarball missing v0.4.4 fingerprint markers:$$MISSING_STRINGS" >&2; \
	    echo "  Either DAEMON_VERSION is wrong or the wrong tarball is cached at" >&2; \
	    echo "  $(DAEMON_TARBALL_CACHE). Refusing to bundle a daemon that lacks" >&2; \
	    echo "  these v0.4.4 features in the customer DMG." >&2; \
	    exit 1; \
	fi; \
	printf '[OK] daemon fingerprint markers present\n'; \
	rm -rf "$$DAEMON_PAYLOAD_DEST"; \
	cp -R "$$DAEMON_PAYLOAD_SRC" "$$DAEMON_PAYLOAD_DEST"; \
	chmod +x "$$DAEMON_INNER_BIN" 2>/dev/null || true; \
	/usr/bin/xattr -cr "$$DAEMON_PAYLOAD_DEST" 2>/dev/null || true; \
	printf '[OK] Staged daemon v%s at %s\n' "$(DAEMON_VERSION)" "$$DAEMON_PAYLOAD_DEST"

# ---------------------------------------------------------------------------
# Release build – Developer ID signed, exported to dist/
# ---------------------------------------------------------------------------
release: check-tools check-identity download-python
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
	# OSTLER_APP_PATH must be passed as an explicit build setting (not just an
	# exported env var) so xcodebuild's "Bundle install.sh / Ostler.app" script
	# phase sees it. xcodebuild scrubs the environment for PhaseScriptExecution;
	# only build settings reliably pass through. A regenerated project.yml-based
	# .xcodeproj does NOT bake OSTLER_APP_PATH in, so without this the hub-bundle
	# phase silently logs "OSTLER_APP_PATH not set" and the DMG ships Hub-less
	# (caught by verify-dmg-contents). See 2026-06-19 cut.
	xcodebuild \
	    -project $(PROJECT) \
	    -scheme $(SCHEME) \
	    -configuration Release \
	    -archivePath "$(ARCHIVE_PATH)" \
	    -derivedDataPath $(DERIVED_DATA) \
	    DEVELOPMENT_TEAM=$(TEAM_ID) \
	    CODE_SIGN_STYLE=Manual \
	    CODE_SIGN_IDENTITY="$(CODESIGN_ID)" \
	    OSTLER_APP_PATH="$(OSTLER_APP_PATH)" \
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
# Sign every Mach-O inside the bundled Python tree with hardened runtime.
#
# CX-20 (launch blocker, 2026-05-23): DMG #17 notarytool rejected with
# "The executable does not have the hardened runtime enabled" for
# Contents/Resources/python/bin/python3.11. xcodebuild's --deep re-sign
# at archive time signs embedded binaries with the Developer ID identity
# but does NOT enable hardened runtime on them -- only the main app
# target gets --options runtime from xcodebuild build settings. Apple
# requires hardened runtime on every Mach-O for notarisation.
#
# This step runs AFTER release (which produces the signed .app at
# $(APP_PATH)) and BEFORE package (which makes the DMG), so the
# hardened-runtime signatures are inside the DMG when notarytool
# scans it.
#
# Re-signs the outer .app at the end so the outer signature seals
# the new inner signatures.
# ---------------------------------------------------------------------------
sign-python-bundle:
	$(STEP) "Signing bundled Python Mach-O files with hardened runtime"
	@bash scripts/sign-python-bundle.sh "$(APP_PATH)" "$(CODESIGN_ID)"
	$(STEP) "Signing bundled assistant daemon with hardened runtime"
	# CX-124 (launch blocker, 2026-06-07): notarytool rejected the DMG with
	# "The executable does not have the hardened runtime enabled" for
	# Contents/Resources/assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant
	# (submission 213e1ba8). Same root cause as CX-20 for python3.11: the daemon
	# arrives from the ostler-releases tarball signed Developer ID but WITHOUT
	# --options runtime (flags=0x0), and the outer --force --deep reseal below does
	# NOT add hardened runtime to nested Mach-Os. Sign the daemon binary + its .app
	# wrapper explicitly here, before the outer reseal seals them. Same entitlements
	# file as python3.11/outer .app for uniform runtime+entitlements state.
	@DAEMON_APP="$(APP_PATH)/Contents/Resources/assistant-agent/OstlerAssistant.app"; \
	if [ -d "$$DAEMON_APP" ]; then \
	    codesign --force --sign "$(CODESIGN_ID)" --options runtime --timestamp \
	        --entitlements "OstlerInstaller/OstlerInstaller.entitlements" \
	        "$$DAEMON_APP/Contents/MacOS/ostler-assistant"; \
	    codesign --force --sign "$(CODESIGN_ID)" --options runtime --timestamp \
	        --entitlements "OstlerInstaller/OstlerInstaller.entitlements" \
	        "$$DAEMON_APP"; \
	    echo "  signed daemon with hardened runtime: $$DAEMON_APP"; \
	else \
	    echo "  no bundled daemon at $$DAEMON_APP -- skipping (standalone sign run)"; \
	fi
	$(STEP) "Re-signing outer .app to seal inner Python signatures"
	# CX-33 (2026-05-24): --entitlements MUST be passed here, otherwise the
	# --force --deep re-sign STRIPS the disable-library-validation entitlement
	# that sign-python-bundle.sh just applied to python3.11 -- and the customer
	# install dies at encrypt_db with the cryptography Team-ID-mismatch error
	# (Studio retest #20 trail). Same entitlements file as the outer .app uses,
	# so the runtime + entitlements state is uniform across every Mach-O.
	# Without this CX-30's fix gets undone before the DMG is even packaged.
	codesign --force --deep --sign "$(CODESIGN_ID)" --options runtime --timestamp --entitlements "OstlerInstaller/OstlerInstaller.entitlements" "$(APP_PATH)"
	codesign --verify --deep --strict --verbose=2 "$(APP_PATH)"
	@echo "Post-sign verify: python3.11 entitlements (must include disable-library-validation)"
	@codesign -d --entitlements :- "$(APP_PATH)/Contents/Resources/python/bin/python3.11" 2>&1 | grep -q "disable-library-validation" \
		&& echo "  ✓ disable-library-validation present on bundled python3.11" \
		|| (echo "  ✗ disable-library-validation MISSING from python3.11 -- DMG will fail at encrypt_db on customer Mac"; exit 1)
	@echo "Post-sign verify: assistant daemon hardened runtime (must be enabled)"
	@DAEMON_BIN="$(APP_PATH)/Contents/Resources/assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant"; \
	if [ -f "$$DAEMON_BIN" ]; then \
	    codesign -dvvv "$$DAEMON_BIN" 2>&1 | grep -Eq "flags=.*runtime" \
	        && echo "  ✓ hardened runtime present on bundled daemon" \
	        || (echo "  ✗ hardened runtime MISSING from bundled daemon -- DMG will fail notarisation"; exit 1); \
	fi

# ---------------------------------------------------------------------------
# Hard prerequisite for `make ship`. Refuses to proceed when
# OSTLER_APP_PATH is empty or not a directory. Previously this was a
# soft warn at sparkle-embed time, which combined with xcodebuild's
# silent-skip on a missing bundle phase input to ship a DMG without
# the Tauri Ostler.app inside Resources/ (2026-05-21 incident).
#
# A standalone `make sparkle-embed` is still allowed to soft-skip
# (preserves the "safe to run by hand" property); only ship-path
# invocation hard-fails via this gate.
check-ostler-app:
	@if [ -z "$(OSTLER_APP_PATH)" ]; then \
	    echo "" >&2; \
	    echo "ERROR: OSTLER_APP_PATH is empty." >&2; \
	    echo "" >&2; \
	    echo "  Shipping a DMG without the Tauri Ostler.app inside Resources/ produces" >&2; \
	    echo "  a Hub-less installer (install.sh hits 'Ostler.app not found' at customer" >&2; \
	    echo "  install time). The 2.58MB DMG cut on 2026-05-21 had exactly this shape." >&2; \
	    echo "" >&2; \
	    echo "  Most likely cause: a parent shell exported OSTLER_APP_PATH= (empty string)," >&2; \
	    echo "  which defeats the \`?=\` default. Unset it first or pass an explicit value:" >&2; \
	    echo "" >&2; \
	    echo "    unset OSTLER_APP_PATH && make ship" >&2; \
	    echo "    OSTLER_APP_PATH=/path/to/Ostler.app make ship" >&2; \
	    echo "" >&2; \
	    exit 1; \
	fi
	@if [ ! -d "$(OSTLER_APP_PATH)" ]; then \
	    echo "" >&2; \
	    echo "ERROR: OSTLER_APP_PATH points at a path that does not exist:" >&2; \
	    echo "  $(OSTLER_APP_PATH)" >&2; \
	    echo "" >&2; \
	    echo "  Build the Tauri Hub desktop first:" >&2; \
	    echo "    cd ~/Documents/Projects/ostler-assistant" >&2; \
	    echo "    cargo tauri build" >&2; \
	    echo "" >&2; \
	    echo "  Or point at an existing build:" >&2; \
	    echo "    OSTLER_APP_PATH=/path/to/Ostler.app make ship" >&2; \
	    echo "" >&2; \
	    exit 1; \
	fi
	@printf '[CHECK] OSTLER_APP_PATH=%s (directory exists)\n' "$(OSTLER_APP_PATH)"

sparkle-embed:
	@if [ ! -d "$(OSTLER_APP_PATH)" ]; then \
	    echo "WARNING: OSTLER_APP_PATH=$(OSTLER_APP_PATH) not found; skipping Sparkle embed." >&2; \
	    echo "         (For ship-path invocation use \`make ship\` — its check-ostler-app" >&2; \
	    echo "          prereq turns this into a hard fail.)" >&2; \
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
# ---------------------------------------------------------------------------
# Cut-provenance preflight -- UNBYPASSABLE gate on the DMG.
# Proves every fix merged to a source main is present in this tree + the pinned
# daemon tag before we seal the DMG. This is why v0.4.8's dead-chat daemon and
# stale-vendored Doctor cannot ship again: package depends on this, so a RED
# provenance check aborts the cut. Ledger: ../scripts/cut_markers.manifest.
# ---------------------------------------------------------------------------
check-provenance:
	$(STEP) "Cut-provenance preflight (DMG)"
	@OSTLER_ASSISTANT_DIR="$${OSTLER_ASSISTANT_DIR:-$(CURDIR)/../../ostler-assistant}" \
	    ../scripts/verify_cut_provenance.sh || { \
	    echo "" >&2; \
	    echo "ERROR: cut-provenance preflight FAILED -- a merged fix is stale/missing." >&2; \
	    echo "Fix the FAILs above (graft vendor / re-tag daemon), then re-cut. DO NOT SHIP." >&2; \
	    exit 1; \
	}

# ---------------------------------------------------------------------------
# Cut-freshness preflight (DMG). Compares EVERY shippable input (vendor pins,
# daemon, wiki images) to its LIVE upstream GitHub HEAD and hard-fails the cut
# if anything lags -- the structural cure for "built but not in the cut". This
# runs BEFORE check-provenance: provenance proves named fixes are present;
# freshness proves nothing has silently fallen behind live HEAD at all. Any
# non-zero (RED stale, or exit 3 CANNOT-VERIFY when GitHub is unreachable)
# aborts the cut fail-closed.
# ---------------------------------------------------------------------------
check-freshness:
	$(STEP) "Cut-freshness preflight (live GitHub HEAD)"
	@../scripts/verify_cut_freshness.sh || { \
	    echo "" >&2; \
	    echo "ERROR: cut-freshness preflight FAILED -- a shippable input lags live upstream HEAD" >&2; \
	    echo "       (or could not be verified against GitHub). Re-pin / re-vendor / rebuild each" >&2; \
	    echo "       RED input to current HEAD, then re-cut. DO NOT SHIP." >&2; \
	    exit 1; \
	}

package: check-tools check-identity check-create-dmg check-freshness check-provenance
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
# Post-ship verification: mount the DMG and assert the assembled payload
# contains every component install.sh expects. Catches the silent-skip
# failure mode (xcodebuild bundle phase or sparkle-embed dropped an input)
# at ship time instead of at customer install time.
#
# The shape we assert is the EXACT failure shape from 2026-05-21: a DMG
# missing Ostler.app inside Resources/ ships a Hub-less installer. We also
# walk install.sh for the RemoteCapture wiring contract (repo + version +
# URL pattern) so a future regression on PR #133 fails here too. Per locked
# memory feedback_silent_bail_regression_test_shape, the assertion is
# byte-by-byte on the assembled output, not happy-path observable.
# ---------------------------------------------------------------------------
verify-dmg-contents:
	@if [ ! -f "$(DMG_PATH)" ]; then \
	    echo "ERROR: $(DMG_PATH) not found. Run \`make ship\` first." >&2; \
	    exit 1; \
	fi
	$(STEP) "Verifying assembled DMG payload — checking for silent-skip regressions"
	@MOUNT=$$(hdiutil attach "$(DMG_PATH)" -nobrowse -readonly 2>&1 | tail -1 | awk -F'\t' '{print $$NF}'); \
	if [ -z "$$MOUNT" ] || [ ! -d "$$MOUNT" ]; then \
	    echo "ERROR: could not mount $(DMG_PATH)" >&2; \
	    exit 1; \
	fi; \
	RES="$$MOUNT/$(APP_NAME).app/Contents/Resources"; \
	MISSING=""; \
	for p in Ostler.app install.sh ostler_security ostler_fda doctor hub-power assistant_api cm024_knowledge cm048_pipeline cm019_preferences cm021 contact_syncer meeting_syncer identity_resolver email-ingest imessage-bridge whatsapp_source email_source spoken_source imessage_source assistant-agent; do \
	    if [ ! -e "$$RES/$$p" ]; then MISSING="$$MISSING $$p"; fi; \
	done; \
	OSTLER_APP_OK=1; \
	if [ ! -x "$$RES/Ostler.app/Contents/MacOS/zeroclaw-desktop" ]; then \
	    OSTLER_APP_OK=0; \
	fi; \
	HUB_SHA="$$(strings "$$RES/Ostler.app/Contents/MacOS/zeroclaw-desktop" 2>/dev/null | grep -oE 'OSTLER_HUB_BUILD_SHA=[0-9a-f]{40}' | head -1 | cut -d= -f2)"; \
	INSTALL_SH_OK=1; \
	if ! grep -q "OSTLER_REMOTECAPTURE_REPO:-ostler-ai/ostler-releases" "$$RES/install.sh" 2>/dev/null; then \
	    INSTALL_SH_OK=0; \
	fi; \
	if ! grep -q "releases/download/remote-capture-v" "$$RES/install.sh" 2>/dev/null; then \
	    INSTALL_SH_OK=0; \
	fi; \
	DAEMON_INNER_BIN="$$RES/assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant"; \
	if [ ! -x "$$DAEMON_INNER_BIN" ]; then \
	    DAEMON_INNER_BIN="$$RES/assistant-agent/bin/ostler-assistant"; \
	fi; \
	DAEMON_OK=1; \
	DAEMON_FP_OK=1; \
	if [ ! -x "$$DAEMON_INNER_BIN" ]; then \
	    DAEMON_OK=0; \
	else \
	    for marker in OSTLER_IMESSAGE_BRIDGE_INBOX_ENABLE OSTLER_IMESSAGE_SELF_HANDLES; do \
	        if ! strings "$$DAEMON_INNER_BIN" 2>/dev/null | grep -q "$$marker"; then \
	            DAEMON_FP_OK=0; \
	        fi; \
	    done; \
	fi; \
	DAEMON_SIGN_OK=1; \
	DAEMON_APP_M="$$RES/assistant-agent/OstlerAssistant.app"; \
	DAEMON_SIGN_TGT="$$DAEMON_APP_M"; \
	[ -d "$$DAEMON_APP_M" ] || DAEMON_SIGN_TGT="$$DAEMON_INNER_BIN"; \
	if [ -e "$$DAEMON_SIGN_TGT" ]; then \
	    codesign -dvv "$$DAEMON_SIGN_TGT" 2>&1 | grep -q "Authority=Developer ID Application: Creative Machines Limited" || DAEMON_SIGN_OK=0; \
	    codesign -dvv "$$DAEMON_SIGN_TGT" 2>&1 | grep -q "TeamIdentifier=$(TEAM_ID)" || DAEMON_SIGN_OK=0; \
	    codesign -dvvv "$$DAEMON_SIGN_TGT" 2>&1 | grep -E "^CodeDirectory" | grep -q "runtime" || DAEMON_SIGN_OK=0; \
	else \
	    DAEMON_SIGN_OK=0; \
	fi; \
	hdiutil detach "$$MOUNT" >/dev/null 2>&1 || true; \
	if [ -n "$$MISSING" ]; then \
	    echo "ERROR: DMG payload missing in Resources/:$$MISSING" >&2; \
	    echo "  This is the silent-warn-skip pattern caught 2026-05-21." >&2; \
	    echo "  Likely cause: xcodebuild bundle phase or sparkle-embed skipped" >&2; \
	    echo "  silently. The check-ostler-app prereq should have caught this" >&2; \
	    echo "  upstream — investigate why it did not." >&2; \
	    exit 1; \
	fi; \
	if [ "$$OSTLER_APP_OK" = "0" ]; then \
	    echo "ERROR: Ostler.app present in Resources/ but missing the Tauri" >&2; \
	    echo "       executable at Contents/MacOS/zeroclaw-desktop." >&2; \
	    exit 1; \
	fi; \
	if [ -z "$$HUB_SHA" ]; then \
	    echo "ERROR: bundled Hub binary carries no OSTLER_HUB_BUILD_SHA marker." >&2; \
	    echo "       This is a STALE / pre-marker Ostler.app (the 2026-06-03 P0:" >&2; \
	    echo "       a fresh binary was on disk but make ship bundled an old one)." >&2; \
	    echo "       Rebuild Ostler.app from current ostler-assistant origin/main" >&2; \
	    echo "       (build.rs stamps the marker) and re-cut." >&2; \
	    exit 1; \
	fi; \
	if [ -n "$(OSTLER_HUB_EXPECTED_SHA)" ] && [ "$$HUB_SHA" != "$(OSTLER_HUB_EXPECTED_SHA)" ]; then \
	    echo "ERROR: bundled Hub build-SHA does not match the expected rebuild." >&2; \
	    echo "       bundled:  $$HUB_SHA" >&2; \
	    echo "       expected: $(OSTLER_HUB_EXPECTED_SHA) (ostler-assistant origin/main)" >&2; \
	    echo "       make ship sourced a different Ostler.app than intended (Bug A)." >&2; \
	    exit 1; \
	fi; \
	if [ "$$INSTALL_SH_OK" = "0" ]; then \
	    echo "ERROR: install.sh on the DMG does not wire RemoteCapture against" >&2; \
	    echo "       the public ostler-ai/ostler-releases CDN URL. Regression" >&2; \
	    echo "       of CM051 PR #133. Customer install would 404 on download." >&2; \
	    exit 1; \
	fi; \
	if [ "$$DAEMON_OK" = "0" ]; then \
	    echo "ERROR: ostler-assistant daemon binary not bundled in DMG Resources/assistant-agent/." >&2; \
	    echo "       Expected either OstlerAssistant.app/Contents/MacOS/ostler-assistant" >&2; \
	    echo "       or bin/ostler-assistant. The stage-daemon Makefile step is" >&2; \
	    echo "       responsible for staging the v$(DAEMON_VERSION) tarball into" >&2; \
	    echo "       ../assistant-agent/ before xcodebuild runs (CX-88)." >&2; \
	    exit 1; \
	fi; \
	if [ "$$DAEMON_FP_OK" = "0" ]; then \
	    echo "ERROR: daemon binary inside DMG missing v0.4.4 fingerprint markers" >&2; \
	    echo "       (OSTLER_IMESSAGE_BRIDGE_INBOX_ENABLE / OSTLER_IMESSAGE_SELF_HANDLES)." >&2; \
	    echo "       The wrong tarball is bundled; check DAEMON_VERSION and the" >&2; \
	    echo "       cached tarball at $(DAEMON_TARBALL_CACHE)." >&2; \
	    exit 1; \
	fi; \
	if [ "$$DAEMON_SIGN_OK" = "0" ]; then \
	    echo "ERROR: bundled daemon is NOT Developer-ID signed + hardened-runtime (Team $(TEAM_ID))." >&2; \
	    echo "       The ostler-releases tarball is adhoc/linker-signed; sign-python-bundle must" >&2; \
	    echo "       re-sign it Developer-ID --options runtime before packaging (CX-124 / step-4 gate)." >&2; \
	    echo "       An adhoc daemon fails Apple notarisation AND Gatekeeper on the customer Mac." >&2; \
	    exit 1; \
	fi; \
	echo "[OK] DMG payload verified -- Ostler.app + install.sh + all vendor packages + Developer-ID hardened-runtime daemon present (Hub build-SHA $$HUB_SHA)"

# ---------------------------------------------------------------------------
# One-shot: validate → build → DMG → notarise → staple → verify → archive
#
# check-ostler-app runs first so we fail fast on the empty/missing
# OSTLER_APP_PATH case (caught 2026-05-21 — would have saved one DMG cut).
# verify-dmg-contents runs between notarise and archive so any silent-skip
# regression downstream of check-ostler-app fails before we archive a bad
# DMG into ~/.ostler-release-artefacts/.
# ---------------------------------------------------------------------------
ship: check-ostler-app download-python stage-daemon sparkle-embed release sign-python-bundle package notarise verify-dmg-contents archive
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
