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
# OSTLER_APP_PATH is exported further down, AFTER its `?=` default.
# That order is load-bearing -- see the block above the assignment.

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
# Sparkle.framework + SU* keys stamped in. Override at make time or in CI to
# point at the notarised bundle produced by a release workflow:
#     make OSTLER_APP_PATH=/path/to/Ostler.app ship
#
# WHY THIS IS DERIVED AND NOT A HOME-DIRECTORY LITERAL (v1018-D668)
#
# The default used to be a hardcoded $(HOME)/Documents/Projects/... path. That
# tree was superseded when the repos moved to ~/Developer, and by 2026-08-13 it
# was a month stale AND had no bundle in it at all:
#
#   ~/Documents/Projects/ostler-assistant   last commit 2026-07-12, Ostler.app ABSENT
#   ~/Developer/ostler-assistant            last commit 2026-08-12, Ostler.app PRESENT
#
# That matters more than a broken path usually would, because a missing
# OSTLER_APP_PATH is deliberately NON-FATAL for `make package`: it warns and
# cuts the DMG anyway. So the default silently produced a Hub-less DMG, and the
# customer met it as install.sh's "Ostler.app not found" at run time. A default
# that cannot work should not be a default.
#
# Derived from this checkout's location instead, so it follows the repo rather
# than one operator's home layout: ostler-assistant is a sibling of the
# installer repo. Works from ~/Developer, from a worktree, from CI, and carries
# no operator path into a shipping tree.
_CM051_ROOT      := $(abspath $(CURDIR)/..)
OSTLER_APP_PATH  ?= $(abspath $(_CM051_ROOT)/../ostler-assistant)/target/release/bundle/macos/Ostler.app

# EXPORT MUST COME AFTER THE `?=` ABOVE. THIS ORDER IS THE WHOLE BUG (D668).
#
# A bare `export VAR` DEFINES VAR (origin becomes "file"), and `?=` assigns only
# when a variable is UNDEFINED. So `export OSTLER_APP_PATH` sitting above the
# default meant the default never applied -- not once, on any version of this
# file. Measured on GNU Make 3.81, the make macOS ships:
#
#   export FOO / FOO ?= default   ->  origin=file  value=[]            <- broken
#   FOO ?= default / export FOO   ->  origin=file  value=[default]     <- works
#
# So the stale ~/Documents/Projects path was a red herring: it was never
# resolved, because nothing ever resolved. `make package` treats a missing
# OSTLER_APP_PATH as non-fatal and cuts the DMG anyway, so the visible symptom
# was a Hub-less DMG, and the Makefile's own error text blames "a parent shell
# exported OSTLER_APP_PATH= (empty string)" -- misdiagnosing its own bug.
#
# tests/test_makefile_app_path_default.sh pins the order and the value.
export OSTLER_APP_PATH

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
# Cut-manifest to verify against (#238). verify_cut_manifest.py auto-selects the
# lexicographically-newest cut-manifests/v*.yaml when no --version is passed --
# which mis-fires on a hotfix: cutting v1.0.13.1 with a staged v1.0.14.yaml
# present, the gate silently verified against v1.0.14 (the next cut's forward
# manifest) instead of the v1.0.13 line. Derive the BASE major.minor.patch from
# the installer version (1.0.13.1 -> v1.0.13) and pass it explicitly so a hotfix
# always selects its own line's manifest. Operator override wins; set empty to
# fall back to the auto-select behaviour.
CUT_MANIFEST_VERSION ?= v$(shell printf '%s' "$(VERSION)" | cut -d. -f1-3)
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
DAEMON_VERSION       ?= 0.4.62
# SHA-256 of the published hub-v$(DAEMON_VERSION) tarball
# (ostler-assistant-aarch64-apple-darwin-v$(DAEMON_VERSION).tar.gz). Verified
# fail-closed in download-daemon: a mismatch deletes the file + aborts the cut,
# so an unverified / wrong-version daemon can never reach the DMG. Bump in
# lockstep with DAEMON_VERSION from the release's published .sha256 sidecar.
# v1.0.13.1 recut (2026-07-31 ORM): hub-v0.4.44 = 6ff1bb2dcb30 = graft/hub-v0.4.43
# + 4 daemon box-walk fixes (#208 Doctor-paired, #229 dead path, #220 first-ingest,
# #222 brand rename) + /api/v1/frontpage/cards + #226 commit-parity sentinels +
# 9 SPA reconciliations (GovernorWelcomeModal supersedes FirstRunPopup, Front Page
# unified, #209 6-digit pairing block provably absent). Signed + notarised +
# stapled at build time (submission a7db175d-8e26).
# v1.0.13.2 recut (2026-08-01 ORM): hub-v0.4.45 = c638a6d7ec88 = hub-v0.4.44
# + 5 red-severity Path D fixes: R6 install-log noise cleanup (#173), R1 frontpage
# cards serve pre-pair welcome cards not 401, R5 SETTLED phase requires
# companion_paired (subsumes R2 Governor modal timing), R3 crop MkDocs Andypedia
# black bar from wiki iframe. Signed + notarised + stapled at build time
# (submission 4c8a2fdb-1049). R4 wiki SETTING-UP typography deferred to v1.0.13.3
# per CM044 namespace mystery (HR015 task #249).
# v1.0.27 (2026-08-15 ORM): 0.4.56 -> 0.4.57, daemon commit acf991bf -> 723c682f.
# MEASURED FROM THE PUBLISHED BYTES, not from a release page or a sidecar name.
# The daemon and the Hub app live in DIFFERENT repositories and this is the trap
# worth naming: ostler-ai/ostler-assistant publishes ONLY the Hub app at .56 and
# .57 (hub-v0.4.55 is the last tag there carrying a daemon tarball), while the
# daemon ships from $(DAEMON_REPO). Reading the wrong repo makes a correct pin
# look like a missing artefact. Verified per side against the published .sha256:
#   ostler-releases  hub-v0.4.57  ostler-assistant-...-v0.4.57.tar.gz  f311519a
#   ostler-assistant hub-v0.4.57  ostler-hub-app-...-v0.4.57.tar.gz    d1b7f828
# Commit parity re-derived rather than inherited: BOTH build-info.json files
# report commit 723c682fd7b44b87e3769adfd2db2fdf59f5dadd, so the daemon and the
# Hub app are the same line, which is what verify-commit-parity asserts.
DAEMON_SHA256        ?= ee1b01610d90a8c530430a1102626c736540f21c7be7b887e348104f1f0786cd
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

# ---------------------------------------------------------------------------
# HUB APP (Ostler.app, the Tauri desktop wrapper) -- task #332
#
# WHY THIS BLOCK EXISTS. Ostler.app was built only on the operator's Mac and
# published nowhere, so OSTLER_APP_PATH's sibling-checkout default is a path
# that CANNOT exist on a hosted runner. Every tagged cut since 2026-08-08 died
# on exactly that, eight runs across v1.0.23/24/25:
#
#   ERROR: OSTLER_APP_PATH points at a path that does not exist:
#     /Users/runner/work/CM051-Home-Hub-Installer/ostler-assistant/...
#   make: *** [check-ostler-app] Error 1
#
# check-ostler-app failing there is CORRECT and must stay a hard failure: a
# missing Hub app used to be non-fatal and shipped a silently Hub-less DMG
# (v1018-D668). The defect was never the gate, it was that the artefact the
# gate demands had no published home. So this fetches it rather than
# loosening the check.
#
# The tag is shared with the daemon deliberately. Both artefacts are built
# from ONE commit and published to ONE release, which is what makes the
# existing verify-commit-parity check meaningful; a separate hub tag would let
# the pair drift apart again (the #225 defect).
#
# Staleness is NOT this target's job. When the operator already has a local
# bundle it is used as-is and verify-commit-parity is what catches it being
# from the wrong commit. Two gates for one property is how a gate ends up
# trusted and wrong.
# ---------------------------------------------------------------------------
HUB_APP_REPO         ?= ostler-ai/ostler-assistant
HUB_APP_TARBALL_NAME := ostler-hub-app-$(DAEMON_TARGET)-v$(DAEMON_VERSION).tar.gz
HUB_APP_TARBALL_CACHE := $(BUILD_DIR)/$(HUB_APP_TARBALL_NAME)
# SHA-256 of the published hub app tarball. Verified fail-closed, exactly as
# DAEMON_SHA256 is: a mismatch deletes the file and aborts the cut, so an
# unverified or wrong-version Ostler.app can never reach the DMG. Bump in
# lockstep with DAEMON_VERSION from the release's published .sha256 sidecar.
#
# 2026-08-15: this pin was a version behind DAEMON_VERSION. It held
# e074d6fd...c2f62bf, which is MEASURABLY the v0.4.55 digest -- byte-identical
# to the published hub-v0.4.55 sidecar -- while DAEMON_VERSION said 0.4.56, and
# nothing at all was published at hub-v0.4.56 on $(HUB_APP_REPO). The fetch path
# was therefore dead: download-hub-app would delete the tarball and abort. It
# went unnoticed because the fetch path is never taken on the operator's Mac,
# where the sibling checkout's bundle is used as-is. Now re-pinned to the
# published hub-v0.4.56 Ostler.app, built from ostler-assistant acf991bf (the
# same commit as the v0.4.56 daemon, so verify-commit-parity stays meaningful).
# v1.0.27 (2026-08-15 ORM): re-pinned in lockstep to the published hub-v0.4.57
# Ostler.app, d1b7f828, built from 723c682f -- the SAME commit as the v0.4.57
# daemon above, so verify-commit-parity keeps its meaning. The bundle is adhoc
# signed and deliberately NOT notarised: the cut re-signs it via embed-sparkle.sh
# codesign --force --deep with the Developer ID, which would discard any earlier
# ticket. Read from the release's own .sha256 sidecar, not from a build log.
HUB_APP_SHA256       ?= 6b73408823f52eb1b0fc8b4af9fc353143ff890519de8a1c333bc7bbb6ee62ae

# ---------------------------------------------------------------------------
# SAFARI EXTENSION (CM020) -- the third artefact the cut cannot build itself.
#
# The v1.0.26 cut got all the way into xcodebuild archive and died at:
#
#   error: vendor/extensions/OstlerSafariExtension.app.zip is missing.
#          W8 / F6: ORM must build + sign + notarise + stage the Safari
#          extension before the .app build.
#
# Exactly the Hub app problem one artefact later: a payload that only ever
# existed on the operator's Mac, so a hosted runner has nothing to bundle.
# Same remedy, deliberately: fetch the published artefact, verify SHA-256
# fail-closed, and no-op when the operator has already staged one.
#
# NOT REBUILT HERE, and that is a decision rather than an omission. The
# extension is signed AND notarised with the Developer ID; rebuilding it in the
# cut would need CM020 source (absent from the build Mac) and would re-sign an
# artefact that Apple has already notarised. Fetching the notarised bytes is
# the honest move; the ship chain re-staples nested apps in two rounds anyway
# (see staple-apps).
#
# TWO KNOWN DEFECTS IN THE ARTEFACT, recorded so neither is discovered twice:
#   * the inner bundle is SafariHistoryExt.app / com.creativemachines.
#     SafariHistoryExt -- the PRE-REBRAND name, and it is customer-visible in
#     Safari's extension list. Same class as #263 (zeroclaw-desktop). Needs a
#     CM020 rebuild, which is its own cycle.
#   * it carries no stapled ticket on its own. Expected for a pre-cut input.
# Publishing the artefact the last good cut used makes neither worse.
# ---------------------------------------------------------------------------
SAFARI_EXT_REPO    ?= $(HUB_APP_REPO)
SAFARI_EXT_NAME    := OstlerSafariExtension.app.zip
SAFARI_EXT_DEST    := $(_CM051_ROOT)/vendor/extensions/$(SAFARI_EXT_NAME)
SAFARI_EXT_SHA256  ?= 87f82a29eb4a4c1e13ddc694335747163f0f76fb4e055717b76219351534c69a
# PINNED INDEPENDENTLY OF DAEMON_VERSION, and that is the whole point of this
# variable existing.
#
# This fetch used to read $(DAEMON_RELEASE_TAG). That is correct for the hub
# app -- see the HUB APP block above, where sharing the daemon's tag is what
# makes verify-commit-parity meaningful -- but it is wrong here, because the
# parity argument does not apply to this artefact at all. The extension is
# built from CM020, not from ostler-assistant, and is NOT rebuilt by the cut
# (see the "NOT REBUILT HERE" note above). It therefore has no commit
# relationship to the daemon, and nothing about a daemon bump changes these
# bytes.
#
# What the coupling actually did: because the tag was DERIVED from
# DAEMON_VERSION, bumping the daemon silently redirected this fetch at a tag
# that does not carry the extension, while leaving SAFARI_EXT_SHA256 pointing
# at bytes published under the old one. Measured 2026-08-15 after the 0.4.56
# re-pin (#681): hub-v0.4.56 does not exist in $(SAFARI_EXT_REPO), so this
# target 404s. Every future daemon bump re-breaks it the same way, which is
# the class of defect a version number should never be able to cause.
#
# Pinned to the release that actually carries the asset. Bump this ONLY when
# CM020 publishes a new extension build, alongside SAFARI_EXT_SHA256 -- the
# two move together because they describe the same bytes.
SAFARI_EXT_TAG     ?= hub-v0.4.55

