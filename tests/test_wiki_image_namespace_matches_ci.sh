#!/usr/bin/env bash
# Wiki image namespace drift guard
# =============================================================
#
# THE INVARIANT
#
#     the namespace CI pushes to  ==  the namespace install.sh pulls from
#
# Break it and every signal stays green while nothing ships.
#
# WHAT HAPPENED (2026-08-07). CM044's release-images.yml publishes to
# ghcr.io/creativemachines-ai/... It has done since a namespace flip in May.
# install.sh went on pinning ghcr.io/ostler-ai/... So for roughly three
# months the installer pulled from a namespace the pipeline had stopped
# writing to. Every wiki image built in that window went somewhere
# install.sh never looked.
#
# The reason this survived so long is that it has NO SYMPTOM. The workflow
# goes green. The pin is a valid digest. The image pulls. Customers just
# quietly receive a build from before the flip. It was only found by
# diffing the stylesheet actually being served on a real box against git --
# 68,542 bytes and 0 occurrences of the design system, byte-identical to a
# months-old main.
#
# A digest check cannot catch this: both digests are real, both pull, they
# are simply from different lineages. Only comparing the NAMESPACES does.
#
# This guard reads the namespace out of CM044's workflow rather than
# hard-coding it, so the day someone flips the namespace again, this fails
# on the next run instead of three months later.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# ── What does install.sh pull from? ───────────────────────────────────────
mapfile -t PINNED < <(grep -oE 'ghcr\.io/[a-z0-9-]+/ostler-wiki-(site|compiler)@sha256:[a-f0-9]{64}' "$INSTALL" | sort -u)
[[ ${#PINNED[@]} -eq 2 ]] \
    || fail "expected exactly 2 pinned wiki images in $INSTALL, found ${#PINNED[@]}"

INSTALL_NS=""
for p in "${PINNED[@]}"; do
    ns="${p%%/ostler-wiki-*}"
    if [[ -n "$INSTALL_NS" && "$ns" != "$INSTALL_NS" ]]; then
        fail "the two wiki images are pinned to DIFFERENT namespaces: $INSTALL_NS vs $ns"
    fi
    INSTALL_NS="$ns"
done
pass "install.sh pulls both wiki images from $INSTALL_NS"

# Digest pinning itself is load-bearing: a :tag pin lets the image change
# under a cut that claims to be reproducible.
grep -qE 'ghcr\.io/[a-z0-9-]+/ostler-wiki-(site|compiler):[0-9]' "$INSTALL" \
    && fail "a wiki image is pinned by TAG; cuts must pin by @sha256 digest"
pass "both wiki images are pinned by digest, not tag"

# ── What does CI push to? ─────────────────────────────────────────────────
# CM044 is a sibling checkout. If it is not present we cannot compare, and
# saying nothing would be the same silence that hid the drift -- so skip
# LOUDLY rather than passing quietly.
CM044_WORKFLOW=""
for cand in \
    "${CM044_DIR:-}/.github/workflows/release-images.yml" \
    "$HOME/Developer/CM044-PWG-Personal-Wiki/.github/workflows/release-images.yml" \
    "$REPO_ROOT/../CM044-PWG-Personal-Wiki/.github/workflows/release-images.yml" \
    "$HOME/Developer/cm044-wiki-remaining/.github/workflows/release-images.yml" \
    "$REPO_ROOT/../cm044-wiki-remaining/.github/workflows/release-images.yml"
do
    [[ -n "$cand" && -f "$cand" ]] && { CM044_WORKFLOW="$cand"; break; }
done

if [[ -z "$CM044_WORKFLOW" ]]; then
    # EXIT 2, NOT 0. The comment four lines up has always said "skip LOUDLY
    # rather than passing quietly" and the code then exited 0, which is
    # passing quietly. Measured 2026-08-21: with no CM044_DIR this returned
    # rc=0, and with CM044_DIR set and the namespaces genuinely matching it
    # ALSO returned rc=0. "I could not look" and "I looked and it is fine"
    # were byte-identical to every caller.
    #
    # That mattered more than it sounds, because BOTH pre-existing fallback
    # paths named `cm044-wiki-remaining`, a checkout that does not exist --
    # the CM044 clone is `CM044-PWG-Personal-Wiki`. So the fallbacks never
    # resolved, and this gate has effectively never run its own comparison
    # except when someone set CM044_DIR by hand. Both real names are now in
    # the candidate list above, most-likely first.
    #
    # This is the check that catches the namespace drift that shipped stale
    # images for three months with NO symptom (see the header). A check that
    # cannot distinguish "did not run" from "passed" cannot catch it either.
    echo "CANNOT RUN: no CM044 checkout found, so the namespace CI pushes to could not be read." >&2
    echo "      Set CM044_DIR=/path/to/CM044 and re-run." >&2
    echo "      Tried:" >&2
    echo "        \${CM044_DIR}/.github/workflows/release-images.yml" >&2
    echo "        \$HOME/Developer/CM044-PWG-Personal-Wiki/.github/workflows/release-images.yml" >&2
    echo "        \$REPO_ROOT/../CM044-PWG-Personal-Wiki/.github/workflows/release-images.yml" >&2
    echo "      This is the check that catches silent drift. Exit 2 = CANNOT-RUN," >&2
    echo "      deliberately distinct from 0 (compared, matched) and 1 (drifted)." >&2
    exit 2
fi

CI_NS="$(grep -oE 'ghcr\.io/[a-z0-9-]+/ostler-wiki' "$CM044_WORKFLOW" | head -1 | sed 's#/ostler-wiki##')"
[[ -n "$CI_NS" ]] || fail "could not read a target namespace from $CM044_WORKFLOW"
pass "CM044 CI pushes to $CI_NS"

# ── The comparison ────────────────────────────────────────────────────────
if [[ "$INSTALL_NS" != "$CI_NS" ]]; then
    cat >&2 <<EOF
FAIL: NAMESPACE DRIFT -- this ships stale images with no symptom.

  CI pushes to      $CI_NS/ostler-wiki-{site,compiler}
  install.sh pulls  $INSTALL_NS/ostler-wiki-{site,compiler}

Every wiki image built by CI is landing somewhere install.sh never reads.
The pipeline will stay green. Customers will keep receiving whatever was
last pushed to $INSTALL_NS, however old that is.

Fix: re-pin install.sh to $CI_NS digests (see CM044
scripts/release_wiki_images.sh), or change the workflow if the move was
deliberate -- but change BOTH.
EOF
    exit 1
fi
pass "namespaces match -- CI publishes where install.sh reads"

echo "PASS: wiki image namespace guard"
