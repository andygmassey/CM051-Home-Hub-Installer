#!/usr/bin/env bash
#
# test_walk_record_binds_the_harness.sh
#
# #1145 follow-up -- the READER half of harness_commit.
#
# artefact_sha256 binds WHAT WAS WALKED. Until harness_commit, nothing bound
# WHAT DID THE WALKING, and the gap paid out inside eighteen minutes on
# 2026-08-30: walks/v1.0.52.tsv merged recording no_unexpected_egress as
# FAILED, and #1299 then rewrote that probe (+246 -17, one file). A re-walk of
# the SAME DMG that now passes it would be indistinguishable from a product
# fix, because both records carry an identical artefact_sha256.
#
# This is the argument artefact_sha256 itself won, one level up. The record's
# own header says a version does not identify a build, because "1.0.50" named
# eleven distinct assemblies. By identical logic a probe NAME does not
# identify a probe.
#
# WHY THE ARMS BELOW USE A **CLEAN** FIXTURE, AND WHY THAT IS NOT A DODGE:
# the check lives inside `if [[ "$VERDICT" == "CLEAN" ]]`, by that guard's own
# stated rule -- evidence of badness outranks absence of evidence, so a FAILED
# or PARTIAL record keeps its own exit code and only a CLEAN claim has to
# prove which build it describes. A failed walk publishes nothing and need not
# prove which harness ran; a CLEAN walk authorises the customer download and
# must prove both halves. I lost real time to this: every arm of my first
# mutation run used the FAILED v1.0.52 record, all three returned identical
# exit codes for unrelated reasons, and I read that as "the check does not
# fire" rather than "my specimen cannot reach it". A uniform result across
# arms built to disagree is a broken measurement, not a finding about the
# subject.
#
# ARM 4 IS THE ANTI-VACUITY ARM. Arms 1-3 could all pass for reasons having
# nothing to do with the harness block, so arm 4 neutralises that block in a
# COPY of the gate and requires arm 1's refusal to DISAPPEAR. If its anchors
# have moved this exits 2 and says so -- re-point the anchor, never delete
# the arm.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_walk_record.sh"
FAKE_SHA="$(printf 'ostler harness citest' | shasum -a 256 | cut -d' ' -f1)"
FAKE_HARNESS="0123456789abcdef0123456789abcdef01234567"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/walks"