# ---------------------------------------------------------------------------
# AU-1 (auto-update): APPCAST PUBLISH.
#
# THE DEFECT THIS EXISTS TO CLOSE. Three pieces make auto-update work. Two of
# them were built and connected; the third was built and never called.
#
#   1. the Sparkle updater inside the Hub app   SHIPPING (see sparkle-embed)
#   2. the appcast feed it polls                LIVE, and answering
#   3. the step that PUBLISHES a release
#      INTO that feed                           BUILT IN CM050, NEVER CALLED
#
# MEASURED on CM051 origin/main before this change, whole repo, over
# Makefile / *.mk / *.sh / *.yml:
#
#     publish-appcast | PUBLISH_APPCAST | ostler-release publish     0 hits
#     sparkle-embed          (positive control, same search style)  14 hits
#     notarise               (positive control, same search style) 124 hits
#
# The controls matter: a zero from a search that finds nothing anywhere is a
# broken search, and this one was not. The zero is real.
#
# CONSEQUENCE OF THE ZERO. Every installed Hub polls the feed, receives a
# well-formed answer listing no release newer than its own, and stays on its
# version for ever. No error, no log line, nothing red. A bug that ships is
# permanent for whoever installed it, because the road back to them was never
# built. That is what this block connects.
#
# CONTROL -- PUBLISH_APPCAST:
#   1|yes (DEFAULT since 2026-08-17) hard-require: fail the cut if the key or
#         the CLI is missing. See WHY THE DEFAULT CHANGED below.
#   auto  publish IFF $OSTLER_SPARKLE_SIGNING_KEY is set; if unset, warn and
#         exit 0. This was the default and it is why the feed is empty. Kept
#         ONLY for deliberate installer-only builds, and it must now be asked
#         for by name.
#
# WHY THE DEFAULT CHANGED, measured 2026-08-17:
#   `auto` + no key = warning + `exit 0`. Every cut therefore reported
#   success while publishing nothing. The appcast serves HTTP 200 with a
#   valid Sparkle feed containing ZERO items, so every installed Hub asks
#   for updates, is correctly told there are none, and can never upgrade.
#   No component was broken. The pipeline was never armed, and it was built
#   to treat that as acceptable.
#
#   The warning even said so: "The DMG shipped, but NO appcast entry was
#   added ... installed Hubs will never see it." A warning nobody is forced
#   to read is not a control. The owner has done a full 70-minute reinstall
#   on every release because of this.
#
#   A publish that is ATTEMPTED and then errors still FAILS the cut. That
#   half was always right. Fail-closed, now from the first cut rather than
#   once somebody remembers to opt in.
#   0|no  skip silently (local installer-only builds).
#
# >>> NEEDS ANDY (two real-world prerequisites this Makefile cannot create) <<<
#   1. OSTLER_SPARKLE_SIGNING_KEY -> path to the DECRYPTED Sparkle EdDSA PEM
#      (mode 0400/0600), present only during a cut. See CM050
#      appcast-server/docs/RELEASE_PROCESS.md (key ceremony + signing session).
#   2. The R2 bucket + RELEASES_HOST behind the download_url, plus wrangler
#      auth on the cut machine. This Makefile never invokes wrangler itself;
#      the CM050 CLI does, from $(OSTLER_APPCAST_DIR).
# ---------------------------------------------------------------------------
# PUBLISH_APPCAST modes. `onbox` is the mode CI uses and it is DELIBERATE.
#
#   1 / yes   HARD-REQUIRE the signing key. Publish, or fail. This is the
#             right default for a LOCAL cut on the box, where the key exists
#             and re-running costs minutes.
#   onbox     DO NOT publish here, and say so loudly. The cut is complete and
#             the appcast is OWED. Exits 0, because a CI cut that produced a
#             good DMG is not a failed cut.
#   0/no/off  Silent skip. Retained for tooling that must not print, and it is
#             the DANGEROUS one: it makes an owed appcast look like a finished
#             one. Do not use it for a real cut.
#
# WHY `onbox` EXISTS RATHER THAN SOFTENING THE HARD-REQUIRE.
#
# The previous comment on the CI step got this exactly right and it is worth
# repeating rather than deleting: "#776 exists because #370 was dark;
# softening it to a warning would put it straight back. The fix is WHERE it
# runs, not WHETHER it is enforced."
#
# Andy's decision, 2026-08-19, and it is settled: a Sparkle EdDSA PRIVATE key
# will not be held as an Actions secret on a PUBLIC repo. Signing happens on
# the box. So the enforcement does not weaken, it MOVES: CI stops pretending
# it might publish, and the debt is collected by
# tests/test_appcast_debt_is_collected.sh, which refuses the NEXT cut while a
# RELEASED version still has no appcast entry.
#
# RELEASED, not cut. A cut is a build; a release is a build somebody can
# obtain. A version with no release has no download for a feed entry to point
# AT, so demanding one is a false accusation rather than strictness. The first
# version of that gate keyed on cuts/<v>/cut.env and would have refused the
# launch cut over eight versions that were never released. Measured 2026-08-19:
# 13 cut records, 0 releases, 0 <item> elements in the live feed.
#
# That pairing is the whole point. `onbox` alone would be a silent deferral
# wearing a green tick, which is #370 again. `onbox` PLUS a tripwire is a
# deferral that cannot become permanent without somebody noticing.
PUBLISH_APPCAST       ?= 1
# ostler-release CLI from CM050 release-tooling (`pip install -e .`). Override
# if not on PATH, e.g. OSTLER_RELEASE_BIN=/path/to/.venv/bin/ostler-release.
OSTLER_RELEASE_BIN    ?= ostler-release
# CM050 appcast-server dir = the wrangler cwd for the publish's KV/R2 writes.
# Passed to the CLI as $OSTLER_APPCAST_DIR. Default = canonical sibling layout.
OSTLER_APPCAST_DIR    ?= $(HOME)/Documents/Projects/CM050 - Home Hub Update System/appcast-server
# Hub release archive base name (matches CM050 BRAND.binaryFilename).
HUB_RELEASE_BASENAME  ?= OstlerHub
# Appcast channel for this cut: stable | security.
APPCAST_CHANNEL       ?= stable
# Hub version/build/min-os. Left blank => read from the Sparkle-embedded
# Ostler.app Info.plist at publish time. Override to pin explicitly.
HUB_VERSION           ?=
HUB_BUILD             ?=
HUB_MIN_OS            ?=
# AU-1 appcast-version guard: the app this release SUPERSEDES, i.e. the one
# currently installed. The guard refuses to publish unless BOTH the version
# and the build being published are STRICTLY GREATER than this bundle's, using
# Sparkle's comparator. Sparkle silently skips any entry whose sparkle:version
# is <= the installed CFBundleVersion -- no dialog, no log, no error -- so a
# pasted-in daemon version (0.4.x where the Hub is on 0.7.x) publishes cleanly
# and reaches nobody. Absent path => nothing to supersede (fresh box / first
# release) => skipped with a printed note. Set empty to disable.
#
# KNOWN LIMITATION, STATED RATHER THAN SHIPPED QUIETLY. Cuts run in CI
# (guard-local-cut refuses a local cut), and a hosted runner has no
# /Applications/Ostler.app. So on the machine where cuts ACTUALLY happen this
# default is absent, the guard takes its documented skip branch, and it
# protects nothing. It is live for a local emergency cut and inert for the
# normal path. That is a strictly better position than before -- there was no
# guard at all, at any layer -- but it is not the finished article, and a
# reader who assumes "wired" means "covering the cut" would be wrong.
#
# CM051 PR #463 has the same property; it is a property of comparing against a
# LOCALLY INSTALLED app rather than of any particular implementation.
#
# THE DURABLE FIX is to compare against the newest entry already in the
# published manifest, which is the real "what is out there" and is the same
# answer on every machine. `ostler-release list` returns it. That needs
# network + wrangler auth, so it belongs in CM050 beside the publisher rather
# than here, and it is not in this PR. Until then, a CI cut that wants the
# guard live must pass HUB_REFERENCE_APP explicitly at a path the runner has.
HUB_REFERENCE_APP     ?= /Applications/Ostler.app
# The guard itself. A variable so a self-test can point the recipe at a stub
# and prove the recipe's own branching, per the PROVENANCE_SH / STAPLING_SH
# pattern used by every other gate wrapper here.
APPCAST_GUARD_PY      ?= $(CURDIR)/../scripts/appcast_version_guard.py
# Release-notes HTML stem; published URL is $(RELEASE_NOTES_BASE)/<version>.html
RELEASE_NOTES_BASE    ?= https://ostler.ai/releases

STEP          := @printf '\n[STEP] %s\n'

.PHONY: help all debug release package notarise notarise-app notarise-dmg \
        staple staple-apps archive ship clean regen \
        check-tools check-identity check-create-dmg check-ostler-app check-version \
        check-pbxproj-sync \
        print-version print-dmg-path print-dist-dir print-build-dir print-archive-dir \
        dmg-bg sparkle-embed verify-dmg-contents verify-stapling \
        check-orphans \
        check-pr-age \
        verify-commit-parity \
        download-python sign-python-bundle download-daemon download-hub-app \
        download-safari-extension stage-daemon \
        check-provenance check-freshness check-provenance-content check-manifest \
        publish-appcast verify-appcast

# The default goal is deliberately INERT.
#
# It used to be `all: debug`, and `debug` ends with `open "$(DEBUG_APP)"` --
# so a bare `make` in gui/ built AND LAUNCHED the installer. That is a bad
# default anywhere and a dangerous one on the cut machine: on 2026-08-08 a
# `make -p` (intended only to dump the variable database -- but -p without a
# target still runs the default goal) built and launched a Debug installer on
# the operator's Mac mid-session. Nothing in the repo invokes `make` in gui/
# without a target, so making the default a no-op costs nothing.
#
# Build explicitly: `make debug`, `make release`, `make ship`.
.DEFAULT_GOAL := help

help:
	@echo "Ostler installer (gui/) -- no default build; choose a target:"
	@echo ""
	@echo "  make debug              build Debug and OPEN the .app"
	@echo "  make release            build Release (runs the preflight gates)"
	@echo "  make ship               full cut: build, sign, notarise, staple, package (NOT publish)"
	@echo "  make publish-appcast    AU-1: sign + publish this cut's appcast entry"
	@echo "  make verify-appcast     AU-1: prove this version is LIVE on the feed"
	@echo "  make regen              regenerate the .xcodeproj from project.yml"
	@echo "  make check-version      version-consistency preflight (#171)"
	@echo "  make check-pbxproj-sync tracked .xcodeproj == xcodegen(project.yml)"
	@echo "  make print-version      print the version this tree would stamp"
	@echo ""
	@echo "Pre-cut gates all at once:  ../scripts/run_all_cut_gates.sh"

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

# print-dmg-path -- where `ship` ACTUALLY leaves the DMG.
#
# WHY THIS EXISTS (v1.0.26, 2026-08-14). cut.yml's verify step did
# `find dist -name '*.dmg'` and upload-artifact read `dist/*.dmg`, but DIST_DIR
# defaults to /tmp/ostler-installer-dist-$(USER) and nothing ever created
# `dist`. So on the first run in which notarise, staple and create-dmg ALL
# succeeded, the very next step died with:
#
#     find: dist: No such file or directory
#
# and upload-artifact was skipped, so a fully notarised and stapled DMG was
# thrown away with the runner. The build was correct; the two steps that READ
# it were looking somewhere the build never writes.
#
# Hardcoding the /tmp path into the workflow would fix today and drift again
# the first time DIST_DIR moves. Asking make removes the second copy of the
# truth: there is now ONE definition of where the DMG is, and the workflow
# derives it instead of restating it.
print-dmg-path:
	@echo "$(DMG_PATH)"

# THE SIBLINGS OF print-dmg-path, FOR THE SAME REASON (task #359).
#
# The gates-only dry run ends by ASSERTING that nothing shippable exists on the
# runner: no DMG, no exported .app, no xcarchive, no archived copy. That
# assertion is only worth anything if it looks where the build would actually
# write, and the v1.0.26 lesson is that a second copy of a path is a second
# thing to drift -- `find dist -name '*.dmg'` threw away a notarised DMG
# because DIST_DIR pointed at /tmp all along.
#
# So the dry run asks make, exactly as cut.yml already does for the DMG. One
# definition of each path, three readers, no restatements.
print-dist-dir:
	@echo "$(DIST_DIR)"

print-build-dir:
	@echo "$(BUILD_DIR)"

print-archive-dir:
	@echo "$(ARCHIVE_DIR)"

# ---------------------------------------------------------------------------
# Version-consistency preflight (CM051 #171). Fail-closed guard that the
# installer's version agrees across the three tracked sources of truth:
#   gui/OstlerInstaller/Info.plist   (what the built .app stamps)
#   gui/project.yml                  (the xcodegen source)
#   gui/OstlerInstaller.xcodeproj/project.pbxproj  (the generated project)
# on BOTH the marketing/short version and the build number. This refuses the
# half-bump shape -- e.g. project.yml edited but `xcodegen generate` not
# re-run so the tracked pbxproj lags, or Info.plist forgotten -- that let the
# v1.0.11/v1.0.12 DMGs ship OstlerInstaller.app stamped a stale "1.0.10".
# Pure text/plist parse, no build deps; runs the repo's bash gate.
#
# NOTE: this proves the three SOURCE files agree. It does NOT derive the
# version from the cut tag, so it does not by itself catch a "nobody bumped
# anything" cut (all three consistently stale vs the release version -- the
# literal #171 shape). See ../VERSIONING.md for the bump checklist and the
# cut-derivation + cut-manifest `plist_key_equals` proposals that close that
# remaining gap at the built-artefact boundary.
# ---------------------------------------------------------------------------
check-version:
	$(STEP) "Installer version-consistency preflight (#171)"
	@bash "$(CURDIR)/../tests/test_installer_version_consistency.sh"

