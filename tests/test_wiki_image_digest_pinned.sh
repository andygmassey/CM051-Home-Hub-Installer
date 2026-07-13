#!/usr/bin/env bash
#
# test_wiki_image_digest_pinned.sh
#
# Regression lint for the F&F stale-wiki class (2026-06-28): the F&F cut
# shipped a STALE wiki because the CM044 wiki images were pinned by a
# MUTABLE version tag, so whatever happened to be under that tag at install
# time shipped -- WOW slop band ON, vertical meetings, 10.7k orphans. The
# cure (landed for v1.0.6) pins install.sh's compose to immutable
# @sha256 digests and verify_cut_provenance.sh pulls + greps INSIDE the
# pinned digest at cut time.
#
# THIS test keeps the cure from regressing: every first-party
# (ghcr.io/ostler-ai/*) image reference in install.sh MUST be digest-pinned.
# A `:0.1` / `:latest`-style mutable tag on an ostler image = instant FAIL.
#
# Third-party images (oxigraph, vane) are out of scope: they are upstream
# version tags we do not publish over, not the stale-own-artefact class.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL" ]]; then
    echo "FAIL: install.sh missing at $INSTALL" >&2
    exit 1
fi

# Axis 1: the wiki compose must reference BOTH first-party wiki images --
# if a refactor moves/renames them, this test must be re-pointed, not
# silently skipped.
for img in ostler-wiki-site ostler-wiki-compiler; do
    if ! grep -Eq "image:[[:space:]]*ghcr\.io/ostler-ai/${img}@sha256:[0-9a-f]{64}" "$INSTALL"; then
        failure "install.sh has no digest-pinned 'image: ghcr.io/ostler-ai/${img}@sha256:<64-hex>' reference -- either the pin regressed to a mutable tag (the F&F stale-wiki class) or the compose moved (re-point this test)"
    fi
done

# Axis 2: NO first-party ghcr image reference may use a mutable tag form
# anywhere in install.sh (image: lines, docker pull, bare refs).
MUTABLE="$(grep -nE 'ghcr\.io/ostler-ai/[A-Za-z0-9._-]+:[A-Za-z0-9]' "$INSTALL" | grep -vE '@sha256:[0-9a-f]{64}' || true)"
if [[ -n "$MUTABLE" ]]; then
    failure "mutable-tag reference(s) to first-party ghcr images in install.sh (must be @sha256 digest pins):
$MUTABLE"
fi

# Axis 3: same sweep over the wiki-recompile leg (it re-runs the compiler
# image post-install; a mutable tag there re-opens the stale class after
# the install has passed).
for f in "$REPO_ROOT"/wiki-recompile/bin/*.sh; do
    [[ -f "$f" ]] || continue
    MUTABLE="$(grep -nE 'ghcr\.io/ostler-ai/[A-Za-z0-9._-]+:[A-Za-z0-9]' "$f" | grep -vE '@sha256:[0-9a-f]{64}' || true)"
    if [[ -n "$MUTABLE" ]]; then
        failure "mutable-tag ghcr.io/ostler-ai reference(s) in ${f#$REPO_ROOT/}:
$MUTABLE"
    fi
done

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_wiki_image_digest_pinned: FAILED" >&2
    exit 1
fi
echo "test_wiki_image_digest_pinned: all first-party image refs are @sha256 digest pins (stale-wiki class closed)"
