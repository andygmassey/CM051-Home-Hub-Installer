#!/usr/bin/env python3
"""An enrichment MISS is not an import error (walk #16, import_data red).

On the #16 walk box every import landed (people, Facebook, Instagram,
preferences), and the import_data step still ended `status=unmeasured` with a
red triangle. The only "errors" were three Wikidata look-ups that found
nothing ("No Wikidata entity for: ...", "Wikidata has no film or programme
named: ..."). The enrich CLI counted them as `failed`, `failed > successful`
made it exit 1, ostler-import's `|| rc=$?` carried that out, and install.sh
took the warn branch.

This drives the REAL enrich CLI (`_run_enrichment`, which owns the exit code)
over the REAL `EnrichmentService.enrich_batch` loop. Only the network edge is
stubbed: `enrich_preference` returns the result a client returns, and the
store and the already-enriched check answer locally. Every title is synthetic.

  arm 1  three misses, nothing else: exit 0, listed as "No enrichment match",
         and no "--- Errors" block.                    (RED before the fix)
  arm 2  one real failure (a client exception), no success: exit 1.
  arm 3  one transport failure (MatchType.UNAVAILABLE): exit 1, never a miss.
  arm 4  a client exception whose text is NOT a miss phrasing but carries the
         default MatchType.NONE: exit 1 (the classifier is fail-closed).

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

import asyncio
import contextlib
import io
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENRICH = REPO / "vendor" / "cm019_preferences" / "services" / "enrich"
if not (ENRICH / "src" / "cli.py").is_file():
    print(f"CANNOT RUN: enrich CLI missing under {ENRICH}", file=sys.stderr)
    sys.exit(2)
sys.path.insert(0, str(ENRICH))

try:
    from src import cli as enrich_cli
    from src.enricher import EnrichmentService
    from src.models.enrichment import EnrichmentResult, EnrichmentSource, MatchType
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT RUN: {type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(2)

PASS = FAIL = 0


def ok(m):
    global PASS
    print(f"  PASS  {m}")
    PASS += 1


def no(m):
    global FAIL
    print(f"  FAIL  {m}")
    FAIL += 1


def miss(pref_id, title, kind):
    r = EnrichmentResult(preference_id=pref_id, original_subject=title,
                         source=EnrichmentSource.WIKIDATA)
    r.error = (f"No Wikidata entity for: {title}" if kind == "entity"
               else f"Wikidata has no film or programme named: {title}")
    r.match_type = MatchType.NONE
    return r


def unavailable(pref_id, title):
    r = EnrichmentResult(preference_id=pref_id, original_subject=title,
                         source=EnrichmentSource.WIKIDATA)
    r.error = f"Could not reach Wikidata to look up {title!r}. This is NOT a statement about it."
    r.match_type = MatchType.UNAVAILABLE
    return r


def caught_exception(pref_id, title):
    r = EnrichmentResult(preference_id=pref_id, original_subject=title,
                         source=EnrichmentSource.WIKIDATA)
    r.error = "JSONDecodeError: Expecting value: line 1 column 1 (char 0)"
    return r  # match_type left at its default, NONE


def run(outcomes):
    """outcomes: list of callables(pref_id, title) -> result, or an Exception
    instance to raise. Returns (exit_code, stderr_text)."""
    prefs = [{"id": f"pref_synthetic_{i}", "category": "movie",
              "subject": f"Synthetic Film Title {i}", "extra": {"category_inferred": False}}
             for i in range(len(outcomes))]
    by_id = {p["id"]: o for p, o in zip(prefs, outcomes)}

    class FakeService(EnrichmentService):
        def __init__(self):  # no clients, no HTTP session
            pass

        async def _check_already_enriched(self, pref_id):
            return False

        async def enrich_preference(self, pref):
            o = by_id[pref["id"]]
            if isinstance(o, Exception):
                raise o
            return o(pref["id"], pref["subject"])

        async def _store_enrichment(self, result):
            return True

        async def enrich_all(self, user_id=None, category=None, limit=10000, batch_size=50,
                             progress_callback=None, deadline=None, **kw):
            from src.enricher import EnrichmentStats
            stats = EnrichmentStats()
            await self.enrich_batch(prefs, stats, deadline=deadline)
            return stats

        async def close(self):
            pass

    real = enrich_cli.EnrichmentService
    enrich_cli.EnrichmentService = FakeService
    err = io.StringIO()
    code = 0
    try:
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            asyncio.run(enrich_cli._run_enrichment(
                user_id="synthetic-user", categories=["movie"], limit=10,
                batch_size=10, verbose=False, budget_seconds=0))
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 1
    finally:
        enrich_cli.EnrichmentService = real
    return code, err.getvalue()


print("arm 1: three Wikidata misses, nothing else")
code, out = run([lambda i, t: miss(i, t, "entity"),
                 lambda i, t: miss(i, t, "film"),
                 lambda i, t: miss(i, t, "entity")])
print(f"        denominator: 3 items dispatched, exit {code}")
(ok if code == 0 else no)(f"three misses exit 0 (got {code})")
(ok if "--- Errors" not in out else no)("no '--- Errors' block for misses")
(ok if "No enrichment match (3" in out else no)("the misses are listed as 'No enrichment match (3...'")
(ok if "No match: 3" in out else no)("the summary counts 'No match: 3'")

print("arm 2: one real failure (client raised), no success")
code, out = run([RuntimeError("synthetic parse failure in a client response")])
print(f"        denominator: 1 item dispatched, exit {code}")
(ok if code == 1 else no)(f"a real failure still exits 1 (got {code})")
(ok if "--- Errors (1)" in out else no)("it is listed under '--- Errors (1)'")

print("arm 3: one transport failure (MatchType.UNAVAILABLE)")
code, out = run([unavailable])
print(f"        denominator: 1 item dispatched, exit {code}")
(ok if code == 1 else no)(f"an unreachable source is a failure, never a miss (got {code})")

print("arm 4: a caught exception with the default MatchType.NONE")
code, out = run([caught_exception])
print(f"        denominator: 1 item dispatched, exit {code}")
(ok if code == 1 else no)(f"an unrecognised message is a failure, fail-closed (got {code})")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
