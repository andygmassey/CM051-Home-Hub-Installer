#!/usr/bin/env python3
"""Ongoing Spotify listening (CM051 "Spotify ongoing"): osascript answers
(playing, paused, not running, permission denied), the 30 s rule, dedupe, the
real CM019 parser and pipeline, the Doctor row, the shipped Swift and shell.

Synthetic data only: every title, artist and album below is a fixture string.
No test here calls the real osascript, security, tccutil or launchctl.
"""
from __future__ import annotations

import asyncio
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
sys.path.insert(0, str(ROOT / "vendor" / "doctor" / "agent"))

from ostler_fda import spotify_live as s  # noqa: E402

SEP = s.SEP
T0 = 1_760_000_000.0  # a fixed instant; every timestamp below is derived from it


def line(state="playing", tid="spotify:track:fixture0001", name="fixture-song-one",
         artist="fixture-band", album="fixture-album", pos="45", dur="200000") -> str:
    return SEP.join([state, tid, name, artist, album, pos, dur]) + "\n"


class Box:
    def __init__(self, tmp: Path):
        self.dir = tmp / "ostler"
        self.sdir = s.state_dir(self.dir)
        self.sdir.mkdir(parents=True)
        self.ingests = []
        self.ok = True

    def poll(self, rc=0, stdout="", stderr="", at=T0):
        (self.sdir / s.POLL_OUT_NAME).write_text(json.dumps(
            {"schema": 1, "polled_at": at, "rc": rc, "stdout": stdout, "stderr": stderr}))
        return self

    def ingest(self, directory, ostler_dir, user):
        rows = json.loads((Path(directory) / s.EXPORT_NAME).read_text())
        self.ingests.append([r["spotify_track_uri"] for r in rows])
        return self.ok

    def run(self):
        return s.apply(self.dir, ingest=self.ingest)


@pytest.fixture
def box(tmp_path):
    return Box(tmp_path)


# ── 1. what osascript said ─────────────────────────────────────────────────

def test_playing_is_read_field_by_field():
    o = s.parse_poll(0, line(), "")
    assert (o.status, o.track_id, o.name, o.artist, o.album, o.position_s, o.duration_ms) == (
        "playing", "spotify:track:fixture0001", "fixture-song-one", "fixture-band",
        "fixture-album", 45, 200000)


def test_paused_not_running_and_stopped():
    assert s.parse_poll(0, line("paused"), "").status == "paused"
    assert s.parse_poll(0, "not_running\n", "").status == "not_running"
    assert s.parse_poll(0, "stopped\n", "").status == "stopped"


def test_permission_denied_is_its_own_known_state():
    err = "execution error: Not authorized to send Apple events to Spotify. (-1743)"
    o = s.parse_poll(1, "", err)
    assert o.status == "automation_not_granted"


def test_other_failures_are_could_not_look_with_a_reason_never_denied():
    o = s.parse_poll(1, "", "execution error: Spotify got an error: Can't get track. (-1728)")
    assert o.status == "could_not_look" and o.reason == "osascript_rc_1"
    assert s.parse_poll(0, "garbage", "").status == "could_not_look"
    assert s.parse_poll("x", "", "").status == "could_not_look"


def test_title_containing_pipes_commas_and_unicode_survives():
    o = s.parse_poll(0, line(name="a|b, c é世", artist="x|y"), "")
    assert o.name == "a|b, c é世" and o.artist == "x|y"


def test_a_comma_decimal_position_is_still_read():
    assert s.parse_poll(0, line(pos="45,0"), "").position_s == 45


def test_the_script_never_launches_spotify():
    first = s.APPLESCRIPT.splitlines()[0]
    assert first == 'if application "Spotify" is not running then return "not_running"'
    # no `tell application "Spotify"` may precede the guard
    assert s.APPLESCRIPT.index('tell application "Spotify"') > s.APPLESCRIPT.index(first)
    assert "launch" not in s.APPLESCRIPT.lower() and "activate" not in s.APPLESCRIPT.lower()


# ── 2. the 30 s rule and dedupe ────────────────────────────────────────────

