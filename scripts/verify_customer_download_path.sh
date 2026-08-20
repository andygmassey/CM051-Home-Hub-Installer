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

# ---------------------------------------------------------------------------
# POSTURE, declared by the caller. Pre-launch the release is a DRAFT: invisible
# publicly, so the public URL still 404s BY DESIGN. Asserting the public URL in
# that window would red every cut for a known and intended reason, and a gate
# that reds for an intended reason is one people learn to ignore, then disable.
# That is exactly how a URL went unwatched for 45 days.
#
# So assert the strongest TRUE thing for the posture instead of skipping:
#
#   prelaunch  the DRAFT release exists for this tag and carries an asset named
#              EXACTLY OstlerInstaller.dmg at the expected byte count. This has
#              real teeth today -- it catches the v0.4.1 failure mode (release
#              present, DMG absent or under another name) while it is still
#              cheap, rather than on launch morning.
#   public     the unauthenticated URL check below, exactly as a buyer sees it.
#
# Never `continue-on-error` and never a skipped step: both switch the gate off
# while leaving it looking on.
# ---------------------------------------------------------------------------
POSTURE="${OSTLER_DOWNLOAD_POSTURE:-public}"
RELEASE_REPO="${OSTLER_RELEASE_REPO:-ostler-ai/ostler-installer}"
WANT_BYTES="${OSTLER_EXPECTED_DMG_BYTES:-}"
ASSET_NAME="OstlerInstaller.dmg"   # the redirect matches on FILENAME; v0.4.1
                                   # 404s precisely because it carries only the
                                   # daemon tarball under a different name.

check_draft_release() {
    local tag="v${1}"
    command -v gh >/dev/null 2>&1 || { say "[CANNOT] gh absent -- cannot inspect ${RELEASE_REPO}" >&2; return 2; }
    WORK_OUT="$(mktemp)"   # created HERE: only this path uses it, and the single
                           # EXIT trap above clears it on 0, 1 and 2 alike.
    say "== PRE-LAUNCH posture: draft release ${tag} on ${RELEASE_REPO} =="
    local json
    json="$(gh api "repos/${RELEASE_REPO}/releases" --paginate 2>/dev/null)" || {
        say "[CANNOT] could not list releases on ${RELEASE_REPO} (auth? network?)" >&2; return 2; }

    printf '%s' "${json}" | python3 -c '
import json,sys
tag, asset, want = sys.argv[1], sys.argv[2], sys.argv[3]
rels = json.load(sys.stdin)
match = [r for r in rels if r.get("tag_name") == tag]
if not match:
    print("FAIL|no release for %s -- the cut did not publish, or published elsewhere" % tag); raise SystemExit(0)
r = match[0]
names = [a["name"] for a in r.get("assets", [])]
if asset not in names:
    print("FAIL|release %s exists but has NO asset named exactly %s. assets: %s" % (tag, asset, ", ".join(names) or "(none)"))
    print("INFO|  this is the v0.4.1 failure mode: a release the redirect resolves to, carrying no DMG under that name.")
    raise SystemExit(0)
a = [x for x in r["assets"] if x["name"] == asset][0]
if want and str(a["size"]) != want:
    print("FAIL|%s is %s bytes, the cut produced %s -- a DIFFERENT build was attached" % (asset, a["size"], want)); raise SystemExit(0)
print("OK|draft=%s, %s present, %s bytes%s" % (r.get("draft"), asset, a["size"], "" if want else " (size not pinned -- pass OSTLER_EXPECTED_DMG_BYTES)"))
if not r.get("draft"):
    print("INFO|  NOTE: this release is NOT a draft. If that is intentional (launch), switch to POSTURE=public.")
' "${tag}" "${ASSET_NAME}" "${WANT_BYTES}" > "${WORK_OUT}" 2>&1

    local verdict msg line
    line="$(head -1 "${WORK_OUT}")"; verdict="${line%%|*}"; msg="${line#*|}"
    sed -n '2,$p' "${WORK_OUT}" | sed 's/^INFO|/   /'
    case "${verdict}" in
        OK)   say "[OK] ${msg}"; return 0 ;;
        FAIL) say "[FAIL] ${msg}"; return 1 ;;
        *)    say "[CANNOT] ${line}"; return 2 ;;
    esac
}

