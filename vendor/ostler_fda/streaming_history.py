"""Recognise what the owner WATCHES and LISTENS to from browser history.

Input: the timeline dicts safari_history / chrome_history already emit
(``url``, ``domain``, ``title``, ``timestamp``, ``source``). Output: one
preference payload per viewing SESSION, in the shape ``ingest_bookmarks``
writes into the Qdrant ``preferences`` collection, which is the path
export importers use and the one interest_profile reads. No new store.

Services: Netflix, Prime Video, Max, Disney+, Apple TV+, YouTube and
YouTube Music. A YouTube music video (an "Artist - Song (Official Video)"
title) feeds music taste, not film and TV.

Rules, each pinned by tests/test_streaming_history.py:

* Local only. The service, title and artist come from the URL and the page
  title and nothing else. There is no network lookup anywhere in this file.
* A page is a viewing only if its URL SHAPE says so: a watch page, a video
  page, a title or detail page. A homepage, a browse page, a search page, a
  channel page or a playlist page is never a title, however its page title
  reads ("Netflix", "foo - YouTube").
* Netflix ``/watch/<id>`` carries the bare title "Netflix" in a real
  browser, so a title that cannot be read is NOT a title: the visit is
  dropped and counted, never guessed.
* Dedupe per viewing session: visits to the same video or title within
  ``SESSION_GAP`` of each other are one session (a seek, a reload, ``&t=``
  all collapse). A later return is a new session, so a rewatch counts.
* Watch time is NOT emitted. History records when a page was opened, not how
  long it played; a first-to-last span would be a guess dressed as a
  measurement, so the field does not exist.
* Strength rests on evidence only: watching (a watch page or autoplay)
  outweighs merely opening a title page, and a generic YouTube video
  weighs least.
* The stored URL is rebuilt from the parsed identity, never copied: YouTube
  keeps ``v=`` and ``list=`` and nothing else; every other service keeps
  scheme, host and path. Tracking parameters therefore cannot ride along,
  whatever the upstream URL cleaner did or did not strip.
* A visit flagged private/incognito by a reader is dropped. Today's
  Safari/Chrome readers never see private windows (the browsers do not
  write them), so the flag is belt and braces for a future reader.
* Privacy level is the browsing default (set by the caller). Minor and
  deceased flags are not read or changed here.
"""
from __future__ import annotations

import re
import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional
from urllib.parse import parse_qs, urlparse

SOURCE = "streaming_history"
SESSION_GAP = timedelta(minutes=30)

# interest_profile category names: movie_tv and music carry trust and a
# domain there; "video" is unknown to it on purpose (default trust, sinks).
CAT_FILM_TV = "movie_tv"
CAT_MUSIC = "music"
CAT_VIDEO = "video"

# Evidence -> base strength. Capped, never derived from time on page.
_STRENGTH = {
    ("watched", CAT_FILM_TV): 0.60,
    ("viewed", CAT_FILM_TV): 0.30,
    ("watched", CAT_MUSIC): 0.55,
    ("watched", CAT_VIDEO): 0.25,
}

_LRM = "\u200e\u200f\u202a\u202c"
_GENERIC_TITLES = {
    "", "netflix", "youtube", "youtube music", "prime video", "amazon prime video",
    "max", "hbo max", "disney+", "disney plus", "apple tv", "apple tv+", "home",
    "browse", "search", "sign in", "log in", "watch", "watch now", "my list",
    "subscriptions", "history", "library", "explore", "trending", "shorts",
    "loading", "loading...",
}

_PRIVATE_FLAGS = ("private", "incognito", "is_private", "private_browsing")


@dataclass(frozen=True)
class Viewing:
    """One recognised page visit, before session dedupe."""
    service: str
    category: str
    kind: str               # show | film | episode | track | video | music_video
    title: str              # the title as read from the page
    subject: str            # what the preference is ABOUT (series, artist, title)
    identity: str           # stable per title/video: the dedupe key
    url: str                # rebuilt, tracking-free
    evidence: str           # watched | viewed
    at: datetime
    channel: Optional[str] = None
    artist: Optional[str] = None
    series: Optional[str] = None


# -- title cleaning -------------------------------------------------

_YT_SUFFIX = re.compile(r"\s+[-|\u2013]\s+YouTube(?: Music)?\s*$", re.I)
_NOTIFY_PREFIX = re.compile(r"^\(\d+\+?\)\s+")


def _clean(text: str) -> str:
    text = unicodedata.normalize("NFC", text or "")
    for ch in _LRM:
        text = text.replace(ch, "")
    return re.sub(r"\s+", " ", text).strip()


def _is_generic(text: str) -> bool:
    return _clean(text).casefold() in _GENERIC_TITLES