def play(state, pos, at, tid="spotify:track:fixture0001", status="playing", **kw):
    obs = s.Observation(status, track_id=tid, name=kw.get("name", "fixture-song-one"),
                        artist=kw.get("artist", "fixture-band"), album="fixture-album",
                        position_s=pos, duration_ms=200000)
    return s.advance(state, obs, at)


def test_below_thirty_seconds_is_not_a_play_at_thirty_it_is():
    st = {}
    assert play(st, 29, T0) is None
    assert play(st, 30, T0 + 1) is not None


def test_the_same_listen_seen_again_counts_once():
    st = {}
    first = play(st, 40, T0)
    assert first is not None
    assert play(st, 100, T0 + 60) is None
    assert play(st, 160, T0 + 120) is None


def test_a_track_seen_first_below_30_is_counted_on_the_next_poll_once():
    st = {}
    assert play(st, 10, T0) is None
    assert play(st, 70, T0 + 60) is not None
    assert play(st, 130, T0 + 120) is None


def test_pause_and_resume_is_one_play():
    st = {}
    assert play(st, 40, T0) is not None
    assert play(st, 0, T0 + 60, status="paused") is None
    assert play(st, 41, T0 + 600) is None


def test_a_restart_of_the_same_track_is_a_new_play():
    st = {}
    assert play(st, 170, T0) is not None
    assert play(st, 40, T0 + 60) is not None


def test_a_different_track_is_a_new_play():
    st = {}
    assert play(st, 40, T0) is not None
    assert play(st, 40, T0 + 60, tid="spotify:track:fixture0002") is not None


def test_stopped_or_closed_forgets_the_current_play():
    st = {}
    play(st, 40, T0)
    s.advance(st, s.Observation("stopped"), T0 + 60)
    assert st["current"] is None
    assert play(st, 45, T0 + 120) is not None


def test_ads_episodes_and_local_files_are_counted_not_emitted():
    for tid in ("spotify:ad:fixture", "spotify:episode:fixture", "spotify:local:a:b:c:1"):
        st = {}
        assert play(st, 60, T0, tid=tid) is None
        assert st["skipped_non_track"] == 1
    st = {}
    assert play(st, 60, T0, artist="") is None  # a track with no artist is not a play


def test_the_play_is_timed_to_its_start_in_utc():
    st = {}
    p = play(st, 60, T0)
    assert p["ts"] == "2025-10-09T08:52:40Z"  # T0 - 60 s, explicit UTC (Z)
    assert p["ms_played"] == 60000


# ── 3. apply: store, retry, outcomes ───────────────────────────────────────

def test_not_running_writes_nothing_and_never_calls_the_ingest(box):
    box.poll(stdout="not_running\n")
    assert box.run()["outcome"] == "idle"
    assert box.ingests == []
    assert not (box.dir / "state" / "hydrate" / "spotify_live.done").exists()


def test_no_poll_file_is_nothing_to_do(box):
    assert box.run()["outcome"] == "nothing_to_do"


def test_playing_past_30s_is_stored_once_and_the_poll_is_consumed(box):
    box.poll(stdout=line(pos="45"))
    res = box.run()
    assert res["outcome"] == "stored" and res["plays"] == 1
    assert box.ingests == [["spotify:track:fixture0001"]]
    assert not (box.sdir / s.POLL_OUT_NAME).exists()
    box.poll(stdout=line(pos="105"), at=T0 + 60)
    assert box.run()["outcome"] == "idle"
    assert len(box.ingests) == 1, "the same listen is not stored twice"


def test_a_failed_ingest_keeps_the_play_and_retries_it_whole(box):
    box.ok = False
    box.poll(stdout=line(pos="45"))
    assert box.run()["outcome"] == "could_not_store"
    box.ok = True
    box.poll(stdout=line(tid="spotify:track:fixture0002", pos="45"), at=T0 + 60)
    res = box.run()
    assert res["outcome"] == "stored" and res["plays"] == 2
    assert box.ingests[-1] == ["spotify:track:fixture0001", "spotify:track:fixture0002"]


