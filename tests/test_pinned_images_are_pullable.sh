#!/usr/bin/env bash
#
# test_pinned_images_are_pullable.sh
#
# Every container image install.sh pins by @sha256 digest must be fetchable
# ANONYMOUSLY, the way a customer's Mac fetches it.
#
# WHY THIS EXISTS
# ---------------
# CM044's release-images.yml had been failing at the GHCR *login* step since at
# least 2026-08-05 -- `denied: denied` for the CM_AI_GHCR_PAT secret. Nobody
# read the red run. So tag v0.1.2 never published, the digests in install.sh
# stayed pointed at older images, and every wiki change (the reskin, the
# deleted fake settling card, the dup-decision buttons) kept landing in git
# while never reaching a single customer.
#
# That is the same shape as a writer with no callers: the work exists, the
# tests pass, and the customer sees nothing. The only honest check is to ask
# the registry, as an anonymous client, whether the exact bytes we pin are
# there.
#
# This catches, in one probe:
#   * a digest that was never published (CI silently failed);
#   * a digest typo'd during a re-pin;
#   * a package that is PRIVATE -- pull works for us because we are logged in,
#     and fails for every customer;
#   * an image deleted or a namespace retired underneath us.
#
# Deliberately anonymous: `docker pull` on this machine would succeed from the
# local cache or a logged-in session and prove nothing about a fresh Mac.
#
# Network-dependent by nature. Skips (exit 0) when offline so it cannot wedge
# an air-gapped dev loop, but a reachable registry that refuses a pinned digest
# is a hard failure.
#
# Usage: bash tests/test_pinned_images_are_pullable.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

printf '== test_pinned_images_are_pullable ==\n'
[[ -f "$INSTALL" ]] || { echo "install.sh not found" >&2; exit 3; }

command -v curl >/dev/null 2>&1 || { echo "SKIP: curl unavailable"; exit 0; }
if ! curl -s --max-time 10 -o /dev/null https://ghcr.io/v2/ 2>/dev/null; then
    echo "SKIP: ghcr.io unreachable (offline?); pin check not run"
    exit 0
fi

# Collect every `image: <host>/<path>@sha256:<digest>` pin.
# 🔴 NO mapfile -- bash 4 builtin, and /bin/bash is 3.2 on every Mac.
# MEASURED 2026-08-26: bash 5 rc=0, /bin/bash 3.2 rc=1 "mapfile: command not
# found". The count feeds a zero-guard AND the reported total ("found N
# digest-pinned image(s)"), so the conversion is verified by diffing full
# output before and after, not by eye.
PINS=()
while IFS= read -r _pin; do
    [ -n "$_pin" ] || continue
    PINS+=("$_pin")
done < <(grep -oE 'image:[[:space:]]+ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}' "$INSTALL" \
                    | sed -E 's/^image:[[:space:]]+//' | sort -u)

if [[ "${#PINS[@]}" -eq 0 ]]; then
    bad "no digest-pinned ghcr.io images found in install.sh -- did the pin format change?"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi
ok "found ${#PINS[@]} digest-pinned ghcr.io image(s)"

ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

for pin in "${PINS[@]}"; do
    repo="${pin#ghcr.io/}"; repo="${repo%@*}"
    digest="${pin#*@}"
    short="${repo}@${digest:0:14}…"

    # Anonymous pull token. GHCR issues one for public repos without creds;
    # a private repo yields no usable token, which IS the finding.
    token="$(curl -s --max-time 20 \
        "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("token","") or "")
except Exception: print("")' 2>/dev/null)"

    if [[ -z "$token" ]]; then
        bad "$short -- no anonymous pull token; the package is PRIVATE, so every customer install fails to pull it"
        continue
    fi

    code="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $token" -H "Accept: ${ACCEPT}" \
        "https://ghcr.io/v2/${repo}/manifests/${digest}")"

    case "$code" in
        200) ok "$short -- anonymously pullable" ;;
        404) bad "$short -- HTTP 404: that digest is NOT published. A re-pin pointed at bytes that do not exist (CI push failed, or the digest was mistyped)." ;;
        401|403) bad "$short -- HTTP $code: registry refused an anonymous client. Package is private or the namespace changed." ;;
        *)   bad "$short -- unexpected HTTP $code from ghcr.io" ;;
    esac
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
