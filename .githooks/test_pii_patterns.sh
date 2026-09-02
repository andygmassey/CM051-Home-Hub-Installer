#!/usr/bin/env bash
# Unit tests for .githooks/pii_patterns.sh -- the customer-configurable
# regex PII layer added for backlog #188.
#
# Pure bash, no bats / external test runner required. Run with:
#   ./.githooks/test_pii_patterns.sh
#
# RULE ZERO: every datum below is SYNTHETIC. Phone numbers use the OFCOM
# drama range (+44 7700 900xxx) reserved for fiction; SSNs / DSIDs are
# made-up digit runs; names are obviously-fake test strings. No real PII.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/pii_patterns.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

assert_contains() {
    # $1 haystack, $2 needle, $3 label
    case "$1" in
        *"$2"*) ok "$3" ;;
        *)      bad "$3 (expected to contain: $2)" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) bad "$3 (did NOT expect: $2)" ;;
        *)      ok "$3" ;;
    esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== pii_patterns.sh unit tests =="

# ──────────────────────────────────────────────────────────────────────────
# 1. Regex validator
# ──────────────────────────────────────────────────────────────────────────
echo "-- regex validator --"
if pii_regex_is_valid '[0-9]{3}-[0-9]{2}-[0-9]{4}'; then
    ok "valid ERE accepted"
else
    bad "valid ERE accepted"
fi

if pii_regex_is_valid 'a[b'; then
    bad "malformed regex rejected (unterminated class)"
else
    ok "malformed regex rejected (unterminated class)"
fi

if pii_regex_is_valid ''; then
    bad "empty regex rejected"
else
    ok "empty regex rejected"
fi

# ──────────────────────────────────────────────────────────────────────────
# 2. Built-in defaults are present even with NO customer file
# ──────────────────────────────────────────────────────────────────────────
echo "-- built-in defaults load --"
DEFAULTS="$(pii_load_patterns "$WORK/does-not-exist")"
if [ -n "$DEFAULTS" ]; then
    ok "built-in defaults load without a customer file"
else
    bad "built-in defaults load without a customer file"
fi

# ──────────────────────────────────────────────────────────────────────────
# 3. A built-in default fires on synthetic data
#    (US SSN format -- synthetic, fake digits)
# ──────────────────────────────────────────────────────────────────────────
echo "-- built-in default fires --"
SSN_FILE="$WORK/ssn.txt"
# Composed at runtime, never a literal: this file is scanned by the hook it
# tests, and an SSN-shaped literal here is blocked by it. The literal had been
# in this file since before the hook covered it, so it only surfaced the next
# time somebody touched the file. A gate's test must not carry the thing the
# gate hunts.
_ssn_a="123"; _ssn_b="45"; _ssn_c="6789"
printf 'customer ref %s-%s-%s on file\n' "$_ssn_a" "$_ssn_b" "$_ssn_c" > "$SSN_FILE"
OUT="$(pii_scan_files "$SSN_FILE" "$WORK/no-custom")"
assert_contains "$OUT" "$SSN_FILE" "built-in SSN pattern fires on synthetic SSN"

# ── UK phone: BOTH limbs of the reserved-placeholder contract ────────────
# This limb used to write an OFCOM drama-range number and assert it FIRED.
# That was true until pii_reserved_placeholder_re was added, whose entire
# purpose is to EXCUSE the drama range: the hook's own error message tells
# you to use 07700 900xxx, so a guard that then blocked it taught people to
# reach for --no-verify. The test kept asserting the pre-change behaviour and
# had been a permanent RED ever since, in the test suite of a shared security
# library. A predicate pinned to behaviour that was deliberately changed is
# red-while-fixed, and a permanent red trains people to ignore red.
#
# Asserting the real contract instead, which is stronger than the original
# because it pins BOTH directions rather than one.
#
# The non-reserved number is composed at runtime, never written as a literal:
# this file is scanned by the very hook it tests, and a real-shaped phone
# literal here would be blocked by it. A gate's test must not carry the thing
# the gate hunts.
#
# THE SUBSCRIBER BLOCK IS ALL ZEROS, AND THAT IS A DELIBERATE UPGRADE.
# An earlier version of this canary used an ALLOCATED UK mobile prefix. It
# satisfied the stated rule -- a positive control must be a value the scanner
# must FIND, never one it must FORGIVE -- but it was still a plausible real
# subscriber's number shape, which is a poor thing for a PII guard's own test
# to manufacture even transiently. An all-zero subscriber block is
# STRUCTURALLY NON-ASSIGNABLE: no person can hold it, and it still matches the
# built-in and is still outside every reserved range, so it is found.
#
# Credit where due: this choice is from #387, adopted here after comparing the
# two rather than assuming they were equivalent. They were not.
#
#   non-reserved  is what makes a canary WORK
#   non-assignable is what makes it SAFE
#   the reserved fiction ranges are neither, for a shape-based guard
#
# BOTH FORMS ARE EXERCISED. The library carries the international (+44 7xxx)
# and the national (07xxx) mobile shapes as SEPARATE built-ins. A canary that
# only ever wrote one form would leave the other with no positive control at
# all, and its silence would be indistinguishable from it working.
_blk="7000"; _sub="000000"

