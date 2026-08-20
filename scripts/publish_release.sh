#!/usr/bin/env bash
# PUBLISH THE CUT DMG AS A RELEASE OBJECT, AND PROVE A CUSTOMER CAN FETCH IT.
#
# WHY THIS EXISTS. Measured 2026-08-20: 37 cut tags had produced ZERO release
# objects. andygmassey/CM051-Home-Hub-Installer had one release in its entire
# history (v0.1.0, 2026-05-01); ostler-ai/ostler-installer's newest was v0.4.1
# from 2026-05-20. Every cut built a signed, notarised, stapled artefact that
# no customer could obtain: ostler.ai/install.dmg returned 404, and so did the
# download_url the licence API hands to someone who has just paid.
#
# The website redirect was never wrong. `_redirects` maps
#   /install.dmg -> /releases/latest/download/OstlerInstaller.dmg
# and GitHub resolves `latest` to the newest NON-prerelease. There was simply
# no release carrying that asset. Publishing v1.0.37 as a PRERELEASE left the
# 404 in place (measured); promoting it to latest fixed it with no config
# change. Hence --latest below is load-bearing, not decoration.
#
# THE ASSET NAME IS PART OF THE CONTRACT. The redirect requests the literal
# name OstlerInstaller.dmg, so the release must carry that name. A versioned
# copy ships alongside it for humans and for archaeology.
#
# THIS SCRIPT REFUSES TO CLAIM SUCCESS FROM ITS OWN UPLOAD. After publishing it
# fetches the CUSTOMER url and recomputes the hash on the received bytes. A
# release object that exists but does not serve is the failure this whole file
# is here to prevent, and only the customer url can tell you which you have.
set -uo pipefail

VERSION="${1:-}"
DMG="${2:-}"
REPO="${PUBLISH_RELEASE_REPO:-ostler-ai/ostler-installer}"
CUSTOMER_URL="${PUBLISH_RELEASE_CUSTOMER_URL:-https://ostler.ai/install.dmg}"
ASSET_NAME="OstlerInstaller.dmg"

