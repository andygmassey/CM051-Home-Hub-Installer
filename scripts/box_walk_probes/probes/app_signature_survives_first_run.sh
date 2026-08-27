#!/usr/bin/env bash
# probes/app_signature_survives_first_run.sh
# ============================================================================
# QUESTION: does the installer still verify AFTER its interpreter has run?
#
# Measured 2026-08-25: the v1.0.45 DMG passed 14 of 14 artefact checks and then
# bricked itself the first time Andy launched it --
#     "OstlerInstaller is damaged and can't be opened. You should move it to
#      the Bin."
#
# CAUSE. CPython writes __pycache__/*.pyc beside imported source. The
# interpreter ships INSIDE the notarised app, so the first import rewrites the
# sealed bundle, codesign goes to rc=1 and Gatekeeper refuses it.
#
# 🔴 WHY EVERY ARTEFACT CHECK MISSED IT, and this is the lesson worth keeping:
# all 14 read the app on a READ-ONLY volume, where this defect CANNOT occur.
# A control that cannot exhibit the defect is not a control. This probe reads a
# WRITABLE copy, which is the only place a customer ever runs it.
#
# ── THREE DEFECTS IN THIS FILE'S OWN HISTORY, FIXED 2026-08-26 ──────────────
#
# 1. IT HAD NEVER RUN. It defined `run()`; probe_main dispatches `run_probe`.
#    Every box walk since it was written printed
#    "VERDICT: BROKEN -- defines no run_probe" and measured NOTHING. The gate
#    for the defect that has cost the most releases was itself dark.
#
# 2. ITS .pyc PREDICATE WAS INVERTED BY THE FIX. It failed on `pyc > 0`. That
#    was right for the v1.0.45 design, which shipped ZERO .pyc. v1.0.47
#    deliberately PRE-SEEDS 1448 unchecked-hash .pyc -- that IS the fix. Lit as
#    written, this probe would have failed v1.0.47 for being correct. Third
#    instance of this exact staleness (walk_dmg ARM 8 #1086, ARM 7 #1088).
#
# 3. IT GREPPED ONLY `^file added:`. v1.0.46 scored 0 on `added:` and bricked
#    anyway, because a rewrite-in-place reports `modified:` and moves no file
#    count at all. Count-shaped predicates are structurally blind to it.
#
# WHAT "CORRECT" LOOKS LIKE NOW (PEP 552): every shipped .pyc carries flag word
# 1 (unchecked-hash) at byte offset 4 -- never revalidated, therefore never
# rewritten. flags 0 (timestamp) and 2/3 (checked-hash) are revalidated against
# the source and WILL be rewritten inside the bundle.
# ============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/probe.sh"

PROBE_NAME="app_signature_survives_first_run"
PROBE_QUESTION="does the installer still verify after its own bundled interpreter has run?"

# Overridable ONLY so this probe can be proved against a real bricked specimen
# (see the v1.0.45 copy preserved during the 2026-08-26 walk). The default is
# the customer path and no caller in the suite sets it.
APP="${OSTLER_INSTALLER_APP:-/Applications/OstlerInstaller.app}"
PY_REL=Contents/Resources/python/bin/python3.11

# Aggregate digest of every .pyc, so a REWRITE-IN-PLACE is visible. A count
# cannot see it: v1.0.46 went 1448 -> 1448 while codesign went 0 -> 1.
_pyc_digest_cmd() {
    printf "find '%s' -name '*.pyc' -type f -print0 2>/dev/null | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print \$1}'" "$1"
}

# PEP 552 flag-word census, ONE LINE PER FILE, emitted as G/B/U:
#   G  flag word 1  -- unchecked-hash, never revalidated, never rewritten
#   B  anything else -- timestamp (0) or checked-hash (3), WILL be rewritten
#   U  unreadable    -- mode unknown, which is CANNOT-RUN, not a pass
#
# Per-file, not `-exec od {} \;` piped into grep: od emits a trailing blank
# line per file, so a naive `grep -vc '^1$'` counts the blanks as failures.
# The self_test below caught exactly that in this probe's first draft — two
# fixture files, one genuinely bad, and the count came back 3.
_flag_census_cmd() {
    printf "find '%s' -name '*.pyc' -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do fl=\$(od -An -tu4 -j4 -N4 \"\$f\" 2>/dev/null | tr -d ' \\n'); if [ -z \"\$fl\" ]; then echo U; elif [ \"\$fl\" != 1 ]; then echo B; else echo G; fi; done | sort | uniq -c | awk '{print \$2\"=\"\$1}' | tr '\\n' ' '" "$1"
}

