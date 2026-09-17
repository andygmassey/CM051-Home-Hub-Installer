#!/usr/bin/env bash
#
# verify_customer_download_is_current.sh
#
# GOES RED when the build customers download is older than the newest build that
# has earned the right to be downloaded.
#
# ⚠️ THE WORDING OF THIS HEADER IS LOAD-BEARING, AND I GOT IT WRONG FIRST TIME.
# scripts/verify_declared_gates_reachable.sh enumerates the cut-gate population
# by grepping the whole tree CASE-INSENSITIVELY for a set of declaring phrases,
# then demands every file that matches be reachable from the cut. This file is
# not in that population: it says nothing about the artefact being assembled,
# only about which already-published artefact the public url resolves to.
#
# My first draft opened with one of those phrases, then added a paragraph
# explaining that it was NOT one -- and a case-insensitive grep matches the
# denial exactly as well as the claim. That is the same trap as
# test_the_cut_checklist_is_complete.py, where "NOT LAUNCH BLOCKING" parsed as
# BLOCKING. So the phrases do not appear here at all, in either polarity.
#
# What invokes it instead: .github/workflows/customer-download-path.yml, and
# tests/test_download_currency_gate_is_wired.sh asserts that invocation exists,
# because a gate nobody calls and a gate that passes print the same nothing.
#
# WHY THIS EXISTS. CM051 #2107, measured 2026-09-17, minutes after v1.0.100 was
# built, signed, notarised, stapled and published:
#
#     gh api repos/ostler-ai/ostler-installer/releases/latest -q .tag_name
#       -> v1.0.41
#     curl -sSL https://ostler.ai/install.dmg | wc -c
#       -> 57877510          <- v1.0.41's bytes, exactly
#     v1.0.100's OstlerInstaller.dmg
#       -> 72098359
#
# Anyone following ostler.ai/install.dmg that day downloaded a build 59 versions
# old. Nothing was broken and nothing went red: the redirect resolved correctly,
# the releases existed, every gate we owned passed. GitHub resolves `latest` to
# the newest NON-prerelease, every cut since v1.0.41 published as a prerelease,
# and nothing ever promoted one.
#
# THE GATE THAT SHOULD HAVE CAUGHT IT ALREADY EXISTED AND COULD NOT.
# scripts/verify_customer_download_path.sh asserts the served version in `public`
# posture, and .github/workflows/customer-download-path.yml already runs it. It
# is green because nothing tells it WHICH version should be served: the tag is a
# workflow_dispatch input a human types, so with no input it runs in prelaunch
# posture and asserts only that the path resolves at all. The missing piece was
# never the check. It was the EXPECTATION.
#
# This file supplies the expectation, and it derives it rather than storing it,
# because a stored expectation is one more thing to forget to update.
#
# HOW THE EXPECTATION IS DERIVED, AND WHY IT DELEGATES.
# "Which build has earned the customer download" is exactly the question
# scripts/verify_walk_record.sh answers, so this asks that script rather than
# reimplementing clean/console/scope. Two gates that decide the same thing by
# different code will disagree eventually, and the disagreement will be silent.
#
# ⚠️ THE SHA HANDED TO THAT GATE IS THE RECORD'S OWN. That is deliberate and it
# is a WEAKER question than the one publish_release.sh asks. publish_release.sh
# hashes the DMG it is about to upload and asks "was THIS BUILD walked" (#931).
# Here there is no candidate artefact -- the question is "does this record
# authorise a promote of the build it names", so the record's own artefact_sha256
# is the subject, not a cross-check. Anyone reading this as a content check would
# be wrong, hence the paragraph.
#
# WHAT A ZERO MEANS HERE, STATED SO IT CANNOT BE MISREAD. Measured 2026-09-17:
# 20 walk records exist and 20 are FAILED. Not one build in this repo's history
# has ever earned a promote. So "no promotable record" is the NORMAL state today
# and it is a PASS -- but the denominator is printed every time, because "no
# record authorises a promote" and "I could not read the records" print the same
# green otherwise.
#
# EXIT CODES
#   0  the served build is the newest promotable one, or nothing is promotable
#   1  RED: served is behind a promotable build, or ahead of every promotable
#      build (something was promoted that no record authorises -- worse)
#   2  CANNOT-RUN: the release API or the walk gate could not be consulted
#
# British English throughout.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WALK_DIR="${OSTLER_WALK_RECORD_DIR:-${REPO_ROOT}/walks}"
RELEASE_REPO="${PUBLISH_RELEASE_REPO:-ostler-ai/ostler-installer}"
WALK_GATE="${SCRIPT_DIR}/verify_walk_record.sh"

say() { printf '[download-currency] %s\n' "$*"; }
red() { printf '[download-currency] %s\n' "$*" >&2; }

# --- a sortable key ----------------------------------------------------------
# v1.0.100 must sort ABOVE v1.0.99, which is the whole reason this is not a
# string compare: "1.0.100" < "1.0.99" lexically, and that single fact is how a
# currency check would report the newest build as the oldest. Sub-patch is
# carried in its own field rather than folded in, because patch*100+subpatch
# makes 1.0.99.100 and 1.0.100 the same number.
vkey() {
    local v="${1#v}" a b c d
    IFS=. read -r a b c d <<< "$v"
    [[ "$a" =~ ^[0-9]+$ ]] || return 1
    [[ "$b" =~ ^[0-9]+$ ]] || return 1
    [[ "$c" =~ ^[0-9]+$ ]] || return 1
    [[ -n "${d:-}" ]] || d=0
    [[ "$d" =~ ^[0-9]+$ ]] || return 1
    printf '%05d%05d%05d%05d\n' "$a" "$b" "$c" "$d"
}

