#!/usr/bin/env bash
# test_cm041_usage_journal_producer.sh
#
# ===========================================================================
# WHY THIS TEST EXISTS, AND WHY IT IS NOT A GREP FOR AN IMPORT LINE
# ===========================================================================
#
# The usage-journal roster (scripts/usage_journal_producers.tsv) declares
# cm041_identity_resolution as REQUIRED, matched on session_prefix "cm041-"
# AND purpose "enriching". Until this graft landed, that row's own provenance
# said "not yet observable, the producer is unwired".
#
# The producer exists UPSTREAM: CM041 #137, merged 82f45376. It does not reach
# a customer from there. This repo ships VENDORED copies of the CM041 trees,
# pinned behind that commit, and a fix that is merged upstream but absent from
# the vendored copy is exactly the MERGED != IN THE ARTEFACT failure that
# tests/test_vendored_fda_writes_the_usage_journal.sh was written for after the
# ostler_fda producer was lost at the same boundary.
#
# So this test does NOT assert that an import line is present. An import line
# is a spelling, and CM041's own commit message records that py_compile passed
# on a version of this producer carrying two NameErrors, either of which would
# have killed the API server at import. A SYNTAX CHECK IS NOT A NAME CHECK.
# This RUNS both vendored producers and asserts a record is written, with the
# session-id prefix and the purpose read out of the roster rather than
# restated here.
#
# ===========================================================================
# THE TWO PRODUCERS, AND WHY THEY ARE SPELLED DIFFERENTLY
# ===========================================================================
#
#   vendor/cm041/contact_syncer/usage.py       imports the writer as
#       contact_syncer._vendor.ostler_usage_journal.usage_journal
#   vendor/cm041/assistant_api/ical-server.py  imports it as
#       _vendor.ostler_usage_journal.usage_journal
#
# That is not an inconsistency, it is the staging. install.sh copies NAMED
# directories into PIPELINE_DIR (contact_syncer, meeting_syncer,
# identity_resolver, pwg_privacy.py) and nothing else, so a repo-root sibling
# _vendor/ would never ship and the contact_syncer copy has to nest inside the
# package. ical-server.py is executed as a SCRIPT and install.sh copies its
# directory CONTENTS, so there a sibling _vendor/ is exactly right and matches
# upstream's spelling. Both are asserted by EXECUTION below, which is the only
# check that can tell a correct spelling from a plausible one.
#
# ===========================================================================
# WHAT IS ASSERTED
# ===========================================================================
#   CONTROL 0  the control is live (asserted FIRST, before any zero below is
#              trusted)
#   1  the writer is present in BOTH vendored trees
#   2  and is BYTE-IDENTICAL to vendor/ostler_fda/usage_journal.py, the copy
#      already proven by execution. A fork here is a silent divergence between
#      two writers feeding one panel.
#   3  all six contact_syncer embed sites call the recorder
#   4  RUNNING the contact_syncer producer writes a record
#   5  its session_id carries the prefix the ROSTER matches on
#   6  its purpose is the one the ROSTER declares
#   7  the counts are PASSED THROUGH UNCHANGED (measured, never estimated)
#   8  MUST-MISS: no counts reported writes NOTHING
#   9  RUNNING the ical-server producer writes a record, prefix + purpose
#  10  MUST-MISS on the ical-server producer too
#  11  the _embed_text HOT PATH calls the recorder (the arm that goes red if
#      someone later tidies the accounting back out of the call site)
#
# Assertions 8 and 10 are what stop this test being satisfiable by a writer
# that logs unconditionally. Without them a producer that invents a zero-token
# record every call would pass everything else and put a fabricated number on
# a customer's cost panel.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM041="${REPO_ROOT}/vendor/cm041"
CS="${CM041}/contact_syncer"
API="${CM041}/assistant_api"
FDA_JOURNAL="${REPO_ROOT}/vendor/ostler_fda/usage_journal.py"
ROSTER="${REPO_ROOT}/scripts/usage_journal_producers.tsv"

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

PY="${PYTHON3_BIN:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 on PATH"; exit 2; }

# sha256, portable. macOS ships `shasum`, most Linux images ship `sha256sum`,
# and neither is guaranteed on the other. Resolve ONCE and refuse if neither
# exists rather than letting an empty digest compare equal to another empty
# digest, which would report two forked writers as identical.
if command -v shasum >/dev/null 2>&1; then
    _sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
    _sha256() { sha256sum "$1" | cut -d' ' -f1; }
else
    echo "CANNOT-RUN: neither shasum nor sha256sum on PATH"; exit 2
