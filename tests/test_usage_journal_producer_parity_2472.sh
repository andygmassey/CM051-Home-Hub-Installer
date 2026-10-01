#!/usr/bin/env bash
# test_usage_journal_producer_parity_2472.sh
#
# ===========================================================================
# WHY THIS TEST EXISTS
# ===========================================================================
#
# Issue #2472: a 2026-10-01 walk measured Ollama's OWN log showing 13,636
# embed calls + 481 generate calls in a one-hour window while costs.jsonl
# recorded ZERO rows in that window -- a CALLS-MADE vs ROWS-WRITTEN gap. The
# five per-caller tests alongside this one each prove their own producer
# writes something; none of them proves the RATIO holds. A producer that
# writes one row for every three calls would pass every per-caller test here
# (each only checks "wrote >= 1") and still under-count a customer's panel by
# two thirds.
#
# This test drives all FIVE wired call sites a FIXED N=3 times each against a
# synthetic mock Ollama HTTP responder, then asserts costs.jsonl holds EXACTLY
# N new rows per caller, with the right model and purpose on every one of
# them. N=3 rather than 1 specifically to catch an off-by-one in a batching
# loop (e.g. "record once per logical call" instead of "once per actual HTTP
# response") that a single-call test cannot distinguish from correct.
#
# ===========================================================================
# WHAT THIS DOES NOT PROVE, STATED EXPLICITLY
# ===========================================================================
#
# This is a PRODUCER-SIDE invariant only: "N real HTTP responses in -> N
# journal rows out", measured against a synthetic responder that never leaves
# loopback. It does NOT prove Ollama was actually called 13,636 times on any
# real box, and it does NOT prove the daemon's reader or the customer-facing
# panel renders the figure correctly -- CI has no Ollama at all. Comparing
# against a LIVE Ollama log (the measurement that found #2472 in the first
# place) is a separate CANNOT-RUN-in-CI check: it needs a real box walk
# (scripts/ttywalk.sh) with Ollama's own log as the independent oracle, the
# same shape scripts/box_walk_probes/probes/usage_journal_producers.sh already
# uses for the roster's existing rows.
#
# ===========================================================================
# WHAT IS ASSERTED
# ===========================================================================
#   CONTROL 0  python3 + httpx are available (CANNOT-RUN otherwise, never FAIL)
#   For each of the 5 callers: N=3 measured calls -> exactly 3 new rows, each
#   with the caller's purpose and session-id prefix (15 rows total); PLUS one
#   must-miss call per caller that must add ZERO rows (5 more checks).
#   A FINAL aggregate: total new rows this run == 15 exactly (5 callers x 3),
#   the parity claim itself, not just five separate "some rows appeared".
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N=3

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

PY="${PYTHON3_BIN:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 on PATH"; exit 2; }

echo "== usage-journal producer parity (#2472): N=${N} calls -> N rows, per caller =="