[[ -x "$WALK_GATE" ]] || { red "CANNOT-RUN: ${WALK_GATE} is not executable. An absent gate is not a satisfied one."; exit 2; }

# --- 1. what SHOULD be served ------------------------------------------------
shopt -s nullglob
RECORDS=("${WALK_DIR}"/*.tsv)
shopt -u nullglob
N_RECORDS=${#RECORDS[@]}

BEST=""; BEST_KEY=""; N_PROMOTABLE=0
for r in "${RECORDS[@]}"; do
    base="${r##*/}"; ver="${base%.tsv}"
    sha="$(awk -F'\t' '$1=="artefact_sha256"{print $2; exit}' "$r")"
    [[ -n "$sha" ]] || continue
    OSTLER_WALK_RECORD_DIR="$WALK_DIR" "$WALK_GATE" "$ver" "$sha" >/dev/null 2>&1
    [[ $? -eq 0 ]] || continue
    N_PROMOTABLE=$(( N_PROMOTABLE + 1 ))
    k="$(vkey "$ver")" || continue
    if [[ -z "$BEST_KEY" || "$k" > "$BEST_KEY" ]]; then BEST_KEY="$k"; BEST="$ver"; fi
done

say "walk records examined: ${N_RECORDS} in ${WALK_DIR}"
say "records that authorise a promote: ${N_PROMOTABLE} of ${N_RECORDS} (scripts/verify_walk_record.sh, rc=0)"

# --- 2. what IS served -------------------------------------------------------
API="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
HDR=(-H 'Accept: application/vnd.github+json')
[[ -n "${GH_TOKEN:-}" ]] && HDR+=(-H "Authorization: Bearer ${GH_TOKEN}")
BODY="$(curl -sS --max-time 30 "${HDR[@]}" "$API" 2>/dev/null)"
CURL_RC=$?
if [[ $CURL_RC -ne 0 || -z "$BODY" ]]; then
    red "CANNOT-RUN: could not read ${API} (curl rc=${CURL_RC}). Not a pass: the served version is unknown."
    exit 2
fi
SERVED="$(printf '%s' "$BODY" | /usr/bin/python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tag_name",""))
except Exception: print("")' 2>/dev/null)"
if [[ -z "$SERVED" ]]; then
    red "CANNOT-RUN: ${RELEASE_REPO} has no release marked latest, or the response was unreadable."
    red "            First 200 bytes: $(printf '%s' "$BODY" | head -c 200)"
    exit 2
fi
say "releases/latest on ${RELEASE_REPO}: ${SERVED}  <- what a customer downloads"

# --- 3. compare --------------------------------------------------------------
if [[ $N_PROMOTABLE -eq 0 ]]; then
    say "OK: no walk record authorises a promote, so ${SERVED} staying put is correct."
    say "    This is a PASS on an empty numerator, which is why the denominator is printed above."
    exit 0
fi

SERVED_KEY="$(vkey "$SERVED")" || { red "CANNOT-RUN: cannot parse the served tag '${SERVED}' as a version."; exit 2; }
say "newest promotable build: ${BEST}"

if [[ "$BEST_KEY" == "$SERVED_KEY" ]]; then
    say "OK: customers are downloading ${SERVED}, which is the newest build with a walk record that authorises it."
    exit 0
fi

if [[ "$BEST_KEY" > "$SERVED_KEY" ]]; then
    red "RED: customers are downloading ${SERVED}, but ${BEST} has earned the download and nobody promoted it."
    red ""
    red "     This is CM051 #2107 recurring. Nothing is broken and nothing will go"
    red "     red anywhere else: the redirect resolves, the release exists, and the"
    red "     newer build is sitting there as a prerelease that /releases/latest/"
    red "     excludes by design."
    red ""
    red "     To fix it, with the PUBLISHED bytes and never a rebuild:"
    red "       gh release download ${BEST} --repo ${RELEASE_REPO} \\"
    red "           --pattern OstlerInstaller.dmg --dir /tmp/promote-${BEST}"
    red "       PUBLISH_RELEASE_TOKEN=... scripts/publish_release.sh ${BEST} \\"
    red "           /tmp/promote-${BEST}/OstlerInstaller.dmg"
    red ""
    red "     That script re-runs the walk gate and the BOM gate, promotes, and then"
    red "     fetches the customer url and compares the bytes it receives."
    exit 1
fi

red "RED: customers are downloading ${SERVED}, which is NEWER than ${BEST}, the newest build any walk record authorises."
red ""
red "     This is the worse direction. A build was promoted to the customer"
red "     download without a walk record that authorises it, or the record that"
red "     authorised it has since been removed or downgraded. Either way the"
red "     public download is currently unbacked by evidence."
red ""
red "     Do not fix this by promoting ${BEST}: that would REPLACE a customer's"
red "     download with an older build. Find out why ${SERVED} is latest first."
exit 1
