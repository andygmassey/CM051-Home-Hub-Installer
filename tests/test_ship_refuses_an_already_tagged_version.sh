#!/usr/bin/env bash
#
# tests/test_ship_refuses_an_already_tagged_version.sh
#
# A RELEASE BUILT AT AN ALREADY-TAGGED VERSION IS INVISIBLE TO SPARKLE AND
# MISLABELS EVERY RECORD BOUND TO IT.
#
# MEASURED 2026-09-06, on the artefact that was queued for the v1.0.73 walk:
#
#     DMG sha256 6f001449be3b...  (the published cut artefact)
#       mounted bundle   CFBundleShortVersionString  1.0.72
#                        CFBundleVersion             7200
#       origin/main      all four version sites      1.0.72 / 7200
#       cut-manifests/v1.0.73.yaml:31                version: v1.0.73
#       git ls-remote --tags                         newest tag is v1.0.72
#
# The tree was never bumped, and nothing bumps it: every `bump` in gui/Makefile
# is a manual python / daemon / Ostler.app pin, and
# test_installer_version_consistency.sh:30 says so outright.
#
# WHY THE EXISTING GATE CANNOT SEE THIS. That gate asserts the four version
# sites agree AND that the build number is DERIVED from the marketing version
# (1.0.P -> P*100). 1.0.72 derives 7200, so the tree agrees with itself
# perfectly and the gate exits 0. It guards internal consistency, which is the
# PROXY. Nothing compares the version to the set of versions already shipped,
# which is the PROPERTY. That gate's own header records this class twice: the
# app shipped reading 1.0.10 for both v1.0.11 and v1.0.12, then froze through
# seven consecutive cuts. The fix at the time replaced a hand-copied manifest
# row with a derivation -- strictly better, and still blind here.
#
# WHY IT IS NOT COSMETIC, in that same header's words: "CFBundleVersion is the
# field Sparkle compares." An artefact shipped as v1.0.73 carrying 7200 is
# indistinguishable from v1.0.72 to Sparkle, so no box already on v1.0.72 is
# ever offered it. A walk record binds to the exact artefact bytes, so the
# record and every BOM row referencing it name a version the artefact does not
# claim.
#
# WHY SHIP-TIME AND NOT PUSH-TIME. Immediately after a tag, main legitimately
# sits at the version just shipped until someone bumps it. Asserting this on
# every push would redden main for that window and teach people to ignore it.
# The question only has a right answer at the moment a release artefact is
# about to be built, so it belongs in ship's prerequisites, where it costs one
# ls-remote and fails before the first download.
#
# THE SUBSTRING TRAP, tested below. `v1.0.7` is a prefix of `v1.0.72`. A naive
# grep for the version inside the tag list reports 1.0.7 as already shipped on
# a repo that has only ever tagged 1.0.72. Matching is exact, on the full ref.
#
# TWO ARMS.
#   A  the version must not already be tagged        (needs the remote)
#   B  the version must name the NEWEST cuts/ record (local, and the one that
#      guards the four path-resolving consumers directly)
#
# B is the stronger of the two and exists because A is a proxy. What the payload
# actually depends on is that cuts/v$(VERSION)/ IS this cut's record; "not yet
# tagged" merely correlates with that. B is also offline, so it still answers
# when the remote does not.
#
# OSTLER_ALLOW_OLDER_CUT=1 relaxes arm B for a hotfix on an older line, and only
# that far: the version must still have a cuts/ record of its own. Arm A is not
# relaxed by it, so an already-tagged version is still refused.
#
# Exit 0 = both arms clear, safe to build
# Exit 1 = FAIL. Either the version is already tagged, or it does not name the
#          newest cut record in the tree.
# Exit 2 = CANNOT-RUN. Never a pass: a tag list that could not be read, a
#          version that could not be established, or a tree with no cut records
#          is not evidence of safety.

set -uo pipefail

