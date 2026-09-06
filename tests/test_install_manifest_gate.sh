#!/usr/bin/env bash
# ============================================================================
# THE INSTALL-COMPLETENESS CLASS GATE (A2). Drives the REAL verifier
# (scripts/verify_install_manifest.py), the REAL manifest
# (scripts/install_manifest.tsv) and the REAL box-walk probe against synthetic
# installs, and asserts it NAMES every difference in both directions.
#
# WHY THIS GATE EXISTS. For a month the same shape shipped: a thing a finished
# install must contain was silently absent and nothing counted it -- an empty
# [[cron.jobs]] block (#619), a usage-journal dir never created (#482), a kinship
# guard with no importer on a write path (#617). Each found by a human, never a
# gate. The class gate compares a HAND-DECLARED manifest (not derived from
# install.sh) to what is present, both directions, every difference NAMED.
#
# WHAT THIS TEST ASSERTS
#   A  COMPLETE   a synthetic install with every box-observable required subject
#      present -> PASS (the positive control: a gate that reds a healthy install
#      is worse than the defect).
#   B  MISSING    remove one required LaunchAgent -> FAIL, and the missing one is
#      NAMED (a count would not distinguish WHICH).
#   C  UNDECLARED add a LaunchAgent in no manifest row -> FAIL, NAMED (the
#      produced-but-not-declared direction, the one that catches a new surprise).
#   D  CRON       drop a required cron job -> FAIL, NAMED (this is #619's shape).
#   E  DIR        remove a required artefact_dir -> FAIL, NAMED (#482's family).
#   F  IMPORT     against the real repo, the shared-guard importer passes (the
#      positive control, proving the enumerator detects presence) and the set of
#      uncovered write paths is compared against a DECLARED, DATED expectation.
#      A NEW uncovered path fails. Closing one does NOT: it passes and names the
#      declaration line to delete. This arm used to assert the #617 gap was
#      still there, so repairing it turned the job red (CM051 #1688).
#   F2 the comparison function itself, driven with synthetic sets across all
#      four states, because every verdict in F comes out of it.
#   G  PRIVATE-COPY  a same-named PRIVATE helper `_is_relationship_label` must NOT
#      be read as the shared guard (pwg_ingest carries its own, deliberately).
#      Driven through the real verifier with a temp manifest + temp source.
#   H  PROBE SELF-TEST  the box-walk probe's own negative control returns FAIL
#      (the runner marks a probe BROKEN unless its --self-test fails), so the
#      control that must fail is wired where the walk enforces it.
#
# Extract-real throughout: nothing here reimplements the verifier, so nothing can
# pass against a copy of it.
#
# Exit: 0 all hold | 1 a rule is broken | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
VERIFIER="$REPO/scripts/verify_install_manifest.py"
MANIFEST="$REPO/scripts/install_manifest.tsv"
PROBE="$REPO/scripts/box_walk_probes/probes/install_manifest_complete.sh"

