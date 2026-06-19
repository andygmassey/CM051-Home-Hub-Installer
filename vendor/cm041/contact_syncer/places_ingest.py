"""Places ingester - aggregate location signals already in the graph into
Qdrant ``preferences`` points with ``category=place`` so the CM044 wiki
Places section is non-empty without any CM044 reader change.

Why this exists
---------------
The wiki Places page (CM044 ``compiler/pages/place_pages.py``) reads ONLY the
Qdrant ``preferences`` collection filtered to ``category == "place"``. Nothing
ever wrote those points, so the page always rendered its empty state even
though the graph holds real location signals: 96 meetings carry a
``pwg:meetingLocation`` literal (dozens of distinct strings) and photo events
may carry ``pwg:photoPlace``. None of those literals were ever promoted into a
browsable Place. This module closes that leg.

What it does
------------
1. SELECT distinct location strings out of Oxigraph:
   - ``pwg:meetingLocation`` on ``pwg:Meeting`` nodes (primary signal), counting
     how many meetings reference each location and the most-recent meeting date.
   - ``pwg:photoPlace`` on photo-event nodes (secondary, if present).
2. De-dupe by a normalised location key (case-folded, whitespace-collapsed,
   trailing punctuation stripped) so "Fuel Espresso" and "fuel espresso "
   collapse to one Place.
3. Upsert one ``area_preference`` point per distinct place into the
   ``preferences`` collection with the exact payload shape the reader expects
   (``subject``, ``source``, ``strength``, ``category="place"`` and an ``extra``
   dict carrying ``type="area_preference"``, ``total_visits``, ``sources`` and a
   ``meeting_count``). The reader treats ``extra.type == "area_preference"`` as
   an *area* (a hub page); plain venues are anything else.

Loud guard
----------
If location signals exist (>0 meeting locations read out of the graph) but the
aggregation produces 0 place points, we log a LOUD warning and the CLI exits
non-zero, because that is the exact silent-failure class that left Places empty
in the first place (a writer that runs but produces nothing).

Idempotent: point IDs are a deterministic uuid5 of the normalised key, so a
re-run upserts the same points rather than duplicating them.

Usage::

    python -m contact_syncer.places_ingest [--dry-run] [--verbose]

Reads ``OXIGRAPH_URL`` and ``QDRANT_URL`` (optionally ``EMBED_OLLAMA_URL`` /
``EMBED_MODEL``) from the environment / ``.env`` (see ``contact_syncer.config``).
"""
from __future__ import annotations

import argparse
import logging
import os
import re
import sys
import uuid
from typing import Any, Dict, List, Optional, Tuple

import httpx

_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from contact_syncer import config

logger = logging.getLogger(__name__)

PWG = "https://pwg.dev/ontology#"

# The collection + category + payload contract the CM044 reader
# (compiler/pages/place_pages.py) expects. Do NOT change these without a
# matching CM044 change.
PLACE_COLLECTION = "preferences"
PLACE_CATEGORY = "place"
# place_pages._split_by_type() routes a point to the AREA branch (a hub page)
# when extra.type == "area_preference"; everything else is an inline venue.
AREA_TYPE = "area_preference"

# Default embedding dimension. place_pages never reads the vector, but Qdrant
# requires every point to carry one and the collection is created 768-dim
# (Cosine) by the existing ensure-collection paths. We embed the place name so
# the point is also semantically searchable for free; if embedding is
# unavailable we fall back to a deterministic zero-ish vector of the right size.
_DEFAULT_VECTOR_SIZE = 768


# ── Normalisation ────────────────────────────────────────────────────


def normalise_location(raw: str) -> str:
    """Return a stable de-dupe key for a location string.

    Case-folded, internal whitespace collapsed, surrounding whitespace and
    trailing punctuation stripped. Two location literals that differ only by
    case or trailing punctuation collapse to the same Place.
    """
    if not raw:
        return ""
    s = raw.strip().casefold()
    s = re.sub(r"\s+", " ", s)
    s = s.strip(" \t\r\n.,;:-")
    return s


def _display_name(variants: List[str]) -> str:
    """Pick a human display label from the raw variants of a place.

    Prefers the longest variant (usually the most complete address), falling
    back to the first. Keeps the original casing rather than the folded key.
    """
    cleaned = [v.strip() for v in variants if v and v.strip()]
    if not cleaned:
        return ""
    # Longest first, then alphabetical for determinism.
    cleaned.sort(key=lambda v: (-len(v), v))
    return cleaned[0]


# ── Oxigraph reads ───────────────────────────────────────────────────


