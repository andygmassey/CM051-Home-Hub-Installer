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

# --- IS THERE A RUNTIME PROOF? (#844) ----------------------------------------
# Everything above this line measures the ARTEFACT: hashes, staple, spctl. All
# of it can pass on a DMG that installs to a broken machine, because none of it
# has ever been installed. #844: nothing between "gates green" and "customer
# download" was a runtime proof. The box-walk probes existed to be that proof
# and NOTHING INVOKED THEM -- measured on origin/main, OS003's cut dirs score 0
# for post_walk_qa and run_box_walk against a control (verify_must_contain)
# that scores bin/cut.sh:368.
#
# The probes cannot run here: they need an installed, walked box, and a box can
# only exist after this script has published something. So publication is SPLIT
# at exactly the line the customer sees:
#
#   no clean walk  ->  publish as PRERELEASE. Assets are up and fetchable by
#                      version, so the box CAN be built and walked. But
#                      /install.dmg resolves /releases/latest/, GitHub excludes
#                      prereleases from it, and the customer keeps getting the
#                      last release that WAS walked.
#   clean walk     ->  promote to latest, then prove the customer url serves it.
#
# Nothing is blocked and no cut is held. What changes is that the repoint now
# costs one piece of evidence.
PROMOTE=1
WALK_NOTE=""
if [[ -n "${PUBLISH_RELEASE_ALLOW_UNWALKED:-}" ]]; then
    # Deliberately requires a REASON, not a boolean. "=1" tells whoever reads
    # the log a year from now nothing at all; a sentence does. It is echoed
    # into the release notes so the bypass is visible from the artefact, not
    # only from a CI log that expires.
    step "⚠️ WALK GATE BYPASSED, reason: ${PUBLISH_RELEASE_ALLOW_UNWALKED}"
    WALK_NOTE="

⚠️ Published without a clean box walk. Reason given: ${PUBLISH_RELEASE_ALLOW_UNWALKED}"
elif [[ -x "${BASH_SOURCE[0]%/*}/verify_walk_record.sh" ]]; then
    # $SHA is computed at the top of this script from the DMG about to be
    # uploaded -- not read from a manifest, not passed in. Handing it to the
    # gate is what turns "a v1.0.50 box was walked" into "THIS BUILD of v1.0.50
    # was walked" (#931). Both sides of that comparison are content hashes.
    "${BASH_SOURCE[0]%/*}/verify_walk_record.sh" "$VERSION" "$SHA"
    case $? in
        0) WALK_NOTE="

Walked clean on a real box before release." ;;
        *) PROMOTE=0 ;;
    esac
else
    # The gate is missing from the tree. Fail CLOSED: an absent gate must not
    # read as a satisfied one, which is how a deleted check becomes a silent
    # promotion.
    step "⚠️ verify_walk_record.sh not found -- treating as NO walk evidence"
    PROMOTE=0
fi

# --- publish -----------------------------------------------------------------
# --latest is REQUIRED, not cosmetic: the site redirect resolves /latest/, and
# GitHub excludes prereleases from that. Publishing without it reproduces the
# exact 404 this script exists to close -- which is why it is withheld
# deliberately above, and never by accident.
if [[ "$PROMOTE" -eq 1 ]]; then
    step "publishing ${VERSION} to ${REPO} (marked latest)"
else
    step "publishing ${VERSION} to ${REPO} as a PRERELEASE (no clean walk on record)"
