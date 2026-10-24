"""Streaming / listening taste from browser history, against the VENDORED copy.

Ported from HR015 ostler_fda/tests/test_streaming_history.py (same cases, same
synthetic cast) so the bytes that ship are the bytes that were proven. The
last section is CM051-only consumer-side proof: the payloads this writes are
accepted by the REAL vendored project_preferences.to_triples and ranked by the
REAL vendored interest_profile.compile_profile, and the browser catch-up
adapter calls the writer.

Red before this change: vendor/ostler_fda has no streaming_history.py and
pwg_ingest has no ingest_streaming, so every test errors at import.
"""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path
from datetime import datetime, timedelta, timezone

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "vendor" / "cm059_editor"))
sys.path.insert(0, str(ROOT / "lib"))

from ostler_fda import pwg_ingest
from ostler_fda import streaming_history as sh

T0 = datetime(2026, 3, 1, 20, 0, tzinfo=timezone.utc)
UUID_A = "11111111-2222-3333-4444-555555555555"
UUID_B = "66666666-7777-8888-9999-000000000000"


def visit(url, title, minutes=0, **extra):
    host = url.split("/")[2]
    d = {
        "type": "web_visit",
        "timestamp": (T0 + timedelta(minutes=minutes)).isoformat(),
        "url": url, "domain": host, "title": title,
        "visit_count": 1, "source": "safari_history",
    }
    d.update(extra)
    return d


# (url, page title) -> (service, category, kind, subject, evidence)
POSITIVES = [
    ("https://www.netflix.com/watch/70000001", "Watch Example show S2:E4 | Netflix",
     ("netflix", "movie_tv", "episode", "Example show", "watched")),
    ("https://www.primevideo.com/detail/B0EXAMPLE01/ref=atv_dp?autoplay=1&utm_source=mail",
     "Prime Video: Example drama",
     ("prime_video", "movie_tv", "film", "Example drama", "watched")),
    (f"https://play.max.com/video/watch/{UUID_A}/{UUID_B}", "Watch Example saga | Max",
     ("max", "movie_tv", "film", "Example saga", "watched")),
    (f"https://www.disneyplus.com/en-gb/play/{UUID_A}", "Watch Example adventure | Disney+",
     ("disney_plus", "movie_tv", "film", "Example adventure", "watched")),
    ("https://tv.apple.com/gb/movie/example-thriller/umc.cmc.def456uvw?playableId=tvs.sbd.1",
     "Example thriller - Apple TV+",
     ("apple_tv_plus", "movie_tv", "film", "Example thriller", "watched")),
    ("https://www.amazon.co.uk/gp/video/detail/B0EXAMPLE02/?autoplay=1&t=0",
     "Amazon.co.uk: Watch Example comedy | Prime Video",
     ("prime_video", "movie_tv", "film", "Example comedy", "watched")),
    ("https://www.primevideo.com/region/eu/detail/B0EXAMPLE04/ref=atv_dp?autoplay=1",
     "Prime Video: Example drama S1:E2",
     ("prime_video", "movie_tv", "episode", "Example drama", "watched")),
    ("https://tv.apple.com/gb/episode/example-pilot/umc.cmc.ghi789rst?playableId=tvs.sbd.2",
     "Example pilot - Apple TV+",
     ("apple_tv_plus", "movie_tv", "episode", "Example pilot", "watched")),
    ("https://www.youtube.com/watch?v=aaaaaaaaaaa&si=TRACK&utm_source=x",
     "(3) How to descale an example kettle - YouTube",
     ("youtube", "video", "video", "How to descale an example kettle", "watched")),
    ("https://www.youtube.com/watch?v=bbbbbbbbbbb",
     "Sample artist - Sample song (Official Music Video) - YouTube",
     ("youtube", "music", "music_video", "Sample artist", "watched")),
    ("https://music.youtube.com/watch?v=ccccccccccc",
     "Another Song • Other artist - YouTube Music",
     ("youtube_music", "music", "track", "Other artist", "watched")),
    ("https://youtu.be/ddddddddddd?t=42", "A short example talk - YouTube",
     ("youtube", "video", "video", "A short example talk", "watched")),
    ("https://www.youtube.com/shorts/eeeeeeeeeee", "Quick example trick - YouTube",
     ("youtube", "video", "video", "Quick example trick", "watched")),
]

