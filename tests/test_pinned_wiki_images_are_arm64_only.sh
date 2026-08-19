#!/usr/bin/env bash
# Wiki image PLATFORM gate
# =============================================================
#
# THE INVARIANT
#
#     every wiki image digest pinned in install.sh is arm64-ONLY
#
# WHY THIS EXISTS, and why it is here rather than in CM044 CI.
#
# Ostler is an Apple Silicon Mac product. install.sh does `ARCH=$(uname -m)`
# and, when it is not arm64, calls fail_with_code
# "ERR-01-ARCH-INTEL-NOT-SUPPORTED". An Intel Mac cannot complete an install at
# all, so NO supported install target ever pulls these images on amd64. That
# was decided when the product went single-machine Mac-only.
#
# It was decided and never delivered: CM044 release-images.yml kept building
# `platforms: linux/amd64,linux/arm64`, so every release built, pushed and paid
# for an amd64 half that nobody pulls. Dropping that line is necessary and NOT
# sufficient, which is the whole reason this file exists:
#
#   * a workflow line can be changed back, by anyone, at any time
#   * a stale pin survives the workflow being correct
#   * CM044 is private and Actions are quota-blocked, so a gate THERE cannot
#     run today at all
#
# So the instrument goes on the surface the defect actually reaches: the
# artefact that ships, checked at the last choke point before a DMG exists.
# This probes the MANIFEST OF THE DIGEST INSTALL.SH CARRIES. It does not read
# the workflow, it does not trust the build log, and it does not care what
# anybody intended.
#
# THREE STATES, deliberately. PASS / FAIL / CANNOT-RUN. An unreadable manifest
# is NOT agreement -- treating a probe that could not run as a pass is the
# false green this project keeps paying for. CANNOT-RUN exits 2 and says so.
#
# It also prints what it EXAMINED. Zero digests inspected reads identical to
# zero problems found unless the denominator is on screen.
#
# Requires: network. Does NOT require docker or a CM044 checkout -- it talks to
# the registry directly and the packages are anonymously pullable.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; OFF=$'\033[0m'
ok()      { echo "  ${GRN}ok${OFF}   $*"; }
bad()     { echo "  ${RED}FAIL${OFF} $*"; }
cannot()  { echo "  ${YEL}CANNOT-RUN${OFF} $*"; }

echo "== pinned wiki image platform gate (arm64-only) =="

# ---------------------------------------------------------------------------
# platforms_of <ns> <name> <digest>
#   stdout: space-separated "os/arch" list, or the literal token UNREADABLE
# ---------------------------------------------------------------------------
platforms_of() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys, urllib.request, urllib.error
ns, name, digest = sys.argv[1], sys.argv[2], sys.argv[3]
ACCEPT = ','.join([
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json',
])
def out(v):
    print(v); sys.exit(0)
try:
    turl = f'https://ghcr.io/token?service=ghcr.io&scope=repository:{ns}/{name}:pull'
    tok = json.load(urllib.request.urlopen(turl, timeout=30)).get('token')
    if not tok:
        out('UNREADABLE')
    r = urllib.request.Request(f'https://ghcr.io/v2/{ns}/{name}/manifests/{digest}')
    r.add_header('Authorization', 'Bearer ' + tok)
    r.add_header('Accept', ACCEPT)
    m = json.load(urllib.request.urlopen(r, timeout=30))
except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
    out('UNREADABLE')

if 'manifests' in m:
    # index: report every entry's platform. Attestation entries carry
    # unknown/unknown and are reported as-is rather than filtered, because a
    # gate that hides an entry cannot fail on it.
    plats = []
    for e in m['manifests']:
        p = e.get('platform', {}) or {}
        plats.append(f"{p.get('os','?')}/{p.get('architecture','?')}")
    out(' '.join(plats) if plats else 'UNREADABLE')

# single manifest: platform lives in the config blob
cfg = (m.get('config') or {}).get('digest')
if not cfg:
    out('UNREADABLE')
try:
    r2 = urllib.request.Request(f'https://ghcr.io/v2/{ns}/{name}/blobs/{cfg}')
    r2.add_header('Authorization', 'Bearer ' + tok)
    c = json.load(urllib.request.urlopen(r2, timeout=30))
except Exception:
    out('UNREADABLE')
osv, arch = c.get('os'), c.get('architecture')
out(f'{osv}/{arch}' if osv and arch else 'UNREADABLE')
PYEOF
}

