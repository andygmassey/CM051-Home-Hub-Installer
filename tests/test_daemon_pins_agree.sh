#!/usr/bin/env bash
#
# test_daemon_pins_agree.sh
#
# The daemon version and its SHA-256 are written in SIX places. They must all
# say the same thing, and each SHA must match the tarball its release actually
# serves.
#
#   1. install.sh   OSTLER_ASSISTANT_VERSION default
#   2. install.sh   DEFAULT_ASSISTANT_TARBALL_SHA256
#   3. gui/Makefile DAEMON_VERSION
#   4. gui/Makefile DAEMON_SHA256
#   5. the published hub-v<version> asset in ostler-ai/ostler-RELEASES
#   6. gui/Makefile HUB_APP_SHA256, and the ostler-hub-app asset at the SAME
#      TAG in ostler-ai/ostler-ASSISTANT
#
# 🔴 SITE 6 WAS ADDED 2026-08-23 AFTER THIS GATE FAILED TO CATCH THE DEFECT IT
# EXISTS FOR. This header said FIVE, and the enumeration was the denominator:
# CM051 #983 bumped DAEMON_VERSION and moved sites 2, 3 and 4, left site 6
# pointing at v0.4.62, and every PR check passed. The cut then refused at
# `download-hub-app` with "Ostler.app tarball SHA-256 mismatch".
#
# The reason site 6 is easy to forget is worth stating: DAEMON_VERSION is the
# version of TWO DIFFERENT ARTEFACTS IN TWO DIFFERENT REPOS. hub-v<version>
# exists in ostler-releases (the Developer ID signed daemon) AND in
# ostler-assistant (the adhoc Hub app wrapper), and only the first is public.
# A gate whose population is one short is not a gate that fails to fire; it is
# a gate that cannot see part of what it is named for.
#
# WHY
# ---
# CUT_STEPS for v1.0.15 names this as "where cuts rot", and says of sites 2
# and 4: "the known D4 drift is that nothing compares them." Nothing did. So a
# DMG could ship an install.sh that verifies one SHA while the Makefile bundles
# a different daemon, and both halves look individually correct.
#
# It nearly happened on the v1.0.16 cut: three sites were bumped and the
# DEFAULT_ASSISTANT_TARBALL_SHA256 was missed. Caught by reading the cut steps,
# not by any gate.
#
# NOTE ON THE CHECK ITSELF
# ------------------------
# The first version of this comparison captured both SHAs into variables that
# came back EMPTY, and `[ "$A" = "$B" ]` was therefore true. A vacuous pass.
# So every capture is asserted non-empty BEFORE it is compared -- an empty
# extraction is a failure of this test, not a silent agreement.
#
# Usage: bash tests/test_daemon_pins_agree.sh
#        SKIP_REMOTE=1 bash tests/... # skip the release-asset check (offline)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
MAKEFILE="$REPO_ROOT/gui/Makefile"

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

printf '== test_daemon_pins_agree ==\n'
for f in "$INSTALL" "$MAKEFILE"; do
    [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 3; }
done

INSTALL_VER="$(grep 'OSTLER_ASSISTANT_VERSION:-' "$INSTALL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
INSTALL_SHA="$(grep 'DEFAULT_ASSISTANT_TARBALL_SHA256="' "$INSTALL" | grep -oE '[a-f0-9]{64}' | head -1)"
MAKE_VER="$(grep -E '^DAEMON_VERSION' "$MAKEFILE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
MAKE_SHA="$(grep -E '^DAEMON_SHA256' "$MAKEFILE" | grep -oE '[a-f0-9]{64}' | head -1)"
HUB_SHA="$(grep -E '^HUB_APP_SHA256' "$MAKEFILE" | grep -oE '[a-f0-9]{64}' | head -1)"

