#!/usr/bin/env python3
"""Reverse the Netflix thumbs-value polarity bug on already-ingested points.

WHY A REPAIR PASS EXISTS AT ALL.

The fix in ``services/ingest/src/parsers/netflix.py`` (``_parse_ratings``)
stops new ingests writing the wrong polarity. It cannot un-write the points
already in the store, and the wiki renders what is in the store, not what
the parser would do today. Until this script runs on an upgraded box, the
parser fix changes nothing a customer with existing Netflix data can see.

WHAT WAS WRONG, AND WHAT THIS SCRIPT DOES ABOUT EACH SHAPE. The buggy
parser wrote three labels (``rating_type`` under the point's ``extra``
payload) for the wrong reason, and left one correct:

    stored rating_type   really meant (true Netflix encoding)   action
    ------------------   ------------------------------------   ------
    two_thumbs_down       Thumbs Value=2, a REAL thumbs-up       RECLASSIFY to Like / thumbs_up
    thumbs_up             Thumbs Value=1, a REAL thumbs-down     RECLASSIFY to Dislike / thumbs_down
    thumbs_down           Thumbs Value=0, NOT RATED AT ALL       DELETE (never a real preference)
    two_thumbs_up          Thumbs Value=3, correct already       left alone (not touched)

WHY DELETION FOR THE "NOT RATED" BUCKET, NOT RECLASSIFICATION. There is no
polarity for an opinion that was never given. Reclassifying it to Neutral
would still assert a preference exists; it does not.

IDEMPOTENCY. Every record this script touches gets a marker written into
its ``extra`` payload: ``netflix_thumbs_polarity_repaired_c10: true``. The
query that selects candidates ALWAYS excludes records already carrying that
marker. This is load-bearing, not decoration: after the first run, a
repaired "two_thumbs_down" record now reads ``rating_type: "thumbs_up"`` --
exactly the SAME label a genuinely-still-wrong record would carry. Without
the marker, a second run would read that already-fixed record as new
damage and flip it straight back to a dislike. The marker is what makes
"fixed" and "still broken" distinguishable once they share a label. The
"not rated" bucket needs no marker: it is deleted, and a deleted point
cannot be found again by the same filter.

DRY RUN BY DEFAULT. Nothing is changed without ``--apply``.

Usage:
    python repair_netflix_rating_polarity.py                    # count only
    python repair_netflix_rating_polarity.py --apply             # repair
    python repair_netflix_rating_polarity.py --qdrant-url URL --collection preferences
"""

import argparse
import sys
from typing import Any

import httpx

DEFAULT_QDRANT_URL = "http://127.0.0.1:6333"
DEFAULT_COLLECTION = "preferences"
MARKER_KEY = "netflix_thumbs_polarity_repaired_c10"

# stored (wrong) rating_type -> the corrected fields a RECLASSIFY applies.
# "thumbs_down" is handled separately (DELETE_LABEL), not reclassified.
RECLASSIFY_FIXES: dict[str, dict[str, Any]] = {
    "two_thumbs_down": {
        "preference_type": "Like",
        "strength": 0.35,
        "rating_type": "thumbs_up",
    },
    "thumbs_up": {
        "preference_type": "Dislike",
        "strength": -0.35,
        "rating_type": "thumbs_down",
    },
}
DELETE_LABEL = "thumbs_down"
ALL_WRONG_LABELS = tuple(RECLASSIFY_FIXES.keys()) + (DELETE_LABEL,)


def _candidate_filter() -> dict:
    """Qdrant filter: Netflix rating points carrying a wrong label, not yet
    repaired. The marker exclusion is what makes re-running this safe."""
    return {
        "must": [
            {"key": "source", "match": {"value": "netflix"}},
            {"key": "extra.rating_type", "match": {"any": list(ALL_WRONG_LABELS)}},
        ],
        "must_not": [
            {"key": f"extra.{MARKER_KEY}", "match": {"value": True}},
        ],
    }


