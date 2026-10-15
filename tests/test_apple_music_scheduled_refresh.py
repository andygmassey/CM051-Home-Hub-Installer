#!/usr/bin/env python3
"""The scheduled Apple Music refresh: schedule, fail-open, idempotent, deltas.
(CM051 v1.0.108, Andy 2026-10-15: "please don't let that slip")

THE DEFECT. Apple Music refreshed at INSTALL ONLY: the background FDA re-run
is a launchd job and cannot hold the "Media & Apple Music" grant. The fix is
two LaunchAgents (vendor/ostler_fda/apple_music_refresh.py plus the app-side
gui/OstlerInstaller/Auth/MusicRefreshMode.swift). This drives the shipped
Python on synthetic data only (no real listening history), and reads the
shipped Swift/shell as text for the wiring that cannot run off a Mac.

WHAT IS NOT PROVEN HERE, and is registered in console_only_probes.tsv: that
macOS attributes the launchd-run app's helper child to the app and answers
from the existing grant. See docs/APPLE_MUSIC_REFRESH_TCC.md (INFERRED).
"""
from __future__ import annotations

import asyncio
import copy
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))

from ostler_fda import apple_music  # noqa: E402
from ostler_fda import apple_music_refresh as r  # noqa: E402

TRACKS = [
    {"id": "A1", "title": "fixture-song-one", "artist": "fixture-band", "album": "fixture-album",
     "genre": "Ambient", "play_count": 42, "skip_count": 1, "rating": 100, "loved": True,
     "last_played": "2026-10-01T08:00:00Z", "added": "2024-01-01T00:00:00Z", "kind": "song"},
    {"id": "A2", "title": "fixture-song-two", "artist": "fixture-band", "album": "fixture-album",
     "genre": "Ambient", "play_count": 3, "skip_count": 0, "rating": 0,
     "last_played": "2025-06-01T08:00:00Z", "added": "2024-01-01T00:00:00Z", "kind": "song"},
    {"id": "A3", "title": "sample-tune-three", "artist": "sample-ensemble", "genre": "Jazz",
     "play_count": 0, "skip_count": 0, "rating": 20, "disliked": True,
     "added": "2023-05-05T00:00:00Z", "kind": "song"},
]
PLAYLISTS = [{"name": "fixture-mix", "smart": False, "track_ids": ["A2"]}]
DENIED = {"schema": 1, "status": "unavailable", "detail": "itlibrary_init_failed",
          "error_domain": "NSCocoaErrorDomain", "error_code": 4097}


def payload(tracks=None, playlists=None) -> dict:
    return {"schema": 1, "status": "ok", "api_version": "1.1",
            "tracks": copy.deepcopy(TRACKS if tracks is None else tracks),
            "playlists": copy.deepcopy(PLAYLISTS if playlists is None else playlists)}


class Box:
    """A synthetic ~/.ostler plus a recording stand-in for the CM019 ingest."""

    def __init__(self, tmp: Path):
        self.dir = tmp / "ostler"
        self.dir.mkdir()
        self.sdir = r.state_dir(self.dir)
        self.sdir.mkdir(parents=True)
        (self.sdir / r.ARMED_NAME).write_text("x\n")
        self.ingests = []      # (rows seen in the delta file) per call
        self.ok = True

    def helper_said(self, obj) -> None:
        (self.sdir / r.HELPER_OUT_NAME).write_text(obj if isinstance(obj, str) else json.dumps(obj))

    def ingest(self, directory, ostler_dir, user):
        data = json.loads((Path(directory) / apple_music.PREFERENCE_EXPORT_NAME).read_text())
        self.ingests.append(sorted(t["id"] for t in data["tracks"]))
        return self.ok

    def run(self):
        return r.apply(self.dir, ingest=self.ingest)


@pytest.fixture
def box(tmp_path):
    return Box(tmp_path)


# ── 1. SCHEDULING ──────────────────────────────────────────────────────────

APP = "/Applications/OstlerInstaller.app/Contents/MacOS/OstlerInstaller"


def test_run_agent_is_daily_and_at_login_in_the_gui_session_only():
    p = r.render_run_plist(APP, "/logs")
    assert p["Label"] == "com.ostler.music-refresh"
    assert p["RunAtLoad"] is True                       # at login
    assert p["LimitLoadToSessionType"] == "Aqua"        # the grant applies in the GUI session
    cal = p["StartCalendarInterval"]
    assert set(cal) == {"Hour", "Minute"}               # recurring; a dated entry is a one-shot (#714)
    assert (cal["Hour"], cal["Minute"]) == (r.DEFAULT_HOUR, r.DEFAULT_MINUTE)
    assert "StartInterval" not in p and "KeepAlive" not in p