# WHERE each value came from, captured with the SAME pattern that captured the
# value, so a drift message can name a file:line the reader can open. Without
# these the message said only "install.sh=A but Makefile=B" and left the reader
# to re-derive both sites by hand -- on a 10k-line install.sh that is the
# difference between a fix and a hunt. Line numbers only; the comparison and
# the exit status below are unchanged.
INSTALL_VER_LN="$(grep -n -m1 'OSTLER_ASSISTANT_VERSION:-' "$INSTALL" | cut -d: -f1)"
INSTALL_SHA_LN="$(grep -n -m1 'DEFAULT_ASSISTANT_TARBALL_SHA256="' "$INSTALL" | cut -d: -f1)"
MAKE_VER_LN="$(grep -n -m1 -E '^DAEMON_VERSION' "$MAKEFILE" | cut -d: -f1)"
MAKE_SHA_LN="$(grep -n -m1 -E '^DAEMON_SHA256' "$MAKEFILE" | cut -d: -f1)"
HUB_SHA_LN="$(grep -n -m1 -E '^HUB_APP_SHA256' "$MAKEFILE" | cut -d: -f1)"

# Non-emptiness FIRST. An empty capture compares equal to another empty
# capture, which is how a broken extractor reports perfect agreement.
for pair in "install.sh version:$INSTALL_VER" "install.sh sha:$INSTALL_SHA" \
            "Makefile version:$MAKE_VER" "Makefile sha:$MAKE_SHA" \
            "Makefile hub-app sha:$HUB_SHA"; do
    label="${pair%%:*}"; value="${pair#*:}"
    if [[ -n "$value" ]]; then
        ok "extracted $label = $value"
    else
        bad "could not extract $label -- the pin format changed; this test would otherwise pass vacuously"
    fi
done
[[ "$fail" -eq 0 ]] || { printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1; }

if [[ "$INSTALL_VER" == "$MAKE_VER" ]]; then
    ok "version agrees across install.sh and gui/Makefile ($INSTALL_VER)"
else
    bad "VERSION DRIFT: install.sh:${INSTALL_VER_LN} OSTLER_ASSISTANT_VERSION=$INSTALL_VER but gui/Makefile:${MAKE_VER_LN} DAEMON_VERSION=$MAKE_VER -- the DMG would bundle one daemon and the installer expect another; set both to the same version"
fi

if [[ "$INSTALL_SHA" == "$MAKE_SHA" ]]; then
    ok "SHA-256 agrees across install.sh and gui/Makefile"
else
    bad "SHA DRIFT: install.sh:${INSTALL_SHA_LN} DEFAULT_ASSISTANT_TARBALL_SHA256=$INSTALL_SHA but gui/Makefile:${MAKE_SHA_LN} DAEMON_SHA256=$MAKE_SHA -- this is the D4 drift CUT_STEPS warns about; re-pin both from the published .sha256 sidecar"
fi

# The pinned SHA must match the bytes the release actually serves. A local
# tarball is preferred (fast, and it is what the build consumes); otherwise
# fetch the published .sha256 sidecar.
LOCAL_TARBALL=""
for cand in \
    "$HOME/Developer/ostler-assistant/ostler-assistant-aarch64-apple-darwin-v${INSTALL_VER}.tar.gz" \
    "$HOME/.ostler-release-artefacts/ostler-assistant-aarch64-apple-darwin-v${INSTALL_VER}.tar.gz"; do
    [[ -f "$cand" ]] && { LOCAL_TARBALL="$cand"; break; }
done

if [[ -n "$LOCAL_TARBALL" ]]; then
    REAL="$(shasum -a 256 "$LOCAL_TARBALL" | awk '{print $1}')"
    if [[ "$REAL" == "$INSTALL_SHA" ]]; then
        ok "pinned SHA matches the real tarball on disk"
    else
        bad "pinned SHA does NOT match $LOCAL_TARBALL (real=$REAL) -- the pin describes bytes nobody has"
    fi
elif [[ "${SKIP_REMOTE:-0}" == "1" ]]; then
    echo "  [skip] no local tarball and SKIP_REMOTE=1"