fi
NOTES="Signed, notarised and stapled macOS installer.

    file    OstlerInstaller-${VERSION#v}.dmg
    bytes   ${SIZE}
    sha256  ${SHA}

Verified before upload: sha256 recomputed locally, stapler validate rc=0, spctl accepted.${WALK_NOTE}"

if [[ "$PROMOTE" -eq 1 ]]; then
    RELEASE_FLAGS=(--prerelease=false --latest)
    CREATE_FLAGS=(--latest)
else
    RELEASE_FLAGS=(--prerelease=true)
    CREATE_FLAGS=(--prerelease)
fi

if GH_TOKEN="$PUBLISH_RELEASE_TOKEN" gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    step "release ${VERSION} already exists, uploading assets with --clobber"
    GH_TOKEN="$PUBLISH_RELEASE_TOKEN" gh release upload "$VERSION" --repo "$REPO" --clobber \
        "${WORK}/OstlerInstaller-${VERSION#v}.dmg" "${WORK}/${ASSET_NAME}" "${WORK}/SHA256SUMS" \
        || die "asset upload failed onto existing release ${VERSION}"
    GH_TOKEN="$PUBLISH_RELEASE_TOKEN" gh release edit "$VERSION" --repo "$REPO" "${RELEASE_FLAGS[@]}" \
        || die "could not set release state on ${VERSION}"
else
    GH_TOKEN="$PUBLISH_RELEASE_TOKEN" gh release create "$VERSION" --repo "$REPO" \
        --title "Ostler Hub ${VERSION}" "${CREATE_FLAGS[@]}" --notes "$NOTES" \
        "${WORK}/OstlerInstaller-${VERSION#v}.dmg" "${WORK}/${ASSET_NAME}" "${WORK}/SHA256SUMS" \
        || die "gh release create failed for ${VERSION}"
fi

# --- prove a customer can actually fetch it ----------------------------------
# The upload succeeding proves the API accepted bytes. It does NOT prove the
# customer url resolves, and the customer url is the thing that was broken.
step "fetching the CUSTOMER url: ${CUSTOMER_URL}"
OUT="${WORK}/fetched.dmg"
CODE="$(curl -sS -L -o "$OUT" -w '%{http_code}' --max-time 600 "$CUSTOMER_URL" 2>/dev/null || echo 000)"
GOT="$(shasum -a 256 "$OUT" 2>/dev/null | awk '{print $1}')"

if [[ "$PROMOTE" -eq 1 ]]; then
    [[ "$CODE" == "200" ]] \
        || die "${CUSTOMER_URL} returned http=${CODE} AFTER publishing ${VERSION}. The release exists but the customer path does not serve it. Check that ${VERSION} is marked latest and carries an asset literally named ${ASSET_NAME}."
    [[ "$GOT" == "$SHA" ]] \
        || die "${CUSTOMER_URL} served DIFFERENT bytes. expected ${SHA}, got ${GOT}. Something else is answering that url."
    step "OK: ${CUSTOMER_URL} serves ${VERSION}, http=200, sha256 matches the notarised artefact"
else
    # THE WITHHOLDING IS ASSERTED, NOT ASSUMED. Skipping the check here would
    # leave "we did not repoint the customer" as an untested belief -- and the
    # belief would look identical whether the prerelease flag worked or was
    # silently ignored. Two positive assertions instead:
    #   1. the customer url STILL SERVES (200) -- the previous good release is
    #      intact and no customer has been handed a 404 by this run
    #   2. it does NOT serve THIS version's bytes -- the repoint really was
    #      withheld
    [[ "$CODE" == "200" ]] \
        || die "${CUSTOMER_URL} returned http=${CODE}. Publishing ${VERSION} as a prerelease should have left the PREVIOUS release serving. A 404 here means customers have no download at all."
    [[ "$GOT" != "$SHA" ]] \
        || die "${CUSTOMER_URL} is serving ${VERSION}'s bytes despite it being published as a PRERELEASE. The customer download was repointed to an unwalked build -- the exact thing the walk gate exists to prevent."

    cat <<MSG

════════════════════════════════════════════════════════════
 ${VERSION} IS PUBLISHED, AND CUSTOMERS ARE NOT GETTING IT YET.
════════════════════════════════════════════════════════════
  It is a PRERELEASE. Verified just now:
    ${CUSTOMER_URL} -> http=200, still the previous release
    (its sha256 is ${GOT:-<none>}, not ${SHA})

  Nothing is broken and no cut is held. The assets are up, so the
  DMG can be downloaded by version, installed, and walked.

  To release it to customers:
    1. install ${VERSION} on a box
    2. scripts/post_walk_qa.sh <box-host> ${VERSION}
    3. commit the walk record it writes under walks/
    4. re-run this script

  This is #844: gates green is a statement about the artefact, not
  about the product. The box walk is the only runtime proof there
  is, and until now nothing consulted it.
════════════════════════════════════════════════════════════
MSG
fi