REPO_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$REPO_ROOT_DEFAULT"
SELF_TEST=0
REMOTE="origin"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --self-test)  SELF_TEST=1; shift ;;
        --repo-root)  REPO_ROOT="${2:?--repo-root needs a directory}"; shift 2 ;;
        --remote)     REMOTE="${2:?--remote needs a name}"; shift 2 ;;
        *) echo "usage: $0 [--self-test] [--repo-root DIR] [--remote NAME]" >&2; exit 2 ;;
    esac
done

# ── The two predicates, as functions, so the self-test drives the REAL code ──
#
# A guard that can only be exercised by the thing it lives inside is a guard
# nobody exercises. Same reasoning as test_expiry_needs_a_cut_version.sh.

# A version is digits and dots and nothing else. This exists because PlistBuddy
# WRITES ITS ERRORS TO STDOUT: on a missing key it emits
# "FileDoesn'tExist,WillCreate:/path" and exits 0, so `[[ -n ]]` passes on a
# failure. ttywalk.sh carries the scar from shipping exactly that as a version.
version_has_valid_shape() {
    [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)+$ ]]
}

# Exact match on the full ref, never a substring. Accepts the peeled form
# `refs/tags/vX^{}` that ls-remote emits beside each annotated tag.
version_is_already_tagged() {
    local _version="$1" _taglist="$2"
    printf '%s\n' "$_taglist" | awk -v want="refs/tags/v${_version}" '
        {
            ref = $NF
            sub(/\^\{\}$/, "", ref)
            if (ref == want) { found = 1 }
        }
        END { exit(found ? 0 : 1) }
    '
}

# THE TAG PUSH *IS* THE CUT, WHICH INVERTS ARM A's PREMISE ON THE CI PATH.
#
# MEASURED 2026-09-07T08:57:31Z, cut run 34103178059, the first cut to reach
# `make ship` after #1748 landed at 03:10Z:
#
#     [ship-version] Info.plist CFBundleShortVersionString: 1.0.74
#     [ship-version] newest cut record in tree:             v1.0.74
#     [ship-version] tags on origin:                        333
#     FAIL: refusing to build. v1.0.74 is ALREADY TAGGED on origin.
#
# Arm B passed. Arm A refused, and it would refuse EVERY cut forever, because
# `.github/workflows/cut.yml` fires ON a `v1.0.*` tag push. By the time its
# `cut:` job runs `make ship`, the tag it is cutting necessarily exists on
# origin -- pushing it is what started the run. Arm A was therefore
# unconditionally true on the only path that produces a DMG.
#
# THE HEADER ABOVE ALREADY SAW HALF OF THIS. "WHY SHIP-TIME AND NOT PUSH-TIME"
# argues the question only has a right answer when an artefact is about to be
# built. That is correct. What it missed is that in this repo the build is
# TRIGGERED BY the tag, so ship-time is strictly AFTER tag-time and the two are
# not separable. The gate was written for the operator path, where a human
# builds first and tags after, and applied to the CI path, where the order is
# reversed.
#
# THE NARROWING, and it keeps the whole defect the gate was written for.
# Refuse only when the version is tagged AT A COMMIT THAT IS NOT THIS BUILD.
# A tag pointing at the very commit being built is this cut's own tag; a tag
# pointing anywhere else means bytes are being stamped with a version that
# already shipped from different source, which is exactly the v1.0.73 case:
# there the tree said 1.0.72 while cuts/ said v1.0.73, so HEAD was nowhere
# near a v1.0.72 tag and this narrowing still refuses it. Arm B catches that
# one first regardless.
#
# FAIL-CLOSED. If either sha cannot be resolved the answer is unknown, and an
# unknown answer is not a safe one -- tag_is_this_build() returns false and the
# refusal stands.

# The commit a tag names, from an `ls-remote --tags` listing. The peeled form
# `refs/tags/vX^{}` wins when present, because for an ANNOTATED tag the bare
# ref names the tag OBJECT and only the peeled line names the commit. A
# lightweight tag has no peeled line and its bare ref is already the commit.
tagged_commit() {
    local _version="$1" _taglist="$2"
    printf '%s\n' "$_taglist" | awk -v want="refs/tags/v${_version}" '
        {
            ref = $NF; sha = $1; peeled = 0
            if (ref ~ /\^\{\}$/) { sub(/\^\{\}$/, "", ref); peeled = 1 }
            if (ref == want) {
                if (peeled)          { p = sha }
                else if (l == "")    { l = sha }
            }
        }
        END { if (p != "") print p; else if (l != "") print l }
    '
}