def plan_for_point(payload: dict) -> dict | None:
    """Pure decision function, no I/O: given a point's CURRENT payload,
    return what to do next, or None if this point needs nothing (already
    repaired, or not a wrong-label row at all). Kept separate from the
    network calls so it can be tested without a Qdrant.

    Returns one of:
      {"action": "skip"}
      {"action": "delete"}
      {"action": "set_payload", "payload": {...}}   -- full new payload
          (preference_type/strength changed, extra carries the marker and
          the corrected rating_type, every other extra key preserved)
    """
    extra = payload.get("extra") or {}
    if not isinstance(extra, dict):
        return {"action": "skip"}
    if extra.get(MARKER_KEY) is True:
        return {"action": "skip"}

    rating_type = extra.get("rating_type")
    if rating_type == DELETE_LABEL:
        return {"action": "delete"}

    fix = RECLASSIFY_FIXES.get(rating_type)
    if fix is None:
        return {"action": "skip"}

    new_extra = dict(extra)
    new_extra["rating_type"] = fix["rating_type"]
    new_extra[MARKER_KEY] = True
    new_payload = dict(payload)
    new_payload["preference_type"] = fix["preference_type"]
    new_payload["strength"] = fix["strength"]
    new_payload["extra"] = new_extra
    return {"action": "set_payload", "payload": new_payload}


def _scroll_all(client: httpx.Client, base: str, collection: str, flt: dict) -> list[dict]:
    points: list[dict] = []
    offset = None
    while True:
        body: dict[str, Any] = {"limit": 500, "with_payload": True, "filter": flt}
        if offset is not None:
            body["offset"] = offset
        resp = client.post(f"{base}/collections/{collection}/points/scroll", json=body)
        resp.raise_for_status()
        result = resp.json()["result"]
        batch = result.get("points", [])
        points.extend(batch)
        offset = result.get("next_page_offset")
        if not batch or not offset:
            break
    return points


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qdrant-url", default=DEFAULT_QDRANT_URL)
    parser.add_argument("--collection", default=DEFAULT_COLLECTION)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="actually repair. Without this the script only counts.",
    )
    args = parser.parse_args()

    base = args.qdrant_url.rstrip("/")

    with httpx.Client(timeout=60.0, trust_env=False) as client:
        try:
            resp = client.post(f"{base}/collections/{args.collection}/points/count", json={"exact": True})
            resp.raise_for_status()
            total = resp.json()["result"]["count"]
        except Exception as exc:  # noqa: BLE001 - operator-facing tool
            print(f"CANNOT REACH QDRANT at {base}: {exc}", file=sys.stderr)
            print(
                "Refusing to report 0 candidates. An unreachable store is not "
                "an empty one, and a 0 printed here would be read as "
                "'nothing to repair'.",
                file=sys.stderr,
            )
            return 2

        candidates = _scroll_all(client, base, args.collection, _candidate_filter())

        plans = [(p["id"], plan_for_point(p.get("payload", {}))) for p in candidates]
        to_reclassify = [(pid, pl) for pid, pl in plans if pl["action"] == "set_payload"]
        to_delete = [pid for pid, pl in plans if pl["action"] == "delete"]

        print(f"collection      : {args.collection} @ {base}")
        print(f"points total    : {total}")
        print(f"candidates found: {len(candidates)} (wrong label, not yet repaired)")
        print(f"  to reclassify : {len(to_reclassify)}")
        print(f"  to delete     : {len(to_delete)} (Thumbs Value=0, not rated)")

        if not candidates:
            print("\nNothing to do.")
            return 0

        if not args.apply:
            print(f"\nDRY RUN. Re-run with --apply to repair {len(candidates)} point(s).")
            return 0

        for pid, pl in to_reclassify:
            # set_payload, NOT the upsert endpoint: upsert requires a vector
            # and this script never fetched one (with_vector was False on
            # the scroll above, deliberately -- it is not needed to decide
            # or apply this fix, and fetching it for ~100 points only to
            # discard it would be wasted work). set_payload merges at the
            # TOP LEVEL only, replacing preference_type/strength/extra
            # wholesale while leaving every other payload key (category,
            # subject, user_id, ...) and the point's vector untouched.
            resp = client.put(
                f"{base}/collections/{args.collection}/points/payload",
                json={
                    "points": [pid],
                    "payload": {
                        "preference_type": pl["payload"]["preference_type"],
                        "strength": pl["payload"]["strength"],
                        "extra": pl["payload"]["extra"],
                    },
                },
            )
            resp.raise_for_status()

        if to_delete:
            resp = client.post(
                f"{base}/collections/{args.collection}/points/delete",
                json={"points": to_delete},
            )
            resp.raise_for_status()

        remaining = len(_scroll_all(client, base, args.collection, _candidate_filter()))
        print(f"\nreclassified    : {len(to_reclassify)}")
        print(f"deleted         : {len(to_delete)}")
        print(f"remaining       : {remaining}")

        if remaining:
            print(
                "\nREPAIR DID NOT FULLY APPLY. Re-run to confirm before "
                "treating this as done.",
                file=sys.stderr,
            )
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
