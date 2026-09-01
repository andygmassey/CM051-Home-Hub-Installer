#!/usr/bin/env bash
# test_vendored_fda_writes_the_usage_journal.sh
#
# ===========================================================================
# WHY THIS TEST EXISTS, AND WHY IT IS NOT A GREP FOR AN IMPORT LINE
# ===========================================================================
#
# The usage-journal roster (scripts/usage_journal_producers.tsv) declares five
# REQUIRED producers. Four of its rows say, in their own provenance, that they
# are pinned-but-not-yet-observable. ONE says MEASURED:
#
#     cm051_ostler_fda_ingest   ... Prefix measured from
#                                   HR015 ostler_fda/pwg_ingest.py:50.
#
# It was measured. On the SOURCE. Which is not what ships.
#
# Until 2026-09-01 the vendored copy at vendor/ostler_fda/pwg_ingest.py scored
# ZERO for record_usage / usage_journal / _USAGE_SESSION_ID, against a live
# control of 57 for `^(def |import |from )` in the same file through the same
# pipeline -- so that zero was real absence, not a broken predicate. And
# vendor/ostler_fda/ did not contain usage_journal.py at all, so the import had
# nowhere to resolve even had it been there.
#
# 🗿 THE PRODUCER WAS WIRED UPSTREAM, MERGED, AND LOST AT THE VENDOR BOUNDARY.
# The roster recorded it as the measured one for as long as it was dark. That
# is MERGED != IN THE ARTEFACT, landing inside the very machinery built to
# detect a silently severed pipeline.
#
# So this test does NOT assert that an import line is present. An import line
# is a spelling. It RUNS the vendored module and asserts a record is written,
# with the session-id prefix and the purpose the roster matches on -- because
# those two strings are the contract between this producer and the gate that
# counts it. A vendored copy can be byte-perfect and still be counted by
# nothing if either drifts.
#
# ===========================================================================
# WHAT IS ASSERTED (7 assertions + 2 controls)
# ===========================================================================
#   CONTROL 0  the control itself is live (asserted FIRST, before any zero is
#              trusted anywhere below)
#   1  vendor/ostler_fda/usage_journal.py EXISTS -- the file whose absence was
#      the defect
#   2  it is BYTE-IDENTICAL to nothing in particular, but it does import and
#      expose record_usage + tokens_from_ollama
#   3  the vendored pwg_ingest imports the writer
#   4  RUNNING it writes a record
#   5  the record's session_id carries the prefix the ROSTER matches on
#   6  the record's purpose is the one the ROSTER declares
#   7  MUST-MISS: an Ollama response with no token counts writes NOTHING
#      (the contract's "measured, never estimated" rule)
#
# A note on assertion 7: it is the one that stops this test being satisfiable
# by a writer that logs unconditionally. Without it, a producer that invents a
# zero-token record every call would pass 1-6 and put a fabricated number on a
# customer's cost panel.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="${REPO_ROOT}/vendor"
INGEST="${VENDOR}/ostler_fda/pwg_ingest.py"
JOURNAL="${VENDOR}/ostler_fda/usage_journal.py"

pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }

PY="${PYTHON3_BIN:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 on PATH"; exit 2; }
[ -f "$INGEST" ] || { echo "CANNOT-RUN: $INGEST absent"; exit 2; }

echo "== vendored ostler_fda usage-journal producer =="

# --- CONTROL 0, asserted FIRST -------------------------------------------
# If this scores zero the file is unreadable or the pipeline is broken, and
# every zero below would be meaningless. Refuse rather than report a pass.
ctl=$(grep -cE '^(def |import |from )' "$INGEST")
if [ "$ctl" -gt 0 ]; then
    ok "CONTROL live: ${ctl} def/import lines readable in the vendored file"
else
    echo "  CANNOT-RUN: control scored 0 -- the file is unreadable, so no zero below can be trusted"
    exit 2
fi

# --- 1: the module that was missing --------------------------------------
if [ -f "$JOURNAL" ]; then
    ok "vendor/ostler_fda/usage_journal.py exists (its absence WAS the defect)"
else
    bad "vendor/ostler_fda/usage_journal.py is ABSENT -- the import cannot resolve, producer is dark"
fi

