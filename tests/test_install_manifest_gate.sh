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
#   F  IMPORT     against the real repo, the shared-guard importer passes and the
#      two uncovered write paths are NAMED (#617), so the type is not uniformly
#      failing (a positive control proves the enumerator detects presence).
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
REQ_AGENTS="com.ostler.stay-awake com.ostler.engine-supervisor com.ostler.ollama com.ostler.ollama-logrotate com.ostler.enrich com.ostler.export-scan com.ostler.doctor com.ostler.ical-server com.ostler.fda-rerun com.creativemachines.ostler.assistant com.creativemachines.ostler.email-ingest com.creativemachines.ostler.wiki-recompile com.creativemachines.ostler.editor-frontpage"
for L in $REQ_AGENTS; do
    printf '<plist><dict><key>Label</key><string>%s</string></dict></plist>\n' "$L" > "$H/Library/LaunchAgents/$L.plist"
done
CFG="$H/.ostler/assistant-config/config.toml"
printf '[[cron.jobs]]\nid = "morning-brief"\n[[cron.jobs]]\nid = "evening-wrap"\n' > "$CFG"

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

# ── F. IMPORT_WIRE against the real repo: control passes, negatives named. ──
out="$(python3 "$VERIFIER" --manifest "$MANIFEST" --home "$H" --source-root "$REPO" --only-type import_wire 2>&1)"; rc=$?
if grep -q 'identifier_quality' <<< "$out"; then
    bad "the import_wire positive control (identifier_quality) was reported MISSING -- the enumerator cannot detect a real shared-guard wiring, so every negative below is meaningless."
else
    pass "the import_wire positive control (identifier_quality) is PRESENT -- the enumerator detects a real wiring"
fi
if [ "$rc" -ne 0 ] && grep -q 'contact_syncer' <<< "$out" && grep -q 'identity_resolver' <<< "$out"; then
    pass "the two uncovered write paths are NAMED (contact_syncer, identity_resolver; #617)"
else
    bad "the uncovered write paths were not both named (rc=$rc): $(printf '%s' "$out" | grep -iE 'contact_syncer|identity_resolver' | head -2)"
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
