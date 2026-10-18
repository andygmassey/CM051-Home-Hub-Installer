#!/usr/bin/env bash
# tests/test_the_store_port_table_cites_anchors_not_line_numbers.sh
# ============================================================================
# THE STORE-PORT PROBE'S PER-PORT TABLE MAY NOT CITE A LINE NUMBER, AND EVERY
# PORT ROW MUST NAME THE POINT IT WAS VERIFIED AT.
#
# MEASURED 2026-09-16 at d0c207fd, on
# scripts/box_walk_probes/probes/no_store_port_is_tcp_reachable.sh:
#
#   TWELVE `install.sh:<line>` pointers. TWELVE stale. A reader following them
#   landed on the Gatekeeper quarantine dialog, a `launchctl print` branch,
#   Safari's History.db path, a bare `fi` and a plist header -- not one on the
#   code its sentence claimed. One of them quoted a comment that `grep` proves
#   is no longer in install.sh at all (control: the same grep finds
#   `ostler-wiki-auth.conf` 5 times, so the zero is real).
#
#   TWO of the SEVEN port rows named a verification point, under a paragraph
#   that claimed "Every row below now names one".
#
# WHY THAT IS A SECURITY DEFECT AND NOT A TYPO (#1595, and #1602 and #1661
# before it). This table is the document a reader consults to decide whether
# #550 is closed. It has now gone stale three times: once reassuring (calling
# shipped-ON credentials default-OFF, which made the whole surface read as
# unfinished and helped hide 8044), once alarming (calling a closed 8044 "the
# worst surface"), and once in its pointers. Every episode has the same cause:
# a claim recorded without the thing that lets a later reader age it.
#
# install.sh is 27k lines. A line number is stale on the next merge and fails
# SILENTLY -- it still resolves, to something else. A grep anchor either finds
# the thing or returns nothing, and nothing is a finding.
#
# WHAT THIS ENFORCES
#   1. no `install.sh:<digits>` pointer anywhere in the probe
#   2. every port in the probe's OWN default MUST_NOT_LISTEN and SURFACES
#      lists has a row in the table that names a v1.0.NN tag or a >=7-hex sha
#
# The denominator in (2) is read out of the probe rather than listed here, so
# a port added later is covered without editing this file, and so a broken
# read is a zero denominator rather than a silent pass.
#
# Exit: 0 both hold, 1 a pointer or an undated row, 2 CANNOT-RUN.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${ROOT}/scripts/box_walk_probes/probes/no_store_port_is_tcp_reachable.sh"