def test_a_raising_ingest_never_raises_out_of_apply(box):
    def boom(*a):
        raise RuntimeError("fixture")
    box.poll(stdout=line(pos="45"))
    assert s.apply(box.dir, ingest=boom)["outcome"] == "could_not_store"


def test_a_corrupt_poll_file_is_could_not_look_not_a_crash(box):
    (box.sdir / s.POLL_OUT_NAME).write_text("{not json")
    assert box.run()["outcome"] == "could_not_look"
    assert not (box.sdir / s.POLL_OUT_NAME).exists(), "consumed, not looped on"


def test_denied_records_the_known_state_for_the_doctor(box):
    box.poll(rc=1, stderr="Not authorized to send Apple events to Spotify. (-1743)")
    res = box.run()
    assert res == {"outcome": "cannot_run", "reason": "automation_not_granted"}
    act = (box.dir / "state" / "source_activity" / "spotify_live.tsv").read_text()
    assert "last_status=cannot_run" in act and "automation_not_granted" in act
    assert box.ingests == []


def test_a_later_success_carries_last_success_and_clears_the_refusal(box):
    box.poll(stdout=line(pos="45"))
    box.run()
    ok_at = re.search(r"last_success_at=(\S+)", (
        box.dir / "state/source_activity/spotify_live.tsv").read_text()).group(1)
    box.poll(rc=1, stderr="(-1743)", at=T0 + 60)
    box.run()
    act = (box.dir / "state/source_activity/spotify_live.tsv").read_text()
    assert "last_status=cannot_run" in act and f"last_success_at={ok_at}" in act


def test_logs_carry_counts_never_titles(box, caplog):
    caplog.set_level("INFO")
    box.poll(stdout=line(name="fixture-secret-title", artist="fixture-secret-artist", pos="45"))
    box.run()
    assert "fixture-secret" not in caplog.text
    tsv = (box.dir / "state/source_activity/spotify_live.tsv").read_text()
    sentinel = (box.dir / "state/hydrate/spotify_live.done").read_text()
    assert "fixture-secret" not in tsv + sentinel


def test_titles_are_not_left_on_disk_once_stored(box):
    box.poll(stdout=line(name="fixture-secret-title", pos="45"))
    box.run()
    left = [p for p in box.dir.rglob("*") if p.is_file()
            and "fixture-secret-title" in p.read_text(errors="replace")]
    assert left == []


def test_state_and_export_files_are_owner_only(box):
    box.ok = False
    box.poll(stdout=line(pos="45"))
    box.run()
    for p in (box.sdir / s.STATE_NAME, box.dir / s.DELTA_DIR_REL / s.EXPORT_NAME):
        assert (p.stat().st_mode & 0o777) == 0o600, p


# ── 4. END TO END through the real CM019 parser and pipeline ───────────────

class _Q:
    def __init__(self):
        self.points = {}

    async def initialize(self):
        return True

    async def upsert_vectors(self, vectors, payloads, ids):
        for i, pl in zip(ids, payloads):
            self.points[i] = pl
        return True

    async def delete_by_user(self, *a, **k):
        return True


class _O:
    async def initialize(self):
        return True

    async def insert_triples(self, ttl, graph=None):
        return True


def test_a_live_play_takes_the_export_path_through_the_real_pipeline(box, monkeypatch):
    from services.ingest.src import pipeline as pl
    pipe = pl.IngestPipeline()
    pipe.qdrant, pipe.oxigraph = _Q(), _O()
    monkeypatch.setattr(pl.vectorizer, "embed_batch", lambda texts: [[0.0] * 4 for _ in texts])

    def real(directory, ostler_dir, user):
        res = asyncio.run(pipe.ingest_directory(Path(directory), user_id="fixture"))
        return res["files_processed"] == 1

    box.poll(stdout=line(pos="45"))
    assert s.apply(box.dir, ingest=real)["outcome"] == "stored"
    assert len(pipe.qdrant.points) == 1
    payload = next(iter(pipe.qdrant.points.values()))
    blob = json.dumps(payload, default=str).lower()
    assert "fixture-band" in blob and "fixture-song-one" in blob
    assert "spotify" in blob


