#!/usr/bin/env bash
#
# tests/test_a_completed_walk_records_itself.sh
#
# ── WHAT THIS GUARDS ─────────────────────────────────────────────────────
#
# The launch directive makes walks/v1.0.NN.tsv with `verdict CLEAN` THE
# deliverable. scripts/verify_walk_record.sh reads it, scripts/publish_release.sh
# refuses to repoint the customer download without it, and
# scripts/post_walk_qa.sh writes it -- correctly, and has since 2026-08-21.
#
# MEASURED ON origin/main 2026-09-23, predicate "an executable invocation of
# post_walk_qa.sh":
#
#   whole repo, excluding tests/        0 files
#   CONTROL, same predicate, tests/     8 files
#
# The writer was BUILT AND DARK. Two full thin walks ran on real hardware that
# day and left nothing any gate could read, because scripts/ttywalk.sh -- the
# command the directive mandates -- named post_walk_qa.sh only in prose.
#
# ── WHY THE ARMS ARE SHAPED LIKE THIS ────────────────────────────────────
#
# A grep proving "ttywalk.sh mentions record_walk.sh" would pass on a comment,
# which is precisely the state that caused the defect. So arm 1 greps for the
# INVOCATION, with a negative control proving the grep can fail; and arms 2-8
# EXECUTE scripts/record_walk.sh against a stub writer, so every branch is
# measured rather than read.
#
# THE STUB IS THE POINT. The real writer needs a walked box, ssh credentials
# and forty minutes. OSTLER_POST_WALK_QA substitutes a stub that behaves the
# way post_walk_qa.sh behaves on each path, which makes the three outcomes --
# RECORDED, DECLINED, CANNOT-RUN -- reachable on a runner with no hardware.
#
# EXIT CODES
#   0  every arm measured what it claims to measure
#   1  the product misbehaved
#   2  CANNOT-RUN: the harness could not set itself up, or an anchor moved.
#      NOTHING has been measured. Re-point the anchor; do not delete the arm.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TTYWALK="${REPO_ROOT}/scripts/ttywalk.sh"
RECORDER="${REPO_ROOT}/scripts/record_walk.sh"

FAILURES=0
ARMS=0