def test_run_agent_program_is_the_app_with_exactly_one_fixed_flag():
    p = r.render_run_plist(APP, "/logs")
    assert p["ProgramArguments"] == [APP, "--music-refresh"]
    # The bare helper must NOT be the launchd program: it would be its own
    # TCC client and hold no grant.
    assert "ostler-music-library" not in json.dumps(p)


def test_apply_agent_fires_on_the_file_the_app_writes(tmp_path):
    p = r.render_apply_plist("/py/python3", "/fda", str(tmp_path / "o"), "/logs", "fixture")
    assert p["WatchPaths"] == [str(r.state_dir(tmp_path / "o") / r.HELPER_OUT_NAME)]
    assert p["ProgramArguments"][1:] == ["-m", "ostler_fda.apple_music_refresh", "apply"]
    assert p["EnvironmentVariables"]["OSTLER_USER"] == "fixture"
    assert p["ThrottleInterval"] >= 30


@pytest.mark.parametrize("hour,minute", [(24, 0), (-1, 0), (3, 60)])
def test_a_bad_time_is_refused_not_scheduled(hour, minute):
    with pytest.raises(ValueError):
        r.render_run_plist(APP, "/logs", hour, minute)


@pytest.mark.skipif(shutil.which("plutil") is None, reason="plutil is macOS only")
def test_both_plists_are_valid_to_plutil(tmp_path):
    for name, d in (("a", r.render_run_plist(APP, "/logs")),
                    ("b", r.render_apply_plist("/py", "/fda", "/o", "/logs", "u"))):
        f = tmp_path / f"{name}.plist"
        r.write_plist_if_changed(f, d)
        out = subprocess.run(["plutil", "-lint", str(f)], capture_output=True, text=True)
        assert out.returncode == 0, out.stdout + out.stderr


def test_install_agents_cli_writes_both_and_is_idempotent(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "o"))
    agents = tmp_path / "LaunchAgents"
    argv = ["install-agents", "--app-executable", APP, "--python", "/py/python3",
            "--fda-parent", "/fda", "--agents-dir", str(agents), "--user", "fixture"]
    assert r.main(argv) == 0
    assert "run_changed=1 apply_changed=1" in capsys.readouterr().out
    run = plistlib.loads((agents / "com.ostler.music-refresh.plist").read_bytes())
    assert run["ProgramArguments"] == [APP, "--music-refresh"]
    assert (agents / "com.ostler.music-refresh-apply.plist").is_file()
    assert r.main(argv) == 0
    assert "run_changed=0 apply_changed=0" in capsys.readouterr().out


# ── 2. THE ARMING GATE: never the background's job to raise a dialog ───────

def _export(tmp_path, reader, tracks=True):
    f = tmp_path / "exp.json"
    f.write_text(json.dumps({"schema": 1, "source": "apple_music_library", "reader": reader,
                             "tracks": [{"id": "A1"}] if tracks else []}))
    return f


def _summary(reader="native", tracks=3, status="ok"):
    return {"sources": {"apple_music": {"status": status, "reader": reader,
                                        "total_tracks": tracks}}}


def test_install_arms_only_after_a_native_read_succeeded(tmp_path):
    for n, (reader, tracks, want) in enumerate([("native", True, True), ("xml", True, False),
                                                ("native", False, False), ("none", False, False)]):
        o = tmp_path / f"o{n}"
        assert r.arm(o, _export(tmp_path, reader, tracks), _summary(reader, 3 if tracks else 0)) is want, (reader, tracks)
        assert r.is_armed(o) is want
    assert r.arm(tmp_path / "o9", tmp_path / "missing.json", _summary()) is False
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    assert r.arm(tmp_path / "o9", bad, _summary()) is False


@pytest.mark.parametrize("summary", [
    None,                                       # no proof offered at all
    _summary("previous_export", 3),             # refused read: old export kept
    _summary("native", 0),                      # 0-track read
    _summary("native", 3, status="no_fda"),     # source did not run
    {"sources": {}},
])
def test_a_stale_native_export_on_disk_does_not_arm_without_this_runs_proof(tmp_path, summary):
    """Review item (a). extract_all keeps the previous export (reader native)
    after a refused or empty read; only THIS run's summary tells the truth."""
    o = tmp_path / "o"
    stale = _export(tmp_path, "native", True)
    assert r.arm(o, stale, summary) is False
    assert r.is_armed(o) is False
    assert r.arm(o, stale, _summary("native", 3)) is True      # control: same file, real proof


