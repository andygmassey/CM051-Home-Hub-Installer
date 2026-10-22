"""Representative-first enrichment: one lookup per group unlocks the whole group.

WHY. The rollup readers (readers.yaml, kind: rollup) apply ONE enriched item's
genre/cuisine to every item that shares its key: the tracks of an artist or an
album, the episodes of a series, the orders from a restaurant. On a real store
only a few hundred of ~118k preference points are enriched, and the enrichment
tick used to walk the collection in point-id order, so the few lookups it could
afford per tick were spread at random across groups. Enriching ONE
representative of a big group first unlocks every point under it. So ORDER
matters, and this module fixes the order:

    1. group the points that no rollup row has a tag for yet, by rollup key;
    2. rank the groups by size, biggest first;
    3. enrich one representative per group (its strongest untried member);
    4. only then the long tail (the old id-order walk, unchanged).

The group keys come from the SHIPPED reader registry (build_readers), not a
second list, so a rollup row added to readers.yaml is ordered here for free.

CONSENT. Fails closed and first: with no recorded yes this module reads no
store, calls no client and makes no request (the stores are local but are
still sockets, and a declined owner gets none). Every lookup goes through
EnrichmentService.enrich_batch, which re-checks consent per batch and applies
the existing eligibility gate and per-client rate limits and cache. This module
adds no client and no new egress path; it only chooses the ORDER of items that
the existing path would have looked up anyway.

RESUMABLE AND IDEMPOTENT. Nothing is remembered except a small ledger of
points whose lookup came back as a deterministic miss (no match, not sendable),
so the next member of the group is tried instead of the same one for ever. A
group is "done" the moment ANY member carries a tag the rollup reads, which is
recomputed from the stores on every run; killing the process at any point loses
nothing, and running it twice in a row does no second lookup for a finished
group. After MAX_TRIES members without a tag a group is parked and retried
after RETRY_AFTER_DAYS.

PRIVACY. The ledger holds point ids and timestamps. The status file holds
counts only. Neither holds a subject, an artist or any value.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import time
import types
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Set, Tuple

from .model import ENRICH_NS

logger = logging.getLogger(__name__)

MIN_GROUP_SIZE = 2          # a group of one is just the point itself: no leverage
MAX_TRIES = 3               # members tried without a tag before a group is parked
RETRY_AFTER_DAYS = 30       # a parked/missed member is tried again after this
CHUNK = 25                  # reps per enrich_batch call; deadline/consent checked between
STATUS_NAME = "enrich-representatives.json"
LEDGER_NAME = "enrich-representatives-ledger.json"
SCHEMA = 1


# ── consent / settings, resolved lazily so this file imports standalone ──────
def _consent_allowed() -> bool:
    try:
        from ..consent import public_lookup_allowed  # package context
    except ImportError:
        import importlib.util

        path = Path(__file__).resolve().parent.parent / "consent.py"
        spec = importlib.util.spec_from_file_location("_rep_consent", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        public_lookup_allowed = mod.public_lookup_allowed
    return bool(public_lookup_allowed())


def _default_gateway():
    from .readers import HttpStoreGateway

    try:
        from ..config import settings

        return HttpStoreGateway(
            oxigraph_url=settings.oxigraph_url,
            qdrant_url=settings.qdrant_url,
            collection=settings.qdrant_collection,
        )
    except ImportError:
        return HttpStoreGateway()


def _state_dir() -> Path:
    base = os.environ.get("OSTLER_DIR") or str(Path.home() / ".ostler")
    return Path(base) / "state"


# ── the plan (pure: no I/O, so the ordering is testable on its own) ──────────
@dataclass
class Plan:
    reps: List[dict] = field(default_factory=list)   # ordered: biggest group first
    groups_total: int = 0        # groups with at least MIN_GROUP_SIZE members
    groups_covered: int = 0      # some member already carries a tag
    groups_parked: int = 0       # MAX_TRIES members tried, none tagged
    groups_unroutable: int = 0   # no member has a lookup client
    groups_pending: int = 0      # still owed a representative
    points_in_groups: int = 0
    points_in_covered_groups: int = 0
    points_in_pending_groups: int = 0   # unlocked if every pending rep succeeds


def rollup_rows(gateway, only_categories: Optional[Iterable[str]] = None) -> list:
    """The shipped RollupReader rows, one per distinct grouping key.

    Two rows that name the same key (dimension differs, key does not) are one
    grouping for ordering purposes only if they also share tag predicate; keep
    them apart otherwise because coverage is per tag predicate.
    """
    from .config import build_readers
    from .readers import RollupReader

    only = set(only_categories) if only_categories is not None else None
    rows, seen = [], set()
    for r in build_readers(gateway):
        if not isinstance(r, RollupReader):
            continue
        if only is not None and not (set(r.select_categories) & only):
            continue
        sig = (
            r.key.field_path, r.key.split, r.key.part, r.key.strip_regex,
            r.key.transform, tuple(sorted(r.select_categories)),
            r.tags.tag_predicate, r.tags.tag_entity_type,
        )
        if sig in seen:
            continue
        seen.add(sig)
        rows.append(r)
    return rows


def plan_representatives(
    points: List[dict],
    rows: list,
    tagged: List[Set[str]],
    enriched: Set[str],
    ledger: Dict[str, float],
    attempted: Set[str],
    routable: Callable[[str], bool] = lambda category: True,
    min_group_size: int = MIN_GROUP_SIZE,
    max_tries: int = MAX_TRIES,
) -> Plan:
    """Order one representative per still-uncovered group, biggest group first.

    points   Qdrant points [{'id', 'payload'}]
    rows     RollupReader rows (see rollup_rows)
    tagged   per row: point ids carrying a tag that row's rollup reads
    enriched point ids that already have an enrichedAt (tried, tag or not)
    ledger   point id -> epoch of a deterministic miss (unexpired entries only)
    attempted point ids already tried in THIS run (never picked twice)
    routable category -> True if some lookup client takes it
    """
    plan = Plan()
    payloads = {str(p.get("id")): (p.get("payload") or {}) for p in points}
    # group id -> {row index, members [(strength, id, category)]}
    groups: Dict[Tuple[int, str], List[Tuple[float, str, str]]] = {}
    member_of: Dict[str, List[Tuple[int, str]]] = {}
    for p in points:
        pid = str(p.get("id"))
        pl = p.get("payload") or {}
        cat = (pl.get("category") or "")
        try:
            strength = float(pl.get("strength") or 0.0)
        except (TypeError, ValueError):
            strength = 0.0
        for ri, row in enumerate(rows):
            if cat not in row.select_categories:
                continue
            key = row.key._value(pl).lower()
            if not key:
                continue
            gid = (ri, key)
            groups.setdefault(gid, []).append((strength, pid, cat))
            member_of.setdefault(pid, []).append(gid)

    tried_all = enriched | set(ledger) | attempted
    chosen_groups: Set[Tuple[int, str]] = set()
    ranked = sorted(
        (g for g, m in groups.items() if len(m) >= min_group_size),
        key=lambda g: (-len(groups[g]), -sum(s for s, _, _ in groups[g]), g[0], g[1]),
    )
    plan.groups_total = len(ranked)
    in_groups: Set[str] = set()
    in_covered: Set[str] = set()
    in_pending: Set[str] = set()
    for gid in ranked:
        members = groups[gid]
        ids = {pid for _, pid, _ in members}
        in_groups |= ids
        if gid in chosen_groups:
            # an earlier representative also belongs to this group (a track is
            # in its artist's group and its album's group): already unlocked
            plan.groups_pending += 1
            in_pending |= ids
            continue
        if ids & tagged[gid[0]]:
            plan.groups_covered += 1
            in_covered |= ids
            continue
        if not any(routable(c) for _, _, c in members):
            plan.groups_unroutable += 1
            continue
        tried = sum(1 for _, pid, _ in members if pid in tried_all)
        candidates = sorted(
            ((s, pid, c) for s, pid, c in members if pid not in tried_all and routable(c)),
            key=lambda m: (-m[0], m[1]),
        )
        if tried >= max_tries or not candidates:
            plan.groups_parked += 1
            continue
        _, rep_id, _ = candidates[0]
        plan.reps.append({"id": rep_id, **payloads[rep_id]})
        plan.groups_pending += 1
        in_pending |= ids
        # the representative unlocks every group it belongs to, not only this one
        chosen_groups.update(member_of.get(rep_id, ()))
    plan.points_in_groups = len(in_groups)
    plan.points_in_covered_groups = len(in_covered)
    plan.points_in_pending_groups = len(in_pending)
    return plan


@dataclass
class RepStats:
    state: str = "not_run"
    groups_total: int = 0
    groups_covered: int = 0
    groups_parked: int = 0
    groups_pending: int = 0
    points_in_groups: int = 0
    points_in_covered_groups: int = 0
    points_in_pending_groups: int = 0
    reps_attempted: int = 0
    reps_enriched: int = 0
    reps_missed: int = 0
    reps_errored: int = 0
    budget_exhausted: bool = False

    def as_status(self) -> dict:
        d = dict(self.__dict__)
        d["schema"] = SCHEMA
        d["updated_at"] = int(time.time())
        return d


def _write_json(path: Path, data: dict) -> None:
    """Atomic, 0600. A failure here is logged and never stops enrichment."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, sort_keys=True)
        os.replace(tmp, path)
    except OSError as exc:  # pragma: no cover - disk full / permissions
        logger.warning("representative-first: could not write %s: %s", path.name, exc)