pass=0; fail=0
pass()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
note()   { printf '        %s\n' "$1"; }
cannot() { printf 'CANNOT RUN: %s\n' "$1" >&2; exit 2; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

command -v python3 >/dev/null 2>&1 || cannot "python3 not on PATH"
[ -r "$VERIFIER" ] || cannot "verifier not readable at $VERIFIER"
[ -r "$MANIFEST" ] || cannot "manifest not readable at $MANIFEST"
[ -r "$PROBE" ]    || cannot "probe not readable at $PROBE"

echo "== install-completeness class gate =="

WORK=""
cleanup() { [ -n "${WORK}" ] && rm -rf "${WORK}"; return 0; }
trap cleanup EXIT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-manifestgate-XXXXXX")" || cannot "could not create a work dir"

# ── PREMISE: the manifest parses and declares rows. ────────────────────
# A malformed or empty manifest is CANNOT-RUN, not a pass -- an empty manifest
# passes everything.
if ! python3 "$VERIFIER" --manifest "$MANIFEST" --home "$WORK" --only-type launch_agent >/dev/null 2>&1; then
    : # a non-zero here is expected (WORK has no LaunchAgents dir -> CANNOT-RUN/FAIL); we only need parse-ability
fi
_parsecheck="$(python3 "$VERIFIER" --manifest "$MANIFEST" --home "$WORK" --only-type import_wire 2>&1 || true)"
if grep -qiE 'manifest line|not one of|declares zero' <<< "$_parsecheck"; then
    cannot "manifest does not parse cleanly: $(printf '%s' "$_parsecheck" | grep -i manifest | head -1)"
fi
note "manifest parses; verifier loads it"

# Build a COMPLETE synthetic install (box-observable types).
H="$WORK/home"
mkdir -p "$H/Library/LaunchAgents" "$H/.ostler/assistant-config" "$H/Documents/Ostler/Wiki" "$H/.ostler/assistant-config/workspace/state"
# The 13 UNCONDITIONAL (required) launch agents. A complete install has all of
# them; declaring only these keeps the synthetic install free of UNDECLARED noise.
REQ_AGENTS="com.ostler.stay-awake com.ostler.engine-supervisor com.ostler.ollama com.ostler.ollama-logrotate com.ostler.export-scan com.ostler.doctor com.ostler.ical-server com.ostler.fda-rerun com.creativemachines.ostler.assistant com.creativemachines.ostler.email-ingest com.creativemachines.ostler.wiki-recompile com.creativemachines.ostler.editor-frontpage com.creativemachines.ostler.context-refresh"
for L in $REQ_AGENTS; do
    printf '<plist><dict><key>Label</key><string>%s</string></dict></plist>\n' "$L" > "$H/Library/LaunchAgents/$L.plist"
done
CFG="$H/.ostler/assistant-config/config.toml"
printf '[[cron.jobs]]\nid = "morning-brief"\n[[cron.jobs]]\nid = "evening-wrap"\n' > "$CFG"
# The complete qdrant present-set via the test seam, so the box-type runs below
# (which include qdrant_collection) see a healthy store instead of CANNOT-RUN.
# The qdrant-specific arm overrides this per-call to inject missing/undeclared.
export OSTLER_MANIFEST_QDRANT_OVERRIDE="people,conversations,preferences,evernote_knowledge,safari_history"

_run() { python3 "$VERIFIER" --manifest "$MANIFEST" --home "$H" --config "$CFG" "$@" 2>&1; }

# ── A. COMPLETE (box types) -> PASS. ───────────────────────────────────
out="$(_run --exclude-type import_wire)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^PASS' <<< "$out"; then
    pass "a complete install passes the box-observable gate"
else
    bad "REGRESSION: a complete install did not PASS (rc=$rc). This gate would red a healthy install. Got: $(printf '%s' "$out" | grep -E 'FAIL|    -' | head -2)"
fi

# ── B. MISSING required LaunchAgent -> FAIL + NAMED. ──────────────────
# Remove com.ostler.doctor: it is a REQUIRED row (colima is only conditional).
rm -f "$H/Library/LaunchAgents/com.ostler.doctor.plist"
out="$(_run --only-type launch_agent)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'com.ostler.doctor' <<< "$out"; then
    pass "a missing required LaunchAgent is NAMED (com.ostler.doctor)"
else
    bad "a missing required LaunchAgent was not caught+named (rc=$rc): $(printf '%s' "$out" | grep -i doctor || printf '(not named)')"
fi
printf '<plist><dict><key>Label</key><string>com.ostler.doctor</string></dict></plist>\n' > "$H/Library/LaunchAgents/com.ostler.doctor.plist"

# ── C. UNDECLARED LaunchAgent -> FAIL + NAMED. ────────────────────────
printf '<plist><dict><key>Label</key><string>com.ostler.mystery</string></dict></plist>\n' > "$H/Library/LaunchAgents/com.ostler.mystery.plist"
out="$(_run --only-type launch_agent)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'com.ostler.mystery' <<< "$out"; then
    pass "an UNDECLARED LaunchAgent is NAMED (produced-but-not-declared direction lives)"
else
    bad "an undeclared LaunchAgent was not caught+named (rc=$rc): $(printf '%s' "$out" | grep -i mystery || printf '(not named)')"
fi
rm -f "$H/Library/LaunchAgents/com.ostler.mystery.plist"

# ── C-bis. A CONDITIONAL agent that IS present must NOT read as UNDECLARED. ──
# This is the other half of C, and it is the half #1506 turned on. com.ostler.enrich
# is `conditional`: absent is not a failure, but PRESENT must still count as declared.
# Without this arm, `conditional` could silently behave like `excluded` -- or worse,
# like a row nobody reads -- and the fixture would never notice.
#
# It gets its own arm rather than a seat in REQ_AGENTS. It was in that list, and that
# list is labelled "the 13 UNCONDITIONAL (required) launch agents", so it contradicted
# its own header AND modelled an install no customer has: install.sh's own comment for
# this agent is "No customer Mac has ever run this agent." A fixture that runs it is
# not modelling a real install. Found by TNM reviewing #1506.
printf '<plist><dict><key>Label</key><string>com.ostler.enrich</string></dict></plist>\n' > "$H/Library/LaunchAgents/com.ostler.enrich.plist"
out="$(_run --only-type launch_agent)"; rc=$?
if grep -q 'com.ostler.enrich' <<< "$out"; then
    bad "a PRESENT conditional agent was reported (rc=$rc): $(printf '%s' "$out" | grep -i enrich | head -1)"
else
    pass "a conditional agent that IS present is neither MISSING nor UNDECLARED"
fi
rm -f "$H/Library/LaunchAgents/com.ostler.enrich.plist"

# ── D. MISSING cron job -> FAIL + NAMED (the #619 shape). ─────────────
printf '[[cron.jobs]]\nid = "morning-brief"\n' > "$CFG"
out="$(_run --only-type cron_job)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'evening-wrap' <<< "$out"; then
    pass "a missing required cron job is NAMED (evening-wrap; this is #619's shape)"
else
    bad "a missing cron job was not caught+named (rc=$rc): $(printf '%s' "$out" | grep -i evening || printf '(not named)')"
fi
printf '[[cron.jobs]]\nid = "morning-brief"\n[[cron.jobs]]\nid = "evening-wrap"\n' > "$CFG"

# ── E. MISSING artefact_dir -> FAIL + NAMED (#482 family). ────────────
rm -rf "$H/Documents/Ostler/Wiki"
out="$(_run --only-type artefact_dir)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'Wiki' <<< "$out"; then
    pass "a missing required artefact_dir is NAMED (~/Documents/Ostler/Wiki)"
else
    bad "a missing artefact_dir was not caught+named (rc=$rc): $(printf '%s' "$out" | grep -i wiki || printf '(not named)')"
fi
mkdir -p "$H/Documents/Ostler/Wiki"

# ── E2. QDRANT_COLLECTION: missing named, undeclared named, down = CANNOT-RUN. ──
# The env assignment sits on the python3 SIMPLE command (reliably exported),
# not on a function call (where bash export semantics are subtle).
_run_q() { OSTLER_MANIFEST_QDRANT_OVERRIDE="$1" python3 "$VERIFIER" --manifest "$MANIFEST" --home "$H" --config "$CFG" --only-type qdrant_collection 2>&1; }
out="$(_run_q "people,preferences")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'conversations' <<< "$out" && grep -q 'evernote_knowledge' <<< "$out"; then
    pass "missing required qdrant collections are NAMED (conversations, evernote_knowledge; the .98/#615 shape)"
else
    bad "missing qdrant collections not caught+named (rc=$rc): $(printf '%s' "$out" | grep -iE 'conversations|evernote' | head -2)"
fi
out="$(_run_q "people,conversations,preferences,evernote_knowledge,mystery_coll")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'mystery_coll' <<< "$out"; then
    pass "an undeclared qdrant collection is NAMED (mystery_coll; how safari_history first surfaced)"
else
    bad "undeclared qdrant collection not named (rc=$rc): $(printf '%s' "$out" | grep -i mystery || printf '(not named)')"
fi
# A store that is DOWN is CANNOT-RUN (exit 2), NOT 'no collections' -- the exact
# false zero that read the v1.0.60 index as empty when it was 401 (up, unauth).
out="$(_run_q "__unreachable__")"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'cannot-run' <<< "$out"; then
    pass "a DOWN qdrant is CANNOT-RUN (exit 2), not read as empty (the false-zero guard)"
else
    bad "a down qdrant was not CANNOT-RUN (rc=$rc); a false zero would ship silently. Got: $(printf '%s' "$out" | head -1)"
fi

# ── F. IMPORT_WIRE against the real repo: the gap is DECLARED, not inferred. ─
#
# WHY THIS ARM WAS REWRITTEN (CM051 #1688, 2026-09-06).
#
# It used to read:
#
#     if [ "$rc" -ne 0 ] && grep -q 'contact_syncer' && grep -q 'identity_resolver'
#     then pass "the two uncovered write paths are NAMED" else bad ... fi
#
# which passes BECAUSE the defect is still there, and goes red the moment
# somebody fixes it. Measured, not inferred: the real verifier with the real
# manifest against a synthetic source tree where #617 IS wired at both declared
# paths (positive control copied in, so the run cannot be green by emptiness)
# returns rc=0 and "PASS: every required subject is present", and the old
# condition then took its bad() branch and printed "the uncovered write paths
# were not both named" -- which describes the opposite of what happened.
#
# A gate that fails on repair does not get fixed; it gets worked around, and the
# next person reads the red as noise. So this arm now compares the verifier's
# verdict against a DECLARED expectation and treats the four states differently:
#
#   missing == declared      the known gap, unchanged            -> pass
#   missing has an extra     a NEW uncovered write path          -> BAD
#   declared has an extra    somebody FIXED one                  -> pass + note
#   missing empty            #617 is wired                       -> pass + note
#
# Only a NEW gap is a failure. Closing a gap is never punished; it is reported,
# with the exact line to delete. Rot is caught by the expiry date instead, the
# same discipline vendor/VENDOR_MANIFEST.toml already uses for unverifiable_ack:
# a declaration is a debt with a name and a date on it, not a permanent excuse.
#
# The locator (the `path-glob|symbol` the manifest declares) is the key, not the
# prose description. Two rows can share words; no two rows share a locator.

# The gap, declared. One locator per line. DELETE A LINE WHEN IT IS FIXED --
# this arm will tell you which, by name, and will not go red while you do it.
F_DECLARED_UNWIRED='vendor/cm041/contact_syncer/*.py|is_relationship_label
vendor/cm041/identity_resolver/*.py|is_relationship_label'
F_DECLARED_TICKET='#617'
F_DECLARED_EXPIRES='2026-09-30'
F_DECLARED_OWNER='archie'

# THE COMPARISON, as a function, so the self-test below drives the SAME code the
# live arm does. Echoes one word: matches | new | closed | wired.
# $1 = newline-separated missing locators, $2 = newline-separated declared.
f_classify() {
    _fm="$(printf '%s\n' "$1" | sed '/^$/d' | LC_ALL=C sort)"
    _fd="$(printf '%s\n' "$2" | sed '/^$/d' | LC_ALL=C sort)"
    if [ -z "$_fm" ]; then echo "wired"; return; fi
    # anything missing that was not declared is a NEW gap, and outranks the rest
    if [ -n "$(comm -23 <(printf '%s\n' "$_fm") <(printf '%s\n' "$_fd"))" ]; then
        echo "new"; return
    fi
    if [ -n "$(comm -13 <(printf '%s\n' "$_fm") <(printf '%s\n' "$_fd"))" ]; then
        echo "closed"; return
    fi
    echo "matches"
}

out="$(python3 "$VERIFIER" --manifest "$MANIFEST" --home "$H" --source-root "$REPO" --only-type import_wire 2>&1)"; rc=$?

# The positive control comes first and is unchanged in intent: if the enumerator
# cannot see a real wiring, every verdict below is meaningless.
if grep -q 'identifier_quality' <<< "$out"; then
    bad "the import_wire positive control (identifier_quality) was reported MISSING -- the enumerator cannot detect a real shared-guard wiring, so every verdict below is meaningless."
else
    pass "the import_wire positive control (identifier_quality) is PRESENT -- the enumerator detects a real wiring"
fi

# The verifier must have actually run. rc=2 is CANNOT-RUN and is not a pass, and
# an rc of 0 or 1 with no recognisable output is not a measurement either.
if [ "$rc" -eq 2 ]; then
    bad "import_wire was CANNOT-RUN (rc=2), which is not a pass: $(printf '%s' "$out" | head -1)"
elif ! grep -qE '^(PASS|FAIL)' <<< "$out"; then
    bad "the verifier produced no PASS/FAIL verdict for import_wire (rc=$rc): $(printf '%s' "$out" | head -1)"
else
    f_missing="$(printf '%s\n' "$out" | sed -n 's/.*\[\(.*\)\]$/\1/p')"
    case "$(f_classify "$f_missing" "$F_DECLARED_UNWIRED")" in
      matches)
        pass "import_wire: the gap is exactly the DECLARED one ($F_DECLARED_TICKET, owner $F_DECLARED_OWNER, expires $F_DECLARED_EXPIRES)"
        printf '%s\n' "$f_missing" | sed 's/^/        still unwired: /'
        ;;
      new)
        bad "import_wire: a write path is uncovered that nobody declared. Wire the guard, or add the locator to F_DECLARED_UNWIRED with a reason:"
        comm -23 <(printf '%s\n' "$f_missing" | LC_ALL=C sort) <(printf '%s\n' "$F_DECLARED_UNWIRED" | LC_ALL=C sort) | sed 's/^/        NEW: /'
        ;;
      closed)
        pass "import_wire: part of the declared $F_DECLARED_TICKET gap is now WIRED. Nothing is broken; delete the line(s) below from F_DECLARED_UNWIRED."
        comm -13 <(printf '%s\n' "$f_missing" | LC_ALL=C sort) <(printf '%s\n' "$F_DECLARED_UNWIRED" | LC_ALL=C sort) | sed 's/^/        now wired, remove: /'
        ;;
      wired)
        pass "import_wire: every declared write path is WIRED. $F_DECLARED_TICKET is closed here."
        note "delete F_DECLARED_UNWIRED and this arm's gap branches -- the declaration has no subject left."
        ;;
    esac
fi

# The declaration is a dated debt. Past its date it is rot, and rot is a failure
# even though the gap it describes has not changed.
_f_today="$(date -u '+%Y-%m-%d')"
if [ "$_f_today" \> "$F_DECLARED_EXPIRES" ]; then
    bad "the import_wire gap declaration expired on $F_DECLARED_EXPIRES (today $_f_today, owner $F_DECLARED_OWNER). Wire it, or re-date it with a reason."
else
    pass "the import_wire gap declaration is in date (expires $F_DECLARED_EXPIRES, owner $F_DECLARED_OWNER)"
fi

# ── F2. THE ARM'S OWN CONTROL. ──────────────────────────────────────────────
# f_classify decides everything above, so drive it directly with synthetic sets.
# Without this, every verdict above could be produced by a function that returns
# one constant. The "closed" and "wired" cases are the ones the old arm got
# wrong, so they are the ones that most need a control.
_f_a='a|s'
_f_b='b|s'
_f_ctl=0
[ "$(f_classify "$_f_a
$_f_b" "$_f_a
$_f_b")" = "matches" ] || { _f_ctl=1; note "f_classify: identical sets did not read as 'matches'"; }
[ "$(f_classify "$_f_a
$_f_b" "$_f_a")"        = "new" ]     || { _f_ctl=1; note "f_classify: an undeclared missing locator did not read as 'new'"; }
[ "$(f_classify "$_f_a" "$_f_a
$_f_b")"                = "closed" ]  || { _f_ctl=1; note "f_classify: a declared-but-no-longer-missing locator did not read as 'closed'"; }
[ "$(f_classify "" "$_f_a")"          = "wired" ]   || { _f_ctl=1; note "f_classify: an empty missing set did not read as 'wired'"; }
[ "$(f_classify "" "")"               = "wired" ]   || { _f_ctl=1; note "f_classify: empty/empty did not read as 'wired'"; }
# A NEW gap must outrank a simultaneous fix, or fixing one path could hide
# another appearing in the same change.
[ "$(f_classify "$_f_b" "$_f_a")"     = "new" ]     || { _f_ctl=1; note "f_classify: a new gap alongside a closed one did not read as 'new'"; }
if [ "$_f_ctl" -eq 0 ]; then
    pass "f_classify discriminates all four states, and a NEW gap outranks a simultaneous fix"
else
    bad "f_classify does not discriminate -- section F's verdicts above are measuring nothing"
fi


# ── G. PRIVATE-COPY: `_is_relationship_label` is NOT the shared guard. ─
# A synthetic source tree + temp manifest, through the real verifier.
SRC="$WORK/src"; mkdir -p "$SRC/priv" "$SRC/shared"
printf 'def _is_relationship_label(x):\n    return False\n' > "$SRC/priv/own.py"          # private copy only
printf 'from x import is_relationship_label\nis_relationship_label("a")\n' > "$SRC/shared/uses.py"  # shared guard
TM="$WORK/tmp_manifest.tsv"
{
  printf 'import_wire\tprivate copy must NOT count\trequired\tpriv/*.py|is_relationship_label\t#617-disc\tleading underscore is a different symbol\n'
  printf 'import_wire\tshared guard counts\trequired\tshared/*.py|is_relationship_label\t#617-disc\tthe real wiring\n'
} > "$TM"
out="$(python3 "$VERIFIER" --manifest "$TM" --home "$H" --source-root "$SRC" --only-type import_wire 2>&1)"; rc=$?
if grep -q 'private copy must NOT count' <<< "$out" && ! grep -q 'shared guard counts' <<< "$out"; then
    pass "private-copy discrimination: _is_relationship_label is NOT read as the shared guard, is_relationship_label IS"
else
    bad "private-copy discrimination failed. The private copy should be MISSING and the shared use PRESENT. Got: $(printf '%s' "$out" | grep -E '    -' | head -3)"
fi

# ── H. The box-walk probe's own negative control fails (runner enforces). ─
"$PROBE" --self-test >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then
    pass "the box-walk probe --self-test returns FAIL, so the runner's phase-1 accepts it (control that must fail is wired)"
else
    bad "the box-walk probe --self-test returned $rc, not 1. The runner would mark it BROKEN (rc 0) or mis-handle it."
fi

# ── ANTI-VACUITY: a verifier that ignored the manifest would pass B..E. ─
# Prove the harness can see the defect: the COMPLETE install passed (A) and each
# single removal flipped it to a NAMED failure (B..E). If the gate ignored the
# manifest, A and B..E would score identically. They did not, above.
note "anti-vacuity: A passed while B..E each failed on one removal, so the gate is reading the manifest, not rubber-stamping"

finish