def _strip_site(title: str, site_names: tuple[str, ...]) -> str:
    """Remove "Watch ", "Site: " and " | Site" / " - Site" decoration."""
    t = _clean(title)
    names = "|".join(re.escape(n) for n in site_names)
    t = re.sub(rf"\s+[|\-\u2013\u2014]\s+(?:{names})\s*$", "", t, flags=re.I)
    t = re.sub(rf"^(?:{names})\s*[:|\-\u2013\u2014]\s+", "", t, flags=re.I)
    t = re.sub(r"^Amazon\.[a-z.]+:\s*", "", t, flags=re.I)
    t = re.sub(r"^Watch\s+", "", t, flags=re.I)
    t = re.sub(r"\s+[|\-\u2013\u2014]\s+(?:Prime Video|Amazon Prime Video)\s*$", "", t, flags=re.I)
    return _clean(t)


_EPISODE_TAIL = re.compile(
    r"^(?P<series>.+?)\s*(?:[-:\u2013|]\s*)?"
    r"(?:\bS(?P<s>\d{1,2})\s*[:.]?\s*E(?P<e>\d{1,3})\b"
    r"|\bSeason\s+(?P<s2>\d{1,2})\b[,:\s-]*(?:Episode|Ep\.?)\s*(?P<e2>\d{1,3})\b)",
    re.I,
)


def _series_of(title: str) -> Optional[str]:
    m = _EPISODE_TAIL.match(title)
    if m:
        series = _clean(m.group("series"))
        if series and not _is_generic(series):
            return series
    return None


# -- per-service recognisers: (host, path, query, title, at) -> Viewing|None --


def _viewing(service, category, kind, title, subject, identity, url, evidence, at, **kw):
    title = _clean(title)
    subject = _clean(subject)
    if _is_generic(title) or _is_generic(subject):
        return None
    return Viewing(service, category, kind, title, subject, identity, url, evidence, at, **kw)


def _netflix(host, path, query, title, at):
    m = re.match(r"^/(?:[a-z]{2}(?:-[A-Za-z]{2})?/)?(watch|title)/(\d+)/?$", path)
    if not m:
        return None  # /browse, /search, /latest, /kids, /: never a title
    t = _strip_site(title, ("Netflix",))
    if _is_generic(t):
        return None
    watched = m.group(1) == "watch"
    series = _series_of(t)
    kind = "episode" if series else ("film" if watched else "show")
    return _viewing("netflix", CAT_FILM_TV, kind, t, series or t,
                    f"netflix:{m.group(1)}:{m.group(2)}",
                    f"https://www.netflix.com/{m.group(1)}/{m.group(2)}",
                    "watched" if watched else "viewed", at, series=series)


def _prime(host, path, query, title, at):
    m = re.match(r"^(?:/gp/video)?/detail/([A-Z0-9]{8,12})(?:/|$)", path)
    if not m:
        return None  # storefront, /search, /dp product pages, /gp/video/storefront
    if "amazon." in host and not path.startswith("/gp/video/detail/"):
        return None  # a bare /detail/ on the shop host is not Prime Video
    t = _strip_site(title, ("Prime Video", "Amazon Prime Video"))
    if _is_generic(t):
        return None
    series = _series_of(t)
    autoplay = (query.get("autoplay") or [""])[0] == "1"
    return _viewing("prime_video", CAT_FILM_TV, "episode" if series else "film", t,
                    series or t, f"prime:{m.group(1)}",
                    f"https://{host}{path.split('/ref=')[0]}",
                    "watched" if autoplay else "viewed", at, series=series)


def _max(host, path, query, title, at):
    m = re.match(r"^/(?:[a-z]{2}(?:-[A-Za-z]{2})?/)?video/watch/([0-9a-f-]{36})(?:/([0-9a-f-]{36}))?/?$", path)
    kind_path = None
    if m:
        ident, evidence = m.group(1) + (m.group(2) or ""), "watched"
    else:
        m = re.match(r"^/(?:[a-z]{2}(?:-[A-Za-z]{2})?/)?(shows|movies)/([a-z0-9-]+)/([0-9a-f-]{36})/?$", path)
        if not m:
            return None  # /, /search, /browse, /collections, /hubs
        kind_path, ident, evidence = m.group(1), m.group(3), "viewed"
    t = _strip_site(title, ("Max", "HBO Max"))
    if _is_generic(t):
        return None
    series = _series_of(t)
    kind = "episode" if series else ("show" if kind_path == "shows" else "film")
    return _viewing("max", CAT_FILM_TV, kind, t, series or t, f"max:{ident}",
                    f"https://{host}{path}", evidence, at, series=series)


