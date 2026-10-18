#!/usr/bin/env bash
# test_converge_must_resync_qdrant_people_too.sh -- board #2562-F.
#
# WHY THIS EXISTS. v1.0.107 walk #4, MEASURED on a walk box: oxigraph=2792
# distinct Person nodes, Doctor (Qdrant-backed /api/v1/hydration/status
# contacts phase)=2648, a gap of 144, right after an identity-resolver
# change (CM051 #2610/#2614) had just reshaped the Person set. Both numbers
# were individually correct for the instant they were read; the gap closed
# on its own within the next scheduled enrich tick. Neither #2608, #2610 nor
# #2614 touches vendor/cm041/assistant_api/ical-server.py (which produces
# the Doctor's count, _wiki_people_count() reading the Qdrant `people`
# collection) or vendor/ostler_fda/pwg_ingest.py (ingest_people_to_qdrant,
# the only writer that resyncs it) -- confirmed by file-level diff of all
# three PRs. The real gap: the dedupe-catchup agent's converge pass already
# triggers a post-converge wiki recompile (so late merges surface there
# immediately) but had NO equivalent trigger for the Qdrant people index, so
# a converge that changes the Person count left Qdrant stale until an
# independently-scheduled tick caught up, and a walk landing inside that
# window reads a false disagreement.
#
# Extracts the REAL dedupe-catchup wrapper (the heredoc
# _install_dedupe_catchup_agent writes to disk) and runs it end to end in a
# sandbox, with a stub converge that "succeeds" and a stub
# ingest_people_to_qdrant that records whether it was actually called -- not
# merely that the source text mentions it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== structural: the catch-up agent's success branch calls the people resync =="
BODY="$(awk '/cat > "\$wrapper" <<.DCUEOF./{f=1; next} f && /^DCUEOF$/{exit} f{print}' "$INSTALL_SH")"
if [ -z "$BODY" ]; then
    echo "CANNOT-RUN: could not extract the dedupe-catchup wrapper body from install.sh" >&2
    exit 2
fi
grep -q "ingest_people_to_qdrant" <<< "$BODY" \
    && ok "the wrapper body mentions ingest_people_to_qdrant" \
    || bad "the wrapper body never mentions ingest_people_to_qdrant"
# Position check: the call must be reachable from the SAME success branch as
# the .done marker write and the wiki recompile trigger, not merely present
# anywhere in the file (which the behavioural check below proves properly,
# this just pins the obvious regression of moving it out of that branch).
AFTER_DONE="$(echo "$BODY" | awk '/: >"\$DONE_MARKER"/{f=1} f')"
grep -q "ingest_people_to_qdrant" <<< "$AFTER_DONE" \
    && ok "the resync call is positioned after the .done marker is written" \
    || bad "the resync call is not reachable from the converge-succeeded branch"

echo "== behavioural: the real wrapper actually calls it on a successful converge =="
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

HOME_SB="${TMPD}/home"
OSTLER_DIR_SB="${HOME_SB}/.ostler"
PIPELINE_DIR_SB="${OSTLER_DIR_SB}/import-pipeline"
mkdir -p "${OSTLER_DIR_SB}/logs" "${OSTLER_DIR_SB}/state" "${OSTLER_DIR_SB}/bin" \
         "${HOME_SB}/Library/LaunchAgents" \
         "${PIPELINE_DIR_SB}/identity_resolver" "${PIPELINE_DIR_SB}/.venv/bin"

# Stub identity_resolver.batch_resolver: a converge that "succeeds" instantly.
cat > "${PIPELINE_DIR_SB}/.venv/bin/python3" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${PIPELINE_DIR_SB}/.venv/bin/python3"

# Stub the FDA module ingest_people_to_qdrant records whether it ran.
MARKER="${TMPD}/people_resync_ran"
FDA_DIR_SB="${OSTLER_DIR_SB}/fda-module"
mkdir -p "${FDA_DIR_SB}/ostler_fda"
: > "${FDA_DIR_SB}/ostler_fda/__init__.py"
cat > "${FDA_DIR_SB}/ostler_fda/pwg_ingest.py" <<PYEOF
import os
def ingest_people_to_qdrant(fda_dir=None):
    with open(r"${MARKER}", "w") as f:
        f.write("ran")
    return {"status": "ok", "sent": 1, "total": 1}
PYEOF

# A no-op wiki-recompile-tick.sh so the pre-existing trigger does not fail.
TICK_SB="${OSTLER_DIR_SB}/bin/wiki-recompile-tick.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TICK_SB"
chmod +x "$TICK_SB"

# Extract the wrapper body and run it for real, with HOME redirected into
# the sandbox and OSTLER_PYTHON pointed at the REAL interpreter (identity_
# resolver's own venv stub above is independent and always hardcoded
# relative to PIPELINE_DIR, matching the shipped script).
WRAPPER="${TMPD}/wrapper.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo "$BODY"
} > "$WRAPPER"
chmod +x "$WRAPPER"

REAL_PY="$(command -v python3)"
if [ -z "$REAL_PY" ]; then
    echo "CANNOT-RUN: no python3 on PATH to run the extracted wrapper" >&2
    exit 2
fi

HOME="$HOME_SB" OSTLER_PIPELINE_DIR="$PIPELINE_DIR_SB" OSTLER_PYTHON="$REAL_PY" \
    OXIGRAPH_URL="http://127.0.0.1:0" QDRANT_URL="http://127.0.0.1:0" \
    "$WRAPPER" >"${TMPD}/run.log" 2>&1
RC=$?

if [ -f "$MARKER" ]; then
    ok "a successful converge actually invokes ingest_people_to_qdrant (marker written)"
else
    bad "ingest_people_to_qdrant was never invoked (marker absent); wrapper rc=${RC}, log follows:"
    sed 's/^/        /' "${TMPD}/run.log" >&2
fi

grep -q "post-converge Qdrant people resync completed" "${OSTLER_DIR_SB}/logs/dedupe-catchup.log" 2>/dev/null \
    && ok "the resync success is logged" \
    || bad "no log line recorded the resync success"

# CONTROL: the pre-existing wiki recompile trigger must still fire too -- the
# new call must be an ADDITION, not a replacement.
grep -q "triggering wiki recompile" "${OSTLER_DIR_SB}/logs/dedupe-catchup.log" 2>/dev/null \
    && ok "CONTROL: the pre-existing wiki recompile trigger still fires" \
    || bad "CONTROL failed: the wiki recompile trigger is gone"

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