fi
[ -d "$CS" ]  || { echo "CANNOT-RUN: ${CS} absent"; exit 2; }
[ -d "$API" ] || { echo "CANNOT-RUN: ${API} absent"; exit 2; }
[ -f "$ROSTER" ] || { echo "CANNOT-RUN: roster absent, cannot state the contract"; exit 2; }

echo "== vendored cm041 usage-journal producer (CM041 #137 at 82f45376) =="

# --- CONTROL 0, asserted FIRST -------------------------------------------
# If this scores zero the tree is unreadable and every zero below is
# meaningless. Refuse rather than report a pass.
ctl=$(grep -cE '^(def |import |from )' "${CS}/syncer.py")
if [ "$ctl" -gt 0 ]; then
    ok "CONTROL live: ${ctl} def/import lines readable in the vendored syncer.py"
else
    echo "  CANNOT-RUN: control scored 0 -- the tree is unreadable, no zero below can be trusted"
    exit 2
fi

# --- the contract, READ from the roster rather than remembered -----------
want_prefix=$(grep -E '^cm041_identity_resolution	' "$ROSTER" | cut -f5)
want_purpose=$(grep -E '^cm041_identity_resolution	' "$ROSTER" | cut -f3)
[ -n "$want_prefix" ] && [ -n "$want_purpose" ] || {
    echo "  CANNOT-RUN: roster has no cm041_identity_resolution row to read the contract from"
    exit 2; }
echo "     roster says: prefix='${want_prefix}' purpose='${want_purpose}'"

# --- 1 + 2: the writer, present and unforked -----------------------------
CS_UJ="${CS}/_vendor/ostler_usage_journal/usage_journal.py"
API_UJ="${API}/_vendor/ostler_usage_journal/usage_journal.py"
for f in "$CS_UJ" "$API_UJ"; do
    if [ -f "$f" ]; then ok "writer present: ${f#${REPO_ROOT}/}"
    else bad "writer ABSENT: ${f#${REPO_ROOT}/} -- the import cannot resolve, producer is dark"; fi
done
if [ -f "$FDA_JOURNAL" ] && [ -f "$CS_UJ" ] && [ -f "$API_UJ" ]; then
    a=$(_sha256 "$FDA_JOURNAL")
    b=$(_sha256 "$CS_UJ")
    c=$(_sha256 "$API_UJ")
    if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "$c" ]; then
        ok "both copies are byte-identical to vendor/ostler_fda/usage_journal.py (${a:0:12}...)"
    else
        bad "a vendored writer has FORKED from vendor/ostler_fda/usage_journal.py"
        echo "     fda=${a:0:12} contact_syncer=${b:0:12} assistant_api=${c:0:12}"
    fi
else
    bad "cannot compare writers, one of the three files is missing"
fi

# --- 3: all six contact_syncer embed sites wired -------------------------
# Counted, with the denominator stated. Six is not a guess: it is the number
# of /api/embed call sites CM041 #137 wired, and each is one `data = resp.json()`
# in this tree.
sites=0
for f in syncer.py linkedin_career.py linkedin_connections.py \
         facebook_friends.py instagram_social.py places_ingest.py; do
    if grep -q 'record_embed_usage(data,' "${CS}/${f}"; then
        sites=$((sites+1))
    else
        bad "contact_syncer/${f} embed site does NOT record usage"
    fi
done
if [ "$sites" -eq 6 ]; then
    ok "all 6 contact_syncer embed sites call record_embed_usage (denominator 6)"
else
    bad "only ${sites} of 6 contact_syncer embed sites record usage"
fi

