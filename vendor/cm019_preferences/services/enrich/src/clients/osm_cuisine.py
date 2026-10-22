"""Cuisine of a restaurant from OpenStreetMap, no API key and no account.

Asks Nominatim (``extratags=1``) for the venue and reads its ``cuisine=`` tag.
Runs ONLY when the owner accepted enrichment at install: the consent is
checked here as well as at the enricher's entry points, and a refusal returns
before any HTTP client is built, so declining means no request at all.

Usage-policy compliance (operations.osmfoundation.org/policies/nominatim):
an identifying User-Agent, at most one request per second (the base client's
limiter), and results cached on disk so a venue is asked about once.
Negative answers are cached too, for a shorter time, so a venue OSM does not
know is not asked about every run.

What leaves the machine: the restaurant name and area text, as the query. That is
the place name the owner visited, which is what the install's enrichment consent
covers. Never a person, a message, a dish or a street address.

Attribution: the cuisine tag is OpenStreetMap data (ODbL). It is stored in the local
cache file with the credit and turned into a word from our own vocabulary
(``chinese``); no OSM-sourced name or text is shown anywhere. Any surface that ever
shows OSM-sourced content must carry "(c) OpenStreetMap contributors".
"""

import asyncio
import fcntl
import json
import logging
import os
import re
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Optional

from .base import BaseClient, InMemoryCache
from ..config import settings
from ..consent import public_lookup_allowed
from ..derive.cuisine_vocab import normalise_cuisines
from ..models.enrichment import EnrichmentResult, EnrichmentSource, MatchType, TopicResult, EntityResult

logger = logging.getLogger(__name__)

EATING_PLACES = {"restaurant", "cafe", "fast_food", "food_court", "bar", "pub", "ice_cream", "biergarten"}
POSITIVE_TTL_S = 90 * 86400
NEGATIVE_TTL_S = 30 * 86400
# Product name/version plus a contact URL, as the usage policy asks. Never the HTTP
# library's default agent.
USER_AGENT = "Ostler/1.0 (restaurant cuisine lookup; contact https://ostler.ai)"
MIN_INTERVAL_S = 1.0
# A ceiling on lookups per process so a first run over a large history is not a bulk
# geocode: the enricher offers one point at a time and the cache answers repeats.
MAX_LOOKUPS_PER_RUN = int(os.environ.get("OSTLER_OSM_MAX_LOOKUPS", "100"))
ATTRIBUTION = "Cuisine tags (c) OpenStreetMap contributors, ODbL: https://www.openstreetmap.org/copyright"