# Pages that must NEVER become a title, however their page title reads.
NEGATIVES = [
    ("https://www.youtube.com/", "YouTube"),
    ("https://www.youtube.com/results?search_query=example+kettle", "example kettle - YouTube"),
    ("https://www.youtube.com/feed/subscriptions", "Subscriptions - YouTube"),
    ("https://www.youtube.com/@examplechannel", "Example channel - YouTube"),
    ("https://www.youtube.com/channel/UCexample0000000000000", "Example channel - YouTube"),
    ("https://www.youtube.com/playlist?list=PLexample", "Example mix - YouTube"),
    ("https://www.youtube.com/hashtag/example", "#example - YouTube"),
    ("https://music.youtube.com/", "YouTube Music"),
    ("https://www.netflix.com/browse", "Netflix"),
    ("https://www.netflix.com/browse?jbv=70000001", "Example show - Netflix"),
    ("https://www.netflix.com/search?q=example", "Netflix"),
    ("https://www.netflix.com/browse/my-list", "My List - Netflix"),
    ("https://www.netflix.com/watch/70000009", "Netflix"),  # title unreadable: dropped, not guessed
    ("https://www.primevideo.com/storefront/home", "Prime Video"),
    ("https://www.primevideo.com/search/ref=atv_nb_sr?phrase=example", "Prime Video: Search"),
    ("https://www.amazon.co.uk/dp/B0EXAMPLE03", "Amazon.co.uk: Example kettle"),
    ("https://www.max.com/", "Max: Stream HBO, TV Series, and Movies"),
    ("https://www.max.com/search?q=example", "Search | Max"),
    ("https://www.disneyplus.com/home", "Home | Disney+"),
    ("https://www.disneyplus.com/browse/entity-" + UUID_A, "Disney+"),
    ("https://tv.apple.com/gb", "Apple TV"),
    ("https://tv.apple.com/gb/room/example-room/edt.item.123", "Example room - Apple TV"),
    # DETAIL pages: the owner is browsing the catalogue, not watching.
    ("https://www.netflix.com/title/70000002", "Example film | Netflix"),
    ("https://www.netflix.com/gb/title/70000002?trackId=1", "Example film | Netflix"),
    ("https://www.primevideo.com/detail/B0EXAMPLE01/ref=atv_dp", "Prime Video: Example drama"),
    ("https://www.primevideo.com/detail/B0EXAMPLE01/ref=atv_dp?autoplay=0", "Prime Video: Example drama"),
    ("https://www.amazon.co.uk/gp/video/detail/B0EXAMPLE02/", "Amazon.co.uk: Watch Example comedy | Prime Video"),
    (f"https://www.max.com/shows/example-series/{UUID_A}", "Example series | Max"),
    (f"https://www.max.com/movies/example-movie/{UUID_A}", "Example movie | Max"),
    (f"https://www.disneyplus.com/movies/example-adventure/abc123XYZ", "Example adventure | Disney+"),
    (f"https://www.disneyplus.com/en-gb/series/example-saga/abc123XYZ", "Example saga | Disney+"),
    ("https://tv.apple.com/gb/show/example-mystery/umc.cmc.abc123xyz", "Example mystery - Apple TV+"),
    ("https://tv.apple.com/gb/movie/example-thriller/umc.cmc.def456uvw", "Example thriller - Apple TV+"),
    ("https://tv.apple.com/gb/episode/example-pilot/umc.cmc.ghi789rst", "Example pilot - Apple TV+"),
    ("https://example.com/watch?v=aaaaaaaaaaa", "Not A Service - YouTube"),
    ("https://notyoutube.com/watch?v=aaaaaaaaaaa", "Lookalike host - YouTube"),
]


@pytest.mark.parametrize("url,title,want", POSITIVES)
def test_each_service_shape_is_recognised(url, title, want):
    v = sh.recognise(visit(url, title))
    assert v is not None, f"not recognised: {url}"
    assert (v.service, v.category, v.kind, v.subject, v.evidence) == want


@pytest.mark.parametrize("url,title", NEGATIVES)
def test_listing_search_browse_and_channel_pages_are_not_titles(url, title):
    assert sh.recognise(visit(url, title)) is None


