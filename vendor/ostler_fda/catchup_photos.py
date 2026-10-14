"""Photos: walk the library back past the install's first year (v1.0.108).

WHY. extract_all's Photos arm reads ``since_days=365`` (extract_all.py, the
photos_metadata block) and nothing else ever reads further back, so a
customer with fifteen years of photos got one year of "Photos here" places
and dates in the wiki. This is the Photos adapter for the shared full-history
catch-up (lib/ostler_catchup.py), driven by com.ostler.export-scan.

HOW. 30-day windows, newest first, starting at the install edge (now - 365 d
at the first catch-up tick) and ending at the oldest asset in the library
(read once, inside the first batch, and kept in the cursor). Each window is
extracted with the SAME rule extract_all uses (face names only with the
photos_faces opt-in, and with the opt-in only photos that carry a face),
written as photos_events.json into a scratch dir, and handed to the shipped
writer, pwg_ingest.ingest_photo_events. Windows are half-open
(lower, upper], contiguous, so nothing falls between two of them.

DEDUPE. The ledger key is the window. The sink is keyed too: every
pwg:PhotoEvent URI is uuid5(date, coordinates), so a window written twice
re-inserts identical triples and adds nothing.

ONLY WHEN THE CUSTOMER PICKED PHOTOS. The adapter runs only if the install
recorded a Photos result (state/hydrate/photos.done, which install.sh writes
for every outcome except "declined"), and never if OSTLER_FDA_SOURCES is set
without photos_metadata.

Counts only in logs. No names, no places.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional

import ostler_catchup as oc

from . import photos_metadata as pm

logger = logging.getLogger(__name__)

INSTALL_WINDOW_DAYS = 365   # extract_all.py: extract_photo_events(since_days=365, ...)
WINDOW_DAYS = 30


def _sources_env() -> Optional[set]:
    raw = os.environ.get("OSTLER_FDA_SOURCES", "").strip()
    if not raw:
        return None
    return {s.strip() for s in raw.split(",") if s.strip()}


def photos_enabled(home: Optional[Path] = None) -> bool:
    env = _sources_env()
    if env is not None and "photos_metadata" not in env:
        return False
    home = home or oc.ostler_home()
    return (home / "state" / "hydrate" / "photos.done").is_file()


def faces_enabled(home: Optional[Path] = None) -> bool:
    """extract_all's rule: faces only with the photos_faces opt-in. The opt-in
    is the env when present, else the file extract_all writes ONLY with it."""
    env = _sources_env()
    if env is not None:
        return "photos_faces" in env
    home = home or oc.ostler_home()
    return (home / "imports" / "fda" / "photos_people.json").is_file()


def _default_ingest(window_dir: Path) -> dict:
    from .pwg_ingest import ingest_photo_events
    return ingest_photo_events(window_dir)


class PhotosAdapter(oc.Adapter):
    source = "photos"
    doctor_row = "photos"
    batch_size = 3   # windows per batch

    def __init__(self, db_path: Optional[Path] = None, *, now: Optional[datetime] = None,
                 work_dir: Optional[Path] = None, faces: Optional[bool] = None,
                 ingest: Optional[Callable[[Path], dict]] = None,
                 window_days: int = WINDOW_DAYS):
        self.db_path = db_path
        self.now = now
        self.work_dir = work_dir
        self.faces = faces
        self.ingest = ingest or _default_ingest
        self.window = int(window_days) * 86400

    def start_cursor(self):
        now = self.now or datetime.now(timezone.utc)
        edge = int((now - timedelta(days=INSTALL_WINDOW_DAYS)).timestamp())
        # The floor is read inside next_batch, where a missing library or an
        # ungranted Full Disk Access is reported as this source's failure.
        return {"upper": edge, "floor": None, "floor_read": False}

    def next_batch(self, cursor, limit):
        cur = dict(cursor)
        if not cur.get("floor_read"):
            oldest = pm.oldest_asset_date(self.db_path)
            cur["floor"] = int(oldest.timestamp()) if oldest else None
            cur["floor_read"] = True
        upper, floor = int(cur["upper"]), cur["floor"]
        if floor is None or upper < floor:
            return oc.Batch(items=[], next_cursor=cur, oldest_at=None, exhausted=True)
        items, exhausted, lower = [], False, upper
        for _ in range(max(1, limit)):
            lower = upper - self.window
            items.append({"lower": lower, "upper": upper})
            upper = lower
            if lower < floor:
                exhausted = True
                break
        cur["upper"] = upper
        oldest_at = oc.to_iso(max(lower, floor))
        return oc.Batch(items=items, next_cursor=cur, oldest_at=oldest_at, exhausted=exhausted)

    def key(self, item):
        return "photos:%d-%d" % (item["lower"], item["upper"])

    def process(self, item):
        faces = self.faces if self.faces is not None else faces_enabled()
        events = pm.extract_photo_events(
            self.db_path,
            with_people_only=faces,
            since=datetime.fromtimestamp(item["lower"], tz=timezone.utc),
            until=datetime.fromtimestamp(item["upper"], tz=timezone.utc),
        )
        if not faces:
            for e in events:
                e.people = []
        base = self.work_dir or (oc.state_dir() / "photos-work")
        d = base / self.key(item).replace(":", "_")
        d.mkdir(parents=True, exist_ok=True)
        try:
            (d / "photos_events.json").write_text(
                json.dumps([asdict(e) for e in events], indent=2, default=str))
            if faces:
                # ingest_photo_events writes face edges only when this file
                # exists, which is exactly extract_all's opt-in signal.
                (d / "photos_people.json").write_text("[]")
            res = self.ingest(d) or {}
        finally:
            shutil.rmtree(d, ignore_errors=True)
        ok = res.get("status") == "ok" or (not events and res.get("status") == "skipped")
        logger.info("catch-up photos window: %d event(s), status=%s", len(events), res.get("status"))
        return ok


def adapters():
    if not photos_enabled():
        logger.info("catch-up photos: Photos was not chosen at install; nothing to walk")
        return []
    return [PhotosAdapter()]
