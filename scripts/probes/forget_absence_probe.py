#!/usr/bin/env python3
"""Walk probe: after a forget, the forgotten fact is absent from the facts file,
summary.md and the summary vector's payload. Each absence is paired with a
CONTROL fact that must still be present in the same store. Without the control,
an empty store would read as "absent" and pass.

Verdicts per store: PASS (forgotten absent AND control present), FAIL (forgotten
still present, or control missing), CANNOT-RUN (the store could not be read).
The probe exits 0 only if all three stores PASS. Nothing here prints a secret.

Usage:
  forget_absence_probe.py --processing DIR --bundle DIR \
      --qdrant URL --collection NAME --forgotten TEXT --control TEXT
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _verdict(forgotten_present, control_present):
    if forgotten_present is None or control_present is None:
        return "CANNOT-RUN"
    if forgotten_present:
        return "FAIL"
    if not control_present:
        return "FAIL"
    return "PASS"


def _facts_hits(processing: Path, needle: str):
    """Return (forgotten_present, control_present) over every 05_facts.json."""
    if not processing.is_dir():
        return None, None
    seen_files = 0
    forgotten = False
    control = False
    for facts in processing.glob("*/05_facts.json"):
        seen_files += 1
        try:
            body = facts.read_text(encoding="utf-8")
        except OSError:
            return None, None
        forgotten |= FORGOTTEN_TEXT in body
        control |= CONTROL_TEXT in body
    if seen_files == 0:
        return None, None
    return forgotten, control


def _summary_hits(bundle: Path):
    if not bundle.is_dir():
        return None, None
    paths = list(bundle.rglob("summary.md"))
    if not paths:
        return None, None
    forgotten = control = False
    for p in paths:
        try:
            body = p.read_text(encoding="utf-8")
        except OSError:
            return None, None
        forgotten |= FORGOTTEN_TEXT in body
        control |= CONTROL_TEXT in body
    return forgotten, control


def _vector_hits(qdrant: str, collection: str):
    """Scroll every conversation_summary point; the payload text is the store's copy."""
    import httpx
    try:
        with httpx.Client(timeout=30.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            r = hc.post("%s/collections/%s/points/scroll" % (qdrant, collection),
                        json={"filter": {"must": [{"key": "point_type",
                                                   "match": {"value": "conversation_summary"}}]},
                              "with_payload": True, "limit": 1000})
            r.raise_for_status()
            points = r.json()["result"]["points"]
    except Exception:
        return None, None
    if not points:
        return None, None
    texts = [str(p.get("payload", {}).get("text", "")) for p in points]
    return (any(FORGOTTEN_TEXT in t for t in texts), any(CONTROL_TEXT in t for t in texts))


FORGOTTEN_TEXT = ""
CONTROL_TEXT = ""


def main(argv=None) -> int:
    global FORGOTTEN_TEXT, CONTROL_TEXT
    ap = argparse.ArgumentParser()
    ap.add_argument("--processing", type=Path, required=True)
    ap.add_argument("--bundle", type=Path, required=True)
    ap.add_argument("--qdrant", required=True)
    ap.add_argument("--collection", required=True)
    ap.add_argument("--forgotten", required=True)
    ap.add_argument("--control", required=True)
    a = ap.parse_args(argv)
    FORGOTTEN_TEXT, CONTROL_TEXT = a.forgotten, a.control

    results = {
        "facts": _verdict(*_facts_hits(a.processing, FORGOTTEN_TEXT)),
        "summary.md": _verdict(*_summary_hits(a.bundle)),
        "summary vector": _verdict(*_vector_hits(a.qdrant, a.collection)),
    }
    for store, verdict in results.items():
        print("%-15s %s" % (store, verdict))
    print("denominator: %d stores" % len(results))
    return 0 if all(v == "PASS" for v in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