def _disney(host, path, query, title, at):
    loc = r"(?:/[a-z]{2}(?:-[a-z]{2})?)?"
    m = re.match(rf"^{loc}/(?:video|play)/([0-9a-f-]{{36}})/?$", path)
    kind_path = None
    if m:
        ident, evidence = m.group(1), "watched"
    else:
        m = re.match(rf"^{loc}/(movies|series)/([a-z0-9-]+)/([A-Za-z0-9]+)/?$", path)
        if not m:
            return None  # /home, /browse, /search, /welcome
        kind_path, ident, evidence = m.group(1), m.group(3), "viewed"
    t = _strip_site(title, ("Disney+", "Disney Plus"))
    if _is_generic(t):
        return None
    series = _series_of(t)
    kind = "episode" if series else ("show" if kind_path == "series" else "film")
    return _viewing("disney_plus", CAT_FILM_TV, kind, t, series or t, f"disney:{ident}",
                    f"https://{host}{path}", evidence, at, series=series)


def _apple_tv(host, path, query, title, at):
    m = re.match(r"^/(?:[a-z]{2}/)?(show|movie|episode)/([^/]+)/(umc\.cmc\.[a-z0-9]+)/?$", path)
    if not m:
        return None  # /us, /us/room/..., /us/channel/..., /us/search
    kind_word, ident = m.group(1), m.group(3)
    t = _strip_site(title, ("Apple TV+", "Apple TV"))
    if _is_generic(t):
        return None
    series = _series_of(t)
    kind = {"show": "show", "movie": "film", "episode": "episode"}[kind_word]
    evidence = "watched" if (query.get("playableId") or kind_word == "episode") else "viewed"
    return _viewing("apple_tv_plus", CAT_FILM_TV, kind, t, series or t, f"appletv:{ident}",
                    f"https://{host}{path}", evidence, at, series=series)


_MUSIC_VIDEO_MARK = re.compile(
    r"\(\s*(?:official\s+)?(?:music\s+)?(?:video|lyric\s+video|audio|visuali[sz]er)\s*\)"
    r"|\[\s*(?:official\s+)?(?:music\s+)?(?:video|lyric\s+video|audio)\s*\]"
    r"|\bofficial\s+music\s+video\b",
    re.I,
)
_VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")


def _split_artist(title: str):
    """"Artist - Track (Official Video)" -> (artist, track). Needs the
    separator AND a music-video marker; a bare "A - B" is not assumed to be
    music (tutorials and news use the same shape)."""
    if not _MUSIC_VIDEO_MARK.search(title):
        return None
    parts = re.split(r"\s+[-\u2013\u2014]\s+", title, maxsplit=1)
    if len(parts) != 2:
        return None
    artist, track = _clean(parts[0]), _clean(_MUSIC_VIDEO_MARK.sub("", parts[1]))
    if not artist or not track or _is_generic(artist):
        return None
    return artist, track


def _youtube(host, path, query, title, at):
    music_host = host.startswith("music.")
    vid = None
    if host == "youtu.be":
        vid = path.strip("/").split("/")[0]
    elif path == "/watch":
        vid = (query.get("v") or [""])[0]
    else:
        m = re.match(r"^/(shorts|live)/([A-Za-z0-9_-]{11})/?$", path)
        if m:
            vid = m.group(2)
    if not vid or not _VIDEO_ID.match(vid):
        return None  # /, /results, /feed/*, /@handle, /channel/*, /playlist, /hashtag
    t = _clean(_NOTIFY_PREFIX.sub("", _clean(title)))
    t = _clean(_YT_SUFFIX.sub("", t))
    if _is_generic(t):
        return None
    lst = (query.get("list") or [""])[0]
    base = f"https://{'music.youtube.com' if music_host else 'www.youtube.com'}"
    url = f"{base}/watch?v={vid}" + (f"&list={lst}" if lst else "")
    split = _split_artist(t)
    if music_host:
        # YouTube Music pages are music by host. "Track • Artist" when the
        # tab title carries both; otherwise the track alone, no artist guess.
        parts = [p for p in re.split(r"\s+•\s+", t) if p]
        track, artist = (parts[0], parts[1]) if len(parts) == 2 else (t, None)
        return _viewing("youtube_music", CAT_MUSIC, "track", track, artist or track,
                        f"yt:{vid}", url, "watched", at, artist=artist)
    if split:
        artist, track = split
        return _viewing("youtube", CAT_MUSIC, "music_video", track, artist, f"yt:{vid}",
                        url, "watched", at, artist=artist)
    return _viewing("youtube", CAT_VIDEO, "video", t, t, f"yt:{vid}", url, "watched", at)