# Both shas must resolve AND agree. Empty is never a match: an unresolvable sha
# is a failure to look, and this gate does not treat those as passes.
tag_is_this_build() {
    local _tag_sha="${1:-}" _head_sha="${2:-}"
    [[ -n "$_tag_sha" && -n "$_head_sha" && "$_tag_sha" == "$_head_sha" ]]
}

# The newest version in a list. Field-wise numeric rather than `sort -V`:
# -V exists on this host and on GNU, but its tie-breaking is not identical
# across implementations and the self-test runs on the CI runner, not here.
# Four fields, because hotfix versions are four-part (1.0.13.2).
newest_version() {
    printf '%s\n' "$1" | grep -E '^[0-9]+(\.[0-9]+)+$' \
        | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1
}

# A version one above the given one, used only to build fixtures. Fixtures must
# NOT hard-code a number: arm 16 originally copied the repo's Info.plist into a
# tree holding cuts/v1.0.73, which stops being a mismatch the moment the repo is
# bumped to 1.0.73 -- the self-test then fails on a correct tree. Caught by
# merge-simulating the bump, not by running the suite here.
higher_version() {
    # OFS in BEGIN, not mid-rule: assigning $NF rebuilds the record using the OFS
    # in force AT THAT MOMENT. Setting it afterwards prints "1 0 73".
    printf '%s\n' "$1" | awk -F. 'BEGIN { OFS="." } { $NF = $NF + 1; print }'
}

