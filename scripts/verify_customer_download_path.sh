#!/usr/bin/env bash
# ============================================================================
# THE URL A CUSTOMER ACTUALLY CLICKS MUST SERVE THE VERSION WE JUST CUT.
#
# On 2026-08-20, with v1.0.37 cut, notarised, stapled and independently
# verified by two agents, https://ostler.ai/install.dmg returned 404. It had
# for weeks. Nobody noticed because:
#
#   - the cut uploads a workflow ARTEFACT, which we fetch with a token
#   - the box-walk installs from a LOCAL .dmg
#   - no gate ever fetched the customer-facing URL
#
# Every check we owned looked at an object only we could reach. This one looks
# at the object a stranger reaches, unauthenticated, exactly as a buyer does.
#
# The redirect chain is load-bearing and is checked, not assumed: ostler.ai
# 302s to a GitHub `releases/latest/download/` path, and GitHub excludes
# PRERELEASES from `latest`. That is precisely how a July build was skipped in
# favour of a May one that carried no DMG at all.
#
# Exit: 0 serves the expected version | 1 wrong/missing | 2 CANNOT-RUN
# ============================================================================
set -uo pipefail

URL="${OSTLER_DOWNLOAD_URL:-https://ostler.ai/install.dmg}"
WANT="${1:-}"

say() { printf '%s\n' "$*"; }

if [ -z "${WANT}" ]; then
    say "usage: $0 <expected-version>   e.g. $0 1.0.37" >&2
    exit 2
fi
command -v curl >/dev/null 2>&1 || { say "[CANNOT] curl absent" >&2; exit 2; }

say "== customer download path: ${URL} =="
say "   expecting version ${WANT}"
say ""

# --- 1. the redirect, reported not assumed ---------------------------------
code="$(curl -sS -o /dev/null -w '%{http_code}' "${URL}" 2>/dev/null || echo 000)"
target="$(curl -sS -o /dev/null -w '%{redirect_url}' "${URL}" 2>/dev/null || true)"
say "   first hop : HTTP ${code}"
[ -n "${target}" ] && say "   redirects : ${target}"

if [ "${code}" = "000" ]; then
    say "[CANNOT] no HTTP response -- network unreachable from here, NOT a verdict on the URL" >&2
    exit 2
fi

# --- 2. follow it and actually GET the bytes -------------------------------
tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
final_code="$(curl -sSL -o "${tmp}" -w '%{http_code}' "${URL}" 2>/dev/null || echo 000)"
size="$(wc -c < "${tmp}" | tr -d ' ')"
say "   final     : HTTP ${final_code}, ${size} bytes"
say ""

if [ "${final_code}" != "200" ]; then
    say "[FAIL] a customer clicking this link gets HTTP ${final_code}."
    say "       The DMG may be cut, notarised and verified and STILL be unreachable:"
    say "       the cut uploads a workflow artefact, which is not a public release."
    say "       If the redirect targets a GitHub 'releases/latest/' path, check that"
    say "       the newest release is NOT marked prerelease -- GitHub skips those,"
    say "       and will happily fall back to an older tag with no DMG attached."
    exit 1
fi

# --- 3. a 200 is not enough: it must be a DMG, and the RIGHT version -------
# A 200 serving an HTML error page, or last month's build, is the failure this
# gate exists to catch. Assert the artefact, not the status code.
if ! head -c 512 "${tmp}" | grep -qa 'koly\|bzip\|zlib\|encrcdsa' && [ "${size}" -lt 1000000 ]; then
    say "[FAIL] 200 but the payload is ${size} bytes and does not look like a DMG."
    say "       A 200 serving an error page is worse than a 404: it reads as success."
    exit 1
fi

if command -v hdiutil >/dev/null 2>&1; then
    mnt="$(mktemp -d)"
    if hdiutil attach -nobrowse -readonly -mountpoint "${mnt}" "${tmp}" >/dev/null 2>&1; then
        got="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
               "${mnt}"/*.app/Contents/Info.plist 2>/dev/null || true)"
        hdiutil detach "${mnt}" >/dev/null 2>&1 || true
        rmdir "${mnt}" 2>/dev/null || true
        if [ -z "${got}" ]; then
            say "[CANNOT] mounted the DMG but could not read CFBundleShortVersionString"
            exit 2
        fi
        say "   served version: ${got}"
        if [ "${got}" != "${WANT}" ]; then
            say ""
            say "[FAIL] the download serves ${got}, the cut produced ${WANT}."
            say "       Customers would receive a DIFFERENT build from the one gated."
            exit 1
        fi
        say ""
        say "[OK] ${URL} serves a real DMG at version ${got} -- the customer path works."
        exit 0
    fi
    say "[CANNOT] could not mount the downloaded DMG to read its version"
    exit 2
fi

say "[CANNOT] hdiutil unavailable -- got a plausible DMG (${size} bytes) but could"
say "         NOT confirm the version. Run this on macOS for the full check."
exit 2
