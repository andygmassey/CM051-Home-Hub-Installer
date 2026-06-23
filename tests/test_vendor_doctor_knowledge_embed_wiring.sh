#!/usr/bin/env bash
#
# tests/test_vendor_doctor_knowledge_embed_wiring.sh
#
# Locks the #519 convert->embed wiring in the VENDORED Doctor "Import
# Evernote" runner (the copy that actually ships in the installer .app).
#
# The gap #519 closed: Doctor's start_import used to fork ONLY
# `ostler-knowledge convert ... --output <staging>`, writing markdown to
# the staging tree but never embedding it into the evernote_knowledge
# Qdrant collection. The CM044 wiki Knowledge section + RAG-over-notes
# read that collection, so it stayed silently empty on a fresh install.
#
# The fix chains an embed phase after convert via the runner's
# `--and-then` sentinel, with a privacy cap that keeps L3 notes out of
# search and the nomic-embed-text/768 model that matches the
# pre-created collection.
#
# Structural grep assertions over the vendored Python (no live Qdrant /
# Ollama / Doctor process), mirroring tests/test_knowledge_repo_wiring.sh.
# The behavioural coverage (Popen argv shape, phase ordering, partial
# status) lives in the vendored pytest suite
# (vendor/doctor/agent/test_import_evernote.py).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IE="${REPO_ROOT}/vendor/doctor/agent/import_evernote.py"
RUNNER="${REPO_ROOT}/vendor/doctor/agent/import_evernote_runner.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

for f in "$IE" "$RUNNER"; do
    [[ -f "$f" ]] || fail "missing vendored file: $f"
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" \
        || fail "$(basename "$f") does not parse"
done
echo "PASS: vendored doctor knowledge files parse"

# ── start_import chains an embed phase after convert ────────────────
grep -q 'embed_phase' "$IE" \
    || fail "[no-embed-phase] start_import does not build an embed phase (#519 regressed)"
echo "PASS: start_import builds an embed phase"

grep -q '"--and-then"' "$IE" \
    || fail "[no-sentinel] convert and embed are not chained via --and-then"
echo "PASS: convert->embed chained via --and-then sentinel"

# ── embed targets the right collection + 768-dim model ──────────────
grep -q '_collection_for_source' "$IE" \
    || fail "[no-collection] embed phase does not target a <source>_knowledge collection"
grep -Eq 'nomic-embed-text|DEFAULT_EMBED_MODEL' "$IE" \
    || fail "[wrong-model] embed phase does not use the 768-dim nomic-embed-text model"
echo "PASS: embed phase targets <source>_knowledge with nomic-embed-text"

# ── L3 privacy cap passed to embed ──────────────────────────────────
grep -q '"--max-compartment-level"' "$IE" \
    || fail "[no-privacy-cap] embed phase does not pass --max-compartment-level (L3 could leak)"
grep -q 'DEFAULT_MAX_COMPARTMENT_LEVEL = 2' "$IE" \
    || fail "[wrong-cap-default] default compartment cap is not 2 (L3 exclusion)"
echo "PASS: embed phase passes the L3 privacy cap (default 2)"

# ── runner executes phases sequentially, stops on first failure ─────
grep -q 'PHASE_SENTINEL' "$RUNNER" \
    || fail "[runner-no-sentinel] runner does not recognise the phase sentinel"
grep -q '_split_phases' "$RUNNER" \
    || fail "[runner-no-split] runner does not split chained phases"
echo "PASS: runner splits + sequences chained phases"

# ── graceful-degrade: convert ok but embed fail => partial ──────────
grep -q '"partial"' "$RUNNER" \
    || fail "[runner-no-partial] runner has no graceful-degrade 'partial' status (notes imported, search pending)"
echo "PASS: runner surfaces 'partial' when only embed fails"

echo "ALL PASS: vendored Doctor convert->embed wiring (#519) locked"