# ââ Self-test ────────────────────────────────────────────────────────────────
if [[ $SELF_TEST -eq 1 ]]; then
    _fails=0; _total=0
    _arm() {
        local _name="$1" _want="$2" _got="$3"
        _total=$((_total + 1))
        if [[ "$_want" == "$_got" ]]; then
            printf '  ok    %s\n' "$_name"
        else
            printf '  FAIL  %s (wanted %s, got %s)\n' "$_name" "$_want" "$_got"
            _fails=$((_fails + 1))
        fi
    }

    REAL_TAGS="$(printf '%s\n' \
        'aaaa	refs/tags/v1.0.71' \
        'bbbb	refs/tags/v1.0.71^{}' \
        'cccc	refs/tags/v1.0.72' \
        'dddd	refs/tags/v1.0.72^{}')"

    echo "self-test: version_is_already_tagged"
    version_is_already_tagged "1.0.72" "$REAL_TAGS"; _arm "1 already-tagged version is DETECTED"      0 $?
    version_is_already_tagged "1.0.73" "$REAL_TAGS"; _arm "2 unshipped version is allowed"            1 $?
    version_is_already_tagged "1.0.7"  "$REAL_TAGS"; _arm "3 SUBSTRING v1.0.7 does not match v1.0.72" 1 $?
    version_is_already_tagged "1.0.71" "$REAL_TAGS"; _arm "4 annotated tag matches via its peeled ref" 0 $?
    version_is_already_tagged "1.0.72" "";           _arm "5 empty tag list matches nothing"          1 $?

    # ── tagged_commit + tag_is_this_build ────────────────────────────────
    #
    # THE SUBTLE ONE IS ARM 30, and it is the control that makes 34 mean
    # anything. For an ANNOTATED tag the bare `refs/tags/vX` line carries the
    # TAG OBJECT's sha, not the commit's. If tagged_commit returned that, it
    # could never equal `git rev-parse HEAD`, the exemption would never fire,
    # and the gate would keep refusing every cut while LOOKING exactly as it
    # does now -- a fix that reads as applied and is not. So the peeled line
    # must win, and 30 asserts it does by demanding the peeled sha and not the
    # tag-object sha that sits one line above it in the same fixture.
    echo "self-test: tagged_commit"
    _arm "30 ANNOTATED tag yields the PEELED commit, not the tag object" \
         "dddd" "$(tagged_commit "1.0.72" "$REAL_TAGS")"
    _arm "31 a LIGHTWEIGHT tag yields its own ref sha" \
         "eeee" "$(tagged_commit "1.0.80" "$(printf '%s\n' 'eeee	refs/tags/v1.0.80')")"
    _arm "32 an untagged version yields nothing" \
         "" "$(tagged_commit "1.0.99" "$REAL_TAGS")"
    _arm "33 SUBSTRING v1.0.7 does not pick up v1.0.72's sha" \
         "" "$(tagged_commit "1.0.7" "$REAL_TAGS")"

    echo "self-test: tag_is_this_build"
    tag_is_this_build "dddd" "dddd"; _arm "34 tag AT the built commit is this cut"      0 $?
    tag_is_this_build "dddd" "cccc"; _arm "35 tag at ANOTHER commit still refuses"      1 $?
    tag_is_this_build ""     "dddd"; _arm "36 unresolvable tag sha is NOT a pass"       1 $?
    tag_is_this_build "dddd" "";     _arm "37 unresolvable HEAD is NOT a pass"          1 $?
    tag_is_this_build ""     "";     _arm "38 two unknowns are NOT a match"             1 $?

    echo "self-test: version_has_valid_shape"
    version_has_valid_shape "1.0.72";                                  _arm "6 a real version"        0 $?
    version_has_valid_shape "1.0.13.2";                                _arm "7 a four-part version"   0 $?
    version_has_valid_shape "FileDoesn'tExist,WillCreate:/tmp/x";      _arm "8 PlistBuddy diagnostic REJECTED" 1 $?
    version_has_valid_shape "";                                        _arm "9 empty rejected"        1 $?
    version_has_valid_shape "unknown";                                 _arm "10 Makefile's 'unknown' fallback rejected" 1 $?

    echo "self-test: newest_version"
    _arm "11 picks the highest, not the last"        "1.0.73" "$(newest_version "$(printf '1.0.71\n1.0.73\n1.0.72\n')")"
    _arm "12 numeric, not lexical (10 beats 9)"      "1.0.10" "$(newest_version "$(printf '1.0.9\n1.0.10\n')")"
    _arm "13 a four-part hotfix outranks its parent" "1.0.13.2" "$(newest_version "$(printf '1.0.13\n1.0.13.2\n')")"
    _arm "14 junk lines are ignored"                 "1.0.72" "$(newest_version "$(printf 'permanent\n1.0.72\nREADME\n')")"

    # END-TO-END RED PROOF. The arms above drive the predicates; this one drives
    # THE SCRIPT ITSELF against a stale fixture and asserts it actually refuses.
    # Predicate-level arms cannot show that the live path wires them up.
    #
    # Arm B fires before any network call, so this needs no remote. It does need
    # PlistBuddy to read the fixture's version, which is macOS-only -- on a Linux
    # runner the script would exit 2 (CANNOT-RUN) and asserting merely "non-zero"
    # would pass VACUOUSLY, crediting a proof that measured nothing. So the
    # assertion is exit 1 exactly, and the arm declares itself unrun elsewhere.
    echo "self-test: end-to-end"
    if [[ -x /usr/libexec/PlistBuddy ]]; then
        _fx="$(mktemp -d "${TMPDIR:-/tmp}/vergate-fx.XXXXXX")"
        _fxv="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                  "${REPO_ROOT}/gui/OstlerInstaller/Info.plist" 2>/dev/null)"
        mkdir -p "$_fx/gui/OstlerInstaller" "$_fx/cuts/v$(higher_version "$_fxv")"
        cp "${REPO_ROOT}/gui/OstlerInstaller/Info.plist" "$_fx/gui/OstlerInstaller/Info.plist" 2>/dev/null
        bash "${BASH_SOURCE[0]}" --repo-root "$_fx" >/dev/null 2>&1; _rc_red=$?
        _total=$((_total + 1))
        if [ "$_rc_red" -eq 1 ]; then
            printf '  ok    16 END-TO-END: exits 1 on a tree stamped below its newest cut record\n'
        else
            printf '  FAIL  16 END-TO-END: wanted exit 1 on the stale fixture, got %s\n' "$_rc_red"
            _fails=$((_fails + 1))
        fi
        rm -rf "$_fx"
    else
        printf '  ----  16 END-TO-END: NOT RUN here (no /usr/libexec/PlistBuddy).\n'
        printf '        Not counted as a pass. This arm proves red on the cut machine.\n'
    fi

    # THE OVERRIDE MUST NOT BECOME A BYPASS. OSTLER_ALLOW_OLDER_CUT relaxes
    # "newest", not "exists". Offline, so it runs anywhere PlistBuddy does.
    # This arm exists so a later simplification into a blanket bypass fails here.
    if [[ -x /usr/libexec/PlistBuddy ]]; then
        _fx2="$(mktemp -d "${TMPDIR:-/tmp}/vergate-ov.XXXXXX")"
        _fxv2="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                   "${REPO_ROOT}/gui/OstlerInstaller/Info.plist" 2>/dev/null)"
        mkdir -p "$_fx2/gui/OstlerInstaller" "$_fx2/cuts/v$(higher_version "$_fxv2")"
        cp "${REPO_ROOT}/gui/OstlerInstaller/Info.plist" "$_fx2/gui/OstlerInstaller/Info.plist" 2>/dev/null
        OSTLER_ALLOW_OLDER_CUT=1 bash "${BASH_SOURCE[0]}" --repo-root "$_fx2" >/dev/null 2>&1; _rc_ov=$?
        _total=$((_total + 1))
        # -eq 1, NOT -ne 0. The fixture has no git remote, so anything that
        # gets past arm B reaches arm A and exits 2 (CANNOT-RUN). '-ne 0'
        # would accept that, and the arm would pass on the very mutant it
        # exists to catch. Same vacuity trap as arm 16.
        if [ "$_rc_ov" -eq 1 ]; then
            printf '  ok    17 OVERRIDE is not a bypass: still refuses a version with no cut record\n'
        else
            printf '  FAIL  17 OVERRIDE let a version with NO cut record through (rc=%s)\n' "$_rc_ov"
            _fails=$((_fails + 1))
        fi
        rm -rf "$_fx2"
    else
        printf '  ----  17 OVERRIDE arm NOT RUN here (no PlistBuddy). Not counted as a pass.\n'
    fi

    # CONTROL. Arms 1 and 2 must DISAGREE. If both returned the same value the
    # fourteen arms above could all be satisfied by a constant, and would be.
    version_is_already_tagged "1.0.72" "$REAL_TAGS"; _a=$?
    version_is_already_tagged "1.0.73" "$REAL_TAGS"; _b=$?
    _total=$((_total + 1))
    if [[ "$_a" != "$_b" ]]; then
        printf '  ok    15 CONTROL: the detect and allow arms disagree (%s vs %s)\n' "$_a" "$_b"
    else
        printf '  FAIL  11 CONTROL: both arms returned %s -- a constant would pass this suite\n' "$_a"
        _fails=$((_fails + 1))
    fi

    echo
    if [[ $_fails -eq 0 ]]; then echo "self-test: ${_total}/${_total} pass"; exit 0; fi
    echo "self-test: ${_fails} of ${_total} FAILED"; exit 1