die() { printf '\n[publish-release] ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '[publish-release] %s\n' "$*"; }

[[ -n "$VERSION" ]] || die "usage: publish_release.sh <version e.g. v1.0.37> <path/to.dmg>"
[[ -n "$DMG" && -f "$DMG" ]] || die "DMG not found at '${DMG}'"

# --- the token is the one thing this cannot synthesise -----------------------
# Deliberately a HARD failure and never a skip. A skipped publish is invisible
# from the product side: the cut goes green, the release never appears, and the
# 404 that started all this comes straight back with nobody told.
if [[ -z "${PUBLISH_RELEASE_TOKEN:-}" ]]; then
    cat >&2 <<'MSG'

[publish-release] ERROR: PUBLISH_RELEASE_TOKEN is unset.

  This step publishes into ostler-ai/ostler-installer, which is a DIFFERENT
  org from the repo being cut. secrets.GITHUB_TOKEN cannot reach it, and
  OSTLER_GH_TOKEN_ANDYGMASSEY was MEASURED to be refused: creating the v1.0.37
  release with that identity failed, and only the ostler-ai identity succeeded.

  Needed: the CM051 Actions secret CM051_INSTALLER_PUBLISH, passed in as
  PUBLISH_RELEASE_TOKEN. A fine-grained token with resource owner ostler-ai,
  repository access limited to ostler-ai/ostler-installer, and
  Contents = Read and write (GitHub files releases under Contents).

  DO NOT REUSE ostler-ai's OSTLER_RELEASES_PUBLISH. Measured 2026-08-20: it is
  scoped to ostler-ai/ostler-releases, NOT ostler-installer, so it cannot do
  this job; and its value is already deployed in ostler-remote-capture as the
  secret OSTLER_RELEASES_PUBLISH_TOKEN. GitHub secrets cannot be read back, so
  obtaining a copy would mean regenerating, which would silently invalidate
  remote-capture's next tag cut. Separate token, least privilege.

  Refusing rather than skipping. A silent skip is how 37 tags produced zero
  releases without anyone noticing.

MSG
    exit 1
fi

# --- how long has this token got? --------------------------------------------
# A token that expires between cuts turns this step red at exactly the moment
# someone is trying to ship, which is the worst possible time to discover it.
# Fine-grained PATs return their expiry in a response header, so ask.
#
# THE ABSENCE OF THE HEADER IS NOT REASSURANCE. Classic OAuth tokens do not
# send it, so a missing header means "cannot tell", and this prints exactly
# that rather than the silent nothing that would read as healthy. Never fatal:
# a publish must not be blocked by a diagnostic about the publish.
EXP="$(GH_TOKEN="$PUBLISH_RELEASE_TOKEN" gh api user -i 2>/dev/null \
        | tr -d '\r' \
        | awk 'tolower($1) ~ /^github-authentication-token-expiration:/ {print $2; exit}')"
if [ -z "$EXP" ]; then
    step "token expiry: UNKNOWN (no expiration header; cannot tell, not the same as fine)"
else
    NOW_S="$(date -u +%s)"
    EXP_S="$(date -u -j -f '%Y-%m-%d' "$EXP" +%s 2>/dev/null || date -u -d "$EXP" +%s 2>/dev/null || echo '')"
    if [ -z "$EXP_S" ]; then
        step "token expiry: $EXP (could not parse to compare)"
    else
        DAYS=$(( (EXP_S - NOW_S) / 86400 ))
        step "token expiry: $EXP (${DAYS} days)"
        if [ "$DAYS" -lt 30 ]; then
            echo "::warning::CM051_INSTALLER_PUBLISH expires in ${DAYS} days (${EXP}). Rotate it before it strands a cut."
        fi
    fi
fi

# --- verify what we are about to hand a customer -----------------------------
step "verifying the artefact BEFORE publishing it"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(wc -c < "$DMG" | tr -d ' ')"
step "  sha256 ${SHA}"
step "  bytes  ${SIZE}"

if command -v xcrun >/dev/null 2>&1; then
    xcrun stapler validate "$DMG" >/dev/null 2>&1 \
        || die "stapler validate FAILED on ${DMG}. Refusing to publish an unstapled DMG: it breaks first run when the customer is offline."
    step "  stapler validate rc=0"
    spctl -a -t open --context context:primary-signature "$DMG" >/dev/null 2>&1 \
        || die "spctl REJECTED ${DMG}. Refusing to publish an artefact Gatekeeper will not open."
    step "  spctl accepted"
else
    step "  WARN: xcrun absent, notarisation checks SKIPPED (not a macOS runner)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$DMG" "${WORK}/OstlerInstaller-${VERSION#v}.dmg"
cp "$DMG" "${WORK}/${ASSET_NAME}"
( cd "$WORK" && shasum -a 256 ./*.dmg > SHA256SUMS )

# --- publish -----------------------------------------------------------------
# --latest is REQUIRED, not cosmetic: the site redirect resolves /latest/, and
# GitHub excludes prereleases from that. Publishing without it reproduces the
# exact 404 this script exists to close.
step "publishing ${VERSION} to ${REPO} (marked latest)"
NOTES="Signed, notarised and stapled macOS installer.

    file    OstlerInstaller-${VERSION#v}.dmg
    bytes   ${SIZE}
    sha256  ${SHA}

Verified before upload: sha256 recomputed locally, stapler validate rc=0, spctl accepted."

if GH_TOKEN="$PUBLISH_RELEASE_TOKEN" gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    step "release ${VERSION} already exists, uploading assets with --clobber"
    GH_TOKEN="$PUBLISH_RELEASE_TOKEN" gh release upload "$VERSION" --repo "$REPO" --clobber \
        "${WORK}/OstlerInstaller-${VERSION#v}.dmg" "${WORK}/${ASSET_NAME}" "${WORK}/SHA256SUMS" \
        || die "asset upload failed onto existing release ${VERSION}"
    GH_TOKEN="$PUBLISH_RELEASE_TOKEN" gh release edit "$VERSION" --repo "$REPO" --prerelease=false --latest \
        || die "could not mark ${VERSION} as latest"
else
    GH_TOKEN="$PUBLISH_RELEASE_TOKEN" gh release create "$VERSION" --repo "$REPO" \
        --title "Ostler Hub ${VERSION}" --latest --notes "$NOTES" \
        "${WORK}/OstlerInstaller-${VERSION#v}.dmg" "${WORK}/${ASSET_NAME}" "${WORK}/SHA256SUMS" \
        || die "gh release create failed for ${VERSION}"
fi

# --- prove a customer can actually fetch it ----------------------------------
# The upload succeeding proves the API accepted bytes. It does NOT prove the
# customer url resolves, and the customer url is the thing that was broken.
step "fetching the CUSTOMER url to prove it serves: ${CUSTOMER_URL}"
OUT="${WORK}/fetched.dmg"
CODE="$(curl -sS -L -o "$OUT" -w '%{http_code}' --max-time 600 "$CUSTOMER_URL" 2>/dev/null || echo 000)"
[[ "$CODE" == "200" ]] \
    || die "${CUSTOMER_URL} returned http=${CODE} AFTER publishing ${VERSION}. The release exists but the customer path does not serve it. Check that ${VERSION} is marked latest and carries an asset literally named ${ASSET_NAME}."

GOT="$(shasum -a 256 "$OUT" | awk '{print $1}')"
[[ "$GOT" == "$SHA" ]] \
    || die "${CUSTOMER_URL} served DIFFERENT bytes. expected ${SHA}, got ${GOT}. Something else is answering that url."

step "OK: ${CUSTOMER_URL} serves ${VERSION}, http=200, sha256 matches the notarised artefact"