class CrossProcessLimiter:
    """At most one request per MIN_INTERVAL_S across ALL processes.

    A lock file holds the time of the last request. Entering takes an exclusive
    flock, sleeps until the interval has passed since that stamp, writes the new
    stamp and releases. Drop-in for the AsyncLimiter the base client uses
    (``async with self.rate_limiter``), so every retry is spaced too.
    """

    def __init__(self, path: Path, interval: float = MIN_INTERVAL_S):
        self.path, self.interval = Path(path), interval

    def _wait_turn(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(self.path), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                last = float(os.pread(fd, 64, 0).decode() or 0)
            except ValueError:
                last = 0.0
            wait = last + self.interval - time.time()
            if wait > 0:
                time.sleep(wait)
            os.ftruncate(fd, 0)
            os.pwrite(fd, repr(time.time()).encode(), 0)
        finally:
            os.close(fd)   # closing releases the flock

    async def __aenter__(self):
        await asyncio.to_thread(self._wait_turn)

    async def __aexit__(self, *exc):
        return False


def _tokens(s: str) -> set:
    return {t for t in re.split(r"[^a-z0-9À-￿]+", (s or "").lower()) if len(t) > 1}


def _cache_file() -> Path:
    base = os.environ.get("OSTLER_DIR") or str(Path.home() / ".ostler")
    return Path(base) / "cache" / "osm_cuisine.json"


class OsmCuisineClient(BaseClient[Dict[str, Any]]):
    BASE_URL = "https://nominatim.openstreetmap.org"
    CACHE_PREFIX = "osm_cuisine"

    def __init__(self, cache: Optional[InMemoryCache] = None, cache_path: Optional[Path] = None):
        # Nominatim: absolute maximum 1 request per second.
        super().__init__(rate_limit=1.0, max_retries=settings.max_retries, timeout=settings.request_timeout, cache=cache)
        self._path = Path(cache_path) if cache_path else _cache_file()
        self.rate_limiter = CrossProcessLimiter(self._path.with_suffix(".rate"))
        self._lookups = 0
        self._disk: Optional[Dict[str, Any]] = None

    def _get_headers(self) -> Dict[str, str]:
        return {"Accept": "application/json", "User-Agent": USER_AGENT}

    # -- persistent cache --
    def _load(self) -> Dict[str, Any]:
        if self._disk is None:
            try:
                self._disk = json.loads(self._path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                self._disk = {}
        return self._disk

    def _save(self) -> None:
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=str(self._path.parent), prefix=".osm_cuisine.")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({**self._disk, "_attribution": ATTRIBUTION}, fh)
            os.replace(tmp, self._path)
        except OSError as exc:
            logger.debug("osm cuisine cache not saved (%s)", type(exc).__name__)

    @staticmethod
    def _key(name: str, area: str) -> str:
        return " ".join(sorted(_tokens(name))) + "|" + " ".join(sorted(_tokens(area)))

    def _cached(self, key: str):
        row = self._load().get(key)
        if not isinstance(row, dict):
            return None
        ttl = POSITIVE_TTL_S if row.get("cuisines") else NEGATIVE_TTL_S
        return row if time.time() - row.get("at", 0) < ttl else None

    # -- lookup --
    async def lookup(self, name: str, area: str = "") -> Optional[Dict[str, Any]]:
        """{'cuisines': [...], 'osm_id': ..} (cuisines may be empty), None on a failed call."""
        key = self._key(name, area)
        hit = self._cached(key)
        if hit is not None:
            self._cache_hits += 1
            return hit
        if self._lookups >= MAX_LOOKUPS_PER_RUN:
            return None   # over the per-run ceiling: no bulk geocoding; try again next run
        self._lookups += 1
        q = f"{name} {area}".strip()
        rows = await self._make_request(
            "GET", f"{self.BASE_URL}/search",
            params={"q": q, "format": "jsonv2", "extratags": 1, "limit": 5, "addressdetails": 0},
        )
        if rows is None:
            return None  # a failed call is not an answer; do not cache it
        want = _tokens(name)
        found: Dict[str, Any] = {"cuisines": [], "at": time.time()}
        for r in rows if isinstance(rows, list) else []:
            if r.get("type") not in EATING_PLACES and r.get("category") not in ("amenity",):
                continue
            got = _tokens(str(r.get("name") or r.get("display_name", "").split(",")[0]))
            if not want or len(want & got) / len(want) < 0.6:
                continue
            found["osm_id"] = f"{r.get('osm_type')}/{r.get('osm_id')}"
            found["cuisines"] = normalise_cuisines((r.get("extratags") or {}).get("cuisine"))
            break
        self._load()[key] = found
        self._save()
        return found

    async def enrich_venue(self, preference_id: str, name: str, area: str = "") -> EnrichmentResult:
        result = EnrichmentResult(preference_id=preference_id, original_subject=name, source=EnrichmentSource.OSM)
        # Fail closed BEFORE any client or request exists.
        if not public_lookup_allowed():
            result.error = "enrichment not accepted by the owner; no request made"
            return result
        got = await self.lookup(name, area)
        if got is None:
            result.error = "lookup failed"
            return result
        if not got.get("cuisines"):
            result.error = "no cuisine tag"
            result.match_type = MatchType.NONE
            result.confidence = 0.0
            return result
        result.match_type = MatchType.FUZZY_TITLE
        result.confidence = 0.8
        result.matched_title = name
        for c in got["cuisines"]:
            result.topics.append(TopicResult(name=c, normalized=c.lower().replace(" ", "_"), confidence=0.8, source_field="osm_cuisine"))
        result.entities.append(EntityResult(name=name, entity_type="venue", external_id=f"osm:{got.get('osm_id', '')}"))
        return result

    async def search(self, query: str) -> Optional[Dict[str, Any]]:
        return await self.lookup(query)

    async def get_details(self, item_id: str) -> Optional[Dict[str, Any]]:
        return None