def _load_ledger(path: Path, now: float) -> Dict[str, float]:
    try:
        raw = json.loads(path.read_text())
        entries = raw.get("missed", {}) if isinstance(raw, dict) else {}
    except (OSError, ValueError):
        return {}
    horizon = now - RETRY_AFTER_DAYS * 86400
    return {str(k): float(v) for k, v in entries.items() if isinstance(v, (int, float)) and v > horizon}


async def run_representative_pass(
    service,
    *,
    user_id: Optional[str] = None,
    categories: Optional[Iterable[str]] = None,
    batch_size: int = CHUNK,
    deadline=None,                       # datetime (utc) or None
    gateway=None,
    consent: Optional[Callable[[], bool]] = None,
    state_dir: Optional[Path] = None,
    now: Optional[float] = None,
) -> RepStats:
    """Enrich one representative per rollup group, biggest group first.

    Never raises: any failure is a state on the returned stats and the caller
    carries on to the long tail exactly as before.
    """
    from datetime import datetime

    stats = RepStats()
    sdir = Path(state_dir) if state_dir else _state_dir()
    status_path, ledger_path = sdir / STATUS_NAME, sdir / LEDGER_NAME
    now = time.time() if now is None else now
    allowed = consent or _consent_allowed

    # Consent first. Nothing below runs, reads or connects without a recorded yes.
    if not allowed():
        stats.state = "consent_declined"
        _write_json(status_path, stats.as_status())
        return stats

    try:
        gateway = gateway or _default_gateway()
        rows = rollup_rows(gateway, categories)
    except Exception as exc:  # derive tree or yaml missing: skip, never block the tail
        logger.warning("representative-first unavailable (%s: %s); long tail only", type(exc).__name__, exc)
        stats.state = "derive_unavailable"
        _write_json(status_path, stats.as_status())
        return stats
    if not rows:
        stats.state = "nothing_to_do"
        _write_json(status_path, stats.as_status())
        return stats

    cats = sorted({c for r in rows for c in r.select_categories})
    clients = getattr(service, "CATEGORY_CLIENTS", {}) or {}
    routable = lambda c: (c or "").lower() in clients  # noqa: E731

    def read_stores():
        points = gateway.scroll(cats, [])
        tagged = [set(r.tags._overlay_tags()) for r in rows]
        rowsq = gateway.sparql(
            "SELECT DISTINCT ?p WHERE { ?p <%senrichedAt> ?d }" % ENRICH_NS
        )
        prefix = "urn:ostler:preference:"
        enriched = {
            b["p"]["value"][len(prefix):] for b in rowsq
            if b.get("p", {}).get("value", "").startswith(prefix)
        }
        return points, tagged, enriched

    try:
        points, tagged, enriched = await asyncio.to_thread(read_stores)
    except Exception as exc:
        logger.warning("representative-first: stores unreadable (%s); long tail only", type(exc).__name__)
        stats.state = "stores_unreadable"
        _write_json(status_path, stats.as_status())
        return stats

    ledger = _load_ledger(ledger_path, now)
    attempted: Set[str] = set()
    stats.state = "ran"
    first = True
    consecutive_errors = 0

    while True:
        plan = plan_representatives(points, rows, tagged, enriched, ledger, attempted, routable)
        if first:
            stats.groups_total = plan.groups_total
            stats.groups_covered = plan.groups_covered
            stats.groups_parked = plan.groups_parked
            stats.groups_pending = plan.groups_pending
            stats.points_in_groups = plan.points_in_groups
            stats.points_in_covered_groups = plan.points_in_covered_groups
            stats.points_in_pending_groups = plan.points_in_pending_groups
            first = False
            _write_json(status_path, stats.as_status())
        if not plan.reps:
            break
        if deadline is not None and datetime.utcnow() >= deadline:
            stats.budget_exhausted = True
            break
        if not allowed():  # the owner can change their answer mid-run
            stats.state = "consent_declined"
            break

        chunk = plan.reps[: max(1, min(batch_size, CHUNK))]
        chunk_stats = _fresh_stats(service)
        try:
            results = await service.enrich_batch(chunk, chunk_stats)
        except Exception as exc:  # one bad chunk must not take the tail down with it
            logger.warning("representative-first: chunk failed (%s); stopping the pass", type(exc).__name__)
            stats.reps_errored += len(chunk)
            break
        ok_ids = {str(getattr(r, "preference_id", "")) for r in (results or [])}
        failed_delta = int(getattr(chunk_stats, "failed", 0))
        for rep in chunk:
            rid = str(rep["id"])
            attempted.add(rid)
            stats.reps_attempted += 1
            if rid in ok_ids:
                stats.reps_enriched += 1
                enriched.add(rid)
            else:
                stats.reps_missed += 1
        # Only a clean chunk (no transport/store errors) may write a miss to the
        # ledger: a timeout is not a verdict on the item.
        if failed_delta == 0:
            consecutive_errors = 0
            for rep in chunk:
                if str(rep["id"]) not in ok_ids:
                    ledger[str(rep["id"])] = now
        else:
            stats.reps_errored += failed_delta
            consecutive_errors += 1
            if consecutive_errors >= 2:
                logger.warning("representative-first: two chunks with errors; stopping early")
                break
        # fresh tags for the rollup (the rep just written changes coverage)
        try:
            tagged = await asyncio.to_thread(lambda: [set(r.tags._overlay_tags()) for r in rows])
        except Exception:
            break
        _write_json(ledger_path, {"schema": SCHEMA, "missed": ledger})
        _write_json(status_path, stats.as_status())

    _write_json(ledger_path, {"schema": SCHEMA, "missed": ledger})
    _write_json(status_path, stats.as_status())
    logger.info(
        "representative-first: %d groups, %d covered, %d parked, %d reps tried, %d enriched",
        stats.groups_total, stats.groups_covered, stats.groups_parked,
        stats.reps_attempted, stats.reps_enriched,
    )
    return stats


def _fresh_stats(service):
    """An EnrichmentStats from the service's own module (the class the CLI prints)."""
    cls = getattr(sys.modules.get(type(service).__module__), "EnrichmentStats", None)
    return cls() if cls else types.SimpleNamespace(failed=0)
