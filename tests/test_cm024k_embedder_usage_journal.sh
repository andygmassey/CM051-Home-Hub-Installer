#!/usr/bin/env bash
# test_cm024k_embedder_usage_journal.sh (#2472)
#
# ===========================================================================
# WHY THIS TEST EXISTS
# ===========================================================================
#
# vendor/cm024_knowledge/ostler_knowledge/ingestion/embedder.py's
# ``Embedder._embed_ollama`` posts to Ollama's own ``/api/embed`` directly (one
# HTTP call per text) and, until this change, read nothing back but
# ``embeddings``. This is one of five vendored call sites found by the
# #2472 sweep (13,636 embed calls + 481 generate calls measured against
# Ollama's own log in a one-hour walk window; costs.jsonl recorded ZERO rows
# in that window). The file sits under ``ingestion/``, the one-time Evernote
# convert/embed pass, so its purpose is ``ingesting``.
#
# A companion PR lands the equivalent fix upstream in
# andygmassey/evernote-knowledge. This test runs against the VENDORED copy,
# because that is what ships -- a fix merged upstream and lost at the vendor
# boundary is exactly the failure class
# tests/test_vendored_fda_writes_the_usage_journal.sh was written for.
#
# Not a grep for an import line: it RUNS ``Embedder.embed_batch`` against a
# monkeypatched Ollama HTTP response and asserts a record is written.
# scripts/usage_journal_producers.tsv deliberately carries no row for this
# producer yet (see cut-manifests v1.0.106.yaml's issue:2472 row), so the
# contract is read from the module's own emitted prefix/purpose, not the
# roster.
#
# UPDATED after the clean re-vendor from andygmassey/evernote-knowledge@
# e0196b10 (PR #18): upstream's embedder.py does NOT call a free
# ``record_usage`` function per call. It holds a ``RollingUsageRecorder``
# (one per ``Embedder`` instance) and calls ``.add(input_tokens,
# output_tokens)`` per HTTP response, which SUMS measured tokens across a
# 60-second window per (model, purpose) and writes ONE rolled-up row on
# flush -- not one row per call. This test therefore asserts the WIRING
# (a row appears, with the right prefix/purpose, after an explicit
# ``flush()``) rather than a 1:1 call-to-row ratio for this file specifically;
# that ratio is a deliberate, documented tradeoff upstream made after a live
# walk measured ~13,600 embed calls/hour, and is covered on the upstream side
# by tests/test_usage_journal_vendor.py (not vendored here; excluded as
# tests/). The sibling classifier.py/email_summarizer.py producers stay
# strictly per-call and are asserted 1:1 in their own test files.
#
# ===========================================================================
# WHAT IS ASSERTED (6 assertions + 1 control)
# ===========================================================================
#   CONTROL 0  the control itself is live
#   1  ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py EXISTS
#   2  embedder.py imports RollingUsageRecorder
#   3  RUNNING embed_batch() against a measured response, then flush(),
#      writes ONE record
#   4  the record's session_id carries the "cm024k-ingest-" prefix
#   5  the record's purpose is "ingesting"
#   6  MUST-MISS: an Ollama response with no token counts, then flush(),
#      writes NOTHING (an unmeasured call never opens a bucket)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM024_ROOT="${REPO_ROOT}/vendor/cm024_knowledge"
EMBEDDER="${CM024_ROOT}/ostler_knowledge/ingestion/embedder.py"
JOURNAL_MOD="${CM024_ROOT}/ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py"

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

PY="${PYTHON3_BIN:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 on PATH"; exit 2; }
[ -f "$EMBEDDER" ] || { echo "CANNOT-RUN: $EMBEDDER absent"; exit 2; }

echo "== vendored cm024 embedder.py usage-journal producer =="

ctl=$(grep -cE '^(def |import |from )' "$EMBEDDER")
if [ "$ctl" -gt 0 ]; then
    ok "CONTROL live: ${ctl} def/import lines readable in embedder.py"
else
    echo "  CANNOT-RUN: control scored 0 -- the file is unreadable, no zero below can be trusted"
    exit 2
fi

if [ -f "$JOURNAL_MOD" ]; then
    ok "ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py exists"
else
    bad "ostler_knowledge/_vendor/ostler_usage_journal/usage_journal.py is ABSENT"
fi

if grep -q 'from .._vendor.ostler_usage_journal import RollingUsageRecorder' "$EMBEDDER"; then
    ok "embedder.py imports RollingUsageRecorder"
else
    bad "embedder.py does NOT import RollingUsageRecorder"
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
    import ostler_knowledge.ingestion.embedder as emb_mod
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
        return FakeAsyncResp({"embeddings": [[0.3, 0.1]], "prompt_eval_count": 11, "eval_count": 0})

httpx.AsyncClient = FakeAsyncClientMeasured
e = emb_mod.Embedder()
before = len(lines())
asyncio.run(e.embed_batch(["a synthetic note, no person in it"]))
# ROLLUP: the recorder holds the measured tokens in an open 60s bucket and
# does not hit disk until flush() (window elapsed, atexit, or SIGTERM). A
# test cannot wait 60 real seconds, so it flushes explicitly -- this is
# the documented, public escape hatch (RollingUsageRecorder.flush()), not
# a private implementation reach-around.
e._usage_recorder.flush()
after = lines()
if len(after) != before + 1:
    print(f"NO_RECORD_WRITTEN before={before} after={len(after)}")
    raise SystemExit(0)
rec = after[-1]
print("WROTE 1")
print("PREFIX_OK" if rec["session_id"].startswith("cm024k-ingest-") else
      f"PREFIX_BAD {rec['session_id']}")
print("PURPOSE_OK" if rec["usage"]["purpose"] == "ingesting" else
      f"PURPOSE_BAD {rec['usage']['purpose']}")

class FakeAsyncClientUnmeasured(FakeAsyncClientMeasured):
    async def post(self, url, json=None, **kw):
        return FakeAsyncResp({"embeddings": [[0.3, 0.1]]})

httpx.AsyncClient = FakeAsyncClientUnmeasured
before2 = len(lines())
asyncio.run(e.embed_batch(["another synthetic note"]))
# An all-unmeasured call must never open a bucket at all (RollingUsageRecorder
# .add()'s own contract), so flushing an untouched recorder must write nothing.
e._usage_recorder.flush()
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
grep -q 'WROTE 1'           <<<"$out" && ok "RUNNING embed_batch() then flush() writes a record" \
                                      || bad "embed_batch()+flush() wrote NOTHING on a measured response: $(printf '%s' "$out" | head -1)"
grep -q 'PREFIX_OK'         <<<"$out" && ok "session_id carries the cm024k-ingest- prefix" \
                                      || bad "session_id prefix is wrong: $(grep -o 'PREFIX_BAD.*' <<<"$out")"
grep -q 'PURPOSE_OK'        <<<"$out" && ok "purpose is 'ingesting'" \
                                      || bad "purpose is wrong: $(grep -o 'PURPOSE_BAD.*' <<<"$out")"
grep -q 'UNMEASURED_SILENT' <<<"$out" && ok "MUST-MISS: an unmeasured response + flush() writes nothing (bucket never opened)" \
                                      || bad "the must-miss arm did not pass: $(grep -o 'UNMEASURED_WROTE.*' <<<"$out")"

echo
echo "  passed ${pass}, failed ${fail}"
[ "$fail" -eq 0 ] || exit 1
exit 0
