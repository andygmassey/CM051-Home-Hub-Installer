#!/usr/bin/env bash
# test_cm024k_email_summarizer_usage_journal.sh (#2472)
#
# ===========================================================================
# WHY THIS TEST EXISTS
# ===========================================================================
#
# vendor/cm024_knowledge/ostler_knowledge/knowledge/email_summarizer.py's
# ``EmailSummarizer._call_ollama`` posts to Ollama's own ``/api/generate``
# directly and, until this change, read nothing back but ``response``. This is
# one of five vendored call sites found by the #2472 sweep. The file sits
# under ``knowledge/`` and turns already-ingested email threads into
# facts/decisions/advice, so its purpose is ``enriching`` -- the contract's own
# definition of enriching, and distinct from the ``ingesting`` purpose its
# ingestion/ siblings use.
#
# A companion PR lands the equivalent fix upstream in
# andygmassey/evernote-knowledge. This test runs against the VENDORED copy,
# because that is what ships.
#
# Not a grep for an import line: it RUNS ``_call_ollama`` against a
# monkeypatched Ollama HTTP response and asserts a record is written.
# scripts/usage_journal_producers.tsv deliberately carries no row for this
# producer yet (see cut-manifests/v1.0.107.yaml).
#
# ===========================================================================
# WHAT IS ASSERTED (6 assertions + 1 control)
# ===========================================================================
#   CONTROL 0  the control itself is live
#   1  ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py EXISTS
#   2  email_summarizer.py imports the writer
#   3  RUNNING _call_ollama() against a measured response writes ONE record
#      (and the LLM text itself still comes back correctly)
#   4  the record's session_id carries the "cm024k-enrich-" prefix
#   5  the record's purpose is "enriching"
#   6  MUST-MISS: an Ollama response with no token counts writes NOTHING
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM024_ROOT="${REPO_ROOT}/vendor/cm024_knowledge"
SUMMARIZER="${CM024_ROOT}/ostler_knowledge/knowledge/email_summarizer.py"
JOURNAL_MOD="${CM024_ROOT}/ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py"

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

PY="${PYTHON3_BIN:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 on PATH"; exit 2; }
[ -f "$SUMMARIZER" ] || { echo "CANNOT-RUN: $SUMMARIZER absent"; exit 2; }

echo "== vendored cm024 email_summarizer.py usage-journal producer =="

ctl=$(grep -cE '^(def |import |from )' "$SUMMARIZER")
if [ "$ctl" -gt 0 ]; then
    ok "CONTROL live: ${ctl} def/import lines readable in email_summarizer.py"
else
    echo "  CANNOT-RUN: control scored 0 -- the file is unreadable, no zero below can be trusted"
    exit 2
fi

if [ -f "$JOURNAL_MOD" ]; then
    ok "ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py exists"
else
    bad "ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py is ABSENT"
fi

if grep -q 'from .._vendor.ostler_usage_journal import record_usage' "$SUMMARIZER"; then
    ok "email_summarizer.py imports record_usage"
else
    bad "email_summarizer.py does NOT import record_usage"
fi

out=$(cd "$REPO_ROOT" && "$PY" - <<'PY' 2>&1
import asyncio, json, pathlib, sys, tempfile, os

repo = pathlib.Path(".").resolve()
sys.path.insert(0, str(repo / "vendor/cm024_knowledge"))

tmp_dir = pathlib.Path(tempfile.mkdtemp())
os.environ["ZEROCLAW_CONFIG_DIR"] = str(tmp_dir)
journal = tmp_dir / "workspace" / "state" / "costs.jsonl"

def lines():
    if not journal.exists():
        return []
    return [json.loads(l) for l in journal.read_text().splitlines() if l.strip()]

try:
    import httpx
except ModuleNotFoundError as exc:
    print(f"DEP_MISSING {exc.name}")
    raise SystemExit(0)

try:
    import ostler_knowledge.knowledge.email_summarizer as es_mod
except Exception as exc:
    print(f"IMPORT_FAILED {type(exc).__name__}: {exc}")
    raise SystemExit(0)

class FakeAsyncResp:
    def __init__(self, data): self._d = data
    def raise_for_status(self): pass
    def json(self): return self._d

class FakeAsyncClientMeasured:
    def __init__(self, *a, **k): pass
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def post(self, url, json=None, **kw):
        return FakeAsyncResp({"response": "a synthetic summary",
                               "prompt_eval_count": 50, "eval_count": 30})

httpx.AsyncClient = FakeAsyncClientMeasured
summarizer = es_mod.EmailSummarizer()

before = len(lines())
text = asyncio.run(summarizer._call_ollama("summarize this synthetic thread"))
after = lines()
if len(after) != before + 1:
    print(f"NO_RECORD_WRITTEN before={before} after={len(after)}")
    raise SystemExit(0)
if text != "a synthetic summary":
    print(f"RESPONSE_BROKEN text={text!r}")
    raise SystemExit(0)
rec = after[-1]
print("WROTE 1")
print("PREFIX_OK" if rec["session_id"].startswith("cm024k-enrich-") else
      f"PREFIX_BAD {rec['session_id']}")
print("PURPOSE_OK" if rec["usage"]["purpose"] == "enriching" else
      f"PURPOSE_BAD {rec['usage']['purpose']}")

class FakeAsyncClientUnmeasured(FakeAsyncClientMeasured):
    async def post(self, url, json=None, **kw):
        return FakeAsyncResp({"response": "another synthetic summary"})

httpx.AsyncClient = FakeAsyncClientUnmeasured
before2 = len(lines())
asyncio.run(summarizer._call_ollama("summarize this other synthetic thread"))
after2 = len(lines())
print("UNMEASURED_SILENT" if before2 == after2 else f"UNMEASURED_WROTE {before2}->{after2}")
PY
)

if grep -q 'DEP_MISSING' <<<"$out"; then
    dep=$(grep -o 'DEP_MISSING.*' <<<"$out" | head -1 | awk '{print $2}')
    echo "  CANNOT-RUN: the runner has no '${dep}'. The vendored module is not at fault."
    exit 2
fi
if grep -q 'IMPORT_FAILED' <<<"$out"; then
    bad "the vendored module does not import: $(printf '%s' "$out" | head -1)"
fi
if grep -q 'RESPONSE_BROKEN' <<<"$out"; then
    bad "the usage-journal wiring broke the LLM response itself: $(printf '%s' "$out" | head -1)"
fi
grep -q 'WROTE 1'           <<<"$out" && ok "RUNNING _call_ollama() writes a record (response text unaffected)" \
                                      || bad "_call_ollama() wrote NOTHING on a measured response: $(printf '%s' "$out" | head -1)"
grep -q 'PREFIX_OK'         <<<"$out" && ok "session_id carries the cm024k-enrich- prefix" \
                                      || bad "session_id prefix is wrong: $(grep -o 'PREFIX_BAD.*' <<<"$out")"
grep -q 'PURPOSE_OK'        <<<"$out" && ok "purpose is 'enriching'" \
                                      || bad "purpose is wrong: $(grep -o 'PURPOSE_BAD.*' <<<"$out")"
grep -q 'UNMEASURED_SILENT' <<<"$out" && ok "MUST-MISS: an unmeasured response writes nothing (no invented numbers)" \
                                      || bad "the must-miss arm did not pass: $(grep -o 'UNMEASURED_WROTE.*' <<<"$out")"

echo
echo "  passed ${pass}, failed ${fail}"
[ "$fail" -eq 0 ] || exit 1
exit 0
