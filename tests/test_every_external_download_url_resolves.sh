#!/usr/bin/env bash
# Every EXTERNAL URL install.sh downloads from must actually resolve.
#
# ============================================================================
# WHY THIS EXISTS. #1625, AND THE FACT THAT #1631 "FIXED" IT WITHOUT FIXING IT.
# ============================================================================
# install.sh has a curl|bash bootstrap that fetches an installer tarball.
# #1625 measured that the asset had NEVER existed: 43 releases in
# ostler-releases, 0 carrying install.tar.gz. #1631 then merged, green, and
# changed the URL to point at ostler-installer instead.
#
# MEASURED 2026-09-06, after that merge, with a positive control:
#
#   post-#1631  404  -> ostler-installer/releases/download/v1.0.41/install.tar.gz
#   pre-#1631   404  -> ostler-releases/releases/download/hub-v0.4.70/install.tar.gz
#   CONTROL     200  -> ostler-installer/releases/latest/download/SHA256SUMS
#
# The fix changed WHICH non-existent URL is fetched. Nothing in CI noticed,
# because no gate has ever asked whether a URL install.sh downloads from
# resolves. Every existing check reads the SOURCE: is the variable set, is the
# repo name right, does the string look like a URL. None of them leaves the
# machine.
#
# THE SECOND DEFECT, WHICH ONLY THE REDIRECT EXPOSES. `latest` resolved to
# v1.0.41 -- thirty versions old -- because every cut publishes a PRERELEASE
# and GitHub excludes prereleases from `latest`. So a `/releases/latest/`
# delivery URL is stale by construction between promotes, and adding the
# missing asset to the newest release would not have helped. That is arm 3.
#
# ============================================================================
# WHAT THIS GATE IS, AND WHAT IT DELIBERATELY IS NOT
# ============================================================================
# It probes the EXTERNAL download URLs only -- the ones that reach the network
# on a customer's Mac. It does NOT probe the ~95 localhost curl calls: those
# are health checks against services the installer has just started, and a
# machine with no Ostler running would fail them for a reason that says
# nothing about the shipped artefact.
#
# THREE STATES, AND THE THIRD IS THE ONE THAT MATTERS. A network this gate
# cannot reach is CANNOT-RUN (2), never a pass. Both controls below exist to
# tell those apart: if the must-200 fails OR the must-404 succeeds, the probe
# itself is not trustworthy and no verdict is issued.
#
#   0  every external download URL resolves
#   1  at least one does not          <- the #1625 class
#   2  CANNOT-RUN: the probe could not be trusted
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${1:-${HERE}/install.sh}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }
cant() { printf '  [CANNOT-RUN] %s\n' "$1" >&2; echo "== ${PASS} pass / ${FAIL} fail / 1 cannot-run =="; exit 2; }

[ -f "$SUBJECT" ] || cant "no install.sh at ${SUBJECT}"
command -v curl >/dev/null 2>&1 || cant "curl unavailable; nothing was probed"

# --noproxy '*' on every probe. A local proxy answers for EVERY host, so
# without it a 200 can come from something that never reached GitHub -- the
# failure already recorded in this project's environment notes.
probe() { curl -sS -o /dev/null -w '%{http_code} %{url_effective}' -L --max-time 25 --noproxy '*' "$1" 2>/dev/null; }
code_of() { printf '%s' "${1%% *}"; }

# ── CONTROLS FIRST. No verdict is issued until the probe proves it can say
#    both YES and NO. A gate whose instrument is dead reports every URL as
#    broken, which is indistinguishable from every URL being broken.
CTL_OK_URL='https://github.com/ostler-ai/ostler-installer/releases/latest/download/SHA256SUMS'
CTL_NO_URL='https://github.com/ostler-ai/ostler-installer/releases/latest/download/a-file-that-must-never-exist-zzz.tar.gz'

_c="$(probe "$CTL_OK_URL")";  _cc="$(code_of "$_c")"
case "$_cc" in
    2*) ok "CONTROL: an asset that exists returns ${_cc}, so the probe can reach GitHub and follow a redirect" ;;
    *)  cant "positive control returned '${_cc}' for an asset that must exist. The network, a proxy or the repo is the problem, NOT install.sh. Refusing to report a verdict on unreachable URLs." ;;
