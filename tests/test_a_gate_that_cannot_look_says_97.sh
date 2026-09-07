#!/usr/bin/env bash
# A rollforward gate that declares CANNOT-RUN must exit 97, not 1.
#
# 97 is the runner's vocabulary for "I could not look", as distinct from "the
# defect is present". bin/rollforward_gate.sh already carries the history: nine
# gates once died on unset directory variables and every one was reported as a
# defect in the PRODUCT. Two of them said, in English, in the log, that they
# were not -- and the harness had no way to hear it. 97 was introduced so it
# could.
#
# MEASURED 2026-09-07: 25 of the 28 gate bodies exit 97 on their cannot-run arm.
# ONE did not -- v1018-D011, which exited 1. That is the gate that closes #1619,
# so on any box without a compiled wiki it reported
#
#     ROLLFORWARD RED -- 1 measured failure(s), 0 CANNOT-RUN
#
# when the truthful line is
#
#     ROLLFORWARD RED -- 0 measured failure(s), 1 CANNOT-RUN
#
# Both are RED and neither ships a cut, so this never failed OPEN. What it did
# was tell a reader the kinship defect was still present on a box where nothing
# had been examined at all -- and #1619 is closed on exactly that reading.
#
# WHY A REGISTRY LINT RATHER THAN A RUN. Running all 28 needs a box, an
# artefact and sibling checkouts. The property is decidable from the text: a
# body that prints CANNOT-RUN must also carry `exit 97`.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${REPO}/cuts/DEFECTS_ROLLFORWARD.md"

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

echo "== a gate that cannot look says 97 =="

[ -r "$REG" ] || { cant "cuts/DEFECTS_ROLLFORWARD.md unreadable -- NOTHING was examined"; echo; exit 2; }

read -r total declaring offenders < <(python3 - "$REG" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r'```gate id=(\S+)[^\n]*\n(.*?)```', s, re.S)
def code(b):
    # STRIP COMMENTS FIRST. My own fix for D011 explained itself in a comment
    # that contains the words "exit 97", and the detector matched THAT -- so a
    # mutation putting the real arm back to `exit 1` still read clean. A grep
    # that matches prose is not measuring code.
    return "\n".join(l for l in b.splitlines() if not l.lstrip().startswith("#"))
declaring = [(g, b) for g, b in blocks if re.search(r'CANNOT[ -]RUN', code(b))]
off = [g for g, b in declaring if not re.search(r'exit\s+97', code(b))]
print(len(blocks), len(declaring), ",".join(off) or "-")
PY
)

if [ "${total:-0}" -lt 10 ]; then
    cant "parsed only ${total:-0} gate block(s). A registry that small is a broken parse, not a small registry."
    printf '\n== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"; exit 2
fi
ok "parsed ${total} gate block(s), ${declaring} of which declare CANNOT-RUN"

if [ "${declaring:-0}" -eq 0 ]; then
    bad "ZERO gates declare CANNOT-RUN. That is not a clean registry, it is a broken predicate -- the runner's own history says nine of them once did."
elif [ "$offenders" = "-" ]; then
    ok "every gate that declares CANNOT-RUN exits 97"
else
    bad "these declare CANNOT-RUN but do NOT exit 97, so the runner scores them as MEASURED PRODUCT FAILURES: ${offenders}"
fi

# ── CONTROL THAT MUST FIRE ────────────────────────────────────────────────
# Without it, a detector that matched nothing would look identical to a clean
# registry -- the exact shape this gate exists to catch elsewhere.
CTRL="$(mktemp)"; trap 'rm -f "$CTRL"' EXIT
cat > "$CTRL" <<'FIX'
```gate id=fixture-bad expect=0 runs-on=box
[ -d "$X" ] || { echo "CANNOT RUN: no X"; exit 1; }
```
FIX
read -r ct cd co < <(python3 - "$CTRL" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r'```gate id=(\S+)[^\n]*\n(.*?)```', s, re.S)
def code(b):
    # STRIP COMMENTS FIRST. My own fix for D011 explained itself in a comment
    # that contains the words "exit 97", and the detector matched THAT -- so a
    # mutation putting the real arm back to `exit 1` still read clean. A grep
    # that matches prose is not measuring code.
    return "\n".join(l for l in b.splitlines() if not l.lstrip().startswith("#"))
declaring = [(g, b) for g, b in blocks if re.search(r'CANNOT[ -]RUN', code(b))]
off = [g for g, b in declaring if not re.search(r'exit\s+97', code(b))]
print(len(blocks), len(declaring), ",".join(off) or "-")
PY
)
if [ "$co" = "fixture-bad" ]; then
    ok "CONTROL: a synthetic gate that declares CANNOT-RUN and exits 1 IS flagged"
else
    bad "CONTROL FAILED: the detector did not flag an obvious offender (got '${co}'), so every verdict above is meaningless"
fi

# ── CONTROL THAT MUST NOT FIRE ────────────────────────────────────────────
cat > "$CTRL" <<'FIX'
```gate id=fixture-good expect=0 runs-on=box
[ -d "$X" ] || { echo "CANNOT RUN: no X"; exit 97; }
```
FIX
read -r gt gd go < <(python3 - "$CTRL" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r'```gate id=(\S+)[^\n]*\n(.*?)```', s, re.S)
def code(b):
    # STRIP COMMENTS FIRST. My own fix for D011 explained itself in a comment
    # that contains the words "exit 97", and the detector matched THAT -- so a
    # mutation putting the real arm back to `exit 1` still read clean. A grep
    # that matches prose is not measuring code.
    return "\n".join(l for l in b.splitlines() if not l.lstrip().startswith("#"))
declaring = [(g, b) for g, b in blocks if re.search(r'CANNOT[ -]RUN', code(b))]
off = [g for g, b in declaring if not re.search(r'exit\s+97', code(b))]
print(len(blocks), len(declaring), ",".join(off) or "-")
PY
)
if [ "$go" = "-" ]; then
    ok "CONTROL: the corrected form reads clean, so this gate does not reject its own fix"
else
    bad "CONTROL FAILED: an exit-97 gate is still flagged; this would reject the correct code"
fi

echo
printf '== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"
[ "$CANT" -gt 0 ] && exit 2
[ "$FAIL" -gt 0 ] && exit 1
exit 0