def test_negative_controls_would_pass_if_the_page_title_alone_decided():
    """CONTROL: the predicate under test is the URL shape. These titles are
    ordinary, readable strings, so a recogniser that trusted the title would
    accept them. If this fails the negatives above prove nothing."""
    readable = [t for u, t in NEGATIVES if t not in ("YouTube", "Netflix", "Prime Video", "Apple TV", "YouTube Music", "Disney+")]
    assert len(readable) >= 10 and all(sh._clean(t) and not sh._is_generic(t) for t in readable)


def test_seen_denominator_counts_every_visit():
    visits = [visit(u, t) for u, t, _ in POSITIVES] + [visit(u, t) for u, t in NEGATIVES]
    got, counts = sh.extract_viewings(visits)
    assert counts == {"seen": len(visits), "recognised": len(POSITIVES), "not_a_title": len(NEGATIVES)}
    assert len(got) == len(POSITIVES)


def test_session_dedupe_collapses_seeks_and_reloads_but_counts_a_rewatch():
    u = "https://www.youtube.com/watch?v=aaaaaaaaaaa"
    t = "A repeatable example - YouTube"
    visits = [
        visit(u, t, 0), visit(u + "&t=120s", t, 5), visit(u + "&t=900s", t, 28),
        visit(u, t, 24 * 60),   # next day: a rewatch
    ]
    got, _ = sh.extract_viewings(visits)
    sessions = sh.sessionise(got)
    assert [s.visits for s in sessions] == [3, 1]
    prefs = sh.to_preferences(sessions, "L2", "2026-03-02T00:00:00+00:00")
    assert len(prefs) == 2 and len({p["point_id"] for p in prefs}) == 2


def test_two_titles_in_the_same_window_stay_two_sessions():
    got, _ = sh.extract_viewings([
        visit("https://www.youtube.com/watch?v=aaaaaaaaaaa", "One - YouTube", 0),
        visit("https://www.youtube.com/watch?v=bbbbbbbbbbb", "Two - YouTube", 1),
    ])
    assert len(sh.sessionise(got)) == 2


def test_stored_url_keeps_v_and_list_and_drops_everything_else():
    got, _ = sh.extract_viewings([visit(
        "https://www.youtube.com/watch?v=aaaaaaaaaaa&list=PLexample&index=3"
        "&utm_source=newsletter&si=TRACK&fbclid=Z", "Example - YouTube")])
    assert got[0].url == "https://www.youtube.com/watch?v=aaaaaaaaaaa&list=PLexample"
    nf = sh.recognise(visit("https://www.netflix.com/watch/70000002?trackId=1&utm_medium=x", "Example film | Netflix"))
    assert nf.url == "https://www.netflix.com/watch/70000002"


def test_no_watch_time_is_ever_emitted():
    got, _ = sh.extract_viewings([visit(u, t) for u, t, _ in POSITIVES])
    blob = json.dumps(sh.to_preferences(sh.sessionise(got), "L2", "2026-03-02T00:00:00+00:00")).lower()
    for word in ("watch_time", "watchtime", "duration", "minutes", "seconds", "runtime"):
        assert word not in blob


def test_private_flagged_visit_is_dropped():
    u, t = "https://www.netflix.com/watch/70000002", "Example film | Netflix"
    assert sh.recognise(visit(u, t)) is not None
    for flag in ("private", "incognito", "is_private", "private_browsing"):
        assert sh.recognise(visit(u, t, **{flag: True})) is None


def test_unparseable_time_is_dropped_not_invented():
    v = visit("https://www.netflix.com/watch/70000002", "Example film | Netflix")
    v["timestamp"] = "yesterday-ish"
    assert sh.recognise(v) is None


def test_payload_matches_the_preferences_contract_and_music_videos_feed_music():
    got, _ = sh.extract_viewings([visit(u, t) for u, t, _ in POSITIVES])
    prefs = sh.to_preferences(sh.sessionise(got), "L2", "2026-03-02T00:00:00+00:00")
    by_cat = {}
    for p in prefs:
        pl = p["payload"]
        for key in ("preference_id", "subject", "preference_type", "category", "strength",
                    "source", "privacy_level", "compartment_level", "observed_at", "created_at"):
            assert pl.get(key) not in (None, ""), key
        assert pl["preference_type"] == "Like" and pl["source"] == "streaming_history"
        assert pl["privacy_level"] == "L2" == pl["compartment_level"]
        assert 0 < pl["strength"] <= 1
        by_cat.setdefault(pl["category"], []).append(pl["subject"])
    assert "Sample artist" in by_cat["music"] and "Other artist" in by_cat["music"]
    assert "Example show" in by_cat["movie_tv"]
    # film/TV playback outweighs a generic video
    st = {p["payload"]["subject"]: p["payload"]["strength"] for p in prefs}
    assert st["Example show"] > st["How to descale an example kettle"]


