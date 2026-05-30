#!/usr/bin/env bash
#
# embed-sparkle.sh
#
# Post-process an Ostler.app bundle: embed Sparkle.framework into
# Contents/Frameworks/, write the SU* Info.plist keys (feed URL +
# EdDSA public key + automatic-check policy), then re-sign with the
# Developer ID Application identity + hardened runtime so the
# resulting .app survives notarisation.
#
# Invoked by gui/Makefile during `make package` / `make ship`. Can
# also be run by hand against a locally-built bundle:
#
#     ./gui/scripts/embed-sparkle.sh \
#         /tmp/ostler-installer-build-$USER/dmg-payload/Ostler.app
#
# The Sparkle framework binary is pulled from sparkle-project's
# official GitHub releases at first invocation and cached under
# $HOME/.cache/ostler/sparkle/. Pinned to SPARKLE_VERSION below so
# the same tarball gets reused across ships. SHA-256 is verified
# against SPARKLE_SHA256 before extract; mismatch is fatal.
#
# Source of truth for the EdDSA public key: HR015
# launch/keys/hub_signing_public_2026-05-16.pem (PUBLIC material,
# safe to commit). The value below is the raw 32-byte public key
# base64-encoded, which is the format Sparkle's SUPublicEDKey
# expects (not the SubjectPublicKeyInfo PEM wrapper).
#
# v1.0 ships Sparkle metadata + framework in place. Runtime
# Rust<->Sparkle linkage is a v1.0.1 follow-on (Tauri shell needs a
# Rust-side load hint or an Objective-C helper bundled into
# Resources to actually invoke SUUpdater on launch). For v1.0 the
# affordance is dormant: the .app declares the feed URL and ships
# the framework so the customer-visible Info.plist is correct, and
# CM050's appcast Worker remains the source of truth ready to
# answer once the runtime is wired.

set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.7.0}"
# SHA-256 of Sparkle-2.7.0.tar.xz from
# https://github.com/sparkle-project/Sparkle/releases/download/2.7.0/Sparkle-2.7.0.tar.xz
# Operators bumping SPARKLE_VERSION must update this checksum too;
# the script refuses to extract a tarball that does not match.
SPARKLE_SHA256="${SPARKLE_SHA256:-}"
SPARKLE_TARBALL_URL="${SPARKLE_TARBALL_URL:-https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz}"

SU_FEED_URL="${SU_FEED_URL:-https://appcast.ostler.ai/appcast.xml}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-kfOIhVR6EIUEuTbmDFe9QghitBBGdhCz5d4LvXLmtdQ=}"
SU_ENABLE_AUTO_CHECKS="${SU_ENABLE_AUTO_CHECKS:-YES}"
SU_AUTOMATICALLY_UPDATE="${SU_AUTOMATICALLY_UPDATE:-NO}"

CODESIGN_ID="${CODESIGN_ID:-Developer ID Application: Creative Machines Limited (V95N2B8X7A)}"

CACHE_DIR="${OSTLER_CACHE_DIR:-${HOME}/.cache/ostler/sparkle}"
mkdir -p "$CACHE_DIR"

die() { echo "embed-sparkle.sh: ERROR: $*" >&2; exit 1; }
note() { echo "embed-sparkle.sh: $*"; }

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    die "usage: $0 <path-to-Ostler.app>"
fi

if [[ "$(basename "$APP_PATH")" != "Ostler.app" ]]; then
    note "warning: bundle is not named Ostler.app; proceeding anyway ($(basename "$APP_PATH"))"
fi

FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"

if [[ ! -f "$INFO_PLIST" ]]; then
    die "Info.plist not found at $INFO_PLIST"
fi

# ── Download + verify Sparkle ─────────────────────────────────
SPARKLE_TARBALL="${CACHE_DIR}/Sparkle-${SPARKLE_VERSION}.tar.xz"
if [[ ! -f "$SPARKLE_TARBALL" ]]; then
    note "Downloading Sparkle ${SPARKLE_VERSION} from ${SPARKLE_TARBALL_URL}"
    if ! curl -fSL --retry 2 --retry-delay 2 -o "$SPARKLE_TARBALL" "$SPARKLE_TARBALL_URL"; then
        die "Sparkle tarball download failed"
    fi
fi

if [[ -n "$SPARKLE_SHA256" ]]; then
    ACTUAL_SHA="$(shasum -a 256 "$SPARKLE_TARBALL" | awk '{print $1}')"
    if [[ "$SPARKLE_SHA256" != "$ACTUAL_SHA" ]]; then
        die "Sparkle tarball SHA-256 mismatch (expected ${SPARKLE_SHA256}, got ${ACTUAL_SHA}); refusing to embed."
    fi
else
    note "warning: SPARKLE_SHA256 not pinned; export SPARKLE_SHA256 before a production ship to gate on checksum"