def test_parse_run_summary_takes_the_last_json_line_of_the_fda_output():
    out = '[ok] Apple Music: 3 tracks\n' + json.dumps(_summary()) + "\n"
    assert r.parse_run_summary(out) == _summary()
    assert r.parse_run_summary("[skip] nothing\n") is None


def test_the_agent_is_only_installed_against_a_stable_app_path(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "o"))
    agents = tmp_path / "LA"
    for bad in ("/Volumes/Ostler/OstlerInstaller.app/Contents/MacOS/OstlerInstaller",
                "/private/tmp/x/OstlerInstaller.app/Contents/MacOS/OstlerInstaller"):
        assert r.main(["install-agents", "--app-executable", bad, "--python", "/py",
                       "--fda-parent", "/f", "--agents-dir", str(agents)]) == 0
        assert not agents.exists()
    assert r.stable_app_executable(APP)


def test_each_refresh_is_recorded_in_source_activity_for_the_doctor(box):
    box.helper_said(DENIED)
    box.run()
    f = box.dir / "state" / "source_activity" / "apple_music.tsv"
    t = f.read_text()
    assert "source=apple_music" in t and "last_status=skipped" in t and "last_success_at=\n" in t
    box.helper_said(payload())
    box.run()
    t = f.read_text()
    assert "last_status=ok" in t and "last_success_at=20" in t
    box.helper_said(DENIED)
    box.run()
    t2 = f.read_text()
    assert "last_status=skipped" in t2
    assert [l for l in t.splitlines() if l.startswith("last_success_at")] == \
           [l for l in t2.splitlines() if l.startswith("last_success_at")], "success carried forward"


def test_uninstaller_names_both_agents_in_its_teardown():
    body = INSTALL[INSTALL.index("OSTLER_LAUNCHAGENT_LABELS=("):]
    body = body[:body.index(")")]
    assert "com.ostler.music-refresh\n" in body and "com.ostler.music-refresh-apply\n" in body


# ── 3. FAIL-OPEN ───────────────────────────────────────────────────────────

def test_no_answer_file_is_a_quiet_no_op(box):
    assert box.run() == {"outcome": "nothing_to_do"}
    assert box.ingests == []


@pytest.mark.parametrize("label,body", [
    ("permission refused", DENIED),
    ("empty library", {"schema": 1, "status": "empty"}),
    ("garbage", "Segmentation fault"),
    ("empty file", ""),
    ("wrong schema", {"schema": 99, "status": "ok"}),
    ("ok with zero songs", {"schema": 1, "status": "ok", "tracks": []}),
])
def test_every_refusal_is_could_not_look_and_changes_nothing(box, caplog, label, body):
    box.helper_said(body)
    caplog.set_level("INFO")
    res = box.run()
    assert res["outcome"] == "could_not_look", label
    assert box.ingests == [], label
    assert "could not look" in caplog.text, label
    assert not (box.dir / r.DELTA_DIR_REL).exists(), label
    assert r.load_state(box.dir)["snapshot"] == {}, label
    assert not (box.sdir / r.HELPER_OUT_NAME).exists(), "answer file must be consumed"


def test_a_refusal_never_erases_what_an_earlier_run_stored(box):
    box.helper_said(payload())
    assert box.run()["outcome"] == "stored"
    snap = r.load_state(box.dir)["snapshot"]
    box.helper_said(DENIED)
    assert box.run()["outcome"] == "could_not_look"
    assert r.load_state(box.dir)["snapshot"] == snap


def test_three_refusals_in_a_row_disarm_and_a_success_resets_the_count(box):
    for _ in range(2):
        box.helper_said(DENIED)
        assert box.run()["armed"] is True
    box.helper_said(payload())
    box.run()
    assert r.load_state(box.dir)["refusals"] == 0
    for n in range(r.DISARM_AFTER):
        box.helper_said(DENIED)
        res = box.run()
    assert res["armed"] is False and not r.is_armed(box.dir)