PHONE_FILE="$WORK/phone.txt"
printf 'call +44 %s %s tomorrow\n' "$_blk" "$_sub" > "$PHONE_FILE"
OUT="$(pii_scan_files "$PHONE_FILE" "$WORK/no-custom")"
assert_contains "$OUT" "$PHONE_FILE" "UK phone INTERNATIONAL form FIRES on a non-assignable number"

PHONE_NAT_FILE="$WORK/phone_national.txt"
printf 'call 0%s %s tomorrow\n' "$_blk" "$_sub" > "$PHONE_NAT_FILE"
OUT="$(pii_scan_files "$PHONE_NAT_FILE" "$WORK/no-custom")"
assert_contains "$OUT" "$PHONE_NAT_FILE" "UK phone NATIONAL form FIRES on a non-assignable number"

# The excused half. Same pattern, same shape, reserved range -> no report.
DRAMA_FILE="$WORK/phone_drama.txt"
printf 'call +44 %s %s tomorrow\n' "7700" "900123" > "$DRAMA_FILE"
OUT="$(pii_scan_files "$DRAMA_FILE" "$WORK/no-custom")"
assert_not_contains "$OUT" "$DRAMA_FILE" "OFCOM drama range is EXCUSED, not reported"

# A clean file should NOT match any built-in.
CLEAN_FILE="$WORK/clean.txt"
printf 'the quick brown fox jumps over the lazy dog\n' > "$CLEAN_FILE"
OUT="$(pii_scan_files "$CLEAN_FILE" "$WORK/no-custom")"
assert_not_contains "$OUT" "$CLEAN_FILE" "clean file does not match built-ins"

# ── Email: BOTH limbs of the reserved-placeholder contract ───────────────
# The email built-in and the /Users/<name> built-in landed in #762, and were
# for weeks the two classes with a denominator of ZERO in CI (see the header of
# .github/scripts/ci-pii-shape-scan.sh). They now carry the same two-limb
# positive control the phone class does: a non-reserved value that MUST fire and
# a reserved/documentation value that MUST be excused. Without the FIRE limb a
# pattern that silently stopped compiling in some grep/locale would look exactly
# like a clean tree, which is the whole failure the floor and these canaries
# exist to make impossible.
#
# Composed at runtime, never a literal: this file is scanned by the very hook it
# tests, and by ci-pii-shape-scan over its own ADDED lines in CI, so a
# real-shaped address written here would be blocked by it. someone.else at
# consumer-mail.co is the same synthetic non-reserved mailbox
# bin/pii_name_guard.py uses as its shape positive control -- one convention,
# not two.
_eu="someone.else"; _ed="consumer-mail.co"
EMAIL_FILE="$WORK/email.txt"
printf 'owner = "%s@%s"\n' "$_eu" "$_ed" > "$EMAIL_FILE"
OUT="$(pii_scan_files "$EMAIL_FILE" "$WORK/no-custom")"
assert_contains "$OUT" "$EMAIL_FILE" "built-in EMAIL pattern FIRES on a synthetic non-reserved mailbox"

# The excused half. An RFC 2606 documentation domain is what a CORRECT fixture
# uses, so it must be let through or the class is unusable -- measured ~63% false
# positive on this repo's real tree when it was not. @example.com is reserved.
EMAIL_DOC_FILE="$WORK/email_doc.txt"
printf 'owner = "fixture@example.com"\n' > "$EMAIL_DOC_FILE"
OUT="$(pii_scan_files "$EMAIL_DOC_FILE" "$WORK/no-custom")"
assert_not_contains "$OUT" "$EMAIL_DOC_FILE" "RFC 2606 example.com address is EXCUSED, not reported"

