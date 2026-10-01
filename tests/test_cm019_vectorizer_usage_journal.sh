#!/usr/bin/env bash
# test_cm019_vectorizer_usage_journal.sh (#2472)
#
# ===========================================================================
# WHY THIS TEST EXISTS
# ===========================================================================
#
# vendor/cm019_preferences/services/ingest/src/vectorizer.py posts to Ollama's
# own ``/api/embed`` directly (the CM051-side swap from upstream's
# sentence-transformers, documented in the module's own docstring) and, until
# this change, read nothing back but ``embeddings``. On a 2026-10-01 walk,
# Ollama's own log showed 13,636 embed calls + 481 generate calls in a
# one-hour window while ``costs.jsonl`` recorded ZERO rows in that window
# (issue #2472). This file is one of the five silent producers found by that
# sweep.
#
# CM019's SOURCE repo (andygmassey/personal-world-graph) has no Ollama call at
# all -- it embeds via sentence-transformers -- so there is no upstream fix to
# graft. This wiring can only ever exist here, vendor-side, which is why this
# test runs against the vendored copy and not a source repo.
#
# Not a grep for an import line: it RUNS ``Vectorizer.embed_batch`` against a
# monkeypatched Ollama HTTP response and asserts a record is written, with the
# session-id prefix and purpose this module's own code emits
# (``cm019-ingest-`` / ``ingesting``) -- scripts/usage_journal_producers.tsv
# deliberately carries no row for this producer yet (see cut-manifests/
# v1.0.107.yaml), so the contract is read from the module, not the roster.
#
# ===========================================================================
# WHAT IS ASSERTED (6 assertions + 1 control)
# ===========================================================================
#   CONTROL 0  the control itself is live
#   1  vendor/.../src/_vendor/ostler_usage_journal/usage_journal.py EXISTS
#   2  vectorizer.py imports the writer
#   3  RUNNING embed_batch() against a measured response writes ONE record
#   4  the record's session_id carries the "cm019-ingest-" prefix
#   5  the record's purpose is "ingesting"
#   6  MUST-MISS: an Ollama response with no token counts writes NOTHING
#      ("measured, never estimated")
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM019_ROOT="${REPO_ROOT}/vendor/cm019_preferences/services/ingest"
VECTORIZER="${CM019_ROOT}/src/vectorizer.py"
JOURNAL_MOD="${CM019_ROOT}/src/_vendor/ostler_usage_journal/usage_journal.py"

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

PY="${PYTHON3_BIN:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 on PATH"; exit 2; }
[ -f "$VECTORIZER" ] || { echo "CANNOT-RUN: $VECTORIZER absent"; exit 2; }

echo "== vendored cm019 vectorizer usage-journal producer =="

# --- CONTROL 0 ------------------------------------------------------------
ctl=$(grep -cE '^(def |import |from )' "$VECTORIZER")
if [ "$ctl" -gt 0 ]; then
    ok "CONTROL live: ${ctl} def/import lines readable in vectorizer.py"
else
    echo "  CANNOT-RUN: control scored 0 -- the file is unreadable, no zero below can be trusted"
    exit 2
fi

# --- 1: the writer that was missing ---------------------------------------
if [ -f "$JOURNAL_MOD" ]; then
    ok "src/_vendor/ostler_usage_journal/usage_journal.py exists"
else
    bad "src/_vendor/ostler_usage_journal/usage_journal.py is ABSENT -- the import cannot resolve"
fi

# --- 2: the wiring, as a spelling (cheap, not the real assertion) --------
if grep -q 'from ._vendor.ostler_usage_journal import record_usage' "$VECTORIZER"; then
    ok "vectorizer.py imports record_usage"
else
    bad "vectorizer.py does NOT import record_usage"
fi

