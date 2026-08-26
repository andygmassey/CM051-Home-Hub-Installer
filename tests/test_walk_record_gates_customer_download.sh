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
      printf 'box_fp\t%s\n'     "3f8a1c9d2e4b6071"
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

# ── 13. qa_exit IS EVIDENCE AND MUST BE READ ─────────────────────────
# ORM's review, 2026-08-23 09:16Z: he drove the gate through seven hand-built
# records and the seventh -- qa_exit=1 with CLEAN counts -- was ACCEPTED (rc=0).
# The field was written by post_walk_qa.sh, documented in walks/README.md, and
# `grep -c qa_exit scripts/verify_walk_record.sh` was 0.
#
# His sharper point, which is what these three assertions actually pin: the gate
# was accidentally safe because VERDICT derives from the same `overall` variable
# that produces qa_exit. One variable feeding two fields is a coincidence of
# implementation, not a property of the format. QA limbs like CUT-MANIFEST never
# move pass/fail/cannot_run/broken, so qa_exit is the ONLY field that can carry
# them. Assert the field.
write_record_qa() {
    # write_record_qa <verdict> <qa_exit|omit>
    { printf 'version\tv1.0.42\n'
      printf 'walked_at\t2026-08-23T09:00:00Z\n'
      printf 'box_fp\t3f8a1c9d2e4b6071\n'
      printf 'pass\t14\nfail\t0\ncannot_run\t0\nbroken\t0\n'
      printf 'verdict\t%s\n' "$1"
      [[ "$2" != "omit" ]] && printf 'qa_exit\t%s\n' "$2"
    } > "${TMP}/v1.0.42.tsv"
}

write_record_qa CLEAN 1
rc="$(run_gate v1.0.42)"
[[ "$rc" == "1" ]] \
    && ok "qa_exit=1 with CLEAN counts is REFUSED (rc=1) -- ORM's probe 7" \
    || bad "qa_exit=1 with CLEAN counts returned rc=${rc}, expected 1 (the hole is open)"

# POSITIVE CONTROL for the two assertions around it. Identical record, one
# field flipped. Without it, a gate that refused everything would score both
# refusals above and below as passes.
write_record_qa CLEAN 0
rc="$(run_gate v1.0.42)"
[[ "$rc" == "0" ]] \
    && ok "CONTROL: the same record with qa_exit=0 is ACCEPTED (rc=0)" \
    || bad "the qa_exit positive control was refused (rc=${rc}) -- the assertions around it prove nothing"

# ABSENCE is CANNOT-RUN, not FAIL. A record written before the field existed is
# not evidence of a bad walk; the exit codes must keep those apart, which is the
# whole reason this script has three of them.
write_record_qa CLEAN omit
rc="$(run_gate v1.0.42)"
[[ "$rc" == "2" ]] \
    && ok "a record with NO qa_exit is CANNOT-RUN (rc=2), not a pass and not a failure" \
    || bad "absent qa_exit returned rc=${rc}, expected 2"

# ── THE RECORD'S COUNTS ARE USELESS IF THE DETAIL IS DELETED ────────────────
#
# post_walk_qa.sh WRITES the record this file gates on. Until 2026-08-26 it held
# the probe output in `mktemp` under `trap rm EXIT`, so the instant the walk
# ended the only record of WHICH probes failed was gone.
#
# MEASURED: walks/v1.0.47.tsv says fail=5 cannot_run=4 verdict=FAILED and names
# not one probe. Those counts refuse the customer download. Recovering the
# reasons costs a full re-walk of a physical box -- the most expensive step in
# the pipeline. A refusal nobody can act on is a refusal that gets overridden.
#
# The predicate is EXTRACTED FROM THE WRITER AND RUN, not re-typed here: a test
# that re-implements the thing it checks passes with the real code deleted.
_pwq="${REPO_ROOT}/scripts/post_walk_qa.sh"
if [[ ! -r "$_pwq" ]]; then
    bad "CANNOT-RUN: no readable post_walk_qa.sh -- not a pass"