_SERVICES = (
    (re.compile(r"^(?:www\.)?netflix\.com$"), _netflix),
    (re.compile(r"^(?:www\.)?primevideo\.com$|^(?:www\.)?amazon\.(?:com|co\.uk|de|co\.jp|ca|com\.au|fr|it|es|in)$"), _prime),
    (re.compile(r"^(?:www\.|play\.)?(?:max|hbomax)\.com$"), _max),
    (re.compile(r"^(?:www\.)?disneyplus\.com$"), _disney),
    (re.compile(r"^tv\.apple\.com$"), _apple_tv),
    (re.compile(r"^(?:www\.|m\.|music\.)?youtube\.com$|^youtu\.be$"), _youtube),
)


def _parse_time(value) -> Optional[datetime]:
    if isinstance(value, datetime):
        dt = value
    else:
        try:
            dt = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
        except (ValueError, TypeError):
            return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def recognise(visit: dict) -> Optional[Viewing]:
    """One timeline dict -> a Viewing, or None when it is not one."""
    if any(visit.get(f) for f in _PRIVATE_FLAGS):
        return None
    at = _parse_time(visit.get("timestamp"))
    url = (visit.get("url") or "").strip()
    if at is None or not url:
        return None
    try:
        p = urlparse(url)
    except ValueError:
        return None
    if p.scheme not in ("http", "https"):
        return None
    host = (p.hostname or "").lower()
    for pattern, fn in _SERVICES:
        if pattern.match(host):
            return fn(host, p.path, parse_qs(p.query), visit.get("title") or "", at)
    return None


def extract_viewings(visits: Iterable[dict]) -> tuple[list[Viewing], dict]:
    """-> (viewings, counts). ``counts`` makes every drop visible: a zero is
    "looked and found none" only when ``seen`` says it looked."""
    out: list[Viewing] = []
    counts = {"seen": 0, "recognised": 0, "not_a_title": 0}
    for v in visits:
        if not isinstance(v, dict):
            continue
        counts["seen"] += 1
        got = recognise(v)
        if got is None:
            counts["not_a_title"] += 1
        else:
            counts["recognised"] += 1
            out.append(got)
    return out, counts


@dataclass(frozen=True)
class Session:
    first: Viewing
    visits: int
    start: datetime
    end: datetime


def sessionise(viewings: Iterable[Viewing]) -> list[Session]:
    """Collapse visits to the same identity within SESSION_GAP of the last one."""
    by_id: dict[tuple[str, str], list[Viewing]] = {}
    for v in viewings:
        by_id.setdefault((v.service, v.identity), []).append(v)
    sessions: list[Session] = []
    for group in by_id.values():
        group.sort(key=lambda v: v.at)
        cur = [group[0]]
        for v in group[1:]:
            if v.at - cur[-1].at <= SESSION_GAP:
                cur.append(v)
            else:
                sessions.append(_close(cur))
                cur = [v]
        sessions.append(_close(cur))
    sessions.sort(key=lambda s: (s.start, s.first.identity))
    return sessions


def _close(cur: list[Viewing]) -> Session:
    # Strongest evidence wins inside a session (title page then autoplay).
    best = max(cur, key=lambda v: v.evidence == "watched")
    return Session(best, len(cur), cur[0].at, cur[-1].at)


def to_preferences(sessions: Iterable[Session], privacy_level: str,
                   now_iso: str) -> list[dict]:
    """One ``preferences`` payload per session (CM019 ParsedPreference parity,
    same keys as ingest_bookmarks). The id is stable per service, subject and
    session start, so a re-run, or an overlapping catch-up window, upserts in
    place instead of duplicating, and a rewatch adds a point (evidence)."""
    out = []
    for s in sessions:
        v = s.first
        strength = _STRENGTH[(v.evidence, v.category)]
        key = unicodedata.normalize("NFC", v.subject).casefold()
        pid = str(uuid.uuid5(
            uuid.NAMESPACE_URL,
            f"streaming|{v.service}|{v.category}|{key}|{s.start.astimezone(timezone.utc).isoformat()}",
        ))
        extra = {
            "service": v.service, "kind": v.kind, "title": v.title,
            "evidence": v.evidence, "url": v.url, "visits_in_session": s.visits,
            "source_type": SOURCE,
        }
        for name in ("channel", "artist", "series"):
            if getattr(v, name):
                extra[name] = getattr(v, name)
        iso = s.start.astimezone(timezone.utc).isoformat()
        out.append({
            "point_id": pid,
            "doc": " ".join(("Like", v.subject, f"category:{v.category}", v.service)),
            "payload": {
                "preference_id": pid,
                "subject": v.subject,
                "preference_type": "Like",
                "category": v.category,
                "strength": strength,
                "source": SOURCE,
                "context": v.service,
                "size": "Medium",
                "compartment_level": privacy_level,
                "privacy_level": privacy_level,
                "created_at": iso,
                "observed_at": iso,
                "extra": extra,
            },
        })
    return out
