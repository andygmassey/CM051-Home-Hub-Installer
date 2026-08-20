#!/usr/bin/env bash
#
# tests/test_appcast_debt_is_collected.sh
#
# THE DEFERRAL THIS COLLECTS
# --------------------------
# Andy's decision, 2026-08-19, settled and not to be re-litigated: a Sparkle
# EdDSA PRIVATE key will not be held as an Actions secret on a PUBLIC repo.
# Signing happens on the box.
#
# So CI cuts with PUBLISH_APPCAST=onbox: the DMG is complete, the appcast is
# NOT published, and the step exits 0 rather than reddening a good cut.
#
# That exit 0 is the whole risk. An unpublished appcast is INVISIBLE from the
# product side: the feed simply does not list the release, Sparkle polls it,
# finds nothing, and reports no update available. Every surface looks healthy.
# Installed Hubs never see the release. That is task #370's exact shape, "the
# publisher exists and NOTHING calls it", and it is why the previous authors
# kept the hard-require even though it reddened every cut.
#
# The hard-require is not softened here. It MOVES. CI stops pretending it
# might publish, and this gate collects the debt on the next cut.
#
# THE DENOMINATOR IS RELEASES, NOT CUTS. This is the correction that matters
# -----------------------------------------------------------------------
# The first version of this gate took its denominator from cuts/<v>/cut.env,
# on the reasoning that a cut record is written by the pipeline and so cannot
# drift from what was cut. True, and the wrong question.
#
# A CUT is a build. A RELEASE is a build somebody can obtain. Sparkle's feed
# points at a download URL, so a version with no release has nothing for an
# appcast entry to point AT. Demanding an entry for it is not strictness, it
# is a false accusation, and on 2026-08-19 it was a false accusation eight
# versions deep that would have refused the launch cut.
#
# Measured that day, with working controls (see CONTROLS below):
#   cuts/v*/cut.env present            : 8   (v1.0.29 .. v1.0.36)
#   of those, GitHub releases          : 0
#   releases on the repo, any tag      : 1   (v0.1.0, 2026-05-01)
#   appcast.ostler.ai <item> elements  : 0   (HTTP 200, empty <channel>)
# So nothing was owed, and the gate said eight things were.
#
# Keying on releases also makes the gate self-maintaining. Nobody has to
# remember to enrol the launch version: the moment a release exists for it,
# it enters the denominator, and the NEXT cut refuses until its appcast
# entry is recorded.
#
# WHY A POSITIVE RECORD, NOT AN "OWED" LIST
# -----------------------------------------
# cuts/appcast-published.txt records versions that HAVE been published. A
# version is considered unpublished when it is ABSENT.
#
# That direction is deliberate. An "owed" list has to be written correctly at
# the moment of deferral, by the process that is deferring, and if that write
# is ever missed the debt vanishes silently and the gate goes green having
# checked nothing. A positive record fails the other way: forget to write it
# and the gate REFUSES. The failure mode of a missing record is a false
# accusation, which someone fixes in a minute, rather than a false clean,
# which nobody ever notices.
#
# CONTROLS, and why there are three
# ---------------------------------
# This gate now asks GitHub a question, so "no release found" has two causes
# that look identical from here: there is no release, or the probe cannot
# see the repo. On 2026-08-19 the second one happened for real -- every
# lookup 404'd because the slug was wrong -- and the only reason it did not
# read as "nothing is owed" is that the LIST call 404'd too. cut.yml:289
# records the same class of failure from a token scoped to the wrong repo.
#
# So before any verdict:
#   C1 APPARATUS   the releases LIST must return a JSON array with >= 1 entry.
#                  A repo we cannot see returns an error here, not an empty
#                  array. This is a must-FIND control, not a must-not-find one.
#   C2 POSITIVE    at least one tag named by the cut records must resolve to a
#                  sha. Proves the probe can find a thing that exists.
#   C3 NEGATIVE    a synthetic tag that cannot exist must NOT resolve. Proves
#                  the probe can still refuse, so C2 is not passing because
#                  every lookup succeeds.
# Any control failing is CANNOT-RUN. A gate that cannot measure has not passed.
#
# EXIT CODES
#   0  every RELEASED version older than the one being cut has been published
#   1  at least one has not (the versions are named)
#   2  CANNOT-RUN, and it is NOT a pass
#
# macOS bash 3.2.57 + BSD userland. No `grep -P`, no `sed \b`, no `grep -o`
# with GNU-only flags. British English; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORD="${APPCAST_PUBLISHED_RECORD:-${REPO_ROOT}/cuts/appcast-published.txt}"
CUTS_DIR="${REPO_ROOT}/cuts"