elif command -v gh >/dev/null 2>&1; then
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    if gh release download "hub-v${INSTALL_VER}" --repo ostler-ai/ostler-releases \
         --pattern '*.tar.gz.sha256' --dir "$TMP" >/dev/null 2>&1; then
        PUB="$(cat "$TMP"/*.sha256 2>/dev/null | grep -oE '[a-f0-9]{64}' | head -1)"
        if [[ -z "$PUB" ]]; then
            bad "published .sha256 for hub-v${INSTALL_VER} is unreadable"
        elif [[ "$PUB" == "$INSTALL_SHA" ]]; then
            ok "pinned SHA matches the published hub-v${INSTALL_VER} asset"
        else
            bad "pinned SHA != published asset (published=$PUB) -- the release was rebuilt without re-pinning"
        fi
    else
        echo "  [skip] could not reach the hub-v${INSTALL_VER} release (auth/offline)"
    fi
else
    echo "  [skip] no local tarball and gh unavailable"
fi

# ---------------------------------------------------------------------------
# SITE 6: gui/Makefile HUB_APP_SHA256, against the ostler-hub-app asset at the
# SAME TAG in ostler-ai/ostler-ASSISTANT.
#
# Two assertions, and the first is the cheap one that would have caught #983.
# ---------------------------------------------------------------------------
if [[ "$HUB_SHA" == "$MAKE_SHA" ]]; then
    bad "HUB_APP_SHA256 and DAEMON_SHA256 are IDENTICAL (gui/Makefile:${HUB_SHA_LN} and :${MAKE_SHA_LN}) -- they describe DIFFERENT artefacts in DIFFERENT repos, so equality means one was pasted over the other"
else
    ok "HUB_APP_SHA256 is distinct from DAEMON_SHA256 (different artefacts)"
fi

HUB_TARBALL_NAME="ostler-hub-app-aarch64-apple-darwin-v${MAKE_VER}.tar.gz"
LOCAL_HUB=""
for cand in \
    "$HOME/Developer/ostler-assistant/${HUB_TARBALL_NAME}" \
    "$HOME/.ostler-release-artefacts/${HUB_TARBALL_NAME}"; do
    [[ -f "$cand" ]] && { LOCAL_HUB="$cand"; break; }
done

if [[ -n "$LOCAL_HUB" ]]; then
    REAL_HUB="$(shasum -a 256 "$LOCAL_HUB" | awk '{print $1}')"
    if [[ "$REAL_HUB" == "$HUB_SHA" ]]; then
        ok "HUB_APP_SHA256 matches the real hub-app tarball on disk"
    else
        bad "HUB_APP_SHA256 does NOT match $LOCAL_HUB (real=$REAL_HUB) -- gui/Makefile:${HUB_SHA_LN} describes bytes nobody has"
    fi
elif [[ "${SKIP_REMOTE:-0}" == "1" ]]; then
    echo "  [skip] no local hub-app tarball and SKIP_REMOTE=1"
elif command -v gh >/dev/null 2>&1; then
    # ostler-ASSISTANT, not ostler-releases. Different repo, and PRIVATE, so an
    # anonymous fetch returns an HTML error page whose sha256 is a perfectly
    # well-formed 64-hex string. That nearly reached a pin on 2026-08-23, which
    # is why the value is read from the SIDECAR and matched against the pin
    # rather than computed over whatever the download produced.
    HTMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "$HTMP"' EXIT
    if gh release download "hub-v${MAKE_VER}" --repo ostler-ai/ostler-assistant \
         --pattern "${HUB_TARBALL_NAME}.sha256" --dir "$HTMP" >/dev/null 2>&1; then
        PUB_HUB="$(cat "$HTMP"/*.sha256 2>/dev/null | grep -oE '[a-f0-9]{64}' | head -1)"
        if [[ -z "$PUB_HUB" ]]; then
            bad "published ${HUB_TARBALL_NAME}.sha256 is unreadable -- an unreadable sidecar is not agreement"
        elif [[ "$PUB_HUB" == "$HUB_SHA" ]]; then
            ok "HUB_APP_SHA256 matches the published hub-v${MAKE_VER} hub-app asset"
        else
            bad "HUB_APP_SHA256 != published hub-app asset (published=$PUB_HUB) -- gui/Makefile:${HUB_SHA_LN} was not moved with DAEMON_VERSION"
        fi
    else
        echo "  [skip] could not reach hub-v${MAKE_VER} in ostler-assistant (auth/offline). NOT a pass: site 6 is unverified in this run."
    fi
else
    echo "  [skip] no local hub-app tarball and gh unavailable"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