# Pull one count out of a census string like "B=45 G=1403 ".
_census_get() {  # $1 = census, $2 = key
    printf '%s\n' "$1" | tr ' ' '\n' | /usr/bin/grep "^$2=" | cut -d= -f2 | head -1
}

run_probe() {
    box_reachable || { probe_cannot_run "box not reachable"; return; }

    if ! box_run "[ -d '$APP' ]"; then
        probe_cannot_run "no ${APP} on this box -- nothing to examine. NOT a pass."
        return
    fi

    # ── DENOMINATOR ────────────────────────────────────────────────────────
    # codesign must actually read the bundle. A silent failure to read is
    # indistinguishable, by exit code alone, from a clean verify.
    local out lines
    out=$(box_run "codesign --verify --deep --strict --verbose=2 '$APP' 2>&1")
    lines=$(printf '%s\n' "$out" | /usr/bin/grep -c . || true)
    probe_examined "$lines" "line(s) of codesign output for ${APP}"
    if [ "${lines:-0}" -eq 0 ]; then
        probe_cannot_run "codesign produced NO output -- it did not look, so this is not a pass"
        return
    fi

    # ── ARM 1: is the seal intact right now? ───────────────────────────────
    # BOTH verbs. `added:` alone was blind to v1.0.46's rewrite-in-place.
    local added modified
    added=$(printf '%s\n' "$out" | /usr/bin/grep -c '^file added:' || true)
    modified=$(printf '%s\n' "$out" | /usr/bin/grep -c '^file modified:' || true)
    probe_examined "$(( added + modified ))" "file(s) changed since signing (added=${added} modified=${modified}) -- BOTH verbs, because a rewrite-in-place reports only modified"

    if printf '%s\n' "$out" | /usr/bin/grep -q 'sealed resource is missing or invalid'; then
        probe_fail "THE INSTALLER HAS VOIDED ITS OWN SIGNATURE: ${added} added, ${modified} modified after signing. macOS refuses it as damaged and the customer has no way back."
        return
    fi
    if [ "${added:-0}" -gt 0 ] || [ "${modified:-0}" -gt 0 ]; then
        probe_fail "${added} file(s) added and ${modified} modified inside the signed bundle. The seal is already compromised."
        return
    fi

    # ── ARM 2: the .pyc must be PRESENT and UNREWRITABLE ───────────────────
    # Present, because pre-seeding is the fix. Unrewritable, because that is
    # what stops the interpreter touching them on a customer's machine.
    local census good bad unread pyc
    census=$(box_run "$(_flag_census_cmd "$APP")")
    good=$(_census_get "$census" G);   good=${good:-0}
    bad=$(_census_get "$census" B);    bad=${bad:-0}
    unread=$(_census_get "$census" U); unread=${unread:-0}
    pyc=$(( good + bad + unread ))
    probe_examined "$pyc" "shipped .pyc examined -- unchecked-hash: ${good} · rewritable: ${bad} · unreadable: ${unread}"

    if [ "$pyc" -eq 0 ]; then
        probe_fail "0 .pyc inside the bundle. The stdlib pre-seeding did not run, so the interpreter will compile its own stdlib INTO the signed bundle on first import -- this is the v1.0.45 brick exactly."
        return
    fi

    if [ "${unread:-0}" -gt 0 ]; then
        probe_cannot_run "${unread} .pyc could not be read -- their invalidation mode is unknown, so this is not a pass"
        return
    fi
    if [ "${bad:-0}" -gt 0 ]; then
        probe_fail "${bad} of ${pyc} shipped .pyc are NOT unchecked-hash (PEP 552 flag word != 1). The seal verifies right now, but those WILL be revalidated and rewritten inside the signed bundle on a later run, exactly as v1.0.46 did."
        return
    fi

    # ── ARM 3: ACTIVELY TRIGGER IT ─────────────────────────────────────────
    # Arms 1-2 are observations. This is the experiment: run the bundled
    # interpreter with bytecode writing ENABLED and see whether the bundle
    # moves. Anything less waits for a customer to run the test for us.
    if ! box_run "[ -x '$APP/$PY_REL' ]"; then
        probe_note "no bundled interpreter at ${PY_REL}; arms 1-2 stand, the active trigger was not run"
        probe_pass "seal intact, ${pyc} .pyc all unchecked-hash (trigger arm skipped: no interpreter)"
        return
    fi

    local before after
    before=$(box_run "$(_pyc_digest_cmd "$APP")")
    if [ -z "$before" ]; then
        probe_cannot_run "could not digest the .pyc corpus before the trigger -- nothing to compare against"
        return
    fi

    # POSITIVE CONTROL FIRST. If this interpreter writes no bytecode at all,
    # then "the bundle did not move" means nothing. Prove the trigger is live
    # by making it write somewhere OUTSIDE the bundle, which cannot fail for
    # the same reason the bundle would.
    local ctl
    ctl=$(box_run "T=\$(mktemp -d); printf 'X = 1\n' > \"\$T/ctlmod.py\"; env -i HOME=\"\$HOME\" PATH=/usr/bin:/bin PYTHONPATH=\"\$T\" '$APP/$PY_REL' -c 'import ctlmod' >/dev/null 2>&1; find \"\$T\" -name '*.pyc' | /usr/bin/grep -c . || true; rm -rf \"\$T\"")
    if [ "${ctl:-0}" -eq 0 ]; then
        probe_cannot_run "POSITIVE CONTROL FAILED: the bundled interpreter wrote no .pyc even outside the bundle, so an unchanged bundle proves nothing about the defect"
        return
    fi
    probe_examined "$ctl" ".pyc written OUTSIDE the bundle by the positive control -- proves the trigger is live, so an unchanged bundle means something"

    box_run "env -i HOME=\"\$HOME\" PATH=/usr/bin:/bin '$APP/$PY_REL' -c 'import json, sqlite3, plistlib, subprocess, hashlib, urllib.request, ssl, email, csv, logging, datetime, tempfile, threading, socket, re, zipfile, tarfile, xml.etree.ElementTree, http.client, decimal, statistics, difflib, locale, calendar' >/dev/null 2>&1" || true

    after=$(box_run "$(_pyc_digest_cmd "$APP")")
    local out2 sealed2
    out2=$(box_run "codesign --verify --deep --strict --verbose=2 '$APP' 2>&1")
    sealed2=$(printf '%s\n' "$out2" | /usr/bin/grep -c 'sealed resource is missing or invalid' || true)
    probe_examined "$pyc" ".pyc re-digested after the live trigger -- corpus moved: $([ "$before" = "$after" ] && echo no || echo YES) · seal broken: $([ "${sealed2:-0}" -gt 0 ] && echo YES || echo no)"

    if [ "$before" != "$after" ]; then
        probe_fail "THE BUNDLE MOVED UNDER A BARE IMPORT. The .pyc corpus digest changed from ${before:0:12} to ${after:0:12} after running the bundled interpreter. That is the brick, reproduced on this box."
        return
    fi
    if [ "${sealed2:-0}" -gt 0 ]; then
        probe_fail "codesign reports a broken seal AFTER running the bundled interpreter, even though the .pyc corpus is unchanged. Something else in the bundle is being written."
        return
    fi

    probe_pass "seal survives a live import: ${pyc} .pyc all unchecked-hash, corpus byte-identical (${before:0:12}) and codesign still clean after the interpreter ran"
}

