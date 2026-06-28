"""Enact a recorded duplicate-merge decision against the graph IMMEDIATELY.

Sister module to ``duplicate_decision.py``. The decision endpoint
(``/api/v1/wiki/duplicates/decision``) only *records* a reversible ``merge:``
entry in ``duplicates.yaml``; the merge then waited for the scheduled
``batch_resolver --execute`` sweep to take effect. That sweep latency is the
"is it saved?" gap a live conversation hits: the user says "merge them", the
decision is recorded, but a follow-up question STILL disambiguates because the
graph hasn't been touched yet (M-3e).

This module applies a single just-recorded ``merge`` decision to the graph the
moment it is taken, by reusing the EXACT resolver primitives the sweep uses --
``identity_resolver.batch_resolver._merge_oxigraph`` / ``_merge_qdrant`` /
``_fetch_all_persons`` / ``pick_canonical`` and ``_backup_triples`` -- scoped to
just the decided ids. No new merge rule, no graph mutation reimplemented here:
the immediate path and the sweep path write identical triples, so behaviour can
never drift between them.

Reversibility is preserved exactly as today: the merge writes
``<discard> pwg:mergedInto <keep>`` and a pre-merge TriG backup, and the
decision lives in ``duplicates.yaml`` where a later ``distinct:`` decision
overrides it (and vetoes any pair marked distinct here too). Thin HTTP plumbing
stays in ``web_ui.py``; the schema + write stays in ``duplicate_decision.py``.
"""

from __future__ import annotations

import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)


# ── identity_resolver discovery ─────────────────────────────────────────────
# The resolver package is CM041-owned. In the HR015 dev tree it sits at the
# repo root (a sibling of doctor/); in the shipped Hub vendor tree the doctor
# lives at vendor/doctor/agent/ and the resolver at vendor/cm041/identity_resolver/.
# Locate it without assuming either layout, and allow an explicit override so an
# operator/packager can pin it. A failure to import is non-fatal at call time:
# the endpoint reports it and the merge still applies on the next sweep.
def _candidate_roots() -> List[Path]:
    here = Path(__file__).resolve()
    roots: List[Path] = []
    env = os.getenv("IDENTITY_RESOLVER_ROOT") or os.getenv("OSTLER_CM041_DIR")
    if env:
        roots.append(Path(os.path.expanduser(env)))
    # doctor/agent/ -> doctor/ -> <repo root or vendor/>
    parents2 = here.parents[2] if len(here.parents) > 2 else here.parent
    roots.append(parents2)          # HR015 dev: <root>/identity_resolver
    roots.append(parents2 / "cm041")  # Hub vendor: vendor/cm041/identity_resolver
    return roots


def _ensure_resolver_importable() -> None:
    for root in _candidate_roots():
        try:
            if (root / "identity_resolver" / "batch_resolver.py").is_file():
                if str(root) not in sys.path:
                    sys.path.insert(0, str(root))
                return
        except OSError:
            continue
    # Fall through: maybe it is already importable (installed / on PYTHONPATH).


class EnactError(Exception):
    """Carries an HTTP status, mirroring duplicate_decision.ValidationError."""

    def __init__(self, detail: str, status: int = 500):
        super().__init__(detail)
        self.detail = detail
        self.status = status


def _load_resolver():
    """Import the resolver primitives, bootstrapping sys.path if needed."""
    try:
        from identity_resolver import batch_resolver as _br  # type: ignore
        from identity_resolver.decisions import (  # type: ignore
            short_id as _short_id,
            load_duplicate_decisions as _load_decisions,
        )
    except Exception:
        _ensure_resolver_importable()
        try:
            from identity_resolver import batch_resolver as _br  # type: ignore
            from identity_resolver.decisions import (  # type: ignore
                short_id as _short_id,
                load_duplicate_decisions as _load_decisions,
            )
        except Exception as exc:  # pragma: no cover - environment specific
            raise EnactError(
                f"identity resolver is unavailable, cannot enact merge now "
                f"(it will apply on the next sweep): {exc}",
                status=503,
            )
    return _br, _short_id, _load_decisions


