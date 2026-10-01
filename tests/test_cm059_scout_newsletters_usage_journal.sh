#!/usr/bin/env bash
# test_cm059_scout_newsletters_usage_journal.sh (#2472)
#
# ===========================================================================
# WHY THIS TEST EXISTS
# ===========================================================================
#
# vendor/cm059_editor/compiler/scout_newsletters.py's ``_llm_relevance`` posts
# to Ollama's own ``/api/generate`` via stdlib ``urllib.request`` (not httpx,
# unlike every other producer in this PR) and, until this change, read
# nothing back but ``response``. This is one of five vendored call sites
# found by the #2472 sweep. The path is opt-in (``OSTLER_SCOUT_LLM=1``, off by
# default) -- still a real producer once a customer enables it -- and it is
# unprompted curation of the operator's own newsletters, so its purpose is
# ``noticing``: the roster's own definition of work the assistant chose to do
# unprompted.
#
# cm059_editor is a vendor-only divergence: there is no equivalent upstream
# fix possible for this file (it is CM051-authored wiring layered on CM059's
# own opt-in re-rank), so unlike the cm024 producers there is no companion
# source-repo PR for this one.
#
# Not a grep for an import line: it RUNS ``_llm_relevance`` against a
# monkeypatched Ollama HTTP response (via urllib.request.urlopen, matching
# this file's own transport) and asserts a record is written, and that the
# deterministic fallback still stands when the LLM path is OFF.
# scripts/usage_journal_producers.tsv deliberately carries no row for this
# producer yet (see cut-manifests/v1.0.107.yaml).
#
# ===========================================================================
# WHAT IS ASSERTED (7 assertions + 1 control)
# ===========================================================================
#   CONTROL 0  the control itself is live
#   1  compiler/_vendor/ostler_usage_journal/usage_journal.py EXISTS
#   2  scout_newsletters.py imports the writer
#   3  the opt-in gate itself: ``_llm_enabled()`` is False with
#      OSTLER_SCOUT_LLM unset (the default -- ``candidates()``/
#      ``build_cards()`` never call ``_llm_relevance`` in that state) and True
#      once it is set to "1"
#   4  with a measured response, RUNNING _llm_relevance() writes ONE record
#   5  the record's session_id carries the "cm059-notice-" prefix
#   6  the record's purpose is "noticing"
#   7  MUST-MISS: an Ollama response with no token counts writes NOTHING
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM059_ROOT="${REPO_ROOT}/vendor/cm059_editor"
SCOUT="${CM059_ROOT}/compiler/scout_newsletters.py"
JOURNAL_MOD="${CM059_ROOT}/compiler/_vendor/ostler_usage_journal/usage_journal.py"

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

PY="${PYTHON3_BIN:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 on PATH"; exit 2; }
[ -f "$SCOUT" ] || { echo "CANNOT-RUN: $SCOUT absent"; exit 2; }

echo "== vendored cm059 scout_newsletters.py usage-journal producer =="

ctl=$(grep -cE '^(def |import |from )' "$SCOUT")
if [ "$ctl" -gt 0 ]; then
    ok "CONTROL live: ${ctl} def/import lines readable in scout_newsletters.py"
else
    echo "  CANNOT-RUN: control scored 0 -- the file is unreadable, no zero below can be trusted"
    exit 2
fi

if [ -f "$JOURNAL_MOD" ]; then
    ok "compiler/_vendor/ostler_usage_journal/usage_journal.py exists"
else
    bad "compiler/_vendor/ostler_usage_journal/usage_journal.py is ABSENT"
fi

if grep -q 'from compiler._vendor.ostler_usage_journal import record_usage' "$SCOUT"; then
    ok "scout_newsletters.py imports record_usage"
else
    bad "scout_newsletters.py does NOT import record_usage"
fi