# --- 3..6: BEHAVIOUR. Run it. ---------------------------------------------
out=$(cd "$REPO_ROOT" && "$PY" - <<'PY' 2>&1
import json, pathlib, sys, tempfile, types, os

repo = pathlib.Path(".").resolve()
cm019_root = repo / "vendor/cm019_preferences/services/ingest"
sys.path.insert(0, str(cm019_root))

tmp_dir = pathlib.Path(tempfile.mkdtemp())
os.environ["ZEROCLAW_CONFIG_DIR"] = str(tmp_dir)
journal = tmp_dir / "workspace" / "state" / "costs.jsonl"

def lines():
    if not journal.exists():
        return []
    return [json.loads(l) for l in journal.read_text().splitlines() if l.strip()]

# vectorizer.py does `from .config import settings`, and src/config.py needs
# pydantic_settings, a THIRD-PARTY dep this producer's own logic does not
# touch. Stub it so a missing pydantic_settings on the runner cannot hide a
# real wiring defect behind a DEP_MISSING CANNOT-RUN. The CM019 install.sh
# venv pins pydantic-settings for real, per vendor/cm019_preferences/
# requirements.txt; this stub exists only for THIS test's isolation.
cfg_mod = types.ModuleType("src.config")
class _Settings:
    ollama_url = "http://127.0.0.1:11434"
    embedding_model = "nomic-embed-text"
    embedding_dim = 768
    batch_size = 8
cfg_mod.settings = _Settings()
sys.modules["src.config"] = cfg_mod

try:
    import httpx
except ModuleNotFoundError as exc:
    print(f"DEP_MISSING {exc.name}")
    raise SystemExit(0)

try:
    import src.vectorizer as vec_mod
except Exception as exc:
    print(f"IMPORT_FAILED {type(exc).__name__}: {exc}")
    raise SystemExit(0)

class FakeResp:
    def __init__(self, data): self._d = data
    def raise_for_status(self): pass
    def json(self): return self._d

def fake_post_measured(self, url, json=None, **kw):
    return FakeResp({"embeddings": [[0.1, 0.2]], "prompt_eval_count": 7, "eval_count": 0})

httpx.Client.post = fake_post_measured
before = len(lines())
vec_mod.Vectorizer().embed_batch(["a synthetic sentence, no person in it"])
after = lines()
if len(after) != before + 1:
    print(f"NO_RECORD_WRITTEN before={before} after={len(after)}")
    raise SystemExit(0)
rec = after[-1]
print("WROTE 1")
print("PREFIX_OK" if rec["session_id"].startswith("cm019-ingest-") else
      f"PREFIX_BAD {rec['session_id']}")
print("PURPOSE_OK" if rec["usage"]["purpose"] == "ingesting" else
      f"PURPOSE_BAD {rec['usage']['purpose']}")

# MUST-MISS: no counts reported -> nothing written.
def fake_post_unmeasured(self, url, json=None, **kw):
    return FakeResp({"embeddings": [[0.1, 0.2]]})
httpx.Client.post = fake_post_unmeasured
before2 = len(lines())
vec_mod.Vectorizer().embed_batch(["another synthetic sentence"])
after2 = len(lines())
print("UNMEASURED_SILENT" if before2 == after2 else f"UNMEASURED_WROTE {before2}->{after2}")
PY
)

if grep -q 'DEP_MISSING' <<<"$out"; then
    dep=$(grep -o 'DEP_MISSING.*' <<<"$out" | head -1 | awk '{print $2}')
    echo "  CANNOT-RUN: the runner has no '${dep}'. The vendored module is not"
    echo "              at fault and NOTHING below was measured."
    exit 2
fi

if grep -q 'IMPORT_FAILED' <<<"$out"; then
    bad "the vendored module does not import: $(printf '%s' "$out" | head -1)"
fi
grep -q 'WROTE 1'           <<<"$out" && ok "RUNNING embed_batch() writes a record" \
                                      || bad "embed_batch() wrote NOTHING on a measured response: $(printf '%s' "$out" | head -1)"
grep -q 'PREFIX_OK'         <<<"$out" && ok "session_id carries the cm019-ingest- prefix" \
                                      || bad "session_id prefix is wrong: $(grep -o 'PREFIX_BAD.*' <<<"$out")"
grep -q 'PURPOSE_OK'        <<<"$out" && ok "purpose is 'ingesting'" \
                                      || bad "purpose is wrong: $(grep -o 'PURPOSE_BAD.*' <<<"$out")"
grep -q 'UNMEASURED_SILENT' <<<"$out" && ok "MUST-MISS: an unmeasured response writes nothing (no invented numbers)" \
                                      || bad "the must-miss arm did not pass: $(grep -o 'UNMEASURED_WROTE.*' <<<"$out")"

echo
echo "  passed ${pass}, failed ${fail}"
[ "$fail" -eq 0 ] || exit 1
exit 0
