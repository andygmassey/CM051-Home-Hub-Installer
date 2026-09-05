#!/usr/bin/env bash
# The cron reader must see BOTH TOML spellings of the same job list.
#
# WHY THIS EXISTS. MEASURED on the v1.0.68 artefact walk, archie@.240,
# 2026-09-05. The SAME BOX passed install_manifest_complete at 08:10Z and
# FAILED it at 08:25Z:
#
#     FAIL: 2 required subject(s) MISSING:
#       - cron_job evening-wrap (#619) -- required but NOT present
#       - cron_job morning-brief (#619) -- required but NOT present
#
# Nothing had removed them. Both jobs were present and enabled the whole time.
# The daemon rewrote config.toml at 08:19:47Z and serialised the same two jobs
# as an INLINE TABLE ARRAY instead of as section headers:
#
#     jobs = [{ id = "morning-brief", ... }, { id = "evening-wrap", ... }]
#
# The reader was a LINE SCANNER looking for the literal string "[[cron.jobs]]".
# Those are two spellings of one TOML value, and it could only see one.
#
# ⚠️ THE FALSE FAIL IS THE LESS DANGEROUS HALF. cron_job is an ENUMERABLE type
# with BOTH directions enforced, so a zero present-set also makes the
# "present but undeclared" arm vacuous -- it finds nothing to report because it
# can see nothing at all. A ZERO DENOMINATOR READS AS SUCCESS the other way.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/scripts/verify_install_manifest.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no verifier at ${SUBJECT}" >&2; exit 2; }

# The reader needs tomllib. Under an older interpreter it is CANNOT-RUN by
# design, and so is this test -- asserting nothing is not the same as passing.
PY=""
for c in python3.13 python3.12 python3.11 python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -c 'import tomllib' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "CANNOT-RUN: no interpreter with tomllib on PATH; the reader needs 3.11+." >&2; exit 2; }

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Both fixtures declare THE SAME TWO JOBS. Synthetic throughout: the number is
# the reserved UK drama range, so nothing here is a real contact.
cat > "${WORK}/headers.toml" <<'TOML'
[cron]
enabled = true

[[cron.jobs]]
id = "morning-brief"
enabled = true
[cron.jobs.delivery]
to = "+447700900000"

[[cron.jobs]]
id = "evening-wrap"
enabled = true
TOML

cat > "${WORK}/inline.toml" <<'TOML'
[cron]
jobs = [{ enabled = true, id = "morning-brief", delivery = { to = "+447700900000" } }, { enabled = true, id = "evening-wrap" }]
enabled = true
TOML

cat > "${WORK}/nojobs.toml" <<'TOML'
[cron]
enabled = true
TOML

printf 'not toml at all {{{\n' > "${WORK}/broken.toml"

_read() {  # <config> -> sorted ids, or CANNOT-RUN, or ERROR
    "$PY" - "$SUBJECT" "$1" <<'PYEOF' 2>/dev/null
# COMPILE FROM SOURCE, NEVER THROUGH THE IMPORT CACHE.
# importlib.exec_module writes and then REUSES scripts/__pycache__/*.pyc, and
# during this file's own mutation run that cache served the MUTATED module
# after the source had been restored: the suite reported 3 failures on a
# provably clean tree. A stale .pyc can hide a fix and can equally hide a
# regression, so the subject is compiled from the bytes on disk every time.
import sys, types
sys.dont_write_bytecode = True
src = open(sys.argv[1], encoding="utf-8").read()
m = types.ModuleType("v")
m.__file__ = sys.argv[1]
exec(compile(src, sys.argv[1], "exec"), m.__dict__)
try:
    print(",".join(sorted(m.present_cron_jobs(sys.argv[2]))))
except m.CannotRun:
    print("CANNOT-RUN")
except Exception:
    print("ERROR")
PYEOF
}

echo "── subject: this tree (interpreter ${PY}, $("$PY" -V 2>&1)) ──"

EXPECT="evening-wrap,morning-brief"

r="$(_read "${WORK}/headers.toml")"
[ "$r" = "$EXPECT" ] && ok "the [[cron.jobs]] header spelling reads both ids" \
                     || bad "header spelling gave '${r}', expected '${EXPECT}'"

