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

# #931: the expected-sha is DERIVED from a real file, never written as a
# constant. Two hardcoded constants matching each other is a value checked
# against itself -- the exact vacuity this argument exists to close.
printf 'ostler walk-record fixture artefact\n' > "${TMP}/fixture-artefact.bin"
FIXTURE_SHA="$(shasum -a 256 "${TMP}/fixture-artefact.bin" | awk '{print $1}')"
FIXTURE_SHA_SOURCE="measured(shasum -a 256 of the fixture artefact)"
FIXTURE_VERSION_SOURCE="measured(CFBundleShortVersionString, matches argument)"

write_record() {
    # write_record <file> <version> <verdict> <pass> <fail> <cannot> <broken>
    #              [artefact_sha] [artefact_sha_source] [version_source]
    { printf 'version\t%s\n'    "$2"
      printf 'version_source\t%s\n'          "${10:-$FIXTURE_VERSION_SOURCE}"
      printf 'artefact_sha256\t%s\n'         "${8:-$FIXTURE_SHA}"
      printf 'artefact_sha256_source\t%s\n'  "${9:-$FIXTURE_SHA_SOURCE}"
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

run_gate() {
    # One argument means "the record should match the artefact being published",
    # which is the ordinary case; the #931 arms below pass their own sha.
    if [[ $# -eq 1 ]]; then
        "$GATE" "$1" "$FIXTURE_SHA" >/dev/null 2>&1; echo $?
    else
        "$GATE" "$@" >/dev/null 2>&1; echo $?
    fi
}

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
      # #931 identity fields. Present and valid on BOTH arms so this pair
      # isolates qa_exit: a fixture that differs in two places cannot say
      # which one the gate reacted to.
      printf 'version_source\t%s\n'         "$FIXTURE_VERSION_SOURCE"
      printf 'artefact_sha256\t%s\n'        "$FIXTURE_SHA"
      printf 'artefact_sha256_source\t%s\n' "$FIXTURE_SHA_SOURCE"
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

# ── #931: A VERSION IS NOT AN IDENTIFIER OF A BUILD ─────────────────────────
#
# Everything above binds the record to a VERSION. CFBundleShortVersionString
# read "1.0.50" for eleven distinct assemblies of that cut and CFBundleVersion
# was frozen at 2500 for seven cuts, so before this section a record walked on
# ANY build of v1.0.50 cleared the gate for EVERY build of v1.0.50.
#
# THE VACUITY THESE ARMS EXIST TO CATCH: `[[ "$a" == "$b" ]]` on a field the
# record does not carry compares two empty strings and PASSES. Both records in
# walks/ today are pre-#931 and carry no sha at all, so the naive fix would
# have been green on the whole live corpus while proving nothing. Arm 931-1 is
# written first and deliberately: it is the anti-vacuity arm.
echo
echo "=== #931: the record must name the BUILD, not just the version ==="

# Source assertions below are COMMENTS-STRIPPED before counting: this change
# ADDS comments that name the very constructs being counted, and a predicate
# that greps a file whose comments describe the construct counts its own
# documentation. Counts are also taken with `grep -c` and compared numerically
# rather than piped into `grep -q`, which under this file's pipefail can take
# SIGPIPE and fail on a SUCCESSFUL match.
write_no_sha() { # a pre-#931 record: version fields present, artefact fields absent
    { printf 'version\t%s\n' "$1"
      printf 'version_source\t%s\n' "$FIXTURE_VERSION_SOURCE"
      printf 'walked_at\t2026-08-23T09:00:00Z\n'
      printf 'box_fp\t3f8a1c9d2e4b6071\n'
      printf 'pass\t14\n';  printf 'fail\t0\n'
      printf 'cannot_run\t0\n'; printf 'broken\t0\n'
      printf 'verdict\tCLEAN\n'; printf 'qa_exit\t0\n'
    } > "${TMP}/$1.tsv"
}

write_no_sha "v9.3.1"
rc="$(run_gate v9.3.1)"
[[ "$rc" == "2" ]] && ok "931-1 ANTI-VACUITY: a CLEAN record with NO artefact_sha256 is CANNOT-RUN, not a pass" \
                   || bad "931-1 a record carrying no artefact sha returned rc=${rc}, expected 2 -- the comparison is vacuous"

OTHER_SHA="$(printf 'a different build of the same version\n' | shasum -a 256 | awk '{print $1}')"
write_record "v9.3.2.tsv" "v9.3.2" "CLEAN" 14 0 0 0 "$OTHER_SHA"
rc="$(run_gate v9.3.2)"
[[ "$rc" == "2" ]] && ok "931-2 a record walked on a DIFFERENT build of this version is REFUSED" \
                   || bad "931-2 sha mismatch gave rc=${rc}, expected 2"

write_record "v9.3.3.tsv" "v9.3.3" "CLEAN" 14 0 0 0 "" "asserted-unverifiable(no DMG on the box)"
rc="$(run_gate v9.3.3)"
[[ "$rc" == "2" ]] && ok "931-3 an ASSERTED sha is refused -- a value checked against itself always agrees" \
                   || bad "931-3 asserted-unverifiable sha gave rc=${rc}, expected 2"

write_record "v9.3.4.tsv" "v9.3.4" "CLEAN" 14 0 0 0 "not-a-hash"
rc="$(run_gate v9.3.4)"
[[ "$rc" == "2" ]] && ok "931-4 a sha that is not 64 hex is refused (an unparseable hash is not a hash)" \
                   || bad "931-4 malformed sha gave rc=${rc}, expected 2"

# version_source has been WRITTEN since 2026-08-24 and was read by nothing. The
# writer prints "a reader must NOT treat this record's version as measured" to a
# terminal; the only automated reader could not tell the two apart. That is
# walks/v1.0.42.tsv -- real probe results filed against a version the box never
# ran -- with the writer's guard in place and the reader's absent.
write_record "v9.3.5.tsv" "v9.3.5" "CLEAN" 14 0 0 0 "" "" "asserted-unverifiable(no Ostler.app on box)"
rc="$(run_gate v9.3.5)"
[[ "$rc" == "2" ]] && ok "931-5 an UNMEASURED version_source is refused -- the walks/v1.0.42.tsv shape" \
                   || bad "931-5 asserted version_source gave rc=${rc}, expected 2"

# THE CALLER'S ARGUMENT IS THE CALLER'S DEFECT. 3, never 2: an operator sent to
# re-walk a box because publish_release.sh passed an empty string is a wasted
# walk and a wrong diagnosis.
rc="$("$GATE" v9.3.2 >/dev/null 2>&1; echo $?)"
[[ "$rc" == "3" ]] && ok "931-6 omitting the expected-sha is a USAGE error (3), not a refusal (2)" \
                   || bad "931-6 missing arg 2 gave rc=${rc}, expected 3"
rc="$("$GATE" v9.3.2 "deadbeef" >/dev/null 2>&1; echo $?)"
[[ "$rc" == "3" ]] && ok "931-7 a malformed expected-sha is a USAGE error (3), not a refusal (2)" \
                   || bad "931-7 short arg 2 gave rc=${rc}, expected 3"

# CONTROL: the section must be able to say YES, and on a value that is not
# byte-identical to the argument -- otherwise the comparison could be a string
# equality that never normalises.
write_record "v9.3.8.tsv" "v9.3.8" "CLEAN" 14 0 0 0 "$(printf '%s' "$FIXTURE_SHA" | tr 'a-f' 'A-F')"
rc="$(run_gate v9.3.8)"
[[ "$rc" == "0" ]] && ok "931-8 CONTROL: an UPPERCASE recorded sha still matches (and the section can pass)" \
                   || bad "931-8 CONTROL FAILED: a case-different but equal sha was refused (rc=${rc}) -- every refusal above is now suspect"

# ANTI-SIGNAL-LOSS. Scoping these checks to CLEAN is load-bearing: both live
# records are FAILED and carry no artefact sha, so an unscoped check would move
# them 1 -> 2 and a walk that MEASURED four real defects would start reporting
# that nothing is known. Evidence of badness outranks absence of evidence.
LIVE_DIR="${REPO_ROOT}/walks"
for lv in v1.0.44 v1.0.47; do
    if [[ ! -f "${LIVE_DIR}/${lv}.tsv" ]]; then
        ok "931-9 ${lv}: no live record present, arm not applicable"
        continue
    fi
    rc="$(OSTLER_WALK_RECORD_DIR="$LIVE_DIR" "$GATE" "$lv" "$FIXTURE_SHA" >/dev/null 2>&1; echo $?)"
    [[ "$rc" == "1" ]] && ok "931-9 live walks/${lv}.tsv still reports rc=1 (FAILED), not downgraded to CANNOT-RUN" \
                       || bad "931-9 live walks/${lv}.tsv now returns rc=${rc}, was 1 -- a measured failure has been turned into absence of evidence"
done
# CONTROL for the arm above: prove that directory is genuinely being read.
rc="$(OSTLER_WALK_RECORD_DIR="$LIVE_DIR" "$GATE" v0.0.0-not-a-real-walk "$FIXTURE_SHA" >/dev/null 2>&1; echo $?)"
[[ "$rc" == "2" ]] && ok "931-9 CONTROL: the live walks dir is really being consulted (absent version -> 2)" \
                   || bad "931-9 CONTROL FAILED: rc=${rc} for a version that dir does not have"

# THE WIRING. publish_release.sh must hand over the sha it computed from the
# DMG it is about to upload -- not a manifest value, not a literal. Asserted on
# the source because driving the real call needs a notarised DMG and a token.
PUB_CODE="$(sed 's/[[:space:]]*#.*$//' "$PUBLISH")"
n="$(printf '%s\n' "$PUB_CODE" | grep -cF 'verify_walk_record.sh" "$VERSION" "$SHA"')"
[[ "$n" -ge 1 ]] && ok "931-10 publish_release.sh passes \$SHA (computed from the DMG) to the gate" \
                 || bad "931-10 publish_release.sh does not pass the artefact sha -- the gate is back to version-only"
n="$(printf '%s\n' "$PUB_CODE" | grep -cF 'SHA="$(shasum -a 256 "$DMG"')"
[[ "$n" -ge 1 ]] && ok "931-10 ...and \$SHA is hashed from \$DMG here, not read from a manifest" \
                 || bad "931-10 \$SHA is no longer computed from the DMG -- both sides of the comparison may be the same assertion"

# The WRITER must produce both fields, or every record from here is CANNOT-RUN.
for fld in 'artefact_sha256' 'artefact_sha256_source'; do
    # The \t is load-bearing: without it 'artefact_sha256' also matches the
    # 'artefact_sha256_source' line and the count reads 2 for one writer.
    n="$(sed 's/[[:space:]]*#.*$//' "$QA" | grep -cF "printf '${fld}\t")"
    [[ "$n" -ge 1 ]] && ok "931-11 post_walk_qa.sh writes ${fld} (${n} site, comments-stripped)" \
                     || bad "931-11 post_walk_qa.sh does not write ${fld} -- the reader would refuse every future record"
done
n="$(grep -cF 'measured(shasum -a 256' "$QA")"
[[ "$n" -ge 1 ]] && ok "931-11 ...and it can record a MEASURED source, not only an asserted one" \
                 || bad "931-11 the writer has no measured(...) path for the sha -- the gate could never pass"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
