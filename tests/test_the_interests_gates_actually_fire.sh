#!/usr/bin/env bash
#
# tests/test_the_interests_gates_actually_fire.sh
#
# THE TWO INTERESTS GATES MUST BE ABLE TO GO RED, AND EACH ARM MUST BE THE ONE
# THAT MAKES THEM.
#
# A test that passes proves nothing on its own: it passes identically when its
# subject is fixed and when its predicate is broken. So every assertion in
#
#     tests/test_the_interests_domain_is_reachable.py
#     tests/test_an_empty_interests_page_says_which_empty.py
#
# is paired here with a MUTANT that should make it fail, and the mutant is
# PROVEN APPLIED before the gate is run. A mutant that did not apply looks
# exactly like one that was not caught: both print "test passed".
#
# Everything happens in a SANDBOX COPY of vendor/cm059_editor and tests/. The
# working tree is never mutated, so an interrupted run cannot leave a poisoned
# file behind.
#
# CONTROLS
#   - the UNMUTATED sandbox must exit 0 for both gates. Without it, "every
#     mutant was caught" is also what a gate that always fails would print.
#   - every mutant's replacement text is grepped for in the sandbox file after
#     the edit, and a mutant that did not apply is a CANNOT-RUN, not a pass.
#
# EXIT CODES
#   0  the unmutated controls pass AND every mutant was caught
#   1  a mutant survived (the gate cannot see that defect) or a control failed
#   2  CANNOT-RUN: no python3, missing sources, or a mutant that would not apply
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY3="$(command -v python3 || true)"
[ -n "${PY3}" ] || { echo "CANNOT-RUN: no python3 on PATH" >&2; exit 2; }

for f in \
  "${REPO}/vendor/cm059_editor/compiler/interest_profile.py" \
  "${REPO}/vendor/cm059_editor/compiler/frontpage.py" \
  "${REPO}/vendor/cm059_editor/compiler/render_html.py" \
  "${REPO}/vendor/cm059_editor/compiler/emit_artefact.py" \
  "${REPO}/tests/test_the_interests_domain_is_reachable.py" \
  "${REPO}/tests/test_an_empty_interests_page_says_which_empty.py" ; do
  [ -f "${f}" ] || { echo "CANNOT-RUN: missing ${f}" >&2; exit 2; }
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/interests_mutants.XXXXXX")" || {
  echo "CANNOT-RUN: cannot create a sandbox" >&2; exit 2; }
trap 'rm -rf -- "${SANDBOX}"' EXIT

mkdir -p -- "${SANDBOX}/vendor" "${SANDBOX}/tests"
cp -R -- "${REPO}/vendor/cm059_editor" "${SANDBOX}/vendor/" || {
  echo "CANNOT-RUN: cannot stage vendor/cm059_editor" >&2; exit 2; }
cp -- "${REPO}/tests/test_the_interests_domain_is_reachable.py" \
      "${REPO}/tests/test_an_empty_interests_page_says_which_empty.py" \
      "${SANDBOX}/tests/" || {
  echo "CANNOT-RUN: cannot stage the gates" >&2; exit 2; }
find "${SANDBOX}" -name '__pycache__' -type d -exec rm -rf -- {} + 2>/dev/null

REACH="${SANDBOX}/tests/test_the_interests_domain_is_reachable.py"
EMPTY="${SANDBOX}/tests/test_an_empty_interests_page_says_which_empty.py"
IPROF="${SANDBOX}/vendor/cm059_editor/compiler/interest_profile.py"
FPAGE="${SANDBOX}/vendor/cm059_editor/compiler/frontpage.py"
RHTML="${SANDBOX}/vendor/cm059_editor/compiler/render_html.py"
EMITA="${SANDBOX}/vendor/cm059_editor/compiler/emit_artefact.py"

PASSES=0
FAILS=0
MUTANTS_RUN=0
MUTANTS_CAUGHT=0

run_gate() {   # run_gate <path>; echoes the exit code, never dies on non-zero
  local rc
  find "${SANDBOX}" -name '__pycache__' -type d -exec rm -rf -- {} + 2>/dev/null
  env -u PYTHONPATH "${PY3}" "$1" >/dev/null 2>&1
  rc=$?           # captured DIRECTLY: through a pipe this would be the pipe's
  printf '%s' "${rc}"
}

note() { printf '%s\n' "$*"; }

# --- CONTROL: the unmutated sandbox must be green ---------------------------
note "CONTROL (unmutated sandbox). Without this, 'every mutant caught' is also"
note "what a gate that can never pass would print."
for pair in "reachability:${REACH}" "empty-page:${EMPTY}"; do
  name="${pair%%:*}"; path="${pair#*:}"
  rc="$(run_gate "${path}")"
  if [ "${rc}" = "0" ]; then
    note "  PASS  ${name} gate is GREEN on unmutated sources (exit 0)"
    PASSES=$((PASSES + 1))
  else
    note "  FAIL  ${name} gate is NOT green on unmutated sources (exit ${rc})"
    FAILS=$((FAILS + 1))
  fi
done
note ""

# --- the mutants ------------------------------------------------------------
# mutate <file> <python-literal-needle> <python-literal-replacement>
mutate() {
  "${PY3}" - "$1" "$2" "$3" <<'PY'
import sys, pathlib
path, needle, repl = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
s = path.read_text(encoding="utf-8")
if needle not in s:
    print("NEEDLE-ABSENT", file=sys.stderr); sys.exit(3)
path.write_text(s.replace(needle, repl, 1), encoding="utf-8")
PY
}