esac

_n="$(probe "$CTL_NO_URL")"; _nc="$(code_of "$_n")"
case "$_nc" in
    404) ok "CONTROL: an asset that cannot exist returns 404, so the probe can say ABSENT" ;;
    *)   cant "negative control returned '${_nc}' for an asset that cannot exist. Something is answering for every path, so a 200 here would prove nothing." ;;
esac

# ── THE SUBJECTS. Extracted from install.sh, with its own defaults applied,
#    so this measures what a customer's shell would actually build. Each
#    extraction asserts it FOUND something: a regex that silently matches
#    nothing would make this gate pass by examining zero URLs, which is the
#    zero-denominator failure this codebase has been bitten by repeatedly.
_val() { # _val <VARNAME> -- the RHS of the first assignment, quotes stripped
    sed -n "s/^${1}=\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$SUBJECT" | head -1
}

# ── DECLARED KNOWN-ABSENT, WITH A REASON AND THE TEST THAT PROVES IT ───────
#
# A URL may legitimately not resolve IF the code that fetches it refuses
# HONESTLY -- naming the missing asset instead of blaming the network -- and a
# test drives that path. Silence is the bug; a recorded decision is fine. Same
# contract as cut-deferrals.yaml, and for the same reason.
#
# Declared entries are still PROBED and still PRINTED on every run, so nothing
# goes quiet, and the moment one starts resolving this says so.
#
# Format: <substring of the URL>|<the test that proves the honest refusal>|<why>
DECLARED=(
  "ostler-installer/releases/latest/download/install.tar.gz|tests/test_a_missing_tarball_is_not_a_network_problem.sh|CM051 #1625. Tarball publishing stopped when the product moved to DMG distribution; install.tar.gz exists on v0.1.0-v0.3.0 of ostler-installer and nothing since. The curl|bash bootstrap is NOT a documented customer route (0 hits across README.md and docs/*.md) and a DMG install never reaches it -- it takes the BASH_SOURCE branch. Rather than build a publisher for an undocumented entry point, the bootstrap now refuses honestly: a 4xx is definitive so it is not retried, and the message names the absent asset and explicitly clears the reader network. The named test drives that arm and carries a negative control against the pre-fix blob."
)
_declared_for() { # -> "test|reason" if this URL is declared, else empty
    local u="$1" d
    for d in "${DECLARED[@]}"; do
        case "$u" in *"${d%%|*}"*) printf '%s' "${d#*|}"; return ;; esac
    done
}

NAMES=(); URLS=()

_tarball="$(_val DEFAULT_INSTALLER_TARBALL_URL)"
[ -n "$_tarball" ] || cant "could not extract DEFAULT_INSTALLER_TARBALL_URL from ${SUBJECT}; the extractor found nothing, so this gate would examine zero URLs"
NAMES+=("curl|bash bootstrap tarball"); URLS+=("$_tarball")

_rcver="$(sed -n 's/^OSTLER_REMOTECAPTURE_VERSION="\${OSTLER_REMOTECAPTURE_VERSION:-\([^}]*\)}".*/\1/p' "$SUBJECT" | head -1)"
_rcrepo="$(sed -n 's/^OSTLER_REMOTECAPTURE_REPO="\${OSTLER_REMOTECAPTURE_REPO:-\([^}]*\)}".*/\1/p' "$SUBJECT" | head -1)"
if [ -n "$_rcver" ] && [ -n "$_rcrepo" ]; then
    NAMES+=("RemoteCapture archive"); URLS+=("https://github.com/${_rcrepo}/releases/download/remote-capture-v${_rcver}/RemoteCapture-${_rcver}-arm64.tar.gz")
else
    cant "could not resolve the RemoteCapture repo/version defaults; refusing to report on a URL built from empty variables"
fi