r="$(_read "${WORK}/inline.toml")"
[ "$r" = "$EXPECT" ] && ok "the INLINE TABLE ARRAY spelling reads both ids -- the shape that produced the false FAIL" \
                     || bad "inline spelling gave '${r}', expected '${EXPECT}'. This is the measured defect."

# The property, stated as itself: the two spellings must agree.
a="$(_read "${WORK}/headers.toml")"; b="$(_read "${WORK}/inline.toml")"
[ "$a" = "$b" ] && ok "the two spellings AGREE, which is the actual property" \
                || bad "the spellings disagree: headers='${a}' inline='${b}'"

# A real absence must stay a real absence, or the fix would just be permissive.
r="$(_read "${WORK}/nojobs.toml")"
[ "$r" = "" ] && ok "a [cron] section with NO jobs is an empty set, not an error and not a phantom" \
              || bad "a config with no jobs gave '${r}', expected empty"

# CANNOT-RUN must stay reachable and must NOT be spelled as an empty set.
r="$(_read "${WORK}/broken.toml")"
[ "$r" = "CANNOT-RUN" ] && ok "an UNPARSEABLE config is CANNOT-RUN, not an empty job list" \
                       || bad "an unparseable config gave '${r}'. A parse failure read as empty is the false zero this fix exists to remove."

r="$(_read "${WORK}/absent.toml")"
[ "$r" = "CANNOT-RUN" ] && ok "an ABSENT config is CANNOT-RUN, not an empty job list" \
                       || bad "an absent config gave '${r}'"

# ── NEGATIVE CONTROL, pinned to the blob that SHIPPED the line scanner ──
# be7ab01f is CM051 main at the time the v1.0.68 walk produced the false FAIL.
# Pinned to a fixed sha, never a branch: a control reading origin/main inverts
# the moment this fix merges.
_CONTROL_SHA="be7ab01f"
echo "── negative control: ${_CONTROL_SHA} (the tree that reported the false FAIL) ──"
CTL="${WORK}/old.py"
if ! git -C "$REPO" show "${_CONTROL_SHA}:scripts/verify_install_manifest.py" > "$CTL" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:scripts/verify_install_manifest.py is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
    echo "  as a passing control." >&2
    exit 2
fi

_read_ctl() {
    "$PY" - "$CTL" "$1" <<'PYEOF' 2>/dev/null
# COMPILE FROM SOURCE, NEVER THROUGH THE IMPORT CACHE.
# importlib.exec_module writes and then REUSES scripts/__pycache__/*.pyc, and
# during this file's own mutation run that cache served the MUTATED module
# after the source had been restored: the suite reported 3 failures on a
# provably clean tree. A stale .pyc can hide a fix and can equally hide a
# regression, so the subject is compiled from the bytes on disk every time.
import sys, types
sys.dont_write_bytecode = True
src = open(sys.argv[1], encoding="utf-8").read()
m = types.ModuleType("v")
m.__file__ = sys.argv[1]
exec(compile(src, sys.argv[1], "exec"), m.__dict__)
try:
    print(",".join(sorted(m.present_cron_jobs(sys.argv[2]))))
except m.CannotRun:
    print("CANNOT-RUN")
except Exception:
    print("ERROR")
PYEOF
}

# CONTROL ON THE CONTROL FIRST. If the old reader could not read the HEADER
# spelling either, then its empty answer on the inline one would say nothing
# about spellings -- it would just be broken, and this control would prove
# nothing about the defect.
r="$(_read_ctl "${WORK}/headers.toml")"
[ "$r" = "$EXPECT" ] && ok "CONTROL ON THE CONTROL: ${_CONTROL_SHA} reads the HEADER spelling fine, so the spelling is the discriminator" \
                     || bad "${_CONTROL_SHA} gave '${r}' on the header spelling; it is broken for some other reason and proves nothing here"

r="$(_read_ctl "${WORK}/inline.toml")"
[ "$r" = "" ] && ok "control ${_CONTROL_SHA}: the inline spelling reads as ZERO jobs, reproducing the false FAIL from the v1.0.68 walk" \
              || bad "control ${_CONTROL_SHA} gave '${r}' on the inline spelling; this harness is not measuring the defect"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
