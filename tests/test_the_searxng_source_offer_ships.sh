#!/usr/bin/env bash
# CM051 117 -- the product must carry the SearXNG (AGPL-3.0) source offer.
#
# THE DEFECT. Vane's image bundles SearXNG, which is AGPL-3.0. The website
# (ostler.ai/licenses) carried the source offer; the PRODUCT carried none:
# vendor/THIRD_PARTY_NOTICES.md and vendor/LICENSES had 0 matches for SearXNG
# or Vane on main. A customer holding the DMG could not read the licence, the
# exact version, or how to ask for the source.
#
# WHAT IS PROVEN, on the files the DMG bundles (gui/project.yml copies
# vendor/LICENSES + vendor/THIRD_PARTY_NOTICES.md, install.sh lands them at
# ~/.ostler/):
#   1. the catalogue names SearXNG, AGPL-3.0, the pinned commit, the source URL,
#      the written offer address, "unmodified apart from configuration" and the
#      Vane container; and names Vane with its MIT licence.
#   2. AGPL-3.0.txt is the FULL text (hash-pinned), not a stub.
#   3. the commit is ONE value everywhere it is written.
#   4. the Vane digest in install.sh is the digest SOURCE.txt says the commit
#      was measured against, so a Vane bump cannot leave a stale offer.
#      LIVE link (optional, needs crane + network): the image's own
#      searxng-src checkout is that commit. Without it: NOT INSTRUMENTED.
#   5. CONSUMER SIDE: `install.sh --licenses` in a sandboxed HOME, after the
#      same copy install.sh step 3.14b does, prints the offer.
#   6. the new files are declared in VENDOR_ONLY.tsv (a sync would delete them).
#
# AGPL_TEST_ROOT points the whole test at another tree (mutant runs).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${AGPL_TEST_ROOT:-$(cd "${HERE}/.." && pwd)}"
export NO_PROXY=127.0.0.1,localhost

# The pinned facts. install.sh's compose line is the source of the digest.
COMMIT="67af4894d4449d2343b1f690bcaa9832ff031335"
SRC_URL="https://github.com/searxng/searxng/tree/${COMMIT}"
AGPL_SHA="57c8ff33c9c0cfc3ef00e650a1cc910d7ee479a8bc509f6c9209a7c2a11399d6"
LAYER="sha256:0f2fd012c4ae240ead8779573c9764ad583368f1dee635445270ff4792dae103"

NOTICES="${ROOT}/vendor/THIRD_PARTY_NOTICES.md"
LIC="${ROOT}/vendor/LICENSES"
INSTALL_SH="${ROOT}/install.sh"

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

# has FILE NEEDLE LABEL: fixed-string match, binary named (BSD grep).
has() {
    if [[ -f "$1" ]] && /usr/bin/grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing: $2 in $1)"; fi
}

echo "-- 1. the catalogue carries the offer"
if [[ ! -f "$NOTICES" ]]; then bad "no $NOTICES"; fi
has "$NOTICES" "SearXNG"                               "names SearXNG"
has "$NOTICES" "AGPL-3.0"                              "names AGPL-3.0"
has "$NOTICES" "$COMMIT"                               "names the pinned commit"
has "$NOTICES" "$SRC_URL"                              "gives the source URL"
has "$NOTICES" "legal@ostler.ai"                       "gives the written-offer address"
has "$NOTICES" "unmodified apart from configuration"   "states it is unmodified"
has "$NOTICES" "ghcr.io/ostler-ai/vane"                "names the Vane container it runs in"
has "$NOTICES" "LICENSES/AGPL-3.0.txt"                 "points at the full licence text"
has "$NOTICES" "Vane (local AI search front-end)"      "has a Vane entry"
has "$NOTICES" "Copyright (c) 2026 ItzCrazyKns"        "Vane copyright line recorded exactly"
has "$LIC/NOTICES/searxng/NOTICE" "legal@ostler.ai"    "per-component NOTICE carries the offer"
has "$LIC/NOTICES/searxng/NOTICE" "$SRC_URL"           "per-component NOTICE carries the source URL"
has "$LIC/NOTICES/vane/LICENSE" "MIT License"          "Vane licence text shipped"
has "$LIC/NOTICES/vane/LICENSE" "Copyright (c) 2026 ItzCrazyKns" "Vane licence carries its copyright line"

echo "-- 2. AGPL-3.0.txt is the full text"
if [[ -f "$LIC/AGPL-3.0.txt" ]]; then
    got="$(shasum -a 256 "$LIC/AGPL-3.0.txt" | cut -d' ' -f1)"
    [[ "$got" == "$AGPL_SHA" ]] && ok "AGPL-3.0.txt sha256 matches upstream at the pinned commit" \
        || bad "AGPL-3.0.txt sha256 ${got} != ${AGPL_SHA}"
    has "$LIC/AGPL-3.0.txt" "GNU AFFERO GENERAL PUBLIC LICENSE"    "AGPL title present"
    has "$LIC/AGPL-3.0.txt" "END OF TERMS AND CONDITIONS"          "AGPL text is not truncated"
else
    bad "vendor/LICENSES/AGPL-3.0.txt not shipped"
fi