def enact_decision(
    normalised: Dict[str, Any],
    *,
    oxigraph_url: str,
    qdrant_url: Optional[str] = None,
    qdrant_collection: str = "people",
    corrections_dir: str = "",
    backup_dir: Optional[str] = None,
) -> Dict[str, Any]:
    """Apply a single recorded decision to the graph now.

    ``normalised`` is the ``{"action", "ids"}`` shape already validated by
    ``duplicate_decision.validate_payload``. Only ``merge`` mutates the graph;
    ``distinct`` is a no-op-now (it only blocks FUTURE merges, which the
    recorded decision already does). Returns a JSON-able result dict.
    """
    action = normalised["action"]
    ids: List[str] = list(normalised["ids"])

    if action != "merge":
        # Nothing to apply immediately: a distinct decision takes effect by
        # vetoing future merges, which the duplicates.yaml record already does.
        return {
            "status": "noop",
            "action": action,
            "reason": "distinct decisions block future merges; nothing to apply now",
        }

    br, short_id, load_decisions = _load_resolver()
    client = br.httpx.Client(timeout=60.0)
    try:
        # Live person nodes only (_fetch_all_persons filters mergedInto already),
        # so an already-merged id simply resolves to nothing and is skipped --
        # the enact is idempotent under a re-ask.
        persons = br._fetch_all_persons(oxigraph_url, client, dict(br.DEFAULT_CONFIG))
        sid_to_uri: Dict[str, str] = {short_id(uri): uri for uri in persons}

        present: List[str] = []
        seen = set()
        for sid in ids:
            uri = sid_to_uri.get(sid)
            if uri and uri not in seen:
                present.append(uri)
                seen.add(uri)

        if len(present) < 2:
            # Fewer than two live nodes: already merged, or the ids never
            # existed. Idempotent success-shaped no-op (the caller treats any
            # 2xx as "applied"; a re-ask after a completed merge lands here).
            return {
                "status": "noop",
                "action": "merge",
                "ids": ids,
                "present": present,
                "reason": "fewer than two live nodes to merge "
                          "(already merged or not found)",
            }

        # Honour an explicit distinct veto on any pair: distinct always wins,
        # exactly as apply_user_decisions does on the sweep.
        decisions = load_decisions(corrections_dir or "")
        distinct_pairs = decisions.get("distinct_pairs") or set()

        # Choose ONE canonical leader by folding pick_canonical across the
        # group, so the whole group collapses into a single node in one go
        # (the sweep's seen_uris guard only merges one pair per round; the
        # immediate enact must fully collapse the group the user just confirmed).
        leader = present[0]
        for uri in present[1:]:
            leader = br.pick_canonical(persons, leader, uri)[0]
        discards = [u for u in present if u != leader]

        # Pre-merge backup for rollback parity with batch execute().
        backup_path: Optional[str] = None
        if backup_dir:
            try:
                os.makedirs(backup_dir, exist_ok=True)
                ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
                backup_path = os.path.join(backup_dir, f"enact_backup_{ts}.trig")
                br._backup_triples(oxigraph_url, client, [leader] + discards, backup_path)
            except Exception as exc:  # backup is best-effort, never blocks merge
                logger.warning("enact backup failed (continuing): %s", exc)
                backup_path = None

        merged: List[str] = []
        skipped: List[str] = []
        for discard in discards:
            pair = frozenset((short_id(leader), short_id(discard)))
            if pair in distinct_pairs:
                skipped.append(discard)  # contradictory distinct mark wins
                continue
            br._merge_oxigraph(oxigraph_url, client, leader, discard)
            if qdrant_url:
                try:
                    br._merge_qdrant(qdrant_url, qdrant_collection, leader, discard)
                except Exception as exc:  # Qdrant is enrichment, non-fatal
                    logger.warning("enact Qdrant merge failed (non-fatal): %s", exc)
            merged.append(discard)

        return {
            "status": "enacted" if merged else "noop",
            "action": "merge",
            "keep": leader,
            "merged": merged,
            "skipped": skipped,
            "backup": backup_path,
        }
    finally:
        client.close()