def test_a_failed_or_raising_ingest_is_could_not_store_and_is_retried_whole(box, caplog):
    box.helper_said(payload())
    box.ok = False
    caplog.set_level("INFO")
    assert box.run()["outcome"] == "could_not_store"
    assert r.load_state(box.dir)["snapshot"] == {}, "snapshot must not advance past a failed store"
    box.ok = True
    box.helper_said(payload())
    res = box.run()
    assert res["outcome"] == "stored" and res["new"] == 3
    assert box.ingests == [["A1", "A2", "A3"], ["A1", "A2", "A3"]]

    def boom(*a, **k):
        raise RuntimeError("fixture failure")
    box.helper_said(payload([dict(TRACKS[0], play_count=43)] + TRACKS[1:]))
    assert r.apply(box.dir, ingest=boom)["outcome"] == "could_not_store"


def test_the_real_ingest_with_no_install_is_could_not_store_not_a_crash(box):
    box.helper_said(payload())
    assert r.apply(box.dir)["outcome"] == "could_not_store"   # no services/cm019 on this box


def test_logs_carry_counts_only_never_a_title(box, caplog):
    caplog.set_level("INFO")
    box.helper_said(payload())
    box.run()
    for needle in ("fixture-song", "fixture-band", "sample-tune", "fixture-mix"):
        assert needle not in caplog.text


# ── 4. IDEMPOTENT RE-READS ─────────────────────────────────────────────────

def test_rereading_an_unchanged_library_stores_nothing(box):
    box.helper_said(payload())
    first = box.run()
    assert first["outcome"] == "stored" and first["changed"] == 3
    for _ in range(3):
        box.helper_said(payload())
        again = box.run()
        assert again["outcome"] == "unchanged" and again["changed"] == 0
    assert len(box.ingests) == 1, "an unchanged library must not reach the store again"
    assert not (box.dir / r.DELTA_DIR_REL / apple_music.PREFERENCE_EXPORT_NAME).exists()


def test_the_snapshot_is_the_same_after_a_repeat(box):
    box.helper_said(payload())
    box.run()
    s1 = (box.sdir / r.STATE_NAME).read_text()
    box.helper_said(payload())
    box.run()
    s2 = json.loads((box.sdir / r.STATE_NAME).read_text())
    assert s2["snapshot"] == json.loads(s1)["snapshot"]


# ── 5. CHANGED-COUNT DELTAS ────────────────────────────────────────────────

def test_only_changed_tracks_are_sent_and_each_change_is_counted(box):
    box.helper_said(payload())
    box.run()
    nxt = copy.deepcopy(TRACKS)
    nxt[0]["play_count"] = 45                              # A1: plays rose
    nxt[1]["last_played"] = "2026-10-14T09:00:00Z"         # A2: recency only
    nxt[2]["rating"] = 80                                  # A3: rating (other)
    nxt.append({"id": "A4", "title": "sample-tune-four", "artist": "sample-ensemble",
                "genre": "Jazz", "play_count": 1, "kind": "song"})   # new
    box.helper_said(payload(nxt))
    res = box.run()
    assert (res["new"], res["plays"], res["recency"], res["other"]) == (1, 1, 1, 1)
    assert res["changed"] == 4 and res["total"] == 4
    assert box.ingests[-1] == ["A1", "A2", "A3", "A4"]

    # One more play on one track: exactly one row goes out.
    nxt[0]["play_count"] = 46
    box.helper_said(payload(nxt))
    res = box.run()
    assert res["changed"] == 1 and res["plays"] == 1 and box.ingests[-1] == ["A1"]


def test_untouched_tracks_never_travel(box):
    box.helper_said(payload())
    box.run()
    nxt = copy.deepcopy(TRACKS)
    nxt[1]["play_count"] += 1
    box.helper_said(payload(nxt))
    box.run()
    assert box.ingests[-1] == ["A2"]


def test_a_track_that_leaves_the_library_is_ignored_and_never_deleted(box):
    box.helper_said(payload())
    box.run()
    box.helper_said(payload(TRACKS[:2]))
    res = box.run()
    assert res["outcome"] == "unchanged"
    assert "A3" in r.load_state(box.dir)["snapshot"], "additive: its record is kept"
    box.helper_said(payload())                    # it comes back, unchanged
    assert box.run()["outcome"] == "unchanged", "a returning track is not re-announced as new"