fi

# ── Live run ─────────────────────────────────────────────────────────────────

INFO_PLIST="${REPO_ROOT}/gui/OstlerInstaller/Info.plist"
[[ -f "$INFO_PLIST" ]] || { echo "CANNOT-RUN: no Info.plist at ${INFO_PLIST} (exit 2)" >&2; exit 2; }

# Read it the same way gui/Makefile:120 reads it, so this gate and the build
# can never disagree about what is being built.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"

if ! version_has_valid_shape "$VERSION"; then
    echo "CANNOT-RUN: could not read a version-shaped value from ${INFO_PLIST}." >&2
    echo "  got: '${VERSION}'" >&2
    echo "  PlistBuddy reports errors on STDOUT, so a diagnostic can arrive in" >&2
    echo "  place of a value and a non-empty check cannot tell the difference." >&2
    exit 2
fi

echo "[ship-version] Info.plist CFBundleShortVersionString: ${VERSION}"

# ── ARM B: the version must name the NEWEST cut record in the tree ──────────
#
# This is the arm that guards the property directly. Four things in gui/Makefile
# resolve a path from $(VERSION) -- the cut BOM (:1203), the daemon pin operand
# (:1721), the cut manifest (:2046) and the DMG name (:130). Every one of them
# reads cuts/v$(VERSION)/... or cut-manifests/v$(VERSION).yaml, and every one of
# them found a file that EXISTS on 2026-09-06 while the cut being built was
# v1.0.73. A missing input is loud in all four. The wrong input was silent in
# all four, because the previous cut's files are still in the tree.
#
# gui/Makefile:1195 says $(VERSION) is safe as that key ONLY because
# OS003/gates/verify_version_stamp_matches_cut.sh asserts it in cut preflight.
# That gate is real and correct, and it is wired into OS003/bin/cut.sh, which
# `make -C gui ship` does not call. This arm makes the CM051 path carry the
# check itself, so choosing an entry point cannot void it.
CUTS_DIR="${REPO_ROOT}/cuts"
if [[ -d "$CUTS_DIR" ]]; then
    CUT_VERSIONS="$(ls -1 "$CUTS_DIR" 2>/dev/null | sed -n 's/^v//p')"
    NEWEST_CUT="$(newest_version "$CUT_VERSIONS")"
    if [[ -z "$NEWEST_CUT" ]]; then
        echo "CANNOT-RUN: ${CUTS_DIR} holds no vN.N.N directory. The cut records" >&2
        echo "  are how this gate knows which cut is being built." >&2
        exit 2
    fi
    echo "[ship-version] newest cut record in tree:             v${NEWEST_CUT}"
    if [[ "$NEWEST_CUT" != "$VERSION" ]] && [[ -n "${OSTLER_ALLOW_OLDER_CUT:-}" ]]; then
        # DELIBERATE OVERRIDE, for a hotfix on an older line. Building 1.0.71.1
        # while cuts/v1.0.73 exists is legitimate and this arm would otherwise
        # refuse it with no way through -- and a gate that blocks a real
        # operation is one people learn to disable wholesale. Named, loud, and
        # it still requires the version to HAVE a cut record of its own, so it
        # relaxes "newest" without relaxing "exists". Same idiom as
        # ALLOW_STALE_SOURCE=1 in sync_cut_bom.sh.
        if [[ -d "${CUTS_DIR}/v${VERSION}" ]]; then
            echo "[ship-version] OSTLER_ALLOW_OLDER_CUT set: building v${VERSION}" >&2
            echo "[ship-version]   while the newest record is v${NEWEST_CUT}. Allowed," >&2
            echo "[ship-version]   because cuts/v${VERSION}/ exists. Arm A still applies." >&2
        else
            echo "" >&2
            echo "FAIL: OSTLER_ALLOW_OLDER_CUT is set, but there is no cuts/v${VERSION}/" >&2
            echo "  at all. The override relaxes \"newest\", not \"exists\". A build whose" >&2
            echo "  version names no cut record has no BOM, no cut.env and no manifest." >&2
            exit 1
        fi
    elif [[ "$NEWEST_CUT" != "$VERSION" ]]; then
        echo "" >&2
        echo "FAIL: refusing to build. The version does not name the newest cut record." >&2
        echo "" >&2
        echo "    Info.plist says          ${VERSION}" >&2
        echo "    newest cuts/ record is   ${NEWEST_CUT}" >&2
        echo "" >&2
        echo "  Four things resolve a path from this version, and all four would" >&2
        echo "  silently read v${VERSION}'s copy while you build v${NEWEST_CUT}:" >&2
        echo "      cuts/v${VERSION}/MUST_CONTAIN.tsv        the cut BOM" >&2
        echo "      cuts/v${VERSION}/cut.env                 the daemon pin operand" >&2
        echo "      cut-manifests/v${VERSION}.yaml           the cut gate" >&2
        echo "      <app>-${VERSION}.dmg                     the artefact name" >&2
        echo "" >&2
        echo "  Those files exist, so nothing else will complain. Bump the version," >&2
        echo "  or remove the cut record that does not belong to this build." >&2
        exit 1
    fi
