#!/usr/bin/env bash
#
# tests/test_v1010_redteam3_supply_chain_pins.sh
#
# FIX RT3 (v1.0.10 security lockdown -- container supply-chain integrity;
# confirmed HIGH Red Team finding, Andy-approved full-close).
#
# The generated docker-compose used to pull third-party container images
# by MUTABLE TAG (qdrant:v1.12.1, oxigraph:0.4.6, nginx:1.27-alpine,
# valkey/valkey:8-alpine, itzcrazykns1337/vane:v1.12.2) while our own
# first-party wiki images were already @sha256-pinned. A mutable tag can
# be re-pushed under us -- an attacker who controls (or compromises) the
# upstream tag ships arbitrary code into the customer's stack on the next
# `docker compose pull`. The valkey ref was the worst: `8-alpine` floats
# across every 8.x patch. The vane image was worse still -- a PERSONAL
# Docker Hub account, deployed by default as the assistant web_search
# backend on localhost:3000.
#
# THE RULE this test enforces: every `image:` line in the generated
# compose must be EITHER a first-party ghcr.io/ostler-ai image OR pinned
# by an @sha256: digest. No mutable third-party tag may survive, and the
# personal itzcrazykns1337/ namespace must appear NOWHERE in install.sh
# (the vane image is mirrored into ghcr.io/ostler-ai and digest-pinned).
#
# Pure shell + grep/awk -- no docker required.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install.sh not found"

# ── Extract the compose heredoc body ─────────────────────────────
COMPOSE="$(mktemp)"
trap 'rm -f "$COMPOSE"' EXIT
awk '
    /<<'\''DCEOF'\''/ { capture = 1; next }
    /^DCEOF$/         { capture = 0 }
    capture           { print }
' "$INSTALL_SCRIPT" > "$COMPOSE"
[[ -s "$COMPOSE" ]] || fail "compose heredoc body empty"

# ── Every image: line is first-party OR @sha256-pinned ───────────
# Strip trailing "# human tag" comments before judging so the readability
# comment (e.g. "  # v1.12.1") never masks a mutable ref.
found_images=0
while IFS= read -r raw; do
    # value after "image:", comment stripped, whitespace trimmed
    ref="$(printf '%s\n' "$raw" | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//')"
    [[ -n "$ref" ]] || continue
    found_images=$((found_images + 1))
    if [[ "$ref" == ghcr.io/ostler-ai/* ]]; then
        # First-party. Our own wiki images are digest-pinned; the mirrored
        # vane image must ALSO be digest-pinned (mirroring a mutable tag
        # into our namespace without pinning would re-introduce the drift).
        if [[ "$ref" == ghcr.io/ostler-ai/vane* && "$ref" != *"@sha256:"* ]]; then
            fail "first-party mirror not digest-pinned: '$ref'"
        fi
        echo "  ok (first-party): $ref"
        continue
    fi
    [[ "$ref" == *"@sha256:"* ]] \
        || fail "third-party image pinned by MUTABLE TAG (must be @sha256): '$ref'"
    echo "  ok (@sha256-pinned): $ref"
done < <(grep -E '^[[:space:]]*image:' "$COMPOSE")

[[ "$found_images" -ge 6 ]] \
    || fail "expected >=6 image: lines in compose, found ${found_images} (extraction broke?)"

# ── The personal vane namespace is gone everywhere in install.sh ─
# A provenance comment recording where the mirror came from is fine; a
# LIVE (non-comment) reference is not. Strip each line at its first '#'
# before judging.
while IFS= read -r cline; do
    ccode="${cline%%#*}"
    if printf '%s' "$ccode" | grep -q 'itzcrazykns1337/vane'; then
        fail "compose has a LIVE itzcrazykns1337/vane reference (personal Docker Hub account): $cline"
    fi
done < <(grep 'itzcrazykns1337/vane' "$COMPOSE" || true)
# The compose ref must be the mirrored, digest-pinned org image. A bare
# comment mentioning the upstream provenance is fine; a live image ref is
# not. Assert the compose has a pinned ghcr.io/ostler-ai/vane image line.
grep -Eq '^[[:space:]]*image:[[:space:]]*ghcr\.io/ostler-ai/vane@sha256:' "$COMPOSE" \
    || fail "vane not repointed to a digest-pinned ghcr.io/ostler-ai/vane image"

# Belt-and-braces: no *live image reference* to the personal namespace
# anywhere in install.sh. We allow the string to survive only inside a
# comment recording where the mirror came from; catch any occurrence that
# is NOT preceded by a '#' on its line.
while IFS= read -r line; do
    # drop everything from the first '#' -- if the token survives, it's live
    code="${line%%#*}"
    if printf '%s' "$code" | grep -q 'itzcrazykns1337/vane'; then
        fail "live (non-comment) reference to itzcrazykns1337/vane survives in install.sh: $line"
    fi
done < <(grep -n 'itzcrazykns1337/vane' "$INSTALL_SCRIPT" || true)

echo "PASS: every compose image is first-party ostler-ai or @sha256-pinned; no live itzcrazykns1337/vane reference remains."
