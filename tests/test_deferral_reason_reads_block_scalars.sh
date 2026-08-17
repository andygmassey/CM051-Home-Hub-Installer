#!/bin/bash
# test_deferral_reason_reads_block_scalars.sh
# ===========================================================================
# deferral_reason() must return the REASON, not the YAML block-scalar marker.
#
# THE DEFECT THIS PINS
#
# The function took the text after `reason:` on that single line. Every
# substantial reason in cut-deferrals.yaml is written as `reason: >-` with an
# indented block, because they run to paragraphs. So the text after the key
# was the literal string ">-", and the gate printed:
#
#     [warn] deferred: daemon:#312 -- >-
#
# MEASURED on cut-deferrals.yaml at the v1.0.34 cut: 21 of 594 refs rendered
# as a bare block token, including the three daemon rows renewed for that cut.
#
# WHY THIS IS NOT COSMETIC, WHICH IS THE WHOLE REASON IT IS GATED
#
# A deferral's justification for existing is that a hold is a RECORDED
# DECISION rather than a silent absence, and the record IS the reason text.
# Printing ">-" turns "deferred, and here is why" into "deferred", which is
# the exact state the file exists to abolish. It also swallowed expiry
# instructions: the vault-state row's own text says the gate must speak up
# again at the next cut, and the gate was structurally unable to say it.
#
# NEGATIVE CONTROLS ARE INCLUDED DELIBERATELY. A test that only asserts
# "output is non-empty" passes on the ">-" defect itself, so the assertions
# below require the marker to be ABSENT and the prose to be PRESENT, and
# check that an unknown ref still yields nothing.
# ===========================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_no_orphaned_fixes.sh"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$GATE" ] || { echo "CANNOT RUN: no gate at $GATE -- nothing was checked." >&2; exit 2; }

# Pull the function out of the gate rather than re-implementing it: the thing
# under test must be the shipped code, not a copy that can drift from it.
FN="$(sed -n '/^deferral_reason()/,/^}/p' "$GATE")"
[ -n "$FN" ] || { echo "CANNOT RUN: could not extract deferral_reason() -- nothing was checked." >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "${WORK}/deferrals.yaml" <<'YAML'
deferrals:
  - ref: synthetic:block-folded
    reason: >-
      FIRST LINE OF THE FOLDED REASON. Second physical line that must also be
      returned, because a reason cut off at the first line loses the part that
      says what to do next.
    until_cut: v9.9.9
  - ref: synthetic:plain-inline
    reason: A single-line reason that was always read correctly.
    until_cut: v9.9.9
  - ref: synthetic:block-literal
    reason: |-
      LITERAL BLOCK REASON that uses a pipe rather than a caret.
    until_cut: v9.9.9
  - ref: synthetic:quoted-inline
    reason: "A quoted single-line reason."
    until_cut: v9.9.9
YAML

run_reason() {
    DEFERRALS_FILE="${WORK}/deferrals.yaml" bash -c "
        $FN
        deferral_reason \"\$1\"
    " _ "$1" 2>/dev/null
}

echo "test_deferral_reason_reads_block_scalars"

# --- folded block: the defect case -------------------------------------------
out="$(run_reason 'synthetic:block-folded')"
case "$out" in
    ">-"|">"|"|"|"|-"|"") no "folded block still returns the bare marker [${out}]" ;;
    *) ok "folded block returns prose, not the marker" ;;
esac
case "$out" in
    *"FIRST LINE OF THE FOLDED REASON"*) ok "folded block includes its first line" ;;
    *) no "folded block lost its first line: [${out}]" ;;
esac
case "$out" in
    *"says what to do next"*) ok "folded block includes its LAST line (not truncated at line 1)" ;;
    *) no "folded block was truncated before its final line: [${out}]" ;;
esac
n="$(printf '%s' "$out" | wc -l | tr -d ' ')"
[ "$n" -eq 0 ] && ok "folded block is emitted as a single line (no trailing newline split)" \
               || no "folded block emitted $((n + 1)) lines; the warn line must stay on one"

# --- literal block ------------------------------------------------------------
out="$(run_reason 'synthetic:block-literal')"
case "$out" in
    *"LITERAL BLOCK REASON"*) ok "literal (|-) block is read too" ;;
    *) no "literal block not read: [${out}]" ;;
esac

# --- inline forms must not regress -------------------------------------------
out="$(run_reason 'synthetic:plain-inline')"
case "$out" in
    "A single-line reason that was always read correctly.") ok "plain inline reason unchanged" ;;
    *) no "plain inline reason regressed: [${out}]" ;;
esac

out="$(run_reason 'synthetic:quoted-inline')"
case "$out" in
    "A quoted single-line reason.") ok "quoted inline reason unchanged (quotes stripped)" ;;
    *) no "quoted inline reason regressed: [${out}]" ;;
esac

# --- negative control ---------------------------------------------------------
out="$(run_reason 'synthetic:does-not-exist')"
[ -z "$out" ] && ok "CONTROL: an unknown ref yields nothing, so a hit means a match" \
              || no "CONTROL FAILED: unknown ref returned [${out}]"

echo "=== ${pass} passed / ${fail} failed ==="
[ "$fail" -eq 0 ] || exit 1