# ---------------------------------------------------------------------------
# self_test -- the negative control. A probe that cannot demonstrate a FAIL has
# not earned a PASS. Runs entirely on locally-built fixtures; touches no box.
# ---------------------------------------------------------------------------
self_test() {
    local fixture rc=0
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT

    # A .pyc header is 16 bytes: 4 magic, 4 flag word, 8 mode-specific.
    _mk_pyc() {  # $1 = path, $2 = flag word (0 timestamp, 1 unchecked-hash)
        mkdir -p "$(dirname "$1")"
        if [ "$2" = "1" ]; then
            printf '\157\015\015\012\001\000\000\000\000\000\000\000\000\000\000\000' > "$1"
        else
            printf '\157\015\015\012\000\000\000\000\000\000\000\000\000\000\000\000' > "$1"
        fi
    }

    # The control runs THE SAME census the measurement runs. An instrument
    # proved on a different surface proves nothing about the real one.
    _census_of() { bash -c "$(_flag_census_cmd "$1")"; }

    # CASE 1: a timestamp-mode .pyc must be caught. This is the v1.0.46 shape:
    # the seal verifies today and breaks on a later run.
    _mk_pyc "$fixture/good.pyc" 1
    _mk_pyc "$fixture/bad.pyc"  0
    local c bad good
    c=$(_census_of "$fixture")
    bad=$(_census_get "$c" B);  bad=${bad:-0}
    good=$(_census_get "$c" G); good=${good:-0}
    if [ "$bad" -ne 1 ] || [ "$good" -ne 1 ]; then
        printf 'VERDICT: BROKEN -- census read [%s]; expected exactly B=1 G=1.\n' "$c"
        printf '  The predicate that must catch the brick cannot read a .pyc header.\n'
        exit "$PROBE_EX_FAIL"
    fi

    # CASE 2: the all-good tree must NOT be flagged, or the probe is simply
    # broken-to-red and its FAILs carry no information.
    rm -f "$fixture/bad.pyc"
    c=$(_census_of "$fixture")
    bad=$(_census_get "$c" B);  bad=${bad:-0}
    good=$(_census_get "$c" G); good=${good:-0}
    if [ "$bad" -ne 0 ] || [ "$good" -ne 1 ]; then
        printf 'VERDICT: BROKEN -- census read [%s] on an all-unchecked-hash tree; expected B=0 G=1.\n' "$c"
        exit "$PROBE_EX_FAIL"
    fi

    # CASE 3: a REWRITE-IN-PLACE must be visible. Same file count, different
    # bytes -- the exact shape that defeated every count-based check.
    local d1 d2
    _digest() { find "$1" -name '*.pyc' -type f -print0 | sort -z \
                | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}'; }
    d1=$(_digest "$fixture")
    printf '\157\015\015\012\001\000\000\000\377\377\377\377\000\000\000\000' > "$fixture/good.pyc"
    d2=$(_digest "$fixture")
    if [ "$d1" = "$d2" ]; then
        printf 'VERDICT: BROKEN -- corpus digest did not change after a rewrite-in-place.\n'
        printf '  This is precisely the defect that count-based checks miss; the digest must see it.\n'
        exit "$PROBE_EX_FAIL"
    fi

    # A SELF-TEST SIGNALS SUCCESS BY GOING RED. It does not exit 0.
    #
    # This used to be `printf 'VERDICT: SELF-TEST PASS...'; exit "${PROBE_EX_OK:-0}"`
    # and it made this probe BROKEN in every walk since it was written.
    #
    # run_box_walk.sh phase 1 drives every probe with --self-test on KNOWN-BAD
    # input and requires rc=1: "each probe must be able to FAIL". A probe that
    # exits 0 there has not demonstrated it can go red, so the runner marks it
    # BROKEN and PHASE 2 SKIPS IT ENTIRELY. This probe guards the installer
    # breaking its own signature during install (#422) -- and it has been
    # guarding nothing.
    #
    # MEASURED 2026-08-26 across all 17 registered probes:
    #     15 exit 1 and print VERDICT: FAIL   <- the contract
    #      2 exit 0 and print SELF-TEST PASS  <- this one and
    #                                            pairing_recovers_without_a_repair_storm
    # A private convention held by 2 of 17 is not a convention, it is a bug.
    #
    #
    # POLARITY, stated once: run_box_walk.sh PHASE 1 drives every probe with
    # --self-test on KNOWN-BAD input and requires rc=1 -- "each probe must be
    # able to FAIL". Anything else is reported BROKEN. The failure branches above
    # print the literal "VERDICT: BROKEN", which phase 1 greps for BEFORE it reads
    # any exit code, precisely so a probe cannot vouch for itself with an exit
    # status.
    #
    # SECOND DEFECT, found independently by Archie2 in #1121 and folded in here:
    # this also read ${PROBE_EX_OK:-0}, and PROBE_EX_OK is defined NOWHERE in
    # lib/probe.sh -- the lib defines PROBE_EX_PASS. The `:-` default silently
    # supplied 0, so the wrong NAME never surfaced as an error. Two bugs wearing
    # one line.
    # probe_examined is REQUIRED before any verdict: the contract refuses a
    # verdict with no denominator, printing "VERDICT: BROKEN -- reported a
    # verdict without calling probe_examined", which phase 1 also catches. The
    # working probes (e.g. daemon_is_listening) do exactly this pair.
    probe_examined 3 "synthetic bundles (negative control): timestamp-mode, unchecked-hash, rewrite-in-place"
    probe_fail "negative control behaved correctly on all 3 synthetic bundles -- caught timestamp-mode, cleared unchecked-hash, saw a rewrite-in-place"
}

probe_main "$@"