def _sparql_query(oxigraph_url: str, sparql: str) -> Dict[str, Any]:
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
        )
        resp.raise_for_status()
        return resp.json()


def read_meeting_locations(oxigraph_url: str) -> List[Dict[str, Any]]:
    """Return per-location rows from meeting locations in Oxigraph.

    Each row: ``{"location": str, "meeting_count": int, "last_date": str}``.
    Aggregated server-side by the raw location literal; cross-literal de-dupe
    (case/punctuation) happens later in :func:`aggregate`.
    """
    sparql = (
        f"PREFIX pwg: <{PWG}>\n"
        "SELECT ?loc (COUNT(?m) AS ?n) (MAX(?d) AS ?last) WHERE {\n"
        "  ?m a pwg:Meeting ;\n"
        "     pwg:meetingLocation ?loc .\n"
        "  OPTIONAL { ?m pwg:meetingDate ?d }\n"
        "}\n"
        "GROUP BY ?loc"
    )
    data = _sparql_query(oxigraph_url, sparql)
    rows: List[Dict[str, Any]] = []
    for b in data.get("results", {}).get("bindings", []):
        loc = (b.get("loc", {}) or {}).get("value", "")
        if not loc.strip():
            continue
        try:
            n = int((b.get("n", {}) or {}).get("value", "0") or 0)
        except (TypeError, ValueError):
            n = 0
        last = (b.get("last", {}) or {}).get("value", "") or ""
        rows.append({"location": loc, "meeting_count": n, "last_date": last})
    return rows


def read_photo_places(oxigraph_url: str) -> List[Dict[str, Any]]:
    """Return per-place rows from photo-event place labels, if any.

    Secondary signal, best-effort. Returns [] when the predicate is absent.
    Each row: ``{"location": str, "photo_count": int, "last_date": str}``.
    """
    sparql = (
        f"PREFIX pwg: <{PWG}>\n"
        "SELECT ?loc (COUNT(?p) AS ?n) (MAX(?d) AS ?last) WHERE {\n"
        "  ?p pwg:photoPlace ?loc .\n"
        "  OPTIONAL { ?p pwg:photoDate ?d }\n"
        "}\n"
        "GROUP BY ?loc"
    )
    try:
        data = _sparql_query(oxigraph_url, sparql)
    except Exception as exc:  # predicate may simply not exist yet
        logger.debug("photoPlace query failed (non-fatal): %s", exc)
        return []
    rows: List[Dict[str, Any]] = []
    for b in data.get("results", {}).get("bindings", []):
        loc = (b.get("loc", {}) or {}).get("value", "")
        if not loc.strip():
            continue
        try:
            n = int((b.get("n", {}) or {}).get("value", "0") or 0)
        except (TypeError, ValueError):
            n = 0
        last = (b.get("last", {}) or {}).get("value", "") or ""
        rows.append({"location": loc, "photo_count": n, "last_date": last})
    return rows


# ── Aggregation (pure, unit-tested) ──────────────────────────────────


def aggregate(
    meeting_rows: List[Dict[str, Any]],
    photo_rows: Optional[List[Dict[str, Any]]] = None,
) -> List[Dict[str, Any]]:
    """Collapse raw location rows into deduped Place payloads.

    Pure function (no I/O) so it can be unit-tested. Input rows are whatever
    :func:`read_meeting_locations` / :func:`read_photo_places` return (or test
    fixtures of the same shape). Output is a list of Qdrant payload dicts
    carrying the exact fields ``place_pages.py`` reads.
    """
    photo_rows = photo_rows or []

    # key -> aggregate accumulator
    agg: Dict[str, Dict[str, Any]] = {}

    def _bucket(key: str) -> Dict[str, Any]:
        if key not in agg:
            agg[key] = {
                "variants": [],
                "meeting_count": 0,
                "photo_count": 0,
                "last_date": "",
                "sources": {},
            }
        return agg[key]

    for row in meeting_rows:
        loc = row.get("location") or ""
        key = normalise_location(loc)
        if not key:
            continue
        bucket = _bucket(key)
        bucket["variants"].append(loc)
        bucket["meeting_count"] += int(row.get("meeting_count") or 0)
        bucket["sources"]["calendar"] = (
            bucket["sources"].get("calendar", 0) + int(row.get("meeting_count") or 0)
        )
        ld = row.get("last_date") or ""
        if ld > bucket["last_date"]:
            bucket["last_date"] = ld

    for row in photo_rows:
        loc = row.get("location") or ""
        key = normalise_location(loc)
        if not key:
            continue
        bucket = _bucket(key)
        bucket["variants"].append(loc)
        bucket["photo_count"] += int(row.get("photo_count") or 0)
        bucket["sources"]["photos"] = (
            bucket["sources"].get("photos", 0) + int(row.get("photo_count") or 0)
        )
        ld = row.get("last_date") or ""
        if ld > bucket["last_date"]:
            bucket["last_date"] = ld

    payloads: List[Dict[str, Any]] = []
    for key, data in agg.items():
        name = _display_name(data["variants"])
        if not name:
            continue
        visits = data["meeting_count"] + data["photo_count"]
        # strength: a soft 0..1 signal the reader uses for the area filter
        # (>0.5 keeps a place even with few venues) and index ordering. We map
        # visit count through a gentle saturating curve: 1 visit ~0.3, 3 ~0.6,
        # 5+ approaches ~0.9.
        strength = round(min(0.95, 0.15 + 0.15 * visits), 4)
        extra: Dict[str, Any] = {
            "type": AREA_TYPE,
            "total_visits": visits,
            "venue_count": 0,
            "meeting_count": data["meeting_count"],
            "sources": data["sources"],
            "normalised_key": key,
        }
        if data["last_date"]:
            extra["last_seen"] = data["last_date"]
        payloads.append(
            {
                "category": PLACE_CATEGORY,
                "subject": name,
                "source": "meeting_locations",
                "strength": strength,
                "preference_type": "Neutral",
                "extra": extra,
            }
        )

    # Deterministic order: most visited first, then name.
    payloads.sort(
        key=lambda p: (-(p["extra"]["total_visits"]), p["subject"].casefold())
    )
    return payloads