# The gws asset name is BUILT from an arch label chosen at runtime, so the
# base URL alone is a DIRECTORY and 404s by design. My first version of this
# gate probed the bare base and reported a defect that does not exist -- a
# false positive, caught before shipping by reading the call site instead of
# trusting my own extraction. Probe the arm64 asset install.sh would actually
# request on the Macs this product supports.
_gwsver="$(_val GWS_VERSION)"
_gwsarch="$(sed -n 's/.*GWS_ARCH_LABEL="\(aarch64[^"]*\)".*/\1/p' "$SUBJECT" | head -1)"
if [ -n "$_gwsver" ] && [ -n "$_gwsarch" ]; then
    NAMES+=("google workspace cli (${_gwsarch})")
    URLS+=("https://github.com/googleworkspace/cli/releases/download/v${_gwsver}/google-workspace-cli-${_gwsarch}.tar.gz")
elif [ -n "$_gwsver" ]; then
    cant "GWS_VERSION resolved to ${_gwsver} but no aarch64 GWS_ARCH_LABEL was found, so the asset name cannot be built. Probing the bare base URL would 404 by design and report a defect that does not exist."
fi

echo "── ${#URLS[@]} external download URL(s) extracted from ${SUBJECT##*/} ──"

i=0
while [ "$i" -lt "${#URLS[@]}" ]; do
    _r="$(probe "${URLS[$i]}")"; _rc="$(code_of "$_r")"
    _decl="$(_declared_for "${URLS[$i]}")"
    case "$_rc" in
        2*) if [ -n "$_decl" ]; then
                bad "${NAMES[$i]}: ${_rc}. This URL is DECLARED known-absent and it now RESOLVES. Retire the declaration -- a stale exemption hides the next real break."
            else
                ok "${NAMES[$i]}: ${_rc}"
            fi ;;
        000) bad "${NAMES[$i]}: no response at all, yet the positive control reached GitHub. ${URLS[$i]}" ;;
        *)  if [ -n "$_decl" ]; then
                _t="${_decl%%|*}"
                if [ -f "${HERE}/${_t}" ]; then
                    ok "${NAMES[$i]}: ${_rc}, DECLARED known-absent and the honest-refusal test is present (${_t})"
                    printf '         why: %s\n' "${_decl#*|}"
                else
                    bad "${NAMES[$i]}: ${_rc}, declared known-absent but its proof test ${_t} DOES NOT EXIST. A declaration without the test it names is an excuse."
                fi
            else
                bad "${NAMES[$i]}: ${_rc} -- install.sh downloads from a URL that does not resolve.
         asked for : ${URLS[$i]}
         landed on : ${_r#* }
         The controls above passed, so this is the URL and not the network.
         If this is deliberate, DECLARE it above with a reason and a test that
         proves the code refuses honestly. Do not just change which URL 404s."
            fi ;;
    esac
    i=$((i + 1))
done

# ── ARM 3: a delivery URL must not depend on `latest` while cuts are
#    prereleases. GitHub excludes prereleases from `latest`, and every cut
#    publishes one deliberately, so such a URL silently serves whatever the
#    last PROMOTED build was. This is not hypothetical: it is why the redirect
#    above landed on v1.0.41.
i=0
_latest_hits=0
while [ "$i" -lt "${#URLS[@]}" ]; do
    case "${URLS[$i]}" in
        */releases/latest/*)
            if [ -n "$(_declared_for "${URLS[$i]}")" ]; then
                ok "${NAMES[$i]} uses /releases/latest/ but is declared known-absent, and the declaration records the prerelease trap"
                i=$((i + 1)); continue
            fi
            _latest_hits=$((_latest_hits + 1))
            bad "${NAMES[$i]} resolves through /releases/latest/, which CANNOT see a prerelease.
         Every cut publishes a prerelease on purpose, so this URL serves the last
         PROMOTED build and is stale by construction between promotes. Name the tag,
         or flip the release at promote time and accept the gap." ;;
    esac
    i=$((i + 1))
done
[ "$_latest_hits" -eq 0 ] && ok "no download URL depends on /releases/latest/ (${#URLS[@]} examined)"

echo
echo "== ${PASS} pass / ${FAIL} fail / 0 cannot-run =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
