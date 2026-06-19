#!/usr/bin/env bash
#
# test_email_ingest_loud_guard.sh
#
# Runtime regression test for the silent-100%-drop bug (live audit on
# box 192.168.1.159, 2026-06-19): the email-ingest tick harvested 1,431
# messages into the staging mbox, logged a green "Emitted 1401
# message(s)", then dropped 100% with
#   "ERROR: pwg-email-ingest is not on PATH. CM046 not installed?"
# because the ingest binary lived in the email-ingest venv's bin/ but
# the LaunchAgent never put it on PATH nor passed PWG_EMAIL_INGEST. Zero
# emails reached the graph.
#
# This test EXECUTES the tick wrapper with a stubbed emitter and asserts
# the loud-guard contract:
#
#   Case A (HEALTHY): emitted > 0 AND PWG_EMAIL_INGEST resolves to a
#                     real executable -> the tick INVOKES it and exits 0.
#   Case B (REGRESSION SHAPE): emitted > 0 AND the ingest binary is
#                     absent / unresolved -> the tick FAILS LOUDLY,
#                     exits non-zero, and the harvested mbox is NEVER
#                     silently dropped.
#   Case C (NO WORK): emitter produced no messages -> the tick exits 0
#                     without touching the ingest leg (no false alarm).
#
# The tick imports nothing at top level beyond bash + coreutils, so we
# stub the emit leg by shadowing `python3 -m ostler_fda.apple_mail_mbox`
# with a fake `python3` on PATH that writes (or declines to write) the
# mbox. No network, no Apple Mail, no venv required.
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="$REPO_ROOT/vendor/email_ingest/bin/email-ingest-tick.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "ok: $*"; }

if [[ ! -f "$TICK" ]]; then
    echo "FAIL: tick wrapper not found at $TICK" >&2
    exit 1
fi

# --------------------------------------------------------------------
# Test harness: a sandbox with a fake python3 (the emit leg) on PATH.
# OSTLER_PYTHON is pointed at this fake so the tick's emit leg runs it.
# EMIT_MODE controls whether the fake writes the mbox.
# --------------------------------------------------------------------
make_sandbox() {
    local sb; sb="$(mktemp -d)"
    mkdir -p "$sb/ostler" "$sb/bin"

    # Fake python3: emulates `python3 -m ostler_fda.apple_mail_mbox
    # --emit-mbox <path> ...`. When EMIT_MODE=write it writes a small
    # mbox to the --emit-mbox path; when EMIT_MODE=empty it writes
    # nothing (mirrors the emitter declining to create a file when there
    # is no new mail). It also stands in for the mark_first_ingest
    # python call (any other invocation just exits 0).
    cat > "$sb/bin/python3" <<'PYEOF'
#!/usr/bin/env bash
# Find --emit-mbox <path> if present.
mbox=""
prev=""
for a in "$@"; do
    if [ "$prev" = "--emit-mbox" ]; then mbox="$a"; fi
    prev="$a"
done
if [ -n "$mbox" ]; then
    if [ "${EMIT_MODE:-write}" = "write" ]; then
        printf 'From test@example.com\nSubject: hi\n\nbody\n' > "$mbox"
        echo "Emitted 1 message(s) to $mbox"
    fi
    exit 0
fi
# mark_first_ingest or anything else: succeed quietly.
exit 0
PYEOF
    chmod 0755 "$sb/bin/python3"
    echo "$sb"
}

run_tick() {
    # run_tick <sandbox> <pwg_email_ingest_value> -> prints log, returns rc
    local sb="$1" ingest="$2"
    OSTLER_DIR="$sb/ostler" \
    OSTLER_HOME="$sb" \
    OSTLER_PYTHON="$sb/bin/python3" \
    PWG_EMAIL_INGEST="$ingest" \
    PATH="$sb/bin:$PATH" \
    EMIT_MODE="${EMIT_MODE:-write}" \
        bash "$TICK" 2>&1
}