# ── Qdrant writes ────────────────────────────────────────────────────


def _embed_text(ollama_url: str, text: str, model: str) -> Optional[List[float]]:
    transport = httpx.HTTPTransport(proxy=None)
    try:
        with httpx.Client(timeout=60.0, transport=transport) as client:
            resp = client.post(
                f"{ollama_url}/api/embed",
                json={"model": model, "input": text},
            )
            resp.raise_for_status()
            data = resp.json()
        embs = data.get("embeddings") or [data.get("embedding")]
        if embs and embs[0]:
            return embs[0]
    except Exception as exc:
        logger.debug("embed failed for %r (using fallback vector): %s", text, exc)
    return None


def _ensure_collection(qdrant: Any, collection: str, vector_size: int) -> None:
    """Self-create the preferences collection if absent (idempotent)."""
    try:
        if qdrant.collection_exists(collection):
            return
    except Exception:
        pass
    from qdrant_client.models import Distance, VectorParams

    size = vector_size if vector_size and vector_size > 0 else _DEFAULT_VECTOR_SIZE
    try:
        qdrant.create_collection(
            collection_name=collection,
            vectors_config=VectorParams(size=size, distance=Distance.COSINE),
        )
        logger.info("Created Qdrant collection '%s' (size=%d, Cosine).", collection, size)
    except Exception as exc:
        logger.debug("create_collection('%s') raced/failed (tolerated): %s", collection, exc)


def _collection_vector_size(qdrant: Any, collection: str) -> int:
    """Return the existing collection's vector size, or the default."""
    try:
        info = qdrant.get_collection(collection)
        params = info.config.params  # type: ignore[attr-defined]
        vectors = params.vectors
        size = getattr(vectors, "size", None)
        if size:
            return int(size)
    except Exception:
        pass
    return _DEFAULT_VECTOR_SIZE


def upsert_places(
    payloads: List[Dict[str, Any]],
    *,
    qdrant_url: str,
    embed_url: str = "",
    embed_model: str = "nomic-embed-text",
    dry_run: bool = False,
    verbose: bool = False,
) -> Dict[str, int]:
    """Upsert deduped place payloads into Qdrant ``preferences``.

    Returns counts: ``{"places": N, "written": W, "errors": E}``.
    """
    counts = {"places": len(payloads), "written": 0, "errors": 0}
    if dry_run:
        for p in payloads:
            if verbose:
                print(
                    f"  [dry-run] {p['subject']}  "
                    f"(visits={p['extra']['total_visits']}, "
                    f"strength={p['strength']})"
                )
        return counts

    from qdrant_client import QdrantClient
    from qdrant_client.models import PointStruct

    qdrant = QdrantClient(url=qdrant_url)

    # Determine the right vector size: prefer the existing collection's, else
    # what the first successful embedding yields, else the 768 default.
    try:
        exists = qdrant.collection_exists(PLACE_COLLECTION)
    except Exception:
        exists = False
    if exists:
        vector_size = _collection_vector_size(qdrant, PLACE_COLLECTION)
    else:
        vector_size = _DEFAULT_VECTOR_SIZE

    _ensure_collection(qdrant, PLACE_COLLECTION, vector_size)

    points: List[Any] = []
    for p in payloads:
        key = p["extra"]["normalised_key"]
        point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"pwg://place/{key}"))
        vector: Optional[List[float]] = None
        if embed_url:
            vector = _embed_text(embed_url, p["subject"], embed_model)
        if vector is None:
            vector = [0.0] * vector_size
        points.append(PointStruct(id=point_id, vector=vector, payload=p))
        if verbose:
            print(
                f"  {p['subject']}  (visits={p['extra']['total_visits']}, "
                f"strength={p['strength']})"
            )

    if not points:
        return counts

    try:
        qdrant.upsert(collection_name=PLACE_COLLECTION, points=points)
        counts["written"] = len(points)
    except Exception as exc:
        logger.error("Qdrant upsert failed: %s", exc)
        counts["errors"] = len(points)

    return counts