RC_DEBT=1
RC_CANNOT_RUN=2

# A tag that cannot exist, for C3. Deliberately not a plausible typo of a real
# version: if this one ever resolves, the probe is answering yes to everything.
IMPOSSIBLE_TAG="v0.0.0-archie-negative-control-must-not-exist"

cannot_run() {
    echo "CANNOT-RUN: $*" >&2
    echo "  Nothing was checked. This is not a passing gate." >&2
    exit "$RC_CANNOT_RUN"
}

[[ -d "$CUTS_DIR" ]] || cannot_run "no cuts/ directory at ${CUTS_DIR}"

# ── Which versions the pipeline has CUT ─────────────────────────────
#
# Still read from cuts/<v>/cut.env, because that is the pipeline's own record
# of a build and cannot drift from what was built. It is the candidate set,
# no longer the denominator.
CUT_VERSIONS=()
for d in "$CUTS_DIR"/v*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}cut.env" ]] || continue
    CUT_VERSIONS+=("$(basename "$d")")
done

if [[ "${#CUT_VERSIONS[@]}" -eq 0 ]]; then
    cannot_run "found no cuts/v*/cut.env, so there is no cut to check.
  Either this is not a CM051 checkout, or the cut records are missing. A gate
  that examined zero versions must not report success."
fi

# CURRENT is the version being cut, if the caller named one. It is exempt:
# its appcast is published AFTER the cut, so demanding it now would refuse
# every cut forever.
CURRENT="${CUT_VERSION:-}"

# ── The probe, and its three controls ───────────────────────────────
#
# 🔴 THE RELEASES ARE NOT ON THIS REPO, AND KEYING ON THIS REPO MADE THE GATE
# UNABLE TO FIRE. Measured 2026-08-19, with GITHUB_REPOSITORY unset so the
# slug resolved to andygmassey/CM051-Home-Hub-Installer:
#
#     cut records found        : 13
#     cut but NOT released     : 13   <-- every one, because it asked the
#     RELEASED, so owed a feed : 0        WRONG REPO for the release
#     verdict                  : PASS rc=0
#
# ...while the live feed carried ZERO <item>. The gate whose entire purpose is
# "a deferral cannot become permanent without somebody noticing" reported that
# nothing was owed, on the exact day the deferral was made permanent.
#
# Customer artefacts ship from ostler-ai/ostler-releases. install.sh:10779 and
# scripts/verify_cut_freshness.sh:848 both already name it, and that repo uses
# COMPONENT-PREFIXED tags (hub-vX.Y.Z, remote-capture-vX.Y.Z, installer-vX.Y.Z)
# rather than the bare vX.Y.Z this gate was looking up. Both halves had to be
# wrong for the zero to look plausible: wrong repo AND wrong tag shape.
#
# CODE_SLUG stays this repo -- tags/refs genuinely live here. RELEASES_SLUG is
# where a customer-obtainable release lives. They are different questions and
# conflating them is what produced the false zero.
CODE_SLUG="${GITHUB_REPOSITORY:-}"
if [[ -z "$CODE_SLUG" ]]; then
    CODE_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
[[ -n "$CODE_SLUG" ]] || cannot_run "could not resolve the repository slug.
  Set GITHUB_REPOSITORY, or run where 'gh repo view' can answer. Guessing a
  slug is how every lookup 404s and the gate reports nothing is owed."

RELEASES_SLUG="${OSTLER_RELEASES_REPO:-ostler-ai/ostler-releases}"
RELEASE_TAG_PREFIX="${OSTLER_INSTALLER_TAG_PREFIX:-installer-}"
SLUG="$RELEASES_SLUG"

command -v gh >/dev/null 2>&1 || cannot_run "gh is not on PATH, so no release can be looked up."