def test_a_live_play_is_a_passive_neutral_music_preference_like_an_exported_one(tmp_path):
    from services.ingest.src.parsers.spotify import SpotifyParser
    f = tmp_path / s.EXPORT_NAME
    f.write_text(json.dumps(s.to_export_rows([
        {"id": "spotify:track:fixture0001", "name": "fixture-song-one",
         "artist": "fixture-band", "album": "fixture-album", "ms_played": 45000,
         "ts": "2025-10-09T08:52:40Z"}])))
    parser = SpotifyParser()
    assert parser.can_parse(f)

    async def collect():
        return [p async for p in parser.parse(f, default_compartment=1)]
    prefs = asyncio.run(collect())
    assert len(prefs) == 1
    p = prefs[0]
    assert (p.category, p.preference_type, p.source) == ("music", "Neutral", "spotify")
    assert p.extra["passive_play"] is True and p.extra["spotify_uri"] == "spotify:track:fixture0001"
    assert p.observed_at is not None and p.observed_at.tzinfo is not None


# ── 5. the Doctor row ──────────────────────────────────────────────────────

def test_doctor_says_ostler_needs_automation_access_to_spotify(box):
    import web_ui
    box.poll(rc=1, stderr="Not authorized to send Apple events to Spotify. (-1743)")
    box.run()
    rows = web_ui.read_source_status(box.dir / "state" / "hydrate",
                                     box.dir / "state" / "source_activity")
    row = next(r for r in rows if r["source"] == "spotify_live")
    assert row["status"] == "cannot_run"
    assert row["needs_access"] == "Automation access to Spotify"
    assert row["reason"].startswith("Ostler needs Automation access to Spotify")
    assert "Full Disk Access" not in row["detail"] + row["reason"]


def test_doctor_has_no_spotify_row_until_a_poll_has_seen_spotify(tmp_path):
    import web_ui
    (tmp_path / "h").mkdir()
    (tmp_path / "a").mkdir()
    rows = web_ui.read_source_status(tmp_path / "h", tmp_path / "a")
    assert all(r["source"] != "spotify_live" for r in rows)


def test_doctor_row_is_ok_after_a_stored_play(box):
    import web_ui
    box.poll(stdout=line(pos="45"))
    box.run()
    rows = web_ui.read_source_status(box.dir / "state" / "hydrate",
                                     box.dir / "state" / "source_activity")
    row = next(r for r in rows if r["source"] == "spotify_live")
    assert row["status"] == "ok" and row["ongoing"] == "active"
    assert "needs_access" not in row


def test_an_fda_refusal_for_another_source_keeps_its_full_disk_access_text(tmp_path):
    import web_ui
    h, a = tmp_path / "h", tmp_path / "a"
    h.mkdir()
    a.mkdir()
    (h / "contacts.done").write_text("source=contacts\nstatus=ok\nitem_count=1\nrecorded_at=x\n")
    (a / "contacts.tsv").write_text(
        "source=contacts\nlast_run_at=x\nlast_status=cannot_run\nlast_success_at=\n"
        'last_detail={"reason": "automation_not_granted"}\n')
    row = next(r for r in web_ui.read_source_status(h, a) if r["source"] == "contacts")
    assert row["needs_access"] == "Full Disk Access"


# ── 6. scheduling ──────────────────────────────────────────────────────────

APP = "/Applications/OstlerInstaller.app/Contents/MacOS/OstlerInstaller"


def test_run_agent_is_every_minute_in_the_gui_session_with_one_fixed_flag():
    p = s.render_run_plist(APP, "/logs")
    assert p["Label"] == "com.ostler.spotify-live"
    assert p["ProgramArguments"] == [APP, "--spotify-poll"]
    assert p["StartInterval"] == 60
    assert p["LimitLoadToSessionType"] == "Aqua"
    assert "KeepAlive" not in p and "RunAtLoad" not in p


def test_apply_agent_has_no_tcc_need_and_watches_only_the_poll_file():
    p = s.render_apply_plist("/py", "/fda", "/home/o/.ostler", "/logs", "u")
    assert p["WatchPaths"] == ["/home/o/.ostler/state/spotify_live/poll_out.json"]
    assert p["ProgramArguments"][-3:] == ["-m", "ostler_fda.spotify_live", "apply"]
    plistlib.dumps(p)