# verdict_for <platforms-string> -> echoes PASS | FAIL | CANNOT
verdict_for() {
    case "$1" in
        UNREADABLE|'')  echo CANNOT ;;
        'linux/arm64')  echo PASS ;;
        *)              echo FAIL ;;
    esac
}

# ---------------------------------------------------------------------------
# SELF-TEST (positive control). A gate with no demonstrated red is not a gate.
#
# The OLD shipping pins were built linux/amd64,linux/arm64, so they are a
# permanent, immutable known-bad specimen. If pointing this gate at them does
# NOT produce FAIL, the gate is broken and everything below it is meaningless.
# ---------------------------------------------------------------------------
SELFTEST_NS="creativemachines-ai"
KNOWN_MULTIARCH="sha256:36de411b2a649f77df6079416ccdb06ce043c30b94b248058f581afd97aec92b"
SELFTEST_IMG="ostler-wiki-site"

echo
echo "-- self-test: the gate must FAIL on a known multi-arch digest --"
st_plats="$(platforms_of "$SELFTEST_NS" "$SELFTEST_IMG" "$KNOWN_MULTIARCH")"
st_verdict="$(verdict_for "$st_plats")"
case "$st_verdict" in
    FAIL)
        ok "positive control fires: ${KNOWN_MULTIARCH:0:23}... reports [$st_plats] -> FAIL"
        ;;
    CANNOT)
        cannot "positive control could not read the known-bad manifest (network?)."
        echo "       The gate cannot prove it discriminates, so its verdict below is not trustworthy."
        exit 2
        ;;
    PASS)
        bad "POSITIVE CONTROL DID NOT FIRE: a known multi-arch digest passed."
        echo "       digest    : $KNOWN_MULTIARCH"
        echo "       platforms : $st_plats"
        echo "       This gate is broken. Fix the gate before trusting any green from it."
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# THE REAL CHECK: every wiki pin in install.sh
# ---------------------------------------------------------------------------
echo
echo "-- checking the digests install.sh actually pins --"

PINS="$(grep -oE 'ghcr\.io/[a-z0-9-]+/ostler-wiki-(site|compiler)@sha256:[a-f0-9]{64}' install.sh | sort -u)"
if [[ -z "$PINS" ]]; then
    cannot "no ostler-wiki-* @sha256 pins found in install.sh."
    echo "       Zero digests examined. That is NOT the same as zero problems."
    exit 2
fi

examined=0; passed=0; failed=0; unreadable=0
while IFS= read -r pin; do
    [[ -z "$pin" ]] && continue
    ref="${pin#ghcr.io/}"
    ns="${ref%%/*}"
    rest="${ref#*/}"
    name="${rest%%@*}"
    digest="${pin#*@}"
    examined=$((examined+1))
    plats="$(platforms_of "$ns" "$name" "$digest")"
    case "$(verdict_for "$plats")" in
        PASS)
            passed=$((passed+1))
            ok "$name is arm64-only  [$plats]"
            ;;
        FAIL)
            failed=$((failed+1))
            bad "$name pins a NON-arm64-only manifest."
            echo "       digest    : $digest"
            echo "       platforms : $plats"
            echo "       expected  : linux/arm64"
            echo "       Ostler is Apple Silicon only -- install.sh hard-fails non-arm64 with"
            echo "       ERR-01-ARCH-INTEL-NOT-SUPPORTED, so any extra platform here is built,"
            echo "       pushed and paid for, and pulled by nobody."
            ;;
        CANNOT)
            unreadable=$((unreadable+1))
            cannot "$name manifest could not be read."
            echo "       digest    : $digest"
            echo "       An unreadable manifest is NOT agreement. Treating it as a pass is"
            echo "       exactly the false green this gate exists to prevent."
            ;;
    esac
done <<< "$PINS"

echo
echo "EXAMINED $examined pinned wiki digest(s): $passed arm64-only, $failed wrong-platform, $unreadable unreadable"

if (( unreadable > 0 )); then
    echo "${YEL}RESULT: CANNOT-RUN${OFF} -- $unreadable manifest(s) unreadable. This is NOT a pass."
    exit 2
fi
if (( failed > 0 )); then
    echo "${RED}RESULT: FAIL${OFF} -- $failed pinned wiki image(s) are not arm64-only. DO NOT CUT."
    exit 1
fi
if (( examined == 0 )); then
    echo "${YEL}RESULT: CANNOT-RUN${OFF} -- zero digests examined."
    exit 2
fi
echo "${GRN}RESULT: PASS${OFF} -- all $examined pinned wiki image(s) are arm64-only."
exit 0
