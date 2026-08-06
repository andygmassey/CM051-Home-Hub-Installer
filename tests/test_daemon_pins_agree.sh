#!/usr/bin/env bash
#
# test_daemon_pins_agree.sh
#
# The daemon version and its SHA-256 are written in FIVE places. They must all
# say the same thing, and the SHA must match the tarball the release actually
# serves.
#
#   1. install.sh   OSTLER_ASSISTANT_VERSION default
#   2. install.sh   DEFAULT_ASSISTANT_TARBALL_SHA256
#   3. gui/Makefile DAEMON_VERSION
#   4. gui/Makefile DAEMON_SHA256
#   5. the published hub-v<version> release asset
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

# Non-emptiness FIRST. An empty capture compares equal to another empty
# capture, which is how a broken extractor reports perfect agreement.
for pair in "install.sh version:$INSTALL_VER" "install.sh sha:$INSTALL_SHA" \
            "Makefile version:$MAKE_VER" "Makefile sha:$MAKE_SHA"; do
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
    bad "VERSION DRIFT: install.sh=$INSTALL_VER but Makefile=$MAKE_VER -- the DMG would bundle one daemon and the installer expect another"
fi

if [[ "$INSTALL_SHA" == "$MAKE_SHA" ]]; then
    ok "SHA-256 agrees across install.sh and gui/Makefile"
else
    bad "SHA DRIFT: install.sh=$INSTALL_SHA but Makefile=$MAKE_SHA -- this is the D4 drift CUT_STEPS warns about"
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