def test_install_agents_refuses_an_unstable_app_path_and_records_why(tmp_path, monkeypatch):
    monkeypatch.setattr(s, "spotify_installed", lambda: True)
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "o"))
    adir = tmp_path / "la"
    rc = s.main(["install-agents", "--app-executable",
                 "/Volumes/Ostler/OstlerInstaller.app/Contents/MacOS/OstlerInstaller",
                 "--python", "/py", "--fda-parent", "/f", "--agents-dir", str(adir)])
    assert rc == 0 and not adir.exists()
    assert "installer_not_in_applications" in (
        tmp_path / "o/state/source_activity/spotify_live.tsv").read_text()


def test_install_agents_without_spotify_installs_nothing(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(s, "spotify_installed", lambda: False)
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "o"))
    adir = tmp_path / "la"
    assert s.main(["install-agents", "--app-executable", APP, "--python", "/py",
                   "--fda-parent", "/f", "--agents-dir", str(adir)]) == 0
    assert "not installed: Spotify" in capsys.readouterr().out and not adir.exists()


def test_install_agents_writes_both_plists_and_is_idempotent(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(s, "spotify_installed", lambda: True)
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "o"))
    args = ["install-agents", "--app-executable", APP, "--python", "/py",
            "--fda-parent", "/f", "--agents-dir", str(tmp_path / "la")]
    s.main(args)
    assert "run_changed=1 apply_changed=1" in capsys.readouterr().out
    s.main(args)
    assert "run_changed=0 apply_changed=0" in capsys.readouterr().out
    assert sorted(p.name for p in (tmp_path / "la").iterdir()) == [
        "com.ostler.spotify-live-apply.plist", "com.ostler.spotify-live.plist"]


# ── 7. the shipped Swift and shell ─────────────────────────────────────────

SWIFT_PATH = ROOT / "gui/OstlerInstaller/Auth/SpotifyLiveMode.swift"
SWIFT = SWIFT_PATH.read_text()
INSTALL = (ROOT / "install.sh").read_text()


def _swift_script() -> str:
    m = re.search(r'static let script = """\n(.*?)\n    """', SWIFT, re.S)
    assert m, "script literal not found"
    return "\n".join(l[4:] if l.startswith("    ") else l for l in m.group(1).splitlines())


def test_swift_script_is_byte_for_byte_the_one_the_python_tests_pin():
    assert _swift_script().strip() == s.APPLESCRIPT.strip()


def test_swift_mode_takes_exactly_one_flag_and_no_path_or_command_from_anywhere():
    assert 'static let flag = "--spotify-poll"' in SWIFT
    assert "arguments.count == 2 && arguments[1] == flag" in SWIFT
    code = "\n".join(l for l in SWIFT.splitlines() if not l.strip().startswith("//"))
    assert "ProcessInfo" not in code and "environment" not in code


def test_swift_mode_does_not_start_osascript_unless_spotify_is_running():
    code = "\n".join(l for l in SWIFT.splitlines() if not l.strip().startswith("//"))
    assert code.index("guard spotifyRunning else { return 0 }") < code.index("proc.run()")
    assert "launchApplication" not in code and "openApplication" not in code


def test_the_app_calls_the_mode_before_any_scene():
    app = (ROOT / "gui/OstlerInstaller/App.swift").read_text()
    init = app[app.index("init() {"):app.index("var body: some Scene")]
    assert "SpotifyLiveMode.runIfRequested()" in init


def test_the_swift_file_is_in_the_xcode_target():
    pbx = (ROOT / "gui/OstlerInstaller.xcodeproj/project.pbxproj").read_text()
    assert re.search(r"SpotifyLiveMode\.swift in Sources \*/ = \{isa = PBXBuildFile", pbx)
    assert re.search(r"SpotifyLiveMode\.swift \*/ = \{isa = PBXFileReference", pbx)
    assert re.search(r"\n\t+[0-9A-F]{24} /\* SpotifyLiveMode\.swift \*/,\n", pbx), "group"
    assert re.search(r"\n\t+[0-9A-F]{24} /\* SpotifyLiveMode\.swift in Sources \*/,\n", pbx), "phase"


