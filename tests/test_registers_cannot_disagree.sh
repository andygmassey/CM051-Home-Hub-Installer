#!/usr/bin/env bash
# tests/test_registers_cannot_disagree.sh
# ===========================================================================
# CM051 #1772, part 2. Drives scripts/verify_register_agreement.py, which is
# the gate that stops two registers grading the same box-walk probe in
# opposite directions without anybody noticing.
#
# WHAT THIS FILE ADDS OVER THE GATE'S OWN --self-test. The self-test builds
# synthetic registers. These arms drive the gate over THE REAL ONES in this
# repo, and then over copies of the real ones with one field changed. A gate
# that works on fixtures and not on the tree it ships in is the shape this
# repo keeps rediscovering.
#
# BASH 3.2 AND BASH 5. macOS ships bash 3.2, which cannot parse a literal `#`
# inside a command substitution, so there are no comments inside any $( ).
# `bash -n` does not descend into command substitutions, so that is checked by
# running the file, not by linting it.
# ===========================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_register_agreement.py"
SCOPE="${REPO_ROOT}/scripts/walk_promote_scope.tsv"
MANIFESTS="${REPO_ROOT}/cut-manifests"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  [pass] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }

if ! command -v python3 >/dev/null 2>&1; then
    echo "  [CANNOT-RUN] no python3 on this machine, so the gate could not be"
    echo "               executed. Nothing was measured; this is not a pass."
    exit 2
fi
if [ ! -f "$GATE" ]; then
    echo "  [CANNOT-RUN] the gate is missing at ${GATE}. Nothing was measured."
    exit 2
fi
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "  [CANNOT-RUN] PyYAML is not importable, so the cut register cannot"
    echo "               be read. Nothing was measured; this is not a pass."
    exit 2
fi

TMPROOT="$(mktemp -d -t regagree-XXXXXX)" || {
    echo "  [CANNOT-RUN] mktemp failed; no copy of the registers could be staged"
    exit 2
}
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

stage() {
    local dest="$1"
    mkdir -p "${dest}/scripts" "${dest}/cut-manifests"
    cp "$SCOPE" "${dest}/scripts/walk_promote_scope.tsv"
    cp "${MANIFESTS}/permanent.yaml" "${dest}/cut-manifests/permanent.yaml"
    cp "${MANIFESTS}"/v*.yaml "${dest}/cut-manifests/" 2>/dev/null
}

echo "=== registers cannot disagree (CM051 #1772) ==="

# ---------------------------------------------------------------------------
# ARM 1. The gate's own negative control passes. 14 arms, each proving one
# refusal fires, plus a positive control so the refusals are not a stuck
# needle. Without this arm every assertion below could be satisfied by a gate
# that refuses unconditionally.
# ---------------------------------------------------------------------------
OUT1="$(python3 "$GATE" --self-test 2>&1)"
RC1=$?
if [ "$RC1" -eq 0 ]; then
    pass "(1) the gate's own 14-arm negative control passes: $(printf '%s' "$OUT1" | /usr/bin/grep -c 'ok ') arm(s) reported ok"
else
    bad "(1) the gate's --self-test exited ${RC1}; it has NOT demonstrated it can refuse"
    printf '%s\n' "$OUT1" | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# ARM 2. The real registers in this repo agree, or every disagreement carries
# a live acknowledgement. This is the arm that goes red when somebody adds a
# box_walk_probe row for an advisory probe, or flips a scope word.
# ---------------------------------------------------------------------------
OUT2="$(python3 "$GATE" --cm051-dir "$REPO_ROOT" 2>&1)"
RC2=$?
if [ "$RC2" -eq 0 ]; then
    pass "(2) the REAL registers in this repo pass: $(printf '%s' "$OUT2" | /usr/bin/grep 'row(s) agree' | sed 's/^EXAMINED: //')"
else
    bad "(2) the real registers do not agree (rc=${RC2})"
    printf '%s\n' "$OUT2" | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# ARM 3. APPARATUS CONTROL, taken BEFORE the mutations below are believed.
# The real registers must actually CONTAIN an acknowledgement and an advisory
# row, or arms 4 and 5 mutate nothing and their reds mean nothing.
# ---------------------------------------------------------------------------
N_ACK="$(/usr/bin/grep -c 'promote_scope_disagreement:' "${MANIFESTS}/permanent.yaml")"
N_ADV="$(awk -F'\t' '$2=="advisory"{n++} END{print n+0}' "$SCOPE")"
N_BLK="$(awk -F'\t' '$2=="blocking"{n++} END{print n+0}' "$SCOPE")"
if [ "${N_ACK:-0}" -ge 1 ] && [ "${N_ADV:-0}" -ge 1 ] && [ "${N_BLK:-0}" -ge 1 ]; then
    pass "(3) apparatus: permanent.yaml carries ${N_ACK} acknowledgement(s); the scope file declares ${N_ADV} advisory and ${N_BLK} blocking probe(s), so the mutations below have something to change"
