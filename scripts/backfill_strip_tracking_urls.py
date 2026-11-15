#!/usr/bin/env python3
"""One-shot, idempotent backfill: strip tracking params from URLs already stored.

DRY-RUN BY DEFAULT. Prints counts and writes nothing. Pass --apply to write.
Never run by the installer, the cut or CI against a real box; it ships for a
human to decide.

What it covers (stdlib only, loopback Qdrant, no proxy):
  1. Qdrant browsing collection (BROWSING_QDRANT_COLLECTION, default
     safari_history): points whose payload.url changes under strip_tracking().
     If the point id is the one the ingest would mint for the OLD url
     (uuid5 "browsing|<src>|<url>|<timestamp>"), the point is RE-KEYED to the
     id minted for the clean url (copy with vector, then delete the old); if
     the clean id already exists the old point is just deleted (dedupe). Any
     other id: payload.url is set in place.
  2. Qdrant preferences collection (PREFERENCES_QDRANT_COLLECTION, default
     preferences), points with payload.source == safari_bookmarks only, same
     rule with id "bookmark|<url>".
  3. FDA extractor JSON files (safari_history.json, chrome_history.json,
     safari_bookmarks.json) under --fda-dir, rewritten atomically.

NOT COVERED, and the dry-run says so: Oxigraph. CM051 vendored code stores no
browsing URL as a triple (grep of vendor/ostler_fda and the Hub handler found
none), so there is nothing to rewrite; if a box has one from another path,
this does not see it. Vectors are kept as they are: the embedded text held the
old url, which only affects similarity at the margin.

Idempotent: a second --apply finds 0 changes.
Counts only in output. No URLs are printed.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import urllib.request
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Load by path, never by sys.path: vendor/ostler_fda holds a calendar.py that
# would shadow the stdlib module for everything imported after us.
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "url_clean", HERE.parent / "vendor" / "ostler_fda" / "url_clean.py")
_uc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_uc)
strip_tracking = _uc.strip_tracking

QDRANT = os.environ.get("QDRANT_URL", "http://localhost:6333").rstrip("/")
BROWSING = os.environ.get("BROWSING_QDRANT_COLLECTION", "safari_history")
PREFS = os.environ.get("PREFERENCES_QDRANT_COLLECTION", "preferences")
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _call(method, path, body=None):
    headers = {"Content-Type": "application/json"}
    key = os.environ.get("QDRANT_API_KEY")
    if key:
        headers["api-key"] = key
    req = urllib.request.Request(
        QDRANT + path, method=method, headers=headers,
        data=None if body is None else json.dumps(body).encode())
    with _OPENER.open(req, timeout=60) as r:
        return json.loads(r.read() or b"{}")


def _scroll(collection):
    offset = None
    while True:
        body = {"limit": 256, "with_payload": True, "with_vector": False}
        if offset is not None:
            body["offset"] = offset
        res = _call("POST", f"/collections/{collection}/points/scroll", body)["result"]
        yield from res.get("points") or []
        offset = res.get("next_page_offset")
        if offset is None:
            return


def _ids_for(url, payload, bookmark):
    ts = payload.get("timestamp") or ""
    if bookmark:
        return [("bookmark", str(uuid.uuid5(uuid.NAMESPACE_URL, f"bookmark|{url}")))]
    srcs = []
    for s in (payload.get("source"), "safari_history", "chrome_history"):
        if s and s not in srcs:
            srcs.append(s)
    return [(s, str(uuid.uuid5(uuid.NAMESPACE_URL, f"browsing|{s}|{url}|{ts}"))) for s in srcs]


def backfill_collection(collection, apply, bookmark=False):
    c = dict(scanned=0, to_change=0, rekeyed=0, deduped=0, in_place=0, errors=0)
    for pt in list(_scroll(collection)):
        pl = pt.get("payload") or {}
        if bookmark and pl.get("source") != "safari_bookmarks":
            continue
        old = pl.get("url")
        if not isinstance(old, str):
            continue
        c["scanned"] += 1
        new = strip_tracking(old)
        if new == old:
            continue
        c["to_change"] += 1
        old_id = pt["id"]
        rekey = None
        for src, oid in _ids_for(old, pl, bookmark):
            if oid == old_id:
                rekey = dict(_ids_for(new, pl, bookmark))[src]
                break
        try:
            if rekey and rekey != old_id:
                exists = _call("POST", f"/collections/{collection}/points",
                               {"ids": [rekey], "with_payload": False, "with_vector": False})["result"]
                if exists:
                    c["deduped"] += 1
                    if apply:
                        _call("POST", f"/collections/{collection}/points/delete?wait=true",
                              {"points": [old_id]})
                else:
                    c["rekeyed"] += 1
                    if apply:
                        full = _call("POST", f"/collections/{collection}/points",
                                     {"ids": [old_id], "with_payload": True, "with_vector": True})["result"][0]
                        full["payload"]["url"] = new
                        _call("PUT", f"/collections/{collection}/points?wait=true",
                              {"points": [{"id": rekey, "vector": full["vector"], "payload": full["payload"]}]})
                        _call("POST", f"/collections/{collection}/points/delete?wait=true",
                              {"points": [old_id]})
            else:
                c["in_place"] += 1
                if apply:
                    _call("POST", f"/collections/{collection}/points/payload?wait=true",
                          {"payload": {"url": new}, "points": [old_id]})
        except Exception as exc:  # count, never print the url
            c["errors"] += 1
            print(f"  error: {type(exc).__name__}", file=sys.stderr)
    return c


def backfill_json(fda_dir, apply):
    out = {}
    for name in ("safari_history.json", "chrome_history.json", "safari_bookmarks.json"):
        p = Path(fda_dir) / name
        if not p.exists():
            out[name] = "absent"
            continue
        data = json.loads(p.read_text(encoding="utf-8"))
        n = 0
        if isinstance(data, list):
            for row in data:
                if isinstance(row, dict) and isinstance(row.get("url"), str):
                    new = strip_tracking(row["url"])
                    if new != row["url"]:
                        n += 1
                        row["url"] = new
        out[name] = n
        if apply and n:
            fd, tmp = tempfile.mkstemp(dir=str(p.parent))
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.replace(tmp, p)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true", help="write changes (default: dry run)")
    ap.add_argument("--fda-dir", help="directory holding the extractor JSON files")
    ap.add_argument("--skip-qdrant", action="store_true")
    a = ap.parse_args(argv)
    print("MODE:", "APPLY" if a.apply else "DRY-RUN (nothing written)")
    if not a.skip_qdrant:
        for col, bm in ((BROWSING, False), (PREFS, True)):
            try:
                print(f"qdrant {col}{' (bookmarks)' if bm else ''}:", backfill_collection(col, a.apply, bm))
            except Exception as exc:
                print(f"qdrant {col}: CANNOT-RUN {type(exc).__name__}")
    if a.fda_dir:
        print("json files:", backfill_json(a.fda_dir, a.apply))
    print("oxigraph: NOT COVERED (no browsing URL triples in the shipped code)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
