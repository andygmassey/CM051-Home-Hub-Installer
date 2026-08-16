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
# against SPARKLE_SHA256 before extract; mismatch is fatal, and so
# is an ABSENT checksum.
#
# THAT SENTENCE USED TO BE FALSE, AND THAT IS WHY IT IS WORTH READING
# TWICE. SPARKLE_SHA256 defaulted to EMPTY and the verification was
# wrapped in `if [[ -n "$SPARKLE_SHA256" ]]`, so on every ship the
# check SKIPPED and printed a warning, while this header told the
# reader the tarball had been verified. v1.0.32 was cut that way.
#
# The exposure was not only the download. The cache branch below
# reuses an existing tarball WITHOUT re-downloading it, so with the
# check disabled a stale or tampered cache file was embedded into a
# signed, notarised bundle and nothing would ever have said so.
#
# A comment is not a control. The pin is now a measured constant and
# the check runs unconditionally.
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

# MEASURED, not copied from a README. Two samples of
# Sparkle-2.7.0.tar.xz taken three months apart -- a cache written
# 2026-05-20 and a fresh fetch from the release URL on 2026-08-16 --
# are byte-identical at 13,339,780 bytes, which is what an immutable
# release tag is supposed to look like.
#
# The pin is bound to the version it was measured against. Bumping
# SPARKLE_VERSION without re-measuring is REFUSED rather than
# silently compared against the wrong constant, because "expected X,
# got Y" on a version you deliberately changed reads as a compromise
# scare when it is really an un-updated pin.
SPARKLE_PINNED_VERSION="2.7.0"
SPARKLE_PINNED_SHA256="09fed60cca507d2dc542c86c22e525598af5483954a5c66366ce039647ec88e9"

if [[ -z "${SPARKLE_SHA256:-}" ]]; then
    if [[ "$SPARKLE_VERSION" != "$SPARKLE_PINNED_VERSION" ]]; then
        echo "embed-sparkle.sh: ERROR: SPARKLE_VERSION is ${SPARKLE_VERSION}, but the built-in checksum was measured against ${SPARKLE_PINNED_VERSION}." >&2
        echo "  Measure the new tarball and update SPARKLE_PINNED_VERSION + SPARKLE_PINNED_SHA256 together, or export SPARKLE_SHA256 for this run." >&2
        exit 1
    fi
    SPARKLE_SHA256="$SPARKLE_PINNED_SHA256"
fi
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

# --self-test proves the checksum gate FIRES, rather than proving it
# compiles. Five controls, and each one is a way the predicate could
# be wrong rather than a way it could be right. Control (3) is the
# defect this file was carrying: an absent checksum must be fatal and
# not a skip. Control (5) refuses a placeholder pin, because a gate
# whose expected value is a row of zeros forgives everything.
if [[ "${1:-}" == "--self-test" ]]; then
    st_pass=0; st_fail=0
    st() {
        if [[ "$2" == "$3" ]]; then
            echo "  PASS  $1"; st_pass=$((st_pass + 1))
        else
            echo "  FAIL  $1 (expected $3, got $2)"; st_fail=$((st_fail + 1))
        fi
    }
    # The comparator, isolated from any download.
    cmp_sha() {
        [[ -z "$1" ]] && return 2
        [[ "$1" == "$2" ]] && return 0
        return 1
    }
    echo "embed-sparkle.sh: self-test"

    # `rc=0; cmd || rc=$?` and NOT `cmd; rc=$?`. This script runs under
    # `set -e`, so a negative control that fails ON PURPOSE kills the harness
    # before it can be scored. Written the naive way, this self-test printed
    # control (1) and exited 1, which reads exactly like a real failure.
    rc=0; cmp_sha "$SPARKLE_PINNED_SHA256" "$SPARKLE_PINNED_SHA256" || rc=$?
    st "(1) matching checksum accepts" "$rc" "0"

    rc=0; cmp_sha "$SPARKLE_PINNED_SHA256" "deadbeef" || rc=$?
    st "(2) mismatching checksum refuses" "$rc" "1"

    rc=0; cmp_sha "" "$SPARKLE_PINNED_SHA256" || rc=$?
    st "(3) EMPTY checksum refuses, never skips" "$rc" "2"

    # Version drift must refuse rather than compare against the wrong pin.
    rc=0
    ( SPARKLE_VERSION="9.9.9" SPARKLE_SHA256="" bash "$0" --resolve-pin-only >/dev/null 2>&1 ) || rc=$?
    st "(4) version bump without a new pin refuses" "$rc" "1"

    # The pin must be a real 64-hex digest, not a placeholder.
    if [[ "$SPARKLE_PINNED_SHA256" =~ ^[0-9a-f]{64}$ ]] \
       && [[ "$SPARKLE_PINNED_SHA256" != "$(printf '0%.0s' $(seq 1 64))" ]]; then
        rc=0
    else
        rc=1
    fi
    st "(5) the pin is a real digest, not a placeholder" "$rc" "0"

    echo ""
    echo "=== $st_pass passed / $st_fail failed ==="
    [[ "$st_fail" -eq 0 ]] || exit 1
    exit 0
fi

# Internal: resolve the pin and exit. Exists so the self-test can
# exercise the version-drift refusal in a real subprocess rather than
# re-implementing it, which would test the copy and not the code.
if [[ "${1:-}" == "--resolve-pin-only" ]]; then
    echo "$SPARKLE_SHA256"
    exit 0
fi

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    die "usage: $0 <path-to-Ostler.app>  |  $0 --self-test"
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

# UNCONDITIONAL. There is deliberately no branch that skips this.
# An empty SPARKLE_SHA256 reaching here means someone exported it
# empty on purpose, and "verify against nothing" must be an error,
# never a warning that a build log scrolls past.
if [[ -z "$SPARKLE_SHA256" ]]; then
    die "SPARKLE_SHA256 resolved empty; refusing to embed an unverified framework into a signed bundle."
fi
ACTUAL_SHA="$(shasum -a 256 "$SPARKLE_TARBALL" | awk '{print $1}')"
if [[ "$SPARKLE_SHA256" != "$ACTUAL_SHA" ]]; then
    die "Sparkle tarball SHA-256 mismatch (expected ${SPARKLE_SHA256}, got ${ACTUAL_SHA}); refusing to embed. If you just bumped SPARKLE_VERSION, re-measure and update the pin; if you did not, treat the cached tarball at ${SPARKLE_TARBALL} as suspect and delete it."
fi
note "Sparkle ${SPARKLE_VERSION} tarball verified against pinned SHA-256"

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
cp -R "$SPARKLE_FRAMEWORK_SRC" "${FRAMEWORKS_DIR}/Sparkle.framework"
# Strip macOS extended attributes (com.apple.FinderInfo,
# com.apple.fileprovider.fpfs#P, com.apple.quarantine, etc.) that
# hitchhike either from the Sparkle tarball's .nib resource forks or
# from an iCloud-synced staging dir. codesign --deep refuses to sign a
# bundle carrying any "resource fork, Finder information, or similar
# detritus" -- 2026-07-31 v1.0.13.1 recut hit this on the .nib carriers
# even after moving the .app to /tmp. Belt-and-braces: strip xattrs on
# the framework AND on the outer .app after all inner staging is done.
xattr -cr "${FRAMEWORKS_DIR}/Sparkle.framework" 2>/dev/null || true
xattr -cr "$APP_PATH" 2>/dev/null || true

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
