"""Shared usage-journal wiring for the contact_syncer embed sites.

Grafted into CM051 from CM041 #137 (merged 82f45376). Upstream file:
``contact_syncer/usage.py``. The ONE adaptation is the import spelling of the
vendored writer -- see below and see ``contact_syncer/_vendor/__init__.py``.

Every ``/api/embed`` call in this package turns raw contact data into identity
vectors, which is *enrichment*. Each such call reports a MEASURED
``prompt_eval_count`` the daemon's /cost panel needs for its ``enriching`` row.
Rather than repeat the record-usage block at every embed clone (``syncer.py``,
``linkedin_career``, ``linkedin_connections``, ``facebook_friends``,
``instagram_social``, ``places_ingest``), they all call
:func:`record_embed_usage` here: one implementation, not six copies.

MEASURED, NEVER ESTIMATED: ``tokens_from_ollama`` returns ``(None, None)`` when
Ollama reported no counts and ``record_usage`` then writes nothing. A guessed
row would be worse than a missing one on a panel shown to a paying customer
beside a price comparison. NO ROW IS THE CORRECT OUTPUT for an unmeasured call.

Never raises: usage accounting must not abort the ingest it measures.

ROSTER CONTRACT. scripts/usage_journal_producers.tsv row
``cm041_identity_resolution`` matches on session_prefix ``cm041-`` AND purpose
``enriching`` -- both, because that file's own header says a producer writing
the wrong purpose is a defect too. Changing either string here takes that gate
red, which is the intended direction.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger(__name__)

# Identifies THIS enrichment RUN, never the person. One id per process is
# correct: each contact_syncer / social-import invocation is its own process.
_USAGE_RUN_ID = "cm041-enrich-" + datetime.now(timezone.utc).strftime(
    "%Y-%m-%dT%H:%M:%SZ"
)


def record_embed_usage(data: Any, model: str) -> None:
    """Record one ``enriching`` usage row from an Ollama ``/api/embed`` response.

    ``data`` is the parsed JSON from ``/api/embed``. Fail-soft in every arm:
    an import error, an unexpected payload shape, or an I/O problem must never
    break an ingest run.
    """
    try:
        # CM051 ADAPTATION. Upstream reads
        # ``from _vendor.ostler_usage_journal.usage_journal import ...``,
        # because upstream's _vendor/ sits at its repo root and its repo root
        # is on sys.path. In this repo the writer is nested inside the package
        # so that install.sh's existing ``cp -R contact_syncer`` carries it;
        # a repo-root sibling would never be staged into PIPELINE_DIR.
        from contact_syncer._vendor.ostler_usage_journal.usage_journal import (
            record_usage,
            tokens_from_ollama,
        )

        prompt, completion = tokens_from_ollama(data if isinstance(data, dict) else {})
        record_usage(
            model=model,
            input_tokens=prompt,
            output_tokens=completion,
            purpose="enriching",
            session_id=_USAGE_RUN_ID,
        )
    except Exception as exc:  # pragma: no cover - defensive
        logger.debug("usage journal write skipped: %s", exc)