pass=0; fail=0
ok()   { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
cannot(){ printf '\033[0;33mCANNOT-RUN\033[0m: %s\n' "$1" >&2; exit 2; }

[ -x "$GATE" ] || [ -f "$GATE" ] || cannot "no gate at ${GATE}"

# A CLEAN record that clears every check ABOVE the harness block, so the only
# thing varying between arms is the harness fields themselves.
mkrec() {
    local v="$1" f="$TMP/walks/$1.tsv"; shift
    {
        printf 'version\t%s\n' "$v"
        printf 'version_source\tmeasured(CFBundleShortVersionString, matches argument)\n'
        printf 'artefact_sha256\t%s\n' "$FAKE_SHA"
        printf 'artefact_sha256_source\tmeasured(shasum -a 256 on the walked box)\n'
        printf 'walked_at\t2026-01-01T00:00:00Z\n'
        printf 'box_fp\tcitestcitest0000\n'
        printf 'counts_scope\tbox_walk_probes_only(phase1)\n'
        printf 'pass\t14\n'; printf 'fail\t0\n'
        printf 'cannot_run\t0\n'; printf 'broken\t0\n'
        printf 'verdict\tCLEAN\n'; printf 'qa_exit\t0\n'
        for l in "$@"; do printf '%b\n' "$l"; done
    } > "$f"
}

run_gate() { # $1=gate path  $2=version -> echoes rc
    OSTLER_WALK_RECORD_DIR="$TMP/walks" bash "$1" "$2" "$FAKE_SHA" >"$TMP/out" 2>&1
    echo $?
}

echo "harness_commit binding -- CLEAN fixtures, one variable per arm"

# ── ARM 1: the field is absent ───────────────────────────────────────────────
mkrec v0.0.0-h1
rc="$(run_gate "$GATE" v0.0.0-h1)"
if [ "$rc" = 2 ] && grep -q 'no harness_commit field' "$TMP/out"; then
    ok "1 absent harness_commit -> CANNOT-RUN (rc=2), and the message names the field"
else
    bad "1 absent harness_commit -> expected rc=2 naming the field, got rc=${rc}"
    sed 's/^/        /' "$TMP/out" | head -4
fi

# ── ARM 2: present, but the harness was dirty when it ran ────────────────────
mkrec v0.0.0-h2 "harness_commit\t${FAKE_HARNESS}" \
                "harness_commit_source\tdirty(harness had uncommitted changes)"
rc="$(run_gate "$GATE" v0.0.0-h2)"
if [ "$rc" = 2 ] && grep -q 'harness_commit_source' "$TMP/out"; then
    ok "2 dirty(...) source -> CANNOT-RUN (rc=2); an unreproducible instrument is not evidence"
else
    bad "2 dirty(...) source -> expected rc=2 naming the source, got rc=${rc}"
    sed 's/^/        /' "$TMP/out" | head -4
fi

# ── ARM 3: THE CONTROL. Without this, arms 1 and 2 prove only that the gate
# refuses things, not that it refuses THESE things. A gate that refuses
# everything passes both arms above and is worthless.
mkrec v0.0.0-h3 "harness_commit\t${FAKE_HARNESS}" \
                "harness_commit_source\tmeasured(git rev-parse HEAD, harness paths clean)"
rc="$(run_gate "$GATE" v0.0.0-h3)"
if [ "$rc" = 0 ] && ! grep -qi 'harness' "$TMP/out"; then
    ok "3 CONTROL clean measured sha -> rc=0 and the harness check is SILENT"
else
    bad "3 CONTROL -> expected rc=0 with no harness output, got rc=${rc}"
    sed 's/^/        /' "$TMP/out" | head -6
fi

# ── ARM 4: ANTI-VACUITY ──────────────────────────────────────────────────────
# Neutralise the record-read so the block can never see an absent field, then
# require arm 1's refusal to vanish. If it does not, arm 1 was refusing for
# some other reason and arms 1-2 are worthless.
MUT="$TMP/gate-mutant.sh"
ANCHOR='HARNESS_COMMIT="$(field harness_commit)"'
grep -qF "$ANCHOR" "$GATE" || cannot "anti-vacuity anchor not found in ${GATE}: ${ANCHOR}. The block moved or was renamed. RE-POINT THIS ANCHOR, do not delete the arm -- without it, arms 1 and 2 are unproven."
sed -e "s|^HARNESS_COMMIT=\"\$(field harness_commit)\"|HARNESS_COMMIT=\"${FAKE_HARNESS}\"|" \
    -e 's|^HARNESS_COMMIT_SOURCE="$(field harness_commit_source)"|HARNESS_COMMIT_SOURCE="measured(neutralised by anti-vacuity arm)"|' \
    "$GATE" > "$MUT"

if ! grep -qF "$FAKE_HARNESS" "$MUT"; then
    cannot "the mutation did not take: ${MUT} does not contain the injected sha. The sed anchors are stale."
fi

rc="$(run_gate "$MUT" v0.0.0-h1)"
if [ "$rc" = 0 ]; then
    ok "4 ANTI-VACUITY: neutralising the record-read makes arm 1 PASS, so arm 1's refusal was caused by this block"
else
    bad "4 ANTI-VACUITY: arm 1 still refuses (rc=${rc}) with the harness read neutralised -- arms 1 and 2 are NOT evidence about harness_commit"
    sed 's/^/        /' "$TMP/out" | head -6
fi

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
echo "HARNESS BINDING PROVED: the gate refuses an unidentified instrument, accepts an identified one, and arm 4 shows the refusals come from that block."