if [ -z "${WANT}" ]; then
    say "usage: $0 <expected-version>   e.g. $0 1.0.37" >&2
    exit 2
fi
# 🔴 ONE trap, registered ONCE. `trap ... EXIT` REPLACES the previous handler
# rather than adding to it, so the original pair of traps leaked the first temp
# file on every run: WORK_OUT was created here, then the second `trap` for
# ${tmp} silently discarded its cleanup. Archie proved it by listing both paths
# after exit. WORK_OUT is also only used by the prelaunch path, so it is now
# created there rather than unconditionally.
WORK_OUT=""
TMP_BODY=""
cleanup() { [ -n "${WORK_OUT}" ] && rm -f "${WORK_OUT}"; [ -n "${TMP_BODY}" ] && rm -f "${TMP_BODY}"; return 0; }
trap cleanup EXIT

if [ "${POSTURE}" = "prelaunch" ]; then
    check_draft_release "${WANT}"; exit $?
fi

command -v curl >/dev/null 2>&1 || { say "[CANNOT] curl absent" >&2; exit 2; }

say "== customer download path: ${URL} =="
say "   expecting version ${WANT}"
say ""

# --- 1. the redirect, reported not assumed ---------------------------------
# 🔴 `|| echo 000` DOUBLED THE VALUE AND MADE THE CANNOT BRANCH UNREACHABLE.
# With `-w '%{http_code}'` curl PRINTS `000` on a connection failure AND exits
# non-zero, so the `||` fired as well and the substitution captured `000000`.
# That is not equal to `000`, so the "network unreachable, NOT a verdict on the
# URL" branch below could never be taken and an offline run fell through to
# report the customer download path FAILED. Every machine without network would
# have called a healthy URL broken: the cry-wolf red this file's own header
# warns about. Found by the companion controls, not by reading the code.
# Keep curl's OUTPUT and its STATUS separate.
code="$(curl -sS -o /dev/null -w '%{http_code}' "${URL}" 2>/dev/null)" || true
[ -n "${code}" ] || code=000
target="$(curl -sS -o /dev/null -w '%{redirect_url}' "${URL}" 2>/dev/null)" || true
say "   first hop : HTTP ${code}"
[ -n "${target}" ] && say "   redirects : ${target}"

if [ "${code}" = "000" ]; then
    say "[CANNOT] no HTTP response -- network unreachable from here, NOT a verdict on the URL" >&2
    exit 2
fi

# --- 2. follow it and actually GET the bytes -------------------------------
TMP_BODY="$(mktemp)"; tmp="${TMP_BODY}"   # cleaned by the single EXIT trap above
final_code="$(curl -sSL -o "${tmp}" -w '%{http_code}' "${URL}" 2>/dev/null)" || true
[ -n "${final_code}" ] || final_code=000
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
# 🔴 `koly` IS A TRAILER. The first version of this check read `head -c 512`,
# and Archie measured that it therefore matched NOTHING on a real DMG: UDIF
# stores its 512-byte `koly` trailer at the END of the file, and bzip/zlib/
# encrcdsa are not in the first block either. The `!` was then always true and
# the whole condition collapsed to `size < 1000000`. Two failures fell out of
# that: an HTML error page OVER 1MB passed the shape check, and a genuine DMG
# UNDER 1MB was failed as "does not look like a DMG" -- crying wolf on a
# correct tree, which is how a gate gets switched off.
# tests/test_customer_download_path_gate.sh pins the offset against a real
# UDZO image so this cannot silently regress.
#
# `grep -c` NOT `grep -q`: a short-circuiting consumer in a pipe under
# `set -o pipefail` reports a SUCCESSFUL match as a failure (#895). `grep -c`
# must read all its input to count, so it cannot short-circuit.
trailer_hits="$(tail -c 512 "${tmp}" | LC_ALL=C grep -ca 'koly' || true)"
header_hits="$(head -c 512 "${tmp}" | LC_ALL=C grep -ca 'encrcdsa' || true)"
if [ "${trailer_hits:-0}" -eq 0 ] && [ "${header_hits:-0}" -eq 0 ]; then
    say "[FAIL] 200 but the payload has no UDIF trailer and is not an encrypted"
    say "       disk image -- ${size} bytes of something that is not a DMG."
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