# --- 2 + 3: the wiring, as spellings (cheap, and NOT the real assertion) --
if grep -q 'from .usage_journal import record_usage' "$INGEST"; then
    ok "vendored pwg_ingest imports record_usage"
else
    bad "vendored pwg_ingest does NOT import record_usage"
fi
if grep -q '_USAGE_SESSION_ID' "$INGEST"; then
    ok "vendored pwg_ingest defines a usage session id"
else
    bad "vendored pwg_ingest has no _USAGE_SESSION_ID"
fi

# --- 4..7: BEHAVIOUR. Run it. --------------------------------------------
# The roster's contract, read from the roster rather than remembered:
ROSTER="${REPO_ROOT}/scripts/usage_journal_producers.tsv"
if [ -f "$ROSTER" ]; then
    want_prefix=$(grep -E '^cm051_ostler_fda_ingest\b' "$ROSTER" | cut -f5)
    want_purpose=$(grep -E '^cm051_ostler_fda_ingest\b' "$ROSTER" | cut -f3)
else
    echo "  CANNOT-RUN: roster absent, cannot state the contract this producer must meet"
    exit 2
fi
[ -n "$want_prefix" ] && [ -n "$want_purpose" ] || {
    echo "  CANNOT-RUN: roster has no cm051_ostler_fda_ingest row to read the contract from"; exit 2; }
echo "     roster says: prefix='${want_prefix}' purpose='${want_purpose}'"

out=$(cd "$VENDOR" && "$PY" - "$want_prefix" "$want_purpose" <<'PY' 2>&1
import json, pathlib, sys, tempfile
want_prefix, want_purpose = sys.argv[1], sys.argv[2]
sys.path.insert(0, ".")
try:
    from ostler_fda import usage_journal, pwg_ingest
except Exception as exc:                      # import failure is a REAL result
    print(f"IMPORT_FAILED {type(exc).__name__}: {exc}")
    raise SystemExit(0)

tmp = pathlib.Path(tempfile.mkdtemp()) / "costs.jsonl"
usage_journal.resolve_journal_path = lambda: tmp

# A real Ollama /api/embed response shape, WITH counts.
pwg_ingest._record_embed_usage(
    {"embeddings": [[0.1, 0.2]], "prompt_eval_count": 42, "eval_count": 0}
)
if not tmp.exists():
    print("NO_RECORD_WRITTEN")
    raise SystemExit(0)

rec = json.loads(tmp.read_text().strip().splitlines()[0])
print("WROTE 1")
print("PREFIX_OK" if rec["session_id"].startswith(want_prefix) else
      f"PREFIX_BAD {rec['session_id']}")
print("PURPOSE_OK" if rec["usage"]["purpose"] == want_purpose else
      f"PURPOSE_BAD {rec['usage']['purpose']}")

# MUST-MISS: no counts reported -> nothing written. "Measured, never estimated."
before = len(tmp.read_text().splitlines())
pwg_ingest._record_embed_usage({"embeddings": [[0.1]]})
after = len(tmp.read_text().splitlines())
print("UNMEASURED_SILENT" if before == after else f"UNMEASURED_WROTE {before}->{after}")
PY
)

case "$out" in
    *IMPORT_FAILED*) bad "the vendored module does not import: $(printf '%s' "$out" | head -1)" ;;
esac
grep -q 'WROTE 1'           <<<"$out" && ok "RUNNING the vendored producer writes a record" \
                                      || bad "the vendored producer wrote NOTHING on a measured response"
grep -q 'PREFIX_OK'         <<<"$out" && ok "session_id carries the prefix the roster matches on" \
                                      || bad "session_id prefix does NOT match the roster: $(grep -o 'PREFIX_BAD.*' <<<"$out")"
grep -q 'PURPOSE_OK'        <<<"$out" && ok "purpose is the one the roster declares" \
                                      || bad "purpose does NOT match the roster: $(grep -o 'PURPOSE_BAD.*' <<<"$out")"
grep -q 'UNMEASURED_SILENT' <<<"$out" && ok "MUST-MISS: an unmeasured response writes nothing (no invented numbers)" \
                                      || bad "an unmeasured response WROTE a record -- estimated, not measured"

echo
echo "  passed ${pass}, failed ${fail}"
[ "$fail" -eq 0 ] || exit 1
exit 0