# C1 APPARATUS. A repo the token cannot see errors here; it does not return [].
RELEASE_COUNT="$(gh api "repos/${SLUG}/releases" --jq 'length' 2>/dev/null || true)"
case "$RELEASE_COUNT" in
    ''|*[!0-9]*)
        cannot_run "C1 FAILED: could not list releases for ${SLUG}.
  This is the failure that masquerades as 'nothing is owed'. Check the token
  scope before reading any verdict from this gate. (cut.yml:289 is the same
  class: a token scoped to another repo, and every compare 404'd.)" ;;
esac
if [[ "$RELEASE_COUNT" -lt 1 ]]; then
    cannot_run "C1 FAILED: ${SLUG} reports 0 releases in total.
  The apparatus cannot be distinguished from a repo it cannot read, so no
  verdict here would mean anything. If this repo genuinely has no releases
  yet, this gate has nothing to enforce and the control must be revisited
  deliberately rather than relaxed in passing."
fi

# C1b APPARATUS, ON THE PREDICATE ITSELF. C1 proves the repo LISTS releases.
# It does not prove that `releases/tags/<something>` -- the call the verdict is
# actually built from -- can ever return TRUE.
#
# That gap is not hypothetical: it is the bug this control was added for. The
# gate spent its whole life calling releases/tags/v1.0.36 against a repo whose
# tags are all PREFIXED (hub-v..., installer-v...). Every call 404'd, every
# version scored "not released", and the verdict was a confident PASS. C1 was
# green throughout, because listing worked fine.
#
# So: take a tag the LIST just returned, and require the LOOKUP to find it. A
# predicate that cannot return true cannot produce a finding, and a gate that
# cannot produce a finding is decoration.
NEWEST_TAG="$(gh api "repos/${RELEASES_SLUG}/releases" --jq '.[0].tag_name' 2>/dev/null || true)"
if [[ -z "$NEWEST_TAG" ]]; then
    cannot_run "C1b FAILED: could not read a tag_name from ${RELEASES_SLUG}'s release list."
fi
if ! gh api "repos/${RELEASES_SLUG}/releases/tags/${NEWEST_TAG}" --jq '.tag_name' >/dev/null 2>&1; then
    cannot_run "C1b FAILED: the release LOOKUP could not find '${NEWEST_TAG}', a tag the
  release LIST just returned. The lookup this gate's verdict is built on cannot
  return true, so its 'nothing is owed' means nothing. Check RELEASES_SLUG
  (${RELEASES_SLUG})."
fi

# C1c PREFIX COVERAGE -- THE SHAPE OF THE ZERO.
#
# C1b proves the lookup MECHANISM works. It does NOT prove the composed form
# this gate builds -- "<prefix><version>" -- can ever match, because it looked
# up a tag the list handed it rather than one the gate composed. That is the
# same instrument/defect split the gate itself was suffering from, reproduced
# inside its own control, and it is why C1b passed on BOTH the fixed and the
# broken prefix.
#
# There is no honest way to demand that installer-vX.Y.Z resolve today: no
# installer release has ever been made, so requiring one would be a false
# accusation. What IS honest is to make the zero's shape impossible to misread.
PREFIX_MATCHES="$(gh api "repos/${RELEASES_SLUG}/releases" --paginate \
    --jq "[.[] | select(.tag_name | startswith(\"${RELEASE_TAG_PREFIX}\"))] | length" 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo 0)"
PREFIX_MATCHES="${PREFIX_MATCHES:-0}"

# C2 POSITIVE. At least one cut version's TAG must resolve.
C2_TAG=""
for v in "${CUT_VERSIONS[@]+"${CUT_VERSIONS[@]}"}"; do
    if gh api "repos/${CODE_SLUG}/git/ref/tags/${v}" --jq '.object.sha' >/dev/null 2>&1; then
        C2_TAG="$v"
        break
    fi
done
[[ -n "$C2_TAG" ]] || cannot_run "C2 FAILED: not one of the ${#CUT_VERSIONS[@]} cut versions has a resolvable tag.
  Every cut is made by pushing a tag, so at least one must exist. That none
  resolves means the probe is not reaching this repo's refs."

# C3 NEGATIVE. The impossible tag must NOT resolve.
if gh api "repos/${CODE_SLUG}/git/ref/tags/${IMPOSSIBLE_TAG}" --jq '.object.sha' >/dev/null 2>&1; then
    cannot_run "C3 FAILED: the impossible tag ${IMPOSSIBLE_TAG} RESOLVED.
  The probe is answering yes regardless of input, so C2 proves nothing and a
  'no release' answer cannot be trusted either."
fi

# ── The denominator: cut AND released ───────────────────────────────
OWED=()
RELEASED_SKIPPED=()
for v in "${CUT_VERSIONS[@]+"${CUT_VERSIONS[@]}"}"; do
    if [[ -n "$CURRENT" && "$v" == "$CURRENT" ]]; then
        continue
    fi
    if gh api "repos/${RELEASES_SLUG}/releases/tags/${RELEASE_TAG_PREFIX}${v}" --jq '.tag_name' >/dev/null 2>&1; then
        OWED+=("$v")
    else
        RELEASED_SKIPPED+=("$v")
    fi
done

published_count=0
if [[ -f "$RECORD" ]]; then
    published_count="$(grep -c '^v[0-9]' "$RECORD" 2>/dev/null || echo 0)"
fi

echo "DENOMINATOR"
echo "  code repository          : ${CODE_SLUG}   (tags/refs)"
echo "  releases repository      : ${RELEASES_SLUG}   (customer artefacts, tag prefix '${RELEASE_TAG_PREFIX}')"
echo "  cut records found        : ${#CUT_VERSIONS[@]}"
echo "  current cut (exempt)     : ${CURRENT:-<none named; CUT_VERSION unset>}"
echo "  cut but NOT released     : ${#RELEASED_SKIPPED[@]}  (nothing for a feed to point at)"
echo "  RELEASED, so owed a feed : ${#OWED[@]}"
echo "  published-record entries : ${published_count}  (${RECORD})"
echo "CONTROLS"
echo "  C1 apparatus  : PASS  (${SLUG} lists ${RELEASE_COUNT} release(s))"
echo "  C1b lookup    : PASS  (releases/tags/${NEWEST_TAG} resolves -- the predicate CAN return true)"
if [[ "$PREFIX_MATCHES" -eq 0 ]]; then
    echo "  C1c prefix    : ⚠️  ZERO releases carry the prefix '${RELEASE_TAG_PREFIX}'."
    echo "                  So every version below scores 'not released' by construction, and"
    echo "                  a PASS here means 'no installer has EVER been released', NOT"
    echo "                  'the appcast is up to date'. The first real installer release"
    echo "                  is what makes this gate start doing its job."
else
    echo "  C1c prefix    : PASS  (${PREFIX_MATCHES} release(s) carry '${RELEASE_TAG_PREFIX}')"
fi
echo "  C2 positive   : PASS  (tag ${C2_TAG} resolves)"
echo "  C3 negative   : PASS  (${IMPOSSIBLE_TAG} does not resolve)"
echo ""

if [[ "${#OWED[@]}" -eq 0 ]]; then
    echo "PASS: no released version is missing an appcast entry."
    echo "  ${#RELEASED_SKIPPED[@]} cut version(s) were never released, so none owes one."
    echo "  This is a measured zero, not an unrun check: all three controls passed"
    echo "  above and the release lookup ran once per cut version."
    exit 0
fi

MISSING=()
for v in "${OWED[@]}"; do
    # Whole-line match. A substring match would let v1.0.3 satisfy v1.0.36,
    # which is the prefix trap that has cost this project real time.
    if ! grep -q -x -F -- "$v" "$RECORD" 2>/dev/null; then
        MISSING+=("$v")
    fi
done

if [[ "${#MISSING[@]}" -gt 0 ]]; then
    echo "FAIL: ${#MISSING[@]} RELEASED version(s) have NO appcast entry recorded:" >&2
    for v in "${MISSING[@]}"; do echo "    - $v" >&2; done
    echo "" >&2
    echo "  What this means: installed Hubs cannot see those releases. Sparkle" >&2
    echo "  polls the feed, the feed does not list them, and it reports no" >&2
    echo "  update available. Nothing looks broken anywhere." >&2
    echo "" >&2
    echo "  ON THE BOX, for each version above:" >&2
    echo "    export OSTLER_SPARKLE_SIGNING_KEY=/path/sparkle_private.pem  # 0400/0600" >&2
    echo "    make -C gui publish-appcast PUBLISH_APPCAST=1" >&2
    echo "" >&2
    echo "  The publish appends the version to:" >&2
    echo "    ${RECORD}" >&2
    echo "" >&2
    echo "  Do NOT satisfy this gate by editing that file by hand. The record" >&2
    echo "  exists to say a publish HAPPENED. Writing the line without doing" >&2
    echo "  the publish converts a loud debt into a silent one, which is the" >&2
    echo "  entire failure this gate was built to prevent." >&2
    exit "$RC_DEBT"
fi

echo "PASS: all ${#OWED[@]} released version(s) have a recorded appcast entry."
exit 0