else
    echo "CANNOT-RUN: no ${CUTS_DIR}. Cannot establish which cut is being built." >&2
    exit 2
fi

TAGS="$(git -C "$REPO_ROOT" ls-remote --tags "$REMOTE" 2>/dev/null)"
LS_RC=$?

if [[ $LS_RC -ne 0 ]]; then
    echo "CANNOT-RUN: git ls-remote --tags ${REMOTE} exited ${LS_RC} in ${REPO_ROOT}." >&2
    echo "  The set of already-shipped versions is unknown. That is not the same" >&2
    echo "  as knowing this version is unshipped." >&2
    exit 2
fi

TAG_COUNT="$(printf '%s\n' "$TAGS" | grep -c 'refs/tags/' || true)"
if [[ "$TAG_COUNT" -eq 0 ]]; then
    # A zero here is the shape of a broken predicate, not a young repo: this
    # gate only ever runs in a repo that is about to cut a RELEASE.
    echo "CANNOT-RUN: ${REMOTE} returned 0 tags. A release repo with no tags is" >&2
    echo "  a failed query, not an empty history." >&2
    exit 2
fi

echo "[ship-version] tags on ${REMOTE}:                       ${TAG_COUNT}"

if version_is_already_tagged "$VERSION" "$TAGS"; then
    # See "THE TAG PUSH *IS* THE CUT" above. A tag naming the commit being
    # built is this run's own trigger, not a version that already shipped.
    TAG_SHA="$(tagged_commit "$VERSION" "$TAGS")"
    HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" || HEAD_SHA=""
    if tag_is_this_build "$TAG_SHA" "$HEAD_SHA"; then
        echo "[ship-version] v${VERSION} is tagged at ${TAG_SHA}, which IS the"
        echo "[ship-version] commit being built. That is this cut's own tag --"
        echo "[ship-version] cut.yml fires ON the tag push, so the tag always"
        echo "[ship-version] exists by the time ship runs. Arm A does not apply."
        echo "PASS: v${VERSION} is this cut's tag, not a shipped version (${TAG_COUNT} tags checked)"
        exit 0
    fi
    echo "" >&2
    echo "FAIL: refusing to build. v${VERSION} is ALREADY TAGGED on ${REMOTE}," >&2
    echo "      at ${TAG_SHA:-<unresolvable>}, and this build is at ${HEAD_SHA:-<unresolvable>}." >&2
    echo "" >&2
    echo "  You are about to produce a release artefact stamped with a version" >&2
    echo "  that has already shipped. CFBundleVersion is what Sparkle compares," >&2
    echo "  so every box already on v${VERSION} would never be offered this" >&2
    echo "  build, and any walk record or BOM row bound to these bytes would" >&2
    echo "  name a version the artefact does not claim." >&2
    echo "" >&2
    echo "  Bump all four sites, then rebuild:" >&2
    echo "      gui/project.yml                        (4 values)" >&2
    echo "      gui/OstlerInstaller/Info.plist          (2 values)" >&2
    echo "      gui/OstlerInstaller.xcodeproj/project.pbxproj  (4 values)" >&2
    echo "" >&2
    echo "  The build number is derived: 1.0.P -> P*100. See" >&2
    echo "  tests/test_installer_version_consistency.sh, which asserts that." >&2
    exit 1
fi

echo "PASS: v${VERSION} is not yet tagged on ${REMOTE} (${TAG_COUNT} tags checked)"
exit 0