# --- 4..8: BEHAVIOUR, contact_syncer. Run it. ----------------------------
out=$(cd "$CM041" && "$PY" - "$want_prefix" "$want_purpose" <<'PY' 2>&1
import json, pathlib, sys, tempfile
want_prefix, want_purpose = sys.argv[1], sys.argv[2]
sys.path.insert(0, ".")

# TWO IMPORT FAILURES THAT LOOK IDENTICAL AND MEAN OPPOSITE THINGS.
#   the vendored writer absent -> THE DEFECT. The producer is dark. FAIL.
#   a third-party dep absent   -> the RUNNER is short. CANNOT-RUN, never FAIL.
_OWN = {"usage", "usage_journal", "contact_syncer", "_vendor"}
try:
    from contact_syncer import usage
    import contact_syncer._vendor.ostler_usage_journal.usage_journal as uj
except ModuleNotFoundError as exc:
    name = (getattr(exc, "name", "") or "").split(".")[-1]
    print("IMPORT_FAILED %s: %s" % (type(exc).__name__, exc) if name in _OWN
          else "DEP_MISSING %s" % name)
    raise SystemExit(0)
except Exception as exc:
    print("IMPORT_FAILED %s: %s" % (type(exc).__name__, exc))
    raise SystemExit(0)

tmp = pathlib.Path(tempfile.mkdtemp()) / "costs.jsonl"
uj.resolve_journal_path = lambda: tmp

# A real Ollama /api/embed response shape, WITH counts.
usage.record_embed_usage(
    {"embeddings": [[0.1, 0.2]], "prompt_eval_count": 42, "eval_count": 0},
    "nomic-embed-text",
)
if not tmp.exists():
    print("NO_RECORD_WRITTEN")
    raise SystemExit(0)

rec = json.loads(tmp.read_text().strip().splitlines()[0])
print("WROTE 1")
print("PREFIX_OK" if rec["session_id"].startswith(want_prefix)
      else "PREFIX_BAD %s" % rec["session_id"])
print("PURPOSE_OK" if rec["usage"]["purpose"] == want_purpose
      else "PURPOSE_BAD %s" % rec["usage"]["purpose"])
print("COUNTS_OK" if rec["usage"].get("input_tokens") == 42
      else "COUNTS_BAD %r" % rec["usage"].get("input_tokens"))

# MUST-MISS: no counts reported -> nothing written. Measured, never estimated.
before = len(tmp.read_text().splitlines())
usage.record_embed_usage({"embeddings": [[0.1]]}, "nomic-embed-text")
after = len(tmp.read_text().splitlines())
print("UNMEASURED_SILENT" if before == after else "UNMEASURED_WROTE %d->%d" % (before, after))
PY
)

# CANNOT-RUN FIRST, and it EXITS. Falling through would print failures
# asserting things the run never observed.
if grep -q 'DEP_MISSING' <<<"$out"; then
    dep=$(grep -o 'DEP_MISSING.*' <<<"$out" | head -1 | awk '{print $2}')
    echo "  CANNOT-RUN: the runner has no '${dep}'. The vendored module is not at"
    echo "              fault and NOTHING below was measured. CANNOT-RUN is not"
    echo "              FAIL and is not PASS."
    exit 2
fi
if grep -q 'IMPORT_FAILED' <<<"$out"; then
    bad "the vendored contact_syncer producer does not import: $(printf '%s' "$out" | head -1)"
fi
grep -q 'WROTE 1'          <<<"$out" && ok "RUNNING the contact_syncer producer writes a record" \
                                     || bad "the contact_syncer producer wrote NOTHING on a measured response"
grep -q 'PREFIX_OK'        <<<"$out" && ok "contact_syncer session_id carries the roster's prefix" \
                                     || bad "contact_syncer session_id prefix does NOT match the roster: $(grep -o 'PREFIX_BAD.*' <<<"$out")"
grep -q 'PURPOSE_OK'       <<<"$out" && ok "contact_syncer purpose is the roster's" \
                                     || bad "contact_syncer purpose wrong or never observed: $(grep -o 'PURPOSE_BAD.*' <<<"$out")"
grep -q 'COUNTS_OK'        <<<"$out" && ok "counts passed through UNCHANGED (42 in, 42 recorded)" \
                                     || bad "counts were altered or never observed: $(grep -o 'COUNTS_BAD.*' <<<"$out")"
grep -q 'UNMEASURED_SILENT' <<<"$out" && ok "MUST-MISS: an unmeasured response writes NOTHING" \
                                     || bad "an unmeasured response WROTE a record: $(grep -o 'UNMEASURED_WROTE.*' <<<"$out")"