out=$(cd "$REPO_ROOT" && "$PY" - <<'PY' 2>&1
import json, pathlib, sys, tempfile, os, urllib.request

repo = pathlib.Path(".").resolve()
sys.path.insert(0, str(repo / "vendor/cm059_editor"))

tmp_dir = pathlib.Path(tempfile.mkdtemp())
os.environ["ZEROCLAW_CONFIG_DIR"] = str(tmp_dir)
os.environ.pop("SKIP_LLM", None)
os.environ.pop("OSTLER_SCOUT_LLM", None)
journal = tmp_dir / "workspace" / "state" / "costs.jsonl"

def lines():
    if not journal.exists():
        return []
    return [json.loads(l) for l in journal.read_text().splitlines() if l.strip()]

try:
    import compiler.scout_newsletters as sn_mod
except Exception as exc:
    print(f"IMPORT_FAILED {type(exc).__name__}: {exc}")
    raise SystemExit(0)

scored = [{"title": "synthetic story one", "relevance": 0.1, "matched_domains": []},
          {"title": "synthetic story two", "relevance": 0.2, "matched_domains": []}]
profile = {"domains": [{"interests": [
    {"subject": "synthetic gaming hobby", "score": 0.5, "domain": "Tech"}
]}]}

class FakeHTTPResponse:
    def __init__(self, data):
        self._d = json.dumps(data).encode("utf-8")
    def read(self):
        return self._d
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False

MEASURED = {"response": json.dumps({"0": 0.8, "1": 0.2}),
            "prompt_eval_count": 15, "eval_count": 3}
UNMEASURED = {"response": json.dumps({"0": 0.5, "1": 0.5})}

def make_urlopen(payload):
    def _urlopen(req, timeout=None):
        return FakeHTTPResponse(payload)
    return _urlopen

# --- 3: the opt-in gate itself. candidates()/build_cards() call
# _llm_relevance ONLY when _llm_enabled() is True, so the gate that matters is
# this predicate, not a re-implementation of its caller's branch.
print("GATE_OFF_OK" if sn_mod._llm_enabled() is False else "GATE_OFF_BAD")
os.environ["OSTLER_SCOUT_LLM"] = "1"
print("GATE_ON_OK" if sn_mod._llm_enabled() is True else "GATE_ON_BAD")

# --- 4..6: LLM ON, measured response. --------------------------------------
urllib.request.urlopen = make_urlopen(MEASURED)
before = len(lines())
out_on = sn_mod._llm_relevance(scored, profile)
after = lines()
if out_on is None or len(after) != before + 1:
    print(f"NO_RECORD_WRITTEN before={before} after={len(after)} out={out_on!r}")
    raise SystemExit(0)
rec = after[-1]
print("WROTE 1")
print("PREFIX_OK" if rec["session_id"].startswith("cm059-notice-") else
      f"PREFIX_BAD {rec['session_id']}")
print("PURPOSE_OK" if rec["usage"]["purpose"] == "noticing" else
      f"PURPOSE_BAD {rec['usage']['purpose']}")

# --- 7: MUST-MISS -----------------------------------------------------------
urllib.request.urlopen = make_urlopen(UNMEASURED)
before2 = len(lines())
sn_mod._llm_relevance(scored, profile)
after2 = len(lines())
print("UNMEASURED_SILENT" if before2 == after2 else f"UNMEASURED_WROTE {before2}->{after2}")
PY
)

if grep -q 'IMPORT_FAILED' <<<"$out"; then
    bad "the vendored module does not import: $(printf '%s' "$out" | head -1)"
fi
grep -q 'GATE_OFF_OK'       <<<"$out" && ok "_llm_enabled() is False with OSTLER_SCOUT_LLM unset (the default)" \
                                      || bad "_llm_enabled() was True with OSTLER_SCOUT_LLM unset"
grep -q 'GATE_ON_OK'        <<<"$out" && ok "_llm_enabled() is True with OSTLER_SCOUT_LLM=1" \
                                      || bad "_llm_enabled() was False with OSTLER_SCOUT_LLM=1"
grep -q 'WROTE 1'           <<<"$out" && ok "with OSTLER_SCOUT_LLM=1, RUNNING _llm_relevance() writes a record" \
                                      || bad "_llm_relevance() wrote NOTHING on a measured response: $(printf '%s' "$out" | head -1)"
grep -q 'PREFIX_OK'         <<<"$out" && ok "session_id carries the cm059-notice- prefix" \
                                      || bad "session_id prefix is wrong: $(grep -o 'PREFIX_BAD.*' <<<"$out")"
grep -q 'PURPOSE_OK'        <<<"$out" && ok "purpose is 'noticing'" \
                                      || bad "purpose is wrong: $(grep -o 'PURPOSE_BAD.*' <<<"$out")"
grep -q 'UNMEASURED_SILENT' <<<"$out" && ok "MUST-MISS: an unmeasured response writes nothing (no invented numbers)" \
                                      || bad "the must-miss arm did not pass: $(grep -o 'UNMEASURED_WROTE.*' <<<"$out")"

echo
echo "  passed ${pass}, failed ${fail}"
[ "$fail" -eq 0 ] || exit 1
exit 0