# ── Orchestrator ─────────────────────────────────────────────────────


def ingest_places(
    *,
    oxigraph_url: str,
    qdrant_url: str,
    embed_url: str = "",
    embed_model: str = "nomic-embed-text",
    dry_run: bool = False,
    verbose: bool = False,
) -> Dict[str, Any]:
    """Read location signals, aggregate, and upsert Place preference points.

    Loud guard: if >0 meeting locations were read but aggregation produced 0
    place points, log a WARNING and return ``status="error_empty_result"`` so
    the caller (and the CLI exit code) surfaces the silent-failure class that
    originally left Places empty.
    """
    meeting_rows = read_meeting_locations(oxigraph_url)
    photo_rows = read_photo_places(oxigraph_url)
    raw_signals = len(meeting_rows) + len(photo_rows)
    logger.info(
        "Read %d meeting-location rows + %d photo-place rows from Oxigraph",
        len(meeting_rows), len(photo_rows),
    )

    payloads = aggregate(meeting_rows, photo_rows)
    logger.info("Aggregated to %d distinct places", len(payloads))

    status = "ok"
    if raw_signals > 0 and not payloads:
        logger.warning(
            "PLACES INGEST GUARD: %d location signals exist in the graph but "
            "0 Place points were produced. The wiki Places page will stay "
            "EMPTY. Check normalise_location() / the SPARQL reads.",
            raw_signals,
        )
        status = "error_empty_result"

    upsert_counts = upsert_places(
        payloads,
        qdrant_url=qdrant_url,
        embed_url=embed_url,
        embed_model=embed_model,
        dry_run=dry_run,
        verbose=verbose,
    )

    # Second loud guard: signals existed, we did not dry-run, yet nothing was
    # written and nothing errored cleanly.
    if (
        raw_signals > 0
        and not dry_run
        and upsert_counts["written"] == 0
        and upsert_counts["errors"] == 0
        and payloads
    ):
        logger.warning(
            "PLACES INGEST GUARD: produced %d place points but wrote 0 to "
            "Qdrant. Places page will stay EMPTY.",
            len(payloads),
        )
        status = "error_empty_result"

    return {
        "status": status,
        "meeting_locations": len(meeting_rows),
        "photo_places": len(photo_rows),
        "places": len(payloads),
        "written": upsert_counts["written"],
        "errors": upsert_counts["errors"],
    }


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(name)s: %(message)s"
    )
    parser = argparse.ArgumentParser(
        description=(
            "Aggregate meeting/photo location signals into Qdrant "
            "preferences (category=place) so the wiki Places page populates."
        )
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    oxigraph_url = config.OXIGRAPH_URL
    qdrant_url = config.QDRANT_URL
    embed_url = config.EMBED_OLLAMA_URL
    embed_model = config.EMBED_MODEL

    if not oxigraph_url:
        print("OXIGRAPH_URL not configured.", file=sys.stderr)
        return 1
    if not qdrant_url:
        print("QDRANT_URL not configured.", file=sys.stderr)
        return 1

    result = ingest_places(
        oxigraph_url=oxigraph_url,
        qdrant_url=qdrant_url,
        embed_url=embed_url,
        embed_model=embed_model,
        dry_run=args.dry_run,
        verbose=args.verbose,
    )

    print(
        f"\nDone: {result['places']} places "
        f"({result['written']} written, {result['errors']} errors) "
        f"from {result['meeting_locations']} meeting locations + "
        f"{result['photo_places']} photo places. status={result['status']}"
    )

    # Non-zero exit on the loud-guard failure or any upsert error so the
    # install log + CI surface it.
    if result["status"] != "ok" or result["errors"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