# assert_applied <file> <expected text>: a mutant that did not apply looks
# exactly like one that was not caught, so this is a CANNOT-RUN, not a fail.
assert_applied() {
  if ! "${PY3}" - "$1" "$2" <<'PY'
import sys, pathlib
sys.exit(0 if sys.argv[2] in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8") else 1)
PY
  then
    note "  CANNOT-RUN: mutant did not apply to $1 (expected text absent after edit)"
    exit 2
  fi
  note "    applied, and VERIFIED present in $(basename "$1"): $(printf '%.72s' "$2")"
}

restore() {   # restore <sandbox file> from the repo original
  local rel="${1#${SANDBOX}/}"
  cp -- "${REPO}/${rel}" "$1"
}

# carry <label> <gate-path> <file> <needle> <replacement> <applied-marker>
carry() {
  local label="$1" gate="$2" file="$3" needle="$4" repl="$5" marker="$6" rc
  MUTANTS_RUN=$((MUTANTS_RUN + 1))
  note "MUTANT ${MUTANTS_RUN}: ${label}"
  if ! mutate "${file}" "${needle}" "${repl}"; then
    note "  CANNOT-RUN: the text this mutant edits is no longer in $(basename "${file}")"
    exit 2
  fi
  assert_applied "${file}" "${marker}"
  rc="$(run_gate "${gate}")"
  if [ "${rc}" != "0" ]; then
    note "  CAUGHT (gate exited ${rc})"
    MUTANTS_CAUGHT=$((MUTANTS_CAUGHT + 1))
  else
    note "  SURVIVED (gate exited 0) -- the gate cannot see this defect"
    FAILS=$((FAILS + 1))
  fi
  restore "${file}"
  note ""
}

# 1. the evidence_factor fix reverted: a single observation is discounted 30%
#    again, so the displayed confidence can never exceed reliability and the
#    Interests domain dies from facebook exactly as it did on the walk box.
carry "evidence_factor reverted to a discount (EVIDENCE_BASE 1.00 -> 0.70)" \
  "${REACH}" "${IPROF}" 'EVIDENCE_BASE = 1.00' 'EVIDENCE_BASE = 0.70' \
  'EVIDENCE_BASE = 0.70'

# 2. the retired comment put back. The code would again claim low-trust rows
#    "still appear in the profile" while deleting them.
carry "the retired 'still appear in the profile' claim restored" \
  "${REACH}" "${IPROF}" '# Taxonomy: how far to trust each source category' \
  '# Trust is the Phase-0 noise lever - low-trust categories still
# appear in the profile but sink, and are flagged for the correction surface.
# Taxonomy: how far to trust each source category' \
  'low-trust categories still'

# 3. the noise lever switched off: recruiter-email csv rows become trusted.
carry "the noise lever disabled (SOURCE_TRUST csv 0.18 -> 0.98)" \
  "${REACH}" "${IPROF}" '"csv": 0.18,' '"csv": 0.98,' '"csv": 0.98,'

# 4. the floor raised so far that no realistic source reaches any domain.
carry "the membership floor raised out of reach (MIN_CONFIDENCE 0.28 -> 0.90)" \
  "${REACH}" "${IPROF}" 'MIN_CONFIDENCE = 0.28' 'MIN_CONFIDENCE = 0.90' \
  'MIN_CONFIDENCE = 0.90'

# 5. the card stops branching: one body for every state, which is the defect
#    itself -- two different facts sharing one output.
carry "the card renders one body for every state (state pinned to 'populated')" \
  "${EMPTY}" "${FPAGE}" '    state = interest_page_state(stats)' \
  '    state = "populated"  # MUTANT' 'state = "populated"  # MUTANT'

# 6. could-not-look rendered as found-nothing: a missing raw_rows read as 0.
carry "a missing raw_rows read as a measured zero (unmeasured -> nothing_read)" \
  "${EMPTY}" "${FPAGE}" '    if raw is None:
        return "unmeasured"' '    if raw is None:
        raw = 0  # MUTANT' 'raw = 0  # MUTANT'

# 7. the preview renderer back to one generic sentence for every cause.
carry "the preview renderer reverted to one generic empty sentence" \
  "${EMPTY}" "${RHTML}" 'body = "".join(doms) or _empty_note(s)' \
  'body = "".join(doms) or (chr(60) + "p" + chr(62) + "nothing yet")  # MUTANT' \
  'nothing yet")  # MUTANT'

# 8. PRESENT BUT DEAD. The compiler still counts everything; the emitter drops
#    the stats on the way to the artefact, so the numbers exist and never reach
#    the page. This is the mutant that proves the gate really travels the whole
#    chain through a file on disk rather than reading the in-process profile.
carry "the emitter drops stats on the way to the artefact (present but dead)" \
  "${EMPTY}" "${EMITA}" '"stats": profile.get("stats", {}),' \
  '"stats": {},  # MUTANT' '"stats": {},  # MUTANT'

# --- verdict ----------------------------------------------------------------
note "DENOMINATORS: 2 unmutated controls, ${MUTANTS_RUN} mutants carried, "
note "${MUTANTS_CAUGHT} of ${MUTANTS_RUN} caught. Nothing here was capped with head or tail."
if [ "${FAILS}" -ne 0 ] || [ "${MUTANTS_CAUGHT}" -ne "${MUTANTS_RUN}" ]; then
  note "FAILED: ${FAILS} problem(s); ${MUTANTS_CAUGHT}/${MUTANTS_RUN} mutants caught"
  exit 1
fi
note "OK: both gates are green unmutated and red under every one of the "
note "${MUTANTS_RUN} mutants, so each assertion is load-bearing."
exit 0