# ── macOS home path carrying a username: BOTH limbs ──────────────────────
# The name segment is composed at runtime for the same reason: a literal
# /Users/<realish-name>/ in this file is precisely what the guard hunts, and CI
# scans this file's added lines in diff mode.
_uh="/Users/"; _un="canaryoperator"
HOME_FILE="$WORK/homepath.txt"
printf 'config at %s%s/Library/Application Support/Ostler\n' "$_uh" "$_un" > "$HOME_FILE"
OUT="$(pii_scan_files "$HOME_FILE" "$WORK/no-custom")"
assert_contains "$OUT" "$HOME_FILE" "built-in HOME-PATH pattern FIRES on a non-placeholder /Users/<name>"

# The excused half. A placeholder home dir (from pii_placeholder_home_names) is
# documentation, not a person, so /Users/you must be let through.
HOME_PH_FILE="$WORK/homepath_placeholder.txt"
printf 'edit %s\n' "/Users/you/config.toml" > "$HOME_PH_FILE"
OUT="$(pii_scan_files "$HOME_PH_FILE" "$WORK/no-custom")"
assert_not_contains "$OUT" "$HOME_PH_FILE" "placeholder home dir /Users/you is EXCUSED, not reported"

# ── Hong Kong mobile: the operator denylist checks it, CI had a zero ──────
# HK mobile (+852) is a class the operator denylist (operator-pii-scan.sh
# build_hk_pattern) has always checked and the CI shape scan never did, so it
# had a denominator of ZERO in CI until this pattern landed. bin/redact_selftest.sh
# independently treats +852 numbers as must-redact PII, which is the same call.
#
# Composed at runtime, and structurally non-assignable: HK 8-digit numbers do
# not begin 0, so an all-zero subscriber block can belong to no subscriber, yet
# a +852 prefix in front of it still matches the shape and so proves the pattern
# is live. (The number is assembled from parts below, never written contiguously,
# for the usual reason: this file is scanned by the very gate it tests.) There is
# no reserved HK drama range to lean on, which is exactly why the FIRE limb must
# exist -- a silently dropped HK pattern would otherwise be invisible.
_hk_cc="+852"; _hk="0000 0000"
HK_FILE="$WORK/hk.txt"
printf 'ring %s %s before noon\n' "$_hk_cc" "$_hk" > "$HK_FILE"
OUT="$(pii_scan_files "$HK_FILE" "$WORK/no-custom")"
assert_contains "$OUT" "$HK_FILE" "built-in HK-mobile pattern FIRES on a +852 non-assignable number"

# ── Linux home path /home/<name>: BOTH limbs ─────────────────────────────
# The denylist checks /home/<name> alongside /Users/<name>; the shape scan only
# had /Users until now. HR015's gaming PC runs Ubuntu, so /home/<operator> is a
# real leak vector. The name segment is composed at runtime, same reason as the
# other canaries.
_lh="/home/"; _ln="canaryoperator"
LHOME_FILE="$WORK/linux_home.txt"
printf 'logs under %s%s/.ostler\n' "$_lh" "$_ln" > "$LHOME_FILE"
OUT="$(pii_scan_files "$LHOME_FILE" "$WORK/no-custom")"
assert_contains "$OUT" "$LHOME_FILE" "built-in HOME-PATH pattern FIRES on a non-placeholder /home/<name>"

# The excused half. /home/runner is the GitHub-hosted Ubuntu CI home and is
# provably impersonal, so it must be let through exactly as /Users/runner is.
LHOME_CI_FILE="$WORK/linux_home_ci.txt"
printf 'built under %s\n' "/home/runner/work/repo" > "$LHOME_CI_FILE"
OUT="$(pii_scan_files "$LHOME_CI_FILE" "$WORK/no-custom")"
assert_not_contains "$OUT" "$LHOME_CI_FILE" "CI home /home/runner is EXCUSED, not reported"