PASS=0; FAIL=0
ok()   { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
cant() { printf 'CANNOT-RUN: %s\n' "$*" >&2
         printf 'A check that could not run has not passed.\n' >&2; exit 2; }

[ -f "$PROBE" ] || cant "no probe at ${PROBE}"

# ---------------------------------------------------------------------------
# (1) NO LINE-NUMBER POINTERS.
# ---------------------------------------------------------------------------
N_PTR="$(/usr/bin/grep -c -E 'install\.sh:[0-9]' "$PROBE" || true)"
if [ "${N_PTR:-0}" -eq 0 ]; then
    ok "no install.sh:<line> pointer in the probe; every citation is a grep anchor"
else
    bad "${N_PTR} install.sh:<line> pointer(s) in the probe. All twelve of these were stale when last measured and a stale pointer resolves SILENTLY to the wrong code. Cite a string to grep for instead."
fi

# CONTROL for (1): the predicate must be able to SEE a pointer, or the zero
# above is a broken grep rather than a clean file. Plant one in a copy.
_tmp="$(mktemp)"; trap 'rm -f "$_tmp"' EXIT
{ cat "$PROBE"; printf '# planted control pointer install.sh:1234\n'; } > "$_tmp"
if [ "$(/usr/bin/grep -c -E 'install\.sh:[0-9]' "$_tmp" || true)" -gt 0 ]; then
    ok "CONTROL: the predicate finds a planted install.sh:<line> pointer, so the count above is a measurement"
else
    bad "CONTROL FAILED: the predicate cannot see a pointer even when one is planted. Every verdict from it is unmeasured."
fi

# ---------------------------------------------------------------------------
# (2) EVERY PORT ROW NAMES A VERIFICATION POINT.
#
# The ports come from the probe's own shipped defaults, so this cannot drift
# out of step with what the probe actually measures.
# ---------------------------------------------------------------------------
_defaults_line() {   # $1 variable name -> the default value, without the ${...-} wrapper
    /usr/bin/sed -n "s/^${1}=\"\\\${OSTLER_[A-Z_]*[:-]-\\{0,1\\}\\(.*\\)}\"\$/\\1/p" "$PROBE" | head -n 1
}
MNL="$(_defaults_line MUST_NOT_LISTEN)"
SURF="$(_defaults_line SURFACES)"
[ -n "$MNL" ]  || cant "could not read the MUST_NOT_LISTEN default out of ${PROBE}; the denominator would be zero and a zero denominator reads as success"
[ -n "$SURF" ] || cant "could not read the SURFACES default out of ${PROBE}; same reason"

PORTS="$MNL"
for e in $SURF; do PORTS="${PORTS} ${e%%:*}"; done
N_PORTS=0
for p in $PORTS; do N_PORTS=$((N_PORTS + 1)); done
[ "$N_PORTS" -ge 2 ] || cant "only ${N_PORTS} port(s) parsed out of the probe's own defaults. The parse is broken, not the file."
ok "CONTROL: ${N_PORTS} ports derived from the probe's own MUST_NOT_LISTEN and SURFACES defaults, so this arm has a subject"

# A row runs from its `#   <port>  ` line to the next such line. A verification
# point is a v1.0.NN tag or a >=7-hex sha -- something a reader can check out.
_row_for() {   # $1 port -> the row's text
    # No {4} interval: the one-true-awk macOS ships did not always support
    # ERE intervals, and this file has to give the same answer on the runner
    # and on the box. Four explicit digit classes instead.
    /usr/bin/awk -v want="$1" '
        /^#[ ][ ]*[0-9][0-9][0-9][0-9][ ]/ { inrow = ($2 == want) }
        inrow { print }
    ' "$PROBE"
}
# Deliberately NOT a bare hex run: "defaced" is seven hex characters and a
# predicate that accepted it would pass a row that names nothing. The sha form
# must be introduced by the word this file already uses for it.
#
# THE ROW IS FLATTENED FIRST. These rows wrap, and the wrap puts a `#` and a
# column of spaces in the middle of the phrase -- so a line-oriented grep
# reports NOTHING FOUND for a row that plainly names a sha, which is a false
# FAIL and would have been read as a finding. Comment markers off, newlines to
# spaces, runs collapsed, then match.
_flatten() { /usr/bin/sed 's/^#[[:space:]]*//' | /usr/bin/tr '\n' ' ' | /usr/bin/tr -s ' '; }
_has_point() {   # $1 text
    printf '%s\n' "$1" | _flatten | /usr/bin/grep -q -E 'at tag v1\.0\.[0-9]+|VERIFIED at [0-9a-f]{7,40}'
}

for p in $PORTS; do
    row="$(_row_for "$p")"
    if [ -z "$row" ]; then
        bad "port ${p} is measured by the probe and has NO row in the per-port table. A port graded by code nobody wrote a reason for is the shape #1595 is about."
        continue
    fi
    if _has_point "$row"; then
        ok "port ${p}: its row names a verification point a reader can check out"
    else
        bad "port ${p}: its row names no tag and no sha, so nothing about it can be AGED. That is the single cause common to all three times this table went stale."
    fi
done

# CONTROL for (2): the point predicate must be able to REFUSE. Strip the
# points out of a real row and re-ask. A predicate that says yes to everything
# would pass every row above without reading one.
_stripped="$(_row_for 6333 | /usr/bin/sed -E -e 's/v1\.0\.[0-9]+//g' -e 's/VERIFIED at [0-9a-f]{7,40}//g')"
if [ -z "$_stripped" ]; then
    bad "CONTROL FAILED: could not build a stripped row for 6333, so the refusal arm measured nothing"
elif _has_point "$_stripped"; then
    bad "CONTROL FAILED: the point predicate still says yes to a row with every tag and sha removed. It says yes to everything, so every ok above is vacuous."
else
    ok "CONTROL: the point predicate REFUSES a row with its tags and shas stripped, so the passes above are measurements"
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