def test_playlist_membership_change_counts(box):
    box.helper_said(payload())
    box.run()
    box.helper_said(payload(playlists=[{"name": "fixture-mix", "smart": False,
                                        "track_ids": ["A2", "A1"]}]))
    res = box.run()
    assert res["changed"] == 1 and box.ingests[-1] == ["A1"]


# ── 6. END TO END through the real CM019 parser and pipeline ───────────────

class _Q:
    def __init__(self):
        self.points = {}
        self.deletes = 0

    async def initialize(self):
        return True

    async def upsert_vectors(self, vectors, payloads, ids):
        for i, pl in zip(ids, payloads):
            self.points[i] = pl
        return True

    async def delete_by_user(self, *a, **k):
        self.deletes += 1
        return True


class _O:
    async def initialize(self):
        return True

    async def insert_triples(self, ttl, graph=None):
        return True


def test_deltas_land_additively_through_the_real_pipeline(box, monkeypatch):
    from services.ingest.src import pipeline as pl
    pipe = pl.IngestPipeline()
    pipe.qdrant, pipe.oxigraph = _Q(), _O()
    monkeypatch.setattr(pl.vectorizer, "embed_batch", lambda texts: [[0.0] * 4 for _ in texts])

    def real(directory, ostler_dir, user):
        res = asyncio.run(pipe.ingest_directory(Path(directory), user_id="fixture"))
        return res["files_processed"] == 1

    box.helper_said(payload())
    assert r.apply(box.dir, ingest=real)["outcome"] == "stored"
    n1 = len(pipe.qdrant.points)
    assert n1 == 3
    before = copy.deepcopy(pipe.qdrant.points)

    nxt = copy.deepcopy(TRACKS)
    nxt[0]["play_count"] = 50
    box.helper_said(payload(nxt))
    assert r.apply(box.dir, ingest=real)["outcome"] == "stored"
    after = pipe.qdrant.points
    assert len(after) == n1, "same stable id: the changed track is updated, not duplicated"
    assert pipe.qdrant.deletes == 0
    changed = [k for k in after if after[k] != before[k]]
    assert len(changed) == 1, "only the track whose play count moved was rewritten"


# ── 7. THE SHIPPED SWIFT AND SHELL, read as text (cannot run off a Mac) ────

SWIFT = (ROOT / "gui/OstlerInstaller/Auth/MusicRefreshMode.swift").read_text()
APP_SWIFT = (ROOT / "gui/OstlerInstaller/App.swift").read_text()
INSTALL = (ROOT / "install.sh").read_text()


def _code(swift: str) -> str:
    return "\n".join(l for l in swift.splitlines() if not l.strip().startswith("//"))


def test_swift_mode_is_gated_by_armed_before_any_helper_is_touched():
    code = _code(SWIFT)
    guard = re.search(r'guard fm\.fileExists\(atPath: dir\.appendingPathComponent\("armed"\)\.path\) else \{[^}]*return 0', code)
    assert guard, "the armed guard must be a bare fileExists test that returns"
    assert guard.start() < code.index("proc.run()")


def test_swift_mode_runs_one_fixed_helper_and_takes_no_command_from_anywhere():
    code = _code(SWIFT)
    assert code.count("Process()") == 1
    assert code.count("executableURL") == 1 and "executableURL = helper" in code
    for forbidden in ("environment[", "ProcessInfo", "/bin/sh", "/bin/bash", "arguments = "):
        assert forbidden not in code, forbidden
    assert 'arguments.count == 2' in code     # exactly: <exe> --music-refresh


def test_the_app_runs_the_mode_before_any_scene_exists():
    assert re.search(r"init\(\)\s*\{[^}]*MusicRefreshMode\.runIfRequested\(\)", APP_SWIFT, re.S)


def test_install_arms_before_it_schedules_and_loads_through_the_verified_loader():
    a = INSTALL.index("apple_music_refresh arm --export")
    b = INSTALL.index("apple_music_refresh install-agents")
    c = INSTALL.index("com.ostler.music-refresh-apply.plist\" || true")
    d = INSTALL.index("com.ostler.music-refresh.plist\"; then")
    assert a < b < c < d
    assert '_AM_APP_EXEC="/Applications/OstlerInstaller.app/Contents/MacOS/OstlerInstaller"' in INSTALL, \
        "the agent points at the installed app, never the DMG or Resources"
    assert "SCRIPT_DIR:-}/../MacOS" not in INSTALL
    assert "arm --export \"$_AM_EXPORT\" --run-summary -" in INSTALL
