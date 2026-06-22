#!/usr/bin/env bash
# vendor/cm019_preferences ingest regression + freshness gate
# ===========================================================
#
# Asserts that vendor/cm019_preferences/ ships the pieces install.sh's
# hydrate_preferences sub-phase needs at customer install time, AND that
# the vendored copy is the Ostler-SWAPPED version, not a stale re-vendor
# of CM019 main.
#
# Why the freshness gate matters (CX-83 stale-vendor class): upstream
# CM019 main embeds preferences with sentence-transformers (all-MiniLM,
# 384-dim) and writes to the `pwg_preferences` collection. The vendored
# copy here is deliberately rewired to:
#
#   - vectorizer.py  -> local Ollama /api/embed (nomic-embed-text, 768-dim),
#                       NO torch / sentence-transformers
#   - config.py      -> qdrant_collection default "preferences" (CM044 reads
#                       this), embedding_dim 768, embedding_model nomic-embed-text
#   - requirements   -> torch / sentence-transformers / the ML stack DROPPED
#
# If a future re-sync pulls the upstream version back in, the wiki's
# Food / Music / Media / Reading / Apps / Places / Topics pages either
# stay empty (wrong collection) or every upsert fails (384 vs 768 dim
# mismatch). This script catches that BEFORE a customer install.
#
# Network-free, env-var-free, dependency-free for the structural +
# marker checks. The optional import-time check exercises the same
# module path install.sh runs and falls back to inconclusive when the
# runtime deps are missing in CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ING="$SCRIPT_DIR/services/ingest/src"

# ── Structural check (deps-free) ────────────────────────────────────
missing=""
for path in \
    services/ingest/src/cli.py \
    services/ingest/src/pipeline.py \
    services/ingest/src/vectorizer.py \
    services/ingest/src/config.py \
    services/ingest/src/parsers/email.py \
    services/enrich/src/cli.py \
    services/enrich/src/enricher.py \
    services/enrich/src/config.py \
    requirements.txt
do
    if [ ! -f "$SCRIPT_DIR/$path" ]; then
        missing="$missing $path"
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL: vendor/cm019_preferences/ missing files:$missing" >&2
    echo "      Re-sync from CM019 services/ingest/ (see vendor/README.md)." >&2
    exit 1
fi
echo "structural check: cli.py + pipeline.py + vectorizer.py + config.py + email.py + requirements.txt present"

# ── Ollama-swap freshness markers in vectorizer.py ──────────────────
# The vendored vectorizer MUST hit the local Ollama embed endpoint.
if ! grep -q '/api/embed' "$ING/vectorizer.py"; then
    echo "FAIL: vectorizer.py does not call the Ollama /api/embed endpoint." >&2
    echo "      This looks like a stale re-vendor of CM019 main (sentence-transformers)." >&2
    exit 1
fi
# And MUST NOT import the torch / sentence-transformers stack. Match real
# import statements only -- the module docstring mentions these names in
# prose explaining the swap, which is fine.
if grep -qE '^[[:space:]]*(import|from)[[:space:]]+(torch|sentence_transformers|transformers|sklearn|nltk)\b' "$ING/vectorizer.py"; then
    echo "FAIL: vectorizer.py imports the torch/ML stack -- stale upstream copy." >&2
    echo "      Re-apply the Ostler Ollama vectorizer swap before bundling." >&2
    exit 1
fi
echo "vectorizer check: Ollama /api/embed present, no torch/sentence-transformers imports"

# ── Collection + embedding-space lock-ins in config.py ──────────────
# These are the load-bearing values; a refactor must not silently shift
# them or the wiki read side breaks.
if ! grep -qE 'qdrant_collection:[[:space:]]*str[[:space:]]*=[[:space:]]*Field\(default="preferences"' "$ING/config.py"; then
    echo "FAIL: config.py qdrant_collection default is not \"preferences\"." >&2
    echo "      CM044 reads the 'preferences' collection; a mismatch blanks 7+ wiki pages." >&2
    exit 1
fi
if ! grep -qE 'embedding_dim:[[:space:]]*int[[:space:]]*=[[:space:]]*Field\(default=768' "$ING/config.py"; then
    echo "FAIL: config.py embedding_dim default is not 768." >&2
    echo "      The 'preferences' collection is pre-created at 768; 384 fails to upsert." >&2
    exit 1
fi
if ! grep -qE 'embedding_model:[[:space:]]*str[[:space:]]*=[[:space:]]*Field\(default="nomic-embed-text"' "$ING/config.py"; then
    echo "FAIL: config.py embedding_model default is not \"nomic-embed-text\"." >&2
    exit 1
fi
echo "config check: collection=preferences, embedding_dim=768, model=nomic-embed-text"

# ── enrich service is WIRED on the same collection ──────────────────
# enrich (normalisation + canonical-entity lookups) reads/writes the same
# `preferences` collection. Upstream CM019 default was pwg_preferences; a
# stale re-vendor here would silently enrich the wrong collection.
if ! grep -qE 'qdrant_collection:[[:space:]]*str[[:space:]]*=[[:space:]]*Field\(default="preferences"' "$SCRIPT_DIR/services/enrich/src/config.py"; then
    echo "FAIL: services/enrich/src/config.py qdrant_collection is not \"preferences\"." >&2
    echo "      enrich would normalise/enrich a collection CM044 never reads." >&2
    exit 1
fi
echo "enrich check: enrich config collection=preferences"