# --------------------------------------------------------------------
# Case A: HEALTHY -- emitted > 0, ingest binary present + executable.
# Expect exit 0 AND evidence the binary was invoked with `mbox`.
# --------------------------------------------------------------------
SB="$(make_sandbox)"
INGEST_MARKER="$SB/ingest-was-called"
cat > "$SB/bin/fake-ingest" <<EOF
#!/usr/bin/env bash
echo "fake-ingest called: \$*" > "$INGEST_MARKER"
exit 0
EOF
chmod 0755 "$SB/bin/fake-ingest"

set +e
OUT="$(EMIT_MODE=write run_tick "$SB" "$SB/bin/fake-ingest")"; RC=$?
set -e
if [[ "$RC" -eq 0 ]] && [[ -f "$INGEST_MARKER" ]] && grep -q 'mbox' "$INGEST_MARKER"; then
    pass "Case A healthy: emitted>0 + ingest present -> tick exit 0 and binary invoked"
else
    failure "Case A: expected exit 0 with ingest invoked; rc=$RC marker=$( [[ -f $INGEST_MARKER ]] && cat "$INGEST_MARKER" || echo MISSING)"
    echo "--- tick output ---" >&2; echo "$OUT" >&2
fi
rm -rf "$SB"

# --------------------------------------------------------------------
# Case B: REGRESSION SHAPE -- emitted > 0 but ingest binary absent.
# This is the exact live-box failure. Expect NON-ZERO exit and a LOUD
# error mentioning that messages were harvested but nothing was ingested.
# --------------------------------------------------------------------
SB="$(make_sandbox)"
set +e
# Point PWG_EMAIL_INGEST at a name that is neither an executable path nor
# on PATH -- the launchd-minimal-PATH situation.
OUT="$(EMIT_MODE=write run_tick "$SB" "pwg-email-ingest-DOES-NOT-EXIST-$$")"; RC=$?
set -e
if [[ "$RC" -ne 0 ]] && printf '%s' "$OUT" | grep -qi 'harvested'; then
    pass "Case B regression shape: emitted>0 + ingest absent -> tick fails loudly (rc=$RC)"
else
    failure "Case B: expected NON-ZERO exit + loud 'harvested' error; rc=$RC"
    echo "--- tick output ---" >&2; echo "$OUT" >&2
fi
# The harvested mbox must be PRESERVED (never silently dropped).
if ls "$SB/ostler/imports/email/"*.mbox.txt >/dev/null 2>&1; then
    pass "Case B: harvested mbox preserved for re-run (not silently dropped)"
else
    failure "Case B: harvested mbox was not preserved"
fi
rm -rf "$SB"

# --------------------------------------------------------------------
# Case C: NO WORK -- emitter wrote nothing. The tick must exit 0 and
# never reach the ingest leg / loud guard (no false alarm on empty mail).
# --------------------------------------------------------------------
SB="$(make_sandbox)"
set +e
OUT="$(EMIT_MODE=empty run_tick "$SB" "pwg-email-ingest-DOES-NOT-EXIST-$$")"; RC=$?
set -e
if [[ "$RC" -eq 0 ]] && ! printf '%s' "$OUT" | grep -qi 'harvested'; then
    pass "Case C no-work: empty emit -> tick exit 0, guard not tripped"
else
    failure "Case C: expected exit 0 with no loud guard; rc=$RC"
    echo "--- tick output ---" >&2; echo "$OUT" >&2
fi
rm -rf "$SB"

# --------------------------------------------------------------------
if [[ "$FAILED" -eq 0 ]]; then
    echo "PASS: email-ingest loud guard holds (healthy ingests, regression-shape fails loudly, empty mail is quiet)"
    exit 0
else
    echo "" >&2
    echo "Regression test failed: the silent-100%-drop guard is not holding." >&2
    echo "See vendor/email_ingest/bin/email-ingest-tick.sh." >&2
    exit 1
fi