def test_install_sh_installs_the_agents_and_cannot_abort_the_install():
    i = INSTALL.index("Spotify listening, ongoing")
    blk = INSTALL[i:INSTALL.index("unset -f _sp_cannot", i)]
    assert "ostler_fda.spotify_live install-agents" in blk
    assert "com.ostler.spotify-live-apply.plist" in blk and "com.ostler.spotify-live.plist" in blk
    assert "|| _SP_OUT=" in blk, "a failing install-agents must not trip set -e"
    assert "|| true" in blk
    assert "OSTLER_LAUNCHAGENT_LABELS" not in blk


def test_both_labels_are_torn_down_and_declared():
    labels = INSTALL[INSTALL.index("OSTLER_LAUNCHAGENT_LABELS=("):]
    labels = labels[:labels.index(")")]
    for lab in ("com.ostler.spotify-live", "com.ostler.spotify-live-apply"):
        assert lab in labels.split()
        assert re.search(r"^launch_agent\t%s\tconditional\t" % re.escape(lab),
                         (ROOT / "scripts/install_manifest.tsv").read_text(), re.M)


def test_the_vendor_only_file_is_registered():
    assert "ostler_fda/spotify_live.py\tHR015" in (ROOT / "vendor/VENDOR_ONLY.tsv").read_text()


# ── 8. THE SWIFT, ACTUALLY RUN, against a stub osascript, into the Python ──

@pytest.mark.skipif(shutil.which("swiftc") is None, reason="CANNOT-RUN: no swiftc on this host")
def test_the_compiled_swift_hands_its_answer_to_the_python_unchanged(tmp_path):
    stub = tmp_path / "osascript"
    stub.write_text("#!/bin/sh\nprintf '%s' \"$STUB_OUT\"\nprintf '%s' \"$STUB_ERR\" >&2\nexit ${STUB_RC:-0}\n")
    stub.chmod(0o755)
    harness = tmp_path / "main.swift"
    harness.write_text(
        'import Foundation\n'
        'let e = ProcessInfo.processInfo.environment\n'
        'let running = e["STUB_RUNNING"] == "1"\n'
        '_ = SpotifyLiveMode.run(home: e["STUB_HOME"]!, spotifyRunning: running, '
        'osascript: e["STUB_BIN"]!)\n')
    exe = tmp_path / "harness"
    build = subprocess.run(["swiftc", "-o", str(exe), str(SWIFT_PATH), str(harness)],
                           capture_output=True, text=True, timeout=600)
    assert build.returncode == 0, build.stderr[-800:]

    def drive(running, out="", err="", rc=0):
        home = tmp_path / f"home{running}{rc}{len(out)}"
        home.mkdir()
        env = {"PATH": "/usr/bin:/bin", "STUB_HOME": str(home), "STUB_BIN": str(stub),
               "STUB_RUNNING": "1" if running else "0", "STUB_OUT": out, "STUB_ERR": err,
               "STUB_RC": str(rc)}
        subprocess.run([str(exe)], env=env, check=True, capture_output=True, timeout=60)
        return home

    # not running: no file, osascript never started
    h = drive(False, out=line())
    assert not (h / ".ostler/state/spotify_live/poll_out.json").exists()

    # playing: the Python reads the Swift's file and stores one play
    h = drive(True, out=line(pos="45"))
    f = h / ".ostler/state/spotify_live/poll_out.json"
    assert (f.stat().st_mode & 0o777) == 0o600
    got = []
    res = s.apply(h / ".ostler", ingest=lambda d, o, u: got.append(1) or True)
    assert res["outcome"] == "stored" and got

    # denied: the Python names the known state
    h = drive(True, err="Not authorized to send Apple events to Spotify. (-1743)", rc=1)
    assert s.apply(h / ".ostler", ingest=lambda *a: True)["reason"] == "automation_not_granted"