def test_ids_are_stable_across_runs():
    vs = [visit(u, t) for u, t, _ in POSITIVES]
    ids = lambda: sorted(p["point_id"] for p in sh.to_preferences(  # noqa: E731
        sh.sessionise(sh.extract_viewings(vs)[0]), "L2", "x"))
    assert ids() == ids()


# ── through the real writer ────────────────────────────────────────


@pytest.fixture
def sink(monkeypatch):
    seen = {"points": [], "ensure": []}
    monkeypatch.setattr(pwg_ingest, "_ollama_embed_batch", lambda texts: [[0.1, 0.2, 0.3] for _ in texts])
    monkeypatch.setattr(pwg_ingest, "_qdrant_ensure_collection",
                        lambda c, n, *a, **k: seen["ensure"].append((c, n)))

    def upsert(collection, points):
        seen["points"].extend(points)
        seen["collection"] = collection
        return len(points)

    monkeypatch.setattr(pwg_ingest, "_qdrant_upsert_points", upsert)
    return seen


def _write(tmp_path, visits, name="safari_history.json"):
    (tmp_path / name).write_text(json.dumps(visits))
    return tmp_path


def test_ingest_streaming_writes_preferences_and_reports_the_denominator(tmp_path, sink):
    visits = [visit(u, t) for u, t, _ in POSITIVES] + [visit(u, t) for u, t in NEGATIVES]
    res = pwg_ingest.ingest_streaming(_write(tmp_path, visits))
    assert res["status"] == "ok" and res["sent"] == res["total"] == len(POSITIVES)
    assert res["seen"] == len(visits)
    assert sink["collection"] == pwg_ingest.PREFERENCES_QDRANT_COLLECTION == "preferences"
    assert {p["payload"]["source"] for p in sink["points"]} == {"streaming_history"}


def test_ingest_streaming_reads_chrome_too_and_drops_sensitive_domains(tmp_path, sink):
    chrome = visit("https://www.netflix.com/watch/70000002", "Example film | Netflix", source="chrome_history")
    bank = visit("https://www.netflix.com.accounts.google.com/watch/70000002", "Example film | Netflix")
    _write(tmp_path, [chrome, bank], "chrome_history.json")
    res = pwg_ingest.ingest_streaming(tmp_path)
    assert res["sent"] == 1 and res["skipped_sensitive"] == 1


def test_nothing_recognised_is_no_data_with_a_nonzero_seen(tmp_path, sink):
    res = pwg_ingest.ingest_streaming(_write(tmp_path, [visit(u, t) for u, t in NEGATIVES]))
    assert res["status"] == "no_data" and res["sent"] == 0 and res["seen"] == len(NEGATIVES)
    assert sink["points"] == []


def test_a_missing_file_is_no_data_with_seen_zero(tmp_path, sink):
    res = pwg_ingest.ingest_streaming(tmp_path)
    assert res["status"] == "no_data" and res["seen"] == 0


def test_a_dead_store_is_an_outage_not_ok(tmp_path, monkeypatch, sink):
    monkeypatch.setattr(pwg_ingest, "_qdrant_upsert_points", lambda c, p: 0)
    res = pwg_ingest.ingest_streaming(_write(tmp_path, [visit(*POSITIVES[0][:2])]))
    assert res["status"] == "error" and res["sink_unavailable"] is True and res["sent"] == 0


def test_it_is_a_dispatch_entry_so_it_cannot_ship_dark():
    assert ("streaming", "ingest_streaming") in pwg_ingest._INGEST_DISPATCH


# ── CM051-only: the consumers, as vendored ─────────────────────────


def _written(tmp_path, sink):
    visits = [visit(u, t) for u, t, _ in POSITIVES] + [visit(u, t) for u, t in NEGATIVES]
    pwg_ingest.ingest_streaming(_write(tmp_path, visits))
    return [p["payload"] for p in sink["points"]]