# --- 9..11: BEHAVIOUR, the assistant API. Run it. ------------------------
# ical-server.py is a SCRIPT with a hyphen in its name, so it is loaded the way
# this repo's own vendored suite loads it (importlib + the ostler_security
# stub), not by import.
out2=$(cd "$API" && "$PY" - "$want_prefix" "$want_purpose" <<'PY' 2>&1
import importlib.util, json, os, pathlib, sys, tempfile, types
want_prefix, want_purpose = sys.argv[1], sys.argv[2]
HERE = pathlib.Path(".").resolve()
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
os.environ.setdefault("USER_ID", "testuser")

# The house stub, mirroring vendor/cm041/assistant_api/tests/
# test_ical_server_wire_shape.py: ical-server hard-fails without it.
import sqlite3 as _sq
pkg = types.ModuleType("ostler_security"); pkg.__path__ = []
sys.modules.setdefault("ostler_security", pkg)
_db = types.ModuleType("ostler_security.database")
_db.get_db_connection = lambda *a, **k: _sq.connect(":memory:")
sys.modules.setdefault("ostler_security.database", _db)
_po = types.ModuleType("ostler_security.posture")
_po.record_posture = lambda *a, **k: None
sys.modules.setdefault("ostler_security.posture", _po)

try:
    spec = importlib.util.spec_from_file_location("ical_server_usage", str(HERE / "ical-server.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    import _vendor.ostler_usage_journal.usage_journal as uj
except ModuleNotFoundError as exc:
    name = (getattr(exc, "name", "") or "").split(".")[-1]
    print("IMPORT_FAILED %s: %s" % (type(exc).__name__, exc)
          if name in {"_vendor", "usage_journal"} else "DEP_MISSING %s" % name)
    raise SystemExit(0)
except Exception as exc:
    print("IMPORT_FAILED %s: %s" % (type(exc).__name__, exc))
    raise SystemExit(0)

tmp = pathlib.Path(tempfile.mkdtemp()) / "costs.jsonl"
uj.resolve_journal_path = lambda: tmp

m._record_embed_usage(
    {"embeddings": [[0.1]], "prompt_eval_count": 17, "eval_count": 0},
    "nomic-embed-text",
)
if not tmp.exists():
    print("NO_RECORD_WRITTEN")
    raise SystemExit(0)
rec = json.loads(tmp.read_text().strip().splitlines()[0])
print("WROTE 1")
print("PREFIX_OK" if rec["session_id"].startswith(want_prefix)
      else "PREFIX_BAD %s" % rec["session_id"])
print("PURPOSE_OK" if rec["usage"]["purpose"] == want_purpose
      else "PURPOSE_BAD %s" % rec["usage"]["purpose"])

before = len(tmp.read_text().splitlines())
m._record_embed_usage({"embeddings": [[0.1]]}, "nomic-embed-text")
after = len(tmp.read_text().splitlines())
print("UNMEASURED_SILENT" if before == after else "UNMEASURED_WROTE %d->%d" % (before, after))

# THE HOT PATH. _embed_text must hand its parsed payload to the recorder.
# This is the arm that goes RED if the accounting is later tidied back out of
# the call site, which is the regression the producer roster exists to catch.
class _Resp:
    def read(self):
        return json.dumps({"embeddings": [[0.5]], "prompt_eval_count": 9,
                           "eval_count": 0}).encode()
import urllib.request as _u
_orig = _u.urlopen
_u.urlopen = lambda *a, **k: _Resp()
try:
    n_before = len(tmp.read_text().splitlines())
    vec = m._embed_text("a synthetic string, no person in it")
    n_after = len(tmp.read_text().splitlines())
    print("HOTPATH_OK" if n_after == n_before + 1 and vec == [0.5]
          else "HOTPATH_BAD %d->%d vec=%r" % (n_before, n_after, vec))
finally:
    _u.urlopen = _orig
PY
)

if grep -q 'DEP_MISSING' <<<"$out2"; then
    dep=$(grep -o 'DEP_MISSING.*' <<<"$out2" | head -1 | awk '{print $2}')
    echo "  CANNOT-RUN: the runner has no '${dep}' so the assistant-API arm could"
    echo "              not be measured. The vendored module is not at fault."
    echo "              Reporting what WAS measured above; rc reflects that only."
else
    if grep -q 'IMPORT_FAILED' <<<"$out2"; then
        bad "the vendored ical-server producer does not import: $(printf '%s' "$out2" | head -1)"
    fi
    grep -q 'WROTE 1'           <<<"$out2" && ok "RUNNING the ical-server producer writes a record" \
                                           || bad "the ical-server producer wrote NOTHING on a measured response"
    grep -q 'PREFIX_OK'         <<<"$out2" && ok "ical-server session_id carries the roster's prefix" \
                                           || bad "ical-server session_id prefix wrong: $(grep -o 'PREFIX_BAD.*' <<<"$out2")"
    grep -q 'PURPOSE_OK'        <<<"$out2" && ok "ical-server purpose is the roster's" \
                                           || bad "ical-server purpose wrong: $(grep -o 'PURPOSE_BAD.*' <<<"$out2")"
    grep -q 'UNMEASURED_SILENT' <<<"$out2" && ok "MUST-MISS: unmeasured ical-server response writes NOTHING" \
                                           || bad "unmeasured ical-server response WROTE a record: $(grep -o 'UNMEASURED_WROTE.*' <<<"$out2")"
    grep -q 'HOTPATH_OK'        <<<"$out2" && ok "the _embed_text HOT PATH records usage and still returns its vector" \
                                           || bad "_embed_text does not record on the hot path: $(grep -o 'HOTPATH_BAD.*' <<<"$out2")"
fi

echo ""
echo "  passed ${pass}, failed ${fail}"
[ "$fail" -eq 0 ] || exit 1
exit 0
