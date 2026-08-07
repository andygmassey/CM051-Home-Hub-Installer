#!/usr/bin/env bash
# Wiki image CONTENT gate
# =============================================================
#
# THE INVARIANT
#
#     the stylesheet inside the pinned image == the stylesheet in git
#
# Every other wiki-image check verifies PROVENANCE: the digest is real, the
# namespace matches, the image pulls. All three can pass while the image
# contains a months-old build. Provenance is not content.
#
# WHAT HAPPENED. The wiki design system was finished, merged, and reached no
# customer for weeks. Four faults conspired (see CM044
# docs/RUNBOOK_wiki_image_release.md), but the reason none of them was CAUGHT
# is simpler: nothing ever opened a wiki image and looked inside. The problem
# was found by hand, by diffing the stylesheet actually being served on a real
# box against git -- 68,542 bytes, ZERO occurrences of the design system,
# byte-identical to a months-old main.
#
# This gate is that hand-check, automated. It opens the image install.sh
# actually pins and compares the stylesheet, byte for byte, with the CM044
# working tree.
#
# It is keyed to CONTENT, deliberately. A gate keyed to a name (a tag, a
# branch, a namespace) rots the moment someone renames the thing. Bytes do not
# rot.
#
# Requires: docker, network, and a CM044 checkout. Skips LOUDLY without them --
# skipping is not passing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CSS_IN_IMAGE="/docs/overrides/stylesheets/extra.css"
CSS_IN_GIT="mkdocs/overrides/stylesheets/extra.css"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
skip() { echo "SKIP: $*" >&2; echo "      (Skipping is NOT a pass.)" >&2; exit 0; }

command -v docker >/dev/null || skip "docker not available"
docker info >/dev/null 2>&1  || skip "docker daemon not running"

# ── Which image does install.sh actually pin? ─────────────────────────────
# Read it out of install.sh rather than accepting it as an argument: the
# question is what SHIPS, not what someone believes ships.
PIN="$(grep -oE 'ghcr\.io/[a-z0-9-]+/ostler-wiki-site@sha256:[a-f0-9]{64}' install.sh | head -1)"
[[ -n "$PIN" ]] || fail "no pinned ostler-wiki-site digest found in install.sh"
pass "install.sh pins ${PIN##*/}"

# ── Where is CM044? ───────────────────────────────────────────────────────
CM044=""
for cand in "${CM044_DIR:-}" "$HOME/Developer/cm044-wiki-remaining" "$REPO_ROOT/../cm044-wiki-remaining"; do
    [[ -n "$cand" && -f "$cand/$CSS_IN_GIT" ]] && { CM044="$cand"; break; }
done
[[ -n "$CM044" ]] || skip "no CM044 checkout found; set CM044_DIR to enable the comparison"

SCRATCH="$(mktemp -d "$REPO_ROOT/.wikicheck.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# ── Open the image ────────────────────────────────────────────────────────
docker pull -q "$PIN" >/dev/null 2>&1 || fail "could not pull $PIN -- a customer could not either"
docker run --rm --entrypoint sh "$PIN" -c "cat $CSS_IN_IMAGE" > "$SCRATCH/image.css" 2>/dev/null \
    || fail "$CSS_IN_IMAGE is not present in the pinned image at all"
[[ -s "$SCRATCH/image.css" ]] || fail "$CSS_IN_IMAGE is EMPTY in the pinned image"

IMG_BYTES=$(wc -c < "$SCRATCH/image.css" | tr -d ' ')
GIT_BYTES=$(wc -c < "$CM044/$CSS_IN_GIT" | tr -d ' ')
IMG_RULES=$(grep -c '\.pw-doc' "$SCRATCH/image.css" || true)
GIT_RULES=$(grep -c '\.pw-doc' "$CM044/$CSS_IN_GIT" || true)

printf '  image  %8s bytes  %4s .pw-doc rules\n' "$IMG_BYTES" "$IMG_RULES"
printf '  git    %8s bytes  %4s .pw-doc rules\n' "$GIT_BYTES" "$GIT_RULES"

# ── The design system must be IN there ────────────────────────────────────
# A bare byte-comparison would pass if both sides lost the design system
# together (e.g. someone reverts it in git and rebuilds). Assert presence
# independently of agreement.
if [[ "$IMG_RULES" -lt 100 ]]; then
    fail "the pinned image's stylesheet has only $IMG_RULES .pw-doc rules.
      The design system is NOT in the image customers receive.
      This is the exact state that shipped for months: a valid digest, a
      clean pull, and a stylesheet from before the design system landed."
fi
pass "the design system is present in the shipped image ($IMG_RULES rules)"

# ── ...and it must be the CURRENT one ─────────────────────────────────────
if ! diff -q "$CM044/$CSS_IN_GIT" "$SCRATCH/image.css" >/dev/null; then
    cat >&2 <<EOF
FAIL: the stylesheet in the pinned image is NOT the one in CM044.

  image  $IMG_BYTES bytes ($IMG_RULES .pw-doc rules)
  git    $GIT_BYTES bytes ($GIT_RULES .pw-doc rules)

The image is a valid, pullable, correctly-namespaced build of OLDER SOURCE.
Every provenance check passes; customers get the old wiki.

Fix: re-release from CM044 main and re-pin --
     scripts/release_wiki_images.sh v0.1.N
EOF
    diff "$CM044/$CSS_IN_GIT" "$SCRATCH/image.css" | head -12 >&2
    exit 1
fi
pass "image stylesheet is byte-identical to CM044 ($IMG_BYTES bytes)"

# ── Positive control ──────────────────────────────────────────────────────
# Prove the comparison can actually fail. Without this, a bug that made both
# sides read the same file would pass silently -- which is how a blind check
# looks from the outside.
printf '/* injected */\n' >> "$SCRATCH/image.css"
if diff -q "$CM044/$CSS_IN_GIT" "$SCRATCH/image.css" >/dev/null; then
    fail "POSITIVE CONTROL FAILED -- the comparison reported a match after the
      image copy was deliberately modified. It is not comparing anything."
fi
pass "positive control: the comparison detects a one-line difference"

echo "PASS: the pinned wiki image contains the current design system"