pass() { ARMS=$((ARMS + 1)); printf '  PASS  %s\n' "$*"; }
fail() { ARMS=$((ARMS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$*"; }
cannot() { printf 'CANNOT-RUN: %s\n' "$*" >&2; exit 2; }

[[ -f "$TTYWALK"  ]] || cannot "scripts/ttywalk.sh is absent; nothing to measure."
[[ -f "$RECORDER" ]] || cannot "scripts/record_walk.sh is absent. If it was deliberately removed, this suite must be removed in the same PR -- an absent subject reads as a passing test."

TMP="$(mktemp -d)" || cannot "cannot create a scratch directory."
trap 'rm -rf "$TMP"' EXIT

# ── THE NO-OP WRITER, AND WHY IT IS NOT /bin/true ────────────────────────
#
# 🔴 THE FIRST VERSION OF THIS SUITE USED /bin/true AND IT FALSE-PASSED. That
# path exists on ubuntu-latest and DOES NOT EXIST ON macOS (it is /usr/bin/true
# there). So on the developer's own machine record_walk.sh refused with "the
# writer is absent", arm 3 saw its expected CANNOT-RUN, and reported success
# for a branch it had never reached -- while arm 4 exposed it by asserting on
# the REASON rather than the code. A probe can answer a question you did not
# ask.
#
# An explicit stub is written instead: it exists everywhere, and its behaviour
# is stated in the file rather than inherited from whichever coreutils the host
# happens to ship.
NOOP_WRITER="${TMP}/stub_writes_nothing.sh"
cat > "$NOOP_WRITER" <<'NOOPEOF'
#!/usr/bin/env bash
# A writer that exits 0 and writes no record: a dead harness.
exit 0
NOOPEOF
chmod +x "$NOOP_WRITER" || cannot "cannot make the stub writer executable."
[[ -x "$NOOP_WRITER" ]] || cannot "the stub writer is not executable; every arm below would measure its absence instead of its behaviour."

printf '== 1. ttywalk.sh INVOKES the recorder, not merely mentions it ==\n'

# The invocation, anchored on `bash <path>/record_walk.sh`. Comments and prose
# cannot match this. `|| true` because grep -c exits 1 on zero and this is a
# measurement, not a gate.
INVOCATIONS="$(/usr/bin/grep -cE '(bash|sh|\$\(|\./)[^|]*record_walk\.sh' "$TTYWALK" || true)"
if [[ "${INVOCATIONS:-0}" -ge 1 ]]; then
    pass "ttywalk.sh carries ${INVOCATIONS} executable reference(s) to record_walk.sh"
else
    fail "ttywalk.sh has NO executable invocation of record_walk.sh. The walk cannot record itself, which is the exact state that produced two unrecorded walks on 2026-09-23."
fi

# NEGATIVE CONTROL FOR THE GREP ITSELF. A predicate that matches everything
# would pass the arm above on any file. This proves it can return zero.
CTL="$(/usr/bin/grep -cE '(bash|sh|\$\(|\./)[^|]*record_walk_THIS_NAME_DOES_NOT_EXIST\.sh' "$TTYWALK" || true)"
if [[ "${CTL:-1}" -eq 0 ]]; then
    pass "control: the same predicate returns 0 for a name that does not exist"
else
    cannot "the invocation predicate matched a deliberately absent filename. It matches anything, so arm 1 measured nothing."
fi

printf '\n== 2. a walk that could not complete is DECLINED, and says so ==\n'

# --walk-verdict 2 is ttywalk's CANNOT-RUN. The box is half-installed; grading
# it would write a file that looks like evidence about a release and is not.
OUT="$(OSTLER_POST_WALK_QA="$NOOP_WRITER" OSTLER_WALK_RECORD_DIR="${TMP}/w1" \
    bash "$RECORDER" --host stub@example.invalid --version v9.9.9 --walk-verdict 2 2>&1)"
RC=$?
if [[ "$RC" -eq 3 ]] && printf '%s' "$OUT" | /usr/bin/grep -q 'walk-record: DECLINED'; then
    pass "an unadjudicated install exits 3 DECLINED and prints a status line"
else
    fail "an unadjudicated install gave rc=${RC} and no DECLINED line. Silence here is what made the defect invisible. Output: ${OUT}"
fi
if [[ -e "${TMP}/w1/v9.9.9.tsv" ]]; then
    fail "a record was written for a walk that never adjudicated. That is a fabricated verdict."
else
    pass "no record was written for a walk that never adjudicated"
fi

printf '\n== 3. a writer that produces nothing is CANNOT-RUN, never silence ==\n'

# NOOP_WRITER exits 0 and writes no file: a dead harness. An implementation
# that trusted the writer's exit code would report success here.
mkdir -p "${TMP}/w2"
OUT="$(OSTLER_POST_WALK_QA="$NOOP_WRITER" OSTLER_WALK_RECORD_DIR="${TMP}/w2" \
    bash "$RECORDER" --host stub@example.invalid --version v9.9.9 --walk-verdict 0 2>&1)"
RC=$?
# THE REASON, NOT MERELY THE CODE. record_walk.sh emits CANNOT-RUN for an
# absent writer too, and that is a different branch. Asserting only on rc=2
# is how the /bin/true false pass survived.
if [[ "$RC" -eq 2 ]] \
   && printf '%s' "$OUT" | /usr/bin/grep -q 'does not exist. The walk is unrecorded' \
   && ! printf '%s' "$OUT" | /usr/bin/grep -q 'the writer is absent'; then
    pass "a writer that exits 0 and writes nothing is CANNOT-RUN, named as a missing record and not as a missing writer"
else
    fail "a dead writer gave rc=${RC} without a CANNOT-RUN line. A green from a dead harness is the failure this control exists to catch. Output: ${OUT}"
fi

printf '\n== 4. a PRE-EXISTING record must not read as this run writing one ==\n'

# THE CONTROL THAT MATTERS MOST. Walk records are TRACKED files, so
# walks/v1.0.101.tsv can already be sitting in the checkout from somebody
# else's walk. A recorder that exits 0 over it, having written nothing, must
# not be reported as having recorded this walk.
mkdir -p "${TMP}/w3"
{ printf 'version\tv9.9.9\n'; printf 'verdict\tCLEAN\n'; } > "${TMP}/w3/v9.9.9.tsv"
# Backdate it well clear of any filesystem timestamp granularity.
touch -t 202601010000 "${TMP}/w3/v9.9.9.tsv"
OUT="$(OSTLER_POST_WALK_QA="$NOOP_WRITER" OSTLER_WALK_RECORD_DIR="${TMP}/w3" \
    bash "$RECORDER" --host stub@example.invalid --version v9.9.9 --walk-verdict 0 2>&1)"
RC=$?
if [[ "$RC" -eq 2 ]] && printf '%s' "$OUT" | /usr/bin/grep -q 'PREVIOUS walk'; then
    pass "a stale record on disk is refused as evidence of this run"
else
    fail "a pre-existing walks/v9.9.9.tsv was accepted as this run's record (rc=${RC}). That silently attributes one walk's verdict to another. Output: ${OUT}"
fi

printf '\n== 5. a writer that DOES write is RECORDED, whatever the verdict ==\n'

# 🔴 THE WRITER EXITS NON-ZERO ON A REAL WALK AND STILL WRITES. post_walk_qa.sh
# exits 1 on a FAIL and 2 on lost coverage; walks/v1.0.100.tsv says
# `verdict FAILED` and is one of the most useful files in this repo. If the
# recorder folded that exit into its own it would report a recorded walk as
# unrecorded -- turning a found defect into a missing measurement.
mkdir -p "${TMP}/w4"
STUB="${TMP}/stub_writer.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Behaves like post_walk_qa.sh on a walk that found defects: writes the record,
# then exits 1.
printf 'version\t%s\n'   "$2" >  "${OSTLER_WALK_RECORD_DIR}/$2.tsv"
printf 'walk_kind\tthin\n'   >> "${OSTLER_WALK_RECORD_DIR}/$2.tsv"
printf 'verdict\tFAILED\n'   >> "${OSTLER_WALK_RECORD_DIR}/$2.tsv"
printf 'pass\t19\n'          >> "${OSTLER_WALK_RECORD_DIR}/$2.tsv"
exit 1
STUBEOF
chmod +x "$STUB"
OUT="$(OSTLER_POST_WALK_QA="$STUB" OSTLER_WALK_RECORD_DIR="${TMP}/w4" \
    bash "$RECORDER" --host stub@example.invalid --version v9.9.9 --walk-verdict 1 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s' "$OUT" | /usr/bin/grep -q 'walk-record: RECORDED'; then
    pass "a FAILED walk that wrote its record exits 0 RECORDED (writer_exit is reported separately)"
else
    fail "a walk that DID record itself gave rc=${RC}. Folding the probe verdict into the recording verdict converts a found defect into a missing measurement. Output: ${OUT}"
fi
if printf '%s' "$OUT" | /usr/bin/grep -q 'verdict=FAILED'; then
    pass "the status line reports the verdict READ BACK from the record, not the one intended"
else
    fail "the status line does not carry the record's own verdict. Output: ${OUT}"
fi

printf '\n== 6. a record with no verdict field is not a record ==\n'

# scripts/verify_walk_record.sh REFUSES a record missing any of
# verdict/pass/fail/cannot_run/broken. A recorder that called such a file a
# success would report a walk as recorded that the gate will reject.
mkdir -p "${TMP}/w5"
STUB2="${TMP}/stub_headerless.sh"
cat > "$STUB2" <<'STUBEOF'
#!/usr/bin/env bash
printf 'version\t%s\n' "$2" > "${OSTLER_WALK_RECORD_DIR}/$2.tsv"
exit 0
STUBEOF
chmod +x "$STUB2"
OUT="$(OSTLER_POST_WALK_QA="$STUB2" OSTLER_WALK_RECORD_DIR="${TMP}/w5" \
    bash "$RECORDER" --host stub@example.invalid --version v9.9.9 --walk-verdict 0 2>&1)"
RC=$?
if [[ "$RC" -eq 2 ]] && printf '%s' "$OUT" | /usr/bin/grep -q 'no verdict field'; then
    pass "a verdict-less record is CANNOT-RUN, matching what verify_walk_record.sh will do with it"
else
    fail "a record with no verdict field was reported as recorded (rc=${RC}). verify_walk_record.sh treats it as no record at all. Output: ${OUT}"
fi

printf '\n== 7. the version is never fabricated ==\n'

# post_walk_qa.sh re-measures the version off the box and refuses a mismatch;
# this arm guards the argument it is handed. A diagnostic must not become a
# filename -- ttywalk.sh's own header records PlistBuddy writing
# "FileDoesn'tExist,WillCreate:..." into exactly this value.
mkdir -p "${TMP}/w6"
OUT="$(OSTLER_POST_WALK_QA="$NOOP_WRITER" OSTLER_WALK_RECORD_DIR="${TMP}/w6" \
    bash "$RECORDER" --host stub@example.invalid --version "FileDoesn'tExist,WillCreate" --walk-verdict 0 2>&1)"
RC=$?
if [[ "$RC" -eq 2 ]]; then
    pass "a malformed version is refused before it can become a filename"
else
    fail "a malformed version was accepted (rc=${RC}). Output: ${OUT}"
fi
if [[ -z "$(find "${TMP}/w6" -name '*.tsv' -print -quit 2>/dev/null)" ]]; then
    pass "no .tsv was created from a malformed version"
else
    fail "a .tsv was created from a malformed version."
fi

printf '\n== 8. an unreachable box is CANNOT-RUN, not a declined precondition ==\n'

# 🔴 THIS ARM EXISTS BECAUSE THE FIRST VERSION GOT IT WRONG. Measured against
# 192.0.2.1 (TEST-NET-1, RFC 5737, which by definition cannot answer): ssh
# timed out, the version came back empty, and record_walk.sh reported
# DECLINED -- "a repo walk ... is not evidence about any release". Every word
# was false; we simply could not ask. "Could not look" and "looked and found
# nothing" print identically unless something separates them.
#
# ssh is SHADOWED rather than dialled, so this arm needs no network and cannot
# take 10 seconds. 255 is ssh's own-failure code.
mkdir -p "${TMP}/w7"
FAKE_SSH_DIR="${TMP}/fakebin"
mkdir -p "$FAKE_SSH_DIR"
cat > "${FAKE_SSH_DIR}/ssh" <<'SSHEOF'
#!/usr/bin/env bash
# Stands in for an unreachable host: ssh's own failure code, nothing on stdout.
echo "ssh: connect to host port 22: Operation timed out" >&2
exit 255
SSHEOF
chmod +x "${FAKE_SSH_DIR}/ssh"
[[ -x "${FAKE_SSH_DIR}/ssh" ]] || cannot "could not create the ssh stand-in; arm 8 would measure the real network instead."

OUT="$(PATH="${FAKE_SSH_DIR}:${PATH}" OSTLER_POST_WALK_QA="$NOOP_WRITER" \
    OSTLER_WALK_RECORD_DIR="${TMP}/w7" \
    bash "$RECORDER" --host stub@example.invalid --walk-verdict 0 2>&1)"
RC=$?
if [[ "$RC" -eq 2 ]] && printf '%s' "$OUT" | /usr/bin/grep -q 'NOT an absent version'; then
    pass "an unreachable box is CANNOT-RUN and names the network as the reason"
elif [[ "$RC" -eq 3 ]]; then
    fail "an unreachable box was reported DECLINED. That states, falsely and confidently, that this was a repo walk with nothing to record. Output: ${OUT}"
else
    fail "an unreachable box gave rc=${RC} without naming the network. Output: ${OUT}"
fi

printf '\n---- %s arms, %s failed ----\n' "$ARMS" "$FAILURES"

# A ZERO DENOMINATOR READS AS SUCCESS. If every arm were skipped this would
# print "0 arms, 0 failed" and exit 0, which is the shape of a suite that
# measured nothing.
if [[ "$ARMS" -lt 11 ]]; then
    cannot "only ${ARMS} arms ran; this suite has 12. Something skipped, and a partial suite is not a pass."
fi

[[ "$FAILURES" -eq 0 ]] || exit 1
exit 0
