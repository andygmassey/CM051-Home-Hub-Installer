#!/usr/bin/env bash
#
# tests/test_ostler_import_exit_code_separates_misses_from_failures.sh
#
# Walk #16, the install.sh end: install.sh decides ok vs warn on import_data
# from ostler-import's exit code (`if "$IMPORT_SCRIPT" ...; then ok ...; else
# warn MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN`). So the contract is on
# ostler-import's rc, and this runs the REAL generated ostler-import (the
# IMPORTEOF heredoc extracted from install.sh) with its CM019 leg pointed at a
# stub python:
#
#   arm 1  ingest OK, enrich reports 3 enrichment misses   -> rc 0  (ok)
#   arm 2  ingest hits a PARSE FAILURE (exit 1), enrich OK -> rc != 0 (warn)
#   arm 3  control: ingest OK, enrich OK                   -> rc 0
#
# The enrich exit code in arm 1 is NOT asserted here by fiat: the stub runs
# tests/test_an_enrichment_miss_is_not_an_import_error.py's subject, the real
# vendored enrich CLI, through the helper below, so this test goes red on main
# exactly when the real CLI exits 1 on misses. If the vendored enrich
# dependencies are not importable, this prints CANNOT RUN and exits 2.
#
# The other legs (contact_syncer, the universal importer) are absent, which
# ostler-import already treats as "skip" ([[ -x ]] guards), so the rc is the
# CM019 leg's alone. Synthetic data only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
ENRICH="${REPO}/vendor/cm019_preferences/services/enrich"
PY="${PYTHON:-python3}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cannot() { echo "CANNOT RUN: $*" >&2; exit 2; }

[[ -f "$INSTALL_SH" ]] || cannot "install.sh not found"
"$PY" -c "import sys; sys.path.insert(0, '${ENRICH}'); import src.cli" 2>/dev/null \
    || cannot "the vendored enrich CLI is not importable by ${PY} (pip install -r vendor/cm019_preferences/requirements.txt)"

awk '/cat > "\$IMPORT_SCRIPT" <<.IMPORTEOF./{f=1;next} f&&/^IMPORTEOF$/{exit} f{print}' "$INSTALL_SH" > "$WORK/ostler-import"
grep -q 'services.enrich.src.cli enrich' "$WORK/ostler-import" || cannot "could not extract ostler-import from install.sh"
chmod +x "$WORK/ostler-import"

# A home the generated script resolves everything under.
H="$WORK/home"
CM019_DIR="$H/.ostler/services/cm019"
mkdir -p "$CM019_DIR/.venv/bin" "$H/.ostler/config" "$WORK/exports/synthetic"
: > "$WORK/exports/synthetic/placeholder.json"

# Runs the REAL enrich CLI over N synthetic misses (helper owns the fake
# service; only the network edge is stubbed).
cat > "$WORK/enrich_misses.py" <<'PYEOF'
import asyncio, sys
sys.path.insert(0, sys.argv[1])
from src import cli as enrich_cli
from src.enricher import EnrichmentService, EnrichmentStats
from src.models.enrichment import EnrichmentResult, EnrichmentSource, MatchType
n = int(sys.argv[2])
prefs = [{"id": "pref_synthetic_%d" % i, "category": "movie",
          "subject": "Synthetic Film Title %d" % i, "extra": {"category_inferred": False}}
         for i in range(n)]
class S(EnrichmentService):
    def __init__(self): pass
    async def _check_already_enriched(self, p): return False
    async def _store_enrichment(self, r): return True
    async def enrich_preference(self, p):
        r = EnrichmentResult(preference_id=p["id"], original_subject=p["subject"],
                             source=EnrichmentSource.WIKIDATA)
        r.error = "No Wikidata entity for: %s" % p["subject"]
        r.match_type = MatchType.NONE
        return r
    async def enrich_all(self, user_id=None, category=None, limit=10000, batch_size=50,
                         progress_callback=None, deadline=None, **kw):
        st = EnrichmentStats(); await self.enrich_batch(prefs, st, deadline=deadline); return st
    async def close(self): pass
enrich_cli.EnrichmentService = S
asyncio.run(enrich_cli._run_enrichment(user_id="synthetic-user", categories=["movie"],
            limit=10, batch_size=10, verbose=False, budget_seconds=0))
PYEOF

# The stub CM019 python: ingest-dir obeys $STUB_INGEST_RC; enrich runs the
# real CLI over $STUB_MISSES misses (0 means a clean enrich, exit 0).
cat > "$CM019_DIR/.venv/bin/python" <<STUB
#!/usr/bin/env bash
case " \$* " in
    *" services.ingest.src.cli ingest-dir "*)
        [[ "\${STUB_INGEST_RC:-0}" -ne 0 ]] && echo "ERROR: could not parse synthetic export (malformed JSON)" >&2
        exit "\${STUB_INGEST_RC:-0}" ;;
    *" services.enrich.src.cli enrich "*)
        [[ "\${STUB_MISSES:-0}" -gt 0 ]] || exit 0
        exec "$PY" "$WORK/enrich_misses.py" "$ENRICH" "\${STUB_MISSES}" ;;
esac
exit 0
STUB
chmod +x "$CM019_DIR/.venv/bin/python"

# launchctl must not touch the real session.
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/launchctl"
chmod +x "$WORK/bin/launchctl"

arm() {
    # arm <ingest_rc> <misses> -> prints rc
    HOME="$H" PATH="$WORK/bin:$PATH" STUB_INGEST_RC="$1" STUB_MISSES="$2" \
        "$WORK/ostler-import" "$WORK/exports" --user-name "Jane Doe" --user-id jane >"$WORK/arm.log" 2>&1
    echo $?
}

status=0
rc="$(arm 0 3)"
echo "arm 1: ingest ok, 3 enrichment misses -> ostler-import rc=${rc} (install.sh: $([[ $rc -eq 0 ]] && echo ok || echo warn))"
if [[ "$rc" -eq 0 ]]; then echo "PASS: 3 enrichment misses do not fail the import"; else echo "FAIL: 3 enrichment misses made ostler-import exit ${rc}, so import_data goes red"; status=1; fi

rc="$(arm 1 0)"
echo "arm 2: ingest PARSE FAILURE, enrich ok -> ostler-import rc=${rc} (install.sh: $([[ $rc -eq 0 ]] && echo ok || echo warn))"
if [[ "$rc" -ne 0 ]]; then echo "PASS: a parse failure still fails the import"; else echo "FAIL: a parse failure exited 0; a real import error would read as ok"; status=1; fi

rc="$(arm 0 0)"
echo "arm 3 (control): ingest ok, enrich ok -> ostler-import rc=${rc}"
if [[ "$rc" -eq 0 ]]; then echo "PASS: control: a clean run exits 0"; else echo "FAIL: control: a clean run exited ${rc}; the harness is broken"; status=1; fi

echo "denominator: 3 runs of the real ostler-import, 1 import leg each"
exit "$status"