else
    bad "(3) apparatus: ack=${N_ACK} advisory=${N_ADV} blocking=${N_BLK}. A zero here means the mutations below change nothing and their verdicts are unmeasured rather than caught"
fi

# ---------------------------------------------------------------------------
# ARM 4. MUTATION: delete every acknowledgement from a copy of the real
# registers. The disagreements are then unacknowledged, and the gate must FAIL
# naming them. This is the defect #1772 filed, reconstructed from the tree.
# ---------------------------------------------------------------------------
M4="${TMPROOT}/m4"
stage "$M4"
python3 - "$M4" <<'PYEOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
removed = 0
for p in (root / "cut-manifests").glob("*.yaml"):
    lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
    out, i = [], 0
    while i < len(lines):
        if lines[i].strip() == "promote_scope_disagreement:":
            indent = len(lines[i]) - len(lines[i].lstrip())
            removed += 1
            i += 1
            while i < len(lines):
                s = lines[i]
                if not s.strip():
                    i += 1
                    continue
                if (len(s) - len(s.lstrip())) <= indent:
                    break
                i += 1
            continue
        out.append(lines[i])
        i += 1
    p.write_text("".join(out), encoding="utf-8")
sys.stderr.write("removed %d acknowledgement block(s)\n" % removed)
PYEOF
M4_REMOVED="$(python3 - "$M4" <<'PYEOF'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
n = sum(t.read_text(encoding="utf-8").count("promote_scope_disagreement:")
        for t in (root / "cut-manifests").glob("*.yaml"))
print(n)
PYEOF
)"
if [ "${M4_REMOVED:-1}" -ne 0 ]; then
    bad "(4) the mutation did not apply: ${M4_REMOVED} acknowledgement(s) survived, so this arm tested nothing"
else
    OUT4="$(python3 "$GATE" --cm051-dir "$M4" 2>&1)"
    RC4=$?
    if [ "$RC4" -eq 1 ] && printf '%s' "$OUT4" | /usr/bin/grep -q 'REGISTER DISAGREEMENT with no acknowledgement'; then
        pass "(4) MUTATION: with the acknowledgements deleted the gate FAILs (rc=1) naming the unacknowledged disagreements"
    else
        bad "(4) MUTATION: acknowledgements deleted and the gate returned rc=${RC4} without naming an unacknowledged disagreement"
        printf '%s\n' "$OUT4" | tail -20 | sed 's/^/        /'
    fi
fi

# ---------------------------------------------------------------------------
# ARM 5. MUTATION, THE OTHER DIRECTION: the acknowledgements stay, but their
# expiry is moved to a cut that has already arrived. An acknowledgement that
# cannot expire is the thing #1772 says lets a defect ship forever, so the
# expiry has to be watched failing, not merely written.
# ---------------------------------------------------------------------------
M5="${TMPROOT}/m5"
stage "$M5"
CURRENT_CUT="$(ls "${M5}"/cut-manifests/v*.yaml | xargs -n1 basename | sed 's/\.yaml$//' | sort -V | tail -1)"
python3 - "$M5" "$CURRENT_CUT" <<'PYEOF'
import pathlib, sys
root, cut = pathlib.Path(sys.argv[1]), sys.argv[2]
changed = 0
for p in (root / "cut-manifests").glob("*.yaml"):
    text = p.read_text(encoding="utf-8")
    new = text.replace('until_cut: "v1.0.100"', 'until_cut: "%s"' % cut)
    if new != text:
        changed += new.count('until_cut: "%s"' % cut)
        p.write_text(new, encoding="utf-8")
sys.stderr.write("moved %d expiry line(s)\n" % changed)
PYEOF
M5_CHANGED="$(python3 - "$M5" "$CURRENT_CUT" <<'PYEOF'
import pathlib, sys
root, cut = pathlib.Path(sys.argv[1]), sys.argv[2]
print(sum(t.read_text(encoding="utf-8").count('until_cut: "%s"' % cut)
          for t in (root / "cut-manifests").glob("*.yaml")))
PYEOF
)"
if [ "${M5_CHANGED:-0}" -lt 1 ]; then
    bad "(5) the expiry mutation did not apply (${M5_CHANGED} row(s) moved to ${CURRENT_CUT}); this arm tested nothing"