def test_the_projector_accepts_every_written_point(tmp_path, sink):
    from compiler import project_preferences as pp
    pts = [{"payload": pl} for pl in _written(tmp_path, sink)]
    lines, skipped = pp.to_triples(pts)
    assert pts and skipped == 0
    assert sum(1 for ln in lines if ln.endswith("#LikePreference> .")) == len(pts)


def test_interest_profile_ranks_them_into_film_tv_and_music(tmp_path, sink):
    from compiler import interest_profile as ip
    raws = [{"subject": pl["subject"], "category": pl["category"], "strength": str(pl["strength"]),
             "source": pl["source"], "observed_at": pl["observed_at"],
             "created_at": pl["created_at"], "polarity": "like"}
            for pl in _written(tmp_path, sink)]
    prof = ip.compile_profile(raws, now=datetime(2026, 3, 3, tzinfo=timezone.utc))
    seen = {i["subject"]: b["domain"] for b in prof["domains"] for i in b["interests"]}
    assert seen["Example show"] == "Film & TV"
    assert seen["Sample artist"] == "Music" and seen["Other artist"] == "Music"
    # nothing from a negative-control page reached the profile
    assert not any("Search" in s or s in ("Netflix", "YouTube", "Home") for s in seen)
    assert prof["stats"]["suppressed_identifier"] == 0


def test_the_browser_catchup_adapter_calls_the_streaming_writer(tmp_path, sink, monkeypatch):
    from ostler_fda import catchup_browser
    mac_epoch = 978307200
    db = tmp_path / "History.db"
    con = sqlite3.connect(db)
    con.executescript(
        "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);"
        "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER,"
        " visit_time REAL, title TEXT, redirect_source INTEGER);")
    when = datetime(2020, 5, 1, 19, 0, tzinfo=timezone.utc).timestamp()
    con.execute("INSERT INTO history_items VALUES (1, 'https://music.youtube.com/watch?v=ccccccccccc', 1)")
    con.execute("INSERT INTO history_visits VALUES (1, 1, ?, 'Old Song \u2022 Old Artist - YouTube Music', NULL)",
                (when - mac_epoch,))
    con.commit()
    con.close()
    ad = catchup_browser.SafariAdapter(db_path=db, now=when + 86400)
    assert ad.process((int(when) - 3600, int(when) + 3600)) is True
    subjects = {p["payload"]["subject"] for p in sink["points"]
                if p["payload"]["source"] == "streaming_history"}
    assert subjects == {"Old Artist"}


def test_a_streaming_outage_retries_the_catchup_window(tmp_path, sink, monkeypatch):
    from ostler_fda import catchup_browser
    monkeypatch.setattr(pwg_ingest, "ingest_streaming", lambda d: {"status": "error", "sink_unavailable": True})
    db = tmp_path / "History.db"
    con = sqlite3.connect(db)
    con.executescript(
        "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);"
        "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER,"
        " visit_time REAL, title TEXT, redirect_source INTEGER);")
    when = datetime(2020, 5, 1, 19, 0, tzinfo=timezone.utc).timestamp()
    con.execute("INSERT INTO history_items VALUES (1, 'https://example.com/a', 1)")
    con.execute("INSERT INTO history_visits VALUES (1, 1, ?, 'A page', NULL)", (when - 978307200,))
    con.commit()
    con.close()
    ad = catchup_browser.SafariAdapter(db_path=db, now=when + 86400)
    with pytest.raises(ConnectionError):
        ad.process((int(when) - 3600, int(when) + 3600))


# ── detail vs playback, and season/episode wording (review MEDIUMs) ──