# ---------------------------------------------------------------------------
# Project-sync preflight (#662). check-version above proves project.yml and the
# pbxproj agree on the VERSION fields. This generalises that to the whole
# project: it regenerates with xcodegen and fails if the tracked pbxproj is not
# byte-identical to the result.
#
# Why: xcodebuild builds the PBXPROJ; humans edit project.yml; nothing in the
# ship chain runs `xcodegen`. At the v1.0.17 cut the pbxproj was stale --
# PR #516's inputFiles/outputFiles for lib/settling_progress.sh were never
# regenerated -- and the bundling gate, which parses project.yml only, still
# reported "Xcode tracks every copy". True of the YAML, false of the build.
# Harmless that time only because `release` rm -rf's the staging dir first.
#
# Exit 2 (xcodegen missing / project already dirty) is UNAVAILABLE, not a pass.
# ---------------------------------------------------------------------------
check-pbxproj-sync:
	$(STEP) "Xcode project-sync preflight (pbxproj == xcodegen(project.yml))"
	@rc=0; bash "$(CURDIR)/../scripts/verify_pbxproj_in_sync.sh" || rc=$$?; \
	if [ "$$rc" -eq 2 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the project-sync gate COULD NOT RUN. It has NOT found the" >&2; \
	    echo "       project to be in sync -- it failed to look. See the reason" >&2; \
	    echo "       printed above (usually: xcodegen absent, or a version other" >&2; \
	    echo "       than the pin in gui/.xcodegen-version)." >&2; \
	    echo "       Install the pinned xcodegen and re-run. DO NOT SHIP." >&2; \
	    exit 2; \
	elif [ "$$rc" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the tracked Xcode project does not match gui/project.yml." >&2; \
	    echo "       xcodebuild builds the pbxproj, so anything project.yml adds" >&2; \
	    echo "       is absent from the build until you re-run xcodegen AND commit." >&2; \
	    echo "       Fix:  cd gui && xcodegen generate && git add -A && commit" >&2; \
	    echo "       DO NOT SHIP." >&2; \
	    exit 1; \
	fi

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
	    if [ -n "$$OSTLER_RELEASES_TOKEN" ]; then \
	        printf '[STEP] using OSTLER_RELEASES_TOKEN (cross-org read)\n'; \
	        GH_TOKEN="$$OSTLER_RELEASES_TOKEN" gh release download "$(DAEMON_RELEASE_TAG)" \
	                --repo "$(DAEMON_REPO)" \
	                --pattern "$(DAEMON_TARBALL_NAME)" \
	                --dir "$(BUILD_DIR)" \
	                --clobber || { \
	            echo "ERROR: cross-org fetch FAILED with OSTLER_RELEASES_TOKEN set." >&2; \
	            echo "  The token is present but could not read $(DAEMON_REPO) $(DAEMON_RELEASE_TAG)." >&2; \
	            echo "  Check it is fine-grained, scoped to that repo, Contents: Read, and not expired." >&2; \
	            echo "  NOT falling back to GITHUB_TOKEN -- a repo-scoped token cannot read another org," >&2; \
	            echo "  so a fallback would just fail later and blame the wrong thing." >&2; \
	            exit 1; \
	        }; \
	    elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then \
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
# Task #332: obtain Ostler.app when this machine does not already have one.
#
# Materialises the bundle AT $(OSTLER_APP_PATH) rather than somewhere else and
# then repointing the variable. That keeps one path in play instead of two, and
# keeps tests/test_makefile_app_path_default.sh's "derived from this checkout"
# assertion true -- a default that resolves into /tmp on CI and beside the repo
# locally is two different defaults wearing one name.
#
# NO-OP WHEN THE BUNDLE IS ALREADY THERE. On the operator's Mac the sibling
# ostler-assistant checkout has a freshly built Ostler.app and that is the one
# that should ship; re-downloading over it would replace the artefact being
# tested with a different one mid-cut.
# ---------------------------------------------------------------------------
download-hub-app:
	@if [ -d "$(OSTLER_APP_PATH)" ]; then \
	    printf '[STEP] Ostler.app already present: %s\n' "$(OSTLER_APP_PATH)"; \
	    printf '[STEP] using it as-is; verify-commit-parity checks it is the right commit\n'; \
	    exit 0; \
	fi; \
	mkdir -p "$(BUILD_DIR)"; \
	printf '\n[STEP] Ostler.app absent -- fetching %s from %s %s\n' \
	    "$(HUB_APP_TARBALL_NAME)" "$(HUB_APP_REPO)" "$(DAEMON_RELEASE_TAG)"; \
	if [ -f "$(HUB_APP_TARBALL_CACHE)" ]; then \
	    printf '[STEP] hub app cache hit: %s\n' "$(HUB_APP_TARBALL_CACHE)"; \
	elif [ -f "$(DAEMON_LOCAL_CACHE_DIR)/$(HUB_APP_TARBALL_NAME)" ]; then \
	    printf '[STEP] hub app local-cache hit\n'; \
	    cp "$(DAEMON_LOCAL_CACHE_DIR)/$(HUB_APP_TARBALL_NAME)" "$(HUB_APP_TARBALL_CACHE)"; \
	elif [ -n "$$OSTLER_RELEASES_TOKEN" ]; then \
	    printf '[STEP] using OSTLER_RELEASES_TOKEN (cross-org read)\n'; \
	    GH_TOKEN="$$OSTLER_RELEASES_TOKEN" gh release download "$(DAEMON_RELEASE_TAG)" \
	            --repo "$(HUB_APP_REPO)" \
	            --pattern "$(HUB_APP_TARBALL_NAME)" \
	            --dir "$(BUILD_DIR)" \
	            --clobber || { \
	        echo "" >&2; \
	        echo "ERROR: could not read $(HUB_APP_REPO) $(DAEMON_RELEASE_TAG) with OSTLER_RELEASES_TOKEN." >&2; \
	        echo "  The token IS set, so this is a scope problem, not a missing credential." >&2; \
	        echo "  $(HUB_APP_REPO) is a DIFFERENT repository from the daemon's" >&2; \
	        echo "  $(DAEMON_REPO), and a fine-grained token scoped to one cannot read" >&2; \
	        echo "  the other. Add $(HUB_APP_REPO) to the token's repository list with" >&2; \
	        echo "  Contents: Read, or publish the hub app tarball alongside the daemon" >&2; \
	        echo "  and set HUB_APP_REPO=$(DAEMON_REPO)." >&2; \
	        echo "  NOT falling back to GITHUB_TOKEN: it cannot read another org either," >&2; \
	        echo "  so the fallback would fail later and blame the wrong component." >&2; \
	        exit 1; \
	    }; \
	elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then \
	    gh release download "$(DAEMON_RELEASE_TAG)" \
	            --repo "$(HUB_APP_REPO)" \
	            --pattern "$(HUB_APP_TARBALL_NAME)" \
	            --dir "$(BUILD_DIR)" \
	            --clobber || { \
	        echo "ERROR: gh release download failed for $(HUB_APP_TARBALL_NAME)." >&2; \
	        echo "  Confirm it is published at:" >&2; \
	        echo "    https://github.com/$(HUB_APP_REPO)/releases/tag/$(DAEMON_RELEASE_TAG)" >&2; \
	        echo "  and that the active gh account can read that repo." >&2; \
	        exit 1; \
	    }; \
	else \
	    echo "ERROR: no way to obtain Ostler.app." >&2; \
	    echo "  Build it in the sibling ostler-assistant checkout, or stage the" >&2; \
	    echo "  tarball at $(DAEMON_LOCAL_CACHE_DIR)/$(HUB_APP_TARBALL_NAME)," >&2; \
	    echo "  or export OSTLER_RELEASES_TOKEN / run \`gh auth login\`." >&2; \
	    exit 1; \
	fi; \
	if [ ! -s "$(HUB_APP_TARBALL_CACHE)" ]; then \
	    echo "ERROR: $(HUB_APP_TARBALL_CACHE) is missing or empty after download." >&2; \
	    rm -f "$(HUB_APP_TARBALL_CACHE)"; \
	    exit 1; \
	fi; \
	EXPECTED="$(HUB_APP_SHA256)"; \
	ACTUAL="$$(shasum -a 256 "$(HUB_APP_TARBALL_CACHE)" | awk '{print $$1}')"; \
	if [ "$$ACTUAL" != "$$EXPECTED" ]; then \
	    echo "" >&2; \
	    echo "ERROR: Ostler.app tarball SHA-256 mismatch (fail-closed)." >&2; \
	    echo "  expected: $$EXPECTED" >&2; \
	    echo "  actual:   $$ACTUAL" >&2; \
	    echo "  file:     $(HUB_APP_TARBALL_CACHE)" >&2; \
	    echo "  This blocks shipping an unverified or wrong-version Hub app. If you" >&2; \
	    echo "  intentionally bumped DAEMON_VERSION, update HUB_APP_SHA256 from the" >&2; \
	    echo "  new release's published .sha256 sidecar and retry." >&2; \
	    rm -f "$(HUB_APP_TARBALL_CACHE)"; \
	    exit 1; \
	fi; \
	DEST="$(dir $(OSTLER_APP_PATH))"; \
	mkdir -p "$$DEST"; \
	tar -xzf "$(HUB_APP_TARBALL_CACHE)" -C "$$DEST"; \
	if [ ! -d "$(OSTLER_APP_PATH)" ]; then \
	    echo "ERROR: tarball extracted but $(OSTLER_APP_PATH) still does not exist." >&2; \
	    echo "  The tarball must contain Ostler.app at its TOP LEVEL." >&2; \
	    echo "  Extracted into: $$DEST" >&2; \
	    exit 1; \
	fi; \
	printf '[OK] Ostler.app v%s fetched + SHA-256 verified at %s\n' "$(DAEMON_VERSION)" "$(OSTLER_APP_PATH)"

# ---------------------------------------------------------------------------
# Task #332 sibling: obtain the Safari extension when this machine has none.
# ---------------------------------------------------------------------------
download-safari-extension:
	@if [ -s "$(SAFARI_EXT_DEST)" ]; then \
	    printf '[STEP] Safari extension already staged: %s\n' "$(SAFARI_EXT_DEST)"; \
	    exit 0; \
	fi; \
	mkdir -p "$(dir $(SAFARI_EXT_DEST))"; \
	printf '\n[STEP] Safari extension absent -- fetching %s from %s %s\n' \
	    "$(SAFARI_EXT_NAME)" "$(SAFARI_EXT_REPO)" "$(SAFARI_EXT_TAG)"; \
	if [ -n "$$OSTLER_RELEASES_TOKEN" ]; then \
	    GH_TOKEN="$$OSTLER_RELEASES_TOKEN" gh release download "$(SAFARI_EXT_TAG)" \
	            --repo "$(SAFARI_EXT_REPO)" --pattern "$(SAFARI_EXT_NAME)" \
	            --dir "$(dir $(SAFARI_EXT_DEST))" --clobber || { \
	        echo "ERROR: could not read $(SAFARI_EXT_REPO) $(SAFARI_EXT_TAG) with OSTLER_RELEASES_TOKEN." >&2; \
	        echo "  The token IS set, so this is a scope problem, not a missing credential." >&2; \
	        exit 1; \
	    }; \
	elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then \
	    gh release download "$(SAFARI_EXT_TAG)" --repo "$(SAFARI_EXT_REPO)" \
	            --pattern "$(SAFARI_EXT_NAME)" --dir "$(dir $(SAFARI_EXT_DEST))" --clobber || { \
	        echo "ERROR: gh release download failed for $(SAFARI_EXT_NAME)." >&2; \
	        exit 1; \
	    }; \
	else \
	    echo "ERROR: no way to obtain the Safari extension." >&2; \
	    echo "  Stage it at $(SAFARI_EXT_DEST), or export OSTLER_RELEASES_TOKEN." >&2; \
	    exit 1; \
	fi; \
	EXPECTED="$(SAFARI_EXT_SHA256)"; \
	ACTUAL="$$(shasum -a 256 "$(SAFARI_EXT_DEST)" | awk '{print $$1}')"; \
	if [ "$$ACTUAL" != "$$EXPECTED" ]; then \
	    echo "" >&2; \
	    echo "ERROR: Safari extension SHA-256 mismatch (fail-closed)." >&2; \
	    echo "  expected: $$EXPECTED" >&2; \
	    echo "  actual:   $$ACTUAL" >&2; \
	    echo "  A digest of e3b0c442...b855 means the file read as EMPTY, not that it" >&2; \
	    echo "  differs -- that is the sha256 of the empty string, and on this build" >&2; \
	    echo "  Mac it means iCloud evicted the source. Fault it in and retry." >&2; \
	    rm -f "$(SAFARI_EXT_DEST)"; \
	    exit 1; \
	fi; \
	printf '[OK] Safari extension fetched + SHA-256 verified at %s\n' "$(SAFARI_EXT_DEST)"

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
# (B-lite) delivery mechanism -- Component 3: payload embedding (cut-time).
# Spec: HR015/launch/BLITE_DELIVERY_DESIGN_v1.0.12.md section 1 "Payload
# embedding".
#
# Embeds a self-contained payload inside the pre-built Hub Ostler.app at
# $(OSTLER_APP_PATH)/Contents/Resources/ostler-payload/ so a later
# OSTLER_UPGRADE_MODE=1 run of install.sh can reconcile EVERY piece of Ostler
# on a customer Mac from the embedded copy (daemon binary, launchd plists,
# doctor / knowledge / cm048 service trees) rather than just
# /Applications/Ostler.app, and without any network fetch. Embedding, not
# downloading, means "if the Hub is on disk, the payload is too" (spec
# rationale) -- no second HTTP dependency at trigger time.
#
# ORDERING IS LOAD-BEARING: this target runs in the ship chain AFTER
# stage-daemon (so the freshly-staged daemon binary exists under
# ../assistant-agent/) and BEFORE sparkle-embed. sparkle-embed's
# embed-sparkle.sh runs `codesign --force --deep` over the whole Ostler.app,
# which SEALS this payload inside the Hub's codesignature. Inject the payload
# after that seal and it would be un-sealed detritus that breaks
# `codesign --verify`; the whole point is that the payload rides inside the
# Hub signature envelope.
#
# Fails loudly if ANY source input is missing -- a partial payload must never
# ship (a customer upgrade would then reconcile from an incomplete set and
# half-swap the product). Size guard: hard-fails above 500 MB (Andy's cap,
# 2026-07-27 sign-off decision #1); expected 50-150 MB, dominated by the
# ~30-50 MB daemon binary.
#
# Note payload service names != vendor source names:
#   services/doctor/    <- vendor/doctor/agent/
#   services/knowledge/ <- vendor/cm024_knowledge/
#   services/cm048/     <- vendor/cm048_pipeline/
# ---------------------------------------------------------------------------
stage-payload:
	@if [ ! -d "$(OSTLER_APP_PATH)" ]; then \
	    echo "" >&2; \
	    echo "ERROR: OSTLER_APP_PATH is not a directory: $(OSTLER_APP_PATH)" >&2; \
	    echo "  stage-payload embeds the (B-lite) upgrade payload INSIDE the pre-built" >&2; \
	    echo "  Ostler.app. Build the Tauri Hub or point OSTLER_APP_PATH at a bundle first." >&2; \
	    exit 1; \
	fi
	$(STEP) "Embedding (B-lite) upgrade payload into Ostler.app (before sparkle-embed seal)"
	@SRC_ROOT="$(CURDIR)/.."; \
	AGENT_SRC="$$SRC_ROOT/assistant-agent"; \
	DAEMON_APP="$$AGENT_SRC/OstlerAssistant.app"; \
	DAEMON_BARE_BIN="$$AGENT_SRC/bin/ostler-assistant"; \
	if [ ! -d "$$DAEMON_APP" ]; then \
	    echo "" >&2; \
	    if [ -x "$$DAEMON_BARE_BIN" ]; then \
	        echo "ERROR: stage-payload found a BARE DAEMON BINARY and no signed .app." >&2; \
	        echo "  present: $$DAEMON_BARE_BIN" >&2; \
	        echo "  needed:  $$DAEMON_APP" >&2; \
	        echo "" >&2; \
	        echo "  A bare binary CANNOT be embedded as the upgrade payload. install.sh" >&2; \
	        echo "  upgrade-mode (_upg_stage_daemon) refuses a bare-binary payload with" >&2; \
	        echo "  exit 20: the swap is gated on codesign --verify --deep --strict against" >&2; \
	        echo "  the Team pin, and a loose binary carries no bundle signature to verify." >&2; \
	        echo "  Embedding one yields a DMG whose own upgrade path refuses it at runtime," >&2; \
	        echo "  silently, on the customer's machine. Refusing at cut time instead." >&2; \
	    else \
	        echo "ERROR: staged daemon .app not found. Expected:" >&2; \
	        echo "  $$DAEMON_APP" >&2; \
	        echo "  Run 'make stage-daemon' before stage-payload -- it extracts the" >&2; \
	        echo "  v$(DAEMON_VERSION) daemon tarball into ../assistant-agent/. In the ship" >&2; \
	        echo "  chain stage-daemon runs first, so this only bites a standalone run." >&2; \
	    fi; \
	    exit 1; \
	fi; \
	INSTALL_SH="$$SRC_ROOT/install.sh"; \
	SNIPPET="$$AGENT_SRC/INSTALL_SNIPPET.sh"; \
	LAUNCHD_DIR="$$AGENT_SRC/launchd"; \
	DOCTOR_SRC="$$SRC_ROOT/vendor/doctor/agent"; \
	KNOWLEDGE_SRC="$$SRC_ROOT/vendor/cm024_knowledge"; \
	CM048_SRC="$$SRC_ROOT/vendor/cm048_pipeline"; \
	PLISTS="$$(ls "$$LAUNCHD_DIR"/*.plist 2>/dev/null || true)"; \
	MISSING=""; \
	[ -f "$$INSTALL_SH" ] || MISSING="$$MISSING install.sh"; \
	[ -f "$$SNIPPET" ] || MISSING="$$MISSING assistant-agent/INSTALL_SNIPPET.sh"; \
	[ -d "$$LAUNCHD_DIR" ] || MISSING="$$MISSING assistant-agent/launchd/"; \
	[ -n "$$PLISTS" ] || MISSING="$$MISSING assistant-agent/launchd/*.plist"; \
	[ -d "$$DOCTOR_SRC" ] || MISSING="$$MISSING vendor/doctor/agent"; \
	[ -d "$$KNOWLEDGE_SRC" ] || MISSING="$$MISSING vendor/cm024_knowledge"; \
	[ -d "$$CM048_SRC" ] || MISSING="$$MISSING vendor/cm048_pipeline"; \
	if [ -n "$$MISSING" ]; then \
	    echo "" >&2; \
	    echo "ERROR: stage-payload source input(s) missing:$$MISSING" >&2; \
	    echo "  Refusing to embed a partial payload -- a customer upgrade would then" >&2; \
	    echo "  reconcile from an incomplete set and half-swap the product. Fix the" >&2; \
	    echo "  inputs above and re-run." >&2; \
	    exit 1; \
	fi; \
	PAYLOAD="$(OSTLER_APP_PATH)/Contents/Resources/ostler-payload"; \
	printf '[STEP] Assembling payload at %s\n' "$$PAYLOAD"; \
	rm -rf "$$PAYLOAD"; \
	mkdir -p "$$PAYLOAD/assistant-agent/launchd" "$$PAYLOAD/services"; \
	printf 'hub-v%s\n' "$(DAEMON_VERSION)" > "$$PAYLOAD/VERSION"; \
	cp "$$INSTALL_SH" "$$PAYLOAD/install.sh"; \
	cp "$$SNIPPET" "$$PAYLOAD/assistant-agent/INSTALL_SNIPPET.sh"; \
	cp "$$LAUNCHD_DIR"/*.plist "$$PAYLOAD/assistant-agent/launchd/"; \
	ditto "$$DAEMON_APP" "$$PAYLOAD/assistant-agent/OstlerAssistant.app"; \
	chmod +x "$$PAYLOAD/assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant"; \
	cp -R "$$DOCTOR_SRC" "$$PAYLOAD/services/doctor"; \
	cp -R "$$KNOWLEDGE_SRC" "$$PAYLOAD/services/knowledge"; \
	cp -R "$$CM048_SRC" "$$PAYLOAD/services/cm048"; \
	/usr/bin/xattr -cr "$$PAYLOAD" 2>/dev/null || true; \
	for req in VERSION install.sh assistant-agent/INSTALL_SNIPPET.sh assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant services/doctor services/knowledge services/cm048; do \
	    if [ ! -e "$$PAYLOAD/$$req" ]; then \
	        echo "ERROR: payload assembly incomplete -- missing $$req after copy." >&2; \
	        exit 1; \
	    fi; \
	done; \
	if [ -e "$$PAYLOAD/assistant-agent/bin/ostler-assistant" ]; then \
	    echo "" >&2; \
	    echo "ERROR: payload contains the LEGACY bare-binary shape at" >&2; \
	    echo "  $$PAYLOAD/assistant-agent/bin/ostler-assistant" >&2; \
	    echo "  install.sh upgrade-mode resolves _UPG_PAYLOAD_APP first and refuses a" >&2; \
	    echo "  bare binary with exit 20. Shipping both shapes invites the wrong one." >&2; \
	    exit 1; \
	fi; \
	printf '[STEP] Verifying the embedded daemon against the SAME requirement upgrade-mode enforces\n'; \
	if ! codesign --verify --deep --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "V95N2B8X7A"' "$$PAYLOAD/assistant-agent/OstlerAssistant.app" 2>&1; then \
	    echo "" >&2; \
	    echo "ERROR: the embedded daemon at" >&2; \
	    echo "  $$PAYLOAD/assistant-agent/OstlerAssistant.app" >&2; \
	    echo "  FAILS codesign --verify --deep --strict against the Team pin V95N2B8X7A." >&2; \
	    echo "  This is the exact check install.sh upgrade-mode runs before the daemon" >&2; \
	    echo "  swap (_upg_stage_daemon, exit 21). A payload that fails here produces a" >&2; \
	    echo "  DMG whose upgrade path refuses itself on the customer's machine. The" >&2; \
	    echo "  cut is refused instead. Checked AFTER xattr -cr, so this is the state" >&2; \
	    echo "  that actually ships." >&2; \
	    exit 1; \
	fi; \
	printf '[OK] embedded daemon verifies against the upgrade-mode Team pin\n'; \
	FILE_COUNT="$$(find "$$PAYLOAD" -type f | wc -l | tr -d ' ')"; \
	PAYLOAD_MB="$$(du -sm "$$PAYLOAD" | awk '{print $$1}')"; \
	printf '[OK] payload assembled: %s files, %s MB, VERSION=hub-v%s\n' "$$FILE_COUNT" "$$PAYLOAD_MB" "$(DAEMON_VERSION)"; \
	if [ "$$PAYLOAD_MB" -gt 500 ]; then \
	    echo "" >&2; \
	    echo "ERROR: embedded payload is $${PAYLOAD_MB} MB, over the 500 MB cap." >&2; \
	    echo "  (Andy's 2026-07-27 sign-off decision #1.) Something bloated the payload;" >&2; \
	    echo "  investigate before shipping -- do NOT raise the cap silently." >&2; \
	    rm -rf "$$PAYLOAD"; \
	    exit 1; \
	fi; \
	printf '[OK] Embedded (B-lite) payload sealed-pending-sparkle at %s\n' "$$PAYLOAD"

# ---------------------------------------------------------------------------
# Release build – Developer ID signed, exported to dist/
# ---------------------------------------------------------------------------
release: guard-local-cut check-tools check-identity check-version check-pbxproj-sync download-python
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
	/usr/bin/xattr -cr "../install.sh" "../lib/progress_emitter.sh" "../lib/settling_progress.sh" || true
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
# top-level Cargo bundle output: in the ostler-assistant checkout that
# sits BESIDE this repo, at
# target/release/bundle/macos/Ostler.app -- which is what the derived
# default above resolves to. Stated relative to the checkout rather than
# as a home literal, because the home literal is what went stale in
# v1018-D668. The script verifies the bundle is present before any
# modification.
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
sign-python-bundle: guard-local-cut
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
	$(STEP) "Signing bundled ostler-mecard helper with hardened runtime"
	# BW2-1 (2026-07-25): ostler-mecard is a Mach-O at Contents/Resources/ostler-mecard,
	# compiled by the xcodegen postBuildScript and left UNSIGNED. Per CX-124 above, the
	# outer --force --deep reseal does NOT add hardened runtime to nested Mach-Os, so
	# without an explicit sign here notarytool rejects the DMG ("executable does not have
	# the hardened runtime enabled") -- a burnt cut cycle. Same identity + entitlements as
	# the daemon/python/outer .app for uniform runtime+entitlements state, before the outer
	# reseal seals it. (Its Contacts read inherits the installer's TCC grant as a same-team
	# hardened descendant; the embedded NSContactsUsageDescription is belt-and-braces.)
	@MECARD_BIN="$(APP_PATH)/Contents/Resources/ostler-mecard"; \
	if [ -f "$$MECARD_BIN" ]; then \
	    codesign --force --sign "$(CODESIGN_ID)" --options runtime --timestamp \
	        --entitlements "OstlerInstaller/OstlerInstaller.entitlements" \
	        "$$MECARD_BIN"; \
	    echo "  signed ostler-mecard with hardened runtime: $$MECARD_BIN"; \
	else \
	    echo "  no ostler-mecard at $$MECARD_BIN -- skipping (standalone sign run)"; \
	fi
	$(STEP) "Re-signing outer .app to seal inner Python signatures"
	# CX-33 (2026-05-24): --entitlements MUST be passed here, otherwise the
	# --force --deep re-sign STRIPS the disable-library-validation entitlement
	# that sign-python-bundle.sh just applied to python3.11 -- and the customer
	# install dies at encrypt_db with the cryptography Team-ID-mismatch error
	# (Studio retest #20 trail). Same entitlements file as the outer .app uses,
	# so the runtime + entitlements state is uniform across every Mach-O.
	# Without this CX-30's fix gets undone before the DMG is even packaged.
	# NO --deep. (v1.0.16, 2026-08-07)
	#
	# --deep re-signs every NESTED bundle as well as the outer one. That gives
	# each nested .app a new CDHash, which silently invalidates the notarisation
	# ticket it arrived with:
	#
	#   * OstlerAssistant.app is stapled inside the daemon tarball.
	#   * Ostler.app is stapled by notarise-hub before `release` copies it in.
	#
	# Both tickets were measured STALE immediately after this step ran with
	# --deep. staple-apps then had to re-staple them to restore the tickets,
	# which writes Contents/CodeResources inside bundles the outer had already
	# sealed -- and that is what produced:
	#
	#   OstlerInstaller.app: a sealed resource is missing or invalid
	#
	# The v1.0.15 cut manifest already carried this conclusion, as an entry
	# named `v1015-outer-reseal-not-deep`: "outer .app reseal must not use
	# --deep (it strips nested tickets)". That manifest is the file that never
	# reached main (commit d7ee25b), so the finding was written down and lost.
	#
	# --deep is redundant here anyway: python3.11, the assistant daemon, the
	# mecard helper and Sparkle are each signed explicitly by the steps above.
	# All this step has to do is re-seal the OUTER bundle so its CodeResources
	# reflects those inner signatures -- which a plain outer sign does. Apple
	# deprecates --deep for signing for exactly these reasons.
	codesign --force --sign "$(CODESIGN_ID)" --options runtime --timestamp --entitlements "OstlerInstaller/OstlerInstaller.entitlements" "$(APP_PATH)"
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
	@echo "Post-sign verify: ostler-mecard hardened runtime (must be enabled)"
	@MECARD_BIN="$(APP_PATH)/Contents/Resources/ostler-mecard"; \
	if [ -f "$$MECARD_BIN" ]; then \
	    codesign -dvvv "$$MECARD_BIN" 2>&1 | grep -Eq "flags=.*runtime" \
	        && echo "  ✓ hardened runtime present on ostler-mecard" \
	        || (echo "  ✗ hardened runtime MISSING from ostler-mecard -- DMG will fail notarisation"; exit 1); \
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
	    echo "  Build the Tauri Hub desktop first, in the ostler-assistant checkout" >&2; \
	    echo "  that sits BESIDE this one -- that is where the path above is derived" >&2; \
	    echo "  from, so this is always the tree that matters, not a home literal:" >&2; \
	    echo "    cd $(abspath $(_CM051_ROOT)/../ostler-assistant)" >&2; \
	    echo "    cargo tauri build" >&2; \
	    echo "" >&2; \
	    echo "  Or point at an existing build:" >&2; \
	    echo "    OSTLER_APP_PATH=/path/to/Ostler.app make ship" >&2; \
	    echo "" >&2; \
	    exit 1; \
	fi
	@printf '[CHECK] OSTLER_APP_PATH=%s (directory exists)\n' "$(OSTLER_APP_PATH)"
	@# PRE-SEAL PROVENANCE. Until this existed, the two checks above were the
	@# whole of check-ostler-app: non-empty, and is-a-directory. Nothing asked
	@# WHICH bundle it was.
	@#
	@# That was survivable only by accident. An ad-hoc bundle used to die at
	@# notarytool (step 11) with "Invalid". #679 made notarise-hub seal the Hub
	@# unconditionally -- correct in itself, an unsigned bundle must never reach
	@# Apple -- and in doing so converted that noisy accidental backstop into a
	@# silent pass: we now sign the unknown bundle ourselves and it is Accepted.
	@#
	@# The surviving TeamIdentifier assertion in verify-dmg-contents runs AFTER
	@# the seal we just applied, so it can only fail if codesign failed. And
	@# verify_commit_parity.sh asks the right question POST-cut, on a mounted
	@# DMG, after a notarisation round trip has already been spent.
	@#
	@# So ask it here, at step 5, before anything is signed. Delegated to a
	@# script (as COMMIT_PARITY_SH is) so the assertion is self-testable:
	@# scripts/tests/test_verify_app_provenance.sh, whose load-bearing control
	@# proves a bundle whose commit differs but whose frontend is IDENTICAL
	@# still passes. rc=2 (could not run) blocks too: an unmeasured provenance
	@# is not a pass.
	@# THE SECOND ARGUMENT IS LOAD-BEARING AND ITS ABSENCE BURNT v1.0.30.
	@# verify_app_provenance.sh takes the reference checkout as $$2 and, without
	@# it, derives a SIBLING path. On the runner that sibling resolves to
	@# .../work/CM051-Home-Hub-Installer/ostler-assistant, which is exactly where
	@# download-hub-app EXTRACTS the Hub app tarball. The directory therefore
	@# exists -- so no earlier check caught it -- and it is not a git repo, so the
	@# gate correctly refused with "reference checkout is not a git repo" and the
	@# cut died at step 11 having fetched and SHA-verified the bundle it could
	@# then not attest.
	@#
	@# The real clone already exists: cut.yml clones ostler-assistant with full
	@# history and tags into $${RUNNER_TEMP} and exports OSTLER_ASSISTANT_DIR.
	@# Two paths, and nothing connected them. This is that connection.
	@#
	@# The fallback is the same sibling default three other targets in this file
	@# already use (1293, 1446, 1481), so an operator Mac with a real sibling
	@# checkout behaves exactly as before.
	@# AND THE DAEMON OPERAND COMES FROM THE CUT RECORD, not from a clone's HEAD.
	@#
	@# Nothing passed OSTLER_DAEMON_COMMIT, so the gate fell through to
	@# `git rev-parse HEAD` on the reference checkout. The bundle is BUILT from
	@# that checkout, so its attested commit and that HEAD are normally the SAME
	@# COMMIT, and the parity loop then compared tree "<sha>:web" against itself.
	@# Measured on the shipping v1.0.33 cut (run 31998597024, 05:39:50Z):
	@# wrapper 5b7efb00, operand 5b7efb00, "frontend parity: identical commit".
	@# A self-comparison. It could not have failed, and its warn line read as
	@# informational.
	@#
	@# Read the pin the cut actually declares. Resolved HERE rather than in
	@# cut.yml because `make ship` also runs on an operator Mac, and a fix that
	@# only lives in the workflow leaves the local path still guessing.
	@#
	@# Empty is passed through deliberately: the gate now treats a missing pin as
	@# CANNOT-RUN (exit 2) and blocks. A cut record with no DAEMON_COMMIT is a cut
	@# nobody can attest, and that must be loud rather than defaulted.
	@# AND A HOTFIX MUST NOT SILENTLY READ ITS PARENT'S CUT RECORD.
	@#
	@# CUT_MANIFEST_VERSION is `v$(shell ... | cut -d. -f1-3)`, which TRUNCATES a
	@# four-part version: 1.0.13.1 resolves cuts/v1.0.13/. Not hypothetical --
	@# CFBundleShortVersionString has held 1.0.13.1 and 1.0.13.2 in this repo's
	@# own history, and a hotfix is precisely when the daemon gets re-pinned. So
	@# the operand this block just started reading could be the PARENT's
	@# DAEMON_COMMIT while the hotfix ships a different daemon: the same
	@# right-question-wrong-operand shape one level up.
	@#
	@# Prefer the record for the FULL version. Fall back to the truncated one,
	@# because no four-part cuts/ directory has ever existed and refusing would
	@# block a hotfix on a convention it has never followed -- but say so, loudly,
	@# naming BOTH paths. A fallback nobody can see is how the parent's pin gets
	@# read as the hotfix's.
	@# DELEGATED TO A SCRIPT so the fallback is TESTABLE. #794 shipped this
	@# resolution inline and Archie merged it flagging that the new WARN had no
	@# control firing it -- and the WARN is the entire safety mechanism, so an
	@# unfired one is a two-state predicate reading a warning as a pass.
	@#
	@# Logic embedded in a recipe cannot be driven by a fixture without a full
	@# build, and asserting the recipe TEXT would test the rendering instead of
	@# the behaviour. Same move, same reason, as COMMIT_PARITY_SH and
	@# APP_PROVENANCE_SH above. Controls live in
	@# scripts/tests/test_resolve_cut_daemon_pin.sh, and the load-bearing pair is
	@# "a four-part version WARNS" plus "a three-part version does NOT" -- a
	@# warning that fires on every cut is noise, and noise gets muted.
	@set -e; \
	DC="$$(bash "$(CUT_PIN_RESOLVER_SH)" "$(CURDIR)/.." "$(VERSION)")"; \
	printf '[CHECK] daemon operand: %s\n' "$${DC:-<unset>}"; \
	OSTLER_DAEMON_COMMIT="$$DC" \
	bash "$(APP_PROVENANCE_SH)" "$(OSTLER_APP_PATH)" "$${OSTLER_ASSISTANT_DIR:-$(CURDIR)/../../ostler-assistant}" || { \
	    echo "" >&2; \
	    echo "  Refusing to continue: the Ostler.app going into this DMG has not" >&2; \
	    echo "  been shown to be the bundle this cut intends to ship. Sealing it" >&2; \
	    echo "  would launder an unattested binary into a signed, notarised DMG." >&2; \
	    exit 1; \
	}

sparkle-embed: guard-local-cut
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
# Script path is a variable so the wrapper's OWN branching can be self-tested
# against a stub that exits 2 (see ../tests/test_cut_gate_wrappers.sh). A
# wrapper whose cannot-run branch has never been executed is a claim, not a
# gate.
PROVENANCE_SH ?= $(CURDIR)/../scripts/verify_cut_provenance.sh
check-provenance:
	$(STEP) "Cut-provenance preflight (DMG)"
	@rc=0; OSTLER_ASSISTANT_DIR="$${OSTLER_ASSISTANT_DIR:-$(CURDIR)/../../ostler-assistant}" \
	    bash "$(PROVENANCE_SH)" || rc=$$?; \
	if [ "$$rc" -eq 2 ] || [ "$$rc" -eq 3 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the cut-provenance gate COULD NOT RUN (exit $$rc)." >&2; \
	    echo "       It has NOT found a fix to be stale or missing -- it failed to" >&2; \
	    echo "       LOOK. Treating that as a clean run, or as a named defect, are" >&2; \
	    echo "       both wrong: one ships unverified, the other sends you hunting" >&2; \
	    echo "       a bug that was never detected. See the reason printed above" >&2; \
	    echo "       (usually a missing manifest or an unresolvable repo checkout)." >&2; \
	    echo "       DO NOT SHIP." >&2; \
	    exit "$$rc"; \
	elif [ "$$rc" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: cut-provenance preflight FAILED -- a merged fix is stale/missing." >&2; \
	    echo "Fix the FAILs above (graft vendor / re-tag daemon), then re-cut. DO NOT SHIP." >&2; \
	    exit 1; \
	fi

# ---------------------------------------------------------------------------
# Cut-freshness preflight (DMG). Compares EVERY shippable input (vendor pins,
# daemon, wiki images) to its LIVE upstream GitHub HEAD and hard-fails the cut
# if anything lags -- the structural cure for "built but not in the cut". This
# runs BEFORE check-provenance: provenance proves named fixes are present;
# freshness proves nothing has silently fallen behind live HEAD at all. Any
# non-zero (RED stale, or exit 3 CANNOT-VERIFY when GitHub is unreachable)
# aborts the cut fail-closed.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Orphaned-fix preflight -- UNBYPASSABLE. Fails the cut when a fix EXISTS on a
# branch, a local-only branch, or an open/DRAFT PR but is not an ancestor of
# what is being shipped.
#
# Every other gate asks "is what we pinned present?". None of them asked "does
# a fix exist that we FORGOT to pin?" -- which is how the v1.0.15 walk hit SIX
# defects that were already fixed and never merged, including a green DRAFT PR
# four days old. Deliberate deferrals go in cut-deferrals.yaml with a reason.
# ---------------------------------------------------------------------------
# LIVE MISREPORT until now: verify_no_orphaned_fixes.sh already exits 3 with
# "CANNOT VERIFY: no repo checkouts resolved" when it resolves ZERO checkouts.
# The old wrapper collapsed that into "work exists that is NOT in what you are
# about to ship" -- an accusation manufactured from a run that examined
# nothing. Zero-checkouts is the single most likely failure on a fresh cut
# machine, so the wrong message was the one you would actually see.
ORPHANS_SH ?= $(CURDIR)/../scripts/verify_no_orphaned_fixes.sh
check-orphans:
	$(STEP) "Orphaned-fix preflight (is any written fix missing from this cut?)"
	@rc=0; bash "$(ORPHANS_SH)" || rc=$$?; \
	if [ "$$rc" -eq 2 ] || [ "$$rc" -eq 3 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the orphaned-fix gate COULD NOT RUN (exit $$rc)." >&2; \
	    echo "       It has NOT found orphaned work -- it failed to look, almost" >&2; \
	    echo "       always because no repo checkout resolved. Nothing about this" >&2; \
	    echo "       run says the cut is complete. Fix the checkouts and re-run." >&2; \
	    echo "       DO NOT SHIP." >&2; \
	    exit "$$rc"; \
	elif [ "$$rc" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: work exists that is NOT in what you are about to ship." >&2; \
	    echo "       Merge it, or record a deliberate deferral with a reason in" >&2; \
	    echo "       cut-deferrals.yaml. Do NOT bypass -- bypassing is the habit" >&2; \
	    echo "       this gate exists to stop. DO NOT SHIP." >&2; \
	    exit 1; \
	fi

# ---------------------------------------------------------------------------
# PR AGE GATE (rule effective 2026-08-06)
# ---------------------------------------------------------------------------
# A PR opened from 2026-08-06 must be MERGED or CLOSED within 48 hours.
#
# The sibling gate above asks "did we forget to pin a fix that exists?". This
# one attacks the cause rather than the symptom: on 2026-08-06 a sweep found
# 176 open PRs and 458 unmerged branches carrying genuinely unique work. That
# backlog is what made six forgotten fixes statistically inevitable, and it
# grew because "done" meant "PR open" rather than "merged to main".
#
# NOT retroactive -- the pre-existing 176 are a legacy backlog with their own
# phased sweep, and failing on them would leave this permanently red, which is
# how a gate becomes something people route around.
# ---------------------------------------------------------------------------
# LIVE MISREPORT until now, same shape as check-orphans: verify_pr_age.sh
# exits 3 at TWO sites ("could not parse RULE_EFFECTIVE_DATE", "no repo
# produced a PR listing"), and the second is what an expired `gh` token
# produces. The old wrapper announced "PRs have outstayed the 48h limit" --
# naming a backlog it never saw, from a listing it never got.
PR_AGE_SH ?= $(CURDIR)/../scripts/verify_pr_age.sh
check-pr-age:
	$(STEP) "PR age preflight (merge or close within 48h)"
	@rc=0; bash "$(PR_AGE_SH)" || rc=$$?; \
	if [ "$$rc" -eq 2 ] || [ "$$rc" -eq 3 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the PR-age gate COULD NOT RUN (exit $$rc)." >&2; \
	    echo "       It has NOT found overdue PRs -- it failed to look. Usually" >&2; \
	    echo "       no repo produced a PR listing (expired gh token / no network)" >&2; \
	    echo "       or RULE_EFFECTIVE_DATE would not parse. Restore access and" >&2; \
	    echo "       re-run. DO NOT SHIP." >&2; \
	    exit "$$rc"; \
	elif [ "$$rc" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: PRs have outstayed the 48h limit." >&2; \
	    echo "       Merge, close, or record an exemption with a reason under" >&2; \
	    echo "       pr_exemptions: in cut-deferrals.yaml. DO NOT SHIP." >&2; \
	    exit 1; \
	fi

# The SEVENTH sibling of the six wrappers fixed in #644, and the one whose
# collapse was hardest to see, because its old message HEDGED: "a shippable
# input lags live upstream HEAD (or could not be verified against GitHub)".
# That sentence is never wrong, and therefore never tells you which of the two
# happened. It reads as a stale-pin finding, so on cut run 31685172775 -- where
# ~15 trees were CANNOT-VERIFY for want of a credential and only 3 were
# genuinely stale -- the operator's remedy ("re-pin / re-vendor / rebuild each
# RED input") was wrong for 15 of the 18 and impossible for all 15.
#
# A hedge is not honesty. Naming both outcomes in one sentence costs the reader
# the same information as naming neither. Exit 1 and exit 3 are different
# answers with different remedies, and the recipe now says which.
FRESHNESS_SH ?= $(CURDIR)/../scripts/verify_cut_freshness.sh
check-freshness:
	$(STEP) "Cut-freshness preflight (live GitHub HEAD)"
	@rc=0; bash "$(FRESHNESS_SH)" || rc=$$?; \
	if [ "$$rc" -eq 2 ] || [ "$$rc" -eq 3 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the cut-freshness gate COULD NOT RUN for at least one input (exit $$rc)." >&2; \
	    echo "       Nothing above says those inputs are stale -- they were NOT compared." >&2; \
	    echo "       Remedy is access, not a re-pin: grant the running token read" >&2; \
	    echo "       access to the source repo(s) named above (a private repo answers" >&2; \
	    echo "       404 exactly like a missing one), or restore network, then re-run." >&2; \
	    echo "       Re-pinning here would change a pin nobody has shown to be stale." >&2; \
	    echo "       DO NOT SHIP." >&2; \
	    exit "$$rc"; \
	elif [ "$$rc" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: cut-freshness preflight FAILED -- a shippable input lags live upstream HEAD." >&2; \
	    echo "       Re-pin / re-vendor / rebuild each RED input to current HEAD, then" >&2; \
	    echo "       re-cut. A hold_ack is for a DELIBERATE hold with a written reason;" >&2; \
	    echo "       it is not a way to make this green. DO NOT SHIP." >&2; \
	    exit 1; \
	fi

# ---------------------------------------------------------------------------
# Content-provenance preflight -- UNBYPASSABLE gate on the DMG.
# Sibling to check-provenance, but proves each launch-required fix is ACTUALLY
# baked into the shipped ARTIFACT (greps inside the pinned wiki image), not just
# that a ledger row CLAIMS a good source sha. This closes the "false ledger
# binding" hole a merge-base / freshness check can never see: install.sh's digest
# is bound to a source sha by a hand-recorded ledger row, and the image carries
# no CM044 revision label to confirm it. Ledger: ../scripts/required_fixes.tsv.
# ---------------------------------------------------------------------------
PROVENANCE_CONTENT_SH ?= $(CURDIR)/../scripts/provenance_gate.sh
check-provenance-content:
	$(STEP) "Content-provenance preflight (fix baked into artifact)"
	@rc=0; CM044_DIR="$${CM044_DIR:-$(CURDIR)/../../CM044 - PWG Personal Wiki}" \
	    OSTLER_ASSISTANT_DIR="$${OSTLER_ASSISTANT_DIR:-$(CURDIR)/../../ostler-assistant}" \
	    bash "$(PROVENANCE_CONTENT_SH)" || rc=$$?; \
	if [ "$$rc" -eq 2 ] || [ "$$rc" -eq 3 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the content-provenance gate COULD NOT RUN (exit $$rc)." >&2; \
	    echo "       It has NOT found a fix to be missing from an artifact -- it" >&2; \
	    echo "       failed to look, usually because the required-fixes ledger or" >&2; \
	    echo "       a source checkout is absent. This gate greps INSIDE shipped" >&2; \
	    echo "       artifacts; when it cannot, nothing is known about them." >&2; \
	    echo "       DO NOT SHIP." >&2; \
	    exit "$$rc"; \
	elif [ "$$rc" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: content-provenance preflight FAILED -- a required fix is NOT baked into a shipped artifact." >&2; \
	    echo "Rebuild + re-pin the RED artifact(s), fix the ledger row, then re-cut. DO NOT SHIP." >&2; \
	    exit 1; \
	fi

# ---------------------------------------------------------------------------
# Cut-manifest gate -- UNBYPASSABLE gate on the built .app.
# Verifies every entry in cut-manifests/permanent.yaml + cut-manifests/<ver>.yaml
# against the built OstlerInstaller.app AND the pinned source SHAs. Uses 5
# primitives (grep_in_installer, grep_in_artefact, grep_in_source_at_sha,
# file_exists_in_artefact, plist_key_equals). Fail-closed on any RED.
#
# See cut-manifests/README.md for schema + when to add entries.
# ---------------------------------------------------------------------------
check-manifest:
	$(STEP) "Cut-manifest preflight (built .app + pinned sources)"
	@if [ ! -d "$(APP_PATH)" ]; then \
	    echo "ERROR: $(APP_PATH) not found. Manifest gate needs a built .app; run 'make release' first." >&2; \
	    exit 1; \
	fi
	@APP_PATH="$(APP_PATH)" \
	    CM044_DIR="$${CM044_DIR:-$(CURDIR)/../../CM044 - PWG Personal Wiki}" \
	    OSTLER_ASSISTANT_DIR="$${OSTLER_ASSISTANT_DIR:-$(CURDIR)/../../ostler-assistant}" \
	    HR015_DIR="$${HR015_DIR:-$(CURDIR)/../../HR015 - Gaming PC}" \
	    ../scripts/verify_cut_manifest.sh --app-path "$(APP_PATH)" $(if $(CUT_MANIFEST_VERSION),--version "$(CUT_MANIFEST_VERSION)") || rc=$$?; \
	if [ "$${rc:-0}" -eq 2 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the cut-manifest gate COULD NOT RUN. It has NOT found a fix" >&2; \
	    echo "       missing -- it failed to look. See the reason above (usually:" >&2; \
	    echo "       python3 absent, or PyYAML uninstallable on this machine)." >&2; \
	    echo "       Resolve it and re-run. DO NOT SHIP." >&2; \
	    exit 2; \
	elif [ "$${rc:-0}" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: cut-manifest preflight FAILED -- a required fix is missing from the built .app." >&2; \
	    echo "Read the RED rows above. For each: either the fix isn't in the merged source, or the daemon/vendored artefact needs re-pinning + rebuild. Then re-cut. DO NOT SHIP." >&2; \
	    echo "" >&2; \
	    echo "Docs: cut-manifests/README.md" >&2; \
	    exit 1; \
	fi

package: guard-local-cut check-tools check-identity check-version check-create-dmg check-freshness check-provenance check-provenance-content
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
# Notarisation + stapling
#
# HR015 task #221 (offline first-launch blocker):
#   Historically this pipeline submitted the DMG for notarisation and then
#   stapled the DMG wrapper only. Every .app bundle INSIDE the DMG
#   (OstlerInstaller.app, and nested Ostler.app + OstlerAssistant.app in
#   Contents/Resources/) received a valid Apple ticket at Apple's ticket
#   server -- but that ticket was never embedded ("stapled") into the
#   bundle itself. Result: when install.sh moves those .apps to
#   /Applications on the customer Mac, Gatekeeper cannot find a stapled
#   ticket and falls back to an online lookup. A customer on a plane, in
#   a cafe with a captive portal, or behind a corporate firewall that
#   blocks Apple's ticket servers cannot launch Ostler.app.
#
# Fix: notarise the OstlerInstaller.app BEFORE packaging into a DMG (so
# Apple sees + registers every nested CDHash), then staple deepest-first
# in the build tree (nested .apps first, then the outer OstlerInstaller.app).
# Only then package into a DMG, sign, submit the DMG for its own
# notarisation (fast -- CDHashes already registered), staple the DMG.
#
# Ship-chain order (see `ship` target below):
#   ... check-manifest -> notarise-app -> staple-apps -> package
#                     -> notarise-dmg -> verify-dmg-contents -> verify-stapling -> archive
#
# The `notarise` + `staple` targets are kept as backwards-compat aliases
# for the DMG-only pattern (still useful for a one-off recut of an
# already-built DMG).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# notarise-app: zip $(APP_PATH), submit to notarytool, wait for accepted.
#
# Submitting the outer OstlerInstaller.app once registers tickets for
# EVERY CDHash inside it (Ostler.app, OstlerAssistant.app, python3.11,
# ostler-mecard, every framework Mach-O, ...) so `xcrun stapler staple`
# can then embed each ticket individually.
#
# We zip with `ditto -c -k --sequesterRsrc --keepParent` -- the
# Apple-blessed form for notary submissions. `zip -r` risks losing
# resource forks / extended attributes and has been the cause of
# "unable to build submission" notary errors in the past.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# notarise-hub: notarise + staple Ostler.app BEFORE the installer seals it.
#
# WHY THIS EXISTS (found on the v1.0.16 cut, 2026-08-07)
# ------------------------------------------------------
# `stapler staple` writes a nested app's ticket to <bundle>/Contents/
# CodeResources. When the OUTER installer app is signed, it seals the byte-for-
# byte contents of every nested bundle. So stapling a nested app AFTER the
# outer is signed either:
#
#   * ADDS a file the outer never sealed  -> "a sealed resource is missing or
#     invalid", the outer app is damaged; or
#   * leaves it untouched, if the nested app ALREADY carried an identical
#     ticket when the outer was signed.
#
# Every cut up to v1.0.15 took the second path by ACCIDENT. OstlerAssistant.app
# arrives already stapled inside the daemon tarball, and Ostler.app was never
# rebuilt -- it was the same bundle, stapled during some earlier cut, so
# re-stapling rewrote identical bytes and the seal survived.
#
# v1.0.16 is the first cut to rebuild the Hub (mandatory: Ostler.app bundles
# web/, so a stale one ships an old UI behind a correct daemon pin). A freshly
# built Hub has no ticket, the outer sealed it without one, and staple-apps
# broke the outer signature. The pipeline was only ever working because nobody
# rebuilt the Hub.
#
# The fix is to make the Hub what the daemon already is: independently
# notarised and stapled before anything seals it. Then staple-apps is a no-op
# rewrite of identical bytes and the outer stays valid -- and the Hub can also
# launch offline on first run, which is what #221 wanted in the first place.
notarise-hub: guard-local-cut check-tools
	@if [ ! -d "$(OSTLER_APP_PATH)" ]; then \
	    echo "ERROR: OSTLER_APP_PATH is not a directory: $(OSTLER_APP_PATH)" >&2; \
	    exit 1; \
	fi
	@if xcrun stapler validate "$(OSTLER_APP_PATH)" >/dev/null 2>&1; then \
	    echo "[skip] Ostler.app already carries a valid ticket -- nothing to do."; \
	else \
	    printf '[STEP] Re-signing embedded upgrade-payload Mach-Os inside Ostler.app\n'; \
	    PAYLOAD="$(OSTLER_APP_PATH)/Contents/Resources/ostler-payload"; \
	    if [ -d "$$PAYLOAD" ]; then \
	        find "$$PAYLOAD" -type f -perm +111 | while read -r bin; do \
	            if file "$$bin" 2>/dev/null | grep -q 'Mach-O'; then \
	                if ! codesign --verify --strict "$$bin" >/dev/null 2>&1; then \
	                    printf '  re-sign: %s\n' "$${bin#$(OSTLER_APP_PATH)/}"; \
	                    codesign --force --timestamp --options runtime \
	                        --sign "$(CODESIGN_ID)" "$$bin" >/dev/null 2>&1 \
	                        || { echo "  ERROR: could not re-sign $$bin" >&2; exit 1; }; \
	                fi; \
	            fi; \
	        done; \
	    fi; \
	    printf '[STEP] Sealing Ostler.app with Developer ID before notarisation\n'; \
	    codesign --force --timestamp --options runtime \
	        --sign "$(CODESIGN_ID)" "$(OSTLER_APP_PATH)" >/dev/null 2>&1 \
	        || { echo "ERROR: could not seal Ostler.app" >&2; exit 1; }; \
	    if ! codesign -dv "$(OSTLER_APP_PATH)" 2>&1 | grep -q 'TeamIdentifier=$(TEAM_ID)'; then \
	        echo "ERROR: Ostler.app is not Developer ID signed after sealing." >&2; \
	        echo "  Refusing to spend a notarisation cycle on a bundle Apple will reject." >&2; \
	        exit 1; \
	    fi; \
	    printf '[STEP] Notarising Ostler.app (Hub) so the installer seals a STAPLED bundle\n'; \
	    HUB_ZIP="$(BUILD_DIR)/Ostler-hub-notary.zip"; \
	    rm -f "$$HUB_ZIP"; \
	    ditto -c -k --sequesterRsrc --keepParent "$(OSTLER_APP_PATH)" "$$HUB_ZIP"; \
	    SUB_JSON="$(BUILD_DIR)/hub-notary-result.json"; \
	    xcrun notarytool submit "$$HUB_ZIP" --keychain-profile "$(NOTARY_PROFILE)" \
	        --wait --output-format json > "$$SUB_JSON" 2>&1 || true; \
	    cat "$$SUB_JSON"; \
	    STATUS="$$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$$SUB_JSON" 2>/dev/null)"; \
	    SUBID="$$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("id",""))' "$$SUB_JSON" 2>/dev/null)"; \
	    rm -f "$$HUB_ZIP"; \
	    if [ "$$STATUS" != "Accepted" ]; then \
	        echo "" >&2; \
	        echo "ERROR: Hub notarisation status is '$$STATUS' (not Accepted)." >&2; \
	        echo "  notarytool EXITS 0 even when the verdict is Invalid, so the status" >&2; \
	        echo "  must be read explicitly -- an exit-code check alone passes a rejection." >&2; \
	        echo "" >&2; \
	        echo "--- Apple's rejection log for $$SUBID ---" >&2; \
	        xcrun notarytool log "$$SUBID" --keychain-profile "$(NOTARY_PROFILE)" >&2 2>&1 \
	          || echo "  (could not fetch the log -- credentials or network)" >&2; \
	        echo "--- end rejection log ---" >&2; \
	        exit 1; \
	    fi; \
	    printf '[STEP] Stapling the ticket into Ostler.app\n'; \
	    xcrun stapler staple "$(OSTLER_APP_PATH)" || { echo "ERROR: stapler failed on Ostler.app" >&2; exit 1; }; \
	fi
	@xcrun stapler validate "$(OSTLER_APP_PATH)" >/dev/null 2>&1 || { \
	    echo "ERROR: Ostler.app has no valid ticket after notarise+staple." >&2; exit 1; }
	@codesign --verify --deep --strict "$(OSTLER_APP_PATH)" 2>/dev/null || { \
	    echo "ERROR: Ostler.app signature invalid after stapling -- do not seal it." >&2; exit 1; }
	@echo "[OK] Ostler.app notarised, stapled and still validly signed."

notarise-app: guard-local-cut check-tools
	@if [ ! -d "$(APP_PATH)" ]; then \
	    echo "ERROR: $(APP_PATH) not found. Run 'make release' + 'make sign-python-bundle' first." >&2; \
	    exit 1; \
	fi
	$(STEP) "Zipping $(APP_NAME).app for notary submission"
	@APP_ZIP="$(BUILD_DIR)/$(APP_NAME)-notary.zip"; \
	    rm -f "$$APP_ZIP"; \
	    ditto -c -k --sequesterRsrc --keepParent "$(APP_PATH)" "$$APP_ZIP"; \
	    printf '[OK] wrote %s (%s bytes)\n' "$$APP_ZIP" "$$(stat -f %z "$$APP_ZIP" 2>/dev/null || stat -c %s "$$APP_ZIP")"
	$(STEP) "Submitting $(APP_NAME).app zip to notarytool (profile: $(NOTARY_PROFILE))"
	@APP_ZIP="$(BUILD_DIR)/$(APP_NAME)-notary.zip"; \
	if ! xcrun notarytool submit "$$APP_ZIP" \
	        --keychain-profile "$(NOTARY_PROFILE)" \
	        --wait; then \
	    echo "" >&2; \
	    echo "App-bundle notarisation failed. Find the submission ID above and run:" >&2; \
	    echo "  xcrun notarytool log <submission-id> --keychain-profile $(NOTARY_PROFILE)" >&2; \
	    exit 1; \
	fi
	@rm -f "$(BUILD_DIR)/$(APP_NAME)-notary.zip"
	@echo "[OK] $(APP_NAME).app + every nested CDHash notarised. Ready to staple."

# ---------------------------------------------------------------------------
# staple-apps: staple the tickets INTO the .app bundles in the build tree.
#
# Order matters: DEEPEST FIRST. Apple's stapler writes the ticket to a
# well-known bundle path that codesign treats as an alternate resource;
# stapling a nested .app after the outer's --deep --strict verify is
# safe, but we still walk deepest-first so any surprise codesign
# consequence surfaces on the innermost item (easier to diagnose).
#
# find is used to enumerate every .app under $(APP_PATH)/Contents/, so
# a future new nested .app (e.g. an in-DMG Safari Extension) gets
# stapled automatically without a Makefile edit. The outer $(APP_PATH)
# is stapled LAST as its own step.
#
# HR015 task #221: without this step the DMG payload ships with
# unstapled inner .apps.
# ---------------------------------------------------------------------------
staple-apps: guard-local-cut check-tools
	@if [ ! -d "$(APP_PATH)" ]; then \
	    echo "ERROR: $(APP_PATH) not found. Run 'make notarise-app' first." >&2; \
	    exit 1; \
	fi
	# TWO NOTARISATION ROUNDS. This is the only order that satisfies both
	# constraints at once, and both are real:
	#
	#   (a) Nested .apps must carry tickets for their FINAL CDHash.
	#       install.sh dittos OstlerAssistant.app and Ostler.app out of this
	#       bundle to their own install locations, so Gatekeeper reads THEIR
	#       tickets. Verified: install.sh takes the bundled .app shape.
	#
	#   (b) The outer signature must stay valid.
	#       Stapling writes <bundle>/Contents/CodeResources, which the outer has
	#       sealed -- so any nested staple after the outer is signed breaks it:
	#       "a sealed resource is missing or invalid".
	#
	# Pre-stapling cannot satisfy (a): `xcodebuild -exportArchive` re-signs the
	# nested apps, so tickets applied before `release` are already STALE by the
	# time the export finishes. Measured directly on this cut.
	#
	# Therefore: staple nested AFTER notarise-app (tickets match final CDHashes),
	# then RE-SEAL the outer so it seals those new CodeResources, then notarise
	# the outer AGAIN for its new CDHash, then staple the outer. One extra
	# notarisation round (~5 min) buys a deterministic, valid artefact.
	# NEVER STAPLE A BUNDLE THAT LIVES INSIDE ANOTHER BUNDLE'S RESOURCES.
	#
	# codesign seals the two nesting locations differently:
	#   Contents/Frameworks/  nested CODE, sealed by the child's own CDHash.
	#                         Stapling stores the ticket outside the signed
	#                         area, so the parent's seal is untouched.
	#   Contents/Resources/   RESOURCES, sealed by file hash in CodeResources.
	#                         Stapling rewrites files there, so the parent's
	#                         seal breaks.
	#
	# v1.0.38 hit this. #890 moved the payload daemon from a bare binary to
	# OstlerAssistant.app, which put an .app under
	#   Ostler.app/Contents/Resources/ostler-payload/assistant-agent/
	# Stapling it broke Ostler.app's seal, and only the OUTER is re-sealed
	# below -- so Apple rejected round 2 (submission bd57c9ec):
	#
	#   path:    .../Ostler.app/Contents/MacOS/ostler-hub
	#   message: The signature of the binary is invalid.
	#
	# v1.0.37 is the control. Its staple list was identical MINUS that one
	# entry, and round 2 was Accepted. Sparkle's Updater.app sits under
	# Contents/Frameworks/ and has never caused this.
	#
	# Skipping the staple costs nothing that was ever had: the payload daemon
	# was a BARE BINARY through v1.0.37 and bare binaries cannot be stapled,
	# so no shipped version has carried a ticket there. It is still notarised
	# -- round 1 covers every nested CDHash -- so Gatekeeper accepts it on the
	# online check, exactly as it did for the bare binary.
	#
	# The predicate is about the MECHANISM, not one path: after stripping the
	# outer prefix, any remaining '.app/Contents/Resources/' means this bundle
	# sits in a nested bundle's resource-sealed subtree.
	$(STEP) "Round 1: stapling nested .apps (deepest-first) now their CDHashes are final"
	@FAIL=0; \
	NESTED_APPS="$$(find "$(APP_PATH)/Contents" -type d -name '*.app' 2>/dev/null | awk '{print length, $$0}' | sort -rn | cut -d' ' -f2-)"; \
	for app in $$NESTED_APPS; do \
	    REL="$${app#$(APP_PATH)/}"; \
	    case "$$REL" in \
	        *.app/Contents/Resources/*) \
	            printf '  [skip] %s\n' "$$REL"; \
	            printf '         inside a nested bundle Resources tree -- stapling would break its seal\n'; \
	            continue;; \
	    esac; \
	    if xcrun stapler staple "$$app" >/dev/null 2>&1; then \
	        printf '  [OK] %s\n' "$$REL"; \
	    else \
	        printf '  [skip] %s (no ticket issued for this CDHash)\n' "$$REL"; \
	    fi; \
	done
	$(STEP) "Round 1: re-sealing the outer .app so it seals the freshly stapled nested bundles"
	codesign --force --sign "$(CODESIGN_ID)" --options runtime --timestamp --entitlements "OstlerInstaller/OstlerInstaller.entitlements" "$(APP_PATH)"
	@codesign --verify --deep --strict "$(APP_PATH)" 2>/dev/null || { \
	    echo "ERROR: outer .app invalid immediately after the re-seal -- stop." >&2; exit 1; }
	@echo "[OK] outer re-sealed and valid; its CDHash has changed, so it needs a new ticket."
	$(STEP) "Round 2: re-notarising the outer .app for its new CDHash"
	@APP_ZIP="$(BUILD_DIR)/$(APP_NAME)-notary-round2.zip"; \
	SUB_JSON="$(BUILD_DIR)/round2-result.json"; \
	rm -f "$$APP_ZIP"; \
	ditto -c -k --sequesterRsrc --keepParent "$(APP_PATH)" "$$APP_ZIP"; \
	xcrun notarytool submit "$$APP_ZIP" --keychain-profile "$(NOTARY_PROFILE)" \
	    --wait --output-format json > "$$SUB_JSON" 2>&1 || true; \
	cat "$$SUB_JSON"; \
	STATUS="$$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$$SUB_JSON" 2>/dev/null)"; \
	SUBID="$$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("id",""))' "$$SUB_JSON" 2>/dev/null)"; \
	rm -f "$$APP_ZIP"; \
	if [ "$$STATUS" != "Accepted" ]; then \
	    echo "ERROR: round-2 notarisation status '$$STATUS' (not Accepted)." >&2; \
	    echo "  notarytool EXITS 0 on a rejection -- the status must be read." >&2; \
	    echo "" >&2; \
	    echo "--- Apple's rejection log for $$SUBID ---" >&2; \
	    xcrun notarytool log "$$SUBID" --keychain-profile "$(NOTARY_PROFILE)" >&2 2>&1 \
	      || echo "  (could not fetch the log -- credentials or network)" >&2; \
	    echo "--- end rejection log ---" >&2; \
	    exit 1; \
	fi
	$(STEP) "Round 2: stapling the outer .app"
	@xcrun stapler staple "$(APP_PATH)" || { echo "ERROR: stapler failed on the outer app" >&2; exit 1; }
	@printf '[OK] nested stapled, outer re-sealed, re-notarised and stapled\n'
	# The exclusion below MUST be the same predicate the Round 1 staple uses.
	# If they drift, this either fails the cut for a bundle we deliberately did
	# not staple, or silently stops requiring a ticket on one we did. They are
	# two halves of one rule -- change both or neither.
	#
	# The excluded bundles are COUNTED and NAMED, not skipped quietly: a gate
	# that can be emptied by an exclusion list has to say how much it excluded.
	$(STEP) "Verifying every stapled .app in $(APP_PATH)"
	@FAIL=0; EXCLUDED=0; CHECKED=0; \
	NESTED_APPS="$$(find "$(APP_PATH)/Contents" -type d -name '*.app' 2>/dev/null)"; \
	for app in "$(APP_PATH)" $$NESTED_APPS; do \
	    REL="$${app#$(APP_PATH)/}"; \
	    case "$$REL" in \
	        *.app/Contents/Resources/*) \
	            printf '  [expected-unstapled] %s\n' "$$REL"; \
	            EXCLUDED=$$((EXCLUDED+1)); \
	            continue;; \
	    esac; \
	    CHECKED=$$((CHECKED+1)); \
	    if xcrun stapler validate "$$app" >/dev/null 2>&1; then \
	        printf '  [OK] %s\n' "$$REL"; \
	    else \
	        printf '  [FAIL] %s -- ticket missing after staple\n' "$$REL" >&2; \
	        FAIL=$$((FAIL+1)); \
	    fi; \
	done; \
	printf '  %s bundle(s) required a ticket, %s deliberately excluded\n' "$$CHECKED" "$$EXCLUDED"; \
	[ "$$CHECKED" -ge 3 ] || { \
	    echo "ERROR: only $$CHECKED bundle(s) were ticket-checked -- expected at least 3" >&2; \
	    echo "  (outer, Ostler.app, Contents/Resources/assistant-agent/OstlerAssistant.app)." >&2; \
	    echo "  An exclusion has swallowed bundles that must carry tickets. DO NOT SHIP." >&2; \
	    exit 1; }; \
	[ "$$FAIL" -eq 0 ] || { echo "ERROR: post-staple validate failed on $$FAIL bundle(s)" >&2; exit 1; }
	$(STEP) "Re-verifying outer codesign after staple (--deep --strict)"
	@codesign --verify --deep --strict --verbose=2 "$(APP_PATH)" || { \
	    echo "" >&2; \
	    echo "ERROR: outer $(APP_NAME).app failed codesign --deep --strict after nested staple." >&2; \
	    echo "  Stapling nested .apps should not invalidate the outer signature. This is a" >&2; \
	    echo "  new failure mode -- investigate before shipping." >&2; \
	    exit 1; \
	}

# ---------------------------------------------------------------------------
# notarise-dmg: submit the packaged DMG for its own notarisation + staple.
# CDHashes for every inner bundle were already registered by notarise-app,
# so this submission returns fast. The DMG wrapper still needs its own
# ticket for Gatekeeper to accept the DMG mount on a first-launch offline.
# ---------------------------------------------------------------------------
notarise-dmg: guard-local-cut check-tools
	@if [ ! -f "$(DMG_PATH)" ]; then \
	    echo "ERROR: $(DMG_PATH) not found. Run 'make package' first." >&2; \
	    exit 1; \
	fi
	$(STEP) "Submitting $(DMG_NAME) to notarytool (profile: $(NOTARY_PROFILE))"
	@if ! xcrun notarytool submit "$(DMG_PATH)" \
	        --keychain-profile "$(NOTARY_PROFILE)" \
	        --wait; then \
	    echo "" >&2; \
	    echo "DMG notarisation failed. Find the submission ID above and run:" >&2; \
	    echo "  xcrun notarytool log <submission-id> --keychain-profile $(NOTARY_PROFILE)" >&2; \
	    exit 1; \
	fi
	@$(MAKE) --no-print-directory staple

# ---------------------------------------------------------------------------
# Backwards-compat alias: `make notarise` still submits the DMG + staples
# the DMG wrapper (pre-#221 behaviour). New ship chain uses notarise-app
# + staple-apps + notarise-dmg explicitly. Prefer those in new code.
# ---------------------------------------------------------------------------
notarise: notarise-dmg

staple: guard-local-cut check-tools
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
	for p in Ostler.app install.sh ostler-mecard ostler_security ostler_fda doctor hub-power assistant_api cm024_knowledge cm048_pipeline cm019_preferences cm021 contact_syncer meeting_syncer identity_resolver email-ingest imessage-bridge whatsapp_source email_source spoken_source imessage_source assistant-agent; do \
	    if [ ! -e "$$RES/$$p" ]; then MISSING="$$MISSING $$p"; fi; \
	done; \
	OSTLER_APP_OK=1; \
	HUB_EXE="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$$RES/Ostler.app/Contents/Info.plist" 2>/dev/null)"; \
	HUB_BIN="$$RES/Ostler.app/Contents/MacOS/$$HUB_EXE"; \
	if [ -z "$$HUB_EXE" ] || [ ! -x "$$HUB_BIN" ]; then \
	    OSTLER_APP_OK=0; \
	fi; \
	PAYLOAD_OK=1; \
	if [ ! -f "$$RES/Ostler.app/Contents/Resources/ostler-payload/VERSION" ]; then \
	    PAYLOAD_OK=0; \
	fi; \
	HUB_SHA="$$(strings "$$HUB_BIN" 2>/dev/null | grep -oE 'OSTLER_HUB_BUILD_SHA=[0-9a-f]{40}' | head -1 | cut -d= -f2)"; \
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
	MECARD_SIGN_OK=1; \
	MECARD_BIN_M="$$RES/ostler-mecard"; \
	if [ -e "$$MECARD_BIN_M" ]; then \
	    codesign -dvv "$$MECARD_BIN_M" 2>&1 | grep -q "Authority=Developer ID Application: Creative Machines Limited" || MECARD_SIGN_OK=0; \
	    codesign -dvv "$$MECARD_BIN_M" 2>&1 | grep -q "TeamIdentifier=$(TEAM_ID)" || MECARD_SIGN_OK=0; \
	    codesign -dvvv "$$MECARD_BIN_M" 2>&1 | grep -E "^CodeDirectory" | grep -q "runtime" || MECARD_SIGN_OK=0; \
	else \
	    MECARD_SIGN_OK=0; \
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
	    echo "ERROR: Ostler.app is present in Resources/ but its declared main" >&2; \
	    echo "       executable is missing or not executable." >&2; \
	    echo "       CFBundleExecutable = '$$HUB_EXE'" >&2; \
	    echo "       expected at         $$HUB_BIN" >&2; \
	    echo "       (an empty CFBundleExecutable means Info.plist is unreadable)" >&2; \
	    exit 1; \
	fi; \
	if [ "$$PAYLOAD_OK" = "0" ]; then \
	    echo "ERROR: (B-lite) upgrade payload missing from the bundled Ostler.app." >&2; \
	    echo "       Expected Ostler.app/Contents/Resources/ostler-payload/VERSION." >&2; \
	    echo "       stage-payload must run in the ship chain AFTER stage-daemon and" >&2; \
	    echo "       BEFORE sparkle-embed so the payload is sealed in the Hub signature." >&2; \
	    echo "       Without it, a v1.0.12 Sparkle update reaches only /Applications/Ostler.app" >&2; \
	    echo "       and cannot reconcile the daemon + services on the customer Mac." >&2; \
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
	if [ "$$MECARD_SIGN_OK" = "0" ]; then \
	    echo "ERROR: bundled ostler-mecard is NOT Developer-ID signed + hardened-runtime (Team $(TEAM_ID))." >&2; \
	    echo "       BW2-1: the me-card helper is a nested Mach-O at Contents/Resources/ostler-mecard;" >&2; \
	    echo "       the outer --force --deep reseal does NOT add hardened runtime (CX-124). sign-python-bundle" >&2; \
	    echo "       must re-sign it Developer-ID --options runtime before packaging, else notarytool rejects" >&2; \
	    echo "       the DMG -- a burnt cut cycle." >&2; \
	    exit 1; \
	fi; \
	echo "[OK] DMG payload verified -- Ostler.app + install.sh + all vendor packages + Developer-ID hardened-runtime daemon + ostler-mecard + embedded (B-lite) ostler-payload present (Hub build-SHA $$HUB_SHA)"

# ---------------------------------------------------------------------------
# verify-stapling: post-cut integrity gate for notarisation ticket staples.
#
# HR015 task #221 (offline first-launch blocker): the v1.0.8 DMG shipped
# with every nested .app UNSTAPLED. `xcrun stapler validate` on the DMG
# wrapper returned "The validate action worked!" but the same command on
# Ostler.app + OstlerAssistant.app + OstlerInstaller.app inside the mount
# returned "does not have a ticket stapled" (or exit 65 on Sonoma+ quiet
# mode). Customers without internet on first launch hit Gatekeeper.
#
# Sibling to task #226 (commit-parity gate + other post-cut integrity
# gates). Both classes share the same shape: mount the shipped artefact
# and prove one thing that a green make-ship alone does NOT prove.
#
# Delegates to scripts/verify_stapling.sh so the gate can be unit-tested
# against fixture .apps with a shim stapler (see
# scripts/tests/test_verify_stapling_gate.sh). Per
# feedback_gate_must_prove_it_fires_not_just_compile, silent no-op gates
# are worse than no gate.
# ---------------------------------------------------------------------------
STAPLING_SH ?= $(CURDIR)/../scripts/verify_stapling.sh
verify-stapling:
	@if [ ! -f "$(DMG_PATH)" ]; then \
	    echo "ERROR: the stapling gate COULD NOT RUN -- $(DMG_PATH) not found." >&2; \
	    echo "       No ticket has been found missing; there is no DMG to check." >&2; \
	    echo "       Run 'make ship' first. DO NOT SHIP." >&2; \
	    exit 2; \
	fi
	$(STEP) "Post-cut stapling gate -- every .app + DMG wrapper must carry a ticket (#221)"
	@rc=0; bash "$(STAPLING_SH)" "$(DMG_PATH)" || rc=$$?; \
	if [ "$$rc" -eq 2 ] || [ "$$rc" -eq 3 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the stapling gate COULD NOT RUN (exit $$rc)." >&2; \
	    echo "       It has NOT found an unstapled artifact -- it failed to look" >&2; \
	    echo "       (bad arguments, unmountable DMG, or stapler unavailable)." >&2; \
	    echo "       A cut whose staples were never checked is not a checked cut." >&2; \
	    echo "       DO NOT SHIP." >&2; \
	    exit "$$rc"; \
	elif [ "$$rc" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: stapling gate FAILED -- an artifact carries no notarisation ticket (#221)." >&2; \
	    echo "       Re-staple the named artifact(s) and re-run. DO NOT SHIP." >&2; \
	    exit 1; \
	fi

# ---------------------------------------------------------------------------
# verify-commit-parity: post-cut integrity gate asserting the Tauri wrapper
# and the ostler-assistant daemon were built from the same source commit
# for the web/dist frontend they each embed.
#
# HR015 task #226 (permanent commit-parity gate). Sibling to task #221.
#
# Class-of-bug (HR015 #225, v1.0.13 cut 2026-07-30): make ship built a
# fresh daemon (hub-v0.4.43, new web/dist/index-DCT9-lP0.js, 6-digit code
# removed) BUT copied the Ostler.app Tauri wrapper stale from
# ~/Documents/Projects/ostler-assistant/target/release/bundle/macos/Ostler.app.
# The stale wrapper embedded pre-2026-06-29 web/dist/index-BlCfKuJD.js
# still rendering the 6-digit code. Both binaries: signed, notarised,
# stapled; verify-dmg-contents + verify-stapling both GREEN; customer
# first-launch UI BROKEN.
#
# The sibling PR in ostler-ai/ostler-assistant stamps:
#   * WRAPPER_FRONTEND_COMMIT=<40-hex> into the Tauri wrapper binary
#   * DAEMON_FRONTEND_COMMIT=<40-hex>  into the ostler-assistant daemon
# via `env!()` at build time (fully codesigning-invariant, discoverable
# via `strings | grep`). This gate mounts the DMG, extracts BOTH markers
# via strings|grep, and fails the cut CLOSED if they differ or are
# absent.
#
# Delegates to scripts/verify_commit_parity.sh so the assertion can be
# unit-tested against fixture binaries with a shim `strings` (see
# scripts/tests/test_verify_commit_parity_gate.sh). Per
# feedback_gate_must_prove_it_fires_not_just_compile, silent no-op gates
# are worse than no gate.
# ---------------------------------------------------------------------------
COMMIT_PARITY_SH ?= $(CURDIR)/../scripts/verify_commit_parity.sh

# Pre-seal sibling of COMMIT_PARITY_SH. Same question, asked at step 5 instead
# of post-cut, and asserted on frontend CONTENT rather than commit-SHA equality.
APP_PROVENANCE_SH ?= $(CURDIR)/../scripts/verify_app_provenance.sh

# Resolves cuts/<tag>/cut.env DAEMON_COMMIT, preferring the FULL version over the
# truncated CUT_MANIFEST_VERSION so a hotfix does not silently read its parent's
# pin. A script rather than a recipe so the fallback WARN is testable.
CUT_PIN_RESOLVER_SH ?= $(CURDIR)/../scripts/resolve_cut_daemon_pin.sh
verify-commit-parity:
	@if [ ! -f "$(DMG_PATH)" ]; then \
	    echo "ERROR: the commit-parity gate COULD NOT RUN -- $(DMG_PATH) not found." >&2; \
	    echo "       No drift has been found; there is no DMG to check." >&2; \
	    echo "       Run 'make ship' first. DO NOT SHIP." >&2; \
	    exit 2; \
	fi
	$(STEP) "Post-cut commit-parity gate -- daemon + wrapper must embed the same web/dist (HR015 #225 / #226)"
	@rc=0; bash "$(COMMIT_PARITY_SH)" "$(DMG_PATH)" || rc=$$?; \
	if [ "$$rc" -eq 2 ] || [ "$$rc" -eq 3 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the commit-parity gate COULD NOT RUN (exit $$rc)." >&2; \
	    echo "       It has NOT found the daemon and wrapper to disagree -- it" >&2; \
	    echo "       failed to look (unmountable DMG, or 'strings' unavailable)." >&2; \
	    echo "       This is the exact gate that would have caught the v1.0.13" >&2; \
	    echo "       stale wrapper, and it has just told you nothing. DO NOT SHIP." >&2; \
	    exit "$$rc"; \
	elif [ "$$rc" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: commit-parity gate FAILED -- daemon and Tauri wrapper embed DIFFERENT" >&2; \
	    echo "       web/dist commits, or a marker is absent (HR015 #225 / #226)." >&2; \
	    echo "       Rebuild both from one commit and re-cut. DO NOT SHIP." >&2; \
	    exit 1; \
	fi

# ---------------------------------------------------------------------------
# One-shot: validate → build → notarise-app → staple-apps → package
#          → notarise-dmg → verify-dmg-contents → verify-stapling
#          → verify-commit-parity → archive
#
# check-ostler-app runs first so we fail fast on the empty/missing
# OSTLER_APP_PATH case (caught 2026-05-21 — would have saved one DMG cut).
#
# Notarisation is now split into TWO passes to fix HR015 #221 (offline
# first-launch blocker). Old chain: package -> notarise-DMG -> staple-DMG,
# which left every nested .app unstapled inside the DMG payload.
# New chain: notarise the outer OstlerInstaller.app (registers every
# nested CDHash at Apple), staple deepest-first in the build tree, THEN
# package into the DMG, then notarise + staple the DMG wrapper for its
# own Gatekeeper mount ticket.
#
# verify-dmg-contents  catches silent-skip payload regressions.
# verify-stapling      catches per-.app stapling regressions (#221).
# verify-commit-parity catches daemon+wrapper frontend drift (#226 / #225).
# All three must be GREEN before archive writes to ~/.ostler-release-artefacts/.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# guard-local-cut -- addresses v1018-D027.
#
# WHY THIS EXISTS. Five months of cuts were hand-made on this laptop. Every
# gate we built was advisory, because `make ship` would happily sign, notarise
# and staple a DMG that had passed none of them. v1.0.18 is the proof: 13/13
# manifest assertions green, and the box-walk found 20 defects. A gate that can
# be walked around is documentation, not a gate.
#
# So the CAPABILITY goes, not the convenience. Cuts run in CI (v1018-D026).
#
# THE ESCAPE HATCH IS DELIBERATE, AND IT IS LOUD. A hand-cut under duress has
# to remain possible -- refusing that just gets the guard commented out at 3am.
# What it must never be is SILENT. So OSTLER_EMERGENCY_CUT=1 requires a reason
# AND a writable shipping ledger, and it FAILS CLOSED: if the cut cannot be
# recorded, the cut does not happen. An untraceable escape hatch is how we end
# up back here in three months.
# ---------------------------------------------------------------------------
.PHONY: guard-local-cut
guard-local-cut:
	@if [ -n "$${CI:-}" ] || [ -n "$${GITHUB_ACTIONS:-}" ]; then \
	    echo "  [guard] CI detected -- cut permitted."; \
	elif [ "$${OSTLER_EMERGENCY_CUT:-}" = "1" ]; then \
	    if [ -z "$${OSTLER_EMERGENCY_REASON:-}" ]; then \
	        echo "ERROR: OSTLER_EMERGENCY_CUT=1 requires OSTLER_EMERGENCY_REASON." >&2; \
	        echo "       An emergency cut must say why, in the ledger, for ever." >&2; \
	        exit 1; \
	    fi; \
	    if [ -z "$${OSTLER_SHIPPING_LEDGER:-}" ]; then \
	        echo "ERROR: OSTLER_EMERGENCY_CUT=1 requires OSTLER_SHIPPING_LEDGER" >&2; \
	        echo "       to point at the SHIPPING_LEDGER.yaml to append to." >&2; \
	        echo "       No ledger, no record; no record, no cut." >&2; \
	        exit 1; \
	    fi; \
	    if [ ! -w "$${OSTLER_SHIPPING_LEDGER:-}" ]; then \
	        echo "ERROR: shipping ledger not writable: $${OSTLER_SHIPPING_LEDGER:-}" >&2; \
	        echo "       Failing closed -- an unrecordable cut must not proceed." >&2; \
	        exit 1; \
	    fi; \
	    { \
	      echo ""; \
	      echo "- emergency_cut:"; \
	      echo "    utc: \"$$(date -u +%Y-%m-%dT%H:%M:%SZ)\""; \
	      echo "    operator: \"$$(id -un)@$$(hostname -s)\""; \
	      echo "    repo_sha: \"$$(git rev-parse HEAD 2>/dev/null || echo unknown)\""; \
	      echo "    dirty: $$(test -n \"$$(git status --porcelain 2>/dev/null)\" && echo true || echo false)"; \
	      echo "    reason: \"$${OSTLER_EMERGENCY_REASON:-}\""; \
	      echo "    note: \"Bypassed CI (v1018-D026). Recorded by guard-local-cut (v1018-D027).\""; \
	    } >> "$${OSTLER_SHIPPING_LEDGER:-}" || { \
	        echo "ERROR: failed writing the ledger entry. Refusing to cut." >&2; exit 1; }; \
	    echo "  [guard] EMERGENCY cut recorded in $${OSTLER_SHIPPING_LEDGER:-}"; \
	else \
	    echo "" >&2; \
	    echo "REFUSING TO CUT LOCALLY  (v1018-D027)" >&2; \
	    echo "" >&2; \
	    echo "  Signing and notarising happen in CI, triggered by pushing a" >&2; \
	    echo "  v1.0.X tag. A DMG built here would bypass every gate in" >&2; \
	    echo "  OS003/cuts/DEFECTS_ROLLFORWARD.md, which is exactly how" >&2; \
	    echo "  v1.0.18 shipped 20 defects with all its own gates green." >&2; \
	    echo "" >&2; \
	    echo "  To cut:       git tag v1.0.X && git push origin v1.0.X" >&2; \
	    echo "  To build      make debug          (unsigned, local, safe)" >&2; \
	    echo "  In a real     OSTLER_EMERGENCY_CUT=1 \\" >&2; \
	    echo "  emergency:    OSTLER_EMERGENCY_REASON='...' \\" >&2; \
	    echo "                OSTLER_SHIPPING_LEDGER=/path/SHIPPING_LEDGER.yaml make ship" >&2; \
	    echo "                (recorded permanently in the ledger)" >&2; \
	    echo "" >&2; \
	    exit 1; \
	fi

# ---------------------------------------------------------------------------
# publish-appcast -- AU-1. Sign the Sparkle-embedded Hub and publish its
# appcast entry, so this release becomes reachable by every installed Hub.
#
# Zips $(OSTLER_APP_PATH) -- the same bundle sparkle-embed stamped, notarise-hub
# stapled and the DMG carries -- signs the .zip with the Sparkle EdDSA key via
# CM050's `ostler-release sign`, then `ostler-release publish` uploads it to R2
# and appends the manifest entry in KV. After that the appcast.xml the Hubs
# poll lists this release. Governed by PUBLISH_APPCAST; see the config block.
#
# WHERE THIS RUNS, AND WHY IT IS NOT IN `ship:`.
#
#   IT USED TO BE the final prerequisite of `ship:`, and that is what burnt
#   v1.0.34: a late `ship:` step failed and destroyed an already-notarised
#   DMG. The publish now runs from .github/workflows/cut.yml, AFTER the
#   artefact has been uploaded, so a publish failure costs a red tick and a
#   diagnosis rather than a version number.
#
#   DO NOT RE-ADD IT TO `ship:`. tests/test_appcast_publish_cannot_destroy_
#   the_dmg.sh exists to keep it out, and the comment that used to sit here
#   claimed the opposite for three days -- which is precisely why the whole
#   pipeline read as unwired to the next person who looked.
#
#   EVIDENCE. Order alone is a promise about make's scheduler, and `make -j`
#   does not make it. So the recipe re-derives, at run time, that the artefact
#   it is about to advertise actually got through the gates: the DMG must
#   exist at $(DMG_PATH), and the Hub bundle must carry a VALID STAPLED TICKET.
#   Run early, or run against a cut that failed, both checks fail and nothing
#   is published. Publishing a feed entry for an artefact that failed
#   verification is worse than not publishing at all: the DMG that failed
#   stays on the shelf, but a bad appcast row goes to every installed machine.
#
# THE VERSION GUARD IS NOT OPTIONAL AND IS NOT REMOTE. Sparkle silently skips
# any entry whose sparkle:version is <= the installed CFBundleVersion, so a
# wrong version is a publish that succeeds and reaches nobody. The check runs
# locally, via $(APPCAST_GUARD_PY), BEFORE anything is signed or uploaded.
#
# MEASURED 2026-08-17 -- why the guard is not simply delegated to the CLI, as
# CM051 PR #463 wrote it. `ostler-release publish` on CM050 origin/main accepts
# --signature --version --build --channel --notes-url --min-os --pub-date and
# nothing else. `--reference-app` and `--dry-run` exist only on the unmerged
# branches feat/au1-appcast-version-guard (CM050 PR #41, OPEN) and
# feat/au1-release-publish-dryrun. Calling them today is not a strict guard,
# it is a usage error that kills every cut at its last step. So the predicate
# lives beside its caller, and --reference-app is threaded into the real
# publish only if the installed CLI advertises it -- defence in depth that
# switches itself on the day #41 lands, and is INERT until then. Inert is
# safe here precisely because the local guard is not conditional.
# ---------------------------------------------------------------------------
publish-appcast:
	$(STEP) "AU-1: appcast publish (PUBLISH_APPCAST=$(PUBLISH_APPCAST))"
	@MODE="$(PUBLISH_APPCAST)"; \
	if [ "$$MODE" = "0" ] || [ "$$MODE" = "no" ] || [ "$$MODE" = "off" ]; then \
	    echo "[SKIP] PUBLISH_APPCAST=$$MODE -- not publishing an appcast entry for this cut."; \
	    exit 0; \
	fi; \
	if [ "$$MODE" = "onbox" ]; then \
	    echo "" ; \
	    echo "============================================================================" ; \
	    echo "APPCAST NOT PUBLISHED HERE, AND THAT IS DELIBERATE." ; \
	    echo "" ; \
	    echo "  The DMG for this cut is COMPLETE. This step did not fail." ; \
	    echo "" ; \
	    echo "  The Sparkle EdDSA private key is NOT held on this repo, which is" ; \
	    echo "  public. Signing happens on the box. That is a settled decision," ; \
	    echo "  not an outstanding question, and re-tagging will not change it." ; \
	    echo "" ; \
	    echo "  THE APPCAST IS NOW OWED FOR THIS VERSION. Until it is published," ; \
	    echo "  installed Hubs will never see this release: the feed does not" ; \
	    echo "  list it, so auto-update stays silent and looks healthy." ; \
	    echo "" ; \
	    echo "  ON THE BOX, run:" ; \
	    echo "    export OSTLER_SPARKLE_SIGNING_KEY=/path/sparkle_private.pem  # 0400/0600" ; \
	    echo "    make -C gui publish-appcast PUBLISH_APPCAST=1" ; \
	    echo "" ; \
	    echo "  This debt is not left to memory. tests/test_appcast_debt_is_collected.sh" ; \
	    echo "  REFUSES the next cut while a RELEASED version has no appcast entry." ; \
	    echo "  (Released, not merely cut: a build nobody can download owes no feed entry.)" ; \
	    echo "============================================================================" ; \
	    exit 0; \
	fi; \
	if [ "$$MODE" = "1" ] || [ "$$MODE" = "yes" ]; then HARD=1; else HARD=0; fi; \
	if [ -z "$${OSTLER_SPARKLE_SIGNING_KEY:-}" ]; then \
	    if [ "$$HARD" = "1" ]; then \
	        echo "" >&2; \
	        echo "ERROR: PUBLISH_APPCAST=$$MODE (hard-require) but OSTLER_SPARKLE_SIGNING_KEY is unset." >&2; \
	        echo "  Export the path to the decrypted Sparkle EdDSA PEM (mode 0400/0600) and re-run." >&2; \
	        echo "  See CM050 appcast-server/docs/RELEASE_PROCESS.md (signing session)." >&2; \
	        exit 1; \
	    fi; \
	    echo "" >&2; \
	    echo "============================================================================" >&2; \
	    echo "WARNING: appcast NOT published -- OSTLER_SPARKLE_SIGNING_KEY is unset." >&2; \
	    echo "  The DMG shipped, but NO appcast entry was added, so the auto-update feed" >&2; \
	    echo "  does not list this release and installed Hubs will never see it." >&2; \
	    echo "  To publish: run the Sparkle signing session, then:" >&2; \
	    echo "    export OSTLER_SPARKLE_SIGNING_KEY=/path/sparkle_private.pem   # 0400/0600" >&2; \
	    echo "    make publish-appcast            # (or re-run make ship)" >&2; \
	    echo "  Force-require it next time with: make ship PUBLISH_APPCAST=1" >&2; \
	    echo "============================================================================" >&2; \
	    echo "" >&2; \
	    exit 0; \
	fi; \
	if ! command -v "$(OSTLER_RELEASE_BIN)" >/dev/null 2>&1; then \
	    echo "ERROR: ostler-release CLI not found ('$(OSTLER_RELEASE_BIN)')." >&2; \
	    echo "  Install CM050 release-tooling: cd '<CM050>/release-tooling' && pip install -e ." >&2; \
	    echo "  Or pass OSTLER_RELEASE_BIN=/path/to/.venv/bin/ostler-release." >&2; \
	    exit 1; \
	fi; \
	APP="$(OSTLER_APP_PATH)"; \
	if [ ! -d "$$APP" ]; then \
	    echo "ERROR: OSTLER_APP_PATH is not a directory: $$APP" >&2; \
	    echo "  Cannot zip the Hub app for the appcast enclosure." >&2; \
	    exit 1; \
	fi; \
	if [ ! -f "$(DMG_PATH)" ]; then \
	    echo "" >&2; \
	    echo "ERROR: refusing to publish -- $(DMG_PATH) does not exist." >&2; \
	    echo "  This step advertises a release to every installed Hub, so it must not" >&2; \
	    echo "  run unless the cut it is advertising actually completed. Run 'make ship'." >&2; \
	    exit 1; \
	fi; \
	if ! xcrun stapler validate "$$APP" >/dev/null 2>&1; then \
	    echo "" >&2; \
	    echo "ERROR: refusing to publish -- the Hub bundle carries no valid stapled ticket." >&2; \
	    echo "  $$APP" >&2; \
	    echo "  notarise-hub + staple-apps + verify-stapling run BEFORE this step in" >&2; \
	    echo "  'make ship'. Seeing an unstapled bundle here means either this target was" >&2; \
	    echo "  run out of order, or the cut it belongs to did not pass its gates. Either" >&2; \
	    echo "  way the bytes are not fit to advertise. DO NOT PUBLISH." >&2; \
	    exit 1; \
	fi; \
	PLIST="$$APP/Contents/Info.plist"; \
	VER="$(HUB_VERSION)"; [ -n "$$VER" ] || VER="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$PLIST" 2>/dev/null || true)"; \
	BUILD="$(HUB_BUILD)"; [ -n "$$BUILD" ] || BUILD="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$$PLIST" 2>/dev/null || true)"; \
	MINOS="$(HUB_MIN_OS)"; [ -n "$$MINOS" ] || MINOS="$$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$$PLIST" 2>/dev/null || true)"; \
	[ -n "$$MINOS" ] || MINOS="13.0"; \
	if [ -z "$$VER" ]; then echo "ERROR: could not read Hub CFBundleShortVersionString from $$PLIST (set HUB_VERSION=)." >&2; exit 1; fi; \
	if [ -z "$$BUILD" ]; then echo "ERROR: could not read Hub CFBundleVersion from $$PLIST (set HUB_BUILD=)." >&2; exit 1; fi; \
	rc=0; \
	python3 "$(APPCAST_GUARD_PY)" --version "$$VER" --build "$$BUILD" \
	    --reference-app "$(HUB_REFERENCE_APP)" || rc=$$?; \
	if [ "$$rc" -eq 2 ]; then \
	    echo "" >&2; \
	    echo "ERROR: the AU-1 version guard COULD NOT RUN (exit 2)." >&2; \
	    echo "       It has NOT found the version to be wrong -- it failed to look." >&2; \
	    echo "       A publish whose version was never checked is not a checked publish." >&2; \
	    echo "       DO NOT PUBLISH." >&2; \
	    exit 2; \
	elif [ "$$rc" -ne 0 ]; then \
	    echo "" >&2; \
	    echo "ERROR: AU-1 appcast-version guard FAILED -- refusing to sign or publish." >&2; \
	    echo "       Sparkle would silently skip this entry and no Hub would ever get it." >&2; \
	    exit 1; \
	fi; \
	ZIP="$(DIST_DIR)/$(HUB_RELEASE_BASENAME)-$$VER.zip"; \
	mkdir -p "$(DIST_DIR)"; \
	rm -f "$$ZIP"; \
	printf '[STEP] Zipping Sparkle-embedded Hub -> %s\n' "$$ZIP"; \
	ditto -c -k --sequesterRsrc --keepParent "$$APP" "$$ZIP"; \
	printf '[STEP] Signing %s (ostler-release sign)\n' "$$ZIP"; \
	SIG="$$('$(OSTLER_RELEASE_BIN)' sign "$$ZIP")"; \
	if [ -z "$$SIG" ]; then echo "ERROR: ostler-release sign produced an empty signature." >&2; exit 1; fi; \
	if [ -n "$${OSTLER_SPARKLE_PUBLIC_KEY:-}" ]; then \
	    printf '[STEP] Verifying signature against %s\n' "$$OSTLER_SPARKLE_PUBLIC_KEY"; \
	    '$(OSTLER_RELEASE_BIN)' verify "$$ZIP" --signature "$$SIG" --public-key "$$OSTLER_SPARKLE_PUBLIC_KEY"; \
	fi; \
	REF_OPT=""; \
	if [ -n "$(HUB_REFERENCE_APP)" ] && [ -d "$(HUB_REFERENCE_APP)" ] && \
	   '$(OSTLER_RELEASE_BIN)' publish --help 2>/dev/null | grep -q -- '--reference-app'; then \
	    REF_OPT="yes"; \
	    printf '[STEP] CLI advertises --reference-app; threading it through as a second opinion.\n'; \
	fi; \
	printf '[STEP] Publishing appcast entry: v%s build %s channel %s\n' "$$VER" "$$BUILD" "$(APPCAST_CHANNEL)"; \
	if [ -n "$$REF_OPT" ]; then \
	    OSTLER_APPCAST_DIR="$(OSTLER_APPCAST_DIR)" '$(OSTLER_RELEASE_BIN)' publish "$$ZIP" \
	        --signature "$$SIG" --version "$$VER" --build "$$BUILD" \
	        --channel "$(APPCAST_CHANNEL)" --notes-url "$(RELEASE_NOTES_BASE)/$$VER.html" \
	        --min-os "$$MINOS" --reference-app "$(HUB_REFERENCE_APP)"; \
	else \
	    OSTLER_APPCAST_DIR="$(OSTLER_APPCAST_DIR)" '$(OSTLER_RELEASE_BIN)' publish "$$ZIP" \
	        --signature "$$SIG" --version "$$VER" --build "$$BUILD" \
	        --channel "$(APPCAST_CHANNEL)" --notes-url "$(RELEASE_NOTES_BASE)/$$VER.html" \
	        --min-os "$$MINOS"; \
	fi; \
	printf '[OK] ostler-release publish reported success for Hub v%s (%s)\n' "$$VER" "$(APPCAST_CHANNEL)"; \
	printf '[STEP] Confirming the FEED actually changed\n'; \
	if ! bash "$(VERIFY_APPCAST_SH)" --version "$$VER" --build "$$BUILD"; then \
	    echo "" >&2; \
	    echo "ERROR: publish reported success and the feed does NOT list v$$VER." >&2; \
	    echo "  Publishing is not the same event as the feed changing, and until" >&2; \
	    echo "  now only the first was ever checked. Do not record this version" >&2; \
	    echo "  as published." >&2; \
	    exit 1; \
	fi; \
	printf '[OK] Appcast entry published AND confirmed live for Hub v%s (%s)\n' "$$VER" "$(APPCAST_CHANNEL)"

# ---------------------------------------------------------------------------
# verify-appcast -- AU-1. Ask the FEED whether this release is actually there.
#
# `publish` exiting 0 is a fact about a subprocess. The customer's Hub does not
# poll a subprocess, it polls a feed, and until this target existed nothing in
# the estate had ever asked the feed anything.
#
# MEASURED 2026-08-19T16:53:19Z, production, with the last cut's version:
#     scripts/verify_appcast_published.sh --version 1.0.36 --build 2500
#     -> items 0, NOT PUBLISHED, rc 1
#
# HTTP 200, valid Sparkle RSS, zero <item>. Valid-and-empty: every installed
# Hub is correctly told there is nothing newer and can never upgrade, and no
# surface anywhere goes red. That held for 36 cuts.
#
# Runs against $(HUB_VERSION) when pinned, else the Sparkle-embedded
# Info.plist, so it verifies the SAME version publish-appcast advertised
# rather than a value typed twice.
VERIFY_APPCAST_SH ?= $(CURDIR)/../scripts/verify_appcast_published.sh
verify-appcast:
	$(STEP) "AU-1: verify this version is live on the appcast feed"
	@VER="$(HUB_VERSION)"; BUILD="$(HUB_BUILD)"; \
	APP="$(OSTLER_APP_PATH)"; \
	if [ -z "$$VER" ] && [ -d "$$APP" ]; then \
	    VER="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$APP/Contents/Info.plist" 2>/dev/null || true)"; \
	fi; \
	if [ -z "$$BUILD" ] && [ -d "$$APP" ]; then \
	    BUILD="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$$APP/Contents/Info.plist" 2>/dev/null || true)"; \
	fi; \
	if [ -z "$$VER" ]; then \
	    echo "verify-appcast: CANNOT RUN -- no version. Pass HUB_VERSION=X.Y.Z or build the app first." >&2; \
	    exit 2; \
	fi; \
	bash "$(VERIFY_APPCAST_SH)" --version "$$VER" $${BUILD:+--build "$$BUILD"}

# ---------------------------------------------------------------------------
# THE CUT. Order is the contract: every gate sits before the step whose output
# it is allowed to bless.
#
# publish-appcast is deliberately NOT in this list. It is the only step whose
# output leaves this machine and reaches customers, and when it lived here a
# failure at the end destroyed the finished DMG (v1.0.34). It now runs from
# cut.yml after the artefact is uploaded. See the publish-appcast block above.
# ---------------------------------------------------------------------------
ship: guard-local-cut check-orphans check-pr-age download-hub-app check-ostler-app download-safari-extension download-python stage-daemon stage-payload sparkle-embed notarise-hub release sign-python-bundle check-manifest notarise-app staple-apps package notarise-dmg verify-dmg-contents verify-stapling verify-commit-parity archive
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