out=$(cd "$REPO_ROOT" && N="$N" "$PY" - <<'PY' 2>&1
import asyncio, json, os, pathlib, sys, tempfile, urllib.request

N = int(os.environ["N"])
repo = pathlib.Path(".").resolve()

tmp_dir = pathlib.Path(tempfile.mkdtemp())
os.environ["ZEROCLAW_CONFIG_DIR"] = str(tmp_dir)
journal = tmp_dir / "workspace" / "state" / "costs.jsonl"

def all_rows():
    if not journal.exists():
        return []
    return [json.loads(l) for l in journal.read_text().splitlines() if l.strip()]

try:
    import httpx
except ModuleNotFoundError as exc:
    print(f"DEP_MISSING {exc.name}")
    raise SystemExit(0)

results = {}  # caller -> (measured_new_rows, prefix_ok, purpose_ok, unmeasured_new_rows)

def check_caller(name, prefix, purpose, before, after_measured, after_unmeasured):
    measured_new = after_measured - before
    rows = all_rows()[before:after_measured]
    prefix_ok = all(r["session_id"].startswith(prefix) for r in rows)
    purpose_ok = all(r["usage"]["purpose"] == purpose for r in rows)
    unmeasured_new = after_unmeasured - after_measured
    results[name] = (measured_new, prefix_ok, purpose_ok, unmeasured_new)

# --------------------------------------------------------------------- cm019
sys.path.insert(0, str(repo / "vendor/cm019_preferences/services/ingest"))
import types as _types
cfg_mod = _types.ModuleType("src.config")
class _S:
    ollama_url = "http://127.0.0.1:11434"
    embedding_model = "nomic-embed-text"
    embedding_dim = 768
    batch_size = 8
cfg_mod.settings = _S()
sys.modules["src.config"] = cfg_mod

class FakeResp:
    def __init__(self, data): self._d = data
    def raise_for_status(self): pass
    def json(self): return self._d

try:
    import src.vectorizer as vec_mod
except Exception as exc:
    print(f"IMPORT_FAILED cm019 {type(exc).__name__}: {exc}")
    raise SystemExit(0)

def post_measured_embed(self, url, json=None, **kw):
    return FakeResp({"embeddings": [[0.1, 0.2]], "prompt_eval_count": 7, "eval_count": 0})
def post_unmeasured_embed(self, url, json=None, **kw):
    return FakeResp({"embeddings": [[0.1, 0.2]]})

v = vec_mod.Vectorizer()
before = len(all_rows())
httpx.Client.post = post_measured_embed
for i in range(N):
    v.embed_batch([f"synthetic sentence {i}"])
after_measured = len(all_rows())
httpx.Client.post = post_unmeasured_embed
v.embed_batch(["synthetic unmeasured sentence"])
after_unmeasured = len(all_rows())
check_caller("cm019_vectorizer", "cm019-ingest-", "ingesting", before, after_measured, after_unmeasured)

# --------------------------------------------------------------------- cm024
sys.path.insert(0, str(repo / "vendor/cm024_knowledge"))

class FakeAsyncResp:
    def __init__(self, data): self._d = data
    def raise_for_status(self): pass
    def json(self): return self._d

try:
    import ostler_knowledge.ingestion.embedder as emb_mod
    import ostler_knowledge.ingestion.classifier as clf_mod
    from ostler_knowledge.ingestion.enex_parser import ParsedNote
    import ostler_knowledge.knowledge.email_summarizer as es_mod
except Exception as exc:
    print(f"IMPORT_FAILED cm024 {type(exc).__name__}: {exc}")
    raise SystemExit(0)

# --- embedder (ingesting) ---
class FakeAsyncClientEmbedMeasured:
    def __init__(self, *a, **k): pass
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def post(self, url, json=None, **kw):
        return FakeAsyncResp({"embeddings": [[0.3]], "prompt_eval_count": 11, "eval_count": 0})
class FakeAsyncClientEmbedUnmeasured(FakeAsyncClientEmbedMeasured):
    async def post(self, url, json=None, **kw):
        return FakeAsyncResp({"embeddings": [[0.3]]})

e = emb_mod.Embedder()
before = len(all_rows())
httpx.AsyncClient = FakeAsyncClientEmbedMeasured
for i in range(N):
    asyncio.run(e.embed_batch([f"synthetic note {i}"]))
after_measured = len(all_rows())
httpx.AsyncClient = FakeAsyncClientEmbedUnmeasured
asyncio.run(e.embed_batch(["synthetic unmeasured note"]))
after_unmeasured = len(all_rows())
check_caller("cm024k_embedder", "cm024k-ingest-", "ingesting", before, after_measured, after_unmeasured)

# --- classifier (ingesting) ---
class FakeClassifierClientMeasured:
    def __init__(self, *a, **k): pass
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def post(self, url, json=None, **kw):
        return FakeResp({"response": '{"level": 3, "reason": "synthetic"}',
                          "prompt_eval_count": 20, "eval_count": 5})
class FakeClassifierClientUnmeasured(FakeClassifierClientMeasured):
    def post(self, url, json=None, **kw):
        return FakeResp({"response": '{"level": 2}'})

clf = clf_mod.PrivacyClassifier(use_llm=True)
note = ParsedNote(title="synthetic", content="synthetic", content_html="<p>s</p>", tags=[])
before = len(all_rows())
clf_mod.httpx = httpx
httpx.Client = FakeClassifierClientMeasured
for i in range(N):
    clf._classify_with_ollama(note)
after_measured = len(all_rows())
httpx.Client = FakeClassifierClientUnmeasured
clf._classify_with_ollama(note)
after_unmeasured = len(all_rows())
check_caller("cm024k_classifier", "cm024k-ingest-", "ingesting", before, after_measured, after_unmeasured)

# --- email_summarizer (enriching) ---
class FakeAsyncClientGenMeasured:
    def __init__(self, *a, **k): pass
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def post(self, url, json=None, **kw):
        return FakeAsyncResp({"response": "synthetic summary",
                               "prompt_eval_count": 50, "eval_count": 30})
class FakeAsyncClientGenUnmeasured(FakeAsyncClientGenMeasured):
    async def post(self, url, json=None, **kw):
        return FakeAsyncResp({"response": "synthetic summary"})

summarizer = es_mod.EmailSummarizer()
before = len(all_rows())
httpx.AsyncClient = FakeAsyncClientGenMeasured
for i in range(N):
    asyncio.run(summarizer._call_ollama(f"synthetic thread {i}"))
after_measured = len(all_rows())
httpx.AsyncClient = FakeAsyncClientGenUnmeasured
asyncio.run(summarizer._call_ollama("synthetic unmeasured thread"))
after_unmeasured = len(all_rows())
check_caller("cm024k_email_summarizer", "cm024k-enrich-", "enriching", before, after_measured, after_unmeasured)

# --------------------------------------------------------------------- cm059
sys.path.insert(0, str(repo / "vendor/cm059_editor"))
os.environ["OSTLER_SCOUT_LLM"] = "1"
os.environ.pop("SKIP_LLM", None)

try:
    import compiler.scout_newsletters as sn_mod
except Exception as exc:
    print(f"IMPORT_FAILED cm059 {type(exc).__name__}: {exc}")
    raise SystemExit(0)

class FakeHTTPResponse:
    def __init__(self, data):
        self._d = json.dumps(data).encode("utf-8")
    def read(self): return self._d
    def __enter__(self): return self
    def __exit__(self, *a): return False

def make_urlopen(payload):
    def _urlopen(req, timeout=None):
        return FakeHTTPResponse(payload)
    return _urlopen

scored = [{"title": "Synthetic A", "relevance": 0.1, "matched_domains": []},
          {"title": "Synthetic B", "relevance": 0.2, "matched_domains": []}]
profile = {"domains": [{"interests": [
    {"subject": "synthetic hobby", "score": 0.5, "domain": "Tech"}
]}]}

before = len(all_rows())
urllib.request.urlopen = make_urlopen(
    {"response": json.dumps({"0": 0.8, "1": 0.2}), "prompt_eval_count": 15, "eval_count": 3})
for i in range(N):
    sn_mod._llm_relevance(scored, profile)
after_measured = len(all_rows())
urllib.request.urlopen = make_urlopen({"response": json.dumps({"0": 0.5, "1": 0.5})})
sn_mod._llm_relevance(scored, profile)
after_unmeasured = len(all_rows())
check_caller("cm059_scout_newsletters", "cm059-notice-", "noticing", before, after_measured, after_unmeasured)

# --------------------------------------------------------------------- report
total_measured = sum(v[0] for v in results.values())
print(f"TOTAL_MEASURED {total_measured}")
print(f"EXPECTED_TOTAL {N * 5}")
for name, (measured_new, prefix_ok, purpose_ok, unmeasured_new) in results.items():
    print(f"CALLER {name} rows={measured_new} prefix_ok={prefix_ok} purpose_ok={purpose_ok} unmeasured_new={unmeasured_new}")
PY
)