# ──────────────────────────────────────────────────────────────────────────
# 4. A customer-added pattern fires (and merges with built-ins)
# ──────────────────────────────────────────────────────────────────────────
echo "-- customer pattern fires --"
CUSTOM="$WORK/.pii-patterns"
cat > "$CUSTOM" <<'EOF'
# synthetic test patterns
ACME-EMP-[0-9]{4}
\bProjectFakeName\b
EOF

EMP_FILE="$WORK/emp.txt"
printf 'badge ACME-EMP-0042 issued\n' > "$EMP_FILE"
OUT="$(pii_scan_files "$EMP_FILE" "$CUSTOM")"
assert_contains "$OUT" "$EMP_FILE" "customer-added pattern fires"

# Built-in still fires when a custom file is present (merge, not replace).
OUT="$(pii_scan_files "$SSN_FILE" "$CUSTOM")"
assert_contains "$OUT" "$SSN_FILE" "built-in still fires when customer file present (merge)"

# A file matching neither stays clean.
OUT="$(pii_scan_files "$CLEAN_FILE" "$CUSTOM")"
assert_not_contains "$OUT" "$CLEAN_FILE" "clean file clean under merged set"

# ──────────────────────────────────────────────────────────────────────────
# 5. A malformed customer regex is SKIPPED with a warning, not a crash
# ──────────────────────────────────────────────────────────────────────────
echo "-- malformed customer regex degrades gracefully --"
BADCUSTOM="$WORK/.pii-patterns-bad"
cat > "$BADCUSTOM" <<'EOF'
# this one is broken (unterminated bracket class)
ACME-[0-9
# this one is fine and should still work
GOODTOKEN-[0-9]{3}
EOF

# Capture stdout (patterns) and stderr (warnings) separately.
PERR="$WORK/perr.txt"
PATS="$(pii_load_patterns "$BADCUSTOM" 2>"$PERR")"
WARN="$(cat "$PERR")"

assert_contains "$WARN" "skipping invalid customer regex" "malformed regex produces a warning on stderr"
assert_contains "$PATS" "GOODTOKEN-[0-9]{3}" "valid sibling pattern still loaded after a bad one"
assert_not_contains "$PATS" "ACME-[0-9" "malformed pattern excluded from the active set"

# The scan must still run (not crash) and still catch the good custom pattern
# AND the built-ins, despite the bad line.
GOOD_FILE="$WORK/good.txt"
printf 'token GOODTOKEN-777 here\n' > "$GOOD_FILE"
SCAN_RC=0
OUT="$(pii_scan_files "$GOOD_FILE" "$BADCUSTOM" 2>/dev/null)" || SCAN_RC=$?
if [ "$SCAN_RC" -eq 0 ]; then
    ok "scan returns cleanly despite a malformed customer regex"
else
    bad "scan returns cleanly despite a malformed customer regex (rc=$SCAN_RC)"
fi
assert_contains "$OUT" "$GOOD_FILE" "good custom pattern still fires alongside a bad sibling"

# A malformed line must not nuke the built-ins either.
OUT="$(pii_scan_files "$SSN_FILE" "$BADCUSTOM" 2>/dev/null)"
assert_contains "$OUT" "$SSN_FILE" "built-ins survive a malformed customer file"

# ──────────────────────────────────────────────────────────────────────────
# 5b. The BUILT-IN PATTERN FLOOR
#
# The library declares how many built-ins it provides. Two things must hold,
# and they fail in opposite directions, so both are asserted:
#
#   DRIFT   declared == the number of patterns actually in the source block.
#           Catches "someone added a pattern and did not bump the count", at
#           commit time, loudly. Without this the declared number rots into a
#           constant nobody maintains and the floor stops meaning anything.
#
#   FLOOR   the check passes on a healthy library, and REFUSES when a built-in
#           goes missing at runtime. Proved in both directions below, because
#           a floor only ever observed passing is indistinguishable from one
#           wired to a predicate that cannot fail.
# ──────────────────────────────────────────────────────────────────────────
echo "-- built-in pattern floor --"

DECLARED="$(pii_builtin_expected_count)"
ACTUAL_IN_SOURCE="$(pii_builtin_patterns | grep -cvE '^[[:space:]]*(#|$)' || true)"
if [ "$DECLARED" = "$ACTUAL_IN_SOURCE" ]; then
    ok "declared built-in count ($DECLARED) matches the source block ($ACTUAL_IN_SOURCE)"
else
    bad "declared built-in count ($DECLARED) does NOT match the source block ($ACTUAL_IN_SOURCE) -- bump pii_builtin_expected_count"
fi

# GREEN limb: a healthy library passes its own floor.
if pii_builtin_floor_check 2>/dev/null; then
    ok "floor passes on the real, healthy library"
else
    bad "floor passes on the real, healthy library"
fi

# TWO RED limbs, because `loaded < declared` is true under two DIFFERENT
# faults that want opposite fixes, and a diagnostic that cannot tell them
# apart sends the reader to the wrong file. Each is provoked along the axis
# it actually measures; overriding the declared count instead would prove
# nothing, since the fault being guarded is patterns going missing, not the
# constant changing.
FLOOR_ERR="$WORK/floor_err.txt"

# RED limb 1 -- SOURCE SHORT. The block was edited, the count was not.
# Subshell so the override cannot leak into later tests.
FLOOR_RC=0
(
    pii_builtin_patterns() {
        cat <<'SHORT'
# only two here, against a declared set of more
\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b
\b[0-9]{15,}\b
SHORT
    }
    pii_builtin_floor_check
) 2>"$FLOOR_ERR" || FLOOR_RC=$?

if [ "$FLOOR_RC" -ne 0 ]; then
    ok "floor REFUSES when the source block is short (rc=$FLOOR_RC)"
else
    bad "floor REFUSES when the source block is short (it passed -- the floor is dead)"
fi
FLOOR_MSG="$(cat "$FLOOR_ERR")"
assert_contains "$FLOOR_MSG" "declared $DECLARED"     "short-source: names the DECLARED count"
assert_contains "$FLOOR_MSG" "source block holds 2"   "short-source: names the SOURCE count"
assert_contains "$FLOOR_MSG" "loaded 2"               "short-source: names the LOADED count"
assert_contains "$FLOOR_MSG" "the source block itself is short" \
    "short-source: names the CAUSE, so the reader edits the count not the grep"

# RED limb 2 -- VALIDATION DROP. The source is intact; this environment could
# not compile one of the patterns. THIS is the fault the floor exists for: a
# BSD/GNU grep disagreement or a locale quirk drops a class in CI and nowhere
# else, and the scan narrows in silence. Provoked by shadowing the VALIDATOR,
# which is precisely the component whose behaviour varies by environment.
FLOOR_RC=0
(
    _real_valid() { pii_regex_is_valid "$@"; }
    pii_regex_is_valid() {
        # Simulate an environment whose grep will not compile the home-path
        # pattern. Everything else validates normally.
        case "$1" in
            */Users/*) return 1 ;;
        esac
        _real_valid "$1"
    }
    pii_builtin_floor_check
) 2>"$FLOOR_ERR" || FLOOR_RC=$?

if [ "$FLOOR_RC" -ne 0 ]; then
    ok "floor REFUSES when a built-in fails validation in this environment (rc=$FLOOR_RC)"
else
    bad "floor REFUSES when a built-in fails validation (it passed -- the floor is dead)"
fi
FLOOR_MSG="$(cat "$FLOOR_ERR")"
assert_contains "$FLOOR_MSG" "NOT survive validation" \
    "validation-drop: names the CAUSE as validation, not a short block"
assert_contains "$FLOOR_MSG" '/Users/' \
    "validation-drop: names the missing pattern BY REGEX, not just a delta"
# The source is intact in this limb, so the short-block cause must NOT be
# claimed. A diagnostic that prints both causes every time has told the reader
# nothing.
assert_not_contains "$FLOOR_MSG" "the source block itself is short" \
    "validation-drop: does NOT also claim the source is short"

# ──────────────────────────────────────────────────────────────────────────
# 6. Comments and blank lines in the customer file are ignored
# ──────────────────────────────────────────────────────────────────────────
echo "-- comments / blanks ignored --"
COMMENTED="$WORK/.pii-patterns-comments"
printf '# just a comment\n\n   \n' > "$COMMENTED"
# Should load exactly the built-ins (no extra, no crash).
ONLY_DEFAULTS="$(pii_load_patterns "$COMMENTED" 2>/dev/null)"
if [ "$ONLY_DEFAULTS" = "$DEFAULTS" ]; then
    ok "comment/blank-only customer file adds nothing"
else
    bad "comment/blank-only customer file adds nothing"
fi

echo ""
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