# ── Re-ingest idempotency (load-bearing for the export watcher) ─────
# ParsedPreference.id MUST be a stable, content-derived id, NOT a random
# uuid4 default. The export watcher re-runs ostler-import over Downloads,
# so a random id would mint duplicate Qdrant points + RDF triples on every
# pass. base.py derives the id from (source, source_id|subject, category,
# type) via uuid5 in __post_init__.
_BASE="$SCRIPT_DIR/services/ingest/src/parsers/base.py"
if grep -qE 'id:[[:space:]]*str[[:space:]]*=[[:space:]]*field\(default_factory=lambda:[[:space:]]*str\(uuid\.uuid4' "$_BASE"; then
    echo "FAIL: ParsedPreference.id still uses a random uuid4 default." >&2
    echo "      Re-ingest would duplicate preferences; restore the stable" >&2
    echo "      content-keyed id (uuid5 in __post_init__)." >&2
    exit 1
fi
# Accept either the inline NAMESPACE_URL form (older vendor graft) or a
# dedicated module-level uuid5 namespace (CM019 main 8f6efb8's
# _PREFERENCE_ID_NAMESPACE). Both are stable content-keyed uuid5 ids; the
# uuid4 rejection above is what guards the actual regression.
if ! grep -qE 'uuid\.uuid5\(' "$_BASE"; then
    echo "FAIL: ParsedPreference.__post_init__ is missing the stable uuid5 id." >&2
    exit 1
fi
echo "idempotency check: ParsedPreference.id is content-keyed (uuid5), not random"

# ── requirements.txt must NOT carry the dropped ML stack ────────────
# Strip comments first -- the file documents the DROPPED deps in prose.
REQS_ACTIVE="$(grep -vE '^[[:space:]]*#' "$SCRIPT_DIR/requirements.txt" | grep -vE '^[[:space:]]*$' || true)"
for banned in torch sentence-transformers transformers scikit-learn nltk fastapi uvicorn aiokafka; do
    if printf '%s\n' "$REQS_ACTIVE" | grep -qiE "^[[:space:]]*${banned}([[:space:]<>=!~]|$)"; then
        echo "FAIL: requirements.txt lists '${banned}' as an active dependency." >&2
        echo "      The hydrate_preferences path does not need it; drop it to keep the bundle lean." >&2
        exit 1
    fi
done
echo "requirements check: torch/sentence-transformers/server/Kafka stack absent from active deps"

# enrich is wired, so its two light deps MUST be present (no torch).
for needed in aiohttp aiolimiter; do
    if ! printf '%s\n' "$REQS_ACTIVE" | grep -qiE "^[[:space:]]*${needed}([[:space:]<>=!~]|$)"; then
        echo "FAIL: requirements.txt is missing '${needed}' -- enrich is wired and needs it." >&2
        exit 1
    fi
done
echo "requirements check: enrich deps (aiohttp + aiolimiter) present"

# ── Optional import-time check ──────────────────────────────────────
# Mirrors how install.sh invokes the CLI
# ("python -m services.ingest.src.cli ..."). Falls back to inconclusive
# when httpx / pydantic are missing -- those are pip-installed by the
# hydrate_preferences venv setup, not by this structural runner.
PY_IMPORT_CHECK=$(cd "$SCRIPT_DIR" && QDRANT_COLLECTION=preferences /usr/bin/env python3 - <<'PY'
import sys, importlib
try:
    cfg = importlib.import_module("services.ingest.src.config")
    vec = importlib.import_module("services.ingest.src.vectorizer")
    importlib.import_module("services.ingest.src.pipeline")
    ecfg = importlib.import_module("services.enrich.src.config")
    importlib.import_module("services.enrich.src.enricher")
    assert cfg.settings.qdrant_collection == "preferences", "collection != preferences"
    assert cfg.settings.embedding_dim == 768, "embedding_dim != 768"
    assert cfg.settings.embedding_model == "nomic-embed-text", "model != nomic-embed-text"
    assert vec.vectorizer.dimension == 768, "vectorizer.dimension != 768"
    assert ecfg.settings.qdrant_collection == "preferences", "enrich collection != preferences"
    base = importlib.import_module("services.ingest.src.parsers.base")
    Pref = base.ParsedPreference
    p1 = Pref(subject="x", source="s", source_id="k", category="c", preference_type="Like")
    p2 = Pref(subject="x", source="s", source_id="k", category="c", preference_type="Like")
    assert p1.id == p2.id and len(p1.id) == 36, "ParsedPreference.id not stable/canonical (re-ingest would duplicate)"
    print("OK")
except AssertionError as exc:
    print(f"FAIL: vendored value mismatch ({exc})")
    sys.exit(2)
except ImportError as exc:
    print(f"INCONCLUSIVE: external dep missing ({exc})")
PY
)
case "$PY_IMPORT_CHECK" in
    "OK")
        echo "import check: ingest package imports cleanly + collection/dim/model match lock-ins"
        ;;
    INCONCLUSIVE:*)
        echo "import check: skipped (${PY_IMPORT_CHECK#INCONCLUSIVE: })"
        ;;
    FAIL:*)
        echo "$PY_IMPORT_CHECK" >&2
        exit 1
        ;;
    *)
        echo "import check: unexpected output: $PY_IMPORT_CHECK" >&2
        exit 1
        ;;
esac

echo "vendor/cm019_preferences preferences-ingest regression: PASS"
