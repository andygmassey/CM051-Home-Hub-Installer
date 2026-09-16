#!/usr/bin/env bash
#
# tests/test_a_matched_grep_cannot_epipe_its_own_producer.sh
#
# WHAT WENT WRONG, ON MAIN, MEASURED.
#
# `launchagent-success-verification` went RED on main at 9e27307c
# (2026-09-16T04:55:44Z). The commit it blamed touched exactly one file, a
# Swift unit test, which cannot reach a launchd plist. The job printed:
#
#     tests/test_v1010_ical_doctor_service_auth.sh: line 37: echo: write error: Broken pipe
#     FAIL: ical-server plist does not carry PWG_SERVICE_TOKEN
#
# The second line is FALSE. `install.sh` at that same commit carries
# `<key>PWG_SERVICE_TOKEN</key>` in the ical-server plist heredoc, count 1,
# with a fabricated key as the control returning 0. So a green assertion
# reported itself as a MISSING SECURITY CREDENTIAL.
#
# THE MECHANISM. Under `set -o pipefail`:
#
#     echo "$BIG" | grep -q PATTERN || fail "..."
#
# `grep -q` exits 0 the instant it matches. That closes the read end while
# `echo` may still be writing, so `echo` takes EPIPE and exits non-zero.
# pipefail takes the WORST status in the pipeline, so the pipeline reports
# failure -- BECAUSE THE PATTERN WAS FOUND EARLY. The better the match, the
# likelier the false failure. It is a race on stdio chunking, which is why it
# fired once in twelve runs and why it did not reproduce on macOS in 3000
# trials: it needs the runner's libc, its buffer size and its scheduling.
#
# A test that cannot fail is indistinguishable from a clean sheet; this is the
# mirror of that, a test that fails while reporting someone else's defect.
#
# THE FIX IS MECHANICAL AND SEMANTICS-PRESERVING. A herestring feeds grep from
# a temporary file, so there is no pipe and no reader to close it:
#
#     grep -q PATTERN <<<"$BIG" || fail "..."
#
# This guard freezes that. It is a RATCHET over the population, not a
# classifier: any NEW occurrence in a pipefail-enabled script is refused.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || { echo "CANNOT RUN: repo root unreadable"; exit 1; }

# ONLY short-circuiting consumers. `grep -c` and `grep -o` must read every
# byte to count or extract, so they never close the pipe early and the
# producer never takes EPIPE; flagging those would demand rewrites of code
# that cannot exhibit the defect, and a guard that refuses correct code gets
# switched off. `-q` stops at the first match, `-l` at the first matching
# file, `-m N` after N matches. Those three, and no others.
RISKY_RE='echo "\$[A-Za-z_][A-Za-z_0-9]*" *\| *grep +(-[A-Za-z]* )*-[A-Za-z]*[qlm]'
rc=0

# --------------------------------------------------------------------------
# ARM 1 -- SELF-TEST FIRST. A scanner that cannot see its own specimen would
# report a clean tree for a broken one. The specimen is written to a temp file
# OUTSIDE the tree, so the ratchet below can never trip over the control.
# --------------------------------------------------------------------------
SPEC_DIR="$(mktemp -d)"
trap 'rm -rf "$SPEC_DIR"' EXIT
cat > "$SPEC_DIR/specimen.sh" <<'SPECEOF'
#!/usr/bin/env bash
set -euo pipefail
BODY="$(cat /etc/hosts)"
echo "$BODY" | grep -q localhost || { echo "FAIL: no localhost"; exit 1; }
SPECEOF
cat > "$SPEC_DIR/clean.sh" <<'CLEANEOF'
#!/usr/bin/env bash
set -euo pipefail
BODY="$(cat /etc/hosts)"
grep -q localhost <<<"$BODY" || { echo "FAIL: no localhost"; exit 1; }
CLEANEOF

spec_hits=$(grep -cE "$RISKY_RE" "$SPEC_DIR/specimen.sh" || true)
clean_hits=$(grep -cE "$RISKY_RE" "$SPEC_DIR/clean.sh" || true)
if [ "${spec_hits:-0}" -lt 1 ]; then
    echo "SELF-TEST FAILED: the scanner did not see the planted specimen."
    echo "Every zero it reports below would be meaningless. Refusing."
    exit 1
fi
if [ "${clean_hits:-0}" -ne 0 ]; then
    echo "SELF-TEST FAILED: the scanner flagged the herestring form, which is"
    echo "the fix. It would demand a rewrite of already-correct code. Refusing."
    exit 1
fi
echo "self-test: specimen seen (${spec_hits}), fixed form not flagged (${clean_hits}). Scanner discriminates."

# --------------------------------------------------------------------------
# ARM 2 -- THE RATCHET over the real tree, scoped to scripts that actually
# enable pipefail. This file is excluded from its own scan: it necessarily
# CONTAINS the pattern it hunts, as a regex literal and as two planted
# specimens, and a scanner that flags its own definition refuses for ever.
# Without pipefail the pipeline takes grep's status and the
# EPIPE is harmless, so flagging those would be noise.
# --------------------------------------------------------------------------
pipefail_files=0
offending=0
offenders=""
while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -qE 'set -[a-z]*o pipefail|set -o pipefail' "$f" 2>/dev/null || continue
    pipefail_files=$((pipefail_files + 1))
    n=$(grep -cE "$RISKY_RE" "$f" 2>/dev/null || true)
    if [ "${n:-0}" -gt 0 ]; then
        offending=$((offending + 1))
        offenders="${offenders}
  ${n}  ${f}"
    fi
done < <(find tests scripts -type f -name '*.sh' 2>/dev/null \
             | grep -v 'test_a_matched_grep_cannot_epipe_its_own_producer.sh')

if [ "$pipefail_files" -lt 1 ]; then
    echo "CANNOT RUN: found 0 pipefail-enabled shell scripts under tests/ and"
    echo "scripts/. That is not a pass. Either the tree moved or the find"
    echo "predicate is broken, and a zero denominator reads as success."
    exit 1
fi
echo "scanned ${pipefail_files} pipefail-enabled script(s)."

if [ "$offending" -gt 0 ]; then
    echo
    echo "REFUSED: ${offending} script(s) pipe a variable into grep under pipefail:${offenders}"
    echo
    echo "Rewrite each as a herestring, which is byte-identical in what grep"
    echo "reads and cannot be EPIPEd by its own consumer:"
    echo
    echo "    -  echo \"\$VAR\" | grep -q PATTERN"
    echo "    +  grep -q PATTERN <<<\"\$VAR\""
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    echo "PASS: no pipefail-enabled script lets a short-circuiting grep EPIPE its own producer."
fi
exit "$rc"