else
    _s=$(grep -n '^PROBE_LOG=""' "$_pwq" | head -1 | cut -d: -f1)
    _e=$(grep -n '^OSTLER_BOX_HOST="\$BOX"' "$_pwq" | head -1 | cut -d: -f1)
    if [[ -z "$_s" || -z "$_e" ]]; then
        bad "CANNOT-RUN: could not extract the probe-log block from post_walk_qa.sh -- anchors moved, re-point this arm rather than deleting it"
    else
        _blk="$(sed -n "${_s},$((_e-1))p" "$_pwq")"
        _h="$(mktemp -d)"
        # BOX must be set. post_walk_qa.sh takes it as $1 and exits 3 without
        # one, and the block now reads it to write the plaintext host header --
        # under `set -u` an unset BOX aborts the eval and PROBE_LOG comes back
        # empty. Caught by this very arm when the header was added.
        _got="$( export HOME="$_h"; BOX="synthetic.invalid"; CUT_VERSION=v0.0.0-test
                 eval "$_blk" >/dev/null 2>&1; printf '%s' "$PROBE_LOG" )"

        # 1. It must survive the run.
        case "$_got" in
            "$_h"/.ostler/walks/*) ok "the probe detail is kept, not deleted with the run" ;;
            *) bad "probe log is not persisted under HOME (got '${_got}') -- a FAILED walk would again name no probes" ;;
        esac

        # 2. AND IT MUST NOT BE IN THIS REPO. CM051 is PUBLIC -- that is exactly
        # why the record stores box_fp as a hash. The raw log is the opposite:
        # real hostname, real paths, real output. If someone "tidies" it into
        # walks/ it becomes a tracked file and the hashing was for nothing.
        #
        # EMPTY IS NOT "OUTSIDE THE REPO". Without this guard the arm passed
        # vacuously the moment the eval aborted: '' does not match "$REPO_ROOT"/*,
        # so a broken extraction scored as proof of containment. Measured -- it
        # reported ok while arm 1 was already failing on the same empty value.
        if [ -z "$_got" ]; then
            bad "arm 2 has nothing to judge (PROBE_LOG empty) -- that is CANNOT-RUN, not proof the log is outside the repo"
        else
            case "$_got" in
                "$REPO_ROOT"/*) bad "the probe log resolves INSIDE the repo (${_got}) -- this repo is public and the log carries the real hostname" ;;
                *) ok "the probe log is outside the repo, so it cannot become a tracked file" ;;
            esac
        fi

        # 3. The header must NAME THE BOX. The record cannot (it is public and
        # stores only sha256(host)[0:16]), so if the local log does not carry
        # the plaintext either, nobody can say which machine a FAILED walk ran
        # against. Measured on v1.0.47: box_fp 38abe713e160f279, eleven
        # candidate hosts, no match -- the box is simply unrecoverable.
        if [ -n "$_got" ] && [ -f "$_got" ]; then
            grep -q 'synthetic.invalid' "$_got" \
                && ok "the local log names the box in plaintext, so a walk is attributable" \
                || bad "the log does not name the host -- a FAILED walk stays unattributable, which is the v1.0.47 situation"
        fi

        # 4. THE TEE MUST APPEND. The three arms above eval the header block in
        # isolation; they cannot see the line that writes the probe output,
        # because driving that needs a real box over ssh. So this one is a
        # source assertion, and it is not decoration:
        #
        #   `| tee "$PROBE_LOG"`     truncates -- header gone, box unattributable
        #   `| tee -a "$PROBE_LOG"`  appends   -- header survives
        #
        # Measured: reverting to the truncating form still PARSES and still
        # passes all three arms above. Without this line that regression is
        # invisible, which is the gap this arm exists to close.
        if grep -qE 'tee -a "\$PROBE_LOG"' "$_pwq"; then
            ok "the probe output APPENDS to the log, so the host header survives"
        else
            bad "the probe output is tee'd WITHOUT -a -- it truncates the file and destroys the host header written above it"
        fi

        # 3. The fallback must CONFESS. Silently reverting to a temp file is the
        # original defect wearing a different mask.
        _h2="$(mktemp -d)"; chmod 500 "$_h2"
        _out="$( export HOME="$_h2"; BOX="synthetic.invalid"; CUT_VERSION=v0.0.0-test; eval "$_blk" 2>&1 )"
        chmod 700 "$_h2"
        case "$_out" in
            *"TEMPORARY and dies"*) ok "an unwritable log dir is ANNOUNCED, not silently downgraded" ;;
            *) bad "the fallback path is silent -- an operator would believe detail was kept when it was not" ;;
        esac
        rm -rf "$_h" "$_h2"
    fi
fi

# ── BROKEN MUST NOT READ ZERO WHEN PROBES ARE BROKEN ────────────────────────
#
# count_of() parses the four counts that go into the walk record. It was
#     awk '$1 == k { print $2; exit }'
# which takes the FIRST line whose first field is the keyword.
#
# PASS / FAIL / CANNOT-RUN appear only in the closing summary, so they parsed by
# luck. BROKEN is ALSO a per-probe label in phase 1 -- "BROKEN  <name>  (self-test
# returned 0, expected 1)" -- and phase 1 is printed first. The match landed on
# the probe line, returned the probe NAME, failed the ^[0-9]+$ guard, and was
# coerced to empty, which the record writes as 0.
#
# MEASURED on the real 2026-08-26T14:17:14Z walk of the v1.0.47 box: two probes
# were BROKEN and the record said broken 0. BROKEN is the most serious state the
# suite has -- a probe that fails its own negative control measures NOTHING and
# phase 2 skips it -- so it was the single count that read zero exactly when it
# mattered, in the file that gates the customer download.
#
# The fixture below reproduces that ORDER deliberately: per-probe label first,
# summary block after. A fixture with only the summary would pass against the
# broken predicate and prove nothing.
_pwq2="${REPO_ROOT}/scripts/post_walk_qa.sh"
if [[ ! -r "$_pwq2" ]]; then
    bad "CANNOT-RUN: no readable post_walk_qa.sh for the count_of arm -- not a pass"
else
    _cline="$(grep -n '^count_of() {' "$_pwq2" | head -1 | cut -d: -f1)"
    if [[ -z "$_cline" ]]; then
        bad "CANNOT-RUN: count_of() not found in post_walk_qa.sh -- re-point this arm rather than deleting it"
    else
        _fix="$(sed -n "${_cline}p" "$_pwq2")"
        _log="$(mktemp)"
        {
            printf '  BROKEN   app_signature_survives_first_run  (self-test returned 0, expected 1)\n'
            printf '  ok       daemon_is_listening  (goes red on known-bad input)\n'
            printf '  BROKEN   pairing_recovers_without_a_repair_storm  (self-test returned 0, expected 1)\n'
            printf '\n  === Summary ===\n'
            printf '  PASS        7\n'
            printf '  FAIL        4\n'
            printf '  CANNOT-RUN  4\n'
            printf '  BROKEN      2\n'
        } > "$_log"

        ( PROBE_LOG="$_log"; eval "$_fix"
          _got_b="$(count_of BROKEN)"; _got_p="$(count_of PASS)"
          [ "$_got_b" = "2" ] && [ "$_got_p" = "7" ] ) \
            && ok "count_of reads the SUMMARY line: BROKEN=2 despite two per-probe BROKEN labels above it" \
            || bad "count_of returned the wrong BROKEN -- a broken probe would be recorded as 0 and the walk would look cleaner than it is"

        # THE CONTROL. A predicate that returned "" for everything would pass the
        # assertion above only if it also broke PASS, so check a keyword that was
        # never ambiguous still resolves.
        ( PROBE_LOG="$_log"; eval "$_fix"
          [ "$(count_of CANNOT-RUN)" = "4" ] ) \
            && ok "CONTROL: an unambiguous keyword still parses (CANNOT-RUN=4)" \
            || bad "CONTROL FAILED: count_of can no longer read CANNOT-RUN -- the fix broke the working cases"

        rm -f "$_log"
    fi
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