else
    OUT5="$(python3 "$GATE" --cm051-dir "$M5" 2>&1)"
    RC5=$?
    if [ "$RC5" -eq 1 ] && printf '%s' "$OUT5" | /usr/bin/grep -q 'EXPIRED acknowledgement'; then
        pass "(5) MUTATION: ${M5_CHANGED} acknowledgement(s) moved to expire at ${CURRENT_CUT} and the gate FAILs (rc=1) calling them EXPIRED"
    else
        bad "(5) MUTATION: expiry moved to the current cut and the gate returned rc=${RC5} without reporting an expiry"
        printf '%s\n' "$OUT5" | tail -20 | sed 's/^/        /'
    fi
fi

# ---------------------------------------------------------------------------
# ARM 6. CONTROL FOR ARM 5. Moving the expiry FORWARD, to a cut that has not
# happened, must still PASS. Without this, arm 5 would be satisfied by a gate
# that failed on any edit to the until_cut line.
# ---------------------------------------------------------------------------
M6="${TMPROOT}/m6"
stage "$M6"
python3 - "$M6" <<'PYEOF'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for p in (root / "cut-manifests").glob("*.yaml"):
    t = p.read_text(encoding="utf-8")
    p.write_text(t.replace('until_cut: "v1.0.100"', 'until_cut: "v1.0.101"'),
                 encoding="utf-8")
PYEOF
OUT6="$(python3 "$GATE" --cm051-dir "$M6" 2>&1)"
RC6=$?
if [ "$RC6" -eq 0 ]; then
    pass "(6) CONTROL: the same acknowledgements expiring at a FUTURE cut still pass, so arm 5 measures the expiry and not the edit"
else
    bad "(6) CONTROL: a future expiry returned rc=${RC6}; arm 5's red may be an artefact of editing the line at all"
    printf '%s\n' "$OUT6" | tail -12 | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# ARM 7. FAIL CLOSED. With the promote register removed the gate must report
# CANNOT-RUN (2), which is neither a pass nor a defect. verify_walk_record.sh
# fails closed on the same absence at :52 and this gate must not be the one
# reader of that file which shrugs.
# ---------------------------------------------------------------------------
M7="${TMPROOT}/m7"
stage "$M7"
rm -f "${M7}/scripts/walk_promote_scope.tsv"
OUT7="$(python3 "$GATE" --cm051-dir "$M7" 2>&1)"
RC7=$?
if [ "$RC7" -eq 2 ] && printf '%s' "$OUT7" | /usr/bin/grep -q 'CANNOT-RUN'; then
    pass "(7) FAIL CLOSED: an absent promote register is CANNOT-RUN (rc=2), not agreement and not a defect"
else
    bad "(7) an absent promote register returned rc=${RC7}, expected 2 (CANNOT-RUN)"
    printf '%s\n' "$OUT7" | tail -8 | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
# ARM 8. THE GATE IS ACTUALLY INVOKED. A gate nothing runs is a gate that
# measures nothing, and that is this repo's most expensive failure shape:
# people_seed_and_retrieval sat one level outside the walk's collector and
# fourteen cuts reported a probe that never ran.
#
# `-w` on every count, not a bare substring: renaming the gate to
# verify_register_agreement_old.py would leave a bare grep reporting the same
# number over a gate nothing calls.
# ---------------------------------------------------------------------------
WF_DIR="${REPO_ROOT}/.github/workflows"
W_RUN="$(/usr/bin/grep -rlw 'scripts/verify_register_agreement.py' "$WF_DIR" 2>/dev/null | wc -l | tr -d ' ')"
W_CTL="$(/usr/bin/grep -rlw 'scripts/verify_cut_manifest.py' "$WF_DIR" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${W_CTL:-0}" -lt 1 ]; then
    bad "(8) apparatus: the control found ${W_CTL} workflow(s) naming verify_cut_manifest.py. A zero there means the search cannot read ${WF_DIR}, so the count below is unmeasured rather than absent"
elif [ "${W_RUN:-0}" -ge 1 ]; then
    pass "(8) the gate is invoked by ${W_RUN} workflow(s) (control: ${W_CTL} name verify_cut_manifest.py, so the search resolves)"
else
    bad "(8) NO workflow invokes scripts/verify_register_agreement.py (control: ${W_CTL}). A gate nothing runs measures nothing."
fi

# ---------------------------------------------------------------------------
# ARM 9. THIS TEST IS ITSELF INVOKED. Same reasoning one level up.
# ---------------------------------------------------------------------------
T_RUN="$(/usr/bin/grep -rlw 'tests/test_registers_cannot_disagree.sh' "$WF_DIR" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${W_CTL:-0}" -lt 1 ]; then
    bad "(9) apparatus control failed, see arm 8; this count is unmeasured"
elif [ "${T_RUN:-0}" -ge 1 ]; then
    pass "(9) this test is invoked by ${T_RUN} workflow(s)"
else
    bad "(9) NO workflow invokes this test file"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