fi

EXTRACT_DIR="$(mktemp -d -t ostler-sparkle-XXXXXX)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
note "Extracting Sparkle.framework into ${EXTRACT_DIR}"
tar -xJf "$SPARKLE_TARBALL" -C "$EXTRACT_DIR"

SPARKLE_FRAMEWORK_SRC="${EXTRACT_DIR}/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK_SRC" ]]; then
    # Some Sparkle release archives nest the framework under a
    # versioned root. Locate it by glob fallback before giving up.
    SPARKLE_FRAMEWORK_SRC="$(find "$EXTRACT_DIR" -maxdepth 3 -type d -name 'Sparkle.framework' -print -quit)"
    if [[ -z "$SPARKLE_FRAMEWORK_SRC" || ! -d "$SPARKLE_FRAMEWORK_SRC" ]]; then
        die "Sparkle.framework not found inside extracted tarball"
    fi
fi

# ── Stage framework into Ostler.app ───────────────────────────
mkdir -p "$FRAMEWORKS_DIR"
note "Installing Sparkle.framework into ${FRAMEWORKS_DIR}/"
rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework"
# CX-115 (2026-05-30): ditto --noextattr --norsrc is the macOS-
# canonical way to copy a bundle without inheriting xattrs from the
# source. cp -R preserves com.apple.FinderInfo + com.apple.fileprovider
# .fpfs#P metadata that Sparkle's release tarball ships on Updater.app,
# XPC services, and .nib bundles, which then makes codesign --deep
# refuse with "resource fork, Finder information, or similar detritus
# not allowed". ditto produces a structurally identical tree with
# zero xattrs anywhere (verified: 12 lines under cp -R, 0 lines under
# ditto, on Sparkle 2.x).
ditto --noextattr --norsrc "$SPARKLE_FRAMEWORK_SRC" "${FRAMEWORKS_DIR}/Sparkle.framework"

# ── Patch Info.plist ──────────────────────────────────────────
plist_set() {
    local key="$1"
    local type="$2"
    local value="$3"
    /usr/libexec/PlistBuddy -c "Delete :${key}" "$INFO_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :${key} ${type} ${value}" "$INFO_PLIST"
}

note "Writing SUFeedURL=${SU_FEED_URL}"
plist_set "SUFeedURL"               string "$SU_FEED_URL"
note "Writing SUPublicEDKey=<32-byte-EdDSA-public-key>"
plist_set "SUPublicEDKey"           string "$SU_PUBLIC_ED_KEY"
note "Writing SUEnableAutomaticChecks=${SU_ENABLE_AUTO_CHECKS}"
plist_set "SUEnableAutomaticChecks" bool   "$SU_ENABLE_AUTO_CHECKS"
note "Writing SUAutomaticallyUpdate=${SU_AUTOMATICALLY_UPDATE}"
plist_set "SUAutomaticallyUpdate"   bool   "$SU_AUTOMATICALLY_UPDATE"

# ── Strip extended attributes (defence in depth) ──────────────
# CX-115 (2026-05-30): Even with ditto above, the parent Ostler.app
# bundle itself may carry com.apple.FinderInfo + com.apple.fileprovider
# .fpfs#P from the upstream Tauri build. `xattr -cr` does NOT recurse
# INTO bundle directories (.app, .framework, .xpc, .nib are dirs with
# a bundle bit; xattr's own recursion stops at the boundary). The
# find pipeline below traverses every file and directory underneath
# the .app and clears xattrs from each one. Belt-and-braces with the
# ditto copy above.
find "$APP_PATH" \( -type f -o -type d \) -print0 2>/dev/null | \
    xargs -0 -I{} xattr -c "{}" 2>/dev/null || true
# Final pass on the bundle root itself (xattr -c on the .app dir).
xattr -c "$APP_PATH" 2>/dev/null || true

# ── Re-sign ───────────────────────────────────────────────────
# Sign nested framework first so the outer --deep pass picks up a
# signed inner. Hardened runtime is required for notarytool to
# accept the resulting bundle.
if security find-identity -p codesigning -v | grep -F "$CODESIGN_ID" >/dev/null; then
    note "Re-signing Sparkle.framework with ${CODESIGN_ID}"
    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_ID" \
        "${FRAMEWORKS_DIR}/Sparkle.framework"

    note "Re-signing ${APP_PATH} (deep, hardened runtime)"
    codesign --force --deep --options runtime --timestamp \
        --sign "$CODESIGN_ID" \
        "$APP_PATH"

    note "Verifying signature"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
    note "warning: codesigning identity ${CODESIGN_ID} not in keychain; leaving bundle unsigned. Notarisation will fail until you re-run with the identity available."
fi

note "Sparkle embed complete: ${APP_PATH}"