if grep -q 'DEP_MISSING' <<<"$out"; then
    dep=$(grep -o 'DEP_MISSING.*' <<<"$out" | head -1 | awk '{print $2}')
    echo "  CANNOT-RUN: the runner has no '${dep}'. Nothing below was measured."
    exit 2
fi
if grep -q 'IMPORT_FAILED' <<<"$out"; then
    bad "a vendored module does not import: $(grep -o 'IMPORT_FAILED.*' <<<"$out" | head -1)"
    echo "$out"
    echo
    echo "  passed ${pass}, failed ${fail}"
    exit 1
fi

for name in cm019_vectorizer cm024k_embedder cm024k_classifier cm024k_email_summarizer cm059_scout_newsletters; do
    line=$(grep -E "^CALLER ${name} " <<<"$out")
    if [ -z "$line" ]; then
        bad "no result line for ${name} -- the run did not reach it"
        continue
    fi
    rows=$(sed -n 's/.*rows=\([0-9]*\).*/\1/p' <<<"$line")
    prefix_ok=$(sed -n 's/.*prefix_ok=\([A-Za-z]*\).*/\1/p' <<<"$line")
    purpose_ok=$(sed -n 's/.*purpose_ok=\([A-Za-z]*\).*/\1/p' <<<"$line")
    unmeasured_new=$(sed -n 's/.*unmeasured_new=\([0-9]*\).*/\1/p' <<<"$line")

    [ "$rows" = "3" ] && ok "${name}: ${rows} measured calls -> exactly ${rows} rows (N=3)" \
                       || bad "${name}: expected exactly 3 rows for 3 measured calls, got ${rows}"
    [ "$prefix_ok" = "True" ] && ok "${name}: every row's session_id carries its declared prefix" \
                              || bad "${name}: at least one row has the wrong session_id prefix"
    [ "$purpose_ok" = "True" ] && ok "${name}: every row carries its declared purpose" \
                               || bad "${name}: at least one row has the wrong purpose"
    [ "$unmeasured_new" = "0" ] && ok "${name}: MUST-MISS -- one unmeasured call adds zero rows" \
                                 || bad "${name}: an unmeasured call added ${unmeasured_new} row(s) (want 0)"
done

total=$(grep -o 'TOTAL_MEASURED [0-9]*' <<<"$out" | awk '{print $2}')
expected=$(grep -o 'EXPECTED_TOTAL [0-9]*' <<<"$out" | awk '{print $2}')
if [ -n "$total" ] && [ -n "$expected" ] && [ "$total" = "$expected" ]; then
    ok "PARITY: ${total} measured calls across 5 callers -> ${total} journal rows (N=3 x 5 callers)"
else
    bad "PARITY BROKEN: ${total:-<none>} rows written against ${expected:-<none>} calls made"
fi

echo
echo "$out" | grep '^CALLER '
echo
echo "  passed ${pass}, failed ${fail}"
[ "$fail" -eq 0 ] || exit 1
exit 0