# (detail URL, playback URL, title): the pair differs ONLY by the playback
# marker, so a pass on the detail side cannot come from a bad title or host.
DETAIL_PLAYBACK_PAIRS = [
    ("https://www.netflix.com/title/70000002", "https://www.netflix.com/watch/70000002",
     "Example film | Netflix"),
    ("https://www.primevideo.com/detail/B0EXAMPLE01/", "https://www.primevideo.com/detail/B0EXAMPLE01/?autoplay=1",
     "Prime Video: Example drama"),
    ("https://www.amazon.co.uk/gp/video/detail/B0EXAMPLE02/", "https://www.amazon.co.uk/gp/video/detail/B0EXAMPLE02/?autoplay=1",
     "Amazon.co.uk: Watch Example comedy | Prime Video"),
    (f"https://www.max.com/shows/example-series/{UUID_A}", f"https://play.max.com/video/watch/{UUID_A}/{UUID_B}",
     "Example series | Max"),
    (f"https://www.max.com/movies/example-movie/{UUID_A}", f"https://play.max.com/video/watch/{UUID_A}",
     "Example movie | Max"),
    ("https://www.disneyplus.com/movies/example-adventure/abc123XYZ", f"https://www.disneyplus.com/play/{UUID_A}",
     "Example adventure | Disney+"),
    ("https://www.disneyplus.com/series/example-saga/abc123XYZ", f"https://www.disneyplus.com/video/{UUID_A}",
     "Example saga | Disney+"),
    ("https://tv.apple.com/gb/show/example-mystery/umc.cmc.abc123xyz",
     "https://tv.apple.com/gb/show/example-mystery/umc.cmc.abc123xyz?playableId=tvs.sbd.1",
     "Example mystery - Apple TV+"),
    ("https://tv.apple.com/gb/episode/example-pilot/umc.cmc.ghi789rst",
     "https://tv.apple.com/gb/episode/example-pilot/umc.cmc.ghi789rst?playableId=tvs.sbd.2",
     "Example pilot - Apple TV+"),
]


@pytest.mark.parametrize("detail,playback,title", DETAIL_PLAYBACK_PAIRS)
def test_detail_page_is_not_a_viewing_but_its_playback_is(detail, playback, title):
    assert sh.recognise(visit(detail, title)) is None
    v = sh.recognise(visit(playback, title))
    assert v is not None and v.evidence == "watched"


def test_no_film_tv_viewing_is_ever_emitted_as_merely_viewed():
    got, _ = sh.extract_viewings([visit(u, t) for u, t, _ in POSITIVES])
    assert got and {v.evidence for v in got} == {"watched"}


# (page title, series, ...): wording each service uses per UI language.
EPISODE_TITLES = [
    ("Example show: Staffel 1, Folge 2 | Netflix", "Example show"),          # de
    ("Example show - Saison 1, épisode 2 | Netflix", "Example show"),     # fr
    ("Example show: Saison 1 : Épisode 2", "Example show"),               # fr, spaced colon
    ("Example show - Temporada 1, episodio 2 | Netflix", "Example show"),    # es
    ("Example show - Stagione 1, episodio 2 | Netflix", "Example show"),     # it
    ("Example show - Temporada 1, episódio 2 | Netflix", "Example show"),  # pt
    ("Example show - Seizoen 1, aflevering 2 | Netflix", "Example show"),    # nl
    ("Example show Season 1, Episode 2 | Netflix", "Example show"),          # en
    ("Example show S1:E2 | Netflix", "Example show"),
    ("Example show S01E02 | Netflix", "Example show"),
    ("Example show - S01 E02 | Netflix", "Example show"),
]


@pytest.mark.parametrize("title,series", EPISODE_TITLES)
def test_episode_wording_is_recognised_in_every_supported_language(title, series):
    v = sh.recognise(visit("https://www.netflix.com/watch/70000001", title))
    assert v is not None
    assert (v.kind, v.series, v.subject) == ("episode", series, series)


@pytest.mark.parametrize("title", [
    "Example film | Netflix",
    "Example film 2 | Netflix",                 # a sequel number is not an episode
    "Saison finale party | Netflix",           # season word without numbers
    "Folge deinem Herzen | Netflix",           # "Folge" is an ordinary German word
])
def test_ordinary_titles_are_not_split_into_series_and_episode(title):
    v = sh.recognise(visit("https://www.netflix.com/watch/70000001", title))
    assert v is not None and v.kind == "film" and v.series is None


def test_non_english_episode_wording_collapses_to_one_series_subject():
    got, _ = sh.extract_viewings([
        visit("https://www.netflix.com/watch/70000001", "Example show - Staffel 1, Folge 2 | Netflix", 0),
        visit("https://www.netflix.com/watch/70000003", "Example show - Saison 2, épisode 5 | Netflix", 60),
    ])
    prefs = sh.to_preferences(sh.sessionise(got), "L2", "2026-03-02T00:00:00+00:00")
    assert {p["payload"]["subject"] for p in prefs} == {"Example show"}