echo "-- 3. one commit everywhere it is written"
bad_commit=0
for f in "$NOTICES" "$LIC/NOTICES/searxng/NOTICE" "$LIC/NOTICES/searxng/SOURCE.txt"; do
    [[ -f "$f" ]] || { bad_commit=1; continue; }
    # every whole 40-hex token (sha256 digests are 64 and excluded) must be the pinned commit
    others="$(/usr/bin/grep -oE '[0-9a-f]{40,}' "$f" | /usr/bin/grep -xE '[0-9a-f]{40}' | /usr/bin/grep -vxF "$COMMIT" | sort -u)"
    [[ -z "$others" ]] || { bad_commit=1; echo "    stray 40-hex in $f: $others"; }
    /usr/bin/grep -qF "$COMMIT" "$f" || bad_commit=1
done
[[ $bad_commit -eq 0 ]] && ok "the commit is one value in notice, NOTICE and SOURCE.txt" \
    || bad "the commit differs or is absent across notice, NOTICE and SOURCE.txt"

echo "-- 4. the shipped Vane digest is the one the commit was measured against"
digest="$(/usr/bin/grep -oE 'ghcr\.io/ostler-ai/vane@sha256:[0-9a-f]{64}' "$INSTALL_SH" | sort -u)"
if [[ "$(wc -l <<<"$digest" | tr -d ' ')" == "1" && -n "$digest" ]]; then
    has "$LIC/NOTICES/searxng/SOURCE.txt" "$digest" "SOURCE.txt records the digest install.sh ships"
else
    bad "install.sh does not pin exactly one ostler-ai/vane digest (got: ${digest:-none})"
fi
if [[ "${AGPL_LIVE_DIGEST:-0}" == "1" ]]; then
    if command -v crane >/dev/null 2>&1 && [[ -n "$digest" ]]; then
        head="$(crane blob "ghcr.io/ostler-ai/vane@${LAYER}" 2>/dev/null \
            | tar xzO usr/local/searxng/searxng-src/.git/refs/heads/master 2>/dev/null)"
        if [[ -z "$head" ]]; then cant "live digest link: could not read the layer"
        elif [[ "$head" == "$COMMIT" ]]; then ok "LIVE: the image's own searxng-src master is ${COMMIT}"
        else bad "LIVE: image searxng-src master ${head} != notice ${COMMIT}"; fi
    else
        cant "live digest link: crane missing"
    fi
else
    echo "  [NOT INSTRUMENTED] image-contains-commit link (set AGPL_LIVE_DIGEST=1; measured 2026-10-22 by hand, see SOURCE.txt)"
fi

echo "-- 5. consumer side: install.sh --licenses shows the offer"
SB="$(mktemp -d "${TMPDIR:-/tmp}/agpl-sb.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
if [[ -f "$NOTICES" && -d "$LIC" ]]; then
    mkdir -p "$SB/.ostler"
    # exactly what install.sh step 3.14b does
    cp "$NOTICES" "$SB/.ostler/THIRD_PARTY_NOTICES.md"
    mkdir -p "$SB/.ostler/LICENSES"; cp -R "$LIC/"* "$SB/.ostler/LICENSES/"
    out="$(HOME="$SB" bash "$INSTALL_SH" --licenses </dev/null 2>"$SB/err")"; rc=$?
    if [[ $rc -ne 0 ]]; then cant "install.sh --licenses exited $rc: $(head -c 200 "$SB/err")"
    else
        for n in "SearXNG" "$COMMIT" "legal@ostler.ai" "unmodified apart from configuration"; do
            /usr/bin/grep -qF -- "$n" <<<"$out" && ok "--licenses prints: $n" || bad "--licenses does not print: $n"
        done
        /usr/bin/grep -qE '^ +AGPL-3\.0\.txt$' <<<"$out" && ok "--licenses lists AGPL-3.0.txt among the installed texts" \
            || bad "--licenses does not list AGPL-3.0.txt"
        [[ -s "$SB/.ostler/LICENSES/NOTICES/searxng/NOTICE" ]] && ok "the per-component NOTICE lands under ~/.ostler/LICENSES/NOTICES" \
            || bad "searxng NOTICE did not land"
    fi
else
    bad "nothing to stage (notices or LICENSES missing)"
fi
# the curl fallback list must also fetch the AGPL text
/usr/bin/grep -qE 'for f in .*AGPL-3\.0\.txt' "$INSTALL_SH" && ok "install.sh fetch-fallback list includes AGPL-3.0.txt" \
    || bad "install.sh fetch-fallback list lacks AGPL-3.0.txt"

echo "-- 6. declared vendor-only"
for p in LICENSES/AGPL-3.0.txt LICENSES/NOTICES/searxng/NOTICE LICENSES/NOTICES/searxng/SOURCE.txt \
         LICENSES/NOTICES/vane/LICENSE LICENSES/NOTICES/vane/SOURCE.txt; do
    /usr/bin/grep -qE "^${p//./\\.}	" "$ROOT/vendor/VENDOR_ONLY.tsv" && ok "VENDOR_ONLY row: $p" || bad "no VENDOR_ONLY row: $p"
done

echo
echo "pass=$PASS fail=$FAIL cannot-run=$CANT"
[[ $FAIL -eq 0 && $CANT -eq 0 ]]
