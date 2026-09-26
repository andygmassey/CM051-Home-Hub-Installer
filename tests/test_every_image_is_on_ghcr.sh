#!/usr/bin/env bash
#
# tests/test_every_image_is_on_ghcr.sh
#
# EVERY CONTAINER IMAGE THE INSTALL PULLS COMES FROM ghcr.io, BY DIGEST.
#
# Until v1.0.103 three images (qdrant, nginx, valkey) were pulled from Docker
# Hub. The v1.0.101 walk saw the customer's VM open a connection to AWS for
# them, and Docker Hub rate-limits anonymous pulls per IP. They are now copied
# byte for byte, at the SAME digest, into ghcr.io/creativemachines-ai/ by
# github.com/creativemachines-ai/ostler-image-mirror, and pinned from there.
#
# THE RULE: every live `image:` value in install.sh (and in any tracked
# docker-compose*.yml) must start with `ghcr.io/` AND be pinned by
# `@sha256:<64 hex>`. A comment mentioning Docker Hub is fine; a live
# reference is not. Anything the parser cannot classify FAILS: a gate that
# waves through what it does not understand is how a new registry slips in.
#
# THE MUTATION TEST IS PART OF THE GATE, not a separate file: every run first
# plants violations into a clean baseline built from install.sh's own first
# ghcr.io pin and must see each one refused, and the baseline accepted. If the planted
# violation passes, the gate is blind and this exits non-zero before judging
# the real tree at all.
#
# Pure bash + grep/sed, bash 3.2 safe, no network, no docker.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"

# check_files FILE... -> prints one line per image, returns 1 on any violation
# (or if it examined zero images: a zero denominator is not a pass).
check_files() {
    local f raw ref n=0 bad=0
    for f in "$@"; do
        while IFS= read -r raw; do
            ref="$(printf '%s\n' "$raw" | sed -E 's/^[0-9]+:[[:space:]]*image:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]*$//; s/^["'\'']//; s/["'\'']$//')"
            n=$((n + 1))
            if printf '%s' "$ref" | grep -Eq '^ghcr\.io/[a-z0-9._-]+(/[a-z0-9._-]+)+@sha256:[a-f0-9]{64}$'; then
                echo "  ok   ${f##*/}: $ref"
            else
                echo "  FAIL ${f##*/}: '$ref' is not ghcr.io/...@sha256:<digest>"
                bad=$((bad + 1))
            fi
        done < <(grep -nE '^[[:space:]]*image:' "$f")
    done
    echo "  examined ${n} image line(s), ${bad} violation(s)"
    [ "$n" -gt 0 ] || { echo "  FAIL: zero image lines examined, the extraction is broken"; return 1; }
    [ "$bad" -eq 0 ]
}

[ -f "$INSTALL" ] || { echo "CANNOT-RUN: install.sh not found" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== mutation test: planted violations must be refused =="
FIRST_GHCR="$(grep -m1 -oE 'image:[[:space:]]+ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}' "$INSTALL" | sed -E 's/^image:[[:space:]]+//')"
if [ -z "$FIRST_GHCR" ]; then
    echo "CANNOT-RUN: no ghcr.io digest pin in install.sh to mutate" >&2
    exit 2
fi
DIG="${FIRST_GHCR#*@}"
# THE CONTROLS RUN ON A CLEAN BASELINE, NOT ON install.sh. Mutating a tree
# that already carries a violation proves nothing: every mutant would be
# refused for the violation that was already there. The baseline is the real
# install.sh's first ghcr.io pin, in the real indentation, and it MUST pass.
printf 'services:\n  a:\n    image: %s  # a pin\n' "$FIRST_GHCR" > "$WORK/base.yml"
blind=0
if check_files "$WORK/base.yml" >/dev/null; then
    echo "  accepted (as it must): the clean baseline $FIRST_GHCR"
else
    echo "  OVER-EAGER: the clean baseline was refused"; blind=$((blind + 1))
fi
i=0
for planted in \
    "qdrant/qdrant@${DIG}" \
    "docker.io/qdrant/qdrant@${DIG}" \
    "nginx@${DIG}" \
    "quay.io/qdrant/qdrant@${DIG}" \
    "ghcr.io/creativemachines-ai/qdrant:v1.12.1" \
    "ghcr.io.evil.example/qdrant@${DIG}" \
    '"docker.io/library/nginx:latest"'
do
    i=$((i + 1))
    sed "s#${FIRST_GHCR}#${planted}#" "$WORK/base.yml" > "$WORK/mut.$i.yml"
    if cmp -s "$WORK/base.yml" "$WORK/mut.$i.yml"; then
        echo "  CANNOT-RUN: mutant $i did not apply"; blind=$((blind + 1)); continue
    fi
    if check_files "$WORK/mut.$i.yml" >/dev/null; then
        echo "  BLIND: planted '$planted' was ACCEPTED"; blind=$((blind + 1))
    else
        echo "  refused (as it must): $planted"
    fi
done
# A Docker Hub name inside a COMMENT is not a pull.
cp "$WORK/base.yml" "$WORK/comment.yml"
printf '    # image: qdrant/qdrant@%s  (a comment, not a pull)\n' "$DIG" >> "$WORK/comment.yml"
if check_files "$WORK/comment.yml" >/dev/null; then
    echo "  accepted (as it must): a commented-out Docker Hub reference"
else
    echo "  OVER-EAGER: a commented Docker Hub reference was refused"; blind=$((blind + 1))
fi
if [ "$blind" -ne 0 ]; then
    echo "FAIL: the gate is not discriminating (${blind} control(s) wrong); not judging the real tree." >&2
    exit 1
fi

echo "== the real tree =="
FILES=("$INSTALL")
while IFS= read -r c; do
    [ -n "$c" ] && FILES+=("${REPO_ROOT}/$c")
done < <(cd "$REPO_ROOT" && git ls-files 'docker-compose*.yml' 'docker-compose*.yaml' 2>/dev/null)
if check_files "${FILES[@]}"; then
    echo "PASS: every image the install pulls is ghcr.io and digest-pinned."
    exit 0
fi
echo "FAIL: an image is pulled from outside ghcr.io or by a mutable tag." >&2
exit 1
