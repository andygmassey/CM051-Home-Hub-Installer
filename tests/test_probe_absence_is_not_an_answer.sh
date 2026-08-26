#!/usr/bin/env bash
# tests/test_probe_absence_is_not_an_answer.sh
# ============================================================================
# THE DEFECT THIS EXISTS FOR, measured on a live installed box, 2026-08-26.
# (The box is named by its walk record, not here: this repo is PUBLIC, so no
# operator username, hostname or LAN address goes in a tracked file.)
#
# pair_state_agreement.sh read its third pairing signal like this:
#
#     ls $HOME/.ostler/paired_devices/*.json 2>/dev/null | wc -l
#
# ~/.ostler/paired_devices DOES NOT EXIST on that box. A failed `ls` still
# feeds `wc` an empty stream, so wc printed 0, and the probe mapped 0 to the
# confident answer `false` -- "no device is paired".
#
# That is not the same fact as "I could not look", and it was the one answer
# that could not be true: the same box carries 35 issued bearer tokens in
# config.toml. The other two signals were UNAVAILABLE (the doctor health body
# has no `paired` key; devices.db is a 0-byte file with no schema), so this
# fail-open `false` was the ONLY readable signal -- and one signal cannot
# contradict itself. The probe could therefore only ever return INSUFFICIENT
# while sitting on top of a genuine pairing split-brain.
#
# AN ABSENT PATH IS A THIRD STATE. Absence must reach the adjudicator as
# UNAVAILABLE, never as a count of zero.
#
# bash 3.2 compatible: /bin/bash on every Mac is 3.2.57. No mapfile, no
# declare -A, no ${var^^}.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBES="${HERE}/../scripts/box_walk_probes/probes"

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

# ---------------------------------------------------------------------------
# The scanner. Finds `ls <glob> | wc -l` that is NOT preceded by a directory
# existence guard on the same line. Comments are excluded -- the fix's own
# explanatory comment quotes the defective idiom verbatim, and a scanner that
# cannot tell a quotation from an instruction reports its own documentation as
# a defect.
# ---------------------------------------------------------------------------
scan_unguarded() {
    # scan_unguarded <file> -> prints offending lines, empty if clean
    /usr/bin/grep -nE 'ls [^|]*\|[[:space:]]*wc -l' "$1" 2>/dev/null \
      | /usr/bin/grep -v '^[0-9]*:[[:space:]]*#' \
      | /usr/bin/grep -v '\[ -d '
}

printf '\n== arm 1: the fixed probe guards the directory before counting ==\n'
marker_body="$(sed -n '/^signal_pair_marker()/,/^}/p' "${PROBES}/pair_state_agreement.sh")"
if printf '%s' "$marker_body" | /usr/bin/grep -q '\[ -d '; then
    ok "signal_pair_marker tests the directory with [ -d ] before counting"
else
    bad "signal_pair_marker counts inside a directory it never proved exists"
fi

printf '\n== arm 2: absence maps to UNAVAILABLE, not to a count ==\n'
if printf '%s' "$marker_body" | /usr/bin/grep -q 'ABSENT) printf .UNAVAILABLE'; then
    ok "an absent directory reaches the adjudicator as UNAVAILABLE"
else
    bad "no ABSENT -> UNAVAILABLE arm: absence can still read as a definite answer"
fi

printf '\n== arm 3: no probe carries an unguarded glob-count ==\n'
offenders=0
for p in "${PROBES}"/*.sh; do
    hits="$(scan_unguarded "$p")"
    if [ -n "$hits" ]; then
        offenders=$((offenders + 1))
        printf '        %s\n' "$(basename "$p")"
        printf '%s\n' "$hits" | sed 's/^/          /'
    fi
done
n_probes="$(ls "${PROBES}"/*.sh 2>/dev/null | /usr/bin/grep -c .)"
if [ "$offenders" -eq 0 ]; then
    ok "0 of ${n_probes} probes count inside an unproved directory"
else
    bad "${offenders} of ${n_probes} probes count inside an unproved directory"
fi

printf '\n== arm 4: POSITIVE CONTROL -- the scanner must FIND a planted defect ==\n'
# Without this arm, arm 3 passes just as happily when the scanner is broken and
# examines nothing. The control lives in a temp file, NEVER in the probes tree,
# so the gate cannot hunt a value it is itself carrying.
# `mktemp -t NAME` is BSD-only. GNU mktemp (ubuntu-latest, which is what
# walk-record-gate.yml runs on) rejects it: "too few X's in template".
# MEASURED in a real ubuntu:latest container, rc=1. An explicit XXXXXX
# template is the one form both accept.
ctl="$(mktemp "${TMPDIR:-/tmp}/probe_ctl.XXXXXX")"
{
    printf 'signal_planted() {\n'
    printf '    out="$(box_run "ls $HOME/.ostler/nope/*.json 2>/dev/null | wc -l")"\n'
    printf '}\n'
} > "$ctl"
if [ -n "$(scan_unguarded "$ctl")" ]; then
    ok "scanner fires on a planted unguarded glob-count (it is not blind)"
else
    bad "scanner did NOT fire on a planted defect -- arm 3's clean verdict is meaningless"
fi
rm -f "$ctl"

printf '\n== arm 5: the scanner does not flag the guarded form ==\n'
ctl2="$(mktemp "${TMPDIR:-/tmp}/probe_ctl2.XXXXXX")"
printf 'x="$(box_run "if [ -d \\"$D\\" ]; then ls $D/*.json 2>/dev/null | wc -l; else printf ABSENT; fi")"\n' > "$ctl2"
if [ -z "$(scan_unguarded "$ctl2")" ]; then
    ok "scanner stays quiet on the guarded form (no false accusation)"
else
    bad "scanner flags the CORRECT form -- it would block the fix it is meant to protect"
fi
rm -f "$ctl2"

printf '\n---- %s passed, %s failed ----\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
