#!/usr/bin/env bash
#
# test_walk_record_gates_customer_download.sh
#
# #844 -- the customer download must not repoint to a build nobody installed.
#
# The gate under test is scripts/verify_walk_record.sh, and the wiring under
# test is scripts/publish_release.sh consulting it before --latest.
#
# WHY A SOURCE-TEXT ASSERTION IS PART OF THIS FILE. The gate's behaviour can be
# tested directly and is, below. Its INVOCATION cannot: publish_release.sh
# needs a notarised DMG and a cross-org token. So the wiring is asserted on the
# source, and the assertion is written to fail if the call is deleted OR if the
# --latest promotion escapes the conditional -- because the defect being closed
# here is precisely a correct mechanism that nothing called.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_walk_record.sh"
PUBLISH="${REPO_ROOT}/scripts/publish_release.sh"
QA="${REPO_ROOT}/scripts/post_walk_qa.sh"

PASS=0; FAIL=0
ok()   { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export OSTLER_WALK_RECORD_DIR="$TMP"

write_record() {
    # write_record <file> <version> <verdict> <pass> <fail> <cannot> <broken>
    { printf 'version\t%s\n'    "$2"
      printf 'walked_at\t%s\n'  "2026-08-23T09:00:00Z"
      printf 'box_fp\t%s\n'     "0000111122223333"
      printf 'pass\t%s\n'       "$4"
      printf 'fail\t%s\n'       "$5"
      printf 'cannot_run\t%s\n' "$6"
      printf 'broken\t%s\n'     "$7"
      printf 'verdict\t%s\n'    "$3"
      printf 'qa_exit\t0\n'
    } > "${TMP}/$1"
}

run_gate() { "$GATE" "$@" >/dev/null 2>&1; echo $?; }

echo
echo "=== #844: a walk record gates the customer download ==="
echo

# ── CANNOT-RUN CHECKS FIRST ──────────────────────────────────────────
# If the files under test are absent, every assertion below would report a
# confident result about nothing.
for f in "$GATE" "$PUBLISH" "$QA"; do
    if [[ ! -f "$f" ]]; then
        echo "FAIL: ${f} does not exist. CANNOT-RUN, not a pass." >&2
        exit 1
    fi
done
ok "CANNOT-RUN check: all three files under test exist"

# ── CONTROL: THE GATE CAN SAY YES ────────────────────────────────────
# Run FIRST and on the same code path as every refusal below. A gate observed
# only refusing is not known to be able to pass, and a gate that refuses
# everything would score full marks on a suite made only of refusals.
write_record "v1.0.42.tsv" "v1.0.42" "CLEAN" 14 0 0 0
rc="$(run_gate v1.0.42)"
if [[ "$rc" == "0" ]]; then
    ok "CONTROL: a clean walk of the right version is ACCEPTED (rc=0)"
else
    echo "FAIL: the positive control was refused (rc=${rc}). Every refusal" >&2
    echo "      below would then be meaningless. CANNOT-RUN." >&2
    exit 1
fi

# ── 1. NO RECORD IS NOT A PASS ───────────────────────────────────────
rc="$(run_gate v9.9.9)"
[[ "$rc" == "2" ]] && ok "no record at all -> rc=2 (CANNOT-RUN, distinct from failure)" \
                   || bad "no record gave rc=${rc}, expected 2"

# ── 2. A FAILED WALK BLOCKS, AND SAYS SO DIFFERENTLY ─────────────────
write_record "v1.0.43.tsv" "v1.0.43" "FAILED" 11 3 0 0
rc="$(run_gate v1.0.43)"
[[ "$rc" == "1" ]] && ok "a FAILED walk -> rc=1 (evidence of badness, not absence of evidence)" \
                   || bad "FAILED walk gave rc=${rc}, expected 1"

# ── 3. PARTIAL IS NOT CLEAN ──────────────────────────────────────────
# The distinction the whole box walk exists to make. 0 failures with 5 probes
# that never ran is not a clean walk.
write_record "v1.0.44.tsv" "v1.0.44" "PARTIAL" 9 0 5 0
rc="$(run_gate v1.0.44)"
[[ "$rc" == "2" ]] && ok "PARTIAL (cannot_run=5, fail=0) -> rc=2, coverage lost is not coverage passed" \
                   || bad "PARTIAL walk gave rc=${rc}, expected 2"

# ── 4. A RECORD OF A DIFFERENT VERSION DOES NOT TRANSFER ─────────────
# The realistic accident: last release's record, still sitting in the tree,
# clearing the gate for a build it never saw.
write_record "v1.0.45.tsv" "v1.0.38" "CLEAN" 14 0 0 0
rc="$(run_gate v1.0.45)"
[[ "$rc" == "2" ]] && ok "a v1.0.38 record filed as v1.0.45 is REFUSED (content, not filename)" \
                   || bad "version mismatch gave rc=${rc}, expected 2"

# ── 5. THE VERDICT MUST AGREE WITH ITS OWN COUNTS ────────────────────
write_record "v1.0.46.tsv" "v1.0.46" "CLEAN" 12 2 0 0
rc="$(run_gate v1.0.46)"
[[ "$rc" == "1" ]] && ok "CLEAN claimed with fail=2 is REFUSED -- trust the counts, not the summary" \
                   || bad "self-contradicting record gave rc=${rc}, expected 1"

# ── 6. AN EMPTY WALK IS NOT A CLEAN WALK ─────────────────────────────
# pass=0 with nothing failing is what a suite that never started looks like.
write_record "v1.0.47.tsv" "v1.0.47" "CLEAN" 0 0 0 0
rc="$(run_gate v1.0.47)"
[[ "$rc" == "2" ]] && ok "pass=0 is REFUSED -- 'nothing failed' and 'nothing ran' are not the same" \
                   || bad "empty walk gave rc=${rc}, expected 2"

# ── 7. AN UNKNOWN VERDICT FAILS CLOSED ───────────────────────────────
write_record "v1.0.48.tsv" "v1.0.48" "CLEAR" 14 0 0 0
rc="$(run_gate v1.0.48)"
[[ "$rc" == "2" ]] && ok "a typo'd verdict ('CLEAR') fails CLOSED, never as CLEAN" \
                   || bad "unknown verdict gave rc=${rc}, expected 2"

# ── 8. A TRUNCATED RECORD IS NOT A PASS ──────────────────────────────
printf 'version\tv1.0.49\nverdict\tCLEAN\n' > "${TMP}/v1.0.49.tsv"
rc="$(run_gate v1.0.49)"
[[ "$rc" == "2" ]] && ok "a record missing its count fields is REFUSED" \
                   || bad "truncated record gave rc=${rc}, expected 2"

# ── 9. THE WIRING: publish_release.sh MUST CONSULT THE GATE ──────────
# This is the #844 assertion proper. The gate existing is not the fix; the
# gate being CALLED is.
if grep -q 'verify_walk_record\.sh' "$PUBLISH"; then
    ok "publish_release.sh invokes verify_walk_record.sh"
else
    bad "publish_release.sh does NOT invoke verify_walk_record.sh -- the gate is dark, which is the defect #844 names"
fi

# ── 10. --latest MUST BE CONDITIONAL, NOT UNCONDITIONAL ──────────────
# Calling the gate and then promoting anyway is the shape that would pass
# assertion 9 while changing nothing. Every --latest must sit behind the
# PROMOTE decision, so the bare form is what gets counted.
bare_latest="$(grep -cE '^[^#]*gh release (create|edit)[^|]*--latest' "$PUBLISH")"
if [[ "$bare_latest" -eq 0 ]]; then
    ok "no unconditional --latest on a gh release command (promotion is behind the gate)"
else
    bad "${bare_latest} gh release command(s) pass --latest directly; promotion must be conditional on the walk record"
fi

# ── 11. THE QA SUITE MUST WRITE THE RECORD ───────────────────────────
# Otherwise the gate is satisfiable only by hand, and a gate whose evidence
# has to be hand-written is a gate that gets hand-waved.
if grep -q 'OSTLER_WALK_RECORD_DIR' "$QA"; then
    ok "post_walk_qa.sh writes a walk record (gate is satisfiable by running the walk)"
else
    bad "post_walk_qa.sh does not write a walk record -- nothing would ever satisfy the gate"
fi

# ── 12. THE BOX HOST MUST NOT BE RECORDED IN CLEARTEXT ───────────────
# This repo is PUBLIC and the box argument is an ssh target -- routinely
# user@address. The record is committed, so a raw host would publish an
# operator's account name and their machine's address on every walk.
if grep -qE 'box_fp.*BOX_FP|BOX_FP=' "$QA" && grep -q 'shasum' "$QA"; then
    ok "the walk record stores a HASH of the box, not the ssh target (public repo)"
else
    bad "post_walk_qa.sh appears to record the box host without hashing it"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
